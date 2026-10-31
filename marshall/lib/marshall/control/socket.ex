defmodule Marshall.Control.Socket do
  @moduledoc """
  Server side of one control WebSocket (ADR-0142).

  The first frame must be a hello for the service authenticated at upgrade.
  Requests run in supervised tasks, so a domain transaction always completes
  even if the socket dies; only its response can be lost, as with HTTPS.
  At most the service's `running` limit execute at once; further accepted
  requests wait in FIFO order here and start as running ones finish
  (ADR-0275). One that waited past the queue deadline is answered
  `temporarily_unavailable` without running.
  Hints for the bound identity are pushed as they arrive, and a notifier
  recovery pushes a resync.
  """
  @behaviour WebSock
  require Marshall.Events

  alias OverallsProtocol.Control.{Close, Envelope}
  alias Marshall.Control.Hints

  @heartbeat_ms 5_000
  @idle_ms 15_000

  @impl true
  def init(%{service: service, module: module, principal: principal}) do
    Process.send_after(self(), :hello_deadline, @heartbeat_ms)

    {:ok,
     %{
       service: service,
       module: module,
       principal: principal,
       limits: Marshall.Control.Service.limits(module),
       queue_deadline_ms: Marshall.Control.Concurrency.fetch!().queue_deadline_ms,
       identity: nil,
       tasks: %{},
       queue: :queue.new(),
       last_seen: now(),
       ping: 0
     }}
  end

  # @cc [owner:ghuntley,label:security;protocol] control-hello-binds-identity
  # No request or hint is served before a hello for the upgraded service binds
  # through the service module. Any other first frame, a different service or
  # version, or a failed bind closes with the matching close code.
  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    state = %{state | last_seen: now()}

    case Envelope.decode(text) do
      {:ok, message} -> message(message, state)
      {:error, :unsupported_version} -> close(state, :unsupported_version)
      {:error, :invalid_message} -> close(state, :protocol_violation)
    end
  end

  def handle_in(_frame, state), do: close(state, :protocol_violation)

  @impl true
  def handle_info(:hello_deadline, %{identity: nil} = state),
    do: close(state, :protocol_violation)

  def handle_info(:hello_deadline, state), do: {:ok, state}

  def handle_info(:heartbeat, state) do
    if now() - state.last_seen > @idle_ms do
      close(state, :idle)
    else
      Process.send_after(self(), :heartbeat, @heartbeat_ms)
      ping = state.ping + 1
      {:push, {:text, Envelope.encode({:ping, ping})}, %{state | ping: ping}}
    end
  end

  def handle_info({:control_hint, kind, id}, %{identity: identity} = state) when identity != nil,
    do: {:push, {:text, Envelope.encode({:hint, %{kind: Atom.to_string(kind), id: id}})}, state}

  def handle_info(:control_resync, %{identity: identity} = state) when identity != nil,
    do: {:push, {:text, Envelope.encode(:resync)}, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:ok, state}

      {id, tasks} ->
        Process.demonitor(ref, [:flush])
        response = {:text, Envelope.encode({:res, %{id: id, result: result}})}
        dispatch(%{state | tasks: tasks}, [response])
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:ok, state}

      {id, tasks} ->
        result = {:error, "unavailable"}
        response = {:text, Envelope.encode({:res, %{id: id, result: result}})}
        dispatch(%{state | tasks: tasks}, [response])
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @spec message(Envelope.message(), map()) :: WebSock.handle_result()
  defp message({:hello, %{service: service, bind: bind}}, %{identity: nil} = state) do
    if service == state.service do
      bind(bind, state)
    else
      close(state, :refused)
    end
  end

  defp message(_message, %{identity: nil} = state), do: close(state, :protocol_violation)

  defp message({:req, %{id: id, op: op, body: body}}, %{identity: identity} = state)
       when identity != nil do
    cond do
      map_size(state.tasks) + :queue.len(state.queue) >= state.limits.in_flight ->
        {:push, {:text, Envelope.encode({:res, %{id: id, result: {:error, "busy"}}})}, state}

      Marshall.Control.FaultGate.blocked?(op) ->
        result = {:error, "temporarily_unavailable"}
        {:push, {:text, Envelope.encode({:res, %{id: id, result: result}})}, state}

      true ->
        queue = :queue.in({id, op, body, identity, now()}, state.queue)
        dispatch(%{state | queue: queue}, [])
    end
  end

  defp message({:ping, n}, state), do: {:push, {:text, Envelope.encode({:pong, n})}, state}
  defp message({:pong, _n}, state), do: {:ok, state}
  defp message(_message, state), do: close(state, :protocol_violation)

  @spec bind(map(), map()) :: WebSock.handle_result()
  defp bind(bind, state) do
    case state.module.bind(state.principal, bind) do
      {:ok, identity, subscriptions} ->
        Enum.each(subscriptions, fn {kind, id} -> :ok = Hints.subscribe(kind, id) end)
        :ok = Hints.subscribe_resync()
        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        Marshall.Events.emit("control.connected", service: service_atom(state.service))

        welcome = %{
          conn: Ecto.UUID.generate(),
          heartbeat_ms: @heartbeat_ms,
          limits: %{"frame" => state.limits.frame, "in_flight" => state.limits.in_flight}
        }

        {:push, {:text, Envelope.encode({:welcome, welcome})}, %{state | identity: identity}}

      {:close, reason} ->
        close(state, reason)
    end
  end

  # @cc [owner:ghuntley,label:capacity;protocol] control-bounded-fifo-dispatch
  # Accepted requests MUST start in arrival order, with at most limits.running
  # of them running at once; running plus queued MUST stay within the
  # advertised in_flight, so the busy refusal fires exactly where it did
  # before. Every accepted request MUST be answered exactly once: with its
  # result, `unavailable` if its task dies, or `temporarily_unavailable` when it
  # waited queue_deadline_ms or longer, in which case it MUST NOT start. Frames
  # and reply names are unchanged; only their timing differs (ADR-0275).
  @spec dispatch(map(), [WebSock.message()]) :: WebSock.handle_result()
  defp dispatch(state, responses) do
    if map_size(state.tasks) < state.limits.running do
      case :queue.out(state.queue) do
        {:empty, _queue} ->
          push(state, responses)

        {{:value, {id, op, body, identity, received}}, queue} ->
          state = %{state | queue: queue}

          if now() - received >= state.queue_deadline_ms do
            Marshall.Events.emit("control.request_expired", service: service_atom(state.service))
            result = {:error, "temporarily_unavailable"}
            response = {:text, Envelope.encode({:res, %{id: id, result: result}})}
            dispatch(state, [response | responses])
          else
            dispatch(start(state, id, op, body, identity), responses)
          end
      end
    else
      push(state, responses)
    end
  end

  @spec push(map(), [WebSock.message()]) :: WebSock.handle_result()
  defp push(state, []), do: {:ok, state}
  defp push(state, [response]), do: {:push, response, state}
  defp push(state, responses), do: {:push, Enum.reverse(responses), state}

  @spec start(map(), term(), String.t(), map(), term()) :: map()
  defp start(state, id, op, body, identity) do
    module = state.module
    service = state.service

    task =
      Task.Supervisor.async_nolink(Marshall.Control.TaskSupervisor, fn ->
        # @cc [owner:ghuntley,label:security;observability] control-request-log-redaction
        # Request tasks MUST carry the authentication redaction metadata
        # the upgrade set: Logger metadata does not cross process
        # boundaries, and domain queries carry credentials and arguments.
        Logger.metadata(marshall_authentication: true)
        measured(service, fn -> request(module, op, body, identity) end)
      end)

    %{state | tasks: Map.put(state.tasks, task.ref, id)}
  end

  @spec request(module(), String.t(), map(), term()) :: {:ok, map()} | {:error, String.t()}
  defp request(module, op, body, identity) do
    module.handle_request(op, body, identity)
  rescue
    _ -> {:error, "unavailable"}
  end

  # @cc [owner:ghuntley,label:observability] control-request-telemetry
  # Lilly and Porsche requests MUST keep emitting the request telemetry their
  # HTTPS plugs emitted (control_* and ssh_* aggregates): duration plus a
  # status class of 200, 400 for a named refusal or 503 when unavailable.
  # Only the fixed status reaches metadata, never the op, body or identity.
  @spec measured(String.t(), (-> {:ok, map()} | {:error, String.t()})) ::
          {:ok, map()} | {:error, String.t()}
  defp measured(service, fun) do
    started = System.monotonic_time()
    result = fun.()

    case service_event(service) do
      nil ->
        result

      event ->
        Overalls.Diagnostics.Metrics.record(
          event,
          %{duration: System.monotonic_time() - started},
          %{
            status: status_class(result)
          }
        )

        result
    end
  end

  @spec service_event(String.t()) :: [atom()] | nil
  defp service_event("lilly"), do: [:marshall, :control, :request]
  defp service_event("porsche"), do: [:marshall, :ssh, :request]
  defp service_event(_service), do: nil

  @spec status_class({:ok, map()} | {:error, String.t()}) :: 200 | 400 | 503
  defp status_class({:ok, _value}), do: 200

  defp status_class({:error, name}) when name in ["unavailable", "temporarily_unavailable"],
    do: 503

  defp status_class(_result), do: 400

  @spec close(map(), Close.reason()) :: WebSock.handle_result()
  defp close(state, reason) do
    Marshall.Events.emit("control.closed", reason: reason)
    {:stop, :normal, {Close.code(reason), ""}, state}
  end

  @spec service_atom(String.t()) :: atom()
  defp service_atom("audi"), do: :audi
  defp service_atom("galileo"), do: :galileo
  defp service_atom("lilly"), do: :lilly
  defp service_atom("porsche"), do: :porsche
  defp service_atom("ziggy"), do: :ziggy
  defp service_atom(_service), do: :other

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
