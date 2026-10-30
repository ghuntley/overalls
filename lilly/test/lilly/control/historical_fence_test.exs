defmodule Lilly.Control.HistoricalFenceTest do
  @moduledoc """
  Characterization pins for the current historical-authority fence behavior. A
  restored pre-revocation control-plane snapshot can only replay regressed
  commands and stale sessions at a surviving host; these fixed tests record the
  current protections that the (still proposal-only) quarantine design builds on.
  Generated transient exchange histories characterize recovery without fencing.

  Physical inventory fencing requires the [native-zfs machine scenario][native-zfs],
  specifically "large tracked unit inventory omits descriptions and still rejects
  unknown resources". It uses actual systemd units and cgroups to verify tracked
  inventory acceptance, refusal when a unit is absent from the expected placement
  set, and rejection of an unknown child cgroup. Ordinary tests cannot assume the
  local host inventory: an enrolled host may have a readable, empty lilly.slice
  after all guests are deleted.

  [native-zfs]: ../../../../nix/verification/tests/machines/native-zfs/driver.py
  """
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.{Runtime, Store}
  alias Lilly.VM.Actor
  @host "11111111-1111-4111-8111-111111111111"
  @vm "44444444-4444-4444-8444-444444444444"
  @placement "22222222-2222-4222-8222-222222222222"
  @pool "33333333-3333-4333-8333-333333333333"
  @moduletag :tmp_dir

  defmodule IdleExecutor do
    @moduledoc false
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile(_context, _command, _history),
      do: raise("unreachable: fenced actors must not execute")
  end

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, @host, 3)
    newer = %{command(2, :start) | execution_epoch: 2}
    {:ok, :stored} = Store.accept(store, newer)
    %{store: store, directory: directory, newer: newer}
  end

  # @cc [owner:ghuntley,label:verification;recovery] fence-replay-acked-without-rollback
  # A replayed command with a regressed execution_epoch/generation pair MUST be
  # acknowledged only after rereading matching-or-newer durable intent, without
  # moving the durable record backwards and without fencing. Command replay from a
  # restored historical snapshot cannot resurrect superseded authority this way;
  # unknown pools and failed or corrupt storage MUST fence receipt processing.
  test "regressed command replay is acknowledged without rolling back durable intent", %{
    store: store,
    newer: newer
  } do
    replayed = command(1, :start)
    state = connected_state(store, %{@placement => newer})

    assert {:noreply, after_exchange} =
             deliver(state, {:ok, %{commands: [replayed], outcome_acknowledgements: []}})

    assert after_exchange.pending_acks == [replayed.id]
    assert after_exchange.durable == %{@placement => newer}
    assert after_exchange.phase == :connected
    assert {:ok, ^newer} = Store.read(store, @placement)
  end

  test "exact duplicate delivery of current intent is acknowledged idempotently", %{
    store: store,
    newer: newer
  } do
    state = connected_state(store, %{@placement => newer})

    assert {:noreply, after_exchange} =
             deliver(state, {:ok, %{commands: [newer], outcome_acknowledgements: []}})

    assert after_exchange.pending_acks == [newer.id]
    assert after_exchange.phase == :connected
    assert {:ok, ^newer} = Store.read(store, @placement)
  end

  test "an unknown-pool receipt fences the batch without acknowledging anything", %{
    store: store,
    newer: newer
  } do
    foreign = %{command(3, :start) | placement_id: @vm, pool_id: @vm}
    follower = command(3, :start)
    state = connected_state(store, %{@placement => newer})

    assert {:noreply, after_exchange} =
             deliver(
               state,
               {:ok, %{commands: [foreign, follower], outcome_acknowledgements: []}}
             )

    assert after_exchange.phase == :fenced
    assert after_exchange.last_error == :command_store_failed
    assert after_exchange.pending_acks == []
    assert after_exchange.durable == %{@placement => newer}
    assert {:ok, ^newer} = Store.read(store, @placement)
  end

  test "corrupt durable storage fences receipt processing instead of acknowledging", %{
    store: store,
    newer: newer
  } do
    File.write!(Path.join(store.path, @placement <> ".json"), "broken")
    replayed = command(1, :start)
    state = connected_state(store, %{@placement => newer})

    assert {:noreply, after_exchange} =
             deliver(state, {:ok, %{commands: [replayed], outcome_acknowledgements: []}})

    assert after_exchange.phase == :fenced
    assert after_exchange.last_error == :command_store_failed
    assert after_exchange.pending_acks == []
    assert {:error, :invalid_stored_command} = Store.read(store, @placement)
  end

  # @cc [owner:ghuntley,label:verification;security] fence-stops-authority-preserves-guests
  # An :unauthorized or stale-session exchange result MUST fence the runtime: stop
  # actor supervision, the terminal stream and clone/transfer workers, keep durable
  # placement intent untouched, emit the fenced metric count and never reopen
  # sampling or exchanges by itself. Independently supervised guest VMMs are
  # outside the runtime child set and MUST NOT be touched by fencing.
  test ":unauthorized fence stops authority, preserves durable intent and never reopens", %{
    store: store,
    newer: newer
  } do
    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:lilly, :control, :fenced],
      fn event, measurements, metadata, pid ->
        send(pid, {:fenced, event, measurements, metadata})
      end,
      self()
    )

    supervisor =
      start_supervised!(
        Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :fenced_vms)
      )

    actor_options = [
      store: store,
      placement_id: @placement,
      vm_id: @vm,
      owner: self(),
      executor: {IdleExecutor, nil}
    ]

    {:ok, actor} = DynamicSupervisor.start_child(supervisor, {Actor, actor_options})
    assert_receive {:vm_actor_ready, @placement, ^actor, nil}, 2000
    actor_ref = Process.monitor(actor)
    actor_watch = Process.monitor(actor)
    terminal = start_agent()
    clone = start_agent()
    transfer = start_agent()
    watches = Map.new([terminal, clone, transfer], &{&1, Process.monitor(&1)})

    state =
      Map.merge(connected_state(store, %{@placement => newer}), %{
        vm_supervisor: supervisor,
        actors: %{@placement => %{pid: actor, ref: actor_ref, reconciled: nil}},
        actor_refs: %{actor_ref => @placement},
        terminal: terminal,
        clone_control: clone,
        transfer_keys: transfer,
        terminal_ready: true
      })

    assert {:noreply, fenced} = deliver(state, {:error, :unauthorized})

    assert fenced.phase == :fenced
    assert fenced.last_error == :unauthorized
    assert fenced.vm_supervisor == nil
    assert fenced.actors == %{}
    assert fenced.actor_refs == %{}
    assert fenced.terminal == nil
    assert fenced.clone_control == nil
    assert fenced.transfer_keys == nil
    assert fenced.terminal_ready == false

    assert_receive {:DOWN, ^actor_watch, :process, ^actor, _reason}, 2000
    refute Process.alive?(actor)

    for {_pid, watch} <- watches do
      assert_receive {:DOWN, ^watch, :process, _pid, :normal}, 2000
    end

    assert_received {:fenced, [:lilly, :control, :fenced], %{count: 1}, %{}}

    # Fencing stops runtime authority only: durable placement intent survives so a
    # later authenticated session reconciles the same incarnation.
    assert fenced.durable == %{@placement => newer}
    assert {:ok, ^newer} = Store.read(store, @placement)

    # A fenced runtime never restarts sampling, exchanges or workers by itself.
    assert {:noreply, ^fenced} = Runtime.handle_info(:tick, fenced)
    assert fenced.sample_task == nil
    assert fenced.exchange_task == nil

    :telemetry.detach(handler)
  end

  test "a stale-session exchange result fences without touching durable intent", %{
    store: store,
    newer: newer
  } do
    state = connected_state(store, %{@placement => newer})

    assert {:noreply, fenced} = deliver(state, {:error, :stale_connection})
    assert fenced.phase == :fenced
    assert fenced.last_error == :stale_connection
    assert {:ok, ^newer} = Store.read(store, @placement)
    assert {:noreply, ^fenced} = Runtime.handle_info(:tick, fenced)
  end

  # @cc [owner:ghuntley,label:verification;security] generated-terminal-fence-rosters
  # Every terminal exchange class MUST stop every controlled actor, retain its
  # durable command and leave the runtime unable to restart work on a tick.
  @tag :hegel
  # The full 100-case budget measured 33-54 s under the parallel suite on
  # 8 local CPUs; the slower CI runner exceeded the 60 s default.
  @tag timeout: 180_000
  test "terminal exchange fences stop generated actor rosters without losing intent", %{
    store: store,
    newer: newer
  } do
    Hegel.check(
      fn ->
        actor_count = draw("actor_count", integer(1..4))

        for reason <- [
              :stale_connection,
              :unauthorized,
              :unsupported_version,
              :machine_identity_mismatch,
              :outcome_conflict,
              :invalid_outcome
            ] do
          extra =
            if actor_count > 1 do
              Enum.map(2..actor_count, fn _ ->
                %{
                  command(2, :start)
                  | placement_id: Lilly.UUID.generate(),
                    vm_id: Lilly.UUID.generate()
                }
              end)
            else
              []
            end

          commands = [newer | extra]

          for command <- extra do
            assert {:ok, :stored} = Store.accept(store, command)
          end

          durable = Map.new(commands, &{&1.placement_id, &1})

          supervisor =
            Overalls.HegelFixtures.start_supervised!(
              Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one},
                id: make_ref(),
                restart: :temporary
              )
            )

          actors =
            Enum.map(commands, fn command ->
              options = [
                store: store,
                placement_id: command.placement_id,
                vm_id: command.vm_id,
                owner: self(),
                executor: {IdleExecutor, nil}
              ]

              {:ok, actor} = DynamicSupervisor.start_child(supervisor, {Actor, options})
              placement = command.placement_id
              assert_receive {:vm_actor_ready, ^placement, ^actor, nil}, 2000
              {command, actor, Process.monitor(actor), Process.monitor(actor)}
            end)

          state =
            Map.merge(connected_state(store, durable), %{
              vm_supervisor: supervisor,
              actors:
                Map.new(actors, fn {command, actor, ref, _watch} ->
                  {command.placement_id, %{pid: actor, ref: ref, reconciled: nil}}
                end),
              actor_refs:
                Map.new(actors, fn {command, _actor, ref, _watch} ->
                  {ref, command.placement_id}
                end)
            })

          assert {:noreply, fenced} = deliver(state, {:error, reason})
          assert fenced.phase == :fenced
          assert fenced.last_error == reason
          assert fenced.vm_supervisor == nil
          assert fenced.actors == %{}
          assert fenced.actor_refs == %{}
          assert fenced.durable == durable
          assert {:reply, %{ready: false}, ^fenced} = Runtime.handle_call(:status, nil, fenced)
          assert {:noreply, ^fenced} = Runtime.handle_info(:tick, fenced)

          for {command, actor, _ref, watch} <- actors do
            assert_receive {:DOWN, ^watch, :process, ^actor, _reason}, 2000
            assert {:ok, ^command} = Store.read(store, command.placement_id)
          end
        end
      end,
      test_cases: 100
    )
  end

  @tag :hegel
  test "transient exchange failures back off and a delivered report restores readiness", %{
    store: store,
    newer: newer
  } do
    Hegel.check(
      fn ->
        errors =
          draw(
            "errors",
            list_of(
              member_of([
                :transport_error,
                :http_error,
                :temporarily_unavailable,
                :invalid_message,
                :invalid_report
              ]),
              min_length: 1,
              max_length: 6
            )
          )

        authority = {newer.placement_id, newer.execution_epoch, newer.generation}

        state =
          Map.merge(connected_state(store, %{@placement => newer}), %{
            terminal_ready: true,
            actors: %{@placement => %{pid: self(), reconciled: authority}},
            delivered_report_at: DateTime.add(DateTime.utc_now(), -16, :second)
          })

        assert {:reply, %{ready: false}, ^state} = Runtime.handle_call(:status, nil, state)

        degraded =
          errors
          |> Enum.with_index(1)
          |> Enum.reduce(state, fn {reason, attempt}, current ->
            before_exchange = System.monotonic_time(:millisecond)
            assert {:noreply, next} = deliver(current, {:error, reason})
            after_exchange = System.monotonic_time(:millisecond)
            failures = min(attempt, 5)
            delay = Runtime.retry_delay(failures)
            assert delay == min(4_000, 1000 * Integer.pow(2, failures - 1))

            assert next.phase == :connected
            assert next.failures == failures
            assert next.last_error == reason
            assert next.retry_at > before_exchange + delay
            assert next.retry_at <= after_exchange + delay + 500
            assert next.durable == %{@placement => newer}
            assert {:ok, ^newer} = Store.read(store, @placement)
            assert {:reply, %{ready: false}, ^next} = Runtime.handle_call(:status, nil, next)
            next
          end)

        sampled_at = DateTime.utc_now()

        ready_to_retry = %{
          degraded
          | retry_at: System.monotonic_time(:millisecond) - 1,
            exchange_report: %{sampled_at: sampled_at}
        }

        assert {:noreply, recovered} =
                 deliver(
                   ready_to_retry,
                   {:ok, %{commands: [], outcome_acknowledgements: []}}
                 )

        assert recovered.phase == :connected
        assert recovered.failures == 0
        assert recovered.last_error == nil
        assert recovered.delivered_report_at == sampled_at
        assert recovered.session_id == state.session_id
        assert recovered.durable == %{@placement => newer}
        assert {:reply, %{ready: true}, ^recovered} = Runtime.handle_call(:status, nil, recovered)
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] version-refusal-fences-after-transients
  # A terminal version refusal MUST fence Lilly after any generated transient
  # failure prefix, retain durable intent and never restart exchange on a tick.
  @tag :hegel
  test "version refusal fences after transient exchange histories", %{
    store: store,
    newer: newer
  } do
    Hegel.check(
      fn ->
        errors =
          draw(
            "errors",
            list_of(member_of([:transport_error, :temporarily_unavailable, :http_error]),
              max_length: 5
            )
          )

        state = connected_state(store, %{@placement => newer})

        degraded =
          Enum.reduce(errors, state, fn reason, current ->
            assert {:noreply, next} = deliver(current, {:error, reason})
            assert next.phase == :connected
            next
          end)

        assert {:noreply, fenced} = deliver(degraded, {:error, :unsupported_version})
        assert fenced.phase == :fenced
        assert fenced.last_error == :unsupported_version
        assert fenced.durable == %{@placement => newer}
        assert {:ok, ^newer} = Store.read(store, @placement)
        assert fenced.exchange_task == nil
        assert {:reply, %{ready: false}, ^fenced} = Runtime.handle_call(:status, nil, fenced)
        assert {:noreply, ^fenced} = Runtime.handle_info(:tick, fenced)
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification;security] unknown-units-fence-execution-readiness
  # Ownership.verify_units/1 MUST fail closed whenever the physical scan cannot
  # positively confirm that every lilly-vm unit and lilly.slice cgroup has a
  # durable command identity: an unknown physical unit, an unavailable systemctl
  # scan or an unreadable lilly.slice cgroup are all rejected identically. Runtime
  # initialization composes that rejection into the host-wide
  # :vm_reconciliation_required fence (Lilly.Control.Runtime.initialize_actors/2).
  # The scan MUST be isolated in its own BEAM with explicit utility fixtures;
  # the test MUST NOT assume the developer host lacks an empty lilly.slice or
  # mutate process-wide PATH while other asynchronous cases execute.
  test "physical units unknown to the durable command set fence execution readiness", %{
    tmp_dir: directory
  } do
    unknown = "lilly-vm-99999999-9999-4999-8999-999999999999.service\n"

    for {script, expected} <- [
          {"printf '%s\\n' lilly-vm-99999999-9999-4999-8999-999999999999.service",
           {:ok, unknown}},
          {"exit 1", {:error, :command_failed}}
        ] do
      fixture = Path.join(directory, "systemctl")

      query = ~S"""
      [ "$#" -eq 5 ] && [ "$1" = show ] && [ "$2" = --property=Id ] &&
        [ "$3" = --value ] && [ "$4" = --no-pager ] &&
        [ "$5" = 'lilly-vm-*.service' ] || exit 2
      """

      File.write!(fixture, "#!/bin/sh\n" <> query <> script <> "\n")
      File.chmod!(fixture, 0o700)

      probe = """
      expected = #{inspect(expected)}
      scan = Lilly.Host.Command.run(:systemctl, ["show", "--property=Id", "--value", "--no-pager", "lilly-vm-*.service"])
      unless scan == expected, do: raise("isolated utility fixture was not invoked")
      for commands <- [[#{inspect(command(1, :start))}], []] do
        unless Lilly.Host.Ownership.verify_units(commands) == {:error, :untracked_vm_units},
          do: raise("untracked physical units must refuse")
      end
      """

      paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
      executable = System.find_executable("elixir") || raise("pinned Elixir is required")
      inherited_path = System.fetch_env!("PATH")

      assert {_, 0} =
               System.cmd(executable, paths ++ ["-e", probe],
                 env: [{"PATH", directory <> ":" <> inherited_path}, {"ERL_FLAGS", "+S 2:2"}],
                 stderr_to_stdout: true
               )
    end
  end

  @spec deliver(map(), term()) :: {:noreply, map()}
  defp deliver(state, result) do
    ref = make_ref()
    exchange = struct(Task, ref: ref)
    Runtime.handle_info({ref, result}, %{state | exchange_task: exchange})
  end

  @spec start_agent() :: pid()
  defp start_agent do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    pid
  end

  @spec connected_state(Store.t(), %{OverallsProtocol.uuid() => map()}) :: map()
  defp connected_state(store, durable) do
    %{
      config: %{
        pools: [%{id: @pool}],
        client: %{host_id: @host, protocol_version: 4}
      },
      lock: nil,
      global: nil,
      vm_supervisor: nil,
      actors: %{},
      actor_refs: %{},
      outcomes: %{},
      capacity_proofs: %{},
      store: store,
      phase: :connected,
      session_id: @host,
      session: nil,
      sequence: 0,
      latest: nil,
      previous: nil,
      sample_task: nil,
      exchange_task: nil,
      exchange_report: nil,
      delivered_report_at: nil,
      sent_sequence: 0,
      pending_acks: [],
      durable: durable,
      retry_at: System.monotonic_time(:millisecond),
      failures: 0,
      last_error: nil,
      sample_error: nil,
      terminal: nil,
      transfer_keys: nil,
      transfer_key_retirement: nil,
      transfer_destination_revocation: nil,
      transfer_source: nil,
      inception: nil,
      clone_control: nil,
      clone_copy: nil,
      transfer_probe: nil,
      transfer_revocation: nil,
      transfer_snapshot_cleanup: nil,
      transfer_destination_cleanup: nil,
      transfer_receive: nil,
      transfer_import: nil,
      transfer_readiness: nil,
      transfer_cleanup: nil,
      terminal_ready: false,
      worker_failures: %{}
    }
  end

  @spec command(pos_integer(), atom()) :: map()
  defp command(generation, kind) do
    %{
      id: Lilly.UUID.generate(),
      vm_id: @vm,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @placement,
      execution_epoch: 1,
      host_id: @host,
      pool_id: @pool,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: generation,
      kind: kind,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
  end
end
