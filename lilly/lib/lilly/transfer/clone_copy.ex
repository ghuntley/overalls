defmodule Lilly.Transfer.CloneCopy do
  @moduledoc """
  Same-pool clone disks materialized by kernel copy offload from a privately
  mounted, GUID-verified capture snapshot (ADR-0145). The destination is an
  ordinary owned dataset bound to a local copy journal; adoption verifies that
  journal instead of receive lineage. Cross-pool and cross-host clones keep the
  send/receive path.
  """
  require Lilly.Events
  alias OverallsProtocol.DiskTransfer
  alias Lilly.Host.{Command, Lock, Pool, PrivateFiles, Storage, ZFSDataset}
  alias Lilly.Transfer.{CloneCopyJournal, SourceSnapshots}
  alias Lilly.VM.Spec

  @copy_timeout 600_000
  @type failure :: {:error, :clone_copy_unconfirmed}
  @type busy :: {:error, :storage_busy}

  @doc "A same-host, same-pool clone descriptor eligible for block copies."
  @spec same_pool?(map()) :: boolean()
  def same_pool?(%{purpose: :clone, source: source, destination: destination}),
    do: source.host_id == destination.host_id and source.pool_id == destination.pool_id

  def same_pool?(_), do: false

  @doc "Whether this placement already has copy history; such placements never switch modes."
  @spec history?(Pool.t(), DiskTransfer.descriptor()) :: boolean()
  def history?(pool, descriptor),
    do: File.exists?(Path.join(journal_directory(pool, descriptor), "copy.json"))

  # @cc [owner:ghuntley,label:concurrency;recovery] clone-copy-contention-stays-busy
  # When the pool lock is unavailable for copy/3's or adopt/2's locked
  # sections, they MUST return `{:error, :storage_busy}`, the closed contended
  # reason callers retry, never `clone_copy_unconfirmed`. A pool observation
  # can hold the lock for seconds, so contention is ordinary, not a fault.

  # @cc [owner:ghuntley,label:security;recovery] clone-copy-source-mount-private
  # copy/3 MUST run under the destination receive lock as mutation owner. The
  # capture snapshot MUST be verified (capture/2) and the journal and destination
  # claim bound under the pool lock before any byte is copied; the snapshot is
  # read only through a private read-only mount (never .zfs automounts under the
  # source placement), unmounted before completion, and re-verified before the
  # journal records completion. Bulk I/O runs outside the pool lock.
  @spec copy(Pool.t(), DiskTransfer.descriptor(), map()) :: {:ok, String.t()} | failure() | busy()
  def copy(pool, descriptor, wire) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, spec} <- destination_spec(descriptor),
         {:ok, stage} <- Storage.locked(pool, fn -> stage(pool, descriptor, wire, spec) end) do
      case stage do
        {:done, guid} ->
          {:ok, guid}

        {:copy, capture} ->
          mount = mount_path(descriptor)

          result =
            with :ok <- unmount(mount, capture.snapshot),
                 :ok <- mount_snapshot(capture.snapshot, mount),
                 {:ok, names} <- copy_files(pool, descriptor, spec, mount) do
              {:ok, names}
            end

          unmounted = unmount(mount, capture.snapshot)

          with {:ok, names} <- result,
               :ok <- unmounted,
               {:ok, guid} <-
                 Storage.locked(pool, fn -> complete(pool, descriptor, wire, spec, names) end) do
            {:ok, guid}
          else
            {:error, :storage_busy} = busy -> busy
            _ -> failure()
          end
      end
    else
      {:error, :storage_busy} = busy -> busy
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] clone-copy-adoption-verifies-journal
  # adopt/3 requires the pool lock path and MUST verify a copied journal whose bound
  # nonce and GUID equal the destination's verified ordinary claim, the expected
  # file set and the boot bundle before publishing drives and marking the disk
  # ready. Replays of an adopted copy only re-verify. It never creates a disk.
  @spec adopt(Pool.t(), DiskTransfer.descriptor()) :: :ok | failure() | busy()
  def adopt(pool, descriptor) do
    with {:ok, spec} <- destination_spec(descriptor),
         :ok <-
           Storage.locked(pool, fn ->
             directory = journal_directory(pool, descriptor)
             identity = pool.storage

             with {:ok, %{"phase" => phase} = journal} when phase in ["copied", "adopted"] <-
                    CloneCopyJournal.read(directory, descriptor, identity),
                  {:ok, owned} <- ZFSDataset.owned_identity(pool, spec),
                  true <-
                    owned.nonce == journal["nonce"] and
                      owned.dataset_guid == journal["dataset_guid"],
                  true <- Enum.all?(Map.keys(journal["files"]), &present?(pool, spec, &1)),
                  :ok <- publish(pool, spec, owned.state),
                  {:ok, _} <-
                    CloneCopyJournal.adopted(
                      directory,
                      descriptor,
                      identity,
                      journal["dataset_guid"]
                    ),
                  do: :ok,
                  else: (_ -> failure())
           end) do
      :ok
    else
      {:error, :storage_busy} = busy -> busy
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] clone-copy-cleanup-owned
  # cleanup_intent/2 requires current cancellation authority, launch and key
  # fences, the receive lock and the pool lock. It MUST retire the journal before
  # any native effect, release only its exact private snapshot mount, remove only
  # its own disk-set files and temporaries from an unpublished destination, then
  # destroy the destination through fenced ownership deletion and record retirement
  # against the exact bound GUID. Without a bound dataset it only proves absence.
  @spec cleanup_intent(Pool.t(), DiskTransfer.intent()) :: :ok | failure()
  def cleanup_intent(pool, intent) do
    with {:ok, descriptor} <- journal_descriptor(pool, intent),
         {:ok, spec} <- destination_spec(descriptor),
         directory = journal_directory(pool, descriptor),
         {:ok, journal} <- CloneCopyJournal.retire(directory, descriptor, pool.storage),
         :ok <- unmount(mount_path(descriptor), source_snapshot(pool, descriptor)),
         :ok <- remove_unpublished(pool, spec, journal),
         :ok <- delete_destination(pool, spec, journal),
         {:ok, _} <-
           CloneCopyJournal.deleted(directory, descriptor, pool.storage, journal["dataset_guid"]) do
      :ok
    else
      _ -> failure()
    end
  end

  @doc "Release a stale private capture mount before source snapshots are pruned."
  @spec release_source_mount(Pool.t(), DiskTransfer.intent()) :: :ok | :error
  def release_source_mount(pool, intent),
    do: unmount(mount_path(intent), source_snapshot(pool, intent))

  defp journal_descriptor(pool, intent) do
    path = Path.join(journal_directory(pool, intent), "copy.json")

    with {:ok, bytes} <- PrivateFiles.read_secret(path),
         {:ok, %{"binding" => bound, "snapshot_guid" => snapshot}} <-
           Lilly.Lifecycle.Journal.decode(bytes),
         stream = %{"source_dataset_guid" => bound["source_dataset_guid"], "to_guid" => snapshot},
         {:ok, descriptor} <-
           bound
           |> Map.drop(["local_storage", "source_dataset_guid"])
           |> Map.put("stream", stream)
           |> DiskTransfer.descriptor(),
         true <- Map.delete(descriptor, :stream) == intent,
         do: {:ok, descriptor},
         else: (_ -> failure())
  end

  # Unpublished copies may hold a partial disk set that ordinary deletion's
  # allowlist would refuse; remove only the fixed copy files and temporaries.
  defp remove_unpublished(pool, spec, %{"dataset_guid" => guid} = journal)
       when is_binary(guid) do
    case ZFSDataset.owned_identity(pool, spec) do
      {:ok, %{state: "bound", dataset_guid: ^guid}} ->
        target = ZFSDataset.directory(pool, spec)

        Enum.reduce_while(CloneCopyJournal.disk_files(), :ok, fn name, :ok ->
          with :ok <- remove_regular(Path.join(target, ".clone-" <> name)),
               :ok <- remove_regular(Path.join(target, name)) do
            {:cont, :ok}
          else
            _ -> {:halt, :error}
          end
        end)

      {:ok, %{state: "ready"}} ->
        if journal["phase"] in ["retiring", "retired"], do: :ok, else: :error

      _ ->
        :ok
    end
  end

  defp remove_unpublished(_, _, _), do: :ok

  defp delete_destination(pool, spec, %{"dataset_guid" => guid}) when is_binary(guid) do
    case ZFSDataset.delete(pool, spec) do
      :ok -> :ok
      _ -> :error
    end
  end

  defp delete_destination(pool, spec, _) do
    with :ok <- ZFSDataset.bind(pool),
         :ok <- Lilly.Host.ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec)),
         do: :ok,
         else: (_ -> :error)
  end

  defp source_snapshot(pool, intent),
    do: pool.storage.dataset <> "/vm-" <> intent.source.placement_id <> "@lilly-b"

  @doc "Private read-only mount point for one clone's capture snapshot."
  @spec mount_path(DiskTransfer.descriptor()) :: Path.t()
  def mount_path(descriptor),
    do: Path.join(["/run/lilly-clone-copies", descriptor.relocation_id])

  defp stage(pool, descriptor, wire, spec) do
    directory = journal_directory(pool, descriptor)
    identity = pool.storage

    with {:ok, capture} <- SourceSnapshots.capture(pool, wire),
         true <- capture.to_guid == descriptor.stream.to_guid,
         {:ok, journal} <- CloneCopyJournal.prepare(directory, descriptor, identity) do
      if journal["phase"] in ["copied", "adopted"] do
        {:ok, {:done, journal["dataset_guid"]}}
      else
        with :ok <- ZFSDataset.prepare(pool, spec),
             {:ok, owned} <- ZFSDataset.owned_identity(pool, spec),
             {:ok, _} <-
               CloneCopyJournal.bind(
                 directory,
                 descriptor,
                 identity,
                 owned.nonce,
                 owned.dataset_guid
               ),
             do: {:ok, {:copy, capture}}
      end
    else
      _ -> failure()
    end
  end

  defp complete(pool, descriptor, wire, _spec, names) do
    directory = journal_directory(pool, descriptor)
    identity = pool.storage

    with {:ok, capture} <- SourceSnapshots.capture(pool, wire),
         true <- capture.to_guid == descriptor.stream.to_guid,
         {:ok, journal} <- CloneCopyJournal.read(directory, descriptor, identity),
         {:ok, _} <-
           CloneCopyJournal.copied(
             directory,
             descriptor,
             identity,
             journal["dataset_guid"],
             names
           ) do
      {:ok, journal["dataset_guid"]}
    else
      _ -> failure()
    end
  end

  defp copy_files(pool, descriptor, spec, mount) do
    directory = journal_directory(pool, descriptor)
    identity = pool.storage
    target = ZFSDataset.directory(pool, spec)

    with {:ok, %{"files" => recorded}} <- CloneCopyJournal.read(directory, descriptor, identity),
         {:ok, names} <- source_names(mount) do
      Enum.reduce_while(names, {:ok, names}, fn name, acc ->
        if Map.has_key?(recorded, name) and present?(pool, spec, name) do
          {:cont, acc}
        else
          case copy_file(directory, descriptor, identity, mount, target, name) do
            :ok -> {:cont, acc}
            _ -> {:halt, failure()}
          end
        end
      end)
    else
      _ -> failure()
    end
  end

  # Only the fixed disk set present in the source snapshot is copied; anything
  # else in the source dataset is refused rather than silently skipped.
  defp source_names(mount) do
    with {:ok, names} <- File.ls(mount),
         true <- Enum.all?(names, &(&1 in CloneCopyJournal.disk_files())),
         true <- "rootfs.ext4" in names,
         do: {:ok, Enum.sort(names)},
         else: (_ -> failure())
  end

  # lilly-image-copy writes the copy as root. A source file the unprivileged
  # BEAM owned (its own metadata, ADR-0182) is handed back to that service
  # uid; guest-owned drives are rebound later by adoption, as before.
  defp own_like_source(path, uid) do
    if uid != 0 and uid == Lilly.Host.Privilege.service_uid() do
      case Command.run(:chown, ["#{uid}:#{uid}", "--", path]) do
        {:ok, _} -> :ok
        _ -> :error
      end
    else
      :ok
    end
  end

  # @cc [owner:ghuntley,label:recovery] clone-copy-durable
  # durable_copy/3 MUST run a clone file copy as a durable hostd job keyed by
  # its exact arguments (source, temporary, size, owner uid), so a copy in
  # flight survives a Lilly restart. It MUST attach to a known job before
  # touching the temporary or destination file, and remove them only when
  # hostd knows no job for the key.
  defp durable_copy(temporary, destination, arguments) do
    key = :crypto.hash(:sha256, Enum.join(["clone-copy" | arguments], <<0>>))

    case Command.attach(key, 120_000) do
      {:error, :job_unknown} ->
        with :ok <- remove_regular(temporary),
             :ok <- remove_regular(destination),
             do: Command.run_durable(:image_copy, arguments, @copy_timeout, key)

      {:error, :job_running} ->
        durable_copy(temporary, destination, arguments)

      # A finished result whose temporary file was already published or
      # removed belongs to an earlier attempt: copy again.
      {:ok, _} = result ->
        case File.lstat(temporary) do
          {:ok, %File.Stat{type: :regular}} ->
            result

          _ ->
            with :ok <- remove_regular(destination),
                 do: Command.run_durable(:image_copy, arguments, @copy_timeout, key)
        end

      result ->
        result
    end
  end

  defp copy_file(directory, descriptor, identity, mount, target, name) do
    source = Path.join(mount, name)
    temporary = Path.join(target, ".clone-" <> name)
    destination = Path.join(target, name)

    started = System.monotonic_time(:millisecond)

    with {:ok, before} <- File.lstat(source, time: :posix),
         true <- before.type == :regular,
         arguments = [
           "snapshot",
           source,
           temporary,
           Integer.to_string(before.size),
           Integer.to_string(before.uid)
         ],
         {:ok, method} <- durable_copy(temporary, destination, arguments),
         true <- method in ["copy\n", "offload\n", "reflink\n"],
         {:ok, ^before} <- File.lstat(source, time: :posix),
         :ok <- own_like_source(temporary, before.uid),
         :ok <- Lilly.Host.Privilege.chmod(temporary, mode(name)),
         {:ok, _} <- Command.run(:mv, ["--no-target-directory", "--", temporary, destination]),
         {:ok, _} <-
           CloneCopyJournal.file_copied(
             directory,
             descriptor,
             identity,
             name,
             before.size,
             stat_identity(before)
           ) do
      Lilly.Events.emit("vm.disk_materialization_step",
        vm_id: descriptor.destination.placement_id,
        utility: :image_copy,
        duration_ms: System.monotonic_time(:millisecond) - started
      )

      :ok
    else
      _ -> failure()
    end
  end

  defp publish(_pool, _spec, "ready"), do: :ok

  defp publish(pool, spec, "bound") do
    metadata = ZFSDataset.metadata_directory(pool, spec)

    with :ok <- ZFSDataset.publish_owned_drives(pool, spec),
         :ok <- PrivateFiles.write(metadata, "disk.json", JSON.encode!(Spec.encode(spec))),
         :ok <- PrivateFiles.write(metadata, "disk-ready.json", JSON.encode!(Spec.encode(spec))),
         :ok <- ZFSDataset.ready(pool, spec),
         do: :ok,
         else: (_ -> :error)
  end

  defp present?(pool, spec, name) do
    match?(
      {:ok, %File.Stat{type: :regular, links: 1}},
      File.lstat(Path.join(ZFSDataset.directory(pool, spec), name))
    )
  end

  defp mode(name) when name in ["kernel", "initrd", "firmware"], do: 0o444
  defp mode(_), do: 0o600

  defp remove_regular(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, links: 1}} ->
        File.rm(path)

      _ ->
        :error
    end
  end

  # Device-independent identity: inode, size, mode, uid, gid, links and posix
  # timestamps; the device number changes across private remounts.
  defp stat_identity(stat) do
    [
      stat.inode,
      stat.size,
      stat.mode,
      stat.uid,
      stat.gid,
      stat.links,
      stat.mtime,
      stat.ctime,
      0,
      0
    ]
  end

  defp mount_snapshot(snapshot, mount) do
    with :ok <- PrivateFiles.directory(Path.dirname(mount)),
         :ok <- PrivateFiles.directory(mount),
         {:ok, _} <-
           Command.run(
             :mount,
             ["-t", "zfs", "-o", "ro,nodev,nosuid,noexec", snapshot, mount],
             30_000
           ),
         do: :ok,
         else: (_ -> :error)
  end

  # @cc [owner:ghuntley,label:security;recovery] clone-copy-unmount-exact-source
  # Only a mount at the exact private path whose source is the exact capture
  # snapshot may be unmounted; any other mount there fails closed.
  defp unmount(mount, snapshot) do
    with {:ok, mounts} <- Lilly.Host.MountTable.read() do
      case Enum.filter(mounts, &(&1["target"] == mount)) do
        [] ->
          :ok

        [%{"source" => ^snapshot}] ->
          case Command.run(:umount, ["--", mount], 30_000) do
            {:ok, _} -> :ok
            _ -> :error
          end

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp journal_directory(pool, descriptor),
    do: CloneCopyJournal.directory(pool.path, descriptor.destination.placement_id)

  defp destination_spec(descriptor),
    do:
      descriptor.workload
      |> Map.drop([:architecture])
      |> Map.merge(%{
        id: descriptor.destination.placement_id,
        pool_id: descriptor.destination.pool_id
      })
      |> Spec.new()

  defp failure, do: {:error, :clone_copy_unconfirmed}
end
