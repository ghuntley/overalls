# @cc [owner:ghuntley,label:verification] zfs-native-runtime-evidence
# This fixture MUST use the source-built Lilly release and real mounted ZFS datasets.
# It checks observation and unit-inventory primitives only; synthetic unit IDs
# MUST NOT establish durable VM ownership or admission.
# Local compression diagnostics MUST retain their observed values for the native
# assertions, independently of the production wire encoder that omits them.
alias Lilly.Host.{Command, Lock, ZFS}
alias OverallsProtocol.Storage

# Lilly runs every zfs utility through the private lilly-hostd this BEAM spawns.
# hostd inherits PATH, so the observation-fault wrapper is found first, but it
# does not pass ZFS_OBSERVATION_FAULT to utilities. The fault mode therefore
# travels through the file the wrapper reads; an unset mode clears that file so
# a stale fault cannot apply to a later check.
case System.get_env("ZFS_OBSERVATION_FAULT") do
  nil ->
    File.rm("/run/zfs-observation-fault-mode")

  mode ->
    File.write!("/run/zfs-observation-fault-mode", mode)
    System.put_env("PATH", "/run/zfs-changing/bin:" <> System.fetch_env!("PATH"))
    "/run/zfs-changing/bin/zfs" = System.find_executable("zfs")
end

action = System.fetch_env!("ZFS_CHECK")
path = System.get_env("ZFS_PATH", "/pool")
read_identity = fn ->
  value = File.read!("/run/zfs-identity") |> JSON.decode!()
  {:ok, storage} = Storage.identity(value["storage"])
  %{
    path: value["path"], filesystem_id: value["filesystem_id"], storage: storage,
    extents: Enum.map(value["extents"], fn extent ->
      %{backing_device: extent["backing_device"], start_sector: extent["start_sector"], sectors: extent["sectors"]}
    end)
  }
end

# Synthetic test expectations exercise the accounting boundary only. Production
# callers must obtain these bindings from verified host-local ownership records.
read_snapshot_bindings = fn ->
  File.read!("/run/zfs-snapshot-bindings") |> JSON.decode!()
  |> Map.new(fn {name, value} ->
    {name, %{dataset_guid: value["dataset_guid"], snapshot_guid: value["snapshot_guid"]}}
  end)
end

case action do
  action when action in ["tracked-units", "reject-units"] ->
    commands =
      File.read!("/run/tracked-unit-ids")
      |> JSON.decode!()
      |> Enum.map(&%{placement_id: &1})

    case {action, Lilly.Host.Ownership.verify_units(commands)} do
      {"tracked-units", :ok} -> :ok
      {"reject-units", {:error, :untracked_vm_units}} -> :ok
    end

  "headroom" ->
    alias Lilly.Host.{Inventory, Limits, Usage}
    {:ok, inventory} = Inventory.read()
    {:ok, limits} = Limits.read("/sys/fs/cgroup", "/sys/fs/cgroup/lilly.slice", inventory)
    {nil, previous} = Usage.sample("/sys/fs/cgroup", "/sys/fs/cgroup/lilly.slice", inventory, limits, nil, %{})
    Process.sleep(1000)
    {:ok, inventory} = Inventory.read()
    {usage, _} = Usage.sample("/sys/fs/cgroup", "/sys/fs/cgroup/lilly.slice", inventory, limits, previous, %{})
    true = is_map(usage)
    IO.puts(JSON.encode!(usage))

  "fixture" ->
    Code.require_file("/etc/zfs-fixture.exs")
    fixture = Lilly.ZFSFixture.create("tank", "/fixture", Lilly.UUID.generate())
    for key <- ["dataset_guid", "owner"] do
      wrong = Map.put(fixture, key, if(key == "owner", do: Lilly.UUID.generate(), else: "1"))
      rejected = try do
        Lilly.ZFSFixture.destroy(wrong)
        false
      rescue
        MatchError -> true
      end
      true = rejected
      {:ok, _} = ZFS.inspect_path("/fixture")
    end
    :ok = Lilly.ZFSFixture.destroy(fixture)
    {:error, _} = ZFS.inspect_path("/fixture")

  "remember" ->
    {:ok, identity} = ZFS.inspect_path(path)
    true = length(identity.extents) == 2
    true = identity.storage.backend == :zfs
    true = String.starts_with?(identity.filesystem_id, "zfs:")
    File.write!("/run/zfs-identity", JSON.encode!(%{identity | storage: Storage.encode(identity.storage)}))
    File.chmod!("/run/zfs-identity", 0o600)

  "reject-mount" ->
    {:error, :unsupported_zfs_pool} = ZFS.inspect_path(path)

  "tree-bytes" ->
    identity = read_identity.()
    {:ok, output} = Command.run(:zfs_list, ["-Hpr", "-t", "all", "-o", Enum.join(ZFS.properties(), ","), identity.storage.dataset])
    IO.puts(byte_size(output))

  action when action in ["observe", "observe-snapshots"] ->
    identity = read_identity.()
    snapshots = if action == "observe-snapshots", do: read_snapshot_bindings.(), else: %{}
    {:ok, lock} = Lock.acquire("/run/zfs-test-lock")

    try do
      {:ok, observation} = ZFS.observe(identity, snapshots)
      false = Map.has_key?(observation, :allocations)
      true = OverallsProtocol.Storage.coherent?(observation.storage, observation.total_bytes, observation.free_bytes)
      storage =
        observation.storage
        |> Storage.encode()
        |> Map.put("logical_used_bytes", observation.storage.logical_used_bytes)
        |> Map.put("compression_ratio", observation.storage.compression_ratio)

      IO.puts(JSON.encode!(%{observation | storage: storage}))
    after
      Lock.release(lock)
    end

  "reject-observation" ->
    identity = read_identity.()
    {:error, :incoherent_zfs_observation} = ZFS.observe(identity)

  "reject-snapshot-bindings" ->
    {:error, :incoherent_zfs_observation} = ZFS.observe(read_identity.(), read_snapshot_bindings.())

  # ADR-0163 decision 4: usage drift between the two exact reads is resampled,
  # not withheld; the latest coherent tree is the observation. A follow-up
  # observation of the now-quiet pool must agree, so a stale first read fails.
  "moving-observation" ->
    identity = read_identity.()
    {:ok, observation} = ZFS.observe(identity)
    {:ok, latest} = ZFS.observe(identity)
    true = observation.storage.used_bytes == latest.storage.used_bytes
    true = observation.free_bytes == latest.free_bytes
end
