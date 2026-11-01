# @cc [owner:ghuntley,label:verification] owned-zfs-lifecycle-real-artifacts
# This fixture MUST invoke actual Lilly disk/ownership APIs and the verified source-built guest
# image. It MUST NOT fake ZFS or count low-level disk calls as VMM/crash-durability acceptance.
alias Lilly.Host.{Image, ImageTemplate, Pool, ZFS}
alias Lilly.Transfer.SourceSnapshots
alias Lilly.VM.{Disk, Spec}

defmodule ZFSLifecycleFixture do
  # @cc [owner:ghuntley,label:verification] lifecycle-retries-only-storage-busy
  # Normal preparation MAY retry only storage_busy within a fixed deadline, preserving the
  # same spec and disk state. Deliberate busy/rejection probes MUST remain single attempts.
  @spec prepare(Pool.t(), Image.t(), Spec.t(), integer()) :: :ok | {:error, atom()}
  def prepare(pool, image, spec, deadline) do
    case Disk.prepare(pool, image, spec) do
      {:error, :storage_busy} = result ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          prepare(pool, image, spec, deadline)
        else
          result
        end

      result ->
        result
    end
  end

  # The observation fault reads its mode from a file because the lazily spawned
  # lilly-hostd clears every variable but PATH. The mode exists only while the
  # observed action runs, so no earlier or later recursive list meets it.
  @spec observed((-> result)) :: result when result: term()
  def observed(action) do
    case System.get_env("ZFS_OBSERVATION_FAULT") do
      nil ->
        action.()

      mode ->
        File.write!("/run/zfs-observation-fault-mode", mode)

        try do
          action.()
        after
          File.rm("/run/zfs-observation-fault-mode")
        end
    end
  end
end

# The Nix release launcher prepends coreutils to PATH. Install the fault boundary
# inside the isolated evaluator so the real copy is intercepted too.
if System.get_env("ZFS_FAULT") == "1" do
  System.put_env("PATH", "/run/zfs-fault/bin:" <> System.fetch_env!("PATH"))
  "/run/zfs-fault/bin/lilly-image-copy" = System.find_executable("lilly-image-copy")
  "/run/zfs-fault/bin/zfs" = System.find_executable("zfs")
end

# Lilly runs zfs through the private lilly-hostd this BEAM spawns lazily, which
# inherits PATH but not ZFS_OBSERVATION_FAULT, so the wrapper goes on PATH before
# the first utility runs and reads its mode from a file (as in the native-zfs
# probe). The mode is written only just before the observed action: a recursive
# list earlier would meet no mode, fail, and expose a misplaced fault.
if System.get_env("ZFS_OBSERVATION_FAULT") do
  System.put_env("PATH", "/run/zfs-changing/bin:" <> System.fetch_env!("PATH"))
  "/run/zfs-changing/bin/zfs" = System.find_executable("zfs")
end

action = System.fetch_env!("ZFS_ACTION")
number = System.get_env("ZFS_VM", "1") |> String.to_integer()
id = "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(number), 12, "0")
pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
host_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
{:ok, identity} = ZFS.inspect_path("/pool")

{:ok, pool} =
  Pool.new(pool_id, "/pool", identity.filesystem_id,
    storage: OverallsProtocol.Storage.encode(identity.storage),
    host_id: host_id
  )

image_path = System.fetch_env!("ZFS_GUEST_IMAGE")
# Read-only/cleanup probes need only the immutable workload descriptor. Full
# artifact hashing still occurs for every preparation and inside Disk.prepare;
# repeating it for snapshot/delete would test catalog I/O rather than storage.
manifest_bytes = File.read!(Path.join(image_path, "manifest.json"))
true = byte_size(manifest_bytes) <= 16_384
{:ok, manifest} = OverallsProtocol.ImageManifest.validate(JSON.decode!(manifest_bytes))
{:ok, _placement_lock} = Lilly.Host.Lock.acquire("/run/zfs-lifecycle-placement-" <> id)

{:ok, spec} =
  Spec.new(%{
    id: id,
    image_id: manifest.id,
    pool_id: pool_id,
    profile: :customer,
    slot: number + 2,
    vcpu: 1,
    memory_bytes: max(512, div(manifest.minimum_memory_bytes + 1_048_575, 1_048_576)) * 1_048_576,
    # Image growth MUST remain a valid native storage fixture, rather than
    # bypassing its intended observation fault through an undersized request.
    disk_bytes:
      max(2, div(manifest.minimum_disk_bytes + 1_073_741_823, 1_073_741_824)) * 1_073_741_824
  })

relocation = System.get_env("ZFS_RELOCATION", "ffffffff-ffff-4fff-8fff-000000000001")
epoch = System.get_env("ZFS_SOURCE_EPOCH", "1") |> String.to_integer()

