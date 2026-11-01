# This disposable fixture exercises imported-template identity and public
# quarantine/retirement without changing production identity or retry guards.
defmodule ZFSGuestTemplatePostImport do
  import Bitwise
  alias Lilly.Host.{Image, ImageTemplate, Lock, Pool, Storage, ZFS, ZFSDataset}
  alias Lilly.Lifecycle.ImageTemplate, as: TemplateRecord
  alias Lilly.Lifecycle.Journal
  alias Lilly.VM.{Boot, Config, Intent, Spec, Unit}

  @files ~w(initrd kernel manifest.json rootfs.ext4)
  @catalog_limit 4096
  @hash_timeout_ms 120_000
  @action_budget_ms 890_000
  @type identities :: %{String.t() => [non_neg_integer()]}
  @type lock_identity :: {non_neg_integer(), non_neg_integer()}
  @type template_state ::
          :staging | :verifying | :sealing | :ready | :quarantined | :retiring | :deleted
  @type payload :: %{
          state: template_state(),
          host_id: OverallsProtocol.uuid(),
          pool_id: OverallsProtocol.uuid(),
          image_id: String.t(),
          incarnation: OverallsProtocol.uuid(),
          nonce: String.t(),
          guid: String.t() | nil,
          bytes: pos_integer(),
          identities: identities()
        }
  @type template_record :: %{
          id: OverallsProtocol.uuid(),
          revision: pos_integer(),
          state: template_state(),
          payload: payload(),
          directory: Path.t(),
          filename: String.t()
        }
  @type classification :: :exact | :device_only

  # @cc [owner:ghuntley,label:verification;security;recovery] post-import-template-device-drift-reuse
  # Only an exact imported ready identity, or consistent st_dev-only drift on
  # all four otherwise exact native vectors, may enter this fixture action.
  # Every other mismatch or failed predicate MUST abort. Linux ZFS reassigns
  # st_dev on every mount, so device-only drift MUST NOT quarantine
  # (ADR-0182, contract sealed-identity-survives-remount): the ordinary reader
  # MUST enter its callback with the unchanged incarnation and revision, whose
  # vectors differ from the record only in st_dev. The old journal and
  # owner.lock MUST NOT be edited, replaced or deleted by fixture code. VM
  # launch authority MUST remain absent throughout cache effects; ordinary
  # Driver.start is a later action.
  @spec run(Pool.t(), Image.t(), Config.t(), Spec.t()) :: :ok
  def run(pool, image, config, spec) do
    true = spec.id == "dddddddd-dddd-4ddd-8ddd-000000000102"
    deadline = System.monotonic_time(:millisecond) + @action_budget_ms
    :ok = unused_placement(config, pool, spec)
    lease_directory = lease_directory(pool, image)
    lock_identity = lock_identity(lease_directory)

    # Freeze AFTER import. No newly added pre-crash reader changes crash state.
    {:ok, owner} = Lock.shared(lease_directory)

    {old, classification} =
      try do
        old = current_ready(pool, image)
        :ok = native(pool, old)
        {:ok, staged} = Image.stage(directory(pool, old))
        true = staged.id == image.id
        {:ok, verified} = bounded_hash(directory(pool, old), lease_directory)
        true = verified.id == image.id and verified.verified
        true = bytes(verified) == old.payload.bytes
        {:ok, observed} = Image.identities(verified)
        classification = classify(old.payload.identities, observed)
        :ok = native(pool, old)
        true = load(pool, old.payload.incarnation) == old
        true = lock_identity(lease_directory) == lock_identity
        :ok = before_deadline(deadline)
        {old, classification}
      after
        :ok = Lock.release(owner)
      end

    # Public APIs acquire their own native image leases and pool locks. Never
    # call them beneath the classifier lease or an outer pool lock.
    case classification do
      :exact ->
        :ok = verify_public_reader(pool, image, old, lock_identity, deadline)
        true = load(pool, old.payload.incarnation) == old

      :device_only ->
        :ok = verify_public_reader(pool, image, old, lock_identity, deadline)
        true = load(pool, old.payload.incarnation) == old
        {:ok, _} = Image.sealed(directory(pool, old), old.payload.identities)
    end

    true = lock_identity(lease_directory) == lock_identity
    :ok = unused_placement(config, pool, spec)
    :ok = before_deadline(deadline)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;security;recovery] drifted-template-fenced-replacement
  # The driver, as root, changed only one sealed file's mtime and restored the
  # readonly seal, a change ADR-0182 still refuses. The ordinary reader MUST
  # quarantine the unchanged incarnation without entering its callback, then
  # ONE ordinary ensure MUST retire it and fully verify a distinct incarnation
  # with the same host, pool, image and bytes. The old journal and owner.lock
  # MUST NOT be edited, replaced or deleted by fixture code, and VM launch
  # authority MUST remain absent throughout.
  @spec replace_drifted(Pool.t(), Image.t(), Config.t(), Spec.t()) :: :ok
  def replace_drifted(pool, image, config, spec) do
    true = spec.id == "dddddddd-dddd-4ddd-8ddd-000000000102"
    deadline = System.monotonic_time(:millisecond) + @action_budget_ms
    :ok = unused_placement(config, pool, spec)
    lease_directory = lease_directory(pool, image)
    lock_identity = lock_identity(lease_directory)
    old = current_ready(pool, image)
    :ok = native(pool, old)
    {:error, :invalid_local_image} = Image.sealed(directory(pool, old), old.payload.identities)
    :ok = before_deadline(deadline)

    {:error, :template_quarantined} =
      ImageTemplate.with_image(pool, image, fn _ ->
        raise "drifted template entered forbidden template callback"
      end)

    :ok = assert_transition(pool, old, :quarantined, 1)
    true = lock_identity(lease_directory) == lock_identity
    :ok = unused_placement(config, pool, spec)
    :ok = before_deadline(deadline)

    :ok = ImageTemplate.ensure(pool, image)
    :ok = assert_transition(pool, old, :deleted, 3)
    :ok = absent_template(pool, old)
    fresh = current_ready(pool, image)
    true = fresh.revision == 4
    true = fresh.id != old.id

    true =
      Enum.all?(~w(incarnation nonce guid)a, fn key ->
        Map.fetch!(fresh.payload, key) != Map.fetch!(old.payload, key)
      end)

    true =
      Map.take(fresh.payload, ~w(host_id pool_id image_id bytes)a) ==
        Map.take(old.payload, ~w(host_id pool_id image_id bytes)a)

    :ok = verify_public_reader(pool, image, fresh, lock_identity, deadline)
    true = load(pool, fresh.payload.incarnation) == fresh
    :ok = assert_transition(pool, old, :deleted, 3)
    :ok = absent_template(pool, old)
    true = lock_identity(lease_directory) == lock_identity
    :ok = unused_placement(config, pool, spec)
    :ok = before_deadline(deadline)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] post-import-exact-vector-classifier
  # Classification MUST compare all eleven integers in all four vectors. The
  # only nonexact accepted case has one common recorded device, one different
  # common current device, and exact indices 1 through 10 on every file.
  @spec classify(identities(), identities()) :: classification()
  defp classify(expected, observed) do
    true = valid_identities?(expected) and valid_identities?(observed)

    if expected == observed do
      :exact
    else
      [old_device] = expected |> Map.values() |> Enum.map(&hd/1) |> Enum.uniq()
      [new_device] = observed |> Map.values() |> Enum.map(&hd/1) |> Enum.uniq()
      true = old_device != new_device

      true =
        Enum.all?(@files, fn file ->
          tl(Map.fetch!(expected, file)) == tl(Map.fetch!(observed, file))
        end)

      :device_only
    end
  end

  @spec valid_identities?(term()) :: boolean()
  defp valid_identities?(value) when is_map(value) do
    Enum.sort(Map.keys(value)) == @files and
      Enum.all?(Map.values(value), fn vector ->
        is_list(vector) and length(vector) == 11 and
          Enum.all?(vector, &(is_integer(&1) and &1 >= 0))
      end)
  end

  defp valid_identities?(_), do: false

  @spec current_ready(Pool.t(), Image.t()) :: template_record()
  defp current_ready(pool, image) do
    root = Path.join([pool.path, ".lilly-templates", "records"])
    :ok = private_directory(root)
    {:ok, incarnations} = File.ls(root)
    true = length(incarnations) <= @catalog_limit

    records =
      Enum.map(incarnations, fn incarnation ->
        true = OverallsProtocol.uuid?(incarnation)
        :ok = private_directory(Path.join(root, incarnation))
        record = load(pool, incarnation)
        true = record.payload.incarnation == incarnation
        true = record.payload.host_id == pool.host_id
        true = record.payload.pool_id == pool.id
        record
      end)

    matching =
      Enum.filter(records, fn record ->
        record.payload.image_id == image.id and record.state != :deleted
      end)

    true = length(matching) == 1
    record = hd(matching)
    :ready = record.state
    true = record.payload.state == :ready
    true = valid_identities?(record.payload.identities)
    record
  end

  # Journal validates the closed external envelope before this lossless typed
  # projection. All payload fields and durable envelope bindings are retained.
  @spec load(Pool.t(), OverallsProtocol.uuid()) :: template_record()
  defp load(pool, incarnation) do
    {:ok, %TemplateRecord{} = external} =
      Journal.load(
        TemplateRecord,
        Path.join([pool.path, ".lilly-templates", "records", incarnation]),
        "template.json"
      )

    true =
      external.state in [
        :staging,
        :verifying,
        :sealing,
        :ready,
        :quarantined,
        :retiring,
        :deleted
      ]

    value = external.payload

    %{
      id: external.id,
      revision: external.revision,
      state: external.state,
      directory: external.directory,
      filename: external.filename,
      payload: %{
        state: external.state,
        host_id: Map.fetch!(value, "host_id"),
        pool_id: Map.fetch!(value, "pool_id"),
        image_id: Map.fetch!(value, "image_id"),
        incarnation: Map.fetch!(value, "incarnation"),
        nonce: Map.fetch!(value, "nonce"),
        guid: Map.fetch!(value, "guid"),
        bytes: Map.fetch!(value, "bytes"),
        identities: Map.fetch!(value, "identities")
      }
    }
  end

  @spec assert_transition(Pool.t(), template_record(), :quarantined | :deleted, pos_integer()) ::
          :ok
  defp assert_transition(pool, frozen, state, revision_delta) do
    record = load(pool, frozen.payload.incarnation)
    true = record.id == frozen.id and record.state == state
    true = record.revision == frozen.revision + revision_delta
    true = record.payload == Map.put(frozen.payload, :state, state)
    true = record.directory == frozen.directory and record.filename == frozen.filename
    :ok
  end

  @spec verify_public_reader(Pool.t(), Image.t(), template_record(), lock_identity(), integer()) ::
          :ok
  defp verify_public_reader(pool, image, record, expected_lock, deadline) do
    :ok = before_deadline(deadline)

    :ok =
      ImageTemplate.with_image(pool, image, fn sealed ->
        true = sealed.id == image.id
        true = sealed.path == directory(pool, record)
        true = sealed.template_record_id == record.id
        true = sealed.template_incarnation == record.payload.incarnation
        true = sealed.source_lease == Path.join(lease_directory(pool, image), "owner.lock")
        true = Lock.held?(Lock.current())
        true = lock_identity(lease_directory(pool, image)) == expected_lock
        true = load(pool, record.payload.incarnation) == record
        :ok = native(pool, record)
        {:ok, verified} = bounded_hash(sealed.path, lease_directory(pool, image))
        true = verified.id == image.id and verified.verified
        true = bytes(verified) == record.payload.bytes
        {:ok, observed} = Image.identities(verified)
        # Exact, or st_dev-only drift that ADR-0182 accepts; nothing else.
        _ = classify(record.payload.identities, observed)
        {:ok, _} = Image.sealed(sealed.path, observed)
        :ok = native(pool, record)
        true = load(pool, record.payload.incarnation) == record
        true = lock_identity(lease_directory(pool, image)) == expected_lock
        :ok = before_deadline(deadline)
        :ok
      end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] post-import-native-proof-is-independent
  # Every artifact read MUST be bracketed by successful pool-locked native
  # observations of unchanged parent identity, exact owner/nonce/GUID, readonly
  # dataset execution seal, root-private directory and exactly four safe files.
  # Failed native observations MUST abort, never become absence or retries.
  @spec native(Pool.t(), template_record()) :: :ok
  defp native(pool, record) do
    :ok =
      Storage.locked(
        pool,
        fn ->
          identity = Pool.zfs_identity(pool)
          {:ok, ^identity} = ZFS.inspect_path(pool.path)
          guid = record.payload.guid
          {:ok, ^guid} = ZFS.template_child(identity, name(pool, record), guid, :on)
          {:ok, owners} = ZFS.owners(identity)
          owner = Map.get(owners, name(pool, record))
          true = is_map(owner)
          true = owner["host"] == pool.host_id and owner["pool"] == pool.id
          true = owner["vm"] == "-" and owner["nonce"] == record.payload.nonce
          true = owner["guid"] == guid
          :ok = private_directory(directory(pool, record))
          {:ok, files} = File.ls(directory(pool, record))
          true = Enum.sort(files) == @files

          Enum.each(@files, fn file ->
            {:ok, %File.Stat{type: :regular, uid: 0, links: 1, mode: mode}} =
              File.lstat(Path.join(directory(pool, record), file))

            true = band(mode, 0o222) == 0
          end)

          {:ok, ^identity} = ZFS.inspect_path(pool.path)
          :ok
        end,
        0
      )

    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] post-import-template-absence-needs-success
  # Template absence MUST follow successful owned-parent dataset and mount
  # observations, with no exact name/descendant/snapshot or relevant mount alias.
  # A remaining canonical stub MUST be an empty root-private directory and MUST
  # NOT be unlinked or treated as dataset authority by fixture code.
  # A command failure MUST NOT establish absence. VM-only absent_child cannot
  # be used for template dataset names.
  @spec absent_template(Pool.t(), template_record()) :: :ok
  defp absent_template(pool, record) do
    :ok =
      Storage.locked(
        pool,
        fn ->
          identity = Pool.zfs_identity(pool)
          {:ok, ^identity} = ZFS.inspect_path(pool.path)
          {:ok, owners} = ZFS.owners(identity)
          dataset = name(pool, record)
          path = directory(pool, record)

          true =
            Enum.all?(Map.keys(owners), fn name ->
              name != dataset and
                not String.starts_with?(name, [dataset <> "/", dataset <> "@", dataset <> "#"])
            end)

          {:ok, mounts} = ZFS.mounts()

          true =
            Enum.all?(mounts, fn
              %{"source" => source, "target" => target}
              when is_binary(source) and is_binary(target) ->
                source != dataset and
                  not String.starts_with?(source, [dataset <> "[", dataset <> "@", dataset <> "/"]) and
                  target != path and not String.starts_with?(target, path <> "/")

              _ ->
                false
            end)

          # Native destruction may leave an empty canonical mountpoint stub.
          # Successful dataset/mount observations above establish no authority;
          # the fixture never removes or repairs that unmounted directory.
          :ok = absent_mountpoint(path)

          {:ok, ^identity} = ZFS.inspect_path(pool.path)
          :ok
        end,
        0
      )

    :ok
  end

  @spec absent_mountpoint(Path.t()) :: :ok
  defp absent_mountpoint(path) do
    # A claimed dataset root belongs to Lilly's service user.
    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory, uid: 0, mode: mode}} ->
        true = band(mode, 0o7777) == 0o700
        # As `lilly` (ADR-0182) a root-owned 0700 mountpoint ZFS left behind
        # cannot be listed; only root can prove it empty. Lilly's own removal
        # needs only its parent.
        listing = File.ls(path)
        true = listing == {:ok, []} or listing == {:error, :eacces}

        :ok
    end
  end

  @spec unused_placement(Config.t(), Pool.t(), Spec.t()) :: :ok
  defp unused_placement(config, pool, spec) do
    directory = Path.join(config.state_dir, spec.id)
    {:ok, :stopped} = Unit.status(spec)
    true = Boot.read(directory) == {:ok, nil}
    true = Intent.read(directory) == {:ok, nil}
    {:error, :enoent} = File.lstat(Path.join(directory, "launch-attempt.bin"))

    :ok =
      Storage.locked(
        pool,
        fn ->
          :ok = ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec))
          {:error, :enoent} = File.lstat(ZFSDataset.directory(pool, spec))
          :ok
        end,
        0
      )

    :ok
  end

  @spec lock_identity(Path.t()) :: lock_identity()
  defp lock_identity(directory) do
    :ok = private_directory(Path.dirname(Path.dirname(directory)))
    :ok = private_directory(Path.dirname(directory))
    :ok = private_directory(directory)

    {:ok,
     %File.Stat{type: :regular, uid: 0, links: 1, mode: mode, major_device: device, inode: inode}} =
      Lilly.Host.Privilege.lstat(Path.join(directory, "owner.lock"))

    true = band(mode, 0o7777) == 0o600
    true = is_integer(device) and device >= 0 and is_integer(inode) and inode > 0
    {device, inode}
  end

  @spec private_directory(Path.t()) :: :ok
  defp private_directory(path) do
    # Lilly creates lock directories as its service user (ADR-0182); Privilege.lstat reports that uid as 0. hostd hands owner.lock
    # inodes to the service user too, so its helpers can flock them.
    {:ok, %File.Stat{type: :directory, uid: 0, mode: mode}} = Lilly.Host.Privilege.lstat(path)
    true = band(mode, 0o7777) == 0o700
    :ok
  end

  # Only the read-only full hash is cancellable; public mutation APIs are called
  # directly and retain their existing native per-operation limits.
  @spec bounded_hash(Path.t(), Path.t()) :: {:ok, Image.t()}
  defp bounded_hash(path, lease_directory) do
    task =
      Task.async(fn ->
        # Process-local native ownership is not inherited by tasks. This reader
        # acquires its own shared descriptor on the same stable source inode;
        # its utility children retain that lease after cancellation/caller death.
        {:ok, task_owner} = Lock.shared(lease_directory)

        try do
          Image.load(path)
        after
          :ok = Lock.release(task_owner)
        end
      end)

    case Task.yield(task, @hash_timeout_ms) do
      {:ok, {:ok, image}} ->
        {:ok, image}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        raise "post-import full hash exceeded bounded read budget"

      _ ->
        raise "post-import full hash failed"
    end
  end

  @spec before_deadline(integer()) :: :ok
  defp before_deadline(deadline) do
    true = System.monotonic_time(:millisecond) < deadline
    :ok
  end

  @spec bytes(Image.t()) :: pos_integer()
  defp bytes(image), do: Enum.sum(Enum.map(image.files, fn {_, {_, stat}} -> stat.size end))

  @spec lease_directory(Pool.t(), Image.t()) :: Path.t()
  defp lease_directory(pool, image),
    do:
      Path.join([
        pool.path,
        ".lilly-templates",
        "locks",
        String.replace_prefix(image.id, "sha256:", "")
      ])

  @spec directory(Pool.t(), template_record()) :: Path.t()
  defp directory(pool, record),
    do: Path.join([pool.path, "templates", record.payload.incarnation])

  @spec name(Pool.t(), template_record()) :: String.t()
  defp name(pool, record), do: pool.storage.dataset <> "/template-" <> record.payload.incarnation
end
