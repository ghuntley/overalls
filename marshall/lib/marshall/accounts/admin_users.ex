defmodule Marshall.Accounts.AdminUsers do
  @moduledoc "Bounded administrative account projections, separate from ordinary sharing reads."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{AdminBootstrap, AdminEvent, Security, User}
  alias Marshall.Compute.Ledger
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;capacity] admin-user-page-projection
  # Every account page MUST recheck current Cedar Control room read permission,
  # bound its query to limit plus one, and expose only identity, role, MFA configuration, owned count, deletion progress and the saved display time zone.
  # Tokens, authentication metadata and unbounded account reads MUST NOT escape.
  @impl true
  def run(input, _, %{actor: actor}) do
    if Marshall.Authorization.control_plane?(
         actor,
         if(input.action.name == :list_admin_users, do: "admin_read", else: "admin_accounts")
       ) do
      case input.action.name do
        :list_admin_users -> list(input.arguments)
        :revoke_sessions_for_admin -> revoke_sessions(input.arguments, actor)
      end
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp list(args) do
    limit = args.limit
    cursor = Map.get(args, :after)

    query =
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(limit + 1)

    query = if cursor, do: Ash.Query.filter(query, id > ^cursor), else: query

    with {:ok, rows} <- Ash.read(query) do
      {:ok,
       %{
         items: rows |> Enum.take(limit) |> Enum.map(&project/1),
         next_cursor: if(length(rows) > limit, do: Enum.at(rows, limit - 1).id)
       }}
    end
  end

  defp project(user) do
    deletion = List.first(Ledger.read!(Marshall.Accounts.UserDeletion, user_id: user.id))

    user
    |> Map.take([:id, :email, :administrator, :mfa_enabled, :deleted_at, :time_zone])
    |> Map.put(:owned_count, Marshall.Accounts.AccountLifecycle.owned_count(user.id))
    |> Map.put(:email, if(deletion, do: deletion.email, else: user.email))
    |> Map.put(
      :deletion_status,
      cond do
        is_nil(deletion) -> nil
        deletion.completed_at -> "Deleted"
        deletion.blocked -> "Retrying machine cleanup"
        true -> "Deleting machines"
      end
    )
  end

  # @cc [owner:ghuntley,label:security;concurrency] admin-revoke-browser-sessions
  # Browser-session revocation MUST hold the admin bootstrap latch and sorted
  # actor/target User locks through audit commit, recheck current administrator authority and revoke the selected account's
  # stored user and remember_me purposes under its row lock. A concurrent remember
  # exchange MUST finish before this revocation or refuse afterwards; fresh email,
  # SSH and service credentials remain independent. Token values and authentication metadata
  # MUST never enter the response or audit event.
  defp revoke_sessions(%{user_id: user_id}, actor) do
    Ledger.transaction(fn ->
      Ledger.lock!(AdminBootstrap, "installation") || Ledger.rollback(:forbidden)
      Security.require_admin!(actor)

      user = Map.fetch!(Security.lock_admin_participants!(actor.id, user_id), user_id)

      unless user, do: Ledger.rollback(:unknown_user)
      Security.require_admin!(actor)

      %{num_rows: count} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "UPDATE tokens SET purpose = 'revocation', updated_at = (now() AT TIME ZONE 'utc') WHERE subject = $1 AND purpose IN ('user', 'remember_me')",
          ["user?id=#{user.id}"],
          log: false
        )

      Marshall.Control.Hints.notify_user(user.id)

      Ledger.create!(AdminEvent, :record, %{
        actor_id: actor.id,
        target_id: user.id,
        kind: :sessions_revoke
      })

      %{user_id: user.id, revoked: count}
    end)
    |> case do
      {:ok, summary} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("account.sessions_revoked",
            user_id: summary.user_id,
            actor_id: actor.id,
            deleted_count: summary.revoked
          )
        end

        {:ok, summary}

      other ->
        other
    end
  end
end
