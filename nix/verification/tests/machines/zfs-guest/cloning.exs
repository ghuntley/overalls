defmodule ZFSGuestCloneFixture do
  @moduledoc false
  alias Lilly.Control.{Client, Store}
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Clone.Effects

  # @cc [owner:ghuntley,label:verification] clone-native-independent-storage
  # This fixture MUST run production clone effects against owned ZFS storage and
  # a real stopped source. Restarting the source before copying MUST not change
  # the snapshot. Local native evidence does not establish cross-host transport.
  # Multi-disk sources MUST copy and adopt every profile-derived drive. Each
  # restarted source boot MUST install host trust before guest services proceed.
  @spec run(
          Lilly.VM.Config.t(),
          Lilly.Host.Pool.t(),
          Lilly.Host.Image.t(),
          Lilly.VM.Spec.t(),
          pos_integer()
        ) :: :ok
  def run(execution, pool, image, source, generation) do
    root = "/var/lib/lilly/clone-transfers"
    state = "/var/lib/lilly/clone-control"
    :ok = PrivateFiles.directory(root)
    {:ok, lock} = Lock.acquire(state)

    digits = fn number ->
      "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(number), 12, "0")
    end

    # Customer sources clone to 115/116; Inception's two-disk layout to 118/119.
    {target_number, unused_number} =
      if source.network.profile == :inception, do: {118, 119}, else: {115, 116}

    try do
      {:ok, store} = Store.open(state, pool.host_id)
      target = digits.(target_number)
      # A distinct relocation identity per leg; retired keys are never reused.
      clone = "cccccccc-cccc-4ccc-8ccc-" <> String.pad_leading(to_string(target_number), 12, "0")

      intent = %{
        "version" => 3,
        "purpose" => "clone",
        "relocation_id" => clone,
        "vm_id" => source.id,
        "destination_vm_id" => target,
        "source_slot" => source.network.slot,
        "source" => %{
          "host_id" => pool.host_id,
          "pool_id" => pool.id,
          "placement_id" => source.id
        },
        "destination" => %{
          "host_id" => pool.host_id,
          "pool_id" => pool.id,
          "placement_id" => target
        },
        "source_epoch" => 1,
        "destination_epoch" => 1,
        "workload" => %{
          "architecture" => "x86_64",
          "image_id" => image.id,
          "profile" => Atom.to_string(source.network.profile),
          "slot" => target_number + 2,
          "vcpu" => source.vcpu,
          "memory_bytes" => source.memory_bytes,
          "disk_bytes" => source.disk_bytes
        }
      }

      runtime = %Lilly.Control.Config{
        client: %Client{
          host_id: pool.host_id,
          base_url: "https://fixture.invalid",
          token: "unused"
        },
        state_dir: state,
        cgroup_path: "/sys/fs/cgroup/lilly.slice",
        pools: [pool],
        images: [image],
        execution: execution,
        transfer_state_dir: root,
        transfer_bytes_per_second: 67_108_864
      }

      current = %{
        id: clone,
        owner_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        vm_id: source.id,
        placement_id: source.id,
        execution_epoch: 1,
        host_id: pool.host_id,
        pool_id: pool.id,
        generation: generation,
        kind: :stop,
        architecture: :x86_64,
        image_id: image.id,
        profile: source.network.profile,
        slot: source.network.slot,
        vcpu: source.vcpu,
        memory_bytes: source.memory_bytes,
        disk_bytes: source.disk_bytes
      }

      {:ok, _} = Store.accept(store, current)

      command = %{
        "id" => clone,
        "clone_id" => clone,
        "host_id" => pool.host_id,
        "kind" => "prepare",
        "endpoint" => "destination",
        "intent" => intent,
        "descriptor" => nil,
        "public_key" => nil,
        "source_endpoint" => nil,
        "source_generation" => generation,
        "revision" => System.system_time(:second),
        "expires_at" => System.system_time(:second) + 180
      }

      prepare = effect(runtime, store, command)
      command = Map.put(command, "public_key", prepare["public_key"])
      captured = effect(runtime, store, %{command | "kind" => "capture", "endpoint" => "source"})
      command = Map.put(command, "descriptor", captured["descriptor"])
      # The independent source resumes while its immutable snapshot is retained.
      :ok = Lilly.VM.Driver.restart(execution, pool, source, generation: generation + 1)
      :ok = await_running(execution, pool, source, System.monotonic_time(:millisecond) + 30_000)
      :ok = Lilly.VM.Driver.trust(execution, pool, source, generation: generation + 1)

      {:ok, _} =
        Store.accept(store, %{
          current
          | id: Lilly.UUID.generate(),
            generation: generation + 1,
            kind: :start
        })

      ^captured =
        effect(runtime, store, %{
          command
          | "kind" => "capture",
            "endpoint" => "source",
            "revision" => command["revision"] + 1
        })

      copied = effect(runtime, store, %{command | "kind" => "copy"})
      true = is_binary(copied["dataset_guid"])
      ^copied = effect(runtime, store, %{command | "kind" => "copy"})
      :ok = copy_mode(pool, target, "copied")
      %{} = effect(runtime, store, %{command | "kind" => "adopt"})
      %{} = effect(runtime, store, %{command | "kind" => "adopt"})
      :ok = copy_mode(pool, target, "adopted")

      %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => "source"})
      %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => "destination"})
      %{} = effect(runtime, store, %{command | "kind" => "prune", "endpoint" => "source"})
      %{} = effect(runtime, store, %{command | "kind" => "prune", "endpoint" => "source"})

      for kind <- ["copy", "adopt"] do
        assert_rejected(runtime, store, %{command | "kind" => kind})
      end

      # Cancellation before a snapshot/receive still leaves permanent launch and
      # transfer fences for the unused destination at its independent epoch 1.
      cancelled = Lilly.UUID.generate()
      unused = digits.(unused_number)

      cancelled_intent =
        intent
        |> Map.put("relocation_id", cancelled)
        |> Map.put("destination_vm_id", unused)
        |> put_in(["destination", "placement_id"], unused)
        |> put_in(["workload", "slot"], unused_number + 2)

      cancelled_command = %{
        command
        | "id" => cancelled,
          "clone_id" => cancelled,
          "intent" => cancelled_intent,
          "descriptor" => nil,
          "kind" => "prepare"
      }

      effect(runtime, store, cancelled_command)
      effect(runtime, store, %{cancelled_command | "kind" => "revoke", "endpoint" => "source"})
      effect(runtime, store, %{cancelled_command | "kind" => "revoke"})
      effect(runtime, store, %{cancelled_command | "kind" => "discard"})
      effect(runtime, store, %{cancelled_command | "kind" => "discard"})
      effect(runtime, store, %{cancelled_command | "kind" => "prune", "endpoint" => "source"})
      assert_rejected(runtime, store, cancelled_command)
      # Complete this permit before the separate receive journey begins.
      if source.network.profile == :customer do
        retry = received_neighbor(runtime, store, pool, image, source, generation, command)
        :ok = Lilly.VM.Driver.restart(execution, pool, source, generation: retry)
        :ok = await_running(execution, pool, source, System.monotonic_time(:millisecond) + 30_000)
        :ok = Lilly.VM.Driver.trust(execution, pool, source, generation: retry)

        {:ok, _} =
          Store.accept(store, %{
            current
            | id: Lilly.UUID.generate(),
              generation: retry,
              kind: :start
          })
      end
    after
      Lock.release(lock)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;storage] same-pool-clone-journal-mode
  # A same-pool clone MUST use its ordinary claim and durable copy journal;
  # receive history MUST NOT be manufactured for that placement (ADR-0145/0159).
  @spec copy_mode(Lilly.Host.Pool.t(), String.t(), String.t()) :: :ok
  defp copy_mode(pool, placement, phase) do
    directory = Lilly.Transfer.CloneCopyJournal.directory(pool.path, placement)
    {:ok, bytes} = File.read(Path.join(directory, "copy.json"))
    {:ok, %{"phase" => ^phase}} = Lilly.Lifecycle.Journal.decode(bytes)
    {:error, :enoent} = File.lstat(Lilly.Transfer.ReceivedDataset.directory(pool, placement))
    :ok
  end

  # @cc [owner:ghuntley,label:verification;storage;recovery] receive-neighbor-real-cross-pool
  # Receive-readiness assertions MUST use genuinely distinct owned ZFS pools
  # with disjoint native backing extents, as validated by Pool.distinct?/1,
  # and stopped source, then production cross-pool clone effects. The received
  # neighbour MUST retain its real import journal until adoption and cancellation;
  # cleanup MUST use the same fenced effects and Driver deletion as production.
  # This native same-host leg does not establish cross-host transport.
  @spec received_neighbor(
          Lilly.Control.Config.t(),
          Store.t(),
          Lilly.Host.Pool.t(),
          Lilly.Host.Image.t(),
          Lilly.VM.Spec.t(),
          pos_integer(),
          map()
        ) ::
          pos_integer()
  defp received_neighbor(runtime, store, pool, image, neighbor, generation, command) do
    alias Lilly.Host.{Pool, ZFS}
    alias Lilly.VM.{Driver, Spec}
    source_pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-000000000120"
    source_id = "dddddddd-dddd-4ddd-8ddd-000000000120"
    destination_id = "dddddddd-dddd-4ddd-8ddd-000000000121"
    clone = "cccccccc-cccc-4ccc-8ccc-000000000121"
    source_path = "/clone-receive-source"
    # The root test driver creates the receive-source/lilly pool here and
    # destroys it afterwards; the probe, running as `lilly` (ADR-0182), cannot.

    {:ok, identity} = ZFS.inspect_path(source_path)

    {:ok, source_pool} =
      Pool.new(source_pool_id, source_path, identity.filesystem_id,
        host_id: pool.host_id,
        storage: OverallsProtocol.Storage.encode(identity.storage)
      )

    true = source_pool.storage.dataset != pool.storage.dataset
    true = source_pool.storage.dataset_guid != pool.storage.dataset_guid
    true = Pool.distinct?([pool, source_pool])

    {:ok, source} =
      Spec.new(%{
        id: source_id,
        image_id: image.id,
        pool_id: source_pool.id,
        profile: :customer,
        slot: 122,
        vcpu: neighbor.vcpu,
        memory_bytes: neighbor.memory_bytes,
        disk_bytes: neighbor.disk_bytes
      })

    :ok = Driver.start(runtime.execution, source_pool, image, source, generation: 1)

    :ok =
      await_running(
        runtime.execution,
        source_pool,
        source,
        System.monotonic_time(:millisecond) + 30_000
      )

    :ok = Driver.stop(runtime.execution, source_pool, source, generation: 2)

    current = %{
      id: clone,
      owner_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      vm_id: source.id,
      placement_id: source.id,
      execution_epoch: 1,
      host_id: pool.host_id,
      pool_id: source_pool.id,
      generation: 2,
      kind: :stop,
      architecture: :x86_64,
      image_id: image.id,
      profile: :customer,
      slot: source.network.slot,
      vcpu: source.vcpu,
      memory_bytes: source.memory_bytes,
      disk_bytes: source.disk_bytes
    }

    {:ok, _} = Store.accept(store, current)
    runtime = %{runtime | pools: [pool, source_pool]}

    intent =
      command["intent"]
      |> Map.put("relocation_id", clone)
      |> Map.put("vm_id", source.id)
      |> Map.put("destination_vm_id", destination_id)
      |> Map.put("source_slot", source.network.slot)
      |> put_in(["source", "placement_id"], source.id)
      |> put_in(["source", "pool_id"], source_pool.id)
      |> put_in(["destination", "placement_id"], destination_id)
      |> put_in(["workload", "slot"], 123)

    command = %{
      command
      | "id" => clone,
        "clone_id" => clone,
        "intent" => intent,
        "kind" => "prepare",
        "endpoint" => "destination",
        "source_generation" => 2,
        "descriptor" => nil,
        "public_key" => nil,
        "revision" => System.system_time(:second),
        "expires_at" => System.system_time(:second) + 180
    }

    prepare = effect(runtime, store, command)
    command = Map.put(command, "public_key", prepare["public_key"])
    captured = effect(runtime, store, %{command | "kind" => "capture", "endpoint" => "source"})
    command = Map.put(command, "descriptor", captured["descriptor"])
    {:ok, descriptor} = OverallsProtocol.DiskTransfer.descriptor(captured["descriptor"])
    false = Lilly.Transfer.CloneCopy.same_pool?(descriptor)
    :ok = pending_import(pool, neighbor, captured["descriptor"])
    copied = effect(runtime, store, %{command | "kind" => "copy"})
    true = is_binary(copied["dataset_guid"])
    ^copied = effect(runtime, store, %{command | "kind" => "copy"})
    false = Lilly.Transfer.CloneCopy.history?(pool, descriptor)
    retry = stage_restart(runtime.execution, pool, neighbor, generation, destination_id)
    %{} = effect(runtime, store, %{command | "kind" => "adopt"})
    %{} = effect(runtime, store, %{command | "kind" => "adopt"})

    for endpoint <- ["source", "destination"] do
      %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => endpoint})
    end

    %{} = effect(runtime, store, %{command | "kind" => "discard"})
    %{} = effect(runtime, store, %{command | "kind" => "discard"})
    %{} = effect(runtime, store, %{command | "kind" => "prune", "endpoint" => "source"})

    {_, absent} =
      System.cmd("zfs", ["list", "-H", pool.storage.dataset <> "/vm-" <> destination_id],
        stderr_to_stdout: true
      )

    true = absent != 0
    {:error, :enoent} = File.lstat(Path.join([pool.path, "vms", destination_id]))

    :ok =
      delete_source(
        runtime.execution,
        source_pool,
        source,
        System.monotonic_time(:millisecond) + 60_000
      )

    {guid, 0} = System.cmd("zpool", ["get", "-Hpo", "value", "guid", "receive-source"])
    true = String.trim(guid) == source_pool.storage.zpool_guid
    retry
  end

  # @cc [owner:ghuntley,label:verification;recovery] receive-source-cleanup-same-authority
  # A delayed native cleanup MUST retry the exact deleted source authority only
  # within its fixed deadline; every other refusal MUST fail the fixture.
  @spec delete_source(Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Lilly.VM.Spec.t(), integer()) ::
          :ok
  defp delete_source(execution, pool, source, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "cross-pool clone source cleanup timed out"
    end

    case Lilly.VM.Driver.delete(execution, pool, source, generation: 3) do
      :ok ->
        :ok

      {:error, reason}
      when reason in [:execution_unavailable, :storage_busy, :zfs_dataset_cleanup_unconfirmed] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "cross-pool clone source cleanup timed out"
        end

        Process.sleep(100)
        delete_source(execution, pool, source, deadline)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] prepared-receive-defers-before-native-birth
  # The exact admitted fixture import MUST defer readiness before receive creates
  # its dataset. A missing already-bound import MUST NOT earn that classification.
  @spec pending_import(Lilly.Host.Pool.t(), Lilly.VM.Spec.t(), map()) :: :ok
  defp pending_import(pool, source, wire) do
    alias Lilly.Host.{Storage, ZFS}
    alias Lilly.Transfer.ReceivedDataset
    {:ok, descriptor} = OverallsProtocol.DiskTransfer.descriptor(wire)
    placement = descriptor.destination.placement_id

    :ok =
      Storage.locked(pool, fn ->
        {:ok, journal} = ReceivedDataset.prepare(pool, descriptor)
        nil = journal["dataset_guid"]
        {:ok, owners} = ZFS.owners(Lilly.Host.Pool.zfs_identity(pool))
        false = Map.has_key?(owners, pool.storage.dataset <> "/vm-" <> placement)
        true = ReceivedDataset.staging_busy?(pool)
        path = Path.join(ReceivedDataset.directory(pool, placement), "import.json")
        original = File.read!(path)

        try do
          :ok = File.write(path, JSON.encode!(Map.put(journal, "dataset_guid", "1")))
          false = ReceivedDataset.staging_busy?(pool)
        after
          :ok = File.write(path, original)
        end

        :ok
      end)

    {:error, :storage_busy} = Lilly.VM.Disk.ready(pool, source)
    {:error, :enoent} = File.lstat(Path.join([pool.path, "vms", placement]))
    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] received-neighbor-defers-restart
  # Real independently owned, finished staging on the same pool MUST NOT block a
  # neighbour's restart: it is validated as staged under receive policy. While
  # parent counters are incoherent the restart MUST defer (storage_busy) without
  # changing boot or launch-attempt evidence, only with matching stable native
  # identity and private import ownership; strict inspection still rejects them.
  # A malformed journal or boot bundle MUST fail closed. With coherent counters
  # the same authority MUST restart through full readiness before adoption.
  @spec stage_restart(
          Lilly.VM.Config.t(),
          Lilly.Host.Pool.t(),
          Lilly.VM.Spec.t(),
          pos_integer(),
          String.t()
        ) :: pos_integer()
  defp stage_restart(execution, pool, source, generation, target) do
    alias Lilly.Host.Storage
    alias Lilly.Transfer.ReceivedDataset
    alias Lilly.VM.{Driver, Intent, Unit}
    :ok = Driver.stop(execution, pool, source, generation: generation + 2)
    revision = generation + 3
    directory = Path.join(execution.state_dir, source.id)
    files = Enum.map(["launch-attempt.bin", "boot.json"], &Path.join(directory, &1))
    previous = Enum.map(files, &File.read/1)
    journal = Path.join(ReceivedDataset.directory(pool, target), "import.json")
    original = File.read!(journal)
    decoded = JSON.decode!(original)
    original_path = System.fetch_env!("PATH")
    fault = "/run/zfs-readiness-fault/parent-incoherent"
    :ok = File.mkdir_p("/run/zfs-readiness-fault/bin")
    :ok = File.cp("/etc/zfs-readiness-fault", "/run/zfs-readiness-fault/bin/zfs")
    :ok = File.chmod("/run/zfs-readiness-fault/bin/zfs", 0o755)

    try do
      System.put_env("PATH", "/run/zfs-readiness-fault/bin:" <> original_path)
      :ok = File.write(fault, "")
      identity = Lilly.Host.Pool.zfs_identity(pool)
      {:error, :unsupported_zfs_pool} = Lilly.Host.ZFS.inspect_path(pool.path)
      true = Lilly.Host.ZFS.staging_identity?(identity)

      for key <- [:dataset_guid, :zpool_guid] do
        false = Lilly.Host.ZFS.staging_identity?(put_in(identity, [:storage, key], "1"))
      end

      for _ <- 1..3 do
        {:error, :storage_busy} = Driver.restart(execution, pool, source, generation: revision)
        ^previous = Enum.map(files, &File.read/1)
        {:ok, %{generation: ^revision}} = Intent.read(directory)
        {:ok, :stopped} = Unit.status(source)
      end

      :ok = Storage.locked(pool, fn -> File.write(journal, "{}") end)
      {:error, :disk_not_ready} = Driver.restart(execution, pool, source, generation: revision)
      ^previous = Enum.map(files, &File.read/1)
      {:ok, %{generation: ^revision}} = Intent.read(directory)
      {:ok, :stopped} = Unit.status(source)
    after
      :ok = Storage.locked(pool, fn -> File.write(journal, original) end)
      File.rm!(fault)
      System.put_env("PATH", original_path)
    end

    {:ok, authority} = Intent.read(directory)
    ^revision = authority.generation

    try do
      for invalid <- [
            %{},
            Map.put(decoded, "dataset_guid", "1"),
            Map.put(decoded, "nonce", String.duplicate("0", 32))
          ] do
        :ok = Storage.locked(pool, fn -> File.write(journal, JSON.encode!(invalid)) end)
        {:error, :disk_not_ready} = Driver.restart(execution, pool, source, generation: revision)
        ^previous = Enum.map(files, &File.read/1)
        {:ok, ^authority} = Intent.read(directory)
      end
    after
      :ok = Storage.locked(pool, fn -> File.write(journal, original) end)
    end

    bundle = Path.join(Lilly.Host.ZFSDataset.directory(pool, source), "boot-bundle.json")
    original_bundle = File.read!(bundle)

    try do
      # Since ec54d521d (ADR-0190) restart/4 admits the portable bundle before
      # Disk.ready, so a malformed bundle refuses as invalid_workload_bundle.
      :ok = Storage.locked(pool, fn -> File.write(bundle, "{}") end)

      {:error, :invalid_workload_bundle} =
        Driver.restart(execution, pool, source, generation: revision)

      ^previous = Enum.map(files, &File.read/1)
      {:ok, ^authority} = Intent.read(directory)
      {:ok, :stopped} = Unit.status(source)
    after
      :ok = Storage.locked(pool, fn -> File.write(bundle, original_bundle) end)
    end

    :ok = Driver.restart(execution, pool, source, generation: revision)
    revision
  end

  defp assert_rejected(runtime, store, command) do
    {:error, _} =
      Task.async(fn -> Effects.execute(runtime, store, command) end) |> Task.await(180_000)
  end

  defp effect(runtime, store, command) do
    Task.async(fn ->
      case Effects.execute(runtime, store, command) do
        {:ok, %{"result" => result}} -> result
        {:error, reason} -> raise "Clone fixture #{command["kind"]} unconfirmed: #{reason}"
      end
    end)
    |> Task.await(180_000)
  end

  @spec await_running(Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Lilly.VM.Spec.t(), integer()) ::
          :ok | {:error, :vmm_unconfirmed}
  defp await_running(execution, pool, source, deadline) do
    if Lilly.VM.Observation.running?(execution, pool, source) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :vmm_unconfirmed}
      else
        Process.sleep(100)
        await_running(execution, pool, source, deadline)
      end
    end
  end
end
