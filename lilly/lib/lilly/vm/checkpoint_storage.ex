defmodule Lilly.VM.CheckpointStorage do
  @moduledoc "Two independently owned immutable RAM datasets, outside the portable workload disk."
  import Bitwise
  alias Lilly.Host.{Command, Pool, PrivateFiles, Privilege, Storage, ZFS}
  alias Lilly.VM.{Checkpoint, Spec}
  alias OverallsProtocol.Checkpoint, as: Descriptor
  @suffix "lilly-checkpoint"
  @type failure :: {:error, :checkpoint_unconfirmed | :storage_busy}

  @spec name(Pool.t(), String.t(), String.t()) :: String.t()
  def name(pool, placement, slot),
    do: pool.storage.dataset <> "/checkpoint-" <> placement <> "-" <> slot

  @spec path(Pool.t(), String.t(), String.t()) :: Path.t()
  def path(pool, placement, slot),
    do: Path.join([pool.path, ".lilly-checkpoints", placement, slot])

  @spec output(Pool.t(), String.t(), String.t()) :: Path.t()
  def output(pool, placement, slot), do: Path.join(path(pool, placement, slot), "output")

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-create-requires-local-intent
  # prepare/2 requires an empty VMM and cleaned jail. Each fresh native dataset
  # MUST have a durable unpredictable nonce before creation, then a fixed GUID.
  # Discovered names or tags alone MUST NOT establish checkpoint ownership.
  @spec prepare(Pool.t(), Spec.t()) :: :ok | failure()
  def prepare(pool, spec) do
    Storage.locked(pool, fn ->
      with :ok <- private_roots(pool, spec.id),
           {:ok, record} <- existing_or_initial(pool, spec),
           {:ok, record} <- prepare_slot(pool, spec, record, "a"),
           {:ok, _record} <- prepare_slot(pool, spec, record, "b"),
           do: :ok,
           else: (_ -> failure())
    end)
  end

  defp existing_or_initial(pool, spec) do
    case Checkpoint.read(pool, spec.id) do
      {:ok, nil} ->
        value = Checkpoint.initial(pool, spec)
        with :ok <- Checkpoint.write(pool, spec.id, value), do: {:ok, value}

      {:ok, %{"binding" => binding} = value} ->
        cond do
          binding == Checkpoint.binding(pool, spec) ->
            {:ok, value}

          value["phase"] == "empty" and value["slots"] == %{} and
              Map.delete(binding, "workload") ==
                Map.delete(Checkpoint.binding(pool, spec), "workload") ->
            next = Checkpoint.initial(pool, spec)
            with :ok <- Checkpoint.write(pool, spec.id, next), do: {:ok, next}

          true ->
            failure()
        end

      _ ->
        failure()
    end
  end

  defp prepare_slot(pool, spec, record, slot) do
    case record["slots"][slot] do
      nil ->
        leaf = %{
          "state" => "creating",
          "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "dataset_guid" => nil,
          "snapshot_guid" => nil,
          "checkpoint_id" => nil
        }

        next = put_in(record, ["slots", slot], leaf)

        with :ok <- Checkpoint.write(pool, spec.id, next),
             do: prepare_slot(pool, spec, next, slot)

      %{"state" => "creating"} = leaf ->
        with :ok <- create_or_match(pool, spec, slot, leaf),
             {:ok, guid} <- native(pool, spec, slot, leaf, :off),
             :ok <- Privilege.claim_directory(path(pool, spec.id, slot)),
             :ok <- PrivateFiles.directory(output(pool, spec.id, slot)),
             {:ok, _} <-
               Command.run(:chown, [
                 "#{spec.network.uid}:#{spec.network.uid}",
                 "--",
                 output(pool, spec.id, slot)
               ]),
             next =
               put_in(record, ["slots", slot], %{
                 leaf
                 | "state" => "empty",
                   "dataset_guid" => guid
               }),
             :ok <- Checkpoint.write(pool, spec.id, next),
             do: {:ok, next},
             else: (_ -> failure())

      %{"state" => "empty"} = leaf ->
        with {:ok, _} <- native(pool, spec, slot, leaf, :off),
             :ok <- empty_output(spec, output(pool, spec.id, slot)),
             do: {:ok, record}

      %{"state" => "sealed"} = leaf ->
        with {:ok, _} <- native(pool, spec, slot, leaf, :on), do: {:ok, record}

      _ ->
        failure()
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] checkpoint-empty-output-reverified-unprivileged
  # An already-empty slot (a start without an intervening stop, such as after host
  # loss) MUST still prove its output directory is an empty real directory. The
  # unprivileged BEAM (ADR-0182) cannot list the 0700 jail-uid directory, so it
  # reclaims it through hostd's single-path no-dereference chown, lists it, and
  # MUST return it to the jail uid before success. Any entry or failed step refuses.
  @spec empty_output(Spec.t(), Path.t()) :: :ok | failure()
  defp empty_output(spec, out) do
    uid = Privilege.service_uid()
    jail = "#{spec.network.uid}:#{spec.network.uid}"

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(out),
         {:ok, _} <- Command.run(:chown, ["--no-dereference", "#{uid}:#{uid}", "--", out]),
         {:ok, []} <- File.ls(out),
         {:ok, _} <- Command.run(:chown, ["--no-dereference", jail, "--", out]),
         do: :ok,
         else: (_ -> failure())
  end

  defp create_or_match(pool, spec, slot, leaf) do
    dataset = name(pool, spec.id, slot)

    case Command.run(:zfs_list, ["-Hp", "-o", "name", dataset]) do
      {:ok, output} when output == dataset <> "\n" ->
        :ok

      {:error, :command_failed} ->
        properties = [
          "mountpoint=" <> path(pool, spec.id, slot),
          "compression=lz4",
          "reservation=0",
          "refreservation=0",
          "dedup=off",
          "sync=standard",
          "readonly=off",
          "canmount=on",
          "quota=" <>
            Integer.to_string(OverallsProtocol.VMShape.checkpoint_bytes(spec.memory_bytes)),
          "refquota=none",
          "lilly:host=" <> pool.host_id,
          "lilly:pool=" <> pool.id,
          "lilly:vm=" <> spec.id,
          "lilly:nonce=" <> leaf["nonce"]
        ]

        with {:ok, _} <-
               Command.run(:zfs_create, Enum.flat_map(properties, &["-o", &1]) ++ [dataset]),
             do: :ok

      _ ->
        failure()
    end
  end

  @spec seal(Pool.t(), Spec.t(), Checkpoint.journal_record()) ::
          {:ok, Descriptor.t(), map()} | failure()
  def seal(pool, spec, %{"phase" => "copied"} = record) do
    slot = record["slot"]
    leaf = record["slots"][slot]
    root = path(pool, spec.id, slot)
    out = output(pool, spec.id, slot)
    manifest = JSON.encode!(record["manifest"])

    with {:ok, _} <- native(pool, spec, slot, leaf, :either),
         :ok <- claim_files(pool, spec, slot, leaf, out),
         {:ok, ["memory", "state"]} <- sorted_entries(out),
         {:ok, memory_hash} <- Checkpoint.hash_file(Path.join(out, "memory"), spec.memory_bytes),
         {:ok, %File.Stat{type: :regular, links: 1, size: state_bytes}} <-
           File.lstat(Path.join(out, "state")),
         true <- state_bytes in 1..Descriptor.overhead_bytes(),
         {:ok, state_hash} <- Checkpoint.hash_file(Path.join(out, "state"), state_bytes),
         :ok <- write_manifest(root, manifest),
         {:ok, _} <- Command.run(:sync, ["--", root], 14_400_000),
         {:ok, _} <- Command.run(:zfs_set, ["readonly=on", name(pool, spec.id, slot)]),
         {:ok, snapshot_guid} <- snapshot(pool, spec, slot, record["checkpoint_id"]),
         descriptor = %{
           id: record["checkpoint_id"],
           memory_bytes: spec.memory_bytes,
           state_bytes: state_bytes,
           compatibility: record["manifest"]["compatibility"],
           memory_sha256: memory_hash,
           state_sha256: state_hash,
           manifest_sha256: Checkpoint.digest(manifest),
           dataset_guid: leaf["dataset_guid"],
           snapshot_guid: snapshot_guid
         },
         {:ok, ^descriptor} <- descriptor |> Descriptor.encode() |> Descriptor.decode(),
         next =
           Map.put(record["slots"], slot, %{
             leaf
             | "state" => "sealed",
               "snapshot_guid" => snapshot_guid
           }),
         :ok <-
           verify(pool, spec, %{
             record
             | "descriptor" => Descriptor.encode(descriptor),
               "slots" => next
           }) do
      {:ok, descriptor, next}
    else
      _ -> failure()
    end
  end

  def seal(_, _, _), do: failure()

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-seal-native-single-path
  # Sealing MUST reclaim each snapshot output through hostd's existing
  # single-path no-dereference chown grammar; a shell-style multi-path chown
  # MUST NOT prevent a copied checkpoint from becoming immutable and ready.
  # An interrupted ownership/mode change MUST verify both outputs before
  # skipping repair. Incomplete files MUST be repaired only in a dataset
  # independently proven writable; readonly incomplete outputs fail closed.
  @spec claim_files(Pool.t(), Spec.t(), String.t(), map(), Path.t()) :: :ok | failure()
  defp claim_files(pool, spec, slot, leaf, out) do
    uid = Privilege.service_uid()

    if sealed_outputs?(out) do
      :ok
    else
      with {:ok, _} <- native(pool, spec, slot, leaf, :off),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(out),
           {:ok, _} <- Command.run(:chown, ["--no-dereference", "#{uid}:#{uid}", "--", out]),
           {:ok, ["memory", "state"]} <- sorted_entries(out),
           {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(Path.join(out, "memory")),
           {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(Path.join(out, "state")),
           {:ok, _} <-
             Command.run(:chown, [
               "--no-dereference",
               "#{uid}:#{uid}",
               "--",
               Path.join(out, "memory")
             ]),
           {:ok, _} <-
             Command.run(:chown, [
               "--no-dereference",
               "#{uid}:#{uid}",
               "--",
               Path.join(out, "state")
             ]),
           :ok <- Privilege.chmod(out, 0o700),
           :ok <- Privilege.chmod(Path.join(out, "memory"), 0o444),
           :ok <- Privilege.chmod(Path.join(out, "state"), 0o444),
           do: :ok
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] both-checkpoint-outputs-sealed
  # Only two independently verified regular, singly linked, service/root-owned
  # 0444 output files may skip ownership and mode repair after interruption.
  @doc false
  @spec sealed_outputs?(Path.t()) :: boolean()
  def sealed_outputs?(out) do
    sealed_file(Path.join(out, "memory")) == :ok and
      sealed_file(Path.join(out, "state")) == :ok
  end

  defp write_manifest(root, bytes) do
    case File.lstat(Path.join(root, "manifest.json")) do
      {:error, :enoent} ->
        PrivateFiles.write(root, "manifest.json", bytes)

      {:ok, _} ->
        with {:ok, ^bytes} <- PrivateFiles.read_secret(Path.join(root, "manifest.json")),
             do: :ok,
             else: (_ -> failure())

      _ ->
        failure()
    end
  end

  defp snapshot(pool, spec, slot, nonce) do
    target = name(pool, spec.id, slot) <> "@" <> @suffix

    case Command.run(:zfs_get, ["-Hp", "-o", "value,source", "lilly:transfer_nonce", target]) do
      {:ok, value} when value == nonce <> "\tlocal\n" ->
        snapshot_guid(target)

      {:error, :command_failed} ->
        with {:ok, _} <-
               Command.run(:zfs_snapshot, ["-o", "lilly:transfer_nonce=" <> nonce, target]),
             do: snapshot_guid(target)

      _ ->
        failure()
    end
  end

  defp snapshot_guid(target) do
    with {:ok, value} <- Command.run(:zfs_get, ["-Hp", "-o", "value", "guid", target]),
         guid = String.trim_trailing(value, "\n"),
         true <- OverallsProtocol.Storage.guid?(guid),
         do: {:ok, guid},
         else: (_ -> failure())
  end

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-content-at-point-of-use
  # verify/3 MUST require journal-bound native GUIDs, creation nonces, exact
  # private file sets and hashes, and a readonly dataset before RAM is exported
  # or loaded. Neither file lengths nor a peer descriptor establishes ownership.
  @spec verify(Pool.t(), Spec.t(), Checkpoint.journal_record()) :: :ok | failure()
  def verify(pool, spec, record) do
    slot = record["slot"]
    root = path(pool, spec.id, slot)
    out = output(pool, spec.id, slot)

    with true <- record["binding"] == Checkpoint.binding(pool, spec),
         true <- Checkpoint.workload_matches?(record["manifest"], spec),
         {:ok, descriptor} <- Descriptor.decode(record["descriptor"]),
         true <- descriptor.memory_bytes == spec.memory_bytes,
         %{"state" => "sealed", "dataset_guid" => dataset_guid, "snapshot_guid" => snapshot_guid} =
           leaf <- record["slots"][slot],
         true <- snapshot_guid == descriptor.snapshot_guid,
         {:ok, ^dataset_guid} <- native(pool, spec, slot, leaf, :on),
         {:ok, ["manifest.json", "output"]} <- sorted_entries(root),
         {:ok, ["memory", "state"]} <- sorted_entries(out),
         {:ok, bytes} <- PrivateFiles.read_secret(Path.join(root, "manifest.json")),
         true <- Checkpoint.digest(bytes) == descriptor.manifest_sha256,
         {:ok, manifest} <- JSON.decode(bytes),
         true <- manifest == record["manifest"],
         {:ok, hash} <- Checkpoint.hash_file(Path.join(out, "memory"), descriptor.memory_bytes),
         true <- hash == descriptor.memory_sha256,
         {:ok, hash} <- Checkpoint.hash_file(Path.join(out, "state"), descriptor.state_bytes),
         true <- hash == descriptor.state_sha256,
         :ok <- sealed_file(Path.join(out, "memory")),
         :ok <- sealed_file(Path.join(out, "state")),
         do: :ok,
         else: (_ -> failure())
  end

  @spec native(Pool.t(), Spec.t(), String.t(), map(), :on | :off | :either) ::
          {:ok, String.t()} | failure()
  def native(pool, spec, slot, leaf, seal) do
    dataset = name(pool, spec.id, slot)

    with true <- ZFS.staging_identity?(Pool.zfs_identity(pool)),
         {:ok, output} <-
           Command.run(:zfs_list, [
             "-Hp",
             "-t",
             "all",
             "-o",
             Enum.join(ZFS.properties(), ","),
             "-r",
             dataset
           ]),
         {:ok, rows} <- ZFS.parse_datasets(output),
         %{^dataset => row} <- rows,
         true <- ZFS.checkpoint_row?({dataset, row}, Pool.zfs_identity(pool)),
         true <- is_nil(leaf["dataset_guid"]) or row["guid"] == leaf["dataset_guid"],
         true <- row["quota"] == OverallsProtocol.VMShape.checkpoint_bytes(spec.memory_bytes),
         true <- seal == :either or row["readonly"] == Atom.to_string(seal),
         expected_snapshot = if(leaf["snapshot_guid"], do: [dataset <> "@" <> @suffix], else: []),
         true <-
           Enum.sort(Map.keys(rows)) == Enum.sort([dataset | expected_snapshot]) or
             (not is_nil(leaf["checkpoint_id"]) and is_nil(leaf["snapshot_guid"]) and
                Enum.sort(Map.keys(rows)) == Enum.sort([dataset, dataset <> "@" <> @suffix]) and
                Lilly.Transfer.SnapshotOwnership.marker?(
                  dataset <> "@" <> @suffix,
                  leaf["checkpoint_id"]
                )),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool), dataset),
         true <- Enum.sort(Map.keys(owners)) == Enum.sort(Map.keys(rows)),
         true <-
           Enum.all?(owners, fn {name, owner} ->
             owner["guid"] == rows[name]["guid"] and
               Map.drop(owner, ["guid"]) == %{
                 "host" => pool.host_id,
                 "pool" => pool.id,
                 "vm" => spec.id,
                 "nonce" => leaf["nonce"]
               }
           end),
         true <-
           is_nil(leaf["snapshot_guid"]) or
             (rows[dataset <> "@" <> @suffix]["guid"] == leaf["snapshot_guid"] and
                Lilly.Transfer.SnapshotOwnership.marker?(
                  dataset <> "@" <> @suffix,
                  leaf["checkpoint_id"]
                )),
         {:ok, mounts} <- ZFS.mounts(),
         true <- mounts_valid?(pool, spec.id, slot, mounts, :mounted, true),
         do: {:ok, row["guid"]},
         else: (_ -> failure())
  end

  @spec expectations(Pool.t(), String.t()) :: {:ok, ZFS.snapshots()} | failure()
  def expectations(pool, placement) do
    case Checkpoint.read(pool, placement) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, record} ->
        Enum.reduce_while(record["slots"], {:ok, %{}}, fn {slot, leaf}, {:ok, acc} ->
          if leaf["snapshot_guid"] do
            target = name(pool, placement, slot) <> "@" <> @suffix

            if Lilly.Transfer.SnapshotOwnership.marker?(target, leaf["checkpoint_id"]),
              do:
                {:cont,
                 {:ok,
                  Map.put(acc, target, %{
                    dataset_guid: leaf["dataset_guid"],
                    snapshot_guid: leaf["snapshot_guid"]
                  })}},
              else: {:halt, failure()}
          else
            {:cont, {:ok, acc}}
          end
        end)

      _ ->
        failure()
    end
  end

  @spec pool_expectations(Pool.t()) :: {:ok, ZFS.snapshots()} | failure()
  def pool_expectations(pool) do
    root = Path.join(pool.path, ".lilly-checkpoint-state")

    case File.ls(root) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, entries} ->
        if length(entries) <= 4096 and Enum.all?(entries, &OverallsProtocol.uuid?/1) do
          Enum.reduce_while(entries, {:ok, %{}}, fn placement, {:ok, acc} ->
            case expectations(pool, placement) do
              {:ok, expected} -> {:cont, {:ok, Map.merge(acc, expected)}}
              _ -> {:halt, failure()}
            end
          end)
        else
          failure()
        end

      _ ->
        failure()
    end
  end

  @doc "Provision the unused slot after a received immutable checkpoint is adopted."
  @spec prepare_unused(Pool.t(), Spec.t()) :: :ok | failure()
  def prepare_unused(pool, spec) do
    with {:ok, %{"phase" => "ready"} = record} <- Checkpoint.read(pool, spec.id),
         other = if(record["slot"] == "a", do: "b", else: "a"),
         {:ok, _} <- prepare_slot(pool, spec, record, other),
         do: :ok,
         else: (_ -> failure())
  end

  @doc "After confirmed VMM/jail emptiness, reclaim the previous immutable RAM backing."
  @spec recycle_other(Pool.t(), Spec.t()) :: :ok | failure()
  def recycle_other(pool, spec) do
    Storage.locked(pool, fn ->
      with {:ok, %{"phase" => "ready"} = record} <- Checkpoint.read(pool, spec.id) do
        other = if record["slot"] == "a", do: "b", else: "a"

        case record["slots"][other] do
          %{"state" => "empty"} ->
            :ok

          %{"state" => "sealed"} = leaf ->
            retiring = %{leaf | "state" => "retiring"}

            with :ok <-
                   Checkpoint.write(pool, spec.id, put_in(record, ["slots", other], retiring)),
                 :ok <- destroy_leaf(pool, spec, other, retiring),
                 next = put_in(record, ["slots", other], nil),
                 next = %{next | "slots" => Map.delete(next["slots"], other)},
                 :ok <- Checkpoint.write(pool, spec.id, next),
                 {:ok, _} <- prepare_slot(pool, spec, next, other),
                 do: :ok,
                 else: (_ -> failure())

          %{"state" => "retiring"} = leaf ->
            with :ok <- destroy_leaf(pool, spec, other, leaf),
                 next = %{record | "slots" => Map.delete(record["slots"], other)},
                 :ok <- Checkpoint.write(pool, spec.id, next),
                 {:ok, _} <- prepare_slot(pool, spec, next, other),
                 do: :ok,
                 else: (_ -> failure())

          _ ->
            failure()
        end
      else
        _ -> failure()
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-retired-before-destruction
  # retire/2 requires an empty VMM and cleaned jail. It MUST permanently revoke
  # continuation authority before any exact snapshot/dataset destruction. It
  # never recursively destroys a dataset or adopts an unjournaled leaf.
  @spec retire(Pool.t(), Spec.t()) :: :ok | failure()
  def retire(pool, spec) do
    Storage.locked(pool, fn ->
      case Checkpoint.read(pool, spec.id) do
        {:ok, nil} ->
          :ok

        {:ok, record} ->
          with true <- record["binding"] == Checkpoint.binding(pool, spec),
               retired = %{record | "phase" => "retired"},
               :ok <- Checkpoint.write(pool, spec.id, retired),
               :ok <-
                 Enum.reduce_while(retired["slots"], :ok, fn {slot, leaf}, :ok ->
                   case destroy_leaf(pool, spec, slot, leaf) do
                     :ok -> {:cont, :ok}
                     _ -> {:halt, failure()}
                   end
                 end),
               :ok <- Checkpoint.write(pool, spec.id, Checkpoint.initial(pool, spec)),
               do: :ok,
               else: (_ -> failure())

        _ ->
          failure()
      end
    end)
  end

  defp destroy_leaf(pool, spec, slot, leaf) do
    dataset = name(pool, spec.id, slot)

    case Command.run(:zfs_list, ["-Hp", "-o", "name", dataset]) do
      {:error, :command_failed} ->
        :ok

      {:ok, output} when output == dataset <> "\n" ->
        with {:ok, snapshot} <- cleanup_native(pool, spec, slot, leaf),
             :ok <- destroy_snapshot(snapshot),
             {:ok, nil} <- cleanup_native(pool, spec, slot, leaf),
             {:ok, _} <- Command.run(:zfs_destroy, [dataset]),
             {:error, :command_failed} <- Command.run(:zfs_list, ["-Hp", "-o", "name", dataset]),
             do: :ok,
             else: (_ -> failure())

      _ ->
        failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-cleanup-replays-only-revoked-owned-leaves
  # Cleanup MUST require a durable retired journal or retiring slot before
  # accepting a missing snapshot, an interrupted create or an unmounted noauto
  # receive. It MUST still match the native parent, local nonce, every known
  # GUID and the exact optional checkpoint snapshot; an unbound snapshot needs
  # its checkpoint UUID marker. Descendants and unknown snapshots MUST refuse.
  defp cleanup_native(pool, spec, slot, leaf) do
    dataset = name(pool, spec.id, slot)
    target = dataset <> "@" <> @suffix

    with {:ok, record} when is_map(record) <- Checkpoint.read(pool, spec.id),
         true <- record["binding"] == Checkpoint.binding(pool, spec),
         true <- record["slots"][slot] == leaf,
         true <- record["phase"] == "retired" or leaf["state"] == "retiring",
         true <- ZFS.staging_identity?(Pool.zfs_identity(pool)),
         {:ok, output} <-
           Command.run(:zfs_list, [
             "-Hp",
             "-t",
             "all",
             "-o",
             Enum.join(ZFS.properties(), ","),
             "-r",
             dataset
           ]),
         {:ok, rows} <- ZFS.parse_datasets(output),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool), dataset),
         {:ok, mounts} <- ZFS.mounts(),
         true <-
           mounts_valid?(
             pool,
             spec.id,
             slot,
             mounts,
             if(rows[dataset]["mounted"] == "yes", do: :mounted, else: :unmounted),
             false
           ),
         cleanup_leaf = cleanup_leaf(record, slot, leaf),
         marker =
           Map.has_key?(rows, target) and is_binary(leaf["checkpoint_id"]) and
             Lilly.Transfer.SnapshotOwnership.marker?(target, leaf["checkpoint_id"]),
         true <-
           cleanup_observation?(pool, spec, slot, cleanup_leaf, %{
             rows: rows,
             owners: owners,
             marker: marker
           }),
         do: {:ok, if(Map.has_key?(rows, target), do: target)},
         else: (_ -> failure())
  end

  defp cleanup_leaf(%{"relocation" => relocation, "slot" => slot} = record, slot, leaf)
       when not is_nil(relocation) do
    case Descriptor.decode(record["descriptor"]) do
      {:ok, descriptor} -> Map.put(leaf, "snapshot_guid", descriptor.snapshot_guid)
      _ -> leaf
    end
  end

  defp cleanup_leaf(_, _, leaf), do: leaf

  @doc false
  @spec cleanup_observation?(Pool.t(), Spec.t(), String.t(), map(), %{
          rows: ZFS.tree(),
          owners: %{String.t() => map()},
          marker: boolean()
        }) :: boolean()
  def cleanup_observation?(pool, spec, slot, leaf, observed) do
    dataset = name(pool, spec.id, slot)
    target = dataset <> "@" <> @suffix
    rows = observed.rows

    with true <- slot in ["a", "b"],
         row when is_map(row) <- rows[dataset],
         true <- Enum.sort(Map.keys(rows)) in [Enum.sort([dataset]), Enum.sort([dataset, target])],
         true <- row["mounted"] in ["yes", "no"] and row["canmount"] in ["on", "noauto"],
         true <- row["canmount"] != "noauto" or row["readonly"] == "on",
         true <-
           ZFS.checkpoint_row?(
             {dataset, row |> Map.put("mounted", "yes") |> Map.put("canmount", "on")},
             Pool.zfs_identity(pool)
           ),
         true <- row["quota"] == OverallsProtocol.VMShape.checkpoint_bytes(spec.memory_bytes),
         true <- is_nil(leaf["dataset_guid"]) or leaf["dataset_guid"] == row["guid"],
         true <- Enum.sort(Map.keys(observed.owners)) == Enum.sort(Map.keys(rows)),
         true <-
           Enum.all?(observed.owners, fn {name, owner} ->
             owner["guid"] == rows[name]["guid"] and
               Map.drop(owner, ["guid"]) == %{
                 "host" => pool.host_id,
                 "pool" => pool.id,
                 "vm" => spec.id,
                 "nonce" => leaf["nonce"]
               }
           end),
         true <-
           not Map.has_key?(rows, target) or
             (rows[target]["type"] == "snapshot" and
                (not is_nil(leaf["snapshot_guid"]) or observed.marker) and
                (is_nil(leaf["snapshot_guid"]) or leaf["snapshot_guid"] == rows[target]["guid"])),
         do: true,
         else: (_ -> false)
  end

  defp destroy_snapshot(nil), do: :ok

  defp destroy_snapshot(snapshot) do
    with {:ok, _} <- Command.run(:zfs_destroy, [snapshot]), do: :ok
  end

  @doc "Audit checkpoint ownership independently from ordinary disk allocation credits."
  @spec audit(Pool.t(), map(), map(), [ZFS.mount()]) ::
          {:ok, %{String.t() => non_neg_integer()}} | failure()
  def audit(pool, children, owners, mounts) do
    Enum.reduce_while(children, {:ok, %{}}, fn {dataset, observed}, {:ok, credits} ->
      prefix = pool.storage.dataset <> "/checkpoint-"
      suffix = String.replace_prefix(dataset, prefix, "")

      with [placement, slot] <- String.split(suffix, ~r/-(?=[ab]$)/),
           {:ok, record} when is_map(record) <- Checkpoint.read(pool, placement),
           binding = record["binding"],
           true <-
             binding["host_id"] == pool.host_id and binding["pool_id"] == pool.id and
               binding["placement_id"] == placement and
               binding["zpool_guid"] == pool.storage.zpool_guid and
               binding["parent_dataset_guid"] == pool.storage.dataset_guid,
           leaf when is_map(leaf) <- record["slots"][slot],
           true <- leaf["dataset_guid"] == observed.dataset_guid,
           owner when is_map(owner) <- owners[dataset],
           true <-
             Map.drop(owner, ["guid"]) == %{
               "host" => pool.host_id,
               "pool" => pool.id,
               "vm" => placement,
               "nonce" => leaf["nonce"]
             },
           true <- leaf["state"] in ["empty", "sealed"],
           true <- observed.readonly == if(leaf["state"] == "sealed", do: "on", else: "off"),
           true <- mounts_valid?(pool, placement, slot, mounts, :mounted, true),
           memory when is_integer(memory) <- binding["workload"]["memory_bytes"] do
        cap = OverallsProtocol.VMShape.checkpoint_bytes(memory)

        {:cont,
         {:ok,
          Map.update(
            credits,
            placement,
            min(observed.physical_bytes, cap),
            &min(&1 + observed.physical_bytes, 2 * cap)
          )}}
      else
        _ -> {:halt, failure()}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;isolation;capacity] checkpoint-mounts-are-exclusive
  # RAM ownership and allocation credit MUST require the one canonical dataset
  # root and only this placement's fixed capture/restore binds. Cleanup MUST
  # reject every remaining jail bind or other alias before destruction. An
  # unmounted receive MUST have no relevant mount, including snapshot aliases.
  @doc false
  @spec mounts_valid?(
          Pool.t(),
          String.t(),
          String.t(),
          [ZFS.mount()],
          :mounted | :unmounted,
          boolean()
        ) :: boolean()
  def mounts_valid?(pool, placement, slot, mounts, state, jail?) do
    dataset = name(pool, placement, slot)
    directory = path(pool, placement, slot)
    jail = Path.join([Lilly.VM.Jail.base(pool), "firecracker", placement, "root"])

    relevant =
      Enum.filter(mounts, fn mount ->
        source = mount["source"]
        target = mount["target"]

        is_binary(source) and is_binary(target) and
          (source == dataset or String.starts_with?(source, dataset <> "[") or
             String.starts_with?(source, dataset <> "@") or target == directory or
             String.starts_with?(target, directory <> "/"))
      end)

    root =
      Enum.filter(relevant, fn mount ->
        mount["target"] == directory and mount["source"] == dataset and
          mount["fstype"] == "zfs" and mount["fsroot"] == "/"
      end)

    (state == :unmounted and relevant == []) or
      (state == :mounted and length(root) == 1 and
         length(Enum.uniq_by(relevant, & &1["target"])) == length(relevant) and
         Enum.all?(relevant -- root, fn mount ->
           jail? and mount["fstype"] == "zfs" and
             Enum.any?(
               [
                 {"checkpoint-" <> slot, "/output"},
                 {"restore.memory", "/output/memory"},
                 {"restore.state", "/output/state"}
               ],
               fn {file, fsroot} ->
                 mount["target"] == Path.join(jail, file) and mount["fsroot"] == fsroot and
                   mount["source"] == dataset <> "[" <> fsroot <> "]"
               end
             )
         end))
  end

  defp private_roots(pool, placement) do
    with :ok <- PrivateFiles.directory(Path.join(pool.path, ".lilly-checkpoints")),
         :ok <- PrivateFiles.directory(Path.join([pool.path, ".lilly-checkpoints", placement])),
         do: :ok
  end

  defp sorted_entries(path) do
    with {:ok, entries} <- File.ls(path), do: {:ok, Enum.sort(entries)}
  end

  defp sealed_file(path) do
    with {:ok, %File.Stat{type: :regular, links: 1, uid: 0, mode: mode}} <- Privilege.lstat(path),
         true <- band(mode, 0o777) == 0o444,
         do: :ok,
         else: (_ -> failure())
  end

  defp failure, do: {:error, :checkpoint_unconfirmed}
end
