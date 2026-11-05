defmodule Ziggy.AgentWorker do
  @moduledoc "Host-side pull worker for Marshall-owned model calls."
  use GenServer
  require Ziggy.Events

  @maximum_active 16
  @poll_ms 1000
  @maximum_body 1_048_576

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    config = Keyword.fetch!(options, :config)
    Process.send_after(self(), :poll, @poll_ms)

    {:ok,
     %{
       config: config,
       active: %{},
       request: Keyword.get(options, :request, &Ziggy.Control.request/3),
       fence: Ziggy.VersionFence.new(options)
     }}
  end

  # @cc [owner:ghuntley,label:recovery] version-refusal-stops-model-poll
  # A control API version refusal MUST stop normal-cadence model-call polling
  # without claiming or launching another provider request; Ziggy.VersionFence
  # backs off and probes, and an accepted probe resumes polling.
  @impl true
  def handle_info(:poll, %{fence: fence} = state) do
    if Ziggy.VersionFence.fenced?(fence), do: {:noreply, state}, else: poll(state)
  end

  # A hinted claim runs once without rescheduling: the periodic poll timer is
  # still pending, so hints never multiply the cadence. A refusal still fences.
  def handle_info(:work_hinted, %{fence: fence} = state) do
    if Ziggy.VersionFence.fenced?(fence), do: {:noreply, state}, else: claim_once(state)
  end

  def handle_info({:probe, token}, %{fence: fence} = state) do
    if Ziggy.VersionFence.probe?(fence, token), do: poll(state), else: {:noreply, state}
  end

  def handle_info({ref, result}, %{active: active} = state) when is_map_key(active, ref) do
    Process.demonitor(ref, [:flush])
    id = Map.fetch!(active, ref)

    if OverallsProtocol.uuid?(id),
      do: Ziggy.Events.emit("ziggy.agent_model_finished", request_id: id, reason: result)

    {:noreply, %{state | active: Map.delete(active, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: active} = state)
      when is_map_key(active, ref) do
    id = Map.fetch!(active, ref)

    if OverallsProtocol.uuid?(id),
      do: Ziggy.Events.emit("ziggy.agent_model_finished", request_id: id, reason: :task_lost)

    {:noreply, %{state | active: Map.delete(active, ref)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:security;recovery] agent-model-host-pull-single-attempt
  # The claimed request MUST match this host and a closed provider route.
  # Marshall admission and a fsynced spool slot MUST precede provider bytes.
  # A crashed or revoked task MUST leave the claimed call uncertain, never
  # auto-claim it again. Only identifiers and closed outcomes enter diagnostics.
  @spec execute(map(), map()) :: atom()
  def execute(config, work) do
    with {:ok, id, claim_id, wire, route} <- validate(config, work),
         input =
           Map.merge(wire, %{
             "request_id" => id,
             "provider" => "openai",
             "model" => route.model,
             "operation" => operation(route.path)
           }),
         {:ok, %{"owner_id" => owner, "admitted_at" => admitted_at, "ttl_ms" => 30_000}} <-
           Ziggy.Control.request(config.control, "admit", input),
         :ok <-
           Ziggy.Spool.admit(
             Ziggy.Spool,
             Map.merge(input, %{"owner_id" => owner, "admitted_at" => admitted_at})
           ),
         {:ok, lease} <- lease(config, id) do
      started = System.monotonic_time(:millisecond)
      Process.put({__MODULE__, :body}, "")
      Process.put({__MODULE__, :response_stream}, nil)
      Process.put({__MODULE__, :responses?}, route.path == "/v1/responses")
      Process.put({__MODULE__, :response_error}, nil)

      try do
        result =
          Ziggy.Upstream.stream(
            route,
            Map.fetch!(config.credentials, :openai),
            [],
            &consume/1,
            finch: Ziggy.Finch,
            finch_module: Map.get(config, :finch_module, Finch),
            request_id: id,
            openai_origin: config.openai_origin
          )

        Ziggy.Lease.stop(lease)

        response =
          provider_response(
            result,
            Process.get({__MODULE__, :body}),
            Process.get({__MODULE__, :response_stream})
          )

        completion = %{
          "provider_request_id" => result.provider_request_id,
          "http_status" => result.status,
          "cost_estimate" => Ziggy.Pricing.estimate(:openai, route.model, result.usage),
          "outcome" => Atom.to_string(accounting_outcome(result.outcome, response)),
          "tokens" => result.usage.tokens,
          "completeness" => result.usage.completeness,
          "duration_ms" => System.monotonic_time(:millisecond) - started,
          "request_bytes" => byte_size(route.body),
          "response_bytes" => result.response_bytes
        }

        with :ok <- Ziggy.Spool.complete(Ziggy.Spool, id, completion),
             :ok <- deliver_result(config, id, claim_id, response, 3) do
          :completed
        else
          _ -> :result_unavailable
        end
      after
        Process.delete({__MODULE__, :body})
        Process.delete({__MODULE__, :response_stream})
        Process.delete({__MODULE__, :responses?})
        Process.delete({__MODULE__, :response_error})
      end
    else
      _ -> :admission_unavailable
    end
  end

  defp validate(config, %{
         "id" => id,
         "claim_id" => claim_id,
         "binding" => wire,
         "request" => request
       })
       when is_map(wire) and is_map(request) do
    with true <- OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(claim_id),
         {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire),
         true <- binding.host_id == config.host_id,
         true <- Map.has_key?(config.credentials, :openai),
         body = Jason.encode!(request),
         true <- byte_size(body) <= 262_144,
         {:ok, path} <- agent_path(request),
         {:ok, route} <- Ziggy.Route.resolve("POST", path, "", body) do
      {:ok, id, claim_id, wire, route}
    else
      _ -> {:error, :invalid_work}
    end
  end

  defp validate(_, _), do: {:error, :invalid_work}

  defp agent_path(%{"input" => input} = request)
       when is_list(input) and not is_map_key(request, "messages"),
       do: {:ok, "/v1/responses"}

  defp agent_path(%{"messages" => messages} = request)
       when is_list(messages) and not is_map_key(request, "input"),
       do: {:ok, "/v1/chat/completions"}

  defp agent_path(_), do: {:error, :invalid_work}

  @spec operation(binary()) :: binary()
  defp operation("/v1/responses"), do: "responses"
  defp operation("/v1/chat/completions"), do: "chat"

  defp lease(config, id) do
    DynamicSupervisor.start_child(
      Ziggy.Leases,
      {Ziggy.Lease,
       owner: self(),
       tasks: Ziggy.Tasks,
       ttl_ms: 30_000,
       renewal_ms: 10_000,
       request_id: id,
       renew: fn ->
         case Ziggy.Control.request(config.control, "renew", %{"request_id" => id}) do
           {:ok, %{"request_id" => ^id, "ttl_ms" => 30_000}} -> :ok
           _ -> :error
         end
       end}
    )
  end

  defp consume({:headers, headers}) do
    streaming? =
      Enum.any?(headers, fn {name, value} ->
        name == "content-type" and String.starts_with?(value, "text/event-stream")
      end)

    if Process.get({__MODULE__, :responses?}) and streaming?,
      do: Process.put({__MODULE__, :response_stream}, %Ziggy.AgentStream{})

    :ok
  end

  defp consume({:data, chunk}) do
    case Process.get({__MODULE__, :response_stream}) do
      %Ziggy.AgentStream{} = state ->
        case Ziggy.AgentStream.feed(state, chunk) do
          {:ok, next} ->
            Process.put({__MODULE__, :response_stream}, next)
            :ok

          {:error, reason} ->
            Process.put({__MODULE__, :response_error}, reason)
            :halt
        end

      _ ->
        body = Process.get({__MODULE__, :body}, "")

        if byte_size(body) + byte_size(chunk) <= @maximum_body do
          Process.put({__MODULE__, :body}, body <> chunk)
          :ok
        else
          Process.put({__MODULE__, :response_error}, :too_large)
          :halt
        end
    end
  end

  defp consume(_), do: :ok

  # @cc [owner:ghuntley,label:security;recovery] agent-terminal-response-only
  # Complete Responses output may include opaque compaction items. Ziggy MUST
  # retain those maps without interpreting checkpoint authority. HTTP and SSE
  # failures MUST deliver only a closed reason, never a raw error document.
  @spec provider_response(Ziggy.Upstream.result(), binary(), Ziggy.AgentStream.t() | nil) :: map()
  defp provider_response(result, body, stream) do
    case Process.get({__MODULE__, :response_error}) do
      nil -> terminal_response(result, body, stream)
      _ -> %{"error" => "invalid_response"}
    end
  end

  @spec terminal_response(Ziggy.Upstream.result(), binary(), Ziggy.AgentStream.t() | nil) :: map()
  defp terminal_response(%{outcome: :cancelled}, _, _), do: %{"error" => "cancelled"}

  # @cc [owner:ghuntley,label:recovery] completed-response-survives-transport-close
  # A provider transport close after a valid terminal response MUST preserve that
  # response. Incomplete streams still fail closed through `AgentStream.finish/1`.
  defp terminal_response(%{outcome: outcome}, _, _)
       when outcome not in [:completed, :upstream_error, :transport_error],
       do: %{"error" => "upstream_failed"}

  defp terminal_response(%{status: status}, _, %Ziggy.AgentStream{} = stream) do
    case Ziggy.AgentStream.finish(stream) do
      {:ok, response} when status in 200..299 -> response
      {:ok, _} -> %{"error" => "upstream_failed"}
      {:error, :too_large} -> %{"error" => "invalid_response"}
      {:error, reason} -> %{"error" => Atom.to_string(reason)}
    end
  end

  defp terminal_response(%{status: status}, body, nil) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, response} when is_map(response) and status in 200..299 ->
        case Ziggy.AgentError.terminal(response) do
          nil -> response
          reason -> %{"error" => Atom.to_string(reason)}
        end

      {:ok, response} ->
        %{"error" => response |> Ziggy.AgentError.classify() |> Atom.to_string()}

      _ ->
        %{"error" => if(status in 200..299, do: "invalid_response", else: "upstream_failed")}
    end
  end

  @spec accounting_outcome(atom(), map()) :: atom()
  defp accounting_outcome(:completed, %{"error" => "cancelled"}), do: :cancelled

  defp accounting_outcome(:completed, %{"error" => error}) when is_binary(error),
    do: :upstream_error

  defp accounting_outcome(outcome, _), do: outcome

  # Delivery retries reuse the claim and the exact provider response. They
  # cannot issue a second model request or consume another accounting slot.
  defp deliver_result(config, id, claim_id, response, attempts) do
    case Ziggy.Control.request(config.control, "agent_result", %{
           "call_id" => id,
           "claim_id" => claim_id,
           "response" => response
         }) do
      {:ok, %{"acknowledged" => ^id}} ->
        :ok

      _ when attempts > 1 ->
        Process.sleep(500)
        deliver_result(config, id, claim_id, response, attempts - 1)

      _ ->
        :error
    end
  end

  defp claim_once(state) do
    case claim(state) do
      {next, :refused} -> {:noreply, schedule(next, :refused)}
      {next, :accepted} -> {:noreply, %{next | fence: Ziggy.VersionFence.accepted(next.fence)}}
      {next, :inconclusive} -> {:noreply, next}
    end
  end

  # One poll; a refusal fences, an accepted reply clears the fence, and a
  # transient failure keeps any fence (probing again at the same backoff).
  defp poll(state) do
    {next, outcome} = claim(state)
    {:noreply, schedule(next, outcome)}
  end

  defp claim(state) do
    if map_size(state.active) < @maximum_active do
      case state.request.(state.config.control, "agent_next", %{}) do
        {:error, :unsupported_version} ->
          {state, :refused}

        {:ok, %{"call" => nil}} ->
          {state, :accepted}

        {:ok, %{"call" => call}} when is_map(call) ->
          task =
            Task.Supervisor.async_nolink(Ziggy.Tasks, fn -> execute(state.config, call) end)

          {%{state | active: Map.put(state.active, task.ref, Map.get(call, "id"))}, :accepted}

        _ ->
          {state, :inconclusive}
      end
    else
      {state, :inconclusive}
    end
  end

  defp schedule(state, :refused) do
    {fence, delay, token} = Ziggy.VersionFence.refused(state.fence)
    Process.send_after(self(), {:probe, token}, delay)
    %{state | fence: fence}
  end

  defp schedule(state, :accepted) do
    Process.send_after(self(), :poll, @poll_ms)
    %{state | fence: Ziggy.VersionFence.accepted(state.fence)}
  end

  defp schedule(%{fence: fence} = state, :inconclusive) do
    if Ziggy.VersionFence.fenced?(fence) do
      Process.send_after(self(), {:probe, fence.token}, fence.backoff)
      state
    else
      Process.send_after(self(), :poll, @poll_ms)
      state
    end
  end
end
