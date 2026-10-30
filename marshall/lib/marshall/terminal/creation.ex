defmodule Marshall.Terminal.Creation do
  @moduledoc "Reserve before effects, retry one guest request, and commit one registry receipt."
  alias Marshall.Terminal.{Opening, Session}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  @spec reserve(VirtualMachine.t(), map(), String.t(), String.t(), String.t()) ::
          {:ok, Opening.t()} | {:error, atom()}
  def reserve(vm, actor, user, term, request_id) do
    if OverallsProtocol.uuid?(request_id) and is_binary(user) and byte_size(user) in 1..64 and
         String.valid?(user) and not String.contains?(user, <<0>>) and
         is_binary(term) and byte_size(term) in 1..32 and String.valid?(term) and
         not String.contains?(term, <<0>>) do
      digest = :crypto.hash(:sha256, JSON.encode!([user, term]))

      transaction(
        fn ->
          lock_request(request_id)
          lock_vm(vm.id)
          previous = read_request(request_id)

          cond do
            previous &&
                (previous.vm_id != vm.id or previous.actor_id != actor.id or
                   previous.parameter_hash != digest) ->
              Ledger.rollback(:idempotency_conflict)

            not is_nil(previous) and previous.status == :ready and current?(previous, vm) ->
              previous

            previous &&
                (previous.status != :pending or expired?(previous) or not current?(previous, vm)) ->
              Ledger.rollback(:opening_expired)

            previous ->
              previous

            true ->
              slots =
                Ash.count!(Session |> Ash.Query.filter(vm_id == ^vm.id and is_nil(archived_at)),
                  actor: Marshall.Authorization.SystemActor.compute()
                )

              pending =
                Ash.count!(
                  Opening
                  |> Ash.Query.filter(
                    vm_id == ^vm.id and status in [:pending, :cancelling] and
                      placement_id == ^vm.current_placement_id and
                      execution_epoch == ^vm.execution_epoch
                  ),
                  actor: Marshall.Authorization.SystemActor.compute()
                )

              if slots + pending >= 64, do: Ledger.rollback(:too_many_terminal_sessions)

              Ash.create!(
                Opening,
                %{
                  id: request_id,
                  vm_id: vm.id,
                  actor_id: actor.id,
                  placement_id: vm.current_placement_id,
                  execution_epoch: vm.execution_epoch,
                  parameter_hash: digest,
                  expires_at: DateTime.add(Ledger.now(), 600)
                },
                actor: Marshall.Authorization.SystemActor.compute()
              )
          end
        end,
        actor
      )
      |> refused(vm.id)
    else
      refused({:error, :invalid_terminal_request}, vm.id)
    end
  end

  # @cc [owner:ghuntley,label:security;observability] terminal-creation-refusals
  # Every refused terminal creation MUST emit its closed refusal reason after
  # the transaction settles; admitted creations stay silent because the
  # durable opening, lifecycle audit and attach diagnostics carry the outcome.
  # Reasons never carry usernames, terminal types or request identifiers.
  defp refused({:ok, _} = ok, _vm_id), do: ok

  defp refused({:error, reason}, vm_id) when is_atom(reason) do
    unless Marshall.Repo.in_transaction?() do
      Marshall.Events.emit("terminal.creation_refused", vm_id: vm_id, reason: reason)
    end

    {:error, reason}
  end

  # @cc [owner:ghuntley,label:recovery] create-completion-single-receipt
  # Guest creation replies MUST complete only a matching pending request. The
  # registry, opened receipt and ready state MUST commit in one transaction;
  # duplicate replies return that same registry record. Cancellation wins once
  # claimed and a late reply MUST NOT resurrect a cancelled request.
  @spec complete(String.t(), pos_integer()) :: {:ok, Session.t()} | {:error, atom()}
  def complete(request_id, guest_id) do
    transaction(
      fn ->
        lock_request(request_id)
        request = read_request(request_id) || Ledger.rollback(:unknown_request)
        lock_vm(request.vm_id)

        case request.status do
          :ready ->
            session!(request.session_id)

          :pending ->
            vm =
              Ledger.lock!(VirtualMachine, request.vm_id) ||
                Ledger.rollback(:unknown_session)

            if expired?(request) or not current?(request, vm),
              do: Ledger.rollback(:opening_expired)

            if vm.desired_state != :running or vm.observed_state != :running,
              do: Ledger.rollback(:terminal_unavailable)

            session =
              Ledger.create!(
                Session,
                :open,
                %{
                  vm_id: request.vm_id,
                  owner_id: request.actor_id,
                  placement_id: request.placement_id,
                  execution_epoch: request.execution_epoch,
                  guest_session_id: guest_id
                }
              )

            {:ok, _} =
              Marshall.Terminal.record(
                %{
                  vm_id: request.vm_id,
                  actor_id: request.actor_id,
                  session_id: session.id,
                  guest_session_id: guest_id,
                  kind: :opened,
                  request_id: request.id
                },
                actor: Marshall.Authorization.SystemActor.compute()
              )

            Ash.update!(request, %{session_id: session.id},
              action: :complete,
              actor: Marshall.Authorization.SystemActor.compute()
            )

            session

          _ ->
            Ledger.rollback(:opening_expired)
        end
      end,
      :provisioner
    )
    |> refused(nil)
  end

  @spec receipt(Opening.t()) :: {:ok, Session.t()} | {:error, atom()}
  def receipt(request) do
    case Ash.get(Session, request.session_id, actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, %Session{} = session} -> {:ok, session}
      _ -> {:error, :unknown_session}
    end
  end

  @spec begin_cancel(String.t()) :: {:ok, Opening.t()} | {:error, atom()}
  def begin_cancel(id) do
    transaction(fn ->
      lock_request(id)

      case read_request(id) do
        %Opening{status: :pending} = request ->
          Ash.update!(request, %{},
            action: :begin_cancel,
            actor: Marshall.Authorization.SystemActor.compute()
          )

        %Opening{status: :cancelling} = request ->
          request

        _ ->
          Ledger.rollback(:already_complete)
      end
    end)
  end

  @spec cancelled(String.t()) :: :ok | {:error, atom()}
  def cancelled(id) do
    case transaction(fn ->
           lock_request(id)

           case read_request(id) do
             %Opening{status: :cancelling} = request ->
               Ash.update!(request, %{},
                 action: :fail,
                 actor: Marshall.Authorization.SystemActor.compute()
               )

               :changed

             %Opening{status: :failed} ->
               :ok

             _ ->
               Ledger.rollback(:already_complete)
           end
         end) do
      {:ok, :changed} ->
        unless Marshall.Repo.in_transaction?(),
          do: Marshall.Events.emit("terminal.creation_cancelled", request_id: id)

        :ok

      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec expired?(Opening.t()) :: boolean()
  def expired?(request), do: DateTime.compare(request.expires_at, Ledger.now()) != :gt
  @spec current?(Opening.t(), VirtualMachine.t()) :: boolean()
  def current?(request, vm),
    do:
      request.placement_id == vm.current_placement_id and
        request.execution_epoch == vm.execution_epoch

  defp read_request(id),
    do:
      Opening
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(actor: Marshall.Authorization.SystemActor.compute())

  defp session!(id) do
    case Ash.get(Session, id, actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, %Session{} = session} -> session
      _ -> Ledger.rollback(:unknown_session)
    end
  end

  defp lock_request(id), do: lock("terminal-create:" <> id)
  defp lock_vm(id), do: lock("terminal-open:" <> id)

  defp lock(key),
    do:
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        [key],
        log: false
      )

  defp transaction(fun, actor \\ :inherit) do
    Ledger.transaction(fun, actor)
  rescue
    _ -> {:error, :terminal_unavailable}
  end
end