case action do
  "disk-size" ->
    IO.puts(spec.disk_bytes)

  action
  when action in [
         "permit-issue",
         "reject-permit-issue",
         "permit-fence",
         "permit-lookup",
         "reject-permit-lookup"
       ] ->
    root = "/run/source-permits"

    case File.mkdir(root) do
      :ok -> File.chmod!(root, 0o700)
      {:error, :eexist} -> :ok
    end

    wire = File.read!("/run/export-descriptor.json") |> JSON.decode!()
    public = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
    now = System.system_time(:second)
    revision = System.get_env("PERMIT_REVISION", "1") |> String.to_integer()

    cond do
      action == "permit-fence" ->
        :ok = Lilly.Transfer.PermitJournal.fence(root, host_id, wire["relocation_id"])

      action in ["permit-lookup", "reject-permit-lookup"] ->
        result =
          Lilly.Transfer.PermitJournal.lookup(root, host_id, wire["relocation_id"], public, now)

        if action == "permit-lookup", do: {:ok, _} = result, else: {:error, _} = result

      true ->
        result =
          Lilly.Host.Storage.locked(pool, fn ->
            Lilly.Transfer.Permit.issue(root, pool, wire, public, revision, now + 300)
          end)

        if action == "permit-issue", do: :ok = result, else: {:error, _} = result
    end

  action when action in ["export-descriptor", "export", "reject-export"] ->
    path = "/run/export-descriptor.json"

    if action == "export-descriptor" do
      dataset = Lilly.Host.ZFSDataset.name(pool, spec)
      {:ok, entries} = ZFS.owners(Pool.zfs_identity(pool))

      wire = %{
        "version" => 3,
        "relocation_id" => relocation,
        "vm_id" => "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        "source" => %{"host_id" => host_id, "pool_id" => pool_id, "placement_id" => id},
        "destination" => %{
          "host_id" => "aaaaaaaa-aaaa-4aaa-8aaa-000000000002",
          "pool_id" => "bbbbbbbb-bbbb-4bbb-8bbb-000000000002",
          "placement_id" => "dddddddd-dddd-4ddd-8ddd-000000000099"
        },
        "source_epoch" => epoch,
        "destination_epoch" => epoch + 1,
        "workload" =>
          Map.drop(Spec.encode(spec), ["id", "pool_id"]) |> Map.put("architecture", "x86_64"),
        "stream" => %{
          "source_dataset_guid" => entries[dataset]["guid"],
          "to_guid" => entries[dataset <> "@lilly-b"]["guid"]
        }
      }

      {:ok, _} = OverallsProtocol.Relocation.descriptor(wire)
      File.write!(path, JSON.encode!(wire))
    else
      wire = File.read!(path) |> JSON.decode!()
      result = Lilly.Host.Storage.locked(pool, fn -> SourceSnapshots.export(pool, wire) end)

      if action == "reject-export" do
        {:error, _} = result
      else
        # The root export worker's argv streams; Lilly hosts name the same
        # lineage to hostd by typed fields only (ADR-0183).
        {:ok, {executable, args}} = result

        {:ok, {:local_send, %{placement: _}}} =
          Lilly.Host.Storage.locked(pool, fn -> SourceSnapshots.local_producer(pool, wire) end)

        {_, 0} =
          System.cmd("/bin/sh", ["-c", ~s("$0" "$@" > /dev/null), executable | args],
            stderr_to_stdout: true
          )
      end
    end

  action when action in ["transfer-final", "reject-transfer-final"] ->
    result =
      Lilly.Host.Storage.locked(pool, fn ->
        SourceSnapshots.create(pool, spec, relocation, epoch)
      end)

    if String.starts_with?(action, "reject-"), do: {:error, _} = result, else: {:ok, _} = result

  action when action in ["transfer-cleanup", "reject-transfer-cleanup"] ->
    result =
      Lilly.Host.Storage.locked(pool, fn ->
        SourceSnapshots.cleanup(pool, spec, relocation, epoch)
      end)

    if String.starts_with?(action, "reject-"), do: {:error, _} = result, else: :ok = result

  "prepare" ->
    {:ok, image} = Image.load(image_path)

    :ok =
      ZFSLifecycleFixture.prepare(pool, image, spec, System.monotonic_time(:millisecond) + 60_000)

  # Usage drift between the two exact reads is resampled and the latest coherent
  # tree is the observation (ADR-0163 decision 4, contract
  # zfs-bounded-resampling-no-credit), so a preparation under moving usage
  # succeeds in one attempt.
  "moving-prepare" ->
    {:ok, image} = Image.load(image_path)
    :ok = ZFSLifecycleFixture.observed(fn -> Disk.prepare(pool, image, spec) end)

  "warm-template" ->
    {:ok, image} = Image.load(image_path)
    :ok = ImageTemplate.ensure(pool, image)

  "reject-prepare" ->
    {:ok, image} = Image.load(image_path)
    {:error, _} = Disk.prepare(pool, image, spec)

  "delete" ->
    :ok = ZFSLifecycleFixture.observed(fn -> Disk.delete(pool, spec) end)
    {:error, :enoent} = File.lstat(Lilly.Host.ZFSDataset.directory(pool, spec))

  "reject-delete" ->
    {:error, _} = ZFSLifecycleFixture.observed(fn -> Disk.delete(pool, spec) end)

  "reject-ready" ->
    {:error, _} = Disk.ready(pool, spec)

  action when action in ["credit", "no-credit"] ->
    {:ok, observation} = Pool.snapshot(pool)
    credit = Map.get(observation.allocations, spec.id)

    if action == "credit",
      do: true = is_integer(credit) and credit > 0,
      else: true = is_nil(credit)

  "snapshot" ->
    {:ok, observation} = Pool.snapshot(pool)

    IO.puts(
      JSON.encode!(%{observation | storage: OverallsProtocol.Storage.encode(observation.storage)})
    )

  "reject-snapshot" ->
    {:error, _} = Pool.snapshot(pool)
end
