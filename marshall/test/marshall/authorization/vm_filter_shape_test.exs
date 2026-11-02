defmodule Marshall.Authorization.VmFilterShapeTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  @moduletag capture_log: true

  alias Marshall.Authorization
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}

  @actions ~w(read write manage web)

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    %{owner: fixture.owner, vm: fixture.vm, member: user()}
  end

  # Verifies vm-cedar-membership-index-paths: the Cedar-filtered machine read MUST carry every membership source as an
  # uncorrelated `= ANY(ARRAY(...))` set: no lateral per-machine aggregate and
  # no correlated EXISTS over grant or membership tables.
  test "the machine list filter has no per-machine membership subquery", c do
    sql = list_sql(c.member, "read")

    assert sql =~ "= ANY(ARRAY("
    refute sql =~ "LATERAL"
    refute sql =~ "GROUP BY"

    for table <- ~w(access_grants thread_grants threads team_members teams),
        do: refute(sql =~ ~s|exists((SELECT 1 FROM "public"."#{table}"|)
  end

  test "a thread grant stops reaching the machine when a second binding appears", c do
    thread = bound_thread(c.owner, c.vm)
    thread_grant!(thread, c.member, c.owner, :manager)
    assert_access(c.member, c.vm.id, ~w(read write manage web))

    _second = bound_thread(c.owner, c.vm)
    assert_access(c.member, c.vm.id, [])
  end

  test "a thread grant on a binding the owner did not create never reaches the machine", c do
    other = user()
    thread = bound_thread(other, c.vm)
    thread_grant!(thread, c.member, other, :viewer)
    assert_access(c.member, c.vm.id, [])
  end

  test "an archived owning team no longer admits its members", c do
    {:ok, team} =
      Marshall.Teams.create_team(
        %{name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8), idempotency_key: uuid()},
        actor: c.owner
      )

    sql!("UPDATE compute_virtual_machines SET team_id = $2 WHERE id = $1", [c.vm.id, team.id])

    {:ok, _} =
      Marshall.Teams.set_team_member(
        %{
          team_id: team.id,
          email: to_string(c.member.email),
          role: :admin,
          idempotency_key: uuid()
        },
        actor: c.owner
      )

    assert_access(c.member, c.vm.id, ~w(read write manage web))

    sql!("UPDATE teams SET archived_at = now() WHERE id = $1", [team.id])
    assert_access(c.member, c.vm.id, [])
  end

  test "a machine without a team admits no one through team membership", c do
    assert_access(c.member, c.vm.id, [])
    assert_access(c.owner, c.vm.id, @actions)
  end

  @spec assert_access(Marshall.Accounts.User.t(), Ecto.UUID.t(), [String.t()]) :: :ok
  defp assert_access(principal, vm_id, allowed) do
    for action <- @actions do
      expected = action in allowed

      assert Authorization.allowed?(principal, action, VirtualMachine.Cedar, vm_id) == expected,
             "decision #{action}"

      assert listed?(principal, action, vm_id) == expected, "list #{action}"
    end

    :ok
  end

  @spec listed?(Marshall.Accounts.User.t(), String.t(), Ecto.UUID.t()) :: boolean()
  defp listed?(principal, action, id) do
    principal
    |> list_query(action)
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec list_query(Marshall.Accounts.User.t(), String.t()) :: Ash.Query.t()
  defp list_query(principal, action) do
    VirtualMachine
    |> Ash.Query.for_read(:read, %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, action, VirtualMachine.Cedar)
    |> Ash.Query.select([:id])
  end

  # The SQL statement the filtered machine read sends to PostgreSQL.
  @spec list_sql(Marshall.Accounts.User.t(), String.t()) :: String.t()
  defp list_sql(principal, action) do
    handler = "vm-filter-shape-#{System.unique_integer([:positive])}"
    caller = self()
    agent = start_supervised!({Agent, fn -> [] end})

    :ok =
      :telemetry.attach(
        handler,
        [:marshall, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == caller,
            do: Agent.update(agent, &[to_string(metadata.query) | &1])
        end,
        nil
      )

    try do
      principal |> list_query(action) |> Ash.read!()
    after
      :telemetry.detach(handler)
    end

    agent
    |> Agent.get(& &1)
    |> Enum.find(&(&1 =~ ~s|FROM "compute_virtual_machines" AS c0|))
    |> Kernel.||(flunk("no machine list statement captured"))
  end

  @spec bound_thread(Marshall.Accounts.User.t(), VirtualMachine.t()) :: Thread.t()
  defp bound_thread(creator, vm) do
    key = uuid()

    Thread
    |> Ledger.create!(:open, %{
      creator_id: creator.id,
      objective: "Filter shape work",
      mode: :medium,
      machine_spec: request(),
      idempotency_key: key,
      machine_key: key
    })
    |> Marshall.ThreadStateFixture.ready!(%{machine_id: vm.id})
  end

  @spec thread_grant!(Thread.t(), Marshall.Accounts.User.t(), Marshall.Accounts.User.t(), atom()) ::
          struct()
  defp thread_grant!(thread, user, by, role) do
    Ledger.create!(Grant, :grant, %{
      thread_id: thread.id,
      user_id: user.id,
      role: role,
      granted_by_id: by.id
    })
  end

  defp uuid, do: Ash.UUID.generate()

  defp sql!(statement, ids),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, statement, Enum.map(ids, &Ecto.UUID.dump!/1))
end
