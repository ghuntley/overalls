defmodule Marshall.Terminal.Termination do
  @moduledoc "Durable owner-requested kill and atomic confirmation/registry receipts."
  alias Marshall.Terminal.{Authority, Relay, Session}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;recovery] kill-request-owner-and-commit
  # Kill requests MUST reload and lock current VM/session authority, require its
  # owner and Cedar write, then commit pending state and one request receipt
  # before dispatch. Retries MUST reuse that pending state without a new receipt.
  @spec request(Session.t(), Marshall.Accounts.User.t()) :: {:ok, Session.t()} | {:error, atom()}
  def request(session, actor) do
    transaction(
      fn ->
        vm = Ledger.lock!(VirtualMachine, session.vm_id) || Ledger.rollback(:unknown_session)
        current = lock_session(session.id) || Ledger.rollback(:unknown_session)
        same_binding!(session, current)

        unless current.owner_id == actor.id and current.vm_id == vm.id and
                 current.placement_id == vm.current_placement_id and
                 current.execution_epoch == vm.execution_epoch and
                 vm.desired_state != :deleted and
                 Marshall.Access.Authorization.allowed?(vm, actor, "write"),
               do: Ledger.rollback(:forbidden)

        case current.kill_status do
          :idle ->
            pending = Ledger.update!(current, :request_kill, %{})
            record!(pending, actor.id, :kill_requested)
            pending

          :pending ->
            current

          _ ->
            Ledger.rollback(:unknown_session)
        end
      end,
      actor
    )
  end

  @spec dispatch(Session.t()) :: :ok | {:error, :terminal_close_pending}
  def dispatch(%Session{kill_status: :pending} = session) do
    message = %{
      type: :kill,
      vm_id: session.vm_id,
      placement_id: session.placement_id,
      execution_epoch: session.execution_epoch,
      guest_session_id: session.guest_session_id
    }

    expected = message |> Map.put(:type, :killed) |> Map.put(:ok, true)

    with {:ok, host_id} <- Authority.host_for(session),
         {:ok, stream} <- Relay.stream_for(host_id),
         {:ok, ^expected} <- Relay.control(stream, message),
         :ok <- confirm(session) do
      :ok
    else
      _ -> {:error, :terminal_close_pending}
    end
  rescue
    _ -> {:error, :terminal_close_pending}
  catch
    :exit, _ -> {:error, :terminal_close_pending}
  end

  # @cc [owner:ghuntley,label:recovery] kill-confirmation-atomic-receipt
  # Confirmation MUST atomically transition pending intent, archive the registry
  # and append one killed receipt. Concurrent listing/acknowledgement retries
  # MUST NOT produce duplicate receipts or resurrect archived authority.
  @spec confirm(Session.t()) :: :ok | {:error, atom()}
  def confirm(session), do: finish(session, :confirm_kill, :killed, session.owner_id)

  @spec retire(Session.t()) :: :ok | {:error, atom()}
  def retire(session), do: finish(session, :retire_kill, :closed, nil)

  # @cc [owner:ghuntley,label:recovery] terminal-listing-kill-race
  # An authoritative absence observer MUST reload kill intent under the same
  # session lock as archival. A listing snapshot taken before a kill request
  # MUST NOT archive pending intent without its confirmation/retirement receipt.
  @spec observe_absent(Session.t(), boolean(), String.t() | nil) :: :ok | {:error, atom()}
  def observe_absent(session, retired?, observer_id) do
    case transaction(fn ->
           case lock_session(session.id) do
             nil ->
               :ok

             %Session{} = current ->
               same_binding!(session, current)

               if current.kill_status == :pending do
                 action = if retired?, do: :retire_kill, else: :confirm_kill
                 kind = if retired?, do: :closed, else: :killed
                 actor = if retired?, do: nil, else: current.owner_id
                 close_pending!(current, action, kind, actor)
               else
                 :ok = Ledger.archive!(current, :close)
                 record!(current, observer_id, :closed)
               end

               :ok
           end
         end) do
      {:ok, :ok} ->
        closure_processed(session, if(retired?, do: :retired, else: :absent))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec finish(Session.t(), :confirm_kill | :retire_kill, :killed | :closed, String.t() | nil) ::
          :ok | {:error, atom()}
  defp finish(session, action, kind, actor_id) do
    case transaction(fn ->
           case lock_session(session.id) do
             nil ->
               :ok

             %Session{kill_status: :pending} = current ->
               same_binding!(session, current)
               close_pending!(current, action, kind, actor_id)
               :ok

             _ ->
               Ledger.rollback(:unknown_session)
           end
         end) do
      {:ok, :ok} ->
        closure_processed(session, action)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec close_pending!(
          Session.t(),
          :confirm_kill | :retire_kill,
          :killed | :closed,
          String.t() | nil
        ) :: Marshall.Terminal.Event.t()
  defp close_pending!(current, action, kind, actor_id) do
    current = Ledger.update!(current, action, %{})
    :ok = Ledger.archive!(current, :close)
    record!(current, actor_id, kind)
  end

  @spec same_binding!(Session.t(), Session.t()) :: :ok
  defp same_binding!(expected, current) do
    unless expected.vm_id == current.vm_id and expected.placement_id == current.placement_id and
             expected.execution_epoch == current.execution_epoch and
             expected.guest_session_id == current.guest_session_id,
           do: Ledger.rollback(:unknown_session)

    :ok
  end

  @spec lock_session(String.t()) :: Session.t() | nil
  defp lock_session(id),
    do:
      Session
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: Marshall.Authorization.SystemActor.compute())

  @spec closure_processed(Session.t(), atom()) :: :ok
  defp closure_processed(session, outcome) do
    unless Marshall.Repo.in_transaction?(),
      do:
        Marshall.Events.emit("terminal.closure_processed",
          vm_id: session.vm_id,
          session_id: session.id,
          reason: outcome
        )

    :ok
  end

  @spec record!(Session.t(), String.t() | nil, :kill_requested | :killed | :closed) ::
          Marshall.Terminal.Event.t()
  defp record!(session, actor_id, kind) do
    Ash.create!(
      Marshall.Terminal.Event,
      %{
        vm_id: session.vm_id,
        actor_id: actor_id,
        session_id: session.id,
        guest_session_id: session.guest_session_id,
        kind: kind,
        request_id: session.id
      },
      actor: Marshall.Authorization.SystemActor.compute()
    )
  end

  @spec transaction((-> result)) :: {:ok, result} | {:error, atom()} when result: var
  defp transaction(fun, actor \\ :inherit) do
    Ledger.transaction(fun, actor)
  rescue
    _ -> {:error, :terminal_unavailable}
  end
end
