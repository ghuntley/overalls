defmodule Lilly.VM.ActorFailureSettledTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.Store
  alias Lilly.VM.Actor
  @moduletag :tmp_dir
  # Positive receives wait for the actual signal; the bound only fails a
  # genuinely lost message, so it is generous for loaded hosts (a 2 s bound
  # flaked under a load average of about 20 on 2026-11-01). Negative bounds
  # are unchanged.
  @receive_ms 15_000

  @type event :: :tick | :cast | :restart | :newer_command
  @type run :: %{actor: pid(), command: map(), store: Store.t(), options: keyword()}

  defmodule ControlledExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile(owner, command, history) do
      send(owner, {:execute, self(), command, history})

      receive do
        {:result, result} -> result
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity;recovery] settled-failure-drive-model
  # Generated histories of periodic ticks, unchanged reconcile casts, actor
  # restarts and newer commands over a placement whose every launch fails MUST
  # start executor work exactly once per (actor process, stored command): a
  # durably recorded failure is never re-driven by a tick or unchanged cast, a
  # replacement actor re-observes it once without appending a durable outcome,
  # and a newer command or a delete still drives at once. A recorded failure
  # MUST remain the pending outcome Marshall receives.
  @tag :hegel
  test "a recorded failure is driven once per actor process and command", context do
    Hegel.check(
      fn ->
        events =
          draw(
            "events",
            list_of(
              frequency([
                {4, constant(:tick)},
                {4, constant(:cast)},
                {1, constant(:restart)},
                {2, constant(:newer_command)}
              ]),
              max_length: 14
            )
          )

        reason = draw("reason", member_of([:execution_failed, :crashed]))
        run = boot(context.tmp_dir)

        try do
          before = drive_failure(run, reason)
          assert before.sequence == 1

          run =
            Enum.reduce(events, run, fn event, run ->
              step(event, run, reason)
            end)

          # A delete is a newer command and drives at once, even from a settled failure.
          delete = %{newer(run.command) | kind: :delete}
          {:ok, :stored} = Store.accept(run.store, delete)
          Actor.reconcile(run.actor)
          assert_receive {:execute, worker, ^delete, _}, @receive_ms
          send(worker, {:result, {:ok, observation(:deleted, :none)}})
          id = delete.placement_id
          actor = run.actor
          assert_receive {:vm_actor_outcome, ^id, ^actor, %{state: :deleted}}, @receive_ms
        after
          stop_case(run.command.placement_id)
        end
      end,
      test_cases: 100
    )
  end

  # The actor's own one-second timer: two periods after a recorded failure no
  # work has started, and a newer command is driven as soon as it is cast.
  test "the periodic tick does not re-drive a settled failure", context do
    run = boot(context.tmp_dir)
    drive_failure(run, :execution_failed)
    refute_receive {:execute, _, _, _}, 2_500
    assert %{executing: false, outcome_sequence: 1} = Actor.status(run.actor)

    command = newer(run.command)
    {:ok, :stored} = Store.accept(run.store, command)
    Actor.reconcile(run.actor)
    assert_receive {:execute, _worker, ^command, _}, @receive_ms
    stop_supervised!(command.placement_id)
  end

  @spec step(event(), run(), atom()) :: run()
  defp step(event, run, _reason) when event in [:tick, :cast] do
    before = Actor.status(run.actor)
    if event == :tick, do: send(run.actor, :tick), else: Actor.reconcile(run.actor)
    _ = :sys.get_state(run.actor)
    refute_received {:execute, _, _, _}
    assert %{executing: false} = after_step = Actor.status(run.actor)
    assert after_step.outcome_sequence == before.outcome_sequence
    run
  end

  defp step(:restart, run, reason) do
    id = run.command.placement_id
    stop_case(id)
    actor = start_supervised!({Actor, run.options}, id: id)
    assert_receive {:vm_actor_ready, ^id, ^actor, pending}, @receive_ms
    run = %{run | actor: actor}
    recorded = :sys.get_state(actor).journal.outcome
    assert pending == nil or pending.id == recorded.id

    # The replacement observes the same failure once; the journal is unchanged.
    outcome = drive_failure(run, reason)
    assert outcome == recorded
    run
  end

  defp step(:newer_command, run, reason) do
    command = newer(run.command)
    {:ok, :stored} = Store.accept(run.store, command)
    run = %{run | command: command}
    previous = :sys.get_state(run.actor).journal.outcome
    outcome = drive_failure(run, reason)
    assert outcome.generation == command.generation
    assert outcome.sequence == previous.sequence + 1
    run
  end

  # Casts a reconcile, answers the single resulting execution with a failure
  # and returns the recorded outcome, which is also the pending outcome
  # delivered to the runtime (and from there to Marshall).
  @spec drive_failure(run(), atom()) :: map()
  defp drive_failure(run, reason) do
    command = run.command
    id = command.placement_id
    actor = run.actor
    Actor.reconcile(actor)
    assert_receive {:execute, worker, ^command, _}, @receive_ms
    monitor = Process.monitor(worker)
    send(worker, {:result, {:ok, observation(:failed, reason)}})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @receive_ms
    assert_receive {:vm_actor_outcome, ^id, ^actor, %{state: :failed} = pending}, @receive_ms
    assert_receive {:vm_actor_reconciled, ^id, ^actor, _authority}, @receive_ms
    _ = :sys.get_state(actor)
    refute_received {:execute, _, _, _}
    outcome = :sys.get_state(actor).journal.outcome
    assert pending == outcome
    assert %{state: :failed, reason: ^reason, operation_id: operation} = outcome
    assert operation == command.id
    outcome
  end

  @spec boot(Path.t()) :: run()
  defp boot(tmp_dir) do
    id = Lilly.UUID.generate()
    directory = Path.join(tmp_dir, id)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, id, 3)
    command = command(id)
    {:ok, :stored} = Store.accept(store, command)

    options = [
      store: store,
      vm_id: id,
      placement_id: id,
      execution_epoch: 1,
      owner: self(),
      executor: {ControlledExecutor, self()}
    ]

    actor = start_supervised!({Actor, options}, id: id)
    assert_receive {:vm_actor_ready, ^id, ^actor, nil}, @receive_ms
    %{actor: actor, command: command, store: store, options: options}
  end

  # Synchronously stop this case's producer before removing only its queued
  # executions. An execution from any live worker remains an oracle failure.
  @spec stop_case(String.t()) :: :ok
  defp stop_case(id) do
    assert stop_supervised(id) in [:ok, {:error, :not_found}]
    drain_stopped_executions(id)
  end

  @spec drain_stopped_executions(String.t()) :: :ok
  defp drain_stopped_executions(id) do
    receive do
      {:execute, worker, %{placement_id: ^id}, _} ->
        refute Process.alive?(worker), "stopped actor retained a live executor"
        drain_stopped_executions(id)
    after
      0 -> :ok
    end
  end

  @spec newer(map()) :: map()
  defp newer(command),
    do: %{command | id: Lilly.UUID.generate(), kind: :start, generation: command.generation + 1}

  @spec observation(:failed | :deleted, atom()) :: map()
  defp observation(state, reason),
    do: %{
      state: state,
      compute_empty: true,
      disk_present: state == :failed,
      cleanup_complete: state == :deleted,
      reason: reason
    }

  @spec command(String.t()) :: map()
  defp command(id),
    do: %{
      id: Lilly.UUID.generate(),
      vm_id: id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: id,
      execution_epoch: 1,
      host_id: id,
      pool_id: id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: 1,
      kind: :provision,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
end
