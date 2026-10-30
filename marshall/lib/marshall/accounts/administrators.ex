defmodule Marshall.Accounts.Administrators do
  @moduledoc "Serialized, audited administrator membership changes."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{AdminBootstrap, AdminEvent, Security, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency] administrator-membership-authority
  # Role changes MUST hold the bootstrap singleton and sorted actor/target User
  # locks through audit commit, rechecking persisted Cedar authority after locking. Self-demotion MUST fail even with other admins.
  # Revocation MUST retain an administrator; mutation and audit commit together.
  @impl true
  def run(input, _, %{actor: %User{} = actor}) do
    result =
      Ledger.transaction(fn ->
        Ledger.lock!(AdminBootstrap, "installation") || Ledger.rollback(:forbidden)

        unless Marshall.Authorization.control_plane?(actor, "admin_accounts"),
          do: Ledger.rollback(:forbidden)

        %{user_id: id, administrator: enabled} = input.arguments
        if id == actor.id and not enabled, do: Ledger.rollback(:self_demotion)

        user = Map.fetch!(Security.lock_admin_participants!(actor.id, id), id)

        unless (user && is_nil(user.deleted_at)) and user.active,
          do: Ledger.rollback(:unknown_user)

        Security.require_admin!(actor)

        changed =
          if user.administrator != enabled do
            if not enabled do
              remaining =
                User
                |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
                |> Ash.Query.filter(administrator == true and is_nil(deleted_at) and id != ^id)
                |> Ash.count!()

              if remaining == 0, do: Ledger.rollback(:last_administrator)
            end

            Ledger.update!(user, :assign_administrator, %{administrator: enabled})

            Ledger.create!(AdminEvent, :record, %{
              actor_id: actor.id,
              target_id: id,
              kind: if(enabled, do: :grant, else: :revoke)
            })

            true
          else
            false
          end

        {%{user_id: id, administrator: enabled},
         if(changed,
           do: {:admin_role_changed, id, actor.id, if(enabled, do: :granted, else: :revoked)},
           else: nil
         )}
      end)

    with {:ok, {outcome, event}} <- result do
      unless Marshall.Repo.in_transaction?(), do: emit_event(event)
      {:ok, outcome}
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp emit_event({:admin_role_changed, user_id, actor_id, operation_status}),
    do:
      Marshall.Events.emit("admin.role_changed",
        user_id: user_id,
        actor_id: actor_id,
        operation_status: operation_status
      )

  defp emit_event(nil), do: :ok
end
