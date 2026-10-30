defmodule Lilly.Host.PoolObserverTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Collector, Pool, PoolObserver}

  @pool %Pool{
    id: "11111111-1111-4111-8111-111111111111",
    path: "/nonexistent/lilly-pool-observer",
    filesystem_id: "fixture-fs",
    storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"},
    backend: :zfs
  }

  @observed %{
    id: "11111111-1111-4111-8111-111111111111",
    total_bytes: 100,
    free_bytes: 60,
    allocations: %{},
    checkpoint_allocations: %{},
    storage: %{
      backend: :zfs,
      zpool_guid: "1",
      dataset_guid: "2",
      dataset: "tank/lilly",
      used_bytes: 40,
      quota_bytes: 100
    }
  }

  # A pool read that takes `delay_ms`, reporting when it starts and returns.
  @spec slow_read(pid(), non_neg_integer()) :: PoolObserver.read()
  defp slow_read(test, delay_ms) do
    fn _pool ->
      send(test, {:read_started, System.monotonic_time(:millisecond)})
      Process.sleep(delay_ms)
      @observed
    end
  end

  @spec start_observer(PoolObserver.read()) :: atom()
  defp start_observer(read) do
    view = :"pool_observer_test_#{System.unique_integer([:positive])}"
    start_supervised!({PoolObserver, {[@pool], [view: view, read: read, interval_ms: 1000]}})
    view
  end

  # @cc [owner:ghuntley,label:verification;capacity] pool-read-never-delays-report
  # With a pool read slower than Marshall's 5 s capacity freshness, collection
  # MUST keep its one-second cadence, report the pool busy until the read
  # completes, then report the observation stamped with the read's start time.
  test "a pool read slower than capacity freshness keeps reports on a one-second cadence" do
    view = start_observer(slow_read(self(), 6000))
    assert_receive {:read_started, started}, 1000

    samples =
      for sequence <- 1..5 do
        before = System.monotonic_time(:millisecond)

        {:ok, report, _} =
          Collector.sample([@pool], "/sys/fs/cgroup", nil, sequence, [], %{}, %{}, view)

        took = System.monotonic_time(:millisecond) - before
        Process.sleep(max(0, 1000 - took))
        {took, report}
      end

    for {took, report} <- samples do
      assert took < 500
      assert [%{id: id, busy: true, storage: storage}] = report.pools
      assert id == @pool.id and storage == @pool.storage
    end

    # The 6 s read has now completed (or does shortly): the observation is
    # reported with its read's start time, not the report's time.
    {:ok, report} =
      wait_for(fn ->
        {:ok, report, _} = Collector.sample([@pool], "/sys/fs/cgroup", nil, 6, [], %{}, %{}, view)
        if Map.has_key?(hd(report.pools), :observed_at), do: {:ok, report}
      end)

    [entry] = report.pools
    assert Map.delete(entry, :observed_at) == @observed
    lag = DateTime.diff(report.sampled_at, entry.observed_at, :millisecond)
    assert lag >= 6000
    assert System.monotonic_time(:millisecond) - started >= 6000

    # No second read overlapped the first.
    {:messages, messages} = Process.info(self(), :messages)
    later = for {:read_started, at} <- messages, do: at
    assert Enum.all?(later, &(&1 >= started + 6000))
  end

  test "a crashed read keeps the previous observation and reads again" do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    read = fn _pool ->
      call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      send(test, {:read, call})
      if call == 2, do: raise("pool read failed"), else: @observed
    end

    view = start_observer(read)
    assert_receive {:read, 1}, 1000

    {:ok, first} =
      wait_for(fn ->
        case PoolObserver.report(@pool, view) do
          %{observed_at: _} = entry -> {:ok, entry}
          _ -> nil
        end
      end)

    assert_receive {:read, 2}, 3000
    assert PoolObserver.report(@pool, view) == first
    assert_receive {:read, 3}, 3000
  end

  test "without an observer view the pool is reported busy, never read inline" do
    assert %{id: id, busy: true, storage: storage} =
             PoolObserver.report(@pool, :pool_observer_test_absent_view)

    assert id == @pool.id and storage == @pool.storage
  end

  @spec wait_for((-> {:ok, term()} | nil), non_neg_integer()) :: {:ok, term()}
  defp wait_for(probe, attempts \\ 40) do
    case probe.() do
      {:ok, value} ->
        {:ok, value}

      nil when attempts > 0 ->
        Process.sleep(100)
        wait_for(probe, attempts - 1)

      nil ->
        flunk("condition not reached")
    end
  end
end
