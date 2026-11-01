defmodule ZFSGuestCompletedExecutor do
  @moduledoc false
  @behaviour Lilly.VM.Executor
  @type context :: {Lilly.Control.Config.t(), pid()}

  # @cc [owner:ghuntley,label:verification;recovery] native-effect-before-actor-crash
  # The wrapper MUST invoke the production executor unchanged, then pause only
  # after a real running observation. It MUST NOT fabricate physical evidence
  # or return a running result until the fixture has suspended the recording actor.
  @impl true
  @spec reconcile(context(), OverallsProtocol.Execution.command(), %{
          running_epoch: non_neg_integer(),
          running_generation: non_neg_integer()
        }) :: Lilly.VM.Executor.result()
  def reconcile({config, owner}, command, history) do
    result = Lilly.VM.Executor.reconcile(config, command, history)

    case result do
      {:ok, %{state: :running}} ->
        send(owner, {:native_effect_completed, self()})

        receive do
          :release_native_result -> result
        after
          30_000 -> raise "native result barrier timed out"
        end

      {:retry, reason} ->
        send(owner, {:native_effect_retry, reason})
        result

      other ->
        send(owner, :native_effect_failed)
        other
    end
  end
end

defmodule ZFSGuestActorRecovery do
  @moduledoc false
  alias Lilly.Control.{Client, Store}
  alias Lilly.Host.{Image, Lock, Pool, PrivateFiles}
  alias Lilly.VM.{Actor, Config, Spec, Unit}
  alias OverallsProtocol.Execution

  @type executor ::
          {ZFSGuestCompletedExecutor, ZFSGuestCompletedExecutor.context()}
          | {Lilly.VM.Executor, Lilly.Control.Config.t()}

  # @cc [owner:ghuntley,label:verification;recovery] native-completed-effect-adoption
  # Killing the real actor with the real executor's completed running result in
  # its mailbox MUST leave its attempt-only journal unchanged. Replacement and
  # repeated replay MUST preserve the exact native VMM process snapshot and
  # launch marker, and replay one stable durable outcome ID/sequence.
  @type mode :: :actor | :beam_crash | :beam_recover
  @spec run(Config.t(), Pool.t(), Image.t(), Spec.t(), pos_integer(), mode()) :: :ok
  def run(config, pool, image, spec, generation, mode \\ :actor) do
    true = generation in 1..9_223_372_036_854_775_805
    replays = String.to_integer(System.fetch_env!("ZFS_TARGET"))
    true = replays in 1..3
    state = Path.join("/var/lib/lilly/actor-recovery", spec.id)
    :ok = PrivateFiles.directory(Path.dirname(state))
    :ok = PrivateFiles.directory(state)
    {:ok, lock} = Lock.acquire(state)
    {:ok, view} = OverallsProtocol.View.start_link(name: Lilly.Execution.view())

    try do
      run_owned(config, pool, image, spec, generation, replays, state, mode)
    after
      :ok = GenServer.stop(view)
      :ok = Lock.release(lock)
    end
  end

  @spec run_owned(
          Config.t(),
          Pool.t(),
          Image.t(),
          Spec.t(),
          pos_integer(),
          1..3,
          Path.t(),
          mode()
        ) :: :ok
  defp run_owned(config, pool, image, spec, generation, replays, state, mode) do
    {:ok, store} = Store.open(state, pool.host_id, 3)

    command =
      if mode == :beam_recover do
        {:ok, [stored]} = Store.all(store)
        true = stored.placement_id == spec.id and stored.generation == generation
        true = stored.host_id == pool.host_id and stored.execution_epoch == 1
        stored
      else
        command = command(pool, spec, generation)
        {:ok, :stored} = Store.accept(store, command)
        command
      end

    runtime = %Lilly.Control.Config{
      client: %Client{host_id: pool.host_id, base_url: "https://fixture.invalid", token: "unused"},
      state_dir: state,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      pools: [pool],
      images: [image],
      execution: config
    }

    path = Path.join([state, "actors", spec.id, "journal.json"])

    if mode == :beam_recover do
      recover_beam(store, command, runtime, spec, config, state, path, replays)
    else
      complete_then_crash(
        store,
        command,
        runtime,
        spec,
        config,
        state,
        path,
        generation,
        replays,
        mode
      )
    end
  end

  @spec complete_then_crash(
          Store.t(),
          Execution.command(),
          Lilly.Control.Config.t(),
          Spec.t(),
          Config.t(),
          Path.t(),
          Path.t(),
          pos_integer(),
          1..3,
          :actor | :beam_crash
        ) :: :ok
  defp complete_then_crash(
         store,
         command,
         runtime,
         spec,
         config,
         state,
         path,
         generation,
         replays,
         mode
       ) do
    actor = start_actor(store, command, {ZFSGuestCompletedExecutor, {runtime, self()}})

    try do
      prove_retry_before_effect(actor, config, spec, path, generation)
      :ok = Actor.reconcile(actor)

      task =
        receive do
          {:native_effect_completed, task} -> task
          :native_effect_failed -> raise "production executor returned non-running before barrier"
        after
          120_000 -> raise "production executor did not complete a running effect"
        end

      %{task: %Task{ref: result_ref}} = :sys.get_state(actor)
      :ok = :sys.suspend(actor)
      before = File.read!(path)
      %{journal: journal} = :sys.get_state(actor)
      true = journal.attempted_generation == generation and journal.attempted_epoch == 1
      nil = journal.outcome
      {:ok, :running} = Unit.status(spec)
      process = process_snapshot(spec)
      marker_path = Path.join([config.state_dir, spec.id, "launch-attempt.bin"])
      marker = File.read!(marker_path)
      placement = spec.id
      <<^placement::binary-size(36), 1::64, ^generation::64>> = marker
      task_ref = Process.monitor(task)
      send(task, :release_native_result)

      receive do
        {:DOWN, ^task_ref, :process, ^task, :normal} -> :ok
      after
        10_000 -> raise "completed executor task did not return"
      end

      {:messages, messages} = Process.info(actor, :messages)

      true =
        Enum.any?(messages, fn
          {^result_ref, {{:ok, %{state: :running}}, {:running, :none}}} -> true
          _ -> false
        end)

      ^before = File.read!(path)

      if mode == :beam_crash do
        # The next BEAM must reopen Store and the native journal locks itself.
        :ok =
          PrivateFiles.write(
            state,
            "beam-witness.json",
            JSON.encode!(%{
              "journal_digest" => digest(before),
              "process" => process,
              "marker" => Base.encode64(marker)
            })
          )

        :erlang.halt(137)
      end

      kill(actor)
      ^before = File.read!(path)
      recovered = recover(store, command, runtime)
      true = recovered.state == :running and recovered.reason == :none
      true = recovered.generation == generation and recovered.execution_epoch == 1
      true = recovered.vm_id == command.vm_id and recovered.placement_id == command.placement_id
      true = recovered.operation_id == command.id
      true = recovered.compute_empty == false and recovered.disk_present == true
      true = recovered.cleanup_complete == false
      true = recovered.sequence == 1
      ^process = process_snapshot(spec)
      ^marker = File.read!(marker_path)
      # No acknowledgement is sent: each replacement must replay the exact
      # pending identity before observation, then retain it after reconciliation.
      for _ <- 1..replays do
        ^recovered = recover(store, command, runtime, recovered)
        ^process = process_snapshot(spec)
        ^marker = File.read!(marker_path)
      end
    after
      if Process.alive?(actor), do: kill(actor)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] native-beam-completion-recovery
  # A fresh source-built BEAM MUST reopen the persisted Store and actor locks
  # after abrupt worker exit, preserve the attempt-only journal on first recovery,
  # adopt the identical native VMM and marker, and replay one stable outcome.
  # Fixture witnesses MUST contain no guest bytes or credentials.
  @spec recover_beam(
          Store.t(),
          Execution.command(),
          Lilly.Control.Config.t(),
          Spec.t(),
          Config.t(),
          Path.t(),
          Path.t(),
          1..3
        ) :: :ok
  defp recover_beam(store, command, runtime, spec, config, state, path, replays) do
    %{"journal_digest" => journal_digest, "process" => process, "marker" => encoded_marker} =
      JSON.decode!(File.read!(Path.join(state, "beam-witness.json")))

    true = is_binary(journal_digest) and is_binary(process) and is_binary(encoded_marker)
    {:ok, marker} = Base.decode64(encoded_marker)
    marker_path = Path.join([config.state_dir, spec.id, "launch-attempt.bin"])
    outcome_path = Path.join(state, "beam-outcome-digest")

    expected =
      case File.read(outcome_path) do
        {:error, :enoent} ->
          ^journal_digest = digest(File.read!(path))
          nil

        {:ok, outcome_digest} ->
          true = byte_size(outcome_digest) == 64
          :retained
      end

    ^process = process_snapshot(spec)
    ^marker = File.read!(marker_path)
    recovered = recover(store, command, runtime, expected)
    true = recovered.state == :running and recovered.reason == :none
    true = recovered.generation == command.generation and recovered.execution_epoch == 1
    true = recovered.vm_id == command.vm_id and recovered.placement_id == command.placement_id
    true = recovered.operation_id == command.id and recovered.sequence == 1
    true = recovered.compute_empty == false and recovered.disk_present == true
    true = recovered.cleanup_complete == false
    outcome_digest = digest(:erlang.term_to_binary(recovered, [:deterministic]))

    case File.read(outcome_path) do
      {:error, :enoent} -> :ok = PrivateFiles.write(state, "beam-outcome-digest", outcome_digest)
      {:ok, ^outcome_digest} -> :ok
    end

    for _ <- 1..replays do
      ^recovered = recover(store, command, runtime, recovered)
      ^process = process_snapshot(spec)
      ^marker = File.read!(marker_path)
    end

    :ok
  end

  @spec digest(binary()) :: String.t()
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # @cc [owner:ghuntley,label:verification;recovery] native-attempt-before-contended-effect
  # A real placement lock MUST force the production executor to return retry
  # while the durable actor attempt is present, its outcome is absent, the unit
  # is stopped and no launch marker exists. The lock helper MUST confirm release
  # before the fixture waits for the completed physical effect.
  @spec prove_retry_before_effect(pid(), Config.t(), Spec.t(), Path.t(), pos_integer()) :: :ok
  defp prove_retry_before_effect(actor, config, spec, journal_path, generation) do
    owner = self()
    :ok = PrivateFiles.directory(config.state_dir)
    :ok = PrivateFiles.directory(Path.join(config.state_dir, spec.id))
    holder = Task.async(fn -> hold_execution_lock(config, spec, owner) end)

    try do
      receive do
        {:native_lock_held, pid} when pid == holder.pid -> :ok
      after
        10_000 -> raise "native placement lock was not acquired"
      end

      Actor.reconcile(actor)

      receive do
        {:native_effect_retry, :execution_unavailable} -> :ok
      after
        15_000 -> raise "production executor did not retry the held placement lock"
      end

      %{journal: journal} = :sys.get_state(actor)
      true = journal.attempted_epoch == 1 and journal.attempted_generation == generation
      nil = journal.outcome

      %{"attempted_epoch" => 1, "attempted_generation" => ^generation, "outcome" => nil} =
        JSON.decode!(File.read!(journal_path))

      {:ok, :stopped} = Unit.status(spec)
      {:error, :enoent} = File.read(Path.join([config.state_dir, spec.id, "launch-attempt.bin"]))
      send(holder.pid, :release_native_lock)
      :ok = Task.await(holder, 10_000)
    after
      if Process.alive?(holder.pid), do: Task.shutdown(holder, :brutal_kill)
    end

    :ok
  end

  @spec hold_execution_lock(Config.t(), Spec.t(), pid()) :: :ok
  defp hold_execution_lock(config, spec, owner) do
    {:ok, lock} = Lock.acquire(Path.join([config.state_dir, spec.id, "lock"]))

    try do
      send(owner, {:native_lock_held, self()})

      receive do
        :release_native_lock -> :ok
      after
        30_000 -> raise "native placement lock barrier timed out"
      end
    after
      :ok = Lock.release(lock)
    end
  end

  @spec command(Pool.t(), Spec.t(), pos_integer()) :: Execution.command()
  defp command(pool, spec, generation) do
    %{
      id: Lilly.UUID.generate(),
      owner_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      vm_id: spec.id,
      placement_id: spec.id,
      host_id: pool.host_id,
      pool_id: pool.id,
      execution_epoch: 1,
      generation: generation,
      kind: :provision,
      architecture: :x86_64,
      image_id: spec.image_id,
      profile: spec.network.profile,
      slot: spec.network.slot,
      vcpu: spec.vcpu,
      memory_bytes: spec.memory_bytes,
      disk_bytes: spec.disk_bytes
    }
  end

  @spec start_actor(Store.t(), Execution.command(), executor()) :: pid()
  defp start_actor(store, command, executor) do
    {:ok, actor} =
      Actor.start_link(
        store: store,
        vm_id: command.vm_id,
        placement_id: command.placement_id,
        owner: self(),
        executor: executor
      )

    Process.unlink(actor)
    actor
  end

  @spec recover(
          Store.t(),
          Execution.command(),
          Lilly.Control.Config.t(),
          Execution.outcome() | nil | :retained
        ) :: Execution.outcome()
  defp recover(store, command, runtime, expected \\ nil) do
    actor = start_actor(store, command, {Lilly.VM.Executor, runtime})
    placement = command.placement_id

    try do
      receive do
        {:vm_actor_ready, ^placement, ^actor, pending} ->
          if expected == :retained do
            true = is_map(pending) and pending.sequence == 1 and pending.state == :running
          else
            true = pending == expected
          end
      after
        10_000 -> raise "replacement actor did not open its durable journal"
      end

      Actor.reconcile(actor)

      receive do
        {:vm_actor_outcome, ^placement, ^actor, outcome} -> outcome
      after
        120_000 -> raise "replacement actor did not publish running adoption"
      end
    after
      kill(actor)
    end
  end

  @spec kill(pid()) :: :ok
  defp kill(actor) do
    ref = Process.monitor(actor)
    Process.exit(actor, :kill)

    receive do
      {:DOWN, ^ref, :process, ^actor, :killed} ->
        :ok

      {:DOWN, ^ref, :process, ^actor, :noproc} ->
        raise "actor exited before fixture kill"

      {:DOWN, ^ref, :process, ^actor, :normal} ->
        raise "actor exited normally before fixture kill"

      {:DOWN, ^ref, :process, ^actor, _reason} ->
        raise "actor exited unexpectedly before fixture kill"
    after
      10_000 -> raise "actor did not die"
    end
  end

  @spec process_snapshot(Spec.t()) :: binary()
  defp process_snapshot(spec) do
    # This BEAM runs as `lilly` without capabilities and cannot read the jailed
    # VMM's executable link; it compares PIDs and start times, and the root
    # driver checks executable identity (vm-processes.py snapshot/survival).
    {snapshot, 0} = System.cmd("zfs-guest-processes", ["--survival", spec.id])
    true = byte_size(snapshot) > 2
    snapshot
  end
end
