defmodule Lilly.Host.PoolObserverLockTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{ImageTemplate, Pool, PoolObserver, Storage}
  @moduletag :tmp_dir

  # A CI-sized observation: the pool lock held for 2.5 s per read.
  @hold_ms 2500

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

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    pool = %Pool{
      id: "11111111-1111-4111-8111-111111111111",
      path: directory,
      filesystem_id: "zfs:1:2"
    }

    %{pool: pool}
  end

  # The production snapshot's lock section: a 200 ms wait, then the hold.
  @spec locked_read(pid(), non_neg_integer()) :: PoolObserver.read()
  defp locked_read(test, hold_ms) do
    fn pool ->
      Storage.locked(
        pool,
        fn ->
          send(test, {:read_started, System.monotonic_time(:millisecond)})
          Process.sleep(hold_ms)
          send(test, {:read_finished, System.monotonic_time(:millisecond)})
          @observed
        end,
        200,
        :snapshot
      )
    end
  end

  @spec start_observer(Pool.t(), PoolObserver.read()) :: atom()
  defp start_observer(pool, read) do
    view = :"pool_observer_lock_test_#{System.unique_integer([:positive])}"
    start_supervised!({PoolObserver, {[pool], [view: view, read: read, interval_ms: 1000]}})
    view
  end

  @spec reserve(Pool.t(), non_neg_integer()) :: {term(), non_neg_integer()}
  defp reserve(pool, wait_ms) do
    started = System.monotonic_time(:millisecond)
    result = Storage.locked(pool, fn -> :reserved end, wait_ms, :template_reserve)
    {result, System.monotonic_time(:millisecond) - started}
  end

  # @cc [owner:ghuntley,label:verification;concurrency] template-reserve-within-one-observation
  # While a pool observer holds the pool lock for 2.5 s per read, a template
  # reservation arriving at any point of a read MUST acquire the lock within
  # the rest of that one read plus 1 s, never storage_busy. The former 1 s
  # wait MUST be shown to fail against the same read (run 41164441328).
  test "a template reservation outwaits one slow observation", %{pool: pool} do
    start_observer(pool, locked_read(self(), @hold_ms))

    # Root cause: a 1 s wait cannot outlast a 2.5 s observation hold.
    assert_receive {:read_started, _}, 2000
    Process.sleep(100)
    assert {{:error, :storage_busy}, _} = reserve(pool, 1000)

    for offset <- [100, 1200, 2200] do
      assert_receive {:read_started, started}, 10_000
      Process.sleep(offset)
      {result, waited} = reserve(pool, ImageTemplate.section_wait_ms())
      assert result == :reserved
      assert waited <= @hold_ms - offset + 1000
      assert System.monotonic_time(:millisecond) - started <= @hold_ms + 1000
    end
  end

  # @cc [owner:ghuntley,label:verification;concurrency] observer-lock-duty-at-most-half
  # With a 2.5 s read, the observer MUST leave the pool lock free between reads
  # for at least as long as the read held it.
  test "a slow observation rests at least as long as it held the lock", %{pool: pool} do
    start_observer(pool, locked_read(self(), @hold_ms))
    assert_receive {:read_started, _}, 2000

    gaps =
      for _ <- 1..2 do
        assert_receive {:read_finished, finished}, 10_000
        assert_receive {:read_started, next}, 10_000
        next - finished
      end

    assert Enum.all?(gaps, &(&1 >= @hold_ms))
  end

  @tag :hegel
  test "rest keeps one read per interval and at most half the lock for slow reads" do
    Hegel.check(
      fn ->
        interval = draw("interval", integer(1..5000))
        duration = draw("duration", integer(0..20_000))
        rest = PoolObserver.Worker.rest(interval, duration)

        assert duration + rest >= interval
        assert rest >= min(duration, 3000)
        assert rest <= max(interval, 3000)
      end,
      test_cases: 200
    )
  end
end
