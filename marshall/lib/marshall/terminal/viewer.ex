defmodule Marshall.Terminal.Viewer do
  @moduledoc "WebSock handler for one browser or SSH-gateway terminal viewer: one stream channel per attachment."
  @behaviour WebSock

  require Marshall.Events
  alias OverallsProtocol.TerminalWindow, as: Window
  alias Marshall.Terminal.ViewerAuthority
  @authority_interval 5000
  @heartbeat_ms 5_000
  @type refusal_reason ::
          :authority
          | :authority_unconfirmed
          | :authority_login
          | :authority_session
          | :authority_host
          | :authority_writer
          | :authority_credential
          | :input_window
          | :output_window
          | :input_ack
          | :output_ack
          | :slow_viewer

  # Gateway and attach refusals that close before an attachment exists; each
  # is reported as `terminal.viewer_refused` so operators can see why.
  @type attach_refusal ::
          :gateway_session
          | :gateway_unavailable
          | :gateway_ticket
          | :stream_unavailable
          | :attach_timeout
          | :attach_refused

  # @cc [owner:ghuntley,label:security] viewer-ticket-and-cedar-authority
  # init/1 MUST consume a single-use ticket, load its registry session, and
  # recheck Cedar read (ro) or write (rw) permission on the VM before any
  # attach is issued; failures close the socket without details. Terminal
  # bytes MUST never be logged or stored.
  @impl true
  def init(%{ticket: ticket, actor: actor, cursor: cursor, login_jti: login_jti} = options) do
    Logger.metadata(marshall_terminal: true)

    with {:ok, _expiry} <- Marshall.Accounts.Login.present(login_jti, actor.id),
         {:ok, claim} <- Marshall.Terminal.Tickets.consume(ticket),
         true <- claim.ssh_session_id == nil || {:error, :unauthorized},
         {:ok, session} <- claimed_session(claim, actor) do
      attach(session, claim, actor, cursor, options, %{
        origin: :browser,
        authority: {:login, login_jti}
      })
    else
      {:error, _reason} -> {:stop, :unauthorized, %{}}
    end
  end

  # @cc [owner:ghuntley,label:security] viewer-ssh-gateway-authority
  # A gateway stream (ADR-0223) MUST authenticate the enabled gateway and a
  # live, approved SSH session before consuming the ticket, and the ticket MUST
  # name that same SSH session and account. Browser tickets never open a
  # gateway stream and SSH tickets never open a browser viewer. Refusals close
  # with only a closed TerminalAttach code: 4001 authority, 4003 refused.
  def init(%{ticket: ticket, authority: {:ssh, gateway, token}, cursor: cursor} = options)
      when is_binary(gateway) and is_binary(token) do
    Logger.metadata(marshall_terminal: true)

    case Marshall.SSH.Authority.session_actor(gateway, token) do
      {:ok, %{user: actor, ssh_session_id: ssh_session_id}} ->
        with {:ok, claim} <- Marshall.Terminal.Tickets.consume(ticket),
             true <- claim.ssh_session_id == ssh_session_id || {:error, :unauthorized},
             {:ok, session} <- claimed_session(claim, actor) do
          attach(session, claim, actor, cursor, options, %{
            origin: :ssh,
            authority: {:ssh, gateway, token},
            ssh_session_id: ssh_session_id
          })
        else
          {:error, _reason} -> gateway_refused(:gateway_ticket, :refused)
        end

      {:error, :authority_credential} ->
        gateway_refused(:gateway_session, :authority)

      {:error, :unavailable} ->
        gateway_refused(:gateway_unavailable, :transport)
    end
  end

  def init(_options), do: {:stop, :unauthorized, %{}}

  @spec attach(map(), Marshall.Terminal.Tickets.claim(), map(), non_neg_integer(), map(), map()) ::
          WebSock.handle_result()
  defp attach(session, claim, actor, cursor, options, origin) do
    with {:ok, host_id} <- Marshall.Terminal.Authority.host_for(session),
         {:ok, stream} <- Marshall.Terminal.Relay.stream_for(host_id) do
      mode = attach_mode(claim.mode, session, actor)

      state =
        Map.merge(origin, %{
          stream: stream,
          session: session,
          actor: actor,
          mode: mode,
          channel: nil,
          cursor: cursor,
          unconfirmed_since: nil,
          input_window: Window.new(),
          output_window: Window.new()
        })

      request = %{
        ref: make_ref(),
        caller: self(),
        terminal_session_id: session.id,
        message: %{
          type: :attach,
          cols: if(mode == :rw, do: Map.get(options, :cols, 0), else: 0),
          rows: if(mode == :rw, do: Map.get(options, :rows, 0), else: 0),
          vm_id: session.vm_id,
          placement_id: session.placement_id,
          execution_epoch: session.execution_epoch,
          guest_session_id: session.guest_session_id,
          mode: mode,
          cursor: cursor
        }
      }

      send(stream, {:viewer_attach, request})

      receive do
        {:terminal_attached, message} ->
          state = %{state | channel: message.channel}

          case Marshall.Terminal.Authority.record_viewer_event(session, actor, :attached) do
            :ok ->
              Process.send_after(self(), :check_authority, @authority_interval)
              Process.send_after(self(), :heartbeat, @heartbeat_ms)
              # Revocation hints trigger an immediate recheck (ADR-0140); the
              # five-second poll remains the backstop for a lost hint.
              Marshall.Control.Hints.subscribe(:user, actor.id)
              Marshall.Control.Hints.subscribe(:vm, session.vm_id)

              if state.origin == :ssh,
                do: Marshall.Control.Hints.subscribe(:ssh_session, state.ssh_session_id)

              Marshall.Control.Hints.subscribe_resync()

              Marshall.Events.emit("terminal.attached",
                vm_id: session.vm_id,
                session_id: session.id,
                actor_id: actor.id,
                origin: state.origin
              )

              Marshall.Terminal.Metrics.opened(:viewer)
              {:push, {:text, attach_info(message, state)}, state}

            {:error, _reason} ->
              send(stream, {:viewer_gone, message.channel})
              stop(:audit_unavailable, :transport, state)
          end

        {:relay_reply, _ref, {:error, reason}} ->
          _ = Marshall.Terminal.Authority.record_viewer_event(session, actor, :denied)
          attach_refused(:attach_refused)
          stop(reason, :refused, state)
      after
        5000 ->
          _ = Marshall.Terminal.Authority.record_viewer_event(session, actor, :denied)
          attach_refused(:attach_timeout)
          stop(:attach_timeout, :transport, state)
      end
    else
      {:error, _reason} ->
        attach_refused(:stream_unavailable)
        if origin.origin == :ssh, do: stop_ssh(:refused), else: {:stop, :unauthorized, %{}}
    end
  end

  @spec attach_refused(attach_refusal()) :: :ok
  defp attach_refused(reason) do
    Marshall.Events.emit("terminal.viewer_refused", reason: reason)
    :ok
  end

  @spec gateway_refused(attach_refusal(), OverallsProtocol.TerminalAttach.outcome()) ::
          WebSock.handle_result()
  defp gateway_refused(reason, outcome) do
    attach_refused(reason)
    stop_ssh(outcome)
  end

  # Browser viewers keep their historical close behaviour; a gateway stream
  # closes with the closed TerminalAttach code for its outcome.
  @spec stop(term(), OverallsProtocol.TerminalAttach.outcome(), map()) :: WebSock.handle_result()
  defp stop(reason, outcome, %{origin: :ssh} = state),
    do: {:stop, reason, OverallsProtocol.TerminalAttach.close_code(outcome), state}

  defp stop(reason, _outcome, state), do: {:stop, reason, state}

  @spec stop_ssh(OverallsProtocol.TerminalAttach.outcome()) :: WebSock.handle_result()
  defp stop_ssh(outcome),
    do: {:stop, :normal, OverallsProtocol.TerminalAttach.close_code(outcome), %{}}

  @impl true
  def handle_in({_bytes, [opcode: :binary]}, %{mode: :ro} = state), do: {:ok, state}

  def handle_in({bytes, [opcode: :binary]}, %{channel: channel} = state)
      when is_integer(channel) and channel > 0 do
    case authority(state) do
      {:ok, state} ->
        case Window.take(state.input_window, byte_size(bytes)) do
          {:ok, window} ->
            send(state.stream, {:viewer_input, channel, bytes})

            Overalls.Diagnostics.Metrics.record(
              [:marshall, :terminal, :input],
              %{duration: 0},
              %{}
            )

            {:ok, %{state | input_window: window}}

          _ ->
            refuse(:input_window, state)
        end

      {:error, reason, state} ->
        refuse(reason, state)
    end
  end

  def handle_in({text, [opcode: :text]}, state) when byte_size(text) <= 512 do
    case authority(state) do
      {:ok, state} -> control(text, state)
      {:error, reason, state} -> refuse(reason, state)
    end
  end

  def handle_in({_bytes, _opcode}, state), do: {:ok, state}

  defp control(text, state) do
    case JSON.decode(text) do
      {:ok, %{"op" => "output_ack", "frames" => frames, "bytes" => bytes} = message}
      when map_size(message) == 3 ->
        case Window.acknowledge(state.output_window, frames, bytes) do
          {:ok, window} ->
            send(state.stream, {:viewer_output_ack, state.channel, frames, bytes})
            {:ok, %{state | output_window: window}}

          _ ->
            refuse(:output_ack, state)
        end

      _ ->
        if state.mode == :rw, do: resize(text, state), else: {:ok, state}
    end
  end

  defp resize(text, state) do
    case JSON.decode(text) do
      {:ok, %{"op" => "resize", "cols" => cols, "rows" => rows}}
      when is_integer(cols) and cols in 1..4096 and is_integer(rows) and rows in 1..512 ->
        message = resize_message(state, cols, rows)

        if message do
          send(state.stream, {:viewer_resize, message})
          {:ok, state}
        else
          {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  defp attach_info(message, state) do
    JSON.encode!(%{
      "op" => "attached",
      "replay_bytes" => message.replay_bytes,
      "channel" => message.channel,
      "guest_session_id" => message.guest_session_id,
      "from" => message.from,
      "mode" => Atom.to_string(state.mode)
    })
  end

  @impl true
  def handle_info({:terminal_output, bytes}, state) do
    case Window.take(state.output_window, byte_size(bytes)) do
      {:ok, window} -> {:reply, :ok, {:binary, bytes}, %{state | output_window: window}}
      _ -> refuse(:output_window, state)
    end
  end

  def handle_info({:terminal_input_ack, frames, bytes}, state) do
    case Window.acknowledge(state.input_window, frames, bytes) do
      {:ok, window} ->
        {:reply, :ok, {:text, JSON.encode!(%{op: "input_ack", frames: frames, bytes: bytes})},
         %{state | input_window: window}}

      _ ->
        refuse(:input_ack, state)
    end
  end

  def handle_info({:terminal_closed, _message}, state), do: stop(:normal, :closed, state)

  def handle_info(:terminal_slow_viewer, state), do: refuse(:slow_viewer, state)

  # @cc [owner:ghuntley,label:recovery] viewer-socket-liveness
  # An attached viewer MUST send a heartbeat control frame every five seconds,
  # so a browser whose Marshall died behind a half-open proxy connection sees
  # fifteen seconds of silence and reconnects to a surviving node. The frame
  # carries no terminal data and does not consume output credit.
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:push, {:text, ~s({"op":"heartbeat"})}, state}
  end

  def handle_info(:check_authority, state) do
    case authority(state) do
      {:ok, state} ->
        Process.send_after(self(), :check_authority, @authority_interval)
        {:ok, state}

      {:error, reason, state} ->
        refuse(reason, state)
    end
  end

  def handle_info(message, state)
      when (is_tuple(message) and elem(message, 0) == :control_hint) or
             message == :control_resync do
    case authority(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason, state} -> refuse(reason, state)
    end
  end

  def handle_info(_, state), do: {:ok, state}

  # @cc [owner:ghuntley,label:security] viewer-refusal-diagnostics
  # Refusal diagnostics MUST contain only a closed reason atom. Terminal bytes,
  # control text, tickets and viewer state MUST NOT enter event metadata.
  @spec refuse(refusal_reason(), map()) ::
          {:stop, :normal | :slow_viewer, map()}
          | {:stop, :normal | :slow_viewer, 1000..4999, map()}
  defp refuse(reason, state)
       when reason in [
              :authority,
              :authority_unconfirmed,
              :authority_login,
              :authority_session,
              :authority_host,
              :authority_writer,
              :authority_credential,
              :input_window,
              :output_window,
              :input_ack,
              :output_ack,
              :slow_viewer
            ] do
    Marshall.Events.emit("terminal.viewer_refused", reason: reason)
    stop(if(reason == :slow_viewer, do: :slow_viewer, else: :normal), outcome(reason), state)
  end

  # A gateway client maps these closes to its exit status (TerminalAttach).
  @spec outcome(refusal_reason()) :: OverallsProtocol.TerminalAttach.outcome()
  defp outcome(reason)
       when reason in [
              :authority,
              :authority_login,
              :authority_session,
              :authority_writer,
              :authority_credential
            ],
       do: :authority

  defp outcome(reason) when reason in [:authority_host, :authority_unconfirmed, :slow_viewer],
    do: :transport

  defp outcome(_reason), do: :invalid

  @impl true
  def terminate(_reason, %{channel: channel, stream: stream, session: session, actor: actor})
      when is_integer(channel) do
    send(stream, {:viewer_gone, channel})
    _ = Marshall.Terminal.Authority.record_viewer_event(session, actor, :detached)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp claimed_session(claim, actor) do
    case Ash.get(Marshall.Terminal.Session, claim.session_id,
           actor: Marshall.Authorization.SystemActor.compute()
         ) do
      {:ok, %Marshall.Terminal.Session{} = session} when claim.actor_id == actor.id ->
        case Marshall.Terminal.Authority.session_for(claim.session_id, actor) do
          {:ok, authorized} ->
            {:ok, authorized}

          {:error, _reason} = error ->
            _ = Marshall.Terminal.Authority.record_viewer_event(session, actor, :denied)
            error
        end

      {:ok, %Marshall.Terminal.Session{} = session} ->
        _ = Marshall.Terminal.Authority.record_viewer_event(session, actor, :denied)
        {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] viewer-revocation-is-live
  # Input and resize MUST recheck persisted login and session/Cedar authority;
  # user and VM control hints MUST trigger an immediate recheck, and idle or
  # output-only viewers MUST also recheck every five seconds as the backstop
  # for a lost hint (ADR-0142). A failed recheck
  # while the database answers closes the viewer at once; a cached writable mode
  # MUST NOT survive permission revocation. Only when the database itself is
  # unreachable is the recheck inconclusive (ADR-0140): the last confirmed
  # authority then survives for at most ViewerAuthority.backstop_ms/0, then the
  # viewer closes as :authority_unconfirmed.
  @spec authority(map()) :: {:ok, map()} | {:error, refusal_reason(), map()}
  defp authority(state) do
    started = System.monotonic_time()
    result = recheck(state)

    # @cc [owner:ghuntley,label:observability] viewer-authority-latency
    # Every recheck MUST report only its duration and a closed status class to
    # the aggregate metrics; terminal bytes, tickets and identities never do.
    Overalls.Diagnostics.Metrics.record(
      [:marshall, :terminal, :authority],
      %{duration: System.monotonic_time() - started},
      %{status: if(result == :ok, do: 200, else: 503)}
    )

    since = Map.get(state, :unconfirmed_since)

    if result == :inconclusive and since == nil,
      do: Marshall.Events.emit("terminal.viewer_authority_inconclusive", [])

    case ViewerAuthority.step(
           since,
           result,
           System.monotonic_time(:millisecond)
         ) do
      {:ok, nil} when since == nil -> {:ok, state}
      {:ok, next} -> {:ok, Map.put(state, :unconfirmed_since, next)}
      {:refuse, reason} -> {:error, reason, state}
    end
  end

  # An unanswered lookup is inconclusive; a refusal additionally only counts
  # while the database demonstrably answers.
  @spec recheck(map()) :: ViewerAuthority.result()
  defp recheck(%{authority: _, actor: _, session: _, mode: _} = state) do
    case fresh_authority(state) do
      :ok ->
        :ok

      :inconclusive ->
        :inconclusive

      {:error, reason} ->
        if Marshall.Repo.answers?(), do: {:error, reason}, else: :inconclusive
    end
  rescue
    # A crashed lookup is not a refusal; the backstop still bounds it.
    _ -> :inconclusive
  end

  defp recheck(_state), do: {:error, :authority}

  @spec fresh_authority(map()) :: :ok | :inconclusive | {:error, refusal_reason()}
  defp fresh_authority(%{authority: authority, actor: actor, session: session, mode: mode}) do
    with {:login, {:ok, _expiry}} <- {:login, credential(authority, actor)},
         {:session, {:ok, current}} <-
           {:session, Marshall.Terminal.Authority.session_for(session.id, actor)},
         {:writer, true} <- {:writer, mode != :rw or attach_mode(:rw, current, actor) == :rw} do
      :ok
    else
      {:login, :unavailable} -> :inconclusive
      {:session, {:error, :unavailable}} -> :inconclusive
      {:login, {:error, :authority_credential}} -> {:error, :authority_credential}
      {:login, _} -> {:error, :authority_login}
      {:session, {:error, :terminal_unavailable}} -> {:error, :authority_host}
      {:session, _} -> {:error, :authority_session}
      {:writer, _} -> {:error, :authority_writer}
    end
  end

  # The browser login, or the gateway-bound SSH session, behind the viewer.
  @spec credential({:login, String.t()} | {:ssh, binary(), binary()}, map()) ::
          {:ok, term()} | :unavailable | {:error, :authority_credential} | term()
  defp credential({:login, jti}, actor), do: Marshall.Accounts.Login.check(jti, actor.id)

  defp credential({:ssh, gateway, token}, _actor) do
    case Marshall.SSH.Authority.session_live?(gateway, token) do
      true -> {:ok, :live}
      false -> {:error, :authority_credential}
      :unavailable -> :unavailable
    end
  end

  defp attach_mode(:rw, session, actor) do
    if session.owner_id == actor.id and
         Marshall.Terminal.Authority.writable?(session.vm_id, actor) do
      :rw
    else
      :ro
    end
  end

  defp attach_mode(:ro, _session, _actor), do: :ro

  defp resize_message(state, cols, rows) do
    if state.channel do
      %{
        type: :resize,
        vm_id: state.session.vm_id,
        placement_id: state.session.placement_id,
        execution_epoch: state.session.execution_epoch,
        guest_session_id: state.session.guest_session_id,
        cols: cols,
        rows: rows
      }
    end
  end
end
