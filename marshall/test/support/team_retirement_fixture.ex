defmodule Marshall.TeamRetirementFixture do
  @moduledoc "Target-specific write gates and committed observations for real account retirement."
  alias Marshall.Accounts.{User, UserDeletion}
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.{Team, TeamMember, Transfer}
  alias Marshall.Repo

  @type gate_kind :: :membership | :acceptance | :retirement
  @type snapshot :: %{
          retired: boolean(),
          memberships: [{String.t(), atom(), boolean()}],
          transfers: [{String.t(), atom()}],
          events: [{String.t(), String.t(), atom()}],
          deletions: [{String.t(), boolean(), non_neg_integer(), boolean()}]
        }

  # @cc [owner:ghuntley,label:verification] team-retirement-real-production-gates
  # Gates MUST pause target-specific writes inside real production actions. They
  # MUST NOT acquire account or team locks on behalf of those actions. The
  # competing operation's actual PostgreSQL wait MUST identify the account fence.
  @spec install_gate(gate_kind(), String.t(), pos_integer()) :: :ok
  def install_gate(kind, id, gate) do
    id = Ecto.UUID.cast!(id)
    name = name(id)

    {table, event, condition} =
      case kind do
        :membership ->
          {"team_members", "INSERT", "NEW.user_id = TG_ARGV[0]::uuid"}

        :acceptance ->
          {"team_transfers", "UPDATE OF state",
           "NEW.id = TG_ARGV[0]::uuid AND NEW.state = 'accepted'"}

        :retirement ->
          {"users", "UPDATE OF deleted_at",
           "NEW.id = TG_ARGV[0]::uuid AND NEW.deleted_at IS NOT NULL"}
      end

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN
        PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    query("""
    CREATE TRIGGER #{name} BEFORE #{event} ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{name}('#{id}', '#{gate}')
    """)

    :ok
  end

  @spec remove_gate(gate_kind(), String.t()) :: :ok
  def remove_gate(kind, id) do
    table =
      Map.fetch!(
        %{membership: "team_members", acceptance: "team_transfers", retirement: "users"},
        kind
      )

    name = name(id)
    query("DROP TRIGGER IF EXISTS #{name} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{name}()")
    :ok
  end

  @spec retire(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def retire(admin, account) do
    User
    |> Ash.ActionInput.for_action(
      :delete_user,
      %{user_id: account.id, confirmation: to_string(account.email)},
      actor: admin
    )
    |> Ash.run_action()
  end

  @spec snapshot(String.t(), String.t()) :: snapshot()
  def snapshot(team_id, account_id) do
    %{
      retired: Marshall.Accounts.Security.current(account_id).deleted_at != nil,
      memberships:
        Ledger.history!(TeamMember, team_id: team_id)
        |> Enum.map(&{&1.user_id, &1.role, &1.archived_at != nil})
        |> Enum.sort(),
      transfers:
        Ledger.history!(Transfer, team_id: team_id) |> Enum.map(&{&1.id, &1.state}) |> Enum.sort(),
      events: events(team_id, account_id),
      deletions:
        Ledger.read!(UserDeletion, user_id: account_id)
        |> Enum.map(&{&1.id, &1.completed_at != nil, &1.remaining, &1.blocked})
    }
  end

  @spec events(String.t(), String.t()) :: [{String.t(), String.t(), atom()}]
  defp events(team_id, account_id) do
    ids = [team_id, account_id | Enum.map(Ledger.history!(Transfer, team_id: team_id), & &1.id)]

    Ledger.read!(Marshall.Accounts.AdminEvent)
    |> Enum.filter(&(&1.target_id in ids))
    |> Enum.map(&{&1.actor_id, &1.target_id, &1.kind})
    |> Enum.sort()
  end

  # @cc [owner:ghuntley,label:verification] team-retirement-fixture-history-ownership
  # Callers MUST finish or stop all remote operations before disposal. Job
  # histories may be deleted only for raw jobs returned by deletion receipts
  # belonging to these owned fixture users; unrelated history MUST survive.
  @spec cleanup(Team.t(), [User.t()]) :: :ok
  def cleanup(team, users) do
    params = [Ecto.UUID.dump!(team.id)]

    query(
      "UPDATE teams SET archived_at = clock_timestamp() AT TIME ZONE 'UTC' WHERE id=$1",
      params
    )

    query(
      "DELETE FROM account_admin_events WHERE target_id=$1 OR target_id IN (SELECT id FROM team_transfers WHERE team_id=$1)",
      params
    )

    for table <- ["team_transfers", "team_members"] do
      query(
        "DELETE FROM #{table}_versions WHERE version_source_id IN (SELECT id FROM #{table} WHERE team_id=$1)",
        params
      )

      query("DELETE FROM #{table} WHERE team_id=$1", params)
    end

    query("DELETE FROM teams_versions WHERE version_source_id=$1", params)
    query("DELETE FROM teams WHERE id=$1", params)

    for user <- users do
      id = Ecto.UUID.dump!(user.id)

      Marshall.CommittedFixtureCleanup.subscription_reviews!([user.id])

      for deletion <- Ledger.read!(UserDeletion, user_id: user.id) do
        Marshall.CommittedFixtureCleanup.jobs!("args->'primary_key'->>'id'=$1", [deletion.id])
      end

      query("DELETE FROM account_user_deletions WHERE user_id=$1", [id])
      Marshall.PasskeyFixture.cleanup(user)
      query("DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1", [id])
      query("DELETE FROM users WHERE id=$1", [id])
    end

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  @spec name(String.t()) :: String.t()
  defp name(id), do: "team_retire_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")
end
