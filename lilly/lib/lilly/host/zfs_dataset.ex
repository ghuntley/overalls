defmodule Lilly.Host.ZFSDataset do
  @moduledoc "Durable ownership of per-placement datasets; claims and tombstones live outside the child being destroyed."
  require Lilly.Events

  alias Lilly.Host.{
    Command,
    Lock,
    Pool,
    PoolSnapshot,
    PrivateFiles,
    ZFS,
    ZFSNamespaceMounts
  }

  alias Lilly.VM.{Jail, Spec, WorkloadBundle}
  alias OverallsProtocol.Storage
  alias Lilly.Transfer.{ImportJournal, ReceivedDataset, SnapshotOwnership}

  @type readiness_stage ::
          :dataset_identity
          | :dataset_ownership
          | :snapshot_ownership
          | :accounting
          | :mounts
          | :disk_metadata
          | :boot_bundle

  @states ~w(creating bound ready deleting deleted importing import-pruned import-publishing import-deleting)

  # @cc [owner:ghuntley,label:recovery;security] imported-claim-cleanup-fence
  # fence_import_cleanup/3 requires the pool lock and validated local import
  # journal. It MUST reject an unrelated ordinary claim, preserve the exact local
  # nonce/GUID/spec binding, and fence adopted or partially adopted claims against
  # preparation before destructive cleanup. Missing claims grant staging-only
  # policy; deleted claims grant absence verification only, never new destruction.
  @spec fence_import_cleanup(Pool.t(), Spec.t(), ImportJournal.journal() | nil) ::
          {:ok, :staging | :adoption | :absent} | {:error, :import_claim_unconfirmed}
  def fence_import_cleanup(pool, spec, journal) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, record, location} <- cleanup_claim(pool, spec, journal) do
      cond do
        is_nil(record) ->
          {:ok, :staging}

        location == :retired or record["state"] == "deleted" ->
          {:ok, :absent}

        true ->
          with :ok <- save(pool, spec, %{record | "state" => "import-deleting"}),
               do: {:ok, :adoption},
               else: (_ -> {:error, :import_claim_unconfirmed})
      end
    else
      _ -> {:error, :import_claim_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:recovery] imported-claim-tombstone-after-absence
  # finish_import_cleanup/3 MUST confirm native/mount absence before retiring an
  # exact import-deleting claim. Tombstones live outside the child, survive retries
  # and MUST NOT be removed or reused for new provisioning.
  @spec finish_import_cleanup(Pool.t(), Spec.t(), ImportJournal.journal()) ::
          :ok | {:error, :import_claim_unconfirmed}
  def finish_import_cleanup(pool, spec, journal) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         :ok <- ZFS.absent_child(Pool.zfs_identity(pool), name(pool, spec)),
         {:ok, record, location} <- cleanup_claim(pool, spec, journal) do
      if is_nil(record) or location == :retired do
        :ok
      else
        with true <- record["state"] in ~w(import-deleting deleted),
             :ok <- save(pool, spec, %{record | "state" => "deleted"}),
             {:ok, _} <-
               Command.run(:mv, [
                 "--no-target-directory",
                 "--",
                 metadata_directory(pool, spec),
                 Path.join(retired(pool), spec.id)
               ]),
             {:ok, _} <- Command.run(:sync, ["--", active(pool), retired(pool)]),
             do: :ok,
             else: (_ -> {:error, :import_claim_unconfirmed})
      end
    else
      _ -> {:error, :import_claim_unconfirmed}
    end
  end

  defp cleanup_claim(pool, spec, journal) do
    live = Path.join(metadata_directory(pool, spec), "claim.json")
    dead = Path.join([retired(pool), spec.id, "claim.json"])

    case {Lilly.Host.Privilege.lstat(live), Lilly.Host.Privilege.lstat(dead)} do
      {{:error, :enoent}, {:error, :enoent}} ->
        with {:error, :enoent} <- Lilly.Host.Privilege.lstat(metadata_directory(pool, spec)),
             {:error, :enoent} <- Lilly.Host.Privilege.lstat(Path.join(retired(pool), spec.id)),
             do: {:ok, nil, :absent}

      {{:ok, _}, {:error, :enoent}} ->
        with {:error, :enoent} <- Lilly.Host.Privilege.lstat(Path.join(retired(pool), spec.id)),
             do: bound_cleanup_claim(live, pool, spec, journal, :active)

      {{:error, :enoent}, {:ok, _}} ->
        with {:error, :enoent} <- Lilly.Host.Privilege.lstat(metadata_directory(pool, spec)),
             do: bound_cleanup_claim(dead, pool, spec, journal, :retired)

      _ ->
        :error
    end
  end

  defp bound_cleanup_claim(path, pool, spec, journal, location) when is_map(journal) do
    with {:ok, record, ^location} <- load_claim(path, pool, spec, location),
         true <-
           record["state"] in ~w(importing import-pruned import-publishing ready import-deleting deleted),
         true <-
           record["nonce"] == journal["nonce"] and
             record["dataset_guid"] == journal["dataset_guid"],
         do: {:ok, record, location}
  end

  defp bound_cleanup_claim(_, _, _, _, _), do: :error

  # @cc [owner:ghuntley,label:security;recovery] import-adoption-never-materializes-a-blank-disk
  # adopt/3 requires current destination authority, a complete portable workload
  # bundle, the destination pool lock and quiescent streams/VMMs. Only a verified final
  # receipt may create an importing claim. Persisted import states MUST precede
  # snapshot destruction and policy changes, reject ordinary preparation, and bind
  # all retries to the original local nonce/GUID. Readiness MUST require the exact
  # profile-derived drive and portable boot-bundle set, each artifact shape, and
  # destination-local disk metadata. No path may copy, truncate or recreate imported data.
  # Adoption alone grants no launch or source deletion authority.
  @spec adopt(Pool.t(), Spec.t(), OverallsProtocol.DiskTransfer.descriptor()) ::
          :ok | {:error, atom()}
  def adopt(pool, spec, descriptor) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, %{"phase" => "active", "stream_state" => "received"} = journal} <-
           ImportJournal.read(ReceivedDataset.directory(pool, spec.id), descriptor, pool.storage),
         true <-
           descriptor.destination == %{
             placement_id: spec.id,
             host_id: pool.host_id,
             pool_id: pool.id
           },
         true <-
           journal["stream"] ==
             OverallsProtocol.DiskTransfer.encode_descriptor(descriptor)["stream"],
         {:ok, workload} <-
           descriptor.workload
           |> Map.drop([:architecture])
           |> Map.merge(%{id: spec.id, pool_id: pool.id})
           |> Spec.new(),
         true <- workload == Spec.storage(spec),
         :ok <- bind(pool),
         {:error, :enoent} <- Lilly.Host.Privilege.lstat(Path.join(retired(pool), spec.id)),
         {:ok, record} <- import_claim(pool, spec, descriptor, journal),
         :ok <- continue_import(pool, spec, descriptor, journal, record) do
      :ok
    else
      _ ->
        Lilly.Events.emit("lilly.zfs_import_adoption_unconfirmed", placement_id: spec.id)
        {:error, :zfs_import_adoption_unconfirmed}
    end
  end

  defp import_claim(pool, spec, descriptor, journal) do
    path = Path.join(metadata_directory(pool, spec), "claim.json")

    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} ->
        with {:error, :enoent} <- Lilly.Host.Privilege.lstat(metadata_directory(pool, spec)),
             {:ok, ^journal} <- ReceivedDataset.verify(pool, descriptor),
             staging = Path.join(ReceivedDataset.directory(pool, spec.id), "disk-claim"),
             :ok <- PrivateFiles.directory(staging),
             record = %{
               "version" => 1,
               "binding" => binding(pool, spec),
               "nonce" => journal["nonce"],
               "dataset_guid" => journal["dataset_guid"],
               "state" => "importing"
             },
             true <-
               Lilly.Host.Privilege.lstat(Path.join(staging, "claim.json")) == {:error, :enoent} or
                 read_json(Path.join(staging, "claim.json")) == {:ok, record},
             :ok <-
               Lilly.Lifecycle.Journal.write(
                 Lilly.Lifecycle.Dataset,
                 staging,
                 "claim.json",
                 record
               ),
             {:ok, _} <-
               Command.run(:mv, [
                 "--no-target-directory",
                 "--",
                 staging,
                 metadata_directory(pool, spec)
               ]),
             {:ok, _} <- Command.run(:sync, ["--", Path.dirname(staging), active(pool)]) do
          {:ok, record}
        end

      {:ok, _} ->
        with {:ok, record, :active} <- load_claim(path, pool, spec, :active),
             true <- record["state"] in ~w(importing import-pruned import-publishing ready),
             true <-
               record["nonce"] == journal["nonce"] and
                 record["dataset_guid"] == journal["dataset_guid"],
             do: {:ok, record}

      _ ->
        :error
    end
  end

  defp continue_import(pool, spec, descriptor, journal, %{"state" => "importing"} = record) do
    with {:ok, retained, :unmounted} <- inspect_import(pool, spec, descriptor, journal, :pruning),
         :ok <- prune_received_snapshot(name(pool, spec), retained),
         {:ok, empty, :unmounted} when map_size(empty) == 0 <-
           inspect_import(pool, spec, descriptor, journal, :pruning),
         next = %{record | "state" => "import-pruned"},
         :ok <- save(pool, spec, next),
         do: continue_import(pool, spec, descriptor, journal, next)
  end

  defp continue_import(pool, spec, descriptor, journal, %{"state" => "import-pruned"} = record) do
    with {:ok, _, mounted} <- inspect_import(pool, spec, descriptor, journal, :mounting),
         :ok <- mount_import(pool, spec, mounted),
         {:ok, _, :mounted} <- inspect_import(pool, spec, descriptor, journal, :mounting),
         true <- import_disk_shape?(pool, spec, descriptor),
         next = %{record | "state" => "import-publishing"},
         :ok <- save(pool, spec, next),
         do: continue_import(pool, spec, descriptor, journal, next)
  end

  defp continue_import(
         pool,
         spec,
         descriptor,
         journal,
         %{"state" => "import-publishing"} = record
       ) do
    with {:ok, _, mounted} <- inspect_import(pool, spec, descriptor, journal, :publishing),
         :ok <- mount_import(pool, spec, mounted),
         {:ok, _, :mounted} <- inspect_import(pool, spec, descriptor, journal, :publishing),
         true <- import_disk_shape?(pool, spec, descriptor),
         {:ok, _} <-
           Command.run(:zfs_set, ["readonly=off", "canmount=on", name(pool, spec)], 30_000),
         :ok <- Lilly.Host.Privilege.claim_directory(directory(pool, spec)),
         :ok <- PrivateFiles.directory(directory(pool, spec)),
         :ok <- publish_drives(pool, spec),
         :ok <-
           PrivateFiles.write(
             metadata_directory(pool, spec),
             "disk.json",
             JSON.encode!(Spec.encode(spec))
           ),
         :ok <-
           PrivateFiles.write(
             metadata_directory(pool, spec),
             "disk-ready.json",
             JSON.encode!(Spec.encode(spec))
           ),
         true <- ready_disk?(pool, spec),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             name(pool, spec),
             record["dataset_guid"],
             %{}
           ),
         next = %{record | "state" => "ready"},
         :ok <- save(pool, spec, next),
         do: continue_import(pool, spec, descriptor, journal, next)
  end

  defp continue_import(pool, spec, _descriptor, journal, %{"state" => "ready"} = record) do
    with true <- ReceivedDataset.local_owner?(pool, spec.id, journal["nonce"]),
         true <- import_disk_shape?(pool, spec) and ready_disk?(pool, spec),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             name(pool, spec),
             record["dataset_guid"],
             %{}
           ),
         {:ok, mounts} <- ZFS.mounts(),
         true <- mounts_valid?(mounts, pool, spec, :present, false),
         do: :ok
  end

  defp prune_received_snapshot(name, retained) do
    snapshot = name <> "@" <> Lilly.Transfer.SnapshotJournal.slot()

    cond do
      not Map.has_key?(retained, snapshot) -> :ok
      match?({:ok, _}, Command.run(:zfs_destroy, [snapshot], 30_000)) -> :ok
      true -> :error
    end
  end

  defp inspect_import(pool, spec, descriptor, journal, stage) do
    snapshots = ReceivedDataset.snapshots(name(pool, spec), journal["dataset_guid"], descriptor)

    with true <- ReceivedDataset.local_owner?(pool, spec.id, journal["nonce"]),
         {:ok, _, _} = result <-
           ZFS.adoption_child(
             Pool.zfs_identity(pool),
             name(pool, spec),
             journal["dataset_guid"],
             snapshots,
             stage
           ),
         true <- ReceivedDataset.local_owner?(pool, spec.id, journal["nonce"]),
         do: result
  end

  defp mount_import(_pool, _spec, :mounted), do: :ok

  defp mount_import(pool, spec, :unmounted) do
    with true <-
           Lilly.Host.Privilege.lstat(directory(pool, spec)) == {:error, :enoent} or
             (match?(
                {:ok, %File.Stat{type: :directory, uid: 0}},
                Lilly.Host.Privilege.lstat(directory(pool, spec))
              ) and
                File.ls(directory(pool, spec)) == {:ok, []}),
         {:ok, _} <- Command.run(:zfs_mount, [name(pool, spec)], 30_000),
         do: :ok
  end

  # @cc [owner:ghuntley,label:security;isolation] clone-import-rebinds-only-admitted-source-uid
  # Before publication a clone's received regular disks may retain the admitted
  # source slot's UID. Validate that exact source UID, every drive's size and
  # single link, and the exact profile-derived drive-name set before rebinding to
  # the new slot. Ready disks MUST still validate only destination ownership;
  # arbitrary received UIDs never qualify.
  defp import_disk_shape?(pool, spec, descriptor \\ nil) do
    source_shape =
      case descriptor do
        %{purpose: :clone} ->
          with {:ok, source} <-
                 OverallsProtocol.DiskTransfer.source_workload(descriptor)
                 |> Map.drop([:architecture])
                 |> Map.merge(%{id: spec.id, pool_id: pool.id})
                 |> Spec.new(),
               do: disk_shape?(pool, source),
               else: (_ -> false)

        _ ->
          false
      end

    match?(
      {:ok, %File.Stat{type: :directory, uid: 0}},
      Lilly.Host.Privilege.lstat(directory(pool, spec))
    ) and
      received_entries?(pool, spec) and
      match?({:ok, _}, WorkloadBundle.load(directory(pool, spec), spec)) and
      (disk_shape?(pool, spec) or source_shape)
  end

  # The received dataset holds the profile's drives plus exactly one closed
  # boot-bundle file set (kernel or firmware); the bundle itself is validated
  # separately by WorkloadBundle.load/2.
  defp received_entries?(pool, spec) do
    drives = Enum.map(Spec.drives(spec), & &1.name)

    case File.ls(directory(pool, spec)) do
      {:ok, names} ->
        Enum.any?(WorkloadBundle.file_sets(), fn set ->
          MapSet.new(names) == MapSet.new(drives ++ set)
        end)

      _ ->
        false
    end
  end

  defp publish_drives(pool, spec) do
    directory = directory(pool, spec)
    owner = "#{spec.network.uid}:#{spec.network.uid}"

    result =
      Enum.reduce_while(Spec.drives(spec), :ok, fn drive, :ok ->
        disk = Path.join(directory, drive.name)

        with {:ok, _} <- Command.run(:chown, [owner, "--", disk]),
             :ok <- Lilly.Host.Privilege.chmod(disk, 0o600),
             {:ok, _} <- Command.run(:sync, ["--", disk], 300_000) do
          {:cont, :ok}
        else
          _ -> {:halt, :error}
        end
      end)

    with :ok <- result,
         {:ok, _} <- Command.run(:sync, ["--", directory], 300_000),
         do: :ok
  end

  # @cc [owner:ghuntley,label:security;recovery] zfs-parent-binding-before-mutations
  # bind/1 MUST require root and a current ownership lock, match the actual parent identity,
  # and preserve a private host/pool binding. A parent with VM data or retained import history cannot acquire a
  # new binding just because its ownership metadata is absent.
  @spec bind(Pool.t()) :: :ok | {:error, atom()}
  def bind(pool) do
    with true <- pool.backend == :zfs and OverallsProtocol.uuid?(pool.host_id),
         {:ok, %File.Stat{uid: 0}} <- Lilly.Host.Privilege.stat("/proc/self"),
         lock when is_struct(lock, Lilly.Host.Lease) <- Lock.current(),
         expected = Pool.zfs_identity(pool),
         {:ok, ^expected} <- ZFS.inspect_path(pool.path),
         :ok <- claim_pool_root(pool),
         :ok <- PrivateFiles.directory(base(pool)),
         :ok <- PrivateFiles.directory(active(pool)),
         :ok <- PrivateFiles.directory(retired(pool)),
         :ok <- validate_import_root(pool),
         :ok <- parent_claim(pool),
         :ok <- PrivateFiles.directory(Path.join(pool.path, "vms")) do
      :ok
    else
      {:error, :storage_busy} = error -> error
      _ -> {:error, :zfs_ownership_unconfirmed}
    end
  end

  # Lilly's service user (ADR-0182) owns the verified pool root so it can
  # create its .lilly-* directories, even for a pool imported after boot;
  # hostd hands it over under the pool lease.
  defp claim_pool_root(pool), do: Lilly.Host.Privilege.claim_directory(pool.path)

  # @cc [owner:ghuntley,label:recovery] zfs-create-intent-precedes-dataset
  # prepare/2 MUST persist the immutable binding and unpredictable creation nonce before zfs
  # create. Only the matching nonce can recover an interrupted create before GUID binding;
  # after binding, a missing or replaced dataset MUST NOT be recreated. Callers hold the pool lock.
  # Coherent usage-only drift MUST use the observation's at-most-three complete attempts,
  # 25 ms apart, returning the latest coherent tree if counters keep moving (ADR-0163).
  # Genuine storage_busy MUST remain retryable before any VMM launch attempt; identity or
  # non-usage policy drift and accounting exhaustion MUST fail without granting readiness.

  # @cc [owner:ghuntley,label:observability;security;capacity] zfs-prepare-observation-is-diagnostic
  # Dataset preparation MUST use the same bounded whole-pool observation and
  # capacity refusal while emitting only the validated placement UUID and
  # catalogued stage/reason atoms for an incoherent read. Native properties,
  # paths, command output and VM contents MUST NOT enter diagnostics or grant
  # a retry or capacity credit.

  # @cc [owner:ghuntley,label:capacity;recovery] prepare-reads-native-state-once
  # Under the pool lock, prepare_batch/3 MUST read one PoolSnapshot after
  # bind/1 for the whole batch and derive every placement's absence proof and
  # claim, and the batch's single allocation and template audit, from
  # it (ADR-0152). After the batch's own native mutations it MUST re-verify the
  # whole pool exactly once; without any, the snapshot is the current state.
  # No check may consult native state read before the lock was acquired.
  # Preparation derives no capacity credit, so both reads use identity usage.
  # A placement's own failure MUST NOT fail another placement in the batch; a
  # failure of a shared read or audit fails every placement (ADR-0176).
  @spec prepare(Pool.t(), Spec.t()) :: :ok | {:error, atom()}
  def prepare(pool, spec) do
    [{^spec, result}] = prepare_batch(pool, [spec])
    result
  end

  @spec prepare_batch(Pool.t(), [Spec.t(), ...]) ::
          [{Spec.t(), :ok | {:error, atom()}}]
  def prepare_batch(pool, [first | _] = specs) do
    shared =
      with :ok <- bind(pool),
           do: prepare_snapshot(PoolSnapshot.read(pool, first.id, :identity))

    case shared do
      {:ok, snapshot} ->
        claimed = Enum.map(specs, &{&1, prepare_claim(pool, &1, snapshot)})

        case allocations(pool, snapshot) do
          {:ok, _} ->
            materialized =
              Enum.map(claimed, fn
                {spec, {:ok, record}} ->
                  {spec, prepare_effect(pool, spec, record, snapshot)}

                other ->
                  other
              end)

            current =
              if Enum.any?(materialized, &match?({_, {:ok, _, :mutated}}, &1)),
                do: verification_snapshot(PoolSnapshot.reread(pool, snapshot, first.id)),
                else: {:ok, snapshot}

            Enum.map(materialized, fn
              {spec, {:ok, record, _effect}} ->
                {spec, prepare_result(pool, spec, prepare_finish(pool, spec, record, current))}

              {spec, failure} ->
                {spec, prepare_result(pool, spec, failure)}
            end)

          failure ->
            Enum.map(specs, &{&1, prepare_result(pool, &1, failure)})
        end

      failure ->
        Enum.map(specs, &{&1, prepare_result(pool, &1, failure)})
    end
  end

  defp prepare_claim(pool, spec, snapshot) do
    with true <- spec.pool_id == pool.id,
         {:ok, record, :active} <- claim(pool, spec, snapshot),
         true <- record["state"] in ~w(creating bound ready),
         do: {:ok, record}
  rescue
    _ -> {:error, :invalid_result}
  end

  defp prepare_effect(pool, spec, record, snapshot) do
    materialize_dataset(pool, spec, record, snapshot)
  rescue
    _ -> {:error, :invalid_result}
  end

  defp prepare_finish(pool, spec, record, current) do
    with {:ok, current} <- current,
         :ok <- verify_snapshot(pool, spec, record, current),
         :ok <- Lilly.Host.Privilege.claim_directory(directory(pool, spec)),
         do: PrivateFiles.directory(directory(pool, spec))
  rescue
    _ -> {:error, :invalid_result}
  end

  defp prepare_result(_pool, _spec, :ok), do: :ok
  defp prepare_result(_pool, _spec, {:error, :storage_busy} = error), do: error

  defp prepare_result(pool, spec, result) do
    reason =
      case result do
        {:error, reason} when is_atom(reason) -> reason
        _ -> :invalid_result
      end

    # Only a local error atom leaves this boundary; neither ownership
    # records, native utility output nor guest contents are diagnostic data.
    Lilly.Events.emit("vm.dataset_preparation_failed",
      host_id: pool.host_id,
      vm_id: spec.id,
      reason: reason
    )

    {:error, :zfs_dataset_prepare_failed}
  end

  @spec prepare_snapshot({:ok, PoolSnapshot.t()} | {:error, PoolSnapshot.read_error()}) ::
          {:ok, PoolSnapshot.t()} | {:error, atom()}
  defp prepare_snapshot({:ok, _} = result), do: result
  defp prepare_snapshot({:error, {:observe, reason}}), do: {:error, reason}
  defp prepare_snapshot({:error, stage}), do: {:error, stage}

  @spec verification_snapshot({:ok, PoolSnapshot.t()} | {:error, PoolSnapshot.read_error()}) ::
          {:ok, PoolSnapshot.t()} | {:error, readiness_stage() | :storage_busy}
  defp verification_snapshot({:ok, _} = result), do: result
  defp verification_snapshot({:error, {:observe, :storage_busy}}), do: {:error, :storage_busy}

  defp verification_snapshot({:error, {:observe, :snapshot_ownership_unconfirmed}}),
    do: {:error, :snapshot_ownership}

  defp verification_snapshot({:error, :owner_set}), do: {:error, :dataset_ownership}
  defp verification_snapshot({:error, :mounts}), do: {:error, :mounts}
  defp verification_snapshot({:error, _}), do: {:error, :accounting}

  # @cc [owner:ghuntley,label:security;recovery] owned-identity-is-verified-claim
  # owned_identity/2 requires the pool lock and returns the nonce and GUID only
  # for a bound or ready active claim whose native child verifies. It is evidence
  # for binding a same-pool copy journal (ADR-0145), never capacity credit.
  @doc false
  @spec owned_identity(Pool.t(), Spec.t()) ::
          {:ok, %{nonce: String.t(), dataset_guid: String.t(), state: String.t()}}
          | {:error, atom()}
  def owned_identity(pool, spec) do
    with true <- spec.pool_id == pool.id,
         {:ok, record, :active} <- claim(pool, spec),
         true <- record["state"] in ~w(bound ready),
         :ok <- verify_child(pool, spec, record) do
      {:ok,
       %{nonce: record["nonce"], dataset_guid: record["dataset_guid"], state: record["state"]}}
    else
      {:error, :storage_busy} = error -> error
      _ -> {:error, :zfs_ownership_unconfirmed}
    end
  end

  @doc false
  @spec publish_owned_drives(Pool.t(), Spec.t()) :: :ok | :error
  def publish_owned_drives(pool, spec), do: publish_drives(pool, spec)

  # @cc [owner:ghuntley,label:security;observability] readiness-diagnostics-preserve-validation
  # Readiness MUST retain identity, snapshot accounting, mount, disk metadata and
  # bundle validation. Failures report only placement identity and fixed stage/
  # reason atoms; native output and paths MUST NOT enter diagnostics. Verified
  # usage contention and independently owned receive staging MUST remain a quiet
  # storage_busy result before publication, without converting unknown failures.
  @spec ready(Pool.t(), Spec.t()) :: :ok | {:error, atom()}
  def ready(pool, spec) do
    [{^spec, result}] = ready_batch(pool, [spec])
    result
  end

  # @cc [owner:ghuntley,label:security;recovery] readiness-batch-shared-reads
  # ready_batch/2 MUST read the owner set, mount table, staged imports and one
  # identity observation once per batch under the pool lock, then apply every
  # placement's claim, bundle, disk metadata, ownership, mount and GUID check
  # against those reads and save only that placement's readiness. A shared
  # read failure fails every placement with the same stage; one placement's
  # failure MUST NOT fail another (ADR-0176).
  @spec ready_batch(Pool.t(), [Spec.t(), ...]) :: [{Spec.t(), :ok | {:error, atom()}}]
  def ready_batch(pool, [first | _] = specs) do
    shared = readiness_reads(pool, first)
    Enum.map(specs, &{&1, ready_one(pool, &1, shared)})
  end

  defp readiness_reads(pool, first) do
    with {:dataset_ownership, {:ok, owners}} <-
           {:dataset_ownership, ZFS.owners(Pool.zfs_identity(pool))},
         {:mounts, {:ok, mounts}} <- {:mounts, ZFS.mounts()},
         {:ok, staged} <- readiness_imports(pool),
         {:accounting, {:ok, observation}} <-
           {:accounting, staged_observation(pool, first.id, staged)} do
      {:ok, %{owners: owners, mounts: mounts, observation: observation}}
    else
      {:error, :storage_busy} -> {:error, :storage_busy}
      {:accounting, {:error, :storage_busy}} -> {:error, :storage_busy}
      {:accounting, {:error, :snapshot_ownership_unconfirmed}} -> {:error, :snapshot_ownership}
      {stage, _} -> {:error, stage}
    end
  end

  defp ready_one(pool, spec, shared) do
    with {:dataset_identity, true} <- {:dataset_identity, spec.pool_id == pool.id},
         {:dataset_identity, {:ok, record, :active}} <- {:dataset_identity, claim(pool, spec)},
         {:dataset_identity, true} <- {:dataset_identity, record["state"] in ~w(bound ready)},
         {:boot_bundle, {:ok, _}} <-
           {:boot_bundle, WorkloadBundle.load(directory(pool, spec), spec)},
         {:disk_metadata, true} <- {:disk_metadata, ready_disk_metadata?(pool, spec)},
         {:ok, facts} <- shared,
         :ok <- verify_restart(pool, spec, record, facts),
         {:disk_metadata, :ok} <-
           {:disk_metadata, save(pool, spec, %{record | "state" => "ready"})} do
      :ok
    else
      {:error, :storage_busy} = error -> error
      {:error, stage} -> readiness_failure(spec, stage, :unconfirmed)
      {stage, _} -> readiness_failure(spec, stage, :invalid)
    end
  rescue
    _ -> readiness_failure(spec, :disk_metadata, :invalid)
  end

  defp verify_restart(pool, spec, record, %{
         owners: owners,
         mounts: mounts,
         observation: observation
       }) do
    with {:dataset_ownership, true} <-
           {:dataset_ownership, owner?(owners[name(pool, spec)], pool, spec, record)},
         {:mounts, true} <- {:mounts, mounts_valid?(mounts, pool, spec, :present, true)},
         {:dataset_identity, %{dataset_guid: guid}} <-
           {:dataset_identity, observation.children[name(pool, spec)]},
         {:dataset_identity, true} <- {:dataset_identity, guid == record["dataset_guid"]} do
      :ok
    else
      {stage, _} -> {:error, stage}
    end
  end

  # Restart readiness defers only while an owned import may still be writing;
  # finished imports are validated as staged children, not a pool-wide refusal.
  # Space counters may still settle just after a receive finishes; while any
  # finished import is staged, an accounting failure defers instead of failing.
  defp staged_observation(pool, diagnostic_placement, staged) do
    case observe(pool, diagnostic_placement, staged) do
      {:ok, observation} -> {:ok, observation}
      {:error, _reason} when map_size(staged) > 0 -> {:error, :storage_busy}
      other -> other
    end
  end

  @spec readiness_imports(Pool.t()) :: {:ok, ReceivedDataset.staged()} | {:error, :storage_busy}
  defp readiness_imports(pool) do
    case ReceivedDataset.staging(pool) do
      :busy -> {:error, :storage_busy}
      {:ok, staged} -> {:ok, staged}
    end
  end

  @spec readiness_failure(Spec.t(), readiness_stage(), :unconfirmed | :invalid) ::
          {:error, :zfs_disk_not_ready}
  defp readiness_failure(spec, stage, reason) do
    Lilly.Events.emit("vm.disk_readiness_failed",
      placement_id: spec.id,
      stage: stage,
      reason: reason
    )

    {:error, :zfs_disk_not_ready}
  end

  # @cc [owner:ghuntley,label:assumption;recovery] zfs-destroy-requires-physical-stop
  # Callers of delete/2 MUST first prove the VMM/cgroup empty and clean its jail mounts/network.
  # delete/2 MUST retain a durable deletion fence, match GUID and ownership, reject unknown
  # contents/mount aliases/snapshots, detach only exact foreign namespace copies with
  # ordinary unmount, use nonrecursive nonforced destroy, and observe absence
  # and durably remove its empty canonical mountpoint before success, including
  # retired-record retries. Tombstones MUST survive outside the destroyed child.
  # An interrupted destroy MAY remount only its already-deleting, GUID-bound owned child at
  # an empty canonical mountpoint, then repeat all normal content/mount/destruction checks.
  # The precondition uses an identity observation: unrelated pool usage churn (guest
  # writes, builds, other frees) MUST NOT fail deletion, while identity, policy,
  # snapshot and ownership drift still MUST. Every unconfirmed attempt MUST report
  # the fixed stage that refused it.
  @spec delete(Pool.t(), Spec.t()) :: :ok | {:error, atom()}
  def delete(pool, spec) do
    with true <- stage(spec.pool_id == pool.id, :pool),
         :ok <- stage(bind(pool), :bind),
         {:ok, record, location} <- stage(claim(pool, spec), :claim),
         :ok <- stage(recover_delete_mount(pool, spec, record), :recover_mount),
         {:ok, observation} <- stage(observe_identity(pool), :observe),
         {:ok, owners} <- stage(ZFS.owners(Pool.zfs_identity(pool)), :owners),
         true <-
           stage(
             not Enum.any?(
               Map.keys(observation.snapshots),
               &String.starts_with?(&1, name(pool, spec) <> "@")
             ),
             :snapshots
           ),
         :ok <-
           delete_owned(
             pool,
             spec,
             record,
             location,
             observation.children[name(pool, spec)],
             owners
           ) do
      Lilly.Events.emit("lilly.zfs_destroyed", placement_id: spec.id)

      :ok
    else
      failure ->
        Lilly.Events.emit("lilly.zfs_delete_unconfirmed",
          placement_id: spec.id,
          reason: :zfs_dataset_cleanup_unconfirmed,
          stage: failed_stage(failure)
        )

        {:error, :zfs_dataset_cleanup_unconfirmed}
    end
  end

  @delete_stages [
    :pool,
    :bind,
    :claim,
    :recover_mount,
    :observe,
    :owners,
    :snapshots,
    :ownership,
    :mounts,
    :save_deleting,
    :destroy,
    :absent,
    :directory,
    :save_deleted,
    :retire
  ]

  defp stage(result, name) when result in [false, :error], do: {:failed, name}
  defp stage({:error, _}, name), do: {:failed, name}
  defp stage(result, _name), do: result

  defp failed_stage({:failed, name}) when name in @delete_stages, do: name
  defp failed_stage(_), do: :unknown

  defp recover_delete_mount(pool, spec, %{"state" => "deleting"} = record) do
    identity = Pool.zfs_identity(pool)
    name = name(pool, spec)

    with {:ok, owners} <- ZFS.owners(identity) do
      case owners[name] do
        nil ->
          :ok

        owner ->
          with true <- guid?(record["dataset_guid"]) and owner?(owner, pool, spec, record),
               {:ok, state} <- ZFS.child_mount_state(identity, name, record["dataset_guid"]) do
            case state do
              :mounted ->
                :ok

              :unmounted ->
                with {:ok, mounts} <- ZFS.mounts(),
                     true <- mounts_valid?(mounts, pool, spec, :absent, false),
                     {:ok, %File.Stat{type: :directory, uid: 0}} <-
                       Lilly.Host.Privilege.lstat(directory(pool, spec)),
                     {:ok, []} <- File.ls(directory(pool, spec)),
                     {:ok, _} <- Command.run(:zfs_mount, [name], 30_000),
                     do: :ok
            end
          end
      end
    end
  end

  defp recover_delete_mount(_pool, _spec, _record), do: :ok

  # @cc [owner:ghuntley,label:capacity] zfs-credit-requires-ready-owned-disk
  # allocations/2 MUST reject every unclaimed child, replaced GUID, missing initialized disk
  # or conflicting mount. Only ready single-link VM-owned disks earn exclusive physical credit,
  # capped at their logical commitment. Creating/deleting children earn no credit. Callers hold
  # the pool lock; retired tombstones are not an active-dataset index.
  @spec allocations(Pool.t(), PoolSnapshot.t()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, atom()}
  def allocations(pool, snapshot) do
    # Only a locked snapshot may back a mutation; a fenced one reports only.
    with true <- PoolSnapshot.held?(snapshot),
         {:ok, credits} <- classify_allocations(pool, snapshot) do
      {:ok, credits}
    else
      _ -> {:error, :zfs_allocation_ownership_unconfirmed}
    end
  end

  # Which allocation-ownership check withheld the pool, as a closed atom.
  # `:pool_lock` means the snapshot outlived the lock it was read under.
  @type allocation_rejection ::
          :pool_lock
          | :active_claims
          | :snapshot_tags
          | :owner_set
          | :templates
          | :workloads

  # @cc [owner:ghuntley,label:capacity] allocation-classification-from-one-snapshot
  # classify_allocations/2 MUST classify only a PoolSnapshot that is still
  # current: its lock still held, or, for a fenced capacity snapshot, its pool
  # generation unchanged. Its snapshot expectations are the ones the observation was accounted
  # against under that lock (ADR-0152); owners and mounts come from the same
  # read. Every ownership, template and disk-metadata refusal is retained; an
  # owned child with an invalid launch bundle is recognized without credit.
  # A `standby-*` child left after ADR-0177 is an unrecognized workload.
  # Only an exact snapshot grants credit: an identity snapshot classifies with
  # every refusal but returns no credits.
  @doc false
  @spec classify_allocations(Pool.t(), PoolSnapshot.t()) ::
          {:ok, map()} | {:error, allocation_rejection()}
  def classify_allocations(pool, %PoolSnapshot{} = snapshot) do
    %PoolSnapshot{observation: observation, owners: owners, mounts: mounts} = snapshot
    snapshots = observation.snapshots

    with {:pool_lock, true} <- {:pool_lock, PoolSnapshot.current?(snapshot)},
         {:active_claims, {:ok, entries}} <- {:active_claims, File.ls(active(pool))},
         {:active_claims, true} <-
           {:active_claims,
            length(entries) <= 4096 and Enum.all?(entries, &OverallsProtocol.uuid?/1)},
         {:snapshot_tags, true} <- {:snapshot_tags, snapshot_tags?(snapshots, owners)},
         {:owner_set, true} <-
           {:owner_set,
            Enum.sort(Map.keys(owners)) ==
              Enum.sort([
                pool.storage.dataset | Map.keys(observation.children) ++ Map.keys(snapshots)
              ])},
         {templates, children} =
           Enum.split_with(observation.children, fn {name, _} ->
             String.starts_with?(name, pool.storage.dataset <> "/template-")
           end),
         {:templates, :ok} <-
           {:templates, Lilly.Host.ImageTemplate.audit(pool, Map.new(templates), owners)},
         {checkpoint_children, children} =
           Enum.split_with(children, fn {name, _} ->
             String.starts_with?(name, pool.storage.dataset <> "/checkpoint-")
           end),
         {:workloads, {:ok, _checkpoint_credits}} <-
           {:workloads,
            Lilly.VM.CheckpointStorage.audit(pool, Map.new(checkpoint_children), owners, mounts)},
         children = Map.new(children),
         {:workloads, {:ok, credits, recognized}} <-
           {:workloads, audit(pool, entries, children, owners, mounts)},
         {:workloads, true} <-
           {:workloads, Enum.sort(recognized) == Enum.sort(Map.keys(children))} do
      {:ok, if(snapshot.usage == :exact, do: credits, else: %{})}
    else
      {check, _} -> {:error, check}
    end
  end

  # @cc [owner:ghuntley,label:capacity] snapshot-observation-joins-local-ownership
  # observe/1 MUST derive snapshot expectations from current local journals/claims
  # and native creation markers before native accounting. Peer-supplied expectations
  # MUST NOT bypass this boundary. Callers hold the pool lock; allocation credit still
  # requires allocations/2 and remains capped at the existing disk commitment.
  @spec observe(Pool.t()) :: {:ok, map()} | {:error, atom()}
  def observe(pool), do: observe(pool, nil)

  @spec observe(Pool.t(), OverallsProtocol.uuid() | nil) :: {:ok, map()} | {:error, atom()}
  defp observe_identity(pool) do
    with {:ok, snapshots} <- SnapshotOwnership.expectations(pool),
         do: ZFS.observe_identity(Pool.zfs_identity(pool), snapshots)
  end

  defp observe(pool, diagnostic_placement, staged \\ %{}) do
    with {:ok, snapshots} <- SnapshotOwnership.expectations(pool) do
      case diagnostic_placement do
        nil ->
          ZFS.observe(Pool.zfs_identity(pool), snapshots)

        placement_id ->
          # Staged imports bring their own journal-fixed snapshot expectations.
          snapshots = Enum.reduce(Map.values(staged), snapshots, &Map.merge(&2, &1))
          staged_names = MapSet.new(Map.keys(staged))

          # Readiness grants no capacity credit (ADR-0176): identity usage.
          ZFS.observe_for_readiness(
            Pool.zfs_identity(pool),
            snapshots,
            placement_id,
            staged_names,
            :identity
          )
      end
    end
  end

  defp snapshot_tags?(snapshots, owners) do
    Enum.all?(snapshots, fn {name, expected} ->
      [dataset, _] = String.split(name, "@")
      child = owners[dataset]
      snapshot = owners[name]

      is_map(child) and is_map(snapshot) and snapshot["guid"] == expected.snapshot_guid and
        Map.drop(snapshot, ["guid"]) == Map.drop(child, ["guid"])
    end)
  end

  @doc "Local claim identity only; callers must independently verify native ownership before effects."
  # @cc [owner:ghuntley,label:security] snapshot-claim-does-not-adopt-data
  # snapshot_claim/2 MUST read an existing GUID-bound claim with an exact pool/spec
  # binding. Missing, malformed and not-yet-bound claims MUST fail without creating
  # metadata or adopting native data. Returned claims are not physical stop proof.
  @spec snapshot_claim(Pool.t(), OverallsProtocol.uuid()) :: {:ok, map()} | {:error, atom()}
  def snapshot_claim(pool, id) do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, record} <- read_json(Path.join([active(pool), id, "claim.json"])),
         true <- valid_record?(record) and guid?(record["dataset_guid"]),
         {:ok, spec} <- decode_spec(record["binding"]["spec"]),
         true <- spec.id == id and record["binding"] == binding(pool, spec) do
      {:ok, %{spec: spec, dataset_guid: record["dataset_guid"], state: record["state"]}}
    else
      _ -> {:error, :zfs_snapshot_claim_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] native-snapshot-source-requires-ready-disk
  # snapshot_source/2 MUST verify the existing parent binding, ready claim, native dataset GUID/tags,
  # disk shape and permitted mount paths. It MUST NOT initialize missing data. Callers
  # hold the pool lock and separately verify native policy and final-source stop.
  # The claim comparison MUST use the spec's storage shape (Spec.storage/1): a
  # running source whose start command carries a workspace source still owns
  # the claim its stopped predecessor journaled without one.
  @spec snapshot_source(Pool.t(), Spec.t()) :: {:ok, map()} | {:error, atom()}
  def snapshot_source(pool, spec) do
    with {:ok, parent} <- read_json(Path.join(base(pool), "owner.json")),
         true <- parent == parent_binding(pool),
         {:ok, %{state: "ready"} = claim} <- snapshot_claim(pool, spec.id),
         true <- claim_matches?(claim, spec),
         {:ok, record} <- read_json(Path.join(metadata_directory(pool, spec), "claim.json")),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         true <- owner?(owners[name(pool, spec)], pool, spec, record),
         {:ok, mounts} <- ZFS.mounts(),
         true <- mounts_valid?(mounts, pool, spec, :present, true),
         true <- ready_disk?(pool, spec),
         do: {:ok, claim},
         else: (_ -> {:error, :zfs_snapshot_source_unconfirmed})
  end

  @doc "Whether a decoded claim describes this spec's persisted storage shape."
  @spec claim_matches?(map(), Spec.t()) :: boolean()
  def claim_matches?(%{spec: %Spec{} = claimed}, %Spec{} = spec),
    do: claimed == Spec.storage(spec)

  def claim_matches?(_, _), do: false

  # @cc [owner:ghuntley,label:recovery] zfs-resize-journal-before-effects
  # With pool and stopped-placement locks held, resize MUST journal the GUID-bound
  # original and target claims before disk growth. Resume accepts only either exact
  # claim/marker and either disk length. Never initialize or adopt a missing disk.
  @spec resize(Pool.t(), Spec.t(), Spec.t(), String.t(), (-> :ok | {:error, atom()})) ::
          :ok | {:error, atom()}
  def resize(pool, source, target, request_id, grow) do
    directory = metadata_directory(pool, source)
    journal_path = Path.join(directory, "resize-" <> request_id <> ".json")

    with true <- OverallsProtocol.uuid?(request_id),
         true <-
           Map.drop(Spec.encode(source), ~w(vcpu memory_bytes disk_bytes)) ==
             Map.drop(Spec.encode(target), ~w(vcpu memory_bytes disk_bytes)),
         true <- target.disk_bytes >= source.disk_bytes,
         {:ok, journal} <- resize_record(pool, source, target, journal_path),
         {:ok, record} <- read_json(Path.join(directory, "claim.json")),
         true <- record in [journal["source"], journal["target"]],
         :ok <- verify_child(pool, source, record),
         true <-
           Enum.all?(["disk.json", "disk-ready.json"], fn name ->
             case read_json(Path.join(directory, name)) do
               {:ok, value} -> value in [Spec.encode(source), Spec.encode(target)]
               _ -> false
             end
           end),
         true <- disk_shape?(pool, source) or disk_shape?(pool, target),
         {:ok, stat} <-
           Lilly.Host.Privilege.lstat(Path.join(directory(pool, source), "rootfs.ext4")),
         true <- stat.uid == source.network.uid,
         :ok <- grow.(),
         true <- disk_shape?(pool, target),
         :ok <- resize_phase(journal_path, journal, "grown"),
         :ok <- PrivateFiles.write(directory, "disk.json", JSON.encode!(Spec.encode(target))),
         :ok <-
           PrivateFiles.write(directory, "disk-ready.json", JSON.encode!(Spec.encode(target))),
         :ok <- save(pool, target, journal["target"]),
         :ok <- verify_child(pool, target, journal["target"]),
         true <- ready_disk?(pool, target),
         :ok <- resize_phase(journal_path, %{journal | "phase" => "grown"}, "confirmed") do
      :ok
    else
      _ -> {:error, :resize_unconfirmed}
    end
  end

  defp resize_phase(path, journal, phase) do
    # Replays never move a confirmed growth back to its earlier intent.
    if journal["phase"] == "confirmed" and phase == "grown" do
      :ok
    else
      Lilly.Lifecycle.Journal.write(
        Lilly.Lifecycle.Resize,
        Path.dirname(path),
        Path.basename(path),
        %{journal | "phase" => phase}
      )
    end
  end

  defp resize_journal_read(path) do
    case Lilly.Host.Privilege.lstat(path) do
      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(path),
             do: Lilly.Lifecycle.Journal.decode(bytes)

      error ->
        error
    end
  end

  defp resize_record(pool, source, target, path) do
    case resize_journal_read(path) do
      {:ok, %{"source" => old, "target" => new} = journal} when map_size(journal) == 3 ->
        if journal["phase"] in ~w(prepared grown confirmed) and valid_record?(old) and
             old["state"] == "ready" and
             old["binding"] == binding(pool, source) and
             new == %{old | "binding" => binding(pool, target)},
           do: {:ok, journal},
           else: {:error, :resize_conflict}

      {:error, :enoent} ->
        with {:ok, _} <- snapshot_source(pool, source),
             {:ok, old} <- read_json(Path.join(metadata_directory(pool, source), "claim.json")),
             journal = %{
               "phase" => "prepared",
               "source" => old,
               "target" => %{old | "binding" => binding(pool, target)}
             },
             :ok <-
               Lilly.Lifecycle.Journal.write(
                 Lilly.Lifecycle.Resize,
                 Path.dirname(path),
                 Path.basename(path),
                 journal
               ),
             do: {:ok, journal}

      _ ->
        {:error, :resize_conflict}
    end
  end

  @doc "Host-local active claim index; never inside a portable child dataset."
  @spec ownership_directory(Pool.t()) :: Path.t()
  def ownership_directory(pool), do: active(pool)

  @spec name(Pool.t(), Spec.t()) :: String.t()
  def name(pool, spec), do: pool.storage.dataset <> "/vm-" <> spec.id
  @spec directory(Pool.t(), Spec.t()) :: Path.t()
  def directory(pool, spec), do: Path.join([pool.path, "vms", spec.id])

  defp base(pool), do: Path.join(pool.path, ".lilly-zfs")
  defp active(pool), do: Path.join(base(pool), "active")
  defp retired(pool), do: Path.join(base(pool), "deleted")
  # @cc [owner:ghuntley,label:security] disk-authority-outside-portable-dataset
  # metadata_directory/2 MUST resolve under the host-local pool ownership index,
  # outside the transferred child dataset. Received disk bytes MUST NOT supply
  # local claims, readiness markers or deletion tombstones.
  @spec metadata_directory(Pool.t(), Spec.t()) :: Path.t()
  def metadata_directory(pool, spec), do: Path.join(active(pool), spec.id)

  # @cc [owner:ghuntley,label:security;recovery] transfer-history-existing-local-claim
  # transfer_history/2 requires the pool lock and MUST return only an existing
  # exactly bound active claim or retained deletion tombstone, never initialize
  # missing ownership. Both locations present is corruption. Returned history is
  # not physical absence evidence; deletion must independently inspect native state.
  @spec transfer_history(Pool.t(), Spec.t()) ::
          {:ok, Path.t(), String.t()} | {:error, atom()}
  def transfer_history(pool, spec) do
    live = metadata_directory(pool, spec)
    dead = Path.join(retired(pool), spec.id)

    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         :ok <- bind(pool),
         {directory, location} <-
           (case {Lilly.Host.Privilege.lstat(live), Lilly.Host.Privilege.lstat(dead)} do
              {{:ok, _}, {:error, :enoent}} -> {live, :active}
              {{:error, :enoent}, {:ok, _}} -> {dead, :retired}
              _ -> :error
            end),
         {:ok, record, ^location} <-
           load_claim(Path.join(directory, "claim.json"), pool, spec, location),
         true <- guid?(record["dataset_guid"]),
         do: {:ok, directory, record["dataset_guid"]},
         else: (_ -> {:error, :transfer_history_unconfirmed})
  end

  defp record_directory(pool, spec), do: metadata_directory(pool, spec)

  defp parent_binding(pool),
    do: %{
      "host_id" => pool.host_id,
      "pool_id" => pool.id,
      "pool_path" => pool.path,
      "storage" => Storage.encode(pool.storage)
    }

  defp binding(pool, spec), do: Map.put(parent_binding(pool), "spec", Spec.encode(spec))

  defp validate_import_root(pool) do
    path = Path.join(base(pool), "imports")

    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> PrivateFiles.directory(path)
      _ -> :error
    end
  end

  defp parent_claim(pool) do
    expected = parent_binding(pool)

    case Lilly.Host.Privilege.lstat(Path.join(base(pool), "owner.json")) do
      {:ok, _} ->
        with {:ok, ^expected} <- read_json(Path.join(base(pool), "owner.json")), do: :ok

      {:error, :enoent} ->
        with {:ok, []} <- File.ls(active(pool)),
             {:ok, []} <- File.ls(retired(pool)),
             true <- File.ls(Path.join(base(pool), "imports")) in [{:error, :enoent}, {:ok, []}],
             true <- File.ls(Path.join(pool.path, "vms")) in [{:error, :enoent}, {:ok, []}],
             {:ok, %{children: children}} <- ZFS.observe(Pool.zfs_identity(pool)),
             true <- children == %{},
             do: PrivateFiles.write(base(pool), "owner.json", JSON.encode!(expected))

      _ ->
        :error
    end
  end

  # @cc [owner:ghuntley,label:recovery] import-history-forbids-blank-provisioning
  # A placement with retained import metadata MUST NOT initialize an ordinary disk
  # claim merely because its received filesystem is absent. Only explicit verified
  # import adoption may create that executable claim. Existing ordinary claims
  # continue through their own ownership checks; import history is never blank-disk authority.
  # A new claim proves native child absence from the preparation's snapshot,
  # or, for every other caller, from a fresh observation under its lock.
  @spec claim(Pool.t(), Spec.t(), PoolSnapshot.t() | :observe) ::
          {:ok, map(), :active | :retired} | {:error, atom()} | :error
  defp claim(pool, spec, source \\ :observe) do
    live = Path.join(record_directory(pool, spec), "claim.json")
    dead = Path.join([retired(pool), spec.id, "claim.json"])

    case {Lilly.Host.Privilege.lstat(live), Lilly.Host.Privilege.lstat(dead)} do
      {{:ok, _}, {:error, :enoent}} ->
        load_claim(live, pool, spec, :active)

      {{:error, :enoent}, {:ok, _}} ->
        load_claim(dead, pool, spec, :retired)

      {{:error, :enoent}, {:error, :enoent}} ->
        with {:error, :enoent} <- Lilly.Host.Privilege.lstat(Path.join(retired(pool), spec.id)),
             {:error, :enoent} <-
               Lilly.Host.Privilege.lstat(Path.join([base(pool), "imports", spec.id])),
             {:error, :enoent} <- Lilly.Host.Privilege.lstat(directory(pool, spec)),
             {:ok, children} <- observed_children(pool, source),
             false <- Map.has_key?(children, name(pool, spec)),
             :ok <- PrivateFiles.directory(record_directory(pool, spec)),
             record = %{
               "version" => 1,
               "binding" => binding(pool, spec),
               "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
               "dataset_guid" => nil,
               "state" => "creating"
             },
             :ok <- save(pool, spec, record) do
          {:ok, record, :active}
        else
          {:error, reason} = error when is_atom(reason) -> error
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp observed_children(pool, :observe) do
    with {:ok, observation} <- observe(pool), do: {:ok, observation.children}
  end

  defp observed_children(_pool, snapshot) do
    if PoolSnapshot.held?(snapshot), do: {:ok, snapshot.observation.children}, else: :error
  end

  defp load_claim(path, pool, spec, location) do
    with {:ok, record} <- read_json(path),
         true <- valid_record?(record) and record["binding"] == binding(pool, spec),
         true <- location == :active or record["state"] == "deleted" do
      {:ok, record, location}
    else
      _ -> :error
    end
  end

  defp valid_record?(
         %{
           "version" => 1,
           "nonce" => nonce,
           "dataset_guid" => guid,
           "state" => state,
           "binding" => binding
         } = record
       )
       when map_size(record) == 5 do
    is_map(binding) and is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{32}\z/, nonce) and
      state in @states and
      ((is_nil(guid) and state in ~w(creating deleting deleted)) or guid?(guid))
  end

  defp valid_record?(_), do: false

  # Reports whether a native mutation happened, so the caller re-verifies the
  # pool exactly when the snapshot no longer describes it.
  @spec materialize_dataset(Pool.t(), Spec.t(), map(), PoolSnapshot.t()) ::
          {:ok, map(), :mutated | :unchanged} | {:error, atom()} | :error
  defp materialize_dataset(pool, spec, record, snapshot) do
    name = name(pool, spec)
    child = snapshot.observation.children[name]

    cond do
      is_nil(child) and record["state"] == "creating" and is_nil(record["dataset_guid"]) ->
        create_dataset(pool, spec, record)

      is_map(child) and record["state"] == "creating" and is_nil(record["dataset_guid"]) ->
        with true <- owner?(snapshot.owners[name], pool, spec, record),
             bound = %{record | "state" => "bound", "dataset_guid" => child.dataset_guid},
             :ok <- save(pool, spec, bound),
             do: {:ok, bound, :unchanged}

      is_map(child) and child.dataset_guid == record["dataset_guid"] ->
        {:ok, record, :unchanged}

      true ->
        :error
    end
  end

  # @cc [owner:ghuntley,label:recovery] zfs-create-empty-dataset
  # Preparation always creates an ordinary empty dataset; the root disk is
  # copied into it on demand (ADR-0177).
  defp create_dataset(pool, spec, record) do
    properties = [
      "mountpoint=" <> directory(pool, spec),
      "compression=lz4",
      "reservation=none",
      "refreservation=none",
      "dedup=off",
      "sync=standard",
      "lilly:host=" <> pool.host_id,
      "lilly:pool=" <> pool.id,
      "lilly:vm=" <> spec.id,
      "lilly:nonce=" <> record["nonce"]
    ]

    with {:ok, _} <-
           Command.run(
             :zfs_create,
             Enum.flat_map(properties, &["-o", &1]) ++ [name(pool, spec)],
             30_000
           ),
         {:ok, bound} <- bind_created(pool, spec, record),
         do: {:ok, bound, :mutated}
  end

  # After this preparation created or renamed the child, only its own
  # ownership tags are re-read; the whole pool is re-verified afterwards.
  defp bind_created(pool, spec, record) do
    name = name(pool, spec)

    with {:ok, %{^name => owner} = owners} when map_size(owners) == 1 <-
           ZFS.owners(Pool.zfs_identity(pool), name),
         true <- owner?(owner, pool, spec, record),
         bound = %{record | "state" => "bound", "dataset_guid" => owner["guid"]},
         :ok <- save(pool, spec, bound),
         do: {:ok, bound}
  end

  @spec verify_child(Pool.t(), Spec.t(), map(), :prepare) ::
          :ok | {:error, readiness_stage() | :storage_busy}
  defp verify_child(pool, spec, record, mode \\ :prepare)

  defp verify_child(pool, spec, record, :prepare) do
    with {:ok, snapshot} <- verification_snapshot(PoolSnapshot.read(pool, nil, :identity)),
         do: verify_snapshot(pool, spec, record, snapshot)
  end

  # The same ownership, exclusive-mount and GUID checks as a native
  # verification, over one pool-locked snapshot whose lock is still held.
  @spec verify_snapshot(Pool.t(), Spec.t(), map(), PoolSnapshot.t()) ::
          :ok | {:error, readiness_stage()}
  defp verify_snapshot(pool, spec, record, snapshot) do
    name = name(pool, spec)

    with {:accounting, true} <- {:accounting, PoolSnapshot.held?(snapshot)},
         {:dataset_ownership, true} <-
           {:dataset_ownership, owner?(snapshot.owners[name], pool, spec, record)},
         {:mounts, true} <-
           {:mounts, mounts_valid?(snapshot.mounts, pool, spec, :present, true)},
         {:dataset_identity, %{dataset_guid: guid}} <-
           {:dataset_identity, snapshot.observation.children[name]},
         {:dataset_identity, true} <- {:dataset_identity, guid == record["dataset_guid"]} do
      :ok
    else
      {stage, _} -> {:error, stage}
    end
  end

  defp owner?(owner, pool, spec, record) when is_map(owner) do
    owner["host"] == pool.host_id and owner["pool"] == pool.id and owner["vm"] == spec.id and
      owner["nonce"] == record["nonce"] and guid?(owner["guid"]) and
      (is_nil(record["dataset_guid"]) or record["dataset_guid"] == owner["guid"])
  end

  defp owner?(_, _, _, _), do: false

  defp audit(pool, entries, children, owners, mounts) do
    Enum.reduce_while(entries, {:ok, %{}, []}, fn id, {:ok, credits, recognized} ->
      with {:ok, record} <- read_json(Path.join([active(pool), id, "claim.json"])),
           true <- valid_record?(record),
           {:ok, spec} <- decode_spec(record["binding"]["spec"]),
           true <- spec.id == id and record["binding"] == binding(pool, spec),
           child = children[name(pool, spec)],
           {:ok, credit} <-
             audit_child(pool, spec, record, child, owners[name(pool, spec)], mounts) do
        recognized = if child, do: [name(pool, spec) | recognized], else: recognized
        credits = if is_integer(credit), do: Map.put(credits, id, credit), else: credits
        {:cont, {:ok, credits, recognized}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp audit_child(pool, spec, record, nil, _owner, mounts) do
    if record["state"] in ~w(creating deleting deleted) and
         mounts_valid?(mounts, pool, spec, :absent, false), do: {:ok, nil}, else: :error
  end

  # @cc [owner:ghuntley,label:capacity;security] retained-storage-does-not-grant-execution
  # An exactly owned ready child MUST retain claim/spec, GUID, mount, drive and
  # disk-metadata checks even when its launch bundle is invalid. Privately owned,
  # bounded boot files with an invalid bundle MUST grant no allocation credit and
  # MUST NOT withhold the otherwise verified pool. Unsafe boot-file custody MUST
  # still refuse. Recognition MUST NOT rewrite metadata or authorize readiness.
  defp audit_child(pool, spec, record, child, owner, mounts) do
    with true <- record["state"] != "deleted" and owner?(owner, pool, spec, record),
         true <- owner["guid"] == child.dataset_guid,
         true <- mounts_valid?(mounts, pool, spec, :present, true) do
      if record["state"] == "ready" do
        if ready_disk_metadata?(pool, spec) do
          case WorkloadBundle.load(directory(pool, spec), spec) do
            {:ok, _} -> {:ok, min(child.physical_bytes, Spec.storage_bytes(spec))}
            {:error, :invalid_workload_bundle} -> retained_boot_storage(pool, spec)
          end
        else
          :error
        end
      else
        {:ok, nil}
      end
    else
      _ -> :error
    end
  end

  # This is a storage-custody check, never a decoder for another bundle version.
  # The caller has already verified the exact drive/boot filename set.
  @spec retained_boot_storage(Pool.t(), Spec.t()) :: {:ok, nil} | :error
  defp retained_boot_storage(pool, spec) do
    root = directory(pool, spec)

    with {:ok, metadata} <- PrivateFiles.read_secret(Path.join(root, "boot-bundle.json")),
         true <- byte_size(metadata) <= 16_384,
         {:ok, entries} <- File.ls(root),
         artifacts = entries -- (Enum.map(Spec.drives(spec), & &1.name) ++ ["boot-bundle.json"]),
         bytes when is_integer(bytes) <- retained_artifact_bytes(root, artifacts),
         true <- bytes + byte_size(metadata) <= OverallsProtocol.WorkloadBundle.storage_bytes() do
      {:ok, nil}
    else
      _ -> :error
    end
  end

  @spec retained_artifact_bytes(Path.t(), [String.t()]) :: non_neg_integer() | :error
  defp retained_artifact_bytes(root, artifacts) do
    Enum.reduce_while(artifacts, 0, fn name, bytes ->
      case Lilly.Host.Privilege.lstat(Path.join(root, name)) do
        {:ok, %File.Stat{type: :regular, links: 1, uid: 0, size: size, mode: mode}}
        when size > 0 ->
          if :erlang.band(mode, 0o777) == 0o444,
            do: {:cont, bytes + size},
            else: {:halt, :error}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp delete_owned(pool, spec, record, location, child, owners) do
    with true <-
           stage(
             is_nil(child) or
               (record["state"] != "deleted" and
                  owner?(owners[name(pool, spec)], pool, spec, record) and
                  owners[name(pool, spec)]["guid"] == child.dataset_guid),
             :ownership
           ),
         {:ok, mounts} <- stage(ZFS.mounts(), :mounts),
         true <-
           stage(
             mounts_valid?(mounts, pool, spec, if(child, do: :present, else: :absent), false),
             :mounts
           ) do
      if location == :retired do
        if is_nil(child),
          do: stage(Lilly.Host.EmptyDirectory.remove(directory(pool, spec)), :directory),
          else: {:failed, :ownership}
      else
        deleting = %{
          record
          | "state" => "deleting",
            "dataset_guid" => if(child, do: child.dataset_guid, else: record["dataset_guid"])
        }

        with :ok <- stage(save(pool, spec, deleting), :save_deleting),
             :ok <- stage(destroy_child(pool, spec, child), :destroy),
             {:ok, owners} <- stage(ZFS.owners(Pool.zfs_identity(pool)), :absent),
             false <- Map.has_key?(owners, name(pool, spec)),
             {:ok, mounts} <- stage(ZFS.mounts(), :absent),
             true <- stage(mounts_valid?(mounts, pool, spec, :absent, false), :absent),
             :ok <- stage(Lilly.Host.EmptyDirectory.remove(directory(pool, spec)), :directory),
             :ok <- stage(save(pool, spec, %{deleting | "state" => "deleted"}), :save_deleted),
             {:error, :enoent} <- Lilly.Host.Privilege.lstat(Path.join(retired(pool), spec.id)),
             {:ok, _} <-
               stage(
                 Command.run(:mv, [
                   "--no-target-directory",
                   "--",
                   record_directory(pool, spec),
                   Path.join(retired(pool), spec.id)
                 ]),
                 :retire
               ),
             {:ok, _} <- stage(Command.run(:sync, ["--", active(pool), retired(pool)]), :retire),
             do: :ok,
             else: (
               true -> {:failed, :absent}
               {:failed, _} = failure -> failure
               _ -> {:failed, :retire}
             )
      end
    else
      failure -> failure
    end
  end

  defp destroy_child(_pool, _spec, nil), do: :ok

  defp destroy_child(pool, spec, _child) do
    with true <- metadata_valid?(pool, spec),
         {:ok, names} <- File.ls(directory(pool, spec)),
         true <- Enum.all?(names, &owned_file?(pool, spec, &1)),
         {:ok, count} <- detach_namespace_mounts(pool, spec),
         :ok <- namespace_cleanup_observed(spec, count),
         {:ok, _} <- Command.run(:zfs_destroy, [name(pool, spec)], 30_000),
         do: :ok
  end

  defp detach_namespace_mounts(pool, spec) do
    case ZFSNamespaceMounts.detach(name(pool, spec), directory(pool, spec)) do
      {:error, reason} = error ->
        Lilly.Events.emit("lilly.zfs_namespace_cleanup_unconfirmed",
          placement_id: spec.id,
          reason: reason
        )

        error

      result ->
        result
    end
  end

  defp namespace_cleanup_observed(_spec, 0), do: :ok

  defp namespace_cleanup_observed(spec, count) do
    Lilly.Events.emit("lilly.zfs_namespace_mounts_detached",
      placement_id: spec.id,
      namespace_count: count
    )

    :ok
  end

  defp owned_file?(pool, spec, "rootfs.ext4"),
    do: drive_shape?(pool, spec, %{name: "rootfs.ext4", bytes: spec.disk_bytes})

  defp owned_file?(pool, spec, file)
       when file in ["kernel", "initrd", "firmware", "boot-bundle.json"],
       do:
         match?(
           {:ok, _},
           WorkloadBundle.load(directory(pool, spec), spec)
         )

  defp owned_file?(_pool, _spec, file)
       when file in [".kernel.pending", ".initrd.pending", ".firmware.pending"],
       do: false

  defp owned_file?(pool, spec, file) when file in ["data.raw", "data.raw.pending"] do
    case Enum.find(Spec.drives(spec), &(&1.name == "data.raw")) do
      nil ->
        false

      drive when file == "data.raw" ->
        drive_shape?(pool, spec, drive)

      _ ->
        match?(
          {:ok, %File.Stat{type: :regular, links: 1, uid: 0}},
          Lilly.Host.Privilege.lstat(Path.join(directory(pool, spec), file))
        )
    end
  end

  # An interrupted copy's root file is root-owned and unpublished until
  # materialization renames it.
  defp owned_file?(pool, spec, ".rootfs.pending" = file) do
    match?(
      {:ok, %File.Stat{type: :regular, links: 1, uid: 0}},
      Lilly.Host.Privilege.lstat(Path.join(directory(pool, spec), file))
    )
  end

  defp owned_file?(_, _, _), do: false

  defp metadata_valid?(pool, spec) do
    Enum.all?(["disk.json", "disk-ready.json"], fn file ->
      path = Path.join(metadata_directory(pool, spec), file)

      Lilly.Host.Privilege.lstat(path) == {:error, :enoent} or
        match?({:ok, _}, matching_json(path, Spec.encode(spec)))
    end)
  end

  defp ready_disk?(pool, spec) do
    ready_disk_metadata?(pool, spec) and
      match?({:ok, _}, WorkloadBundle.load(directory(pool, spec), spec))
  end

  defp ready_disk_metadata?(pool, spec) do
    disk_shape?(pool, spec) and
      received_entries?(pool, spec) and
      Enum.all?(Spec.drives(spec), fn drive ->
        match?(
          {:ok, %File.Stat{uid: uid}} when uid == spec.network.uid,
          Lilly.Host.Privilege.lstat(Path.join(directory(pool, spec), drive.name))
        )
      end) and
      match?(
        {:ok, _},
        matching_json(
          Path.join(metadata_directory(pool, spec), "disk-ready.json"),
          Spec.encode(spec)
        )
      ) and
      match?(
        {:ok, _},
        matching_json(Path.join(metadata_directory(pool, spec), "disk.json"), Spec.encode(spec))
      )
  end

  defp disk_shape?(pool, spec),
    do: Enum.all?(Spec.drives(spec), &drive_shape?(pool, spec, &1))

  defp drive_shape?(pool, spec, drive) do
    case Lilly.Host.Privilege.lstat(Path.join(directory(pool, spec), drive.name)) do
      {:ok, %File.Stat{type: :regular, links: 1, uid: uid, size: size}} ->
        uid in [0, spec.network.uid] and size == drive.bytes

      _ ->
        false
    end
  end

  defp mounts_valid?(mounts, pool, spec, state, jail?) do
    name = name(pool, spec)
    directory = directory(pool, spec)

    relevant =
      Enum.filter(mounts, fn mount ->
        source = mount["source"]
        target = mount["target"]

        is_binary(source) and is_binary(target) and
          (source == name or String.starts_with?(source, name <> "[") or target == directory or
             String.starts_with?(target, directory <> "/"))
      end)

    root =
      Enum.filter(
        relevant,
        &(&1["target"] == directory and &1["source"] == name and &1["fstype"] == "zfs" and
            &1["fsroot"] == "/")
      )

    case state do
      :absent ->
        relevant == []

      :present ->
        length(root) == 1 and
          Enum.all?(relevant -- root, fn mount ->
            jail? and jail_mount?(mount, name, pool, spec)
          end)
    end
  end

  defp jail_mount?(mount, dataset, pool, spec) do
    names = Enum.map(Spec.drives(spec), & &1.name) ++ WorkloadBundle.boot_artifacts()

    Enum.any?(names, fn file ->
      mount["target"] == Path.join(Jail.root(pool, spec), file) and mount["fstype"] == "zfs" and
        mount["fsroot"] == "/" <> file and mount["source"] == dataset <> "[/" <> file <> "]"
    end)
  end

  defp decode_spec(
         %{
           "id" => id,
           "image_id" => image,
           "pool_id" => pool,
           "profile" => profile,
           "slot" => slot,
           "vcpu" => cpu,
           "memory_bytes" => memory,
           "disk_bytes" => disk
         } = value
       )
       when map_size(value) == 8 do
    profile =
      %{
        "customer" => :customer,
        "standard" => :standard,
        "oss" => :oss,
        "inception" => :inception
      }[profile]

    Spec.new(%{
      id: id,
      image_id: image,
      pool_id: pool,
      profile: profile,
      slot: slot,
      vcpu: cpu,
      memory_bytes: memory,
      disk_bytes: disk
    })
  end

  defp decode_spec(_), do: :error

  defp save(pool, spec, record),
    do:
      Lilly.Lifecycle.Journal.write(
        Lilly.Lifecycle.Dataset,
        record_directory(pool, spec),
        "claim.json",
        record
      )

  defp matching_json(path, expected),
    do: with({:ok, ^expected} <- read_json(path), do: {:ok, expected}, else: (_ -> :error))

  defp read_json(path),
    do: with({:ok, bytes} <- PrivateFiles.read_secret(path), do: decode_json(path, bytes))

  defp decode_json(path, bytes) do
    if Path.basename(path) == "claim.json",
      do: Lilly.Lifecycle.Journal.decode(bytes),
      else: JSON.decode(bytes)
  end

  defp guid?(value) when is_binary(value) and byte_size(value) in 1..20,
    do:
      Regex.match?(~r/\A[1-9][0-9]*\z/, value) and
        String.to_integer(value) <= 18_446_744_073_709_551_615

  defp guid?(_), do: false
end
