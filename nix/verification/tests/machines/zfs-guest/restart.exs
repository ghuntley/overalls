defmodule ZFSGuestRestartFixture do
  @moduledoc false
  alias Lilly.Host.{Lock, Pool, Storage, ZFSDataset}
  alias Lilly.VM.{Config, Disk, Driver, Intent, Spec, Unit}

  # @cc [owner:ghuntley,label:verification;recovery] native-restart-contention-before-launch
  # Run the production restart path under one placement/epoch/generation. Pool
  # contention and invalid parent accounting MUST leave boot and launch-attempt files
  # unchanged and the VMM stopped. Removing the fault MUST still require all
  # metadata and bundle checks. The caller then proves a real successful boot.
  @spec run(Config.t(), Pool.t(), Spec.t(), pos_integer()) :: :ok
  def run(config, pool, spec, generation) do
    directory = Path.join(config.state_dir, spec.id)
    files = Enum.map(["launch-attempt.bin", "boot.json"], &Path.join(directory, &1))
    previous = Enum.map(files, &File.read/1)
    options = [execution_epoch: 1, generation: generation]
    {:ok, :stopped} = Unit.status(spec)
    {:ok, owner} = Lock.acquire(Path.join(pool.path, ".lilly-storage"))

    try do
      {:error, :storage_busy} =
        Task.async(fn -> Driver.restart(config, pool, spec, options) end)
        |> Task.await(10_000)
    after
      Lock.release(owner)
    end

    ^previous = Enum.map(files, &File.read/1)
    {:ok, authority} = Intent.read(directory)

    true =
      authority.placement_id == spec.id and authority.execution_epoch == 1 and
        authority.generation == generation and authority.state == :running

    original_path = System.fetch_env!("PATH")
    :ok = File.mkdir_p("/run/zfs-readiness-fault")
    accounting_fault = "/run/zfs-readiness-fault/parent-incoherent"

    try do
      System.put_env("PATH", "/run/zfs-readiness-fault/bin:" <> original_path)
      :ok = File.write(accounting_fault, "")

      for _ <- 1..3 do
        {:error, :disk_not_ready} = Driver.restart(config, pool, spec, options)
        {:ok, ^authority} = Intent.read(directory)
        {:ok, :stopped} = Unit.status(spec)
        ^previous = Enum.map(files, &File.read/1)
      end
    after
      File.rm!(accounting_fault)
      System.put_env("PATH", original_path)
    end

    # Corrupt only fixture-owned files after contention. No success may bypass
    # either validation layer or reconstruct the missing disk/bundle. Since
    # ec54d521d (ADR-0190 native admission) restart/4 validates the portable
    # bundle before Disk.ready, so a missing or malformed bundle refuses as
    # invalid_workload_bundle before any storage lock; a missing disk still
    # refuses inside Disk.ready as disk_not_ready.
    for {file, refusal} <- [
          {Disk.path(pool, spec), :disk_not_ready},
          {Path.join(ZFSDataset.directory(pool, spec), "boot-bundle.json"),
           :invalid_workload_bundle}
        ] do
      saved = file <> ".fixture-saved"
      :ok = File.rename(file, saved)

      try do
        {:error, ^refusal} = Driver.restart(config, pool, spec, options)
        false = File.exists?(file)
        {:ok, :stopped} = Unit.status(spec)
        ^previous = Enum.map(files, &File.read/1)
      after
        :ok = File.rename(saved, file)
      end
    end

    bundle = Path.join(ZFSDataset.directory(pool, spec), "boot-bundle.json")
    original_bundle = File.read!(bundle)

    try do
      :ok = File.write(bundle, "{}")
      {:error, :invalid_workload_bundle} = Driver.restart(config, pool, spec, options)
      {:ok, :stopped} = Unit.status(spec)
      ^previous = Enum.map(files, &File.read/1)
    after
      :ok = File.write(bundle, original_bundle)
    end

    # Successful validation returns no execution credit on its own. The Python
    # driver repeats restart with the identical authority and checks guest data.
    :ok = Storage.locked(pool, fn -> ZFSDataset.ready(pool, spec) end)
    {:ok, ^authority} = Intent.read(directory)
    {:ok, :stopped} = Unit.status(spec)
    ^previous = Enum.map(files, &File.read/1)
    :ok
  end
end
