defmodule Marshall.Authorization.ThreadDecisionTableTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias Marshall.Authorization
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}

  @type action :: String.t()
  @type role :: :viewer | :operator | :manager
  @type relation ::
          :creator
          | :stranger
          | {:thread, role()}
          | {:archived_thread, role()}
          | {:machine, role()}
          | {:team, :admin | :member | :removed}
  @type record_state :: %{
          profile: :customer | :standard | :oss,
          owner_active: boolean(),
          thread_team: boolean(),
          team_archived: boolean(),
          thread_archived: boolean()
        }
  @type state :: %{
          relation: relation(),
          profile: :customer | :standard | :oss,
          owner_active: boolean(),
          thread_team: boolean(),
          team_archived: boolean(),
          thread_archived: boolean()
        }

  @actions ~w(read write manage)
  @roles [:viewer, :operator, :manager]
  @relations [:creator, :stranger, {:team, :admin}, {:team, :member}, {:team, :removed}] ++
               for(
                 kind <- [:thread, :archived_thread, :machine],
                 role <- @roles,
                 do: {kind, role}
               )

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    {:ok, team} = create_team(fixture.owner)

    # The fixture provisions personally; the machine joins the owner's team here.
    sql!("UPDATE compute_virtual_machines SET team_id = $2 WHERE id = $1", [
      fixture.vm.id,
      team.id
    ])

    removed = team_member(team, fixture.owner, :member)
    {:ok, _} = set_member(team, fixture.owner, removed, :removed)

    %{
      owner: fixture.owner,
      vm: fixture.vm,
      team: team,
      thread: bound_thread(fixture.owner, fixture.vm),
      member: user(),
      stranger: user(),
      team_admin: team_member(team, fixture.owner, :admin),
      team_member: team_member(team, fixture.owner, :member),
      team_removed: removed
    }
  end

  # @cc [owner:ghuntley,label:security;verification] thread-decision-table
  # For every generated thread machine profile, creator account state, team
  # binding and archival state, and for every principal relation in that
  # state (creator, stranger, thread grant by role, archived thread grant,
  # direct machine grant on the bound VM, team admin/member/removed), the SQL
  # record decision,
  # membership of the Cedar-derived thread filter, the Cedar decision over a
  # hand-built entity, and the real `get_thread` outcome MUST all equal the
  # intended decision table below, which is written from the policy's intent
  # and not from either implementation.
  property "Thread decisions agree with the decision table on every path",
           c,
           profile: :ci,
           test_cases: 24 do
    record = %{
      profile: draw("profile", member_of([:customer, :standard, :oss])),
      owner_active: draw("owner_active", member_of([true, false])),
      thread_team: draw("thread_team", member_of([true, false])),
      team_archived: draw("team_archived", member_of([true, false])),
      thread_archived: draw("thread_archived", member_of([true, false]))
    }

    arrange_record(c, record)

    try do
      Enum.each(@relations, &decide_all(c, Map.put(record, :relation, &1)))
    after
      restore_record(c)
    end
  end

  @spec decide_all(map(), state()) :: :ok
  defp decide_all(c, state) do
    {principal, grant} = arrange(c, state.relation)

    try do
      for action <- @actions do
        expected = expected(state, action)
        label = "#{inspect(state)} #{action}"

        assert Authorization.allowed?(principal, action, Thread.Cedar, c.thread.id) == expected,
               "record decision " <> label

        assert listed?(principal, action, c.thread.id) == expected, "list filter " <> label

        assert Cedar.allowed?(principal, action, entity(c, state, principal)) == expected,
               "hand-built entity " <> label

        if action == "read" do
          outcome = Marshall.Threads.get_thread(%{thread_id: c.thread.id}, actor: principal)
          assert match?({:ok, _}, outcome) == expected, "get_thread " <> label
        end
      end
    after
      if grant, do: :ok = Ledger.archive!(grant, :revoke)
    end

    :ok
  end

  # The intended table: roles by relation (creator and managers/team admins
  # hold every action, operators/team members read and write, viewers read),
  # team roles only through the thread's own unarchived team, archived grants
  # and direct machine grants never, then the creator-account and sharing-profile
  # limits that bound every role. Retained (archived) threads keep their ACL.
  @spec expected(state(), action()) :: boolean()
  def expected(state, action) do
    team? = state.thread_team and not state.team_archived

    granted =
      case state.relation do
        :creator -> ~w(read write manage)
        {:thread, :manager} -> ~w(read write manage)
        {:thread, :operator} -> ~w(read write)
        {:thread, :viewer} -> ~w(read)
        {:team, :admin} when team? -> ~w(read write manage)
        {:team, :member} when team? -> ~w(read write)
        _ -> []
      end

    sharing? = state.profile in [:standard, :oss]

    action in granted and state.owner_active and (state.relation == :creator or sharing?)
  end

  # Outcome paths roll back through the ledger, so each case's changes are
  # undone explicitly instead of inside a wrapping transaction.
  @spec restore_record(map()) :: :ok
  defp restore_record(c) do
    sql!("UPDATE users SET active = true WHERE id = $1", [c.owner.id])
    sql!("UPDATE teams SET archived_at = NULL WHERE id = $1", [c.team.id])

    sql!(
      """
      UPDATE threads SET team_id = NULL, archived_at = NULL,
        machine_spec = jsonb_set(machine_spec, '{profile}', '"standard"')
      WHERE id = $1
      """,
      [c.thread.id]
    )

    :ok
  end

  @spec arrange_record(map(), record_state()) :: :ok
  defp arrange_record(c, record) do
    unless record.owner_active,
      do: sql!("UPDATE users SET active = false WHERE id = $1", [c.owner.id])

    if record.team_archived,
      do: sql!("UPDATE teams SET archived_at = now() WHERE id = $1", [c.team.id])

    if record.thread_team,
      do: sql!("UPDATE threads SET team_id = $2 WHERE id = $1", [c.thread.id, c.team.id])

    if record.thread_archived,
      do: sql!("UPDATE threads SET archived_at = now() WHERE id = $1", [c.thread.id])

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE threads SET machine_spec = jsonb_set(machine_spec, '{profile}', to_jsonb($2::text)) WHERE id = $1",
      [Ecto.UUID.dump!(c.thread.id), Atom.to_string(record.profile)]
    )

    :ok
  end

  @spec arrange(map(), relation()) ::
          {Marshall.Accounts.User.t(), Grant.t() | Marshall.Access.Grant.t() | nil}
  defp arrange(c, relation) do
    case relation do
      :creator ->
        {c.owner, nil}

      :stranger ->
        {c.stranger, nil}

      {:team, :admin} ->
        {c.team_admin, nil}

      {:team, :member} ->
        {c.team_member, nil}

      {:team, :removed} ->
        {c.team_removed, nil}

      {:machine, role} ->
        Marshall.Access.Grant
        |> Ledger.create!(:grant, %{
          vm_id: c.vm.id,
          user_id: c.member.id,
          role: role,
          granted_by_id: c.owner.id
        })
        |> then(&{c.member, &1})

      {:thread, role} ->
        {c.member, thread_grant(c, role)}

      {:archived_thread, role} ->
        :ok = Ledger.archive!(thread_grant(c, role), :revoke)
        {c.member, nil}
    end
  end

  @spec thread_grant(map(), role()) :: Grant.t()
  defp thread_grant(c, role) do
    Ledger.create!(Grant, :grant, %{
      thread_id: c.thread.id,
      user_id: c.member.id,
      role: role,
      granted_by_id: c.owner.id
    })
  end

  @spec listed?(Marshall.Accounts.User.t(), action(), String.t()) :: boolean()
  defp listed?(principal, action, id) do
    Thread
    |> Ash.Query.for_read(Thread.Cedar.read_action(), %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, action, Thread.Cedar)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec entity(map(), state(), Marshall.Accounts.User.t()) :: Marshall.Authorization.Entity.t()
  defp entity(c, state, principal) do
    team? = state.thread_team and not state.team_archived

    grants =
      case state.relation do
        {:team, :admin} when team? -> %{team_admins: [principal.id], team_members: [principal.id]}
        {:team, :member} when team? -> %{team_members: [principal.id]}
        {:thread, role} -> %{role => [principal.id]}
        _ -> %{}
      end

    Marshall.CedarEntities.thread(c.thread.id, c.owner.id, grants, %{
      "owner_active" => state.owner_active,
      "sharing" => state.profile in [:standard, :oss]
    })
  end

  @spec sql!(String.t(), [String.t()]) :: Postgrex.Result.t()
  defp sql!(statement, ids),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, statement, Enum.map(ids, &Ecto.UUID.dump!/1))

  @spec create_team(Marshall.Accounts.User.t()) :: {:ok, Marshall.Teams.Team.t()}
  defp create_team(owner) do
    Marshall.Teams.create_team(
      %{
        name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8),
        idempotency_key: Ash.UUID.generate()
      },
      actor: owner
    )
  end

  @spec set_member(
          Marshall.Teams.Team.t(),
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          :admin | :member | :removed
        ) :: {:ok, map()} | {:error, term()}
  defp set_member(team, owner, member, role) do
    Marshall.Teams.set_team_member(
      %{
        team_id: team.id,
        email: to_string(member.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: owner
    )
  end

  @spec team_member(Marshall.Teams.Team.t(), Marshall.Accounts.User.t(), :admin | :member) ::
          Marshall.Accounts.User.t()
  defp team_member(team, owner, role) do
    member = user()
    {:ok, _} = set_member(team, owner, member, role)
    member
  end

  @spec bound_thread(Marshall.Accounts.User.t(), VirtualMachine.t()) :: Thread.t()
  defp bound_thread(owner, vm) do
    key = Ash.UUID.generate()

    Thread
    |> Ledger.create!(:open, %{
      creator_id: owner.id,
      objective: "Decision table work",
      mode: :medium,
      machine_spec: request(),
      idempotency_key: key,
      machine_key: key
    })
    |> Marshall.ThreadStateFixture.ready!(%{machine_id: vm.id})
  end
end
