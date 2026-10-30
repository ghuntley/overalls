defmodule Lilly.VM.AntithesisActorPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.Test.DurableFakeExecutor, as: FakeExecutor
  alias Lilly.Control.Store
  alias Lilly.VM.{Actor, Journal}

  @host_id "11111111-1111-4111-8111-111111111111"
  @placement_id "22222222-2222-4222-8222-222222222222"
  @vm_id "33333333-3333-4333-8333-333333333333"
  @pool_id "44444444-4444-4444-8444-444444444444"
  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification;recovery] generated-actor-launch-replay
  # Generated replay and advance histories MUST use the real Store, Actor and
  # journal. Across actor lifetimes, each generation may cause at most one
  # durable fake launch, including when a previous result remains unacknowledged.
  @tag :hegel
  test "replay and generation advance never duplicate a fake launch", %{tmp_dir: root} do
    Hegel.check(
      fn ->
        actions = draw("actions", list_of(member_of([:replay, :advance]), max_length: 7))
        directory = fresh_directory(root)
        {:ok, store} = Store.open(directory, @host_id, 3)
        first = command(1)
        assert {:ok, :stored} = Store.accept(store, first)
        assert_running(reconcile_once(store, directory, first), first)

        final =
          Enum.reduce(actions, first, fn action, current ->
            next =
              case action do
                :replay ->
                  current

                :advance ->
                  %{current | id: Lilly.UUID.generate(), generation: current.generation + 1}
              end

            expected = if action == :replay, do: :duplicate, else: :stored
            assert {:ok, ^expected} = Store.accept(store, next)
            assert_running(reconcile_once(store, directory, next), next)
            assert_unique_attempts(directory, next)
            next
          end)

        assert_unique_attempts(directory, final)
        assert {:ok, ^final} = Store.read(store, @placement_id)
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] interrupted-launch-fails-closed
  # A durable fake launch marker without a running observation MUST fence a
  # same-generation actor replay; the recovered actor MUST NOT launch it again.
  @tag :hegel
  test "a marker left before fake launch completion fences actor replay", %{tmp_dir: root} do
    Hegel.check(
      fn ->
        generation = draw("generation", integer(1..100))
        directory = fresh_directory(root)
        {:ok, store} = Store.open(directory, @host_id, 3)
        intent = command(generation)
        assert {:ok, :stored} = Store.accept(store, intent)

        marker = %{
          "epoch" => intent.execution_epoch,
          "generation" => generation,
          "status" => "attempted",
          "attempts" => %{attempt_key(intent) => 1}
        }

        :ok = Lilly.Host.PrivateFiles.write(directory, "fake-executor.json", JSON.encode!(marker))
        outcome = reconcile_once(store, directory, intent)
        assert outcome.state == :failed
        assert outcome.reason == :execution_failed
        assert FakeExecutor.read(Path.join(directory, "fake-executor.json")) == marker

        replayed = reconcile_once(store, directory, intent)
        assert replayed.id == outcome.id
        assert replayed.sequence == outcome.sequence
        assert replayed.state == :failed
        assert FakeExecutor.read(Path.join(directory, "fake-executor.json")) == marker
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] killed-actor-attempt-fence
  # Killing a real actor after its executor persists an attempted marker MUST
  # leave an attempt-only journal; a replacement actor MUST fail that generation
  # without increasing the durable fake launch count.
  @tag :hegel
  test "actor death after a durable launch attempt fences the same generation", %{
    tmp_dir: root
  } do
    Hegel.check(
      fn ->
        generation = draw("generation", integer(1..100))
        directory = fresh_directory(root)
        {:ok, store} = Store.open(directory, @host_id, 3)
        intent = command(generation)
        assert {:ok, :stored} = Store.accept(store, intent)

        {:ok, actor} =
          Actor.start_link(
            store: store,
            vm_id: @vm_id,
            placement_id: @placement_id,
            owner: self(),
            executor: {FakeExecutor, {directory, self()}}
          )

        Process.unlink(actor)

        try do
          assert_receive {:vm_actor_ready, @placement_id, ^actor, _}, 2_000
          Actor.reconcile(actor)
          assert_receive {:fake_launch_attempted, task}, 5_000

          attempted = FakeExecutor.read(Path.join(directory, "fake-executor.json"))
          assert attempted["status"] == "attempted"
          assert attempted["attempts"] == %{attempt_key(intent) => 1}

          actor_ref = Process.monitor(actor)
          task_ref = Process.monitor(task)
          Process.exit(actor, :kill)
          assert_receive {:DOWN, ^actor_ref, :process, ^actor, :killed}, 2_000
          assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000

          journal_dir = Path.join([directory, "actors", @placement_id])
          assert {:ok, journal} = Journal.open(journal_dir, @host_id, @vm_id, @placement_id)
          assert journal.attempted_generation == generation
          assert journal.outcome == nil

          outcome = reconcile_once(store, directory, intent)
          assert outcome.state == :failed
          assert outcome.reason == :execution_failed
          assert FakeExecutor.read(Path.join(directory, "fake-executor.json")) == attempted

          replayed = reconcile_once(store, directory, intent)
          assert replayed.id == outcome.id
          assert replayed.sequence == outcome.sequence
          assert FakeExecutor.read(Path.join(directory, "fake-executor.json")) == attempted
        after
          if Process.alive?(actor), do: Process.exit(actor, :kill)
        end
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] completed-launch-before-record-crash
  # Actor death after executor completion but before recording MUST preserve
  # durable attempt authority. Restart MUST adopt the completed fake unit without
  # another launch and replay the exact recovered outcome identity and sequence.
  @tag :hegel
  # The full 100-case budget measured 16-26 s under the parallel suite on
  # 8 local CPUs; the slower CI runner exceeded the 60 s default.
  @tag timeout: 180_000
  test "completed launch survives actor death before outcome recording", %{tmp_dir: root} do
    Hegel.check(
      fn ->
        generation = draw("generation", integer(1..100))
        directory = fresh_directory(root)
        {:ok, store} = Store.open(directory, @host_id, 3)
        intent = command(generation)
        assert {:ok, :stored} = Store.accept(store, intent)

        {:ok, actor} =
          Actor.start_link(
            store: store,
            vm_id: @vm_id,
            placement_id: @placement_id,
            owner: self(),
            executor: {FakeExecutor, {directory, self()}}
          )

        Process.unlink(actor)

        try do
          assert_receive {:vm_actor_ready, @placement_id, ^actor, _}, 2_000
          Actor.reconcile(actor)
          assert_receive {:fake_launch_attempted, task}, 5_000
          %{task: %Task{ref: result_ref}} = :sys.get_state(actor)
          :ok = :sys.suspend(actor)
          journal_path = Path.join([directory, "actors", @placement_id, "journal.json"])
          before = File.read!(journal_path)
          raw = JSON.decode!(before)
          assert raw["attempted_generation"] == generation
          assert raw["outcome"] == nil
          task_ref = Process.monitor(task)
          send(task, :resume_fake_launch)
          assert_receive {:DOWN, ^task_ref, :process, ^task, :normal}, 5_000
          assert {:messages, messages} = Process.info(actor, :messages)

          expected = %{
            state: :running,
            compute_empty: false,
            disk_present: true,
            cleanup_complete: false,
            reason: :none
          }

          # The actor's task replies {result, observed target}; only the result is pinned.
          assert Enum.any?(messages, &match?({^result_ref, {{:ok, ^expected}, _target}}, &1))
          completed = FakeExecutor.read(Path.join(directory, "fake-executor.json"))
          assert completed["status"] == "running"
          assert completed["attempts"] == %{attempt_key(intent) => 1}
          assert File.read!(journal_path) == before
          refute_receive {:vm_actor_outcome, @placement_id, ^actor, _}, 0
          actor_ref = Process.monitor(actor)
          Process.exit(actor, :kill)
          assert_receive {:DOWN, ^actor_ref, :process, ^actor, :killed}, 2_000
          assert File.read!(journal_path) == before

          recovered = reconcile_completed_once(store, directory, intent)
          assert_running(recovered, intent)
          assert recovered.sequence == 1
          assert FakeExecutor.read(Path.join(directory, "fake-executor.json")) == completed
          replayed = reconcile_completed_once(store, directory, intent)
          assert replayed == recovered
          assert FakeExecutor.read(Path.join(directory, "fake-executor.json")) == completed
        after
          stop_completed_actor(actor)
        end
      end,
      test_cases: 100
    )
  end

  @spec stop_completed_actor(pid()) :: :ok
  defp stop_completed_actor(actor) do
    ref = Process.monitor(actor)
    if Process.alive?(actor), do: Process.exit(actor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^actor, _}, 2_000
    :ok
  end

  @spec reconcile_completed_once(Store.t(), Path.t(), Store.command()) ::
          OverallsProtocol.Execution.outcome()
  defp reconcile_completed_once(store, directory, command) do
    {:ok, actor} =
      Actor.start_link(
        store: store,
        vm_id: @vm_id,
        placement_id: @placement_id,
        owner: self(),
        executor: {FakeExecutor, directory}
      )

    Process.unlink(actor)

    try do
      assert_receive {:vm_actor_ready, @placement_id, ^actor, _}, 2_000
      Actor.reconcile(actor)
      assert_receive {:vm_actor_reconciled, @placement_id, ^actor, _}, 5_000
      assert_receive {:vm_actor_outcome, @placement_id, ^actor, outcome}, 2_000
      assert outcome.generation == command.generation
      GenServer.stop(actor)

      raw =
        directory
        |> Path.join("actors/#{@placement_id}/journal.json")
        |> File.read!()
        |> JSON.decode!()

      assert raw["attempted_generation"] == command.generation
      assert {:ok, ^outcome} = OverallsProtocol.Execution.outcome(raw["outcome"])
      outcome
    after
      stop_completed_actor(actor)
    end
  end

  @spec fresh_directory(Path.t()) :: Path.t()
  defp fresh_directory(root) do
    directory = Path.join(root, Lilly.UUID.generate())
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end

  @spec reconcile_once(Store.t(), Path.t(), Store.command()) ::
          OverallsProtocol.Execution.outcome()
  defp reconcile_once(store, directory, command) do
    {:ok, actor} =
      Actor.start_link(
        store: store,
        vm_id: @vm_id,
        placement_id: @placement_id,
        owner: self(),
        executor: {FakeExecutor, directory}
      )

    assert_receive {:vm_actor_ready, @placement_id, ^actor, _}, 2_000
    Actor.reconcile(actor)
    assert_receive {:vm_actor_reconciled, @placement_id, ^actor, _}, 5_000
    assert_receive {:vm_actor_outcome, @placement_id, ^actor, outcome}, 2_000
    assert outcome.generation == command.generation
    GenServer.stop(actor)

    journal_dir = Path.join([directory, "actors", @placement_id])
    assert {:ok, journal} = Journal.open(journal_dir, @host_id, @vm_id, @placement_id)
    assert journal.attempted_generation == command.generation
    assert journal.outcome == outcome
    outcome
  end

  @spec assert_running(OverallsProtocol.Execution.outcome(), Store.command()) :: :ok
  defp assert_running(outcome, command) do
    assert outcome.state == :running
    assert outcome.execution_epoch == command.execution_epoch
    assert outcome.generation == command.generation
    :ok
  end

  @spec assert_unique_attempts(Path.t(), Store.command()) :: :ok
  defp assert_unique_attempts(directory, current) do
    state = FakeExecutor.read(Path.join(directory, "fake-executor.json"))
    assert state["status"] == "running"
    assert state["generation"] == current.generation
    assert map_size(state["attempts"]) == current.generation
    assert Enum.all?(state["attempts"], fn {_key, count} -> count == 1 end)
    :ok
  end

  @spec attempt_key(Store.command()) :: String.t()
  defp attempt_key(command),
    do: "#{command.placement_id}:#{command.execution_epoch}:#{command.generation}"

  @spec command(pos_integer()) :: Store.command()
  defp command(generation),
    do: %{
      id: Lilly.UUID.generate(),
      vm_id: @vm_id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @placement_id,
      execution_epoch: 1,
      host_id: @host_id,
      pool_id: @pool_id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: generation,
      kind: :provision,
      architecture: :x86_64,
      profile: :standard,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
end
