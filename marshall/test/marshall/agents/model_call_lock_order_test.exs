defmodule Marshall.Agents.ModelCallLockOrderTest do
  @moduledoc """
  Committed lock-order regression for model-call queueing against host fences.

  Host-authenticated calls and host fences lock the host row before the VM
  (ADR-0019). A real holder transaction takes the host fence (FOR UPDATE) on
  its own connection while `ModelCalls.queue/3` runs on another. Once queueing
  is blocked, the holder takes the VM row with NOWAIT. It must be free: a
  queue that already holds the VM while it waits on the host (through the
  ModelCall host foreign key) is the observed three-way deadlock.
  """
  use ExUnit.Case, async: false
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Agents.{ModelCall, ModelCalls}
  alias Marshall.AgentContextRecoveryFixture, as: Recovery
  alias Marshall.AgentRevocationFixture, as: Fixture
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  @type probe :: :acquired | atom()

  # @cc [owner:ghuntley,label:verification] model-call-lock-order-fixture-preservation
  # The case MUST restore the complete pre-test committed row inventory,
  # including image records created by the fixture.
  setup do
    {before, images_before} =
      unboxed(fn ->
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification;concurrency] model-call-queue-host-before-vm-race
  # Queueing blocked behind a host fence MUST NOT hold the VM row lock, and MUST
  # queue the call once the fence is released.
  test "queueing waits for the host before locking the VM" do
    {fixture, turn} =
      unboxed(fn ->
        {:ok, fixture} = Ledger.transaction(fn -> Fixture.setup() end)
        vm = fixture.vm
        users = [fixture.owner, fixture.member]
        on_exit(fn -> unboxed(fn -> Recovery.cleanup!(vm.id, vm.host_id, users) end) end)
        {fixture, Fixture.submit!(fixture)}
      end)

    parent = self()
    host = Ecto.UUID.dump!(fixture.vm.host_id)
    vm = Ecto.UUID.dump!(fixture.vm.id)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          {:error, probe} =
            Repo.transaction(fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)

              Repo.query!("SELECT 1 FROM compute_hosts WHERE id=$1 FOR UPDATE", [host],
                log: false
              )

              send(parent, {:holding, pid})

              receive do
                :probe -> :ok
              after
                30_000 -> raise "lock-order probe was never released"
              end

              Repo.rollback(probe_vm(vm))
            end)

          probe
        end)
      end)

    pid =
      receive do
        {:holding, pid} -> pid
      after
        30_000 -> raise "lock-order holder did not start"
      end

    queue = Task.async(fn -> unboxed(fn -> ModelCalls.queue(turn.id, "gpt-6-sol") end) end)
    await_blocked!(pid, System.monotonic_time(:millisecond) + 30_000)
    send(holder.pid, :probe)

    assert Task.await(holder, 60_000) == :acquired
    assert {:ok, %ModelCall{turn_id: turn_id, host_id: host_id}} = Task.await(queue, 60_000)
    assert turn_id == turn.id
    assert host_id == fixture.vm.host_id
  end

  @spec probe_vm(binary()) :: probe()
  defp probe_vm(vm) do
    Repo.query!("SELECT 1 FROM compute_virtual_machines WHERE id=$1 FOR UPDATE NOWAIT", [vm],
      log: false
    )

    :acquired
  rescue
    error in Postgrex.Error -> error.postgres.code
  end

  @spec await_blocked!(integer(), integer()) :: :ok
  defp await_blocked!(pid, deadline) do
    %{rows: [[count]]} =
      unboxed(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [pid],
          log: false
        )
      end)

    cond do
      count > 0 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "model-call queueing never blocked on the host fence"

      true ->
        Process.sleep(20)
        await_blocked!(pid, deadline)
    end
  end

  @spec unboxed((-> value)) :: value when value: term()
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
