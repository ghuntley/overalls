# @cc [owner:ghuntley,label:verification] zfs-io-real-collector
# This fixture MUST sample capacity through the source-built Collector and real
# native I/O independently through ZFSIO. Diagnostic counters MUST NOT enter the
# control report. Utility faults follow native identity binding and MUST NOT
# invent successful counters. Reload faults MUST actually export/import the pool.
defmodule Overalls.ZFSIOFixture do
  alias Lilly.Host.{Collector, Pool, PoolObserver, ZFS, ZFSIO}

  @type observation :: %{capacity: map(), io: map()}

  @spec sample() :: [observation()]
  def sample do
    if System.get_env("ZFS_IO_FAULT") do
      File.write!("/run/zfs-io-fault/mode", System.fetch_env!("ZFS_IO_FAULT"))
      System.put_env("PATH", "/run/zfs-io-fault/bin:" <> System.fetch_env!("PATH"))
    end

    pools =
      Enum.map(
        [
          {"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "/pool"},
          {"cccccccc-cccc-4ccc-8ccc-cccccccccccc", "/otherpool"}
        ],
        fn {id, path} ->
          {:ok, identity} = ZFS.inspect_path(path)

          {:ok, pool} =
            Pool.new(id, path, identity.filesystem_id,
              storage: OverallsProtocol.Storage.encode(identity.storage),
              host_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            )

          pool
        end
      )

    if System.get_env("ZFS_IO_FAULT") do
      System.put_env("PATH", "/run/zfs-io-fault/bin:" <> System.fetch_env!("PATH"))
      "/run/zfs-io-fault/bin/zpool" = System.find_executable("zpool")
    end

    # Collection takes pool entries from the background pool observer and never
    # reads a pool inline (contract pool-reads-do-not-delay-sample), so this
    # one-shot BEAM runs its own observer and samples once it has published a
    # measured entry for every pool.
    view = :zfs_io_fixture_pool_observer
    {:ok, _} = PoolObserver.start_link({pools, [view: view, interval_ms: 1000]})
    report = observed(pools, view, System.monotonic_time(:millisecond) + 30_000)
    encoded = OverallsProtocol.encode_report(report)
    {:ok, decoded} = OverallsProtocol.report(encoded)
    ^encoded = OverallsProtocol.encode_report(decoded)

    io =
      case ZFSIO.sample(pools) do
        {:ok, measured} -> measured
        {:error, :zfs_io_unavailable} -> Map.new(pools, &{&1.id, ZFSIO.unavailable(&1)})
      end

    Enum.map(report.pools, fn capacity ->
      false = Map.has_key?(capacity, :io)

      %{
        capacity: Map.take(capacity, [:id, :total_bytes, :free_bytes, :allocations]),
        io: Map.fetch!(io, capacity.id)
      }
    end)
  end

  @spec observed([Pool.t()], atom(), integer()) :: OverallsProtocol.report()
  defp observed(pools, view, until) do
    {:ok, report, _previous} =
      Collector.sample(pools, "/sys/fs/cgroup", nil, 1, [], %{}, %{}, view)

    cond do
      not Enum.any?(report.pools, &Map.get(&1, :busy, false)) ->
        report

      System.monotonic_time(:millisecond) >= until ->
        raise "pool observer published no measured entry before the fixture deadline"

      true ->
        Process.sleep(200)
        observed(pools, view, until)
    end
  end
end

IO.puts(JSON.encode!(Overalls.ZFSIOFixture.sample()))
