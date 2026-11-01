defmodule Lilly.VM.ActorEffectBoundaryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.Store
  alias Lilly.Execution
  alias Lilly.VM.Actor
  @moduletag :tmp_dir

  @deadline_ms 300
  # The deadline is enforced by the actor's one-second tick.
  @kill_bound_ms @deadline_ms + 1_000 + 700

  @type run :: %{actor: pid(), store: Store.t(), command: map(), directory: Path.t()}

  # Reports each reconcile and blocks until told to finish; a task that is
  # never told models a wedged effect (a stop on a hung guest, a delete on a
  # busy dataset).
  defmodule Executor do
    @behaviour Lilly.VM.Executor

    @impl true
    def reconcile(owner, command, _history) do
      send(owner, {:execute, self(), command.generation, command.kind})

      receive do
        :finish -> {:ok, observation(command)}
      end
    end

    @impl true
    def watch_target(_owner, _command), do: :error

    defp observation(%{kind: :delete}),
      do: %{
        state: :deleted,
        compute_empty: true,
        disk_present: false,
        cleanup_complete: true,
        reason: :none
      }

    defp observation(_command),
      do: %{
        state: :stopped,
        compute_empty: true,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }
  end

  # non-launch-effects-finish-or-deadline: a newer stop or start waits for an
  # in-flight stop to finish and then runs at once; a newer delete preempts
  # it at once; a wedged stop is killed within its deadline plus one tick and
  # the newer command then runs.
  @tag :hegel
  test "a newer command waits for a non-launch effect only up to its deadline", context do
    Hegel.check(
      fn ->
        newer = draw("newer", member_of([:stop, :start, :delete]))
        effect = draw("effect", member_of([:finishes, :wedged]))
        delay = draw("delay", integer(0..200))
        run = boot(context.tmp_dir)

        try do
          Actor.reconcile(run.actor)
          assert_receive {:execute, first, 1, :stop}, 2000
          ref = Process.monitor(first)
          store_newer(run, newer)

          cond do
            newer == :delete ->
              assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 2000

            effect == :finishes ->
              refute_receive {:DOWN, ^ref, :process, ^first, _}, delay
              send(first, :finish)
              assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 2000

            true ->
              assert_receive {:DOWN, ^ref, :process, ^first, :killed}, @kill_bound_ms
          end

          assert_receive {:execute, second, 2, ^newer}, 2000
          send(second, :finish)
          refute_received {:execute, _, 1, _}
        after
          stop_case(run.command.placement_id)
        end
      end,
      test_cases: 30
    )
  end

  test "a running stop is not killed by a newer stop before its deadline", context do
    run = boot(context.tmp_dir)
    Actor.reconcile(run.actor)
    assert_receive {:execute, first, 1, :stop}, 2000
    ref = Process.monitor(first)
    store_newer(run, :stop)
    # Strictly inside the deadline (which the tick checks), the stop survives.
    refute_receive {:DOWN, ^ref, :process, ^first, _}, @deadline_ms - 100
    send(first, :finish)
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 2000
    assert_receive {:execute, second, 2, :stop}, 2000
    send(second, :finish)
    stop_case(run.command.placement_id)
  end

  # The escape hatch: a newer delete preempts even a wedged pause capture,
  # whose own deadline is hours.
  test "a newer delete preempts a wedged pause at once", context do
    run = boot(context.tmp_dir, 14_400_000)
    pause = %{run.command | id: Lilly.UUID.generate(), generation: 2, kind: :pause}
    {:ok, :stored} = Store.accept(run.store, pause)
    Actor.reconcile(run.actor)
    assert_receive {:execute, first, 2, :pause}, 2000
    ref = Process.monitor(first)
    delete = %{run.command | id: Lilly.UUID.generate(), generation: 3, kind: :delete}
    {:ok, :stored} = Store.accept(run.store, delete)
    Actor.reconcile(run.actor)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 2000
    assert_receive {:execute, second, 3, :delete}, 2000
    send(second, :finish)
    stop_case(run.command.placement_id)
  end

  # An unreadable command store proves nothing about a newer command, so it
  # must not kill a running non-launch effect before its deadline.
  test "an unreadable store does not kill a running stop before its deadline", context do
    run = boot(context.tmp_dir, 3_000)
    Actor.reconcile(run.actor)
    assert_receive {:execute, first, 1, :stop}, 2000
    ref = Process.monitor(first)
    actor = Process.monitor(run.actor)
    File.write!(Path.join(run.store.path, run.command.placement_id <> ".json"), "not a command")
    Actor.reconcile(run.actor)
    # Two ticks pass with the store unreadable; the stop is not killed.
    refute_receive {:DOWN, ^ref, :process, ^first, _}, 2_200
    send(first, :finish)
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 2000
    # The actor then stops on the unreadable store, as before.
    assert_receive {:DOWN, ^actor, :process, _, _}, 2000
    stop_case(run.command.placement_id)
  end

  @spec store_newer(run(), atom()) :: :ok
  defp store_newer(run, kind) do
    command = %{run.command | id: Lilly.UUID.generate(), generation: 2, kind: kind}
    {:ok, :stored} = Store.accept(run.store, command)
    Actor.reconcile(run.actor)
    :ok
  end

  @spec boot(Path.t(), pos_integer()) :: run()
  defp boot(tmp_dir, deadline_ms \\ @deadline_ms) do
    id = Lilly.UUID.generate()
    directory = Path.join(tmp_dir, id)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, id, 3)
    command = command(id)
    {:ok, :stored} = Store.accept(store, command)
    view = :"effect_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view}, id: {:view, id})
    :ok = Execution.runtime_connected(view)
    :ok = Execution.intent(view, command)

    options = [
      store: store,
      placement_id: id,
      owner: self(),
      executor: {Executor, self()},
      view: view,
      watch_executable: nil,
      effect_deadline_ms: deadline_ms
    ]

    # Temporary: the unreadable-store case stops the actor, as in production.
    actor =
      start_supervised!(Supervisor.child_spec({Actor, options}, id: id, restart: :temporary))

    %{actor: actor, store: store, command: command, directory: directory}
  end

  @spec stop_case(String.t()) :: :ok
  defp stop_case(id) do
    assert stop_supervised(id) in [:ok, {:error, :not_found}]
    _ = stop_supervised({:view, id})
    drain()
  end

  @spec drain() :: :ok
  defp drain do
    receive do
      {:execute, _, _, _} -> drain()
      {:DOWN, _, :process, _, _} -> drain()
    after
      0 -> :ok
    end
  end

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
      kind: :stop,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
end
