defmodule Marshall.Authorization.QueryCountTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Authorization
  alias Marshall.Authorization.{DecisionSnapshot, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    viewer = user()

    Ledger.create!(Marshall.Access.Grant, :grant, %{
      vm_id: fixture.vm.id,
      user_id: viewer.id,
      role: :viewer,
      granted_by_id: fixture.owner.id
    })

    %{vm: fixture.vm, viewer: viewer}
  end

  # @cc [owner:ghuntley,label:performance] authorization-query-budget
  # Outside a decision scope, a record decision MUST cost one principal query
  # and one decision query. Inside a scope, the principal MUST load once and a
  # prefetched page MUST be decided in one query, after which per-record
  # decisions cost no query. A Cedar-filtered read MUST add only the principal
  # query to the read itself.
  test "a record decision costs one principal and one decision query", c do
    assert {true, 2} =
             counted(fn ->
               Authorization.allowed?(c.viewer, "read", VirtualMachine.Cedar, c.vm.id)
             end)

    assert {false, 2} =
             counted(fn ->
               Authorization.allowed?(c.viewer, "write", VirtualMachine.Cedar, c.vm.id)
             end)
  end

  test "a prefetched page is decided in one query and reused within the scope", c do
    ids = [c.vm.id, Ash.UUID.generate(), Ash.UUID.generate()]

    {{:ok, decisions}, queries} =
      counted(fn ->
        DecisionSnapshot.transaction(fn ->
          Authorization.prefetch(c.viewer, "read", VirtualMachine.Cedar, ids)
          Enum.map(ids, &Authorization.allowed?(c.viewer, "read", VirtualMachine.Cedar, &1))
        end)
      end)

    assert decisions == [true, false, false]
    assert queries == 2
  end

  test "a Cedar-filtered read adds only the principal query", c do
    {rows, queries} =
      counted(fn ->
        VirtualMachine
        |> Ash.Query.for_read(:read, %{}, actor: SystemActor.compute())
        |> Authorization.filter(c.viewer, "read", VirtualMachine.Cedar)
        |> Ash.Query.select([:id])
        |> Ash.read!()
      end)

    assert Enum.map(rows, & &1.id) == [c.vm.id]
    assert queries == 2
  end

  # Counts statements, not transaction control, issued by this process.
  @spec counted((-> result)) :: {result, non_neg_integer()} when result: term()
  defp counted(fun) do
    handler = "authorization-query-count-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    caller = self()

    :ok =
      :telemetry.attach(
        handler,
        [:marshall, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == caller and not control?(metadata.query), do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  defp control?(query) do
    statement = query |> to_string() |> String.trim_leading() |> String.downcase()

    Enum.any?(
      ~w(begin commit rollback savepoint release set),
      &String.starts_with?(statement, &1)
    )
  end
end
