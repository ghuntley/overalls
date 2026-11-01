defmodule Lilly.VM.ActorResizeSettledTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.Store
  alias Lilly.VM.Actor
  @moduletag :tmp_dir

  @type run :: %{actor: pid(), store: Store.t(), stop: map(), resize: map()}

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

  # applied-resize-settles-command: the account-lifecycle failure of
  # 2026-11-01. Only a stopped outcome whose applied sizes equal the target
  # settles; one with the source sizes, or none, keeps the resize driven. After the resize outcome was recorded, the next tick re-ran
  # the resize (a second disk truncate and metadata rewrite), and the restart
  # command preempted that replay mid-effect. Generated tick and cast
  # histories after the recorded resize MUST start no executor work, and the
  # restart MUST then drive at once without preempting anything.
  @tag :hegel
  test "a recorded resize is not re-driven before the restart preempts it", context do
    Hegel.check(
      fn ->
        events =
          draw("events", list_of(member_of([:tick, :cast]), min_size: 1, max_size: 8))

        applied = draw("applied", member_of([:target, :source, :none]))
        run = boot(context.tmp_dir)

        try do
          drive_resize(run, applied)

          for event <- events do
            if event == :tick, do: send(run.actor, :tick), else: Actor.reconcile(run.actor)
            _ = :sys.get_state(run.actor)

            if applied == :target do
              refute_received {:execute, _, _, _}
              assert %{executing: false} = Actor.status(run.actor)
            else
              # A half-applied or unconfirmed resize keeps being driven.
              resize = run.resize
              assert_receive {:execute, worker, ^resize, _}, 2000
              finish(run, worker, applied)
            end
          end

          restart = restart(run.resize)
          {:ok, :stored} = Store.accept(run.store, restart)
          Actor.reconcile(run.actor)
          assert_receive {:execute, worker, ^restart, _}, 2000
          assert Process.alive?(worker)
          send(worker, {:result, {:ok, observation(:stopped)}})
        after
          stop_case(run.stop.placement_id)
        end
      end,
      test_cases: 25
    )
  end

  # The actor's own one-second timer does not re-drive a recorded resize.
  test "the periodic tick does not re-drive an applied resize", context do
    run = boot(context.tmp_dir)
    drive_resize(run)
    refute_receive {:execute, _, _, _}, 2_500
    assert %{executing: false} = Actor.status(run.actor)
    stop_case(run.stop.placement_id)
  end

  # A replacement actor still drives the resize once (resumable journal).
  test "a replacement actor drives the recorded resize once", context do
    run = boot(context.tmp_dir)
    drive_resize(run)
    id = run.stop.placement_id
    stop_case(id)
    actor = start_supervised!({Actor, options(run.store, id)}, id: id)
    assert_receive {:vm_actor_ready, ^id, ^actor, _pending}, 2000
    drive_resize(%{run | actor: actor})
    refute_receive {:execute, _, _, _}, 1_500
    stop_case(id)
  end

  @spec drive_resize(run(), :target | :source | :none) :: :ok
  defp drive_resize(run, applied \\ :target) do
    resize = run.resize
    Actor.reconcile(run.actor)
    assert_receive {:execute, worker, ^resize, _}, 2000
    finish(run, worker, applied)
    if applied == :target, do: refute_received({:execute, _, _, _})
    outcome = :sys.get_state(run.actor).journal.outcome
    assert %{state: :stopped} = outcome

    case applied do
      :target -> assert outcome.applied_sizes == OverallsProtocol.Resize.sizes(resize)
      :source -> assert outcome.applied_sizes == resize.resize_from
      :none -> refute Map.has_key?(outcome, :applied_sizes)
    end

    :ok
  end

  # Answers one execution of the resize and waits for the actor to record it.
  @spec finish(run(), pid(), :target | :source | :none) :: :ok
  defp finish(run, worker, applied) do
    resize = run.resize
    id = resize.placement_id
    actor = run.actor
    monitor = Process.monitor(worker)

    result =
      case applied do
        :target ->
          Map.put(observation(:stopped), :applied_sizes, OverallsProtocol.Resize.sizes(resize))

        :source ->
          Map.put(observation(:stopped), :applied_sizes, resize.resize_from)

        :none ->
          observation(:stopped)
      end

    send(worker, {:result, {:ok, result}})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
    assert_receive {:vm_actor_reconciled, ^id, ^actor, _authority}, 2000
    _ = :sys.get_state(actor)
    :ok
  end

  @spec boot(Path.t()) :: run()
  defp boot(tmp_dir) do
    id = Lilly.UUID.generate()
    directory = Path.join(tmp_dir, id)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, id, 3)
    stop = %{command(id) | kind: :stop}
    {:ok, :stored} = Store.accept(store, stop)
    actor = start_supervised!({Actor, options(store, id)}, id: id)
    assert_receive {:vm_actor_ready, ^id, ^actor, nil}, 2000
    Actor.reconcile(actor)
    assert_receive {:execute, worker, ^stop, _}, 2000
    send(worker, {:result, {:ok, observation(:stopped)}})
    assert_receive {:vm_actor_reconciled, ^id, ^actor, _authority}, 2000

    resize =
      Map.merge(stop, %{
        id: Lilly.UUID.generate(),
        generation: 2,
        kind: :resize,
        vcpu: 2,
        disk_bytes: stop.disk_bytes * 2,
        resize_from: OverallsProtocol.Resize.sizes(stop),
        resize_id: Lilly.UUID.generate()
      })

    {:ok, :stored} = Store.accept(store, resize)
    %{actor: actor, store: store, stop: stop, resize: resize}
  end

  @spec options(Store.t(), String.t()) :: keyword()
  defp options(store, id),
    do: [
      store: store,
      vm_id: id,
      placement_id: id,
      execution_epoch: 1,
      owner: self(),
      executor: {ControlledExecutor, self()}
    ]

  @spec restart(map()) :: map()
  defp restart(resize),
    do:
      resize
      |> Map.drop([:resize_from])
      |> Map.merge(%{id: Lilly.UUID.generate(), kind: :start, generation: resize.generation + 1})

  @spec stop_case(String.t()) :: :ok
  defp stop_case(id) do
    assert stop_supervised(id) in [:ok, {:error, :not_found}]
    drain(id)
  end

  @spec drain(String.t()) :: :ok
  defp drain(id) do
    receive do
      {:execute, worker, %{placement_id: ^id}, _} ->
        refute Process.alive?(worker), "stopped actor retained a live executor"
        drain(id)
    after
      0 -> :ok
    end
  end

  @spec observation(:stopped) :: map()
  defp observation(state),
    do: %{
      state: state,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
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
