defmodule Marshall.Terminal.Authority do
  @moduledoc "Terminal session authorization: capability gate, registry lifecycle and stream control."

  alias Marshall.{Access, Compute, Terminal}
  alias Marshall.Compute.{Host, Ledger}
  alias Marshall.Terminal.{Creation, Termination}
  @type access_mode :: :connect | :observe

  # @cc [owner:ghuntley,label:security;recovery] terminal-wake-before-guest-access
  # Wake admission MUST recheck Cedar and the image capability under the VM
  # lock. Pending wake MUST NOT issue guest controls or tickets. A stopped VM
  # still requires explicit start. A new connection MUST join existing demand;
  # server-side observation MUST NOT create demand or refresh the idle clock.
  @spec ensure_awake(map(), map(), String.t(), access_mode()) ::
          {:ok, Compute.VirtualMachine.t()} | {:error, atom()}
  def ensure_awake(vm, actor, action \\ "read", mode \\ :connect)
      when mode in [:connect, :observe] do
    case Ledger.transaction(
           fn ->
             current =
               Ledger.lock!(Compute.VirtualMachine, vm.id) || Ledger.rollback(:unknown_session)

             unless Access.Authorization.allowed?(current, actor, action),
               do: Ledger.rollback(:forbidden)

             unless Compute.Images.guest_capabilities(current.image_id).terminal,
               do: Ledger.rollback(:terminal_unavailable)

             cond do
               Compute.Wake.ready?(current) ->
                 current

               mode == :observe ->
                 Ledger.rollback(:terminal_unavailable)

               current.desired_state == :paused or current.observed_state == :paused ->
                 Compute.Wake.request_locked!(current, :network, actor)
                 :pending

               current.desired_state == :running and current.observed_state == :running ->
                 :pending

               true ->
                 Ledger.rollback(:terminal_unavailable)
             end
           end,
           actor
         ) do
      {:ok, :pending} -> {:error, :terminal_open_pending}
      {:ok, current} -> {:ok, current}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :terminal_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] personal-terminal-account
  # Browser creates MUST use the current actor's durable GuestAccounts identity
  # and fresh Cedar write permission, never a client-selected guest username.
  # Automatic creates MUST use one stable request per actor/account/VM execution;
  # retries and reloads MUST NOT replace a closed shell or duplicate a live shell.
  # Server-side automatic creates MUST observe readiness without creating wake
  # demand if the machine pauses between listing and the supervised opening.
  @spec open_personal_session(
          map(),
          Marshall.Accounts.User.t(),
          :default | String.t(),
          access_mode()
        ) ::
          {:ok, Terminal.Session.t()} | {:error, atom()}
  def open_personal_session(vm, actor, request_id \\ :default, mode \\ :connect) do
    catch_capabilities(fn ->
      with {:ok, {current, account}} <-
             Ledger.transaction(
               fn ->
                 current =
                   Ledger.lock!(Compute.VirtualMachine, vm.id) ||
                     Ledger.rollback(:unknown_session)

                 unless Access.Authorization.allowed?(current, actor, "write"),
                   do: Ledger.rollback(:forbidden)

                 {current, Marshall.Accounts.GuestAccounts.ensure!(actor.id)}
               end,
               actor
             ) do
        request_id =
          if request_id == :default,
            do: default_request(current, actor, account),
            else: request_id

        open_on_vm(current, actor, account.username, "xterm-256color", request_id, "write", mode)
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :guest_account_unavailable}
      end
    end)
  rescue
    _ -> {:error, :guest_account_unavailable}
  end

  defp default_request(vm, actor, account) do
    # A namespaced deterministic UUIDv8, containing no user-controlled parameters.
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
      :crypto.hash(
        :sha256,
        JSON.encode!([
          "personal-terminal-v1",
          actor.id,
          account.id,
          vm.id,
          vm.current_placement_id,
          vm.execution_epoch,
          vm.generation
        ])
      )

    {:ok, id} = Ecto.UUID.load(<<a::48, 8::4, b::12, 2::2, c::62>>)
    id
  end

  # @cc [owner:ghuntley,label:security] terminal-open-requires-capability-and-cedar
  # open_session/4 and /5 MUST verify Cedar read on the VM, a fresh host report
  # advertising terminal protocol 2, and Cedar write for rw sessions; every
  # open MUST persist the registry row and an audit event in one transaction.
  @spec open_session(
          Compute.VirtualMachine.t() | %{required(:id) => String.t()},
          map(),
          String.t(),
          String.t()
        ) ::
          {:ok, Terminal.Session.t()} | {:error, atom()}
  @spec open_session(
          Compute.VirtualMachine.t() | %{required(:id) => String.t()},
          map(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, Terminal.Session.t()} | {:error, atom()}
  def open_session(vm, actor, guest_user, term, request_id \\ Ash.UUID.generate()) do
    catch_capabilities(fn ->
      with {:ok, vm} <- live_vm(vm.id, actor, "read") do
        open_on_vm(vm, actor, guest_user, term, request_id, "read")
      end
    end)
  end

  defp open_on_vm(vm, actor, guest_user, term, request_id, action, mode \\ :connect) do
    with {:ok, vm} <- ensure_awake(vm, actor, action, mode),
         {:ok, host} <- capability(vm),
         :ok <- authorize(vm, actor, action),
         {:ok, writable} <- authorized_mode(vm, actor),
         true <- OverallsProtocol.uuid?(request_id) || {:error, :invalid_terminal_request},
         :ok <- creation_supported(vm, host, request_id),
         {:ok, _sessions} <- list_sessions(vm, actor, mode),
         {:ok, opening} <- Creation.reserve(vm, actor, guest_user, term, request_id) do
      if opening.status == :ready do
        session_for(opening.session_id, actor)
      else
        case create_on_stream(vm, host, guest_user, term, writable, opening.id) do
          {:ok, guest_session_id} ->
            case Creation.complete(opening.id, guest_session_id) do
              {:ok, session} -> {:ok, session}
              _ -> {:error, :terminal_open_pending}
            end

          {:error, reason} when reason in [:rejected, :limit] ->
            with {:ok, _} <- Creation.begin_cancel(opening.id),
                 {:ok, %{type: :creation_cancelled, ok: true}} <-
                   stream_control(host.id, %{
                     type: :creation_cancel,
                     request_id: opening.id,
                     vm_id: vm.id,
                     placement_id: opening.placement_id,
                     execution_epoch: opening.execution_epoch
                   }),
                 do: Creation.cancelled(opening.id)

            {:error, reason}

          _ ->
            {:error, :terminal_open_pending}
        end
      end
    end
  end

  defp catch_capabilities(fun) do
    try do
      fun.()
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  # @cc [owner:ghuntley,label:security] terminal-kill-requires-owner-write
  # close_session/2 MUST require the registry owner and current Cedar write
  # authority. A read-only viewer MUST NOT kill another user's guest session.
  # Pending kill intent MUST commit before dispatch. Registry closure and its
  # killed receipt MUST commit atomically only after guest acknowledgement or
  # authoritative absence; transport failure MUST retain recoverable intent.
  @spec close_session(Terminal.Session.t(), map()) :: :ok | {:error, atom()}
  def close_session(session, actor) do
    with {:ok, vm} <- live_vm(session.vm_id, actor, "write"),
         true <- current_session?(session, vm) || {:error, :unknown_session},
         true <- session.owner_id == actor.id || denied(session, actor, vm),
         {:ok, pending} <- Termination.request(session, actor) do
      Termination.dispatch(pending)
    else
      {:error, :forbidden} = error ->
        _ = record_event_for_session(session, actor, :denied)
        error

      other ->
        other
    end
  end

  @spec record_viewer_event(Terminal.Session.t(), map(), :attached | :detached | :denied) ::
          :ok | {:error, term()}
  def record_viewer_event(session, actor, kind) when kind in [:attached, :detached, :denied],
    do: record_event_for_session(session, actor, kind)

  # @cc [owner:ghuntley,label:recovery] authoritative-listing-retires-exited-sessions
  # Only a successful guest listing may retire absent registry sessions. Snapshot
  # registry candidates before requesting the listing, so concurrently created
  # sessions cannot be mistaken for exited sessions. Archive and closed receipt
  # MUST commit together, once, with the observing actor identified.
  @spec list_sessions(Compute.VirtualMachine.t(), map(), access_mode()) ::
          {:ok, [map()]} | {:error, atom()}
  def list_sessions(vm, actor, mode \\ :connect) do
    with {:ok, vm} <- live_vm(vm.id, actor, "read"),
         {:ok, vm} <- ensure_awake(vm, actor, "read", mode),
         {:ok, host} <- capability(vm),
         {:ok, registry_sessions} <-
           Terminal.list_for_vm(vm.id, actor: Marshall.Authorization.SystemActor.compute()),
         {:ok, %{type: :listed, sessions: sessions}} <-
           stream_control(host.id, listing_message(vm)) do
      sessions =
        sessions |> Enum.filter(& &1.alive) |> Enum.sort_by(&{&1.created_ms, &1.guest_session_id})

      live_ids = MapSet.new(sessions, & &1.guest_session_id)

      Enum.each(registry_sessions, fn session ->
        if not current_session?(session, vm) or
             not MapSet.member?(live_ids, session.guest_session_id) do
          :ok = Termination.observe_absent(session, not current_session?(session, vm), actor.id)
        end
      end)

      registry =
        registry_sessions
        |> Enum.filter(&current_session?(&1, vm))
        |> Marshall.Terminal.Sharing.usable(actor)
        |> Map.new(&{&1.guest_session_id, &1})

      {:ok,
       Enum.flat_map(sessions, fn guest ->
         case registry[guest.guest_session_id] do
           nil -> []
           session -> [Map.merge(Map.from_struct(session), guest)]
         end
       end)}
    end
  end

  @spec boot_log(Compute.VirtualMachine.t(), map(), non_neg_integer()) ::
          {:ok, %{next: non_neg_integer(), bytes: binary()}} | {:error, atom()}
  # @cc [owner:ghuntley,label:security;recovery] boot-log-is-host-diagnostic
  # Boot-log reads MUST recheck Cedar read authority and the current host's
  # authenticated protocol-2 stream and liveness, independently of guest agent
  # capabilities or readiness. Controls MUST retain the current placement and
  # execution epoch; this read MUST NOT authorize guest terminal operations.
  def boot_log(vm, actor, cursor) do
    with {:ok, vm} <- live_vm(vm.id, actor, "read"),
         {:ok, host} <- host_stream_capability(vm),
         {:ok, %{type: :boot_log_data, next: next, bytes: bytes}} <-
           stream_control(host.id, boot_log_message(vm, cursor)) do
      {:ok, %{next: next, bytes: bytes}}
    end
  end

  @spec users(Compute.VirtualMachine.t(), Marshall.Accounts.User.t()) ::
          {:ok, [String.t()]} | {:error, atom()}
  def users(vm, actor) do
    catch_capabilities(fn ->
      with {:ok, vm} <- live_vm(vm.id, actor, "read"),
           {:ok, vm} <- ensure_awake(vm, actor),
           {:ok, host} <- capability(vm),
           {:ok, %{type: :users_listed, users: users}} <-
             stream_control(host.id, %{
               type: :users,
               vm_id: vm.id,
               placement_id: vm.current_placement_id,
               execution_epoch: vm.execution_epoch
             }) do
        {:ok, users}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] terminal-observation-has-no-wake-effects
  # Periodic viewer checks MUST use passive observation. Only explicit attach
  # admission may wake a suspended session; pending readiness grants no ticket.
  @spec session_for(String.t(), map(), access_mode()) ::
          {:ok, Terminal.Session.t()} | {:error, atom()}
  def session_for(session_id, actor, mode \\ :observe) do
    case Ash.get(Terminal.Session, session_id,
           actor: Marshall.Authorization.SystemActor.compute()
         ) do
      {:ok, %Terminal.Session{} = session} ->
        with {:ok, vm} <- live_vm(session.vm_id, actor, "read"),
             true <- Marshall.Terminal.Sharing.allowed?(session, actor) || {:error, :forbidden},
             {:ok, vm} <- ensure_awake(vm, actor, "read", mode),
             true <-
               (current_session?(session, vm) and session.kill_status == :idle) ||
                 {:error, :unknown_session},
             {:ok, _host} <- capability(vm) do
          {:ok, session}
        end

      {:error, error} ->
        if not_found?(error), do: {:error, :unknown_session}, else: {:error, :unavailable}

      _ ->
        {:error, :unknown_session}
    end
  end

  # A missing row is a definite answer; any other lookup failure is not
  # evidence the session is gone (ADR-0140).
  @spec not_found?(term()) :: boolean()
  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  defp not_found?(_), do: false

  @spec host_for(Terminal.Session.t()) :: {:ok, String.t()} | {:error, atom()}
  def host_for(session) do
    case Ledger.read!(Compute.VirtualMachine, id: session.vm_id) do
      [vm] ->
        with true <- current_session?(session, vm) || {:error, :unknown_session},
             true <- Compute.Wake.ready?(vm) || {:error, :terminal_unavailable},
             {:ok, host} <- capability(vm),
             true <- Marshall.Terminal.Relay.ready?(host.id) || {:error, :terminal_unavailable} do
          {:ok, host.id}
        end

      _ ->
        {:error, :unknown_session}
    end
  end

  defp host_of(vm) do
    case Ledger.read!(Compute.WorkloadPlacement, id: vm.current_placement_id) do
      [placement] -> placement.host_id
      _ -> throw({:error, :terminal_unavailable})
    end
  end

  @spec writable?(String.t(), map()) :: boolean()
  def writable?(vm_id, actor) do
    case fetch_vm(vm_id) do
      {:ok, vm} -> Access.Authorization.allowed?(vm, actor, "write")
      {:error, _reason} -> false
    end
  end

  @type ticket_option :: {:read_only, boolean()} | {:ssh_session_id, String.t()}

  # @cc [owner:ghuntley,label:security] terminal-ticket-mode-never-escalates
  # A ticket is writable only for the owner with current Cedar write and no
  # read-only request; `read_only: true` always yields a read-only ticket. An
  # SSH ticket (ADR-0223) is additionally bound to the issuing SSH session.
  @spec ticket(Terminal.Session.t(), map(), [ticket_option()]) ::
          {:ok, String.t()} | {:error, atom()}
  def ticket(session, actor, options \\ []) do
    with {:ok, session} <- session_for(session.id, actor, :connect),
         {:ok, vm} <- live_vm(session.vm_id, actor, "read"),
         true <- current_session?(session, vm) || {:error, :unknown_session},
         {:ok, host} <- capability(vm),
         true <- Marshall.Terminal.Relay.ready?(host.id) || {:error, :terminal_unavailable},
         {:ok, writable} <- authorized_mode(vm, actor) do
      ssh_session_id = Keyword.get(options, :ssh_session_id)

      if session.owner_id == actor.id and writable and not Keyword.get(options, :read_only, false) do
        Marshall.Terminal.Tickets.issue(session.id, actor.id, :rw, ssh_session_id)
      else
        Marshall.Terminal.Tickets.issue(session.id, actor.id, :ro, ssh_session_id)
      end
    end
  end

  # @cc [owner:ghuntley,label:security] terminal-capability-requires-guest-agents
  # capability/1 MUST refuse terminal sessions, listings and tickets for a VM
  # whose catalog image's agent set lacks the terminal capability before
  # consulting host terminal protocol or liveness; the UI hiding is not authority.
  defp capability(vm) do
    with %{terminal: true} <- Compute.Images.guest_capabilities(vm.image_id) do
      host_stream_capability(vm)
    else
      _ -> {:error, :terminal_unavailable}
    end
  end

  defp host_stream_capability(vm) do
    with [host] when is_map(host.inventory) <- Ledger.read!(Host, id: host_of(vm)) do
      if host.inventory["terminal_protocol"] === 2 and
           Marshall.Compute.HostLiveness.authority?(
             host.connection_session_id,
             host.reported_at,
             Ledger.now()
           ) do
        {:ok, host}
      else
        {:error, :terminal_unavailable}
      end
    else
      _ -> {:error, :terminal_unavailable}
    end
  end

  defp live_vm(id, actor, action) do
    with {:ok, vm} <- fetch_vm(id),
         :ok <- authorize(vm, actor, action),
         true <- vm.desired_state != :deleted || {:error, :vm_deleted} do
      {:ok, vm}
    end
  end

  defp fetch_vm(id) do
    case Ledger.read!(Compute.VirtualMachine, id: id) do
      [vm] -> {:ok, vm}
      _ -> {:error, :unknown_session}
    end
  end

  defp authorize(vm, actor, action) do
    if Access.Authorization.allowed?(vm, actor, action), do: :ok, else: {:error, :forbidden}
  end

  defp authorized_mode(vm, actor),
    do: {:ok, Access.Authorization.allowed?(vm, actor, "write")}

  defp denied(_session, _actor, _vm), do: {:error, :forbidden}

  defp record_event_for_session(session, actor, kind) do
    record_event(%{id: session.vm_id}, actor, session.id, session.guest_session_id, kind)
  end

  # @cc [owner:ghuntley,label:recovery;protocol] guest-create-support-before-reservation
  # Creation MUST probe the authenticated guest's creation status before
  # reserving a new request or issuing a create. Only a running, exited or
  # unknown status admits creation; any other reply fails closed, and there is
  # no legacy create fallback.
  @spec creation_supported(Compute.VirtualMachine.t(), Host.t(), String.t()) ::
          :ok | {:error, atom()}
  defp creation_supported(vm, host, request_id) do
    message = %{
      type: :creation_query,
      request_id: request_id,
      vm_id: vm.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch
    }

    case stream_control(host.id, message) do
      {:ok, %{type: :creation_status, state: state}}
      when state in [:unknown, :running, :exited] ->
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :terminal_unavailable}
    end
  end

  defp create_on_stream(vm, host, guest_user, term, writable, request_id) do
    case stream_control(host.id, create_message(vm, guest_user, term, writable, request_id)) do
      {:ok, %{type: :created, ok: true, guest_session_id: guest_session_id}} ->
        {:ok, guest_session_id}

      {:ok, %{type: :created, ok: false, reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_event(vm, actor, session_id, guest_session_id, kind) do
    case Terminal.record(
           %{
             vm_id: vm.id,
             actor_id: actor.id,
             session_id: session_id,
             guest_session_id: guest_session_id,
             kind: kind,
             request_id: nil
           },
           actor: Marshall.Authorization.SystemActor.compute()
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_control(host_id, message) do
    with {:ok, stream} <- Marshall.Terminal.Relay.stream_for(host_id) do
      Marshall.Terminal.Relay.control(stream, message)
    end
  end

  defp create_message(vm, guest_user, term, writable, request_id) do
    %{
      type: :create,
      request_id: request_id,
      vm_id: vm.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      mode: if(writable, do: :rw, else: :ro),
      user: guest_user,
      term: term,
      cols: 80,
      rows: 24
    }
  end

  defp current_session?(session, vm) do
    session.placement_id == vm.current_placement_id and
      session.execution_epoch == vm.execution_epoch
  end

  defp listing_message(vm) do
    %{
      type: :listing,
      vm_id: vm.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch
    }
  end

  defp boot_log_message(vm, cursor) do
    %{
      type: :boot_log,
      vm_id: vm.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      cursor: cursor
    }
  end
end
