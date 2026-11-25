defmodule Lilly.VM.Checkpoint do
  @moduledoc "Durable single-use continuation journal and immutable checkpoint content verification."
  alias Lilly.Host.{Lock, Pool, PrivateFiles, Storage}
  alias Lilly.Lifecycle.Journal
  alias Lilly.VM.{Boot, CheckpointStorage, Intent, Spec}
  alias OverallsProtocol.Checkpoint, as: Descriptor
  @type slot :: :a | :b
  @type journal_record :: %{String.t() => term()}
  @type failure :: {:error, :checkpoint_unconfirmed | :storage_busy}
  @keys ~w(version binding phase checkpoint_id slot slots descriptor manifest capture_authority restore_authority relocation)

  @spec directory(Pool.t(), String.t()) :: Path.t()
  def directory(pool, placement), do: Path.join([pool.path, ".lilly-checkpoint-state", placement])

  @spec binding(Pool.t(), Spec.t()) :: map()
  def binding(pool, spec),
    do: %{
      "host_id" => pool.host_id,
      "pool_id" => pool.id,
      "placement_id" => spec.id,
      "zpool_guid" => pool.storage.zpool_guid,
      "parent_dataset_guid" => pool.storage.dataset_guid,
      "workload" => Spec.encode(Spec.storage(spec))
    }

  @spec read(Pool.t(), String.t()) :: {:ok, journal_record() | nil} | failure()
  def read(pool, placement) do
    with {:ok, value} <-
           Journal.load(Lilly.Lifecycle.Checkpoint, directory(pool, placement), "checkpoint.json") do
      {:ok, if(value, do: value.payload)}
    else
      _ -> failure()
    end
  end

  @spec write(Pool.t(), String.t(), journal_record()) :: :ok | failure()
  def write(pool, placement, value) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         :ok <- PrivateFiles.directory(Path.join(pool.path, ".lilly-checkpoint-state")),
         :ok <- PrivateFiles.directory(directory(pool, placement)),
         :ok <-
           Journal.write(
             Lilly.Lifecycle.Checkpoint,
             directory(pool, placement),
             "checkpoint.json",
             value
           ),
         do: :ok,
         else: (_ -> failure())
  end

  @spec initial(Pool.t(), Spec.t()) :: journal_record()
  def initial(pool, spec),
    do: %{
      "version" => 1,
      "binding" => binding(pool, spec),
      "phase" => "empty",
      "checkpoint_id" => nil,
      "slot" => nil,
      "slots" => %{},
      "descriptor" => nil,
      "manifest" => nil,
      "capture_authority" => nil,
      "restore_authority" => nil,
      "relocation" => nil
    }

  # @cc [owner:ghuntley,label:security;recovery] interrupted-pause-discard-needs-terminal-authority
  # A paused VMM may be discarded without publishing RAM only under stopped,
  # deleted or failed intent for this exact local binding, at least as new as
  # its capture/restore authority. Missing, corrupt, foreign, ready or retired
  # journals MUST NOT authorize forced paused cleanup. This predicate grants no
  # execution authority and MUST NOT advance the checkpoint phase.
  @spec discardable_pause?(term(), Pool.t(), Spec.t(), Intent.t()) :: boolean()
  def discardable_pause?(record, pool, spec, intent) do
    with true <- valid_record?(record),
         true <- record["binding"] == binding(pool, spec),
         true <- intent.placement_id == spec.id and intent.state in [:stopped, :deleted, :failed],
         %{"placement_id" => placement, "execution_epoch" => epoch, "generation" => generation} <-
           (case record["phase"] do
              phase when phase in ["capturing", "copied"] -> record["capture_authority"]
              phase when phase in ["restoring", "consumed"] -> record["restore_authority"]
              _ -> nil
            end) do
      placement == spec.id and
        {intent.execution_epoch, intent.generation} >= {epoch, generation}
    else
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] capture-journal-before-freeze
  # begin_capture/4 requires current running authority and the placement lock.
  # It MUST durably choose a fresh checkpoint ID and the empty opposite slot
  # before freezing vCPUs. An interrupted capture never invents ready RAM.
  @spec begin_capture(Pool.t(), Spec.t(), Boot.t(), map()) :: {:ok, journal_record()} | failure()
  def begin_capture(pool, spec, boot, authority) do
    with {:ok, compatibility} <- compatibility(),
         do: begin_capture(pool, spec, boot, authority, compatibility)
  end

  @spec begin_capture(Pool.t(), Spec.t(), Boot.t(), map(), String.t()) ::
          {:ok, journal_record()} | failure()
  def begin_capture(pool, spec, boot, authority, compatibility) do
    Storage.locked(pool, fn ->
      with {:ok, %{} = previous} <- read(pool, spec.id),
           true <- previous["binding"] == binding(pool, spec) do
        case previous do
          %{"phase" => "capturing", "capture_authority" => ^authority} ->
            {:ok, previous}

          %{"phase" => phase} when phase in ["empty", "consumed"] ->
            slot = if previous["slot"] == "a", do: "b", else: "a"

            with %{"state" => "empty"} <- previous["slots"][slot],
                 true <- OverallsProtocol.ImageManifest.id?(compatibility),
                 manifest = %{
                   "version" => 1,
                   "id" => Lilly.UUID.generate(),
                   "compatibility" => compatibility,
                   "guest_identity" =>
                     Map.new(Boot.expectation(boot), fn {k, v} -> {Atom.to_string(k), v} end),
                   "guest_boot_id" => Map.get(boot, :guest_boot_id),
                   "workload" => Spec.encode(Spec.storage(spec)),
                   "source_authority" => authority,
                   "memory_bytes" => spec.memory_bytes,
                   "slot" => slot
                 },
                 value = %{
                   previous
                   | "phase" => "capturing",
                     "checkpoint_id" => manifest["id"],
                     "slot" => slot,
                     "descriptor" => nil,
                     "manifest" => manifest,
                     "capture_authority" => authority,
                     "restore_authority" => nil,
                     "relocation" => nil
                 },
                 :ok <- write(pool, spec.id, value),
                 do: {:ok, value}

          _ ->
            failure()
        end
      else
        _ -> failure()
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] acknowledged-capture-journal-without-pool-turn
  # After an acknowledged snapshot/create, the caller MUST retain its live
  # placement lease for the configured placement directory and record copied
  # only for the exact local capture binding and authority. This private journal
  # transition changes no dataset, slot
  # ownership or allocation credit, so it MUST NOT acquire a competing pool
  # turn and discard the caller's successful-copy proof on storage contention.
  # Without that acknowledged API result a capturing journal cannot be promoted.
  @spec copied(Pool.t(), Spec.t(), map(), Path.t()) :: :ok | failure()
  def copied(pool, spec, authority, placement_directory) do
    with lease when is_struct(lease, Lilly.Host.Lease) <- Lock.current(),
         true <- lease.directory == placement_directory,
         true <- Lock.held?(lease),
         {:ok, %{"phase" => "capturing", "capture_authority" => ^authority} = value} <-
           read(pool, spec.id),
         true <- value["binding"] == binding(pool, spec),
         next = put_in(value, ["slots", value["slot"], "checkpoint_id"], value["checkpoint_id"]),
         do: write(pool, spec.id, %{next | "phase" => "copied"}),
         else: (_ -> failure())
  end

  @spec complete(Pool.t(), Spec.t(), map()) :: {:ok, Descriptor.t()} | failure()
  def complete(pool, spec, authority) do
    Storage.locked(pool, fn ->
      with {:ok, %{"phase" => "copied", "capture_authority" => ^authority} = value} <-
             read(pool, spec.id),
           {:ok, descriptor, slots} <- CheckpointStorage.seal(pool, spec, value),
           next = %{
             value
             | "phase" => "ready",
               "descriptor" => Descriptor.encode(descriptor),
               "slots" => slots
           },
           :ok <- write(pool, spec.id, next),
           do: {:ok, descriptor}
    end)
  end

  @spec ready(Pool.t(), Spec.t(), Descriptor.t() | nil) ::
          {:ok, Descriptor.t(), journal_record()} | failure()
  def ready(pool, spec, expected \\ nil) do
    with {:ok, %{"phase" => "ready"} = value} <- read(pool, spec.id),
         true <- value["binding"] == binding(pool, spec),
         {:ok, descriptor} <- Descriptor.decode(value["descriptor"]),
         true <- is_nil(expected) or descriptor == expected,
         :ok <- CheckpointStorage.verify(pool, spec, value),
         do: {:ok, descriptor, value},
         else: (_ -> failure())
  end

  # @cc [owner:ghuntley,label:security;recovery] restore-consumed-before-native-launch
  # consume/4 MUST persist the exact restore authority before a VMM may load RAM.
  # A newer generation MUST NOT reuse a consumed checkpoint. After interruption
  # only adoption of the exact already running restored VMM is allowed.
  @spec consume(Pool.t(), Spec.t(), Descriptor.t(), map()) :: {:ok, journal_record()} | failure()
  def consume(pool, spec, expected, authority) do
    with {:ok, compatibility} <- compatibility(),
         do: consume(pool, spec, expected, authority, compatibility)
  end

  @spec consume(Pool.t(), Spec.t(), Descriptor.t(), map(), String.t()) ::
          {:ok, journal_record()} | failure()
  def consume(pool, spec, expected, authority, compatibility) do
    Storage.locked(pool, fn ->
      with {:ok, ^expected, value} <- ready(pool, spec, expected),
           true <-
             OverallsProtocol.ImageManifest.id?(compatibility) and
               expected.compatibility == compatibility,
           next = %{value | "phase" => "restoring", "restore_authority" => authority},
           :ok <- write(pool, spec.id, next),
           do: {:ok, next}
    end)
  end

  @spec consumed(Pool.t(), Spec.t(), map()) :: :ok | failure()
  def consumed(pool, spec, authority) do
    Storage.locked(pool, fn ->
      with {:ok, %{"phase" => phase, "restore_authority" => ^authority} = value} <-
             read(pool, spec.id),
           true <- phase in ["restoring", "consumed"],
           do: write(pool, spec.id, %{value | "phase" => "consumed"}),
           else: (_ -> failure())
    end)
  end

  @spec backing(Pool.t(), Spec.t(), Descriptor.t(), map()) :: :ok | failure()
  def backing(pool, spec, expected, authority) do
    with {:ok, %{"phase" => phase, "restore_authority" => ^authority} = value} <-
           read(pool, spec.id),
         true <- phase in ["restoring", "consumed"],
         {:ok, ^expected} <- Descriptor.decode(value["descriptor"]),
         :ok <- CheckpointStorage.verify(pool, spec, value),
         do: :ok,
         else: (_ -> failure())
  end

  # @cc [owner:ghuntley,label:recovery;security] interrupted-live-restore-never-reloads-memory
  # After restore authority is consumed, the same confined VMM MAY be resumed
  # from Paused or adopted from Running. An unconfigured process, different
  # authority or any other journal phase MUST refuse; this decision never
  # authorizes another snapshot load. Callers MUST separately prove the exact
  # current boot, launched revision and unchanged native process incarnation.
  @doc false
  @spec restore_action(journal_record(), map(), Lilly.VM.API.state()) ::
          {:ok, :resume | :adopt} | failure()
  def restore_action(record, authority, state) do
    with true <- valid_record?(record),
         true <- record["phase"] in ["restoring", "consumed"],
         true <- record["restore_authority"] == authority do
      case state do
        :paused -> {:ok, :resume}
        :running -> {:ok, :adopt}
        _ -> failure()
      end
    else
      _ -> failure()
    end
  end

  @spec compatibility() :: {:ok, String.t()} | failure()
  def compatibility, do: compatibility(System.find_executable("firecracker"))

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-compatibility-binds-native-build
  # Compatibility MUST bind the exact VMM executable bytes, host kernel/KVM
  # build, CPU model/features and microcode. Missing facts MUST withhold restore
  # compatibility; the Firecracker semantic version alone is insufficient.
  @spec compatibility(Path.t() | nil) :: {:ok, String.t()} | failure()
  def compatibility(executable) when is_binary(executable) do
    with {:ok, executable} <- resolve_executable(executable, 8),
         {:ok, %File.Stat{type: :regular, size: bytes}} <- File.lstat(executable),
         true <- bytes in 1..67_108_864,
         {:ok, build_digest} <- hash_file(executable, bytes),
         {:ok, kernel} <- File.read("/proc/version"),
         true <- byte_size(kernel) in 1..4096,
         {:ok, cpu} <- File.read("/proc/cpuinfo"),
         [first | _] <- String.split(cpu, "\n\n"),
         fields =
           Map.new(String.split(first, "\n", trim: true), fn line ->
             case String.split(line, ":", parts: 2) do
               [key, value] -> {String.trim(key), String.trim(value)}
               _ -> {"", ""}
             end
           end),
         keys = ["vendor_id", "cpu family", "model", "stepping", "microcode", "flags"],
         true <- Enum.all?(keys, &(is_binary(fields[&1]) and fields[&1] != "")) do
      {:ok,
       digest(
         IO.iodata_to_binary([
           "firecracker:1.17.0:x86_64\n",
           build_digest,
           "\n",
           kernel | Enum.map(keys, &[&1, "=", fields[&1], "\n"])
         ])
       )}
    else
      _ -> failure()
    end
  end

  def compatibility(_), do: failure()

  defp resolve_executable(_, 0), do: failure()

  defp resolve_executable(path, remaining) do
    case File.read_link(path) do
      {:ok, target} -> resolve_executable(Path.expand(target, Path.dirname(path)), remaining - 1)
      {:error, :einval} -> {:ok, path}
      _ -> failure()
    end
  end

  @spec digest(binary()) :: String.t()
  def digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @spec hash_file(Path.t(), pos_integer()) :: {:ok, String.t()} | failure()
  def hash_file(path, bytes) do
    with {:ok, %File.Stat{type: :regular, links: 1, size: ^bytes}} <- File.lstat(path),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        hash_chunks(file, bytes, :crypto.hash_init(:sha256))
      after
        File.close(file)
      end
    else
      _ -> failure()
    end
  end

  defp hash_chunks(file, 0, context) do
    case :file.read(file, 1) do
      :eof -> {:ok, "sha256:" <> Base.encode16(:crypto.hash_final(context), case: :lower)}
      _ -> failure()
    end
  end

  defp hash_chunks(file, remaining, context) do
    case :file.read(file, min(remaining, 65_536)) do
      {:ok, bytes} when byte_size(bytes) > 0 ->
        hash_chunks(file, remaining - byte_size(bytes), :crypto.hash_update(context, bytes))

      _ ->
        failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-journal-is-closed-and-phase-coherent
  # Durable payloads MUST have the exact version, local binding, bounded slot
  # schemas and phase obligations. Malformed authority, content identity or
  # private guest identity MUST refuse rather than initialize replacement state.
  @spec valid_record?(term()) :: boolean()
  def valid_record?(value) when is_map(value) do
    keys?(value, @keys) and value["version"] == 1 and valid_binding?(value["binding"]) and
      is_map(value["slots"]) and map_size(value["slots"]) <= 2 and
      Enum.all?(value["slots"], fn {slot, leaf} -> slot in ["a", "b"] and valid_leaf?(leaf) end) and
      (is_nil(value["checkpoint_id"]) or OverallsProtocol.uuid?(value["checkpoint_id"])) and
      (is_nil(value["slot"]) or value["slot"] in ["a", "b"]) and
      (is_nil(value["descriptor"]) or match?({:ok, _}, Descriptor.decode(value["descriptor"]))) and
      (is_nil(value["manifest"]) or valid_manifest?(value["manifest"])) and
      Enum.all?(~w(capture_authority restore_authority), fn field ->
        is_nil(value[field]) or valid_authority?(value[field])
      end) and
      valid_relocation?(value["relocation"], value) and phase_valid?(value)
  end

  def valid_record?(_), do: false

  @spec valid_manifest?(term()) :: boolean()
  def valid_manifest?(value) when is_map(value) do
    keys?(
      value,
      ~w(version id compatibility guest_identity guest_boot_id workload source_authority memory_bytes slot)
    ) and
      value["version"] == 1 and OverallsProtocol.uuid?(value["id"]) and
      OverallsProtocol.ImageManifest.id?(value["compatibility"]) and
      valid_workload?(value["workload"]) and
      valid_authority?(value["source_authority"]) and value["slot"] in ["a", "b"] and
      value["memory_bytes"] == value["workload"]["memory_bytes"] and
      (is_nil(value["guest_boot_id"]) or OverallsProtocol.uuid?(value["guest_boot_id"])) and
      valid_guest?(value["guest_identity"])
  end

  def valid_manifest?(_), do: false

  # @cc [owner:ghuntley,label:isolation;security;recovery] restored-memory-retains-guest-network
  # A loaded guest retains its source IP, MAC and device state. Its immutable
  # workload MUST match the destination shape, including profile and slot;
  # only placement and pool identities may change during relocation. Host TAP
  # substitution MUST NOT authorize a different guest address or tenant slot.
  @spec workload_matches?(term(), Spec.t()) :: boolean()
  def workload_matches?(manifest, spec) do
    valid_manifest?(manifest) and
      Map.drop(manifest["workload"], ~w(id pool_id)) ==
        Map.drop(Spec.encode(spec), ~w(id pool_id))
  end

  defp valid_binding?(binding) when is_map(binding) do
    keys?(binding, ~w(host_id pool_id placement_id zpool_guid parent_dataset_guid workload)) and
      Enum.all?(~w(host_id pool_id placement_id), &OverallsProtocol.uuid?(binding[&1])) and
      Enum.all?(~w(zpool_guid parent_dataset_guid), &OverallsProtocol.Storage.guid?(binding[&1])) and
      valid_workload?(binding["workload"]) and
      binding["workload"]["id"] == binding["placement_id"] and
      binding["workload"]["pool_id"] == binding["pool_id"]
  end

  defp valid_binding?(_), do: false

  defp valid_workload?(value) when is_map(value) do
    keys?(value, ~w(id image_id pool_id profile slot vcpu memory_bytes disk_bytes)) and
      Enum.all?(~w(id pool_id), &OverallsProtocol.uuid?(value[&1])) and
      OverallsProtocol.ImageManifest.id?(value["image_id"]) and
      value["profile"] in ~w(customer standard oss inception) and is_integer(value["slot"]) and
      value["slot"] in 2..65534 and
      OverallsProtocol.VMShape.valid?(value["vcpu"], value["memory_bytes"], value["disk_bytes"])
  end

  defp valid_workload?(_), do: false

  defp valid_authority?(value) when is_map(value) do
    keys?(value, ~w(placement_id execution_epoch generation)) and
      OverallsProtocol.uuid?(value["placement_id"]) and
      Enum.all?(
        ~w(execution_epoch generation),
        &(is_integer(value[&1]) and value[&1] in 1..9_223_372_036_854_775_807)
      )
  end

  defp valid_authority?(_), do: false

  defp valid_guest?(value) when is_map(value) do
    case OverallsProtocol.Readiness.response(
           Map.merge(value, %{
             "version" => 1,
             "state" => "ready",
             "boot_id" => value["placement_id"]
           })
         ) do
      {:ok, _} -> keys?(value, ~w(placement_id execution_epoch boot_challenge))
      _ -> false
    end
  end

  defp valid_guest?(_), do: false

  defp valid_leaf?(leaf) when is_map(leaf) do
    keys?(leaf, ~w(state nonce dataset_guid snapshot_guid checkpoint_id)) and
      (is_binary(leaf["nonce"]) and Regex.match?(~r/\A[0-9a-f]{32}\z/, leaf["nonce"])) and
      (is_nil(leaf["dataset_guid"]) or OverallsProtocol.Storage.guid?(leaf["dataset_guid"])) and
      (is_nil(leaf["snapshot_guid"]) or OverallsProtocol.Storage.guid?(leaf["snapshot_guid"])) and
      (is_nil(leaf["checkpoint_id"]) or OverallsProtocol.uuid?(leaf["checkpoint_id"])) and
      case leaf["state"] do
        "creating" ->
          is_nil(leaf["snapshot_guid"]) or not is_nil(leaf["dataset_guid"])

        "empty" ->
          not is_nil(leaf["dataset_guid"]) and is_nil(leaf["snapshot_guid"])

        "sealed" ->
          not is_nil(leaf["dataset_guid"]) and not is_nil(leaf["snapshot_guid"]) and
            not is_nil(leaf["checkpoint_id"])

        "retiring" ->
          not is_nil(leaf["dataset_guid"])

        _ ->
          false
      end
  end

  defp valid_leaf?(_), do: false
  defp valid_relocation?(nil, _), do: true

  defp valid_relocation?(wire, value) do
    case OverallsProtocol.Relocation.descriptor(wire) do
      {:ok, %{checkpoint: descriptor} = transfer} ->
        transfer.destination.placement_id == value["binding"]["placement_id"] and
          transfer.destination.pool_id == value["binding"]["pool_id"] and
          transfer.destination.host_id == value["binding"]["host_id"] and
          (value["phase"] in ["capturing", "copied", "consumed"] or
             descriptor.id == value["checkpoint_id"])

      _ ->
        false
    end
  end

  defp phase_valid?(%{"phase" => "retired"}), do: true

  defp phase_valid?(%{"phase" => "empty"} = value) do
    Enum.all?(
      ~w(checkpoint_id slot descriptor manifest capture_authority restore_authority relocation),
      &is_nil(value[&1])
    )
  end

  defp phase_valid?(%{"phase" => "receiving"} = value) do
    not is_nil(value["relocation"]) and value["slot"] == "a" and is_nil(value["manifest"]) and
      is_nil(value["capture_authority"]) and is_nil(value["restore_authority"]) and
      descriptor_valid?(value)
  end

  defp phase_valid?(%{"phase" => phase} = value)
       when phase in ["capturing", "copied", "ready", "restoring", "consumed"] do
    valid_manifest?(value["manifest"]) and value["manifest"]["id"] == value["checkpoint_id"] and
      value["slot"] in ["a", "b"] and is_map(value["slots"][value["slot"]]) and
      Map.drop(value["manifest"]["workload"], ~w(id pool_id)) ==
        Map.drop(value["binding"]["workload"], ~w(id pool_id)) and
      (valid_authority?(value["capture_authority"]) or not is_nil(value["relocation"])) and
      (not is_nil(value["relocation"]) or
         (value["capture_authority"]["placement_id"] == value["binding"]["placement_id"] and
            value["capture_authority"] == value["manifest"]["source_authority"])) and
      if phase in ["capturing", "copied"] do
        is_nil(value["descriptor"]) and is_nil(value["restore_authority"]) and
          value["slots"][value["slot"]]["state"] == "empty" and
          (phase == "capturing" or
             value["slots"][value["slot"]]["checkpoint_id"] == value["checkpoint_id"])
      else
        descriptor_valid?(value) and value["slots"][value["slot"]]["state"] == "sealed" and
          if phase == "ready",
            do: is_nil(value["restore_authority"]),
            else:
              valid_authority?(value["restore_authority"]) and
                value["restore_authority"]["placement_id"] == value["binding"]["placement_id"]
      end
  end

  defp phase_valid?(_), do: false

  defp descriptor_valid?(value) do
    case Descriptor.decode(value["descriptor"]) do
      {:ok, descriptor} ->
        descriptor.id == value["checkpoint_id"] and
          descriptor.memory_bytes == value["binding"]["workload"]["memory_bytes"] and
          (value["phase"] == "receiving" or
             (value["slots"][value["slot"]]["checkpoint_id"] == descriptor.id and
                value["slots"][value["slot"]]["snapshot_guid"] == descriptor.snapshot_guid and
                value["manifest"]["compatibility"] == descriptor.compatibility and
                (not is_nil(value["relocation"]) or
                   value["slots"][value["slot"]]["dataset_guid"] == descriptor.dataset_guid)))

      _ ->
        false
    end
  end

  defp keys?(value, keys), do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp failure, do: {:error, :checkpoint_unconfirmed}
end
