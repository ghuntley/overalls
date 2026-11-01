defmodule Lilly.VM.ActorWatchTest do
  # The ordered observation/exit regression captures the global Logger stream.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Machine
  alias Lilly.Control.Store
  alias Lilly.Execution
  alias Lilly.Execution.Watch
  alias Lilly.VM.Actor
  @id "11111111-1111-4111-8111-111111111111"
  @moduletag :tmp_dir
  @type fixture :: %{
          dir: Path.t(),
          store: Store.t(),
          view: atom(),
          script: Path.t(),
          command: OverallsProtocol.Execution.command()
        }

  defmodule RunningExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile(_dir, _command, _history),
      do:
        {:ok,
         %{
           state: :running,
           compute_empty: false,
           disk_present: true,
           cleanup_complete: false,
           reason: :none
         }}

    @impl true
    def watch_target(dir, _command), do: {:ok, %{pid: 4242, cgroup: dir}}
  end

  defmodule ControlledExecutor do
    @behaviour Lilly.VM.Executor
    @type context :: {Path.t(), pid()}
    @type history :: %{
            running_epoch: non_neg_integer(),
            running_generation: non_neg_integer()
          }

    @impl true
    @spec reconcile(context(), OverallsProtocol.Execution.command(), history()) ::
            Lilly.VM.Executor.result()
    def reconcile({_dir, owner}, command, _history) do
      send(owner, {:execute, self(), command})

      receive do
        {:result, result} -> result
      end
    end

    @impl true
    @spec watch_target(context(), OverallsProtocol.Execution.command()) ::
            {:ok, Watch.target()} | :error
    def watch_target({dir, _owner}, _command) do
      if File.exists?(Path.join(dir, "target-unavailable")) do
        :error
      else
        pid = if File.exists?(Path.join(dir, "target-b")), do: 4243, else: 4242
        {:ok, %{pid: pid, cgroup: dir}}
      end
    end

    @impl true
    @spec boot_proof(context(), OverallsProtocol.Execution.command()) ::
            {:ok, Watch.target()} | {:error, :execution_unavailable}
    def boot_proof({dir, _owner} = context, command) do
      if File.exists?(Path.join(dir, "boot-proof")) do
        case watch_target(context, command) do
          {:ok, target} -> {:ok, target}
          :error -> {:error, :execution_unavailable}
        end
      else
        {:error, :execution_unavailable}
      end
    end
  end

  describe "watch machine" do
    test "every declared pair reaches its table target and every other pair is refused" do
      for {state, event, expected} <- Machine.cases(Watch) do
        assert Watch.target(state, event) == expected
      end
    end

    property "terminal reports always revoke and only :absent opens a watcher" do
      target = %{pid: 1, cgroup: "/sys/fs/cgroup/x"}

      events =
        draw(
          "events",
          list_of(
            member_of([{:start, target}, :armed, :exited, :error, :crashed, :stop]),
            max_length: 60
          )
        )

      Enum.reduce(events, Watch.new(), fn event, watch ->
        case Watch.step(watch, event) do
          {:ok, next, effects} ->
            if event in [:exited, :error, :crashed],
              do: assert(effects == [{:revoke, event}])

            if match?({:open, _}, List.first(effects)), do: assert(watch.state == :absent)
            assert Watch.watching?(next, target) == (next.state == :watching)
            next

          {:error, :invalid_transition} ->
            watch
        end
      end)
    end
  end

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    {:ok, store} = Store.open(dir, @id, 3)

    command = %{
      id: Lilly.UUID.generate(),
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: 1,
      kind: :start,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    {:ok, :stored} = Store.accept(store, command)
    view = :"watch_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view})
    :ok = Execution.runtime_connected(view)
    :ok = Execution.intent(view, command)

    # A stand-in for lilly-vm-watch: arms, then reports exit when told to.
    script = Path.join(dir, "fake-vm-watch")

    # Like the real helper it exits when Lilly closes its stdin (EOF).
    File.write!(script, """
    #!#{System.find_executable("bash") || raise("missing fixture utility")}
    wait_parent() {
      if read -r -t 0.01 _; then
        return 1
      else
        read_status=$?
        [ "$read_status" -gt 128 ]
      fi
    }
    while [ -e "$1/hold-armed" ] || { [ "$2" = 4243 ] && [ ! -e "$1/arm-b" ]; }; do
      wait_parent || exit 0
    done
    echo armed
    while [ ! -e "$1/exit" ] && [ ! -e "$1/error" ] && [ ! -e "$1/crash" ]; do
      wait_parent || exit 0
    done
    [ -e "$1/crash" ] && exit 3
    [ -e "$1/error" ] && { echo error; exit 1; }
    echo exited
    """)

    File.chmod!(script, 0o700)
    %{dir: dir, store: store, view: view, script: script, command: command}
  end

  defp start_actor(ctx) do
    start_supervised!(
      {Actor,
       store: ctx.store,
       placement_id: @id,
       owner: self(),
       executor: {RunningExecutor, ctx.dir},
       view: ctx.view,
       watch_executable: ctx.script}
    )
  end

  defp live?(view), do: match?({:ok, _, _}, Execution.current(view, @id))

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] actor-watch-revokes-on-exit
  # A watcher reporting exit or crashing MUST revoke the live proof well
  # before the observation backstop, and emit vm.watch_ended.
  test "a VMM exit reported by the watcher revokes the live proof at once", ctx do
    actor = start_actor(ctx)
    Actor.reconcile(actor)
    eventually(fn -> live?(ctx.view) end)
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)

    started = System.monotonic_time(:millisecond)
    File.write!(Path.join(ctx.dir, "exit"), "")
    eventually(fn -> not live?(ctx.view) end)
    assert System.monotonic_time(:millisecond) - started < 1000
    assert :sys.get_state(actor).liveness.state == :revoked
  end

  # @cc [owner:ghuntley,label:verification;observability;security] actor-observation-before-watch-exit
  # A non-running observation MUST revoke authority immediately without losing
  # the existing watcher's later actual exit report. Keeping the watcher MUST
  # NOT renew proof, and its terminal report MUST emit exactly one exited event.
  # This is a deterministic actor/port ordering fixture, not native pidfd proof.
  test "an observation before watcher exit withdraws proof but retains the actual report", ctx do
    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :placement_id, :reason]], fn ->
        actor =
          start_supervised!(
            {Actor,
             store: ctx.store,
             placement_id: @id,
             owner: self(),
             executor: {ControlledExecutor, {ctx.dir, self()}},
             view: ctx.view,
             watch_executable: ctx.script}
          )

        Actor.reconcile(actor)
        assert_receive {:execute, first, _}, 2000
        send(first, {:result, {:ok, running()}})
        eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
        assert live?(ctx.view)
        port = :sys.get_state(actor).watch_port

        Actor.reconcile(actor)
        assert_receive {:execute, second, _}, 2000
        failed = %{running() | state: :failed, compute_empty: true, reason: :crashed}
        send(second, {:result, {:ok, failed}})
        assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :failed}}, 2000
        state = :sys.get_state(actor)
        refute live?(ctx.view)
        assert state.liveness.state == :revoked
        assert state.liveness_timer == nil
        assert state.watch_port == port
        assert state.watch.state == :watching

        # A late armed message cannot publish proof after negative evidence.
        send(actor, {port, {:data, {:eol, "armed"}}})
        _ = :sys.get_state(actor)
        refute live?(ctx.view)

        File.write!(Path.join(ctx.dir, "exit"), "")
        eventually(fn -> :sys.get_state(actor).watch.state == :absent end)
        refute live?(ctx.view)
      end)

    reports =
      log
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ "event=vm.watch_ended" and &1 =~ "placement_id=#{@id}"))

    assert length(reports) == 1
    assert hd(reports) =~ "reason=exited"
  end

  test "a withdrawn proof retains the watcher's actual error report", ctx do
    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :placement_id, :reason]], fn ->
        actor = controlled_actor(ctx)
        controlled_result(actor, running())
        eventually(fn -> :sys.get_state(actor).watch.state == :watching end)

        controlled_result(actor, %{
          running()
          | state: :failed,
            compute_empty: true,
            reason: :crashed
        })

        refute live?(ctx.view)
        File.write!(Path.join(ctx.dir, "error"), "")
        eventually(fn -> :sys.get_state(actor).watch.state == :absent end)
        refute live?(ctx.view)
      end)

    assert log =~ "event=vm.watch_ended"
    assert log =~ "reason=error"
    refute log =~ "reason=exited"
  end

  test "same-command recovery gets the long backstop only after its own new target arms", ctx do
    actor = controlled_actor(ctx)
    controlled_result(actor, running())
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    old_port = :sys.get_state(actor).watch_port
    # An unconfirmed observation revokes without settling the command; a
    # recorded failure would settle it (failed-outcome-settles-command).
    controlled_result(actor, unconfirmed())
    refute live?(ctx.view)

    File.write!(Path.join(ctx.dir, "target-b"), "")
    controlled_result(actor, running())
    state = :sys.get_state(actor)
    assert state.watch.state == :starting
    assert state.watch_port != old_port
    assert Port.info(old_port) == nil
    {:ok, _, proof} = Execution.current(ctx.view, @id)
    assert proof.valid_until - System.monotonic_time(:millisecond) <= 2000
    send(actor, {old_port, {:data, {:eol, "armed"}}})
    send(actor, {old_port, {:data, {:eol, "exited"}}})
    _ = :sys.get_state(actor)
    assert {:ok, _, ^proof} = Execution.current(ctx.view, @id)

    File.write!(Path.join(ctx.dir, "arm-b"), "")
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    {:ok, _, armed} = Execution.current(ctx.view, @id)
    assert armed.valid_until - System.monotonic_time(:millisecond) > 10_000
  end

  test "late real armed from a retained target cannot extend an ambiguous recovery proof", ctx do
    File.write!(Path.join(ctx.dir, "hold-armed"), "")
    actor = controlled_actor(ctx)
    controlled_result(actor, running())
    port = :sys.get_state(actor).watch_port
    assert :sys.get_state(actor).watch.state == :starting
    controlled_result(actor, unconfirmed())
    refute live?(ctx.view)
    File.write!(Path.join(ctx.dir, "target-unavailable"), "")
    controlled_result(actor, running())
    assert :sys.get_state(actor).proof_target == nil
    {:ok, _, proof} = Execution.current(ctx.view, @id)
    File.rm!(Path.join(ctx.dir, "hold-armed"))
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    assert :sys.get_state(actor).watch_port == port
    assert {:ok, _, ^proof} = Execution.current(ctx.view, @id)
    assert proof.valid_until - System.monotonic_time(:millisecond) <= 2000
  end

  test "a boot proof for a different target replaces old live authority with roster-only proof",
       ctx do
    actor = controlled_actor(ctx)
    controlled_result(actor, running())
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    File.write!(Path.join(ctx.dir, "boot-proof"), "")

    Actor.reconcile(actor)
    assert_receive {:execute, same, _}, 2000
    {:ok, _, original} = Execution.current(ctx.view, @id)
    send(same, {:result, {:retry, :booting}})
    eventually(fn -> :sys.get_state(actor).task == nil end)
    assert {:ok, _, ^original} = Execution.current(ctx.view, @id)

    File.write!(Path.join(ctx.dir, "target-b"), "")
    Actor.reconcile(actor)
    assert_receive {:execute, replaced, _}, 2000
    send(replaced, {:result, {:retry, :booting}})
    eventually(fn -> :sys.get_state(actor).liveness.state == :booting end)
    refute live?(ctx.view)
    assert {:ok, _, boot} = Execution.booted(ctx.view, @id)
    assert boot.valid_until - System.monotonic_time(:millisecond) <= 2000
    assert :sys.get_state(actor).proof_target.pid == 4243
    File.write!(Path.join(ctx.dir, "arm-b"), "")
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    refute live?(ctx.view)
    assert {:ok, _, boot} = Execution.booted(ctx.view, @id)
    assert boot.valid_until - System.monotonic_time(:millisecond) > 10_000
  end

  test "command replacement closes the old watcher and actor shutdown closes the current one",
       ctx do
    actor = controlled_actor(ctx)
    controlled_result(actor, running())
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    old_port = :sys.get_state(actor).watch_port
    command = %{ctx.command | id: Lilly.UUID.generate(), generation: 2}
    {:ok, :stored} = Store.accept(ctx.store, command)
    :ok = Execution.intent(ctx.view, command)
    Actor.reconcile(actor)
    assert_receive {:execute, worker, ^command}, 2000
    assert Port.info(old_port) == nil
    assert :sys.get_state(actor).watch.state == :absent
    refute live?(ctx.view)
    send(actor, {old_port, {:data, {:eol, "exited"}}})
    send(worker, {:result, {:ok, running()}})
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    port = :sys.get_state(actor).watch_port
    assert port != old_port
    stop_supervised!(Actor)
    assert Port.info(port) == nil
    # The view is cleared after the actor stops, not synchronously with it.
    eventually(fn -> not live?(ctx.view) end)
  end

  # @cc [owner:ghuntley,label:verification;security] watched-backstop-extension
  # Only proof backed by an armed watcher may carry the long backstop; an
  # unwatched proof keeps the two-second deadline.
  test "an armed watcher extends the proof to the watched backstop", ctx do
    actor = start_actor(ctx)
    Actor.reconcile(actor)
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)

    eventually(fn ->
      case Execution.current(ctx.view, @id) do
        {:ok, _, live} -> live.valid_until - System.monotonic_time(:millisecond) > 10_000
        :error -> false
      end
    end)
  end

  test "an unwatched proof keeps the two-second backstop", ctx do
    actor =
      start_supervised!(
        {Actor,
         store: ctx.store,
         placement_id: @id,
         owner: self(),
         executor: {RunningExecutor, ctx.dir},
         view: ctx.view,
         watch_executable: nil}
      )

    Actor.reconcile(actor)
    eventually(fn -> live?(ctx.view) end)
    {:ok, _, live} = Execution.current(ctx.view, @id)
    assert live.valid_until - System.monotonic_time(:millisecond) <= 2_000
  end

  test "a crashed watcher fails closed", ctx do
    actor = start_actor(ctx)
    Actor.reconcile(actor)
    eventually(fn -> live?(ctx.view) end)
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)
    File.write!(Path.join(ctx.dir, "crash"), "")
    eventually(fn -> not live?(ctx.view) end)
  end

  test "without a watcher executable the backstop alone governs", ctx do
    actor =
      start_supervised!(
        {Actor,
         store: ctx.store,
         placement_id: @id,
         owner: self(),
         executor: {RunningExecutor, ctx.dir},
         view: ctx.view,
         watch_executable: nil}
      )

    Actor.reconcile(actor)
    eventually(fn -> live?(ctx.view) end)
    assert :sys.get_state(actor).watch.state == :absent
  end

  @spec running() :: Lilly.VM.Executor.observation()
  # @cc [owner:ghuntley,label:verification;concurrency] steady-actor-skips-ticks-until-evidence
  # A watched actor whose unchanged running outcome repeated three times MUST
  # stop starting a reconcile on every tick, MUST still reconcile once the
  # 10 s backstop elapses, and MUST resume per-tick reconciles on a watcher
  # report (ADR-0176 steady-state-reconcile-backstop).
  test "a steady watched actor reconciles on the backstop and on watcher evidence", ctx do
    actor = controlled_actor(ctx)
    actor_monitor = Process.monitor(actor)
    controlled_result(actor, running())
    eventually(fn -> :sys.get_state(actor).watch.state == :watching end)

    eventually(fn ->
      receive do
        {:execute, worker, _} -> send(worker, {:result, {:ok, running()}})
      after
        50 -> :ok
      end

      :sys.get_state(actor).steady >= 3
    end)

    # Drain a run that a tick may have started just before steadiness.
    receive do
      {:execute, worker, _} -> send(worker, {:result, {:ok, running()}})
    after
      100 -> :ok
    end

    refute_receive {:execute, _, _}, 2500
    assert live?(ctx.view)

    # The backstop: an old last reconcile makes the next tick reconcile again.
    :sys.replace_state(actor, fn state ->
      %{state | last_reconcile_at: System.monotonic_time(:millisecond) - 11_000}
    end)

    assert_receive {:execute, worker, _}, 2000
    send(worker, {:result, {:ok, running()}})
    refute_receive {:execute, _, _}, 1500

    # Watcher evidence ends steadiness and per-tick reconciles resume.
    File.write!(Path.join(ctx.dir, "exit"), "")

    eventually(fn ->
      try do
        :sys.get_state(actor).steady == 0
      catch
        :exit, _ ->
          assert_receive {:DOWN, ^actor_monitor, :process, ^actor, _reason}, 2000
          flunk("processing an already-exited watcher must preserve the VM actor")
      end
    end)

    assert_receive {:execute, worker, _}, 2000
    send(worker, {:result, {:ok, running()}})
  end

  defp running,
    do: %{
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

  # Executor.unknown/1: inconclusive, revokes liveness, never settles.
  @spec unconfirmed() :: map()
  defp unconfirmed,
    do: %{
      state: :unknown,
      compute_empty: false,
      disk_present: false,
      cleanup_complete: false,
      reason: :identity_mismatch
    }

  @spec controlled_actor(fixture()) :: pid()
  defp controlled_actor(ctx) do
    start_supervised!(
      {Actor,
       store: ctx.store,
       placement_id: @id,
       owner: self(),
       executor: {ControlledExecutor, {ctx.dir, self()}},
       view: ctx.view,
       watch_executable: ctx.script}
    )
  end

  @spec controlled_result(pid(), Lilly.VM.Executor.observation()) :: :ok
  defp controlled_result(actor, observation) do
    Actor.reconcile(actor)
    assert_receive {:execute, worker, _}, 2000
    send(worker, {:result, {:ok, observation}})
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: state}}, 2000
    assert state == observation.state
    _ = :sys.get_state(actor)
    :ok
  end
end
