defmodule Marshall.TeamsConcurrencyTest do
  use ExUnit.Case, async: false
  alias Marshall.Accounts.Security
  alias Marshall.Compute.Ledger
  alias Marshall.Repo
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, TeamMember, Transfer}

  # @cc [owner:ghuntley,label:verification;concurrency] team-independent-connections
  # Team overlap tests MUST run each contender on an independently checked-out
  # PostgreSQL connection and synchronize before mutation. Final assertions MUST
  # cover account state, membership/transfer state and exactly one active owner.
  test "membership addition serializes with account retirement" do
    %{owner: owner, target: target, team: team} = fixture()

    {membership, retirement} =
      race(
        fn ->
          Teams.set_team_member(
            %{
              team_id: team.id,
              email: to_string(target.email),
              role: :member,
              idempotency_key: Ash.UUID.generate()
            },
            actor: owner
          )
        end,
        fn -> retire(target.id, owner.id) end
      )

    assert match?({:ok, _}, retirement)
    assert match?({:ok, _}, membership) or match?({:error, _}, membership)

    unboxed(fn ->
      assert Security.current(target.id).deleted_at != nil
      assert Ledger.read!(TeamMember, team_id: team.id, user_id: target.id) == []
      assert one_owner?(team.id)
    end)
  end

  test "transfer acceptance serializes with target retirement" do
    %{owner: owner, target: target, team: team} = fixture()

    unboxed(fn ->
      assert {:ok, _} =
               Teams.set_team_member(
                 %{
                   team_id: team.id,
                   email: to_string(target.email),
                   role: :member,
                   idempotency_key: Ash.UUID.generate()
                 },
                 actor: owner
               )

      assert {:ok, _} = Coordinator.offer(team.id, to_string(target.email), owner)
    end)

    transfer =
      unboxed(fn -> List.first(Ledger.read!(Transfer, team_id: team.id, state: :pending)) end)

    {acceptance, retirement} =
      race(
        fn -> Coordinator.accept(transfer.id, target) end,
        fn -> retire(target.id, owner.id) end
      )

    unboxed(fn ->
      [result] = Ledger.read!(Transfer, id: transfer.id)
      assert one_owner?(team.id)

      case result.state do
        :accepted ->
          assert match?({:ok, _}, acceptance)
          assert match?({:error, _}, retirement)
          assert Security.current(target.id).deleted_at == nil
          assert Coordinator.roles(team.id).owner == target.id

        :cancelled ->
          assert match?({:error, _}, acceptance)
          assert match?({:ok, _}, retirement)
          assert Security.current(target.id).deleted_at != nil
          assert Coordinator.roles(team.id).owner == owner.id
      end
    end)
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        owner = Marshall.ComputeFixtures.user()
        target = Marshall.ComputeFixtures.user()

        {:ok, team} =
          Teams.create_team(
            %{
              name: "race-team-" <> binary_part(Ash.UUID.generate(), 0, 8),
              idempotency_key: Ash.UUID.generate()
            },
            actor: owner
          )

        %{owner: owner, target: target, team: team}
      end)

    on_exit(fn -> cleanup(fixture) end)
    fixture
  end

  defp race(left, right) do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    tasks =
      for operation <- [left, right] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> operation.())
          end)
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    tasks |> Task.await_many(15_000) |> List.to_tuple()
  end

  defp retire(user_id, actor_id) do
    Ledger.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["account:" <> user_id],
        log: false
      )

      user = Security.lock_user!(user_id)
      Coordinator.retire_user!(user_id, actor_id)
      Ledger.update!(user, :security_state, %{deleted_at: Ledger.now()})
    end)
  end

  defp one_owner?(team_id) do
    Enum.count(Ledger.read!(TeamMember, team_id: team_id), &(&1.role == :owner)) == 1
  end

  defp cleanup(%{owner: owner, target: target, team: team}) do
    unboxed(fn ->
      params = [Ecto.UUID.dump!(team.id)]

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE teams SET archived_at = clock_timestamp() AT TIME ZONE 'UTC' WHERE id = $1",
        params,
        log: false
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM account_admin_events WHERE target_id = $1 OR target_id IN (SELECT id FROM team_transfers WHERE team_id = $1)",
        params,
        log: false
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM team_transfers_versions WHERE version_source_id IN (SELECT id FROM team_transfers WHERE team_id = $1)",
        params,
        log: false
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM team_transfers WHERE team_id = $1", params,
        log: false
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM team_members_versions WHERE version_source_id IN (SELECT id FROM team_members WHERE team_id = $1)",
        params,
        log: false
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM team_members WHERE team_id = $1", params,
        log: false
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM teams_versions WHERE version_source_id = $1",
        params,
        log: false
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM teams WHERE id = $1", params, log: false)

      # Retirement enqueues a subscription review per affected owner. Left
      # behind, it stays a raw job that installation-wide queue counts see.
      %{rows: jobs} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM oban_jobs WHERE worker = 'Marshall.Threads.SubscriptionRevokeJob' AND args->>'owner_id' IN ($1, $2) RETURNING id",
          [owner.id, target.id],
          log: false
        )

      for [job] <- jobs do
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM admin_job_events WHERE job_id = $1", [job],
          log: false
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM admin_job_snapshots WHERE id = $1", [job],
          log: false
        )
      end

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM users WHERE id IN ($1, $2)",
        [
          Ecto.UUID.dump!(owner.id),
          Ecto.UUID.dump!(target.id)
        ],
        log: false
      )
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
