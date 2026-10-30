defmodule Marshall.Terminal.Sharing do
  @moduledoc "Fresh terminal-specific viewing grants with atomic receipts."
  alias Marshall.Terminal.{Grant, Session}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  @doc "Whether Cedar lets `actor` use `session`: its owner or a current share."
  @spec allowed?(Session.t(), Marshall.Accounts.User.t()) :: boolean()
  def allowed?(session, actor),
    do: Marshall.Authorization.allowed?(actor, "terminal_session_use", Session.Cedar, session.id)

  @doc "The sessions among `sessions` that `actor` may use, decided in one query."
  @spec usable([Session.t()], Marshall.Accounts.User.t()) :: [Session.t()]
  def usable(sessions, actor) do
    permitted =
      Marshall.Authorization.prefetch(
        actor,
        "terminal_session_use",
        Session.Cedar,
        Enum.map(sessions, & &1.id)
      )

    Enum.filter(sessions, &Enum.member?(permitted, &1.id))
  end

  # @cc [owner:ghuntley,label:security;recovery] terminal-share-owner-current-vm
  # Only the session owner with current VM write authority may share/revoke it.
  # A recipient MUST already have Cedar read on that VM; the terminal grant MUST
  # NOT grant machine access. Grant mutation and its receipt MUST commit together
  # under the VM/session locks, and repeated identical requests MUST be no-ops.
  @spec set(Session.t(), Marshall.Accounts.User.t(), String.t(), :shared | :revoked) ::
          :ok | {:error, atom()}
  def set(session, actor, email, kind)
      when is_binary(email) and byte_size(email) <= 320 and kind in [:shared, :revoked] do
    result =
      Ledger.transaction(
        fn ->
          vm = Ledger.lock!(VirtualMachine, session.vm_id) || Ledger.rollback(:unknown_session)
          current = Ledger.lock!(Session, session.id) || Ledger.rollback(:unknown_session)

          unless current.owner_id == actor.id and current.kill_status == :idle and
                   current.placement_id == vm.current_placement_id and
                   current.execution_epoch == vm.execution_epoch and
                   vm.desired_state != :deleted and
                   Marshall.Access.Authorization.allowed?(vm, actor, "write"),
                 do: Ledger.rollback(:forbidden)

          recipient =
            Marshall.Accounts.User
            |> Ash.Query.for_read(:internal_lookup, %{},
              actor: Marshall.Authorization.SystemActor.compute()
            )
            |> Ash.Query.filter(email == ^email and is_nil(deleted_at) and active == true)
            |> Ash.read_one!()

          unless not is_nil(recipient) and recipient.id != actor.id and
                   (kind == :revoked or
                      Marshall.Access.Authorization.allowed?(vm, recipient, "read")),
                 do: Ledger.rollback(:recipient_requires_vm_access)

          query =
            Grant |> Ash.Query.filter(session_id == ^current.id and user_id == ^recipient.id)

          existing = Ash.read_one!(query, actor: Marshall.Authorization.SystemActor.compute())

          changed =
            case {kind, existing} do
              {:shared, nil} ->
                if Ash.count!(Grant |> Ash.Query.filter(session_id == ^current.id),
                     actor: Marshall.Authorization.SystemActor.compute()
                   ) >= 64,
                   do: Ledger.rollback(:too_many_viewers)

                Ledger.create!(Grant, :grant, %{
                  session_id: current.id,
                  user_id: recipient.id,
                  granted_by_id: actor.id
                })

                true

              {:revoked, %Grant{} = grant} ->
                Ledger.archive!(grant, :revoke)
                true

              _ ->
                false
            end

          if changed do
            Ash.create!(
              Marshall.Terminal.Event,
              %{
                vm_id: vm.id,
                actor_id: actor.id,
                session_id: current.id,
                guest_session_id: current.guest_session_id,
                kind: kind,
                request_id: Ash.UUID.generate()
              },
              actor: Marshall.Authorization.SystemActor.compute()
            )
          end

          changed
        end,
        actor
      )

    case result do
      {:ok, changed} ->
        if changed and not Marshall.Repo.in_transaction?(),
          do:
            Marshall.Events.emit("terminal.sharing_changed",
              vm_id: session.vm_id,
              session_id: session.id,
              reason: kind
            )

        :ok

      {:error, reason} when is_atom(reason) ->
        refused(session, reason)

      _ ->
        refused(session, :terminal_unavailable)
    end
  rescue
    _ -> refused(session, :terminal_unavailable)
  end

  def set(_, _, _, _), do: {:error, :invalid_terminal_request}

  @spec refused(Session.t(), atom()) :: {:error, atom()}
  defp refused(session, reason) do
    unless Marshall.Repo.in_transaction?(),
      do:
        Marshall.Events.emit("terminal.sharing_refused",
          vm_id: session.vm_id,
          session_id: session.id,
          reason: reason
        )

    {:error, reason}
  end
end
