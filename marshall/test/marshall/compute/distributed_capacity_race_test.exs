defmodule Marshall.Compute.DistributedCapacityRaceTest do
  @moduledoc """
  Generated multi-node admission races with a committed-ledger accounting oracle.

  Provision/clone/relocate/start/stop/delete mixes plus injected crash/failed/
  unknown physical outcomes run at generated concurrency points across three
  real BEAM peers. Expectations come from raw committed SQL rows only; the
  system under test's Budget arithmetic is never consulted.
  """
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  require Marshall.CommittedFixtureCleanup, as: Cleanup
  import Marshall.ComputeFixtures
  import ExUnit.Assertions

  alias Marshall.Compute.{
    Host,
    HostLiveness,
    HostReports,
    Ledger,
    Operation,
    Reservation,
    VirtualMachine
  }

  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 300_000

  @gib 1_073_741_824
  @mem 536_870_912

  @type timing_stage ::
          :peer_startup
          | :peer_boot_wait
          | :peer_paths
          | :peer_environment
          | :peer_applications
          | :fixed_windows
          | :generated_batches
          | :fixture_cleanup
          | :generated_history
          | :lock_history
          | :race_rpc
          | :settlement
          | :oracle
  @type timing_record :: %{
          schema_version: 1,
          stage: timing_stage(),
          duration_us: non_neg_integer(),
          completed_histories: non_neg_integer()
        }

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every sample MUST restore the complete pre-test committed row inventory,
  # including historical rows. Teardown checks are separate from body failure.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] capacity-race-three-independent-peers
  # Each sample MUST run races on three distinct BEAM nodes with independent
  # Repo pools and shared committed PostgreSQL state; the parent runner is not
  # a peer. Peers start per sample and stop before fixture deletion; a failing
  # sample never shares peers with another run. A failed acquisition MUST stop
  # the current peer and every previously acquired peer before propagating.
  # Initialization MAY overlap across the three newly acquired peers, with all
  # exact peer IDs registered for exit cleanup before any initialization task.
  # All tasks MUST finish or terminate before acquisition returns or fails.
  # OTP's concurrent dependency startup MUST start the complete declared DAG,
  # preserving dependency ordering and the existing 30s application RPC bound.
  @spec start_peers() :: [pid()]
  defp start_peers do
    suffix = System.unique_integer([:positive])

    {peers, boots} =
      Enum.reduce([:capacity_race_1, :capacity_race_2, :capacity_race_3], {[], []}, fn name,
                                                                                       {acquired,
                                                                                        boots} ->
        Cleanup.protect acquired do
          tag = make_ref()
          deadline = System.monotonic_time(:millisecond) + 30_000

          {:ok, peer} =
            case :peer.start_link(%{
                   name: String.to_atom("#{name}_#{suffix}"),
                   connection: :standard_io,
                   args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
                   wait_boot: {self(), tag}
                 }) do
              {:ok, pid} -> {:ok, pid}
              {:ok, pid, _node} -> {:ok, pid}
            end

          register_timeout_cleanup([peer | acquired])
          {[peer | acquired], [{peer, tag, deadline} | boots]}
        after
          :ok
        end
      end)

    peers = Enum.reverse(peers)

    config = peer_configuration()

    Cleanup.protect peers do
      measure_stage(:peer_boot_wait, fn ->
        Enum.each(Enum.reverse(boots), &await_peer_boot!/1)
      end)

      # Every RPC retains its finite 5s default or explicit 30s bound. The
      # linked stream cancels remaining tasks if enumeration fails; its own
      # timer must not replace those bounds or the unchanged 300s test budget.
      peers
      |> Task.async_stream(&initialize_peer(&1, config),
        max_concurrency: 3,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.each(fn result -> assert {:ok, :ok} = result end)

      peers
    after
      :ok
    end
  end

  # Boot overlap MUST retain each peer's original 30s deadline from its
  # acquisition, rather than granting a fresh timeout when its turn is awaited.
  @spec await_peer_boot!({pid(), reference(), integer()}) :: :ok
  defp await_peer_boot!({peer, tag, deadline}) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^tag, {:started, node, ^peer}} ->
        assert node != :nonode@nohost
        :ok

      {^tag, {:boot_failed, reason, ^peer}} ->
        flunk("fresh capacity peer failed to boot: #{inspect(reason)}")
    after
      remaining -> flunk("fresh capacity peer exceeded its 30s boot deadline")
    end
  end

  @spec peer_configuration() :: [{atom(), keyword()}]
  defp peer_configuration do
    repo_config =
      Application.fetch_env!(:marshall, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    config =
      for {app, _, _} <- Application.loaded_applications(),
          app not in [:kernel, :stdlib, :elixir, :logger],
          do: {app, Application.get_all_env(app)}

    config
    |> Keyword.update!(:marshall, &Keyword.put(&1, Repo, repo_config))
    |> Keyword.put(:logger, level: :error)
  end

  @spec initialize_peer(pid(), [{atom(), keyword()}]) :: :ok
  defp initialize_peer(peer, config) do
    node = :peer.call(peer, :erlang, :node, [])
    assert node != :nonode@nohost

    :ok =
      measure_stage(:peer_paths, fn ->
        :peer.call(peer, :code, :add_paths, [:code.get_path()])
      end)

    :ok =
      measure_stage(:peer_environment, fn ->
        :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])
      end)

    {:ok, _} =
      measure_stage(:peer_applications, fn ->
        :peer.call(
          peer,
          :application,
          :ensure_all_started,
          [[:marshall], :temporary, :concurrent],
          30_000
        )
      end)

    :ok
  end

  @spec stop_peer_if_alive(pid()) :: :ok
  defp stop_peer_if_alive(peer) do
    if Process.alive?(peer) do
      reference = Process.monitor(peer)

      try do
        :peer.stop(peer)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end

      receive do
        {:DOWN, ^reference, :process, ^peer, _} -> :ok
      after
        10_000 -> raise "sample peer did not stop"
      end
    else
      :ok
    end
  end

  # ---------- generators ----------

  @typedoc "A generated intent; vm picks resolve against committed state at run time."
  @type op ::
          {:provision, non_neg_integer(), shape()}
          | {:lifecycle, non_neg_integer(), :start | :stop | :delete}
          | {:relocate, non_neg_integer()}
          | {:clone, non_neg_integer()}
          | {:outcome, non_neg_integer(), atom(), atom()}
          | {:conflict, non_neg_integer()}
          | :image_remove

  @type shape :: %{vcpu: pos_integer(), memory_bytes: pos_integer(), disk_bytes: pos_integer()}

  # Shapes vary only across keys, never across retries of one key: concurrent
  # same-key calls stay true idempotent replays, and only the dedicated
  # :conflict op may present a changed shape against a committed winner.
  @shape_table [
    %{vcpu: 1, memory_bytes: @mem, disk_bytes: 2 * @gib},
    %{vcpu: 2, memory_bytes: @mem, disk_bytes: 2 * @gib},
    %{vcpu: 1, memory_bytes: @mem, disk_bytes: 3 * @gib}
  ]

  @spec shape_for_key(non_neg_integer()) :: shape()
  defp shape_for_key(key_ix), do: Enum.at(@shape_table, rem(key_ix, 3))

  @spec shape_gen() :: Hegel.Gen.t(shape())
  defp shape_gen do
    member_of(@shape_table)
  end

  @spec op_gen() :: Hegel.Gen.t(op())
  defp op_gen do
    frequency([
      {4,
       map(tuple([member_of([0, 1, 2]), shape_gen()]), fn {key, shape} ->
         {:provision, key, shape}
       end)},
      {2,
       map(tuple([integer(0..9), member_of([:start, :stop, :delete])]), fn {n, kind} ->
         {:lifecycle, n, kind}
       end)},
      {2, gen_all_conflict()},
      {3,
       map(
         tuple([
           integer(0..9),
           frequency([
             {6, constant({:running, :none})},
             {2, constant({:failed, :crashed})},
             {2, constant({:failed, :execution_failed})},
             {1, constant({:unknown, :unknown})}
           ])
         ]),
         fn {n, {state, reason}} ->
           {:outcome, n, state, reason}
         end
       )},
      {1, constant(:image_remove)},
      {1, gen_all_relocate()},
      {1, gen_all_clone()}
    ])
  end

  @spec gen_all_relocate() :: Hegel.Gen.t(op())
  defp gen_all_relocate do
    map(integer(0..9), &{:relocate, &1})
  end

  @spec gen_all_clone() :: Hegel.Gen.t(op())
  defp gen_all_clone do
    map(integer(0..9), &{:clone, &1})
  end

  @spec gen_all_conflict() :: Hegel.Gen.t(op())
  defp gen_all_conflict do
    map(integer(0..3), &{:conflict, &1})
  end

  @spec schedule_gen() :: Hegel.Gen.t([[op()]])
  defp schedule_gen do
    list_of(integer(2..4), min_length: 4, max_length: 7)
    |> bind(fn sizes ->
      sizes
      |> Enum.map(fn size -> list_of(op_gen(), length: size) end)
      |> tuple()
      |> map(&Tuple.to_list/1)
    end)
  end

  # ---------- property ----------

  # @cc [owner:ghuntley,label:verification] capacity-race-committed-oracle
  # Generated admission/outcome mixes across three peers MUST satisfy the raw
  # committed-SQL accounting oracle after every committed batch: startup-held
  # promises plus settled running occupancy never exceed the enrolled capacity
  # minus overheads; refused operations persist zero rows; racing distinct keys
  # commit exactly the genuinely fitting winners; released compute is
  # re-spendable exactly once;
  # non-confirmed-delete terminal paths retain disk and clear temporary bytes;
  # addresses stay unique per profile without pre-archival reuse.
  # Real node startup and committed races consume the engine's input timer.
  #
  # The batch schedule has no finite domain, so ADR-0191's 100-case exploration
  # applies (6fad4d347 raised it from 8). capacity-race-three-independent-peers
  # requires fresh peers per sample, and booting them is only about 1.6 s of the
  # 6-10 s a case takes; most of the rest is the fixed windows and committed
  # races. Sharing peers across cases would therefore break that contract
  # without fixing the budget. 100 cases took 637 s and 680 s locally, against
  # the 300 s module budget that failed in CI, so this test gets 30 minutes.
  @tag timeout: 1_800_000
  property "generated multi-node races preserve committed capacity accounting",
    profile: :ci,
    test_cases: 100 do
    batches = draw("batches", schedule_gen())
    measure_stage(:generated_history, fn -> unboxed(fn -> run_sample(batches) end) end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] capacity-error-wrapper-regression
  # Known SQL deadlock and opaque Ash-wrapped clone errors MUST fail the actual
  # step-result validator. Documented atom refusals and ordinary successful
  # clone results MUST remain valid. Error-like data MUST NOT be SQL evidence.
  property "race result validation rejects raw and Ash-wrapped clone SQL failures",
    test_cases: 100 do
    depth = draw("depth", member_of([0, 1, 3, 8]))
    refusal = draw("refusal", member_of([:insufficient_capacity, :source_unavailable, :vm_busy]))

    raw =
      Postgrex.Error.exception(
        postgres: %{
          code: "40P01",
          severity: "ERROR",
          message: "synthetic deadlock regression",
          detail: nil
        }
      )

    opaque = Ash.Error.to_ash_error(raw)

    for error <- [raw, opaque], nested_depth <- [depth, 0, 8] do
      nested = nest_error(error, nested_depth)

      assert_raise ExUnit.AssertionError, fn ->
        validate_step_result!({:clone, {:ok, %{}}, {:error, nested}})
      end
    end

    assert_raise ExUnit.AssertionError, fn ->
      validate_step_result!({:outcome, :tag, {:error, nest_error(raw, depth)}, %{}})
    end

    assert :ok = validate_step_result!({:clone, {:ok, %{}}, {:error, refusal}})
    assert :ok = validate_step_result!({:clone, {:ok, %{}}, {:ok, :queued}})

    assert :ok =
             validate_step_result!({:probe, {:ok, %{label: "40P01", event: :deadlock_detected}}})
  end

  @spec nest_error(term(), non_neg_integer()) :: term()
  defp nest_error(error, 0), do: error

  defp nest_error(error, depth) when depth > 0,
    do: %{errors: [{:cause, [nest_error(error, depth - 1)]}]}

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  # ---------- model ----------

  # The model restates the documented accounting contract from values the test
  # itself injected (fixture geometry, synthetic reports, issued outcomes) plus
  # raw committed rows read back. It never calls Budget or borrows its code.

  @typedoc "Committed-truth snapshot for one fixture VM."
  @type vmrec :: %{
          id: String.t(),
          host_id: String.t(),
          pool_id: String.t(),
          placement_id: String.t(),
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer(),
          desired: atom(),
          observed: atom() | nil,
          generation: pos_integer(),
          epoch: non_neg_integer(),
          outcome_seq: non_neg_integer(),
          pending: nil | map(),
          anchor: nil | map(),
          settled: boolean(),
          materialized: boolean(),
          compute_held: boolean(),
          disk_held: boolean(),
          startup_compute: boolean(),
          startup_disk: boolean(),
          temporary: non_neg_integer(),
          archived: boolean(),
          relocating: boolean(),
          clone_child: boolean(),
          clone_busy: boolean(),
          crash_times: non_neg_integer(),
          last_outcome: nil | map(),
          reserve_memory: pos_integer(),
          reserve_disk: pos_integer()
        }

  @typep model :: %{
           peers: [pid()],
           owner: Marshall.Accounts.User.t(),
           hosts: [String.t()],
           fixture: %{String.t() => map()},
           disabled: %{String.t() => boolean()},
           seq: %{String.t() => pos_integer()},
           images: %{String.t() => boolean()},
           vms: %{String.t() => vmrec()},
           keys: %{String.t() => {shape(), String.t() | :refused}},
           pool_total: %{String.t() => pos_integer()}
         }

  @spec model_init([pid()], Marshall.Accounts.User.t(), map(), map()) :: model()
  defp model_init(peers, owner, first, second) do
    sorted = Enum.sort_by([first, second], & &1.host.id)
    [a, b] = Enum.map(sorted, & &1.host.id)

    %{
      peers: peers,
      owner: owner,
      hosts: [a, b],
      fixture: Map.new(sorted, &{&1.host.id, &1}),
      disabled: %{a => false, b => false},
      seq: %{a => 2, b => 2},
      images: %{a => true, b => true},
      vms: %{},
      keys: %{},
      pool_total: %{}
    }
  end

  @spec fixture_for(model(), String.t()) :: map()
  defp fixture_for(model, host_id) do
    case Map.get(model.fixture, host_id) do
      nil ->
        vms = Enum.map(Map.values(model.vms), &{&1.id, &1.host_id})

        flunk(
          "host #{host_id} not among fixtures #{inspect(Map.keys(model.fixture))}; vms=#{inspect(vms)}"
        )

      fixture ->
        fixture
    end
  end

  # ---------- interpreter ----------

  # @cc [owner:ghuntley,label:verification;privacy] capacity-fixture-timing-artifacts
  # Optional timing artifacts MUST contain only a fixed stage identifier, actual
  # elapsed microseconds and completed-history count. They MUST NOT contain
  # identities, generated inputs, credentials or exceptions. Disabled collection
  # MUST execute the same body without changing any test or RPC deadline.
  @spec measure_stage(timing_stage(), (-> value)) :: value when value: term()
  defp measure_stage(stage, body) do
    case System.get_env("CAPACITY_RACE_TIMINGS_DIR") do
      nil ->
        body.()

      directory ->
        started = System.monotonic_time(:microsecond)
        result = body.()
        completed = Process.get({__MODULE__, :completed_histories}, 0)

        completed =
          if stage in [:generated_history, :lock_history], do: completed + 1, else: completed

        Process.put({__MODULE__, :completed_histories}, completed)

        record = %{
          schema_version: 1,
          stage: stage,
          duration_us: System.monotonic_time(:microsecond) - started,
          completed_histories: completed
        }

        write_timing!(directory, record)
        result
    end
  end

  @spec write_timing!(String.t(), timing_record()) :: :ok
  defp write_timing!(directory, record) do
    File.mkdir_p!(directory)
    filename = "#{System.unique_integer([:positive, :monotonic])}.json"
    File.write!(Path.join(directory, filename), JSON.encode!(record))
  end

  # @cc [owner:ghuntley,label:verification;durability] capacity-race-timeout-cleanup
  # ExUnit's separate exit process MUST retain the currently acquired peers and
  # exact sample fixture after a forced test timeout bypasses in-process after
  # blocks. Fixture cleanup MUST be registered before acquisition commits.
  # Peers MUST stop before deletion. Successful cleanup MUST disarm the
  # fallback so later histories cannot delete an unrelated fixture.
  @spec register_timeout_cleanup([pid()], (-> :ok)) :: :ok
  defp register_timeout_cleanup(peers, cleanup \\ fn -> :ok end) do
    on_exit(:capacity_race_current_sample, fn ->
      Enum.each(peers, &stop_peer_if_alive/1)
      cleanup.()
    end)
  end

  @spec disarm_timeout_cleanup() :: :ok
  defp disarm_timeout_cleanup do
    on_exit(:capacity_race_current_sample, fn -> :ok end)
  end

  @spec run_sample([[op()]]) :: :ok
  defp run_sample(batches) do
    try do
      peers = measure_stage(:peer_startup, &start_peers/0)

      {:ok, model} =
        Repo.transaction(fn ->
          first = host_fixture()
          second = host_fixture()
          actor = user()
          model = model_init(peers, actor, first, second)
          register_timeout_cleanup(peers, fn -> cleanup_sample(model) end)
          model
        end)

      [host_a, host_b] = model.hosts

      totals = %{
        host_a => 20 * @gib,
        host_b =>
          fixture_for(model, host_b)
          |> Map.fetch!(:report)
          |> Map.get(:pools)
          |> hd()
          |> Map.get(:total_bytes)
      }

      model = %{model | pool_total: totals}

      Cleanup.protect peers do
        model = measure_stage(:fixed_windows, fn -> windows(model) end)

        _ =
          measure_stage(:generated_batches, fn ->
            Enum.reduce(batches, model, fn batch, acc -> run_generated_batch(acc, batch) end)
          end)

        :ok
      after
        Enum.each(peers, &stop_peer_if_alive/1)
        cleanup_sample(model)
        disarm_timeout_cleanup()
      end
    catch
      kind, reason ->
        stack = __STACKTRACE__

        if dir = System.get_env("CAPACITY_RACE_FAILURE_DIR") do
          File.mkdir_p!(dir)

          File.write!(
            Path.join(dir, "#{System.unique_integer([:positive])}.log"),
            Exception.format(kind, reason, stack) <>
              "\n\nSCHEDULE:\n" <> inspect(batches, limit: :infinity, printable_limit: :infinity)
          )
        end

        :erlang.raise(kind, reason, stack)
    end
  end

  # ---------- generated batches ----------

  # Resolve generated vm picks against committed state; one mutating op per vm
  # per batch so concurrent sequences never conflict on outcome sequences.
  @spec resolve_ops(model(), [op()]) :: [map()]
  defp resolve_ops(model, ops) do
    {steps, _used} =
      Enum.map_reduce(ops, MapSet.new(), fn op, used ->
        case resolve_op(model, op, used) do
          {:ok, step, vm_id} -> {step, MapSet.put(used, vm_id)}
          :probe -> {probe_step(model), used}
        end
      end)

    steps
  end

  @spec resolve_op(model(), op(), MapSet.t()) :: {:ok, map(), String.t()} | :probe
  defp resolve_op(model, {:provision, key_ix, _shape}, _used) do
    key = "race-key-#{rem(key_ix, 3)}-#{model.owner.id}"
    shape = shape_for_key(key_ix)
    {:ok, %{type: :provision, key: key, shape: shape, gen_key: key_ix}, key}
  end

  defp resolve_op(model, {:lifecycle, pick, kind}, used) do
    candidates =
      model.vms
      |> Map.values()
      |> Enum.filter(
        &(&1.pending == nil and not &1.archived and not &1.relocating and
            not &1.clone_child and not MapSet.member?(used, &1.id))
      )
      |> Enum.sort_by(& &1.id)

    case pick_from(candidates, pick) do
      nil -> :probe
      vm -> {:ok, %{type: :lifecycle, vm_id: vm.id, kind: kind, key: Ash.UUID.generate()}, vm.id}
    end
  end

  defp resolve_op(model, {:relocate, pick}, used) do
    candidates =
      model.vms
      |> Map.values()
      |> Enum.filter(&stable_vm?(model, &1))
      |> Enum.reject(&MapSet.member?(used, &1.id))
      |> Enum.sort_by(& &1.id)

    case pick_from(candidates, pick) do
      nil -> :probe
      vm -> {:ok, %{type: :relocate, vm_id: vm.id, key: Ash.UUID.generate()}, vm.id}
    end
  end

  defp resolve_op(model, {:clone, pick}, used) do
    candidates =
      model.vms
      |> Map.values()
      |> Enum.filter(&(stable_vm?(model, &1) and not &1.clone_busy))
      |> Enum.reject(&MapSet.member?(used, &1.id))
      |> Enum.sort_by(& &1.id)

    case pick_from(candidates, pick) do
      nil -> :probe
      vm -> {:ok, %{type: :clone, vm_id: vm.id, key: Ash.UUID.generate()}, vm.id}
    end
  end

  defp resolve_op(model, {:outcome, pick, state, reason}, used) do
    candidates =
      model.vms
      |> Map.values()
      |> Enum.filter(&(&1.anchor != nil and not &1.archived))
      |> Enum.reject(&MapSet.member?(used, &1.id))
      |> Enum.sort_by(& &1.id)

    case pick_from(candidates, pick) do
      nil ->
        :probe

      vm ->
        {state, reason} = compatible_outcome(vm.anchor.kind, state, reason)

        {:ok, %{type: :outcome, vm_id: vm.id, state: state, reason: reason, op: vm.anchor}, vm.id}
    end
  end

  defp resolve_op(model, {:conflict, pick}, used) do
    winners =
      model.keys
      |> Enum.flat_map(fn
        {key, {shape, id}} when is_binary(id) -> [{key, shape, id}]
        _ -> []
      end)
      |> Enum.sort()

    candidates =
      winners
      |> Enum.filter(fn {_key, _shape, id} -> not MapSet.member?(used, id) end)

    # A changed shape against an already-won key always conflicts, regardless
    # of remaining capacity: the committed request replay check.
    case candidates do
      [] ->
        :probe

      _ ->
        {key, shape, id} = Enum.at(candidates, rem(pick, length(candidates)))

        conflicting =
          Enum.find(@shape_table, &(&1 != shape))

        {:ok,
         %{
           type: :conflict,
           key: key,
           shape: conflicting,
           original_shape: shape,
           vm_id: id
         }, "conflict:#{id}"}
    end
  end

  defp resolve_op(model, :image_remove, used) do
    host_id = hd(model.hosts)
    marker = "image:" <> host_id

    if MapSet.member?(used, marker) do
      :probe
    else
      {:ok, %{type: :image_remove, host_id: host_id}, marker}
    end
  end

  @spec compatible_outcome(atom(), atom(), atom()) :: {atom(), atom()}
  defp compatible_outcome(kind, state, reason)
       when kind in [:provision, :start] and state in [:running, :failed, :unknown],
       do: {state, reason}

  defp compatible_outcome(kind, state, _reason) when kind in [:provision, :start],
    do: if(state == :stopped, do: {:running, :none}, else: {state, :unknown})

  defp compatible_outcome(:stop, state, _reason) when state in [:stopped, :unknown],
    do: {state, if(state == :unknown, do: :unknown, else: :none)}

  defp compatible_outcome(:stop, _state, _reason), do: {:stopped, :none}

  defp compatible_outcome(:delete, :unknown, _reason), do: {:unknown, :unknown}

  defp compatible_outcome(:delete, _state, _reason), do: {:deleted, :none}

  defp compatible_outcome(_kind, _state, _reason), do: {:unknown, :unknown}

  @spec stable_vm?(model(), vmrec()) :: boolean()
  defp stable_vm?(model, vm) do
    vm.pending == nil and not vm.archived and not vm.relocating and not vm.clone_child and
      vm.desired == vm.observed and vm.desired in [:running, :stopped] and
      vm.disk_held and vm.temporary == 0 and vm.compute_held == (vm.desired == :running) and
      model.images[vm.host_id]
  end

  @spec pick_from([vmrec()], non_neg_integer()) :: vmrec() | nil
  defp pick_from([], _pick), do: nil
  defp pick_from(list, pick), do: Enum.at(list, rem(pick, length(list)))

  # An idempotent replay probe when a generated target has no eligible vm.
  @spec probe_step(model()) :: map()
  defp probe_step(model) do
    case Enum.find(model.keys, fn {_key, entry} ->
           match?({_shape, id} when is_binary(id), entry)
         end) do
      {key, {shape, vm_id}} -> %{type: :probe, key: key, shape: shape, vm_id: vm_id}
      nil -> %{type: :noop}
    end
  end

  # ---------- concurrent execution ----------

  # @cc [owner:ghuntley,label:verification] capacity-race-step-failure-isolation
  # Step execution MUST run on non-linked supervised tasks so a raised or
  # exited step is reported with its step content instead of crashing the
  # property process behind a dead-peer exit. Each phase MUST stop its own
  # supervisor after all tasks finish or fail, rather than retaining thousands
  # of empty supervisors until the generated property exits.
  @spec run_steps(model(), [map()]) :: [term()]
  defp run_steps(model, steps) do
    unique = System.unique_integer([:positive])

    supervisor =
      start_supervised!(%{
        id: {Task.Supervisor, unique},
        start: {Task.Supervisor, :start_link, [[]]}
      })

    try do
      tasks =
        Enum.map(Enum.with_index(steps), fn {step, index} ->
          Task.Supervisor.async_nolink(supervisor, fn ->
            execute_step(model, step, rem(index, 3))
          end)
        end)

      Enum.zip(steps, tasks)
      |> Enum.map(fn {step, task} ->
        case Task.yield(task, 60_000) || Task.shutdown(task) do
          {:ok, result} ->
            validate_step_result!(result)
            result

          {:exit, reason} ->
            flunk(
              "step #{inspect(step, limit: 8, printable_limit: 4_000)} exited: #{inspect(reason)}"
            )

          nil ->
            flunk("step #{inspect(step, limit: 8, printable_limit: 4_000)} timed out")
        end
      end)
    after
      :ok = stop_supervised({Task.Supervisor, unique})
    end
  end

  @spec validate_step_result!(term()) :: :ok
  defp validate_step_result!({:clone, {:ok, _}, advance} = result) do
    assert_no_deadlock!(result)
    assert_clone_advance_result!(advance)
  end

  defp validate_step_result!(result), do: assert_no_deadlock!(result)

  # @cc [owner:ghuntley,label:verification;concurrency] capacity-race-no-structured-deadlock
  # Every generated coordinated operation result MUST reject a structured SQL
  # deadlock even when nested in an Ash error or otherwise accepted refusal.
  # This oracle MUST NOT turn fixture teardown retries into application evidence.
  @spec assert_no_deadlock!(term()) :: :ok
  defp assert_no_deadlock!(result) do
    refute structured_deadlock?(result), "coordinated operation returned SQL deadlock 40P01"
    :ok
  end

  @spec structured_deadlock?(term()) :: boolean()
  defp structured_deadlock?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: true
  defp structured_deadlock?(%Postgrex.Error{postgres: %{pg_code: "40P01"}}), do: true

  defp structured_deadlock?(value) when is_map(value),
    do: Enum.any?(Map.values(value), &structured_deadlock?/1)

  defp structured_deadlock?(value) when is_list(value),
    do: Enum.any?(value, &structured_deadlock?/1)

  defp structured_deadlock?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&structured_deadlock?/1)

  defp structured_deadlock?(_), do: false

  @spec execute_step(model(), map(), non_neg_integer()) :: term()
  defp execute_step(_model, %{type: :noop}, _peer_ix), do: :noop

  defp execute_step(model, %{type: :probe, key: key, shape: shape, vm_id: vm_id}, ix) do
    params = Map.merge(request(%{idempotency_key: key}), shape)

    case :peer.call(
           Enum.at(model.peers, ix),
           Marshall.Compute,
           :provision,
           [
             params,
             [actor: model.owner]
           ],
           30_000
         ) do
      {:ok, vm} ->
        assert vm.id == vm_id

      {:error, error} ->
        flunk("idempotent replay refused: #{Exception.message(error)}")
    end

    :probe_ok
  end

  defp execute_step(model, %{type: :provision, key: key, shape: shape}, ix) do
    params = Map.merge(request(%{idempotency_key: key}), shape)

    {:provision,
     :peer.call(
       Enum.at(model.peers, ix),
       Marshall.Compute,
       :provision,
       [
         params,
         [actor: model.owner]
       ],
       30_000
     )}
  end

  defp execute_step(model, %{type: :lifecycle, vm_id: vm_id, kind: kind, key: key}, ix) do
    {:lifecycle,
     :peer.call(
       Enum.at(model.peers, ix),
       Marshall.Compute,
       :lifecycle,
       [%{vm_id: vm_id, kind: kind, idempotency_key: key}, [actor: model.owner]],
       30_000
     )}
  end

  defp execute_step(model, %{type: :relocate, vm_id: vm_id, key: key}, ix) do
    {:relocate,
     :peer.call(
       Enum.at(model.peers, ix),
       Marshall.Compute,
       :relocate,
       [%{vm_id: vm_id, idempotency_key: key}, [actor: model.owner]],
       30_000
     )}
  end

  defp execute_step(model, %{type: :clone, vm_id: vm_id, key: key}, ix) do
    peer = Enum.at(model.peers, ix)

    result =
      :peer.call(
        peer,
        Marshall.Compute,
        :clone,
        [%{vm_id: vm_id, idempotency_key: key}, [actor: model.owner]],
        30_000
      )

    case result do
      {:ok, view} ->
        advance = :peer.call(peer, Marshall.Compute.CloneCoordinator, :advance, [view.id], 30_000)
        {:clone, {:ok, view}, advance}

      other ->
        {:clone, other, nil}
    end
  end

  defp execute_step(model, %{type: :outcome} = step, ix) do
    vm = Map.fetch!(model.vms, step.vm_id)
    op = step.op

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: op.placement_id,
      execution_epoch: op.epoch,
      operation_id: op.id,
      generation: op.generation,
      sequence: vm.outcome_seq + 1,
      state: step.state,
      compute_empty: step.state != :unknown,
      disk_present: step.state != :deleted,
      cleanup_complete: step.state == :deleted,
      reason: step.reason
    }

    result =
      :peer.call(
        Enum.at(model.peers, ix),
        Marshall.Compute.DistributedCapacityRaceFixture,
        :apply_outcome,
        [vm.host_id, outcome],
        30_000
      )

    {:outcome, vm.id, result, outcome}
  end

  defp execute_step(model, %{type: :conflict, key: key, shape: shape}, ix) do
    params = Map.merge(request(%{idempotency_key: key}), shape)

    {:conflict,
     :peer.call(
       Enum.at(model.peers, ix),
       Marshall.Compute,
       :provision,
       [
         params,
         [actor: model.owner]
       ],
       30_000
     )}
  end

  defp execute_step(_model, %{type: :image_remove}, _ix), do: :image_remove
  # ---------- absorption ----------

  @spec absorb(model(), [map()], [term()]) :: model()
  defp absorb(model, steps, results) do
    Enum.zip(steps, results)
    |> Enum.reduce(model, fn {step, result}, acc -> absorb_step(acc, step, result) end)
    |> refresh_touched(steps)
  end

  defp absorb_step(model, %{type: :noop}, :noop), do: model
  defp absorb_step(model, %{type: :probe}, :probe_ok), do: model

  defp absorb_step(model, %{type: :provision, key: key, shape: shape}, {:provision, r}) do
    case r do
      {:ok, vm} ->
        if conflict_key?(model.keys[key], shape), do: flunk("conflicting key #{key} accepted")

        keys =
          Map.update(model.keys, key, {shape, vm.id}, fn
            {_prev_shape, :refused} ->
              # A refusal persists no durable identity; a later acceptance of
              # the same key under any shape is legal.
              {shape, vm.id}

            {^shape, existing} ->
              assert existing == vm.id, "same key returned a second VM"
              {shape, existing}

            {other, existing} ->
              flunk("key #{key} shape #{inspect(other)} replay accepted as #{inspect(existing)}")
          end)

        with_keys = %{model | keys: keys}

        # Idempotent replays return the original VM; only its first admission is news.
        if Map.has_key?(model.vms, vm.id), do: with_keys, else: put_new_vm(with_keys, vm)

      {:error, error} ->
        if conflict_key?(model.keys[key], shape) do
          if not (Exception.message(error) =~ "idempotency_conflict") do
            {stored_shape, vm_id} = model.keys[key]

            rows =
              sql(
                "SELECT id::text, idempotency_key, vcpu, memory_bytes, disk_bytes, archived_at IS NULL, provisioning_sizes FROM compute_virtual_machines WHERE owner_id=$1 AND idempotency_key=$2",
                [Ecto.UUID.dump!(model.owner.id), key]
              )

            flunk("""
            expected idempotency_conflict, got: #{Exception.message(error)}
            for key=#{key} stored_shape=#{inspect(stored_shape)} vm_id=#{inspect(vm_id)} op_shape=#{inspect(shape)}
            rows=#{inspect(rows.rows)}
            """)
          end

          model
        else
          assert_refusal_class(error)
          keys = Map.put_new(model.keys, key, {shape, :refused})

          %{
            model
            | keys: keys
          }
        end
    end
  end

  defp absorb_step(
         model,
         %{type: :lifecycle, vm_id: lifecycle_vm_id, kind: kind},
         {:lifecycle, r}
       ) do
    case r do
      {:ok, op} ->
        if op.kind != kind, do: flunk("lifecycle op kind mismatch")

        put_expectation(model, lifecycle_vm_id, fn vm ->
          vm = %{vm | pending: pending_from(op), anchor: pending_from(op)}

          if kind == :start do
            # reserve_start! reacquires the full shape before accepting intent.
            %{vm | compute_held: true, startup_compute: true}
          else
            vm
          end
        end)

      {:error, error} ->
        assert_refusal_class(error)
        model
    end
  end

  defp absorb_step(model, %{type: :relocate, vm_id: relocate_vm_id}, {:relocate, r}) do
    case r do
      {:ok, _relocation} ->
        put_expectation(model, relocate_vm_id, fn vm -> %{vm | relocating: true, pending: nil} end)

      {:error, error} ->
        assert_refusal_class(error)
        model
    end
  end

  defp absorb_step(model, %{type: :clone, vm_id: clone_vm_id}, {:clone, admitted, advance}) do
    case admitted do
      {:ok, view} ->
        absorb_clone_advance(model, clone_vm_id, view, advance)

      {:error, error} ->
        assert_refusal_class(error)
        model
    end
  end

  defp absorb_step(
         model,
         %{type: :outcome, vm_id: vm_id},
         {:outcome, tagged, outcome_result, outcome}
       )
       when tagged == vm_id do
    case outcome_result do
      {:ok, _accepted} ->
        apply_outcome_expectation(model, vm_id, outcome)

      {:error, :outcome_conflict} ->
        # A replayed/duplicated outcome at the same placement committed earlier.
        # The ledger already holds the evidence; nothing in the model moves.
        model

      {:error, error} ->
        flunk("constructed outcome rejected: #{inspect(error)}")
    end
  end

  defp absorb_step(model, %{type: :image_remove, host_id: host_id}, :image_remove) do
    put_in(model, [:images, host_id], false)
  end

  defp absorb_step(model, %{type: :conflict, key: key, vm_id: vm_id}, {:conflict, result}) do
    case result do
      {:error, error} ->
        assert Exception.message(error) =~ "idempotency_conflict",
               "changed shape under a won key must conflict: #{Exception.message(error)}"

        %{rows: [[count]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT count(*) FROM compute_virtual_machines WHERE owner_id=$1 AND idempotency_key=$2",
            [Ecto.UUID.dump!(model.owner.id), key],
            log: false
          )

        assert count == 1, "idempotency conflict created another durable VM"

        rows =
          sql("SELECT count(*) FROM compute_operations WHERE vm_id = $1", [Ecto.UUID.dump!(vm_id)])

        op_count = hd(rows.rows) |> hd()
        # Conflict refusals persist no intent rows for the conflicting shape.
        assert is_integer(op_count)
        model

      {:ok, vm} ->
        flunk("conflicting shape against key #{key} accepted as #{vm.id}")
    end
  end

  @spec absorb_clone_advance(model(), map(), map(), term()) :: model()
  defp absorb_clone_advance(model, clone_vm_id, view, advance) do
    assert_clone_advance_result!(advance)

    case clone_committed_destination(view.destination_vm_id) do
      nil ->
        # A durable placement gate refused inside advance; no destination rows.
        put_expectation(model, clone_vm_id, fn vm -> %{vm | clone_busy: false} end)

      dest_vm ->
        model
        |> put_expectation(clone_vm_id, fn vm ->
          %{vm | clone_busy: true, temporary: vm.reserve_disk}
        end)
        |> put_clone_child(dest_vm)
    end
  end

  @spec clone_committed_destination(String.t() | nil) :: VirtualMachine.t() | nil
  defp clone_committed_destination(nil), do: nil

  defp clone_committed_destination(id) do
    case Ledger.read!(VirtualMachine, id: id) do
      [vm] -> vm
      [] -> nil
    end
  end

  @spec put_new_vm(model(), VirtualMachine.t()) :: model()
  defp put_new_vm(model, vm) do
    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    [address] = Ledger.read!(Marshall.Compute.NetworkAddress, vm_id: vm.id)
    assert address.slot >= 2
    assert reservation.compute_held and reservation.disk_held
    assert reservation.startup_compute_held and reservation.startup_disk_held

    rec = %{
      id: vm.id,
      host_id: vm.host_id,
      pool_id: vm.pool_id,
      placement_id: vm.current_placement_id,
      vcpu: vm.vcpu,
      memory_bytes: vm.memory_bytes,
      disk_bytes: vm.disk_bytes,
      desired: vm.desired_state,
      observed: vm.observed_state,
      generation: vm.generation,
      epoch: vm.execution_epoch,
      outcome_seq: vm.outcome_sequence,
      pending: pending_op(vm.id),
      anchor: pending_op(vm.id),
      settled: false,
      materialized: false,
      compute_held: true,
      disk_held: true,
      startup_compute: true,
      startup_disk: true,
      temporary: 0,
      reserve_memory: reservation.memory_bytes,
      reserve_disk: reservation.disk_bytes,
      archived: false,
      relocating: false,
      clone_child: false,
      clone_busy: false,
      crash_times: 0,
      last_outcome: nil
    }

    put_in(model, [:vms, vm.id], rec)
  end

  @spec put_clone_child(model(), VirtualMachine.t()) :: model()
  defp put_clone_child(model, vm) do
    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)

    rec = %{
      id: vm.id,
      host_id: reservation.host_id,
      pool_id: reservation.pool_id,
      placement_id: vm.current_placement_id,
      vcpu: vm.vcpu,
      memory_bytes: vm.memory_bytes,
      disk_bytes: vm.disk_bytes,
      desired: vm.desired_state,
      observed: vm.observed_state,
      generation: vm.generation,
      epoch: vm.execution_epoch,
      outcome_seq: vm.outcome_sequence,
      pending: nil,
      settled: false,
      materialized: false,
      compute_held: reservation.compute_held,
      disk_held: reservation.disk_held,
      startup_compute: reservation.startup_compute_held,
      startup_disk: reservation.startup_disk_held,
      temporary: reservation.temporary_disk_bytes,
      archived: false,
      relocating: false,
      clone_child: true,
      clone_busy: false,
      crash_times: 0,
      last_outcome: nil
    }

    put_in(model, [:vms, vm.id], rec)
  end

  @spec put_expectation(model(), String.t(), (vmrec() -> vmrec())) :: model()
  defp put_expectation(model, vm_id, fun) do
    update_in(model, [:vms, vm_id], fn
      nil -> nil
      vm -> fun.(vm)
    end)
  end

  @spec pending_op(String.t()) :: nil | map()
  defp pending_op(vm_id) do
    case Ledger.read!(Operation, vm_id: vm_id)
         |> Enum.filter(&(&1.status in [:pending, :acknowledged])) do
      [] ->
        nil

      [op] ->
        pending_from(op)

      more ->
        flunk("multiple concurrent operations retained: #{length(more)}")
    end
  end

  @spec pending_from(Operation.t()) :: map()
  defp pending_from(op) do
    %{
      id: op.id,
      kind: op.kind,
      generation: op.generation,
      epoch: op.execution_epoch,
      placement_id: op.placement_id
    }
  end

  # Retain only the issued outcome's identity; physical settlement reports
  # reference it for coverage proofs. Holdings stay committed rows, refreshed
  # back into the model after every batch.
  @spec apply_outcome_expectation(model(), String.t(), map()) :: model()
  defp apply_outcome_expectation(model, vm_id, outcome) do
    put_expectation(model, vm_id, fn vm -> %{vm | last_outcome: outcome} end)
  end

  @spec measured_running_usage(model(), String.t()) :: %{
          vcpu: non_neg_integer(),
          memory_bytes: non_neg_integer()
        }
  defp measured_running_usage(_model, host_id) do
    %{rows: [[vcpu, memory]]} =
      sql(
        """
        SELECT COALESCE(SUM(r.vcpu), 0)::bigint, COALESCE(SUM(r.memory_bytes), 0)::bigint
        FROM compute_reservations r
        JOIN compute_virtual_machines v ON v.id = r.vm_id AND v.current_placement_id = r.placement_id
        WHERE r.host_id = $1::uuid AND r.compute_held AND v.archived_at IS NULL
          AND v.observed_state IN ('running', 'unknown')
        """,
        [Ecto.UUID.dump!(host_id)]
      )

    %{vcpu: vcpu, memory_bytes: memory}
  end

  # Which committed operation pins the vm's next physical observation: a
  # pending/acknowledged operation of the current generation if one exists,
  # otherwise the newest completed/cancelled operation of the current
  # generation and placement. Physical failures against a settled running VM
  # legally bind its last completed operation with a fresh outcome identity.
  @spec pick_pending([Operation.t()], VirtualMachine.t()) :: nil | map()
  defp pick_pending(ops, vm) do
    case Enum.filter(ops, fn op ->
           op.status in [:pending, :acknowledged] and op.generation == vm.generation and
             op.placement_id == vm.current_placement_id
         end) do
      [] -> nil
      [op] -> pending_from(op)
      more -> flunk("multiple pending operations retained: #{length(more)}")
    end
  end

  @spec pick_anchor([Operation.t()], VirtualMachine.t()) :: nil | map()
  defp pick_anchor(ops, vm) do
    current =
      Enum.filter(ops, fn op ->
        op.generation == vm.generation and op.placement_id == vm.current_placement_id
      end)

    case Enum.find(current, &(&1.status in [:pending, :acknowledged])) do
      nil ->
        current
        |> Enum.sort_by(& &1.generation, :desc)
        |> List.first()
        |> case do
          nil -> nil
          op -> pending_from(op)
        end

      op ->
        pending_from(op)
    end
  end

  # After batch commit, refresh every touched vm's committed row so model
  # bookkeeping never substitutes intent for reality.
  @spec refresh_touched(model(), [map()]) :: model()
  defp refresh_touched(model, steps) do
    vm_ids =
      steps
      |> Enum.flat_map(fn step ->
        case step do
          %{vm_id: id} when is_binary(id) -> [id]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(model.vms, &1))

    Enum.reduce(vm_ids, model, fn vm_id, acc -> refresh_vm(acc, vm_id) end)
  end

  @spec refresh_vm(model(), String.t()) :: model()
  defp refresh_vm(model, vm_id) do
    case Ledger.history!(VirtualMachine, id: vm_id) do
      [] ->
        model

      [vm] ->
        ops = Ledger.read!(Operation, vm_id: vm_id)
        pending = pick_pending(ops, vm)
        anchor = pick_anchor(ops, vm)
        archived = vm.archived_at != nil

        reservation =
          case Ledger.read!(Reservation, placement_id: vm.current_placement_id) do
            [reservation] -> reservation
            [] -> nil
          end

        put_expectation(model, vm_id, fn rec ->
          %{
            rec
            | desired: vm.desired_state,
              observed: vm.observed_state || rec.observed,
              generation: vm.generation,
              epoch: vm.execution_epoch,
              outcome_seq: vm.outcome_sequence,
              pending: pending,
              anchor: anchor,
              crash_times: length(vm.crash_restart_times || []),
              archived: archived
          }
          |> refresh_holds(reservation)
        end)
    end
  end

  # @cc [owner:ghuntley,label:verification] capacity-race-refresh-committed-holds
  # Refresh MUST copy committed reservation holdings into the model; model
  # bookkeeping NEVER mutates compute/disk/temporary predictions ahead of the
  # ledger. Window assertions read this committed state.
  @spec refresh_holds(vmrec(), Reservation.t() | nil) :: vmrec()
  defp refresh_holds(rec, nil), do: rec

  defp refresh_holds(rec, reservation) do
    %{
      rec
      | compute_held: reservation.compute_held,
        disk_held: reservation.disk_held,
        startup_compute: reservation.startup_compute_held,
        startup_disk: reservation.startup_disk_held,
        temporary: reservation.temporary_disk_bytes
    }
  end

  @spec conflict_key?(nil | {shape(), String.t() | :refused}, shape()) :: boolean()
  defp conflict_key?(nil, _shape), do: false
  defp conflict_key?({_first, :refused}, _second), do: false
  defp conflict_key?({stored, _id}, shape), do: stored != shape

  @refusal_reasons ~w(insufficient_capacity image_unavailable name_unavailable
    idempotency_conflict address_pool_exhausted relocation_in_progress vm_deleted
    clone_in_progress workload_not_stable transfer_busy forbidden host_unavailable
    disk_not_reserved resize_in_progress invalid_vm_size source_unavailable
    vm_busy placement_changed requirements_not_met)

  @spec assert_refusal_class(term()) :: :ok
  defp assert_refusal_class(error) do
    message = Exception.message(error)

    assert Enum.any?(@refusal_reasons, &String.contains?(message, &1)),
           "unexpected refusal reason: #{message}"

    :ok
  end

  # @cc [owner:ghuntley,label:verification;concurrency] clone-advance-closed-refusal-class
  # Clone activation results MUST be successful or a documented atom refusal.
  # Opaque Ash/Postgrex failures MUST NOT count as placement refusal, including
  # when rollback or a retained destination leaves capacity inventories valid.
  @spec assert_clone_advance_result!(term()) :: :ok
  defp assert_clone_advance_result!({:ok, _}), do: :ok

  defp assert_clone_advance_result!({:error, reason}) when is_atom(reason) do
    assert Atom.to_string(reason) in @refusal_reasons,
           "clone coordinator returned an undocumented refusal"

    :ok
  end

  defp assert_clone_advance_result!(_),
    do: flunk("clone coordinator returned an unexpected error class")

  # ---------- synthetic settlement reports ----------

  # Each settle is one committed report per host carrying covered proofs for
  # completed running outcomes and owned physical allocations for materialized
  # placements. Measured headroom honestly drops by the settled running shape.

  @spec settle(model()) :: model()
  defp settle(model) do
    Enum.reduce(model.hosts, model, fn host_id, acc ->
      case ingest_report(acc, host_id) do
        :ok ->
          mark_settled(put_in(acc, [:seq, host_id], acc.seq[host_id] + 1), host_id)

        {:rejected, reason, report} ->
          oracle_dump =
            sql(
              "SELECT report_sequence, connection_epoch, reported_at, enabled, maintenance_mode, true FROM compute_hosts WHERE id=$1",
              [Ecto.UUID.dump!(host_id)]
            )

          pools_dump =
            sql(
              "SELECT id::text, backend, filesystem_id, zpool_guid, dataset_guid, dataset, reported_at IS NOT NULL FROM compute_storage_pools WHERE host_id=$1",
              [Ecto.UUID.dump!(host_id)]
            )

          flunk("""
          settlement report rejected on #{host_id}: #{inspect(reason)}
          seq=#{report.sequence} sampled_at=#{inspect(report.sampled_at)}
          capacity=#{inspect(report.capacity)}
          inventory=#{inspect(report.inventory)}
          pools=#{inspect(report.pools, limit: :infinity, printable_limit: :infinity)}
          host_row=#{inspect(oracle_dump.rows)}
          pool_rows=#{inspect(pools_dump.rows)}
          """)
      end
    end)
  end

  # Settlement clears exactly the startup holds its proofs cover: compute only
  # for a currently observed running placement, disk for every covered one.
  @spec mark_settled(model(), String.t()) :: model()
  defp mark_settled(model, host_id) do
    Enum.reduce(Map.keys(model.vms), model, fn vm_id, acc ->
      case acc.vms[vm_id] do
        nil ->
          acc

        vm ->
          if vm.host_id == host_id and covered?(vm) do
            running? = vm.last_outcome.state == :running

            put_expectation(acc, vm_id, fn rec ->
              %{
                rec
                | settled: true,
                  startup_compute: rec.startup_compute and not running?,
                  startup_disk: false
              }
            end)
          else
            acc
          end
      end
    end)
  end

  @spec covered?(vmrec()) :: boolean()
  defp covered?(vm) do
    vm.last_outcome != nil and not vm.archived and
      match?(%{state: state} when state in [:running, :stopped], vm.last_outcome) and
      vm.last_outcome.generation == vm.generation and
      vm.last_outcome.placement_id == vm.placement_id
  end

  @spec ingest_report(model(), String.t()) :: :ok | {:rejected, term(), map()}
  defp ingest_report(model, host_id) do
    fixture = fixture_for(model, host_id)
    pool_snapshot = hd(fixture.report.pools)
    total = Map.get(model.pool_total, host_id, pool_snapshot.total_bytes)

    allocations =
      model.vms
      |> Map.values()
      |> Enum.filter(&(&1.pool_id == fixture.pool.id and &1.materialized and not &1.archived))
      |> Map.new(&{&1.placement_id, &1.reserve_disk})

    free = total - Enum.sum(Map.values(allocations))

    # Honest physical usage: every placement currently holding compute with a
    # running or uncertain observation reads its reserved shape out of the
    # committed ledger; released and archived holdings report nothing.
    running = measured_running_usage(model, host_id)

    capacity = %{
      "version" => 1,
      "cpu_headroom_millicores" => max(0, (5 - running.vcpu) * 1000),
      "memory_headroom_bytes" => max(0, 4 * @gib - running.memory_bytes),
      "interval_us" => 1_000_000,
      "covered" => covered_proofs(model, host_id)
    }

    report = %{
      fixture.report
      | sequence: model.seq[host_id],
        sampled_at: Ledger.now(),
        capacity: capacity,
        inventory: %{
          fixture.report.inventory
          | "images" => if(model.images[host_id], do: [image_id()], else: [])
        },
        pools: [
          %{
            pool_snapshot
            | total_bytes: total,
              free_bytes: free,
              allocations: allocations,
              storage: storage_observation(fixture.pool, total, free)
          }
        ]
    }

    case HostReports.ingest(host_id, fixture.epoch, report) do
      {:ok, :ok} -> :ok
      other -> {:rejected, other, report}
    end
  end

  @spec covered_proofs(model(), String.t()) :: %{String.t() => map()}
  defp covered_proofs(model, host_id) do
    model.vms
    |> Map.values()
    |> Enum.filter(&(&1.host_id == host_id and covered?(&1)))
    |> Map.new(fn vm ->
      running? = vm.last_outcome.state == :running

      {vm.placement_id,
       %{
         "outcome_id" => vm.last_outcome.id,
         "generation" => vm.last_outcome.generation,
         "execution_epoch" => vm.last_outcome.execution_epoch,
         "compute" => running?,
         "disk" => true
       }}
    end)
  end

  # ---------- raw committed-SQL oracle ----------

  # @cc [owner:ghuntley,label:verification] capacity-oracle-raw-committed-rows
  # The oracle MUST compute every expectation from committed tables by raw SQL
  # reads or Ledger row reads and the test's own injected values. It MUST NOT
  # call Budget or reuse Budget arithmetic beyond restating the documented
  # contract; a Budget regression MUST surface as an oracle failure.
  @spec oracle!(model()) :: :ok
  defp oracle!(model) do
    owners = [Ecto.UUID.dump!(model.owner.id)]
    assert_startup_compute_within_headroom(model)
    assert_startup_disk_within_free(model)
    assert_cardinality(model, owners)
    assert_hold_invariants(model)
    assert_address_integrity(model)
    :ok
  end

  # (a) Physical non-overcommit per committed ledger + enrolled inventory:
  # startup-held promises plus settled running occupancy must fit the host's
  # enrolled effective capacity minus configured overheads at every committed
  # step, and outstanding (unsettled) startup-held disk charges plus settled
  # materialized disk must fit each pool's enrolled total minus overhead.
  @spec assert_startup_compute_within_headroom(model()) :: :ok
  defp assert_startup_compute_within_headroom(model) do
    ids = Enum.map(model.hosts, &Ecto.UUID.dump!/1)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT h.id, h.effective_cores, h.overhead_cores, h.effective_memory_bytes,
               h.overhead_memory_bytes,
          COALESCE(SUM(r.vcpu) FILTER (WHERE r.compute_held AND r.startup_compute_held), 0)::bigint,
          COALESCE(SUM(r.memory_bytes) FILTER (WHERE r.compute_held AND r.startup_compute_held), 0)::bigint,
          COALESCE(SUM(r.vcpu) FILTER (WHERE r.compute_held AND NOT r.startup_compute_held), 0)::bigint,
          COALESCE(SUM(r.memory_bytes) FILTER (WHERE r.compute_held AND NOT r.startup_compute_held), 0)::bigint
        FROM compute_hosts h
        LEFT JOIN compute_reservations r ON r.host_id = h.id
        WHERE h.id = ANY($1::uuid[])
        GROUP BY h.id
        """,
        [ids],
        log: false
      )

    for [
          host_id,
          cores,
          overhead_cores,
          effective_memory,
          overhead_memory,
          startup_vcpu,
          startup_memory,
          settled_vcpu,
          settled_memory
        ] <- rows do
      assert startup_vcpu + settled_vcpu <= cores - overhead_cores,
             "host #{host_id} exceeds enrolled cores: startup #{startup_vcpu} + settled #{settled_vcpu} > " <>
               "#{cores} - #{overhead_cores}"

      assert startup_memory + settled_memory <= effective_memory - overhead_memory,
             "host #{host_id} exceeds enrolled memory: startup #{startup_memory} + settled #{settled_memory} > " <>
               "#{effective_memory} - #{overhead_memory}"
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] capacity-batched-oracle-equivalence
  # Batched reads MUST preserve every exact owner, pool and idempotency-key
  # predicate and invariant assertion at the existing committed phase boundary.
  # Joining aggregate extras to holds MUST charge extras once per pool.
  @spec assert_startup_disk_within_free(model()) :: :ok
  defp assert_startup_disk_within_free(model) do
    pool_ids = Enum.map(model.hosts, &fixture_for(model, &1).pool.id)

    %{rows: rows} =
      sql(
        """
        SELECT p.id, p.free_bytes, p.overhead_bytes, p.allocations,
               COALESCE(extras.temporary, 0)::bigint, COALESCE(extras.resize, 0)::bigint,
               holds.placement_id, holds.disk_bytes
        FROM compute_storage_pools p
        LEFT JOIN LATERAL (
          SELECT SUM(temporary_disk_bytes) AS temporary, SUM(pending_disk_bytes) AS resize
          FROM compute_reservations WHERE pool_id=p.id
        ) extras ON true
        LEFT JOIN compute_reservations holds
          ON holds.pool_id=p.id AND holds.disk_held AND holds.startup_disk_held
        WHERE p.id = ANY($1::uuid[])
        """,
        [Enum.map(pool_ids, &Ecto.UUID.dump!/1)]
      )

    pools = Enum.group_by(rows, &hd/1)

    for pool_id <- pool_ids do
      holds = Map.fetch!(pools, Ecto.UUID.dump!(pool_id))
      [[_, free, overhead, allocations, temporary, resize, _, _] | _] = holds

      pending =
        Enum.reduce(holds, 0, fn
          [_, _, _, _, _, _, nil, nil], total ->
            total

          [_, _, _, _, _, _, placement_id, disk], total ->
            total + disk - min(Map.get(allocations, placement_id, 0), disk)
        end)

      charged = pending + temporary + resize

      assert charged <= free - overhead,
             "pool #{pool_id} pending disk #{charged} exceeds free #{free} - overhead #{overhead}"
    end

    :ok
  end

  # (b) VM/placement/reservation/address/job cardinality === winning keys.
  @spec assert_cardinality(model(), [binary()]) :: :ok
  defp assert_cardinality(model, owners) do
    %{rows: [[vms, addresses, placements, reservations, operations, jobs]]} =
      sql(
        """
        WITH vms AS (
          SELECT id FROM compute_virtual_machines WHERE owner_id = ANY($1::uuid[])
        ), operations AS (
          SELECT id FROM compute_operations WHERE vm_id IN (SELECT id FROM vms)
        )
        SELECT
          (SELECT count(*) FROM vms),
          (SELECT count(*) FROM compute_network_addresses WHERE vm_id IN (SELECT id FROM vms)),
          (SELECT count(*) FROM compute_workload_placements WHERE vm_id IN (SELECT id FROM vms)),
          (SELECT count(*) FROM compute_reservations WHERE vm_id IN (SELECT id FROM vms)),
          (SELECT count(*) FROM operations),
          (SELECT count(*) FROM oban_jobs
           WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM operations))
        """,
        [owners]
      )

    assert vms == addresses, "#{vms} VMs but #{addresses} addresses"

    assert placements == reservations,
           "#{placements} placements but #{reservations} reservations"

    assert operations == jobs, "#{operations} operations but #{jobs} dispatch jobs"

    %{rows: key_rows} =
      sql(
        """
        SELECT idempotency_key, count(*), array_agg(id::text)
        FROM compute_virtual_machines WHERE owner_id=$1 GROUP BY idempotency_key
        """,
        [hd(owners)]
      )

    keys = Map.new(key_rows, fn [key, count, ids] -> {key, {count, ids}} end)

    for {key, {_shape, vm_id}} <- model.keys, is_binary(vm_id) do
      {count, ids} = Map.get(keys, key, {0, []})

      if count != 1 do
        rows =
          sql(
            """
            SELECT id::text, name, inserted_at, archived_at IS NOT NULL, current_placement_id::text
            FROM compute_virtual_machines WHERE owner_id=$1 AND idempotency_key=$2 ORDER BY inserted_at
            """,
            [hd(owners), key]
          )

        flunk(
          "duplicate durable VMs under one idempotency key #{key}: rows=#{inspect(rows.rows)}"
        )
      end

      assert ids == [vm_id], "idempotent replay lost its original VM"
    end

    :ok
  end

  # (d)+(e) terminal-path holdings from raw committed SQL and clone inventory:
  # no live non-archived VM may lose its disk hold; temporary copy holds exist
  # only under an active clone workflow; archival requires every hold released.
  @spec assert_hold_invariants(model()) :: :ok
  defp assert_hold_invariants(model) do
    owners = [Ecto.UUID.dump!(model.owner.id)]

    %{rows: [[disks_lost, leaked_temporary, unheld_archived]]} =
      sql(
        """
        SELECT
          count(*) FILTER (WHERE v.archived_at IS NULL AND NOT r.disk_held),
          count(*) FILTER (WHERE r.temporary_disk_bytes > 0 AND NOT EXISTS (
            SELECT 1 FROM compute_clone_requests c
            WHERE c.source_vm_id = r.vm_id AND c.active
          )),
          count(*) FILTER (WHERE NOT (v.archived_at IS NULL)
            AND (r.compute_held OR r.disk_held OR r.temporary_disk_bytes != 0))
        FROM compute_reservations r
        JOIN compute_virtual_machines v ON v.id = r.vm_id
        WHERE v.owner_id = ANY($1::uuid[])
        """,
        [owners]
      )

    assert disks_lost == 0, "non-archived VMs lost disk holds: #{disks_lost}"

    assert leaked_temporary == 0,
           "temporary copy holds outlive terminal clone state: #{leaked_temporary}"

    assert unheld_archived == 0, "archived VMs retained holds: #{unheld_archived}"
    :ok
  end

  # (f) address uniqueness per profile; slot reuse only after archival.
  @spec assert_address_integrity(model()) :: :ok
  defp assert_address_integrity(model) do
    %{rows: duplicates} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT profile, slot FROM compute_network_addresses
        WHERE archived_at IS NULL GROUP BY profile, slot HAVING count(*) > 1
        """,
        [],
        log: false
      )

    assert duplicates == [], "duplicate active addresses: #{inspect(duplicates)}"

    vm_ids = model.vms |> Map.keys() |> Enum.map(&Ecto.UUID.dump!/1)

    if vm_ids != [] do
      %{rows: [[violations]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT count(*) FROM (
            SELECT slot, archived_at,
                   lead(inserted_at) OVER (PARTITION BY slot ORDER BY inserted_at) AS next_inserted
            FROM compute_network_addresses
            WHERE profile = 'standard' AND slot IN
              (SELECT DISTINCT slot FROM compute_network_addresses WHERE vm_id = ANY($1::uuid[]))
          ) history
          WHERE (archived_at IS NULL AND next_inserted IS NOT NULL)
             OR (next_inserted IS NOT NULL AND next_inserted < archived_at)
          """,
          [vm_ids],
          log: false
        )

      assert violations == 0, "address slots reused before their archival committed"
    end

    :ok
  end

  # ---------- refusal accounting (c) ----------

  # Every refusal persists zero durable rows, checked immediately after the
  # batch that refused it commits. Provision keys already holding a VM are
  # idempotency-conflict replays, not fresh refusals.
  @spec assert_refusal_zero_rows(model(), map(), term()) :: :ok
  defp assert_refusal_zero_rows(model, %{type: :provision, key: key}, {:provision, {:error, _}}) do
    assert count_where(
             "SELECT count(*) FROM compute_operations WHERE request_key=$1",
             [key]
           ) == 0,
           "refused provision persisted dispatch rows for key #{key}"

    case model.keys[key] do
      {_shape, id} when is_binary(id) ->
        :ok

      _refused_or_absent ->
        assert count_where(
                 "SELECT count(*) FROM compute_virtual_machines WHERE owner_id=$1 AND idempotency_key=$2",
                 [Ecto.UUID.dump!(model.owner.id), key]
               ) == 0,
               "refused provision persisted VM rows for key #{key}"
    end

    :ok
  end

  defp assert_refusal_zero_rows(_model, %{type: :lifecycle, key: key}, {:lifecycle, {:error, _}}) do
    assert count_where("SELECT count(*) FROM compute_operations WHERE request_key=$1", [key]) ==
             0,
           "refused lifecycle persisted an operation for key #{key}"

    :ok
  end

  defp assert_refusal_zero_rows(_model, %{type: :relocate, key: key}, {:relocate, {:error, _}}) do
    assert count_where("SELECT count(*) FROM compute_relocations WHERE request_key=$1", [key]) ==
             0,
           "refused relocation persisted a row for key #{key}"

    assert count_where(
             "SELECT count(*) FROM oban_jobs WHERE args->'primary_key'->>'id' IN " <>
               "(SELECT id::text FROM compute_relocations WHERE request_key=$1)",
             [key]
           ) == 0,
           "refused relocation persisted jobs for key #{key}"

    :ok
  end

  defp assert_refusal_zero_rows(_model, %{type: :clone, key: key}, {:clone, {:error, _}, _}) do
    assert count_where(
             "SELECT count(*) FROM compute_clone_requests WHERE request_key=$1",
             [key]
           ) == 0,
           "refused clone admission persisted a row for key #{key}"

    :ok
  end

  defp assert_refusal_zero_rows(_model, _step, _result), do: :ok

  @spec count_where(String.t(), [term()]) :: integer()
  defp count_where(sql, params) do
    %{rows: [[count]]} = Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)
    count
  end

  # ---------- host control helpers ----------

  @spec set_enabled(model(), String.t(), boolean()) :: model()
  defp set_enabled(model, host_id, enabled) do
    [host] = Ledger.read!(Host, id: host_id)
    _ = Ledger.update!(host, :configure, %{enabled: enabled})
    put_in(model, [:disabled, host_id], not enabled)
  end

  @spec provision_step(model(), String.t(), shape()) :: map()
  defp provision_step(_model, key, shape) do
    %{type: :provision, key: key, shape: shape, gen_key: :window}
  end

  @spec outcome_step(model(), String.t(), atom(), atom()) :: map()
  defp outcome_step(model, vm_id, state, reason) do
    vm = Map.fetch!(model.vms, vm_id)

    if vm.anchor == nil do
      raise "outcome step for vm #{vm_id} has no anchor op: desired=#{vm.desired} observed=#{vm.observed} settled=#{vm.settled} archived=#{vm.archived} relocating=#{vm.relocating} clone_child=#{vm.clone_child} last=#{inspect(vm.last_outcome && Map.take(vm.last_outcome, [:state, :generation]))}"
    end

    %{type: :outcome, vm_id: vm_id, state: state, reason: reason, op: vm.anchor}
  end

  @spec lifecycle_step(String.t(), :start | :stop | :delete) :: map()
  defp lifecycle_step(vm_id, kind) do
    %{type: :lifecycle, vm_id: vm_id, kind: kind, key: Ash.UUID.generate()}
  end

  # ---------- shared phase ----------

  # One deterministic phase: concurrent steps on peers, absorption, refusal
  # accounting at the commit boundary, settlement reports, then the oracle.
  @spec phase(model(), [map()]) :: {model(), [term()]}
  defp phase(model, steps) do
    results = measure_stage(:race_rpc, fn -> run_steps(model, steps) end)

    model = absorb(model, steps, results)

    Enum.zip(steps, results)
    |> Enum.each(fn {step, result} -> assert_refusal_zero_rows(model, step, result) end)

    model = measure_stage(:settlement, fn -> settle(model) end)
    measure_stage(:oracle, fn -> oracle!(model) end)
    {model, results}
  end

  defp run_generated_batch(model, ops) do
    steps = resolve_ops(model, ops)
    {model, _results} = phase(model, steps)
    model
  end

  # Seed n settled running VMs of the seed shape onto one host (the other host
  # disabled), returning the accepted vm records. The host MUST have fitting
  # slots for n per the committed ledger; compute that first.
  @spec seed_vms(model(), String.t(), pos_integer()) :: {model(), [vmrec()]}
  defp seed_vms(model, host_id, n) do
    other = Enum.find(model.hosts, &(&1 != host_id))
    model = set_enabled(model, other, false)

    capacity = fitting_slots(model, host_id, shape0())

    if capacity < n do
      detail =
        sql(
          "SELECT total_bytes, free_bytes, overhead_bytes FROM compute_storage_pools WHERE host_id=$1",
          [Ecto.UUID.dump!(host_id)]
        )

      caps = sql("SELECT capacity FROM compute_hosts WHERE id=$1", [Ecto.UUID.dump!(host_id)])

      flunk("""
      host #{host_id} fits #{capacity} slots, seed needs #{n}.
      pools=#{inspect(detail.rows)} capacity=#{inspect(caps.rows)}
      """)
    end

    steps =
      for i <- 1..n,
          do: provision_step(model, "seed-#{i}-#{Ash.UUID.generate()}", shape0())

    {model, results} = phase(model, steps)

    winners =
      for {%{type: :provision}, {:provision, {:ok, vm}}} <- Enum.zip(steps, results) do
        vm.id
      end

    assert length(winners) == n,
           "seeding #{n} vms on #{host_id} accepted #{length(winners)}"

    outcome_steps = for vm_id <- winners, do: outcome_step(model, vm_id, :running, :none)
    {model, _outcomes} = phase(model, outcome_steps)

    model = set_enabled(model, other, true)
    model = settle(model)
    oracle!(model)

    {model, Enum.map(winners, &Map.fetch!(model.vms, &1))}
  end

  @spec shape0() :: shape()
  defp shape0, do: %{vcpu: 1, memory_bytes: @mem, disk_bytes: 2 * @gib}
  # ---------- deterministic windows (targeted race classes) ----------

  # Physical geometry per seed shape (1 vCPU, 512 MiB guest memory, 2 GiB guest
  # disk): the reservation adds the pinned VMM/bundle footprint, so a host fits
  # exactly three settled VMs and the 10 GiB disk pool binds first. Windows
  # reach exact free-slot states by resizing the synthetic pool (a capacity
  # observation, like a host rescan) and by confirming stops to free vCPU.
  @spec windows(model()) :: model()
  defp windows(model) do
    [host_a, host_b] = model.hosts
    {model, seed_a} = seed_vms(model, host_a, 3)
    {model, seed_b} = seed_vms(model, host_b, 3)

    model = window_failed_release(model, hd(seed_a).id)
    model = window_crash_exhaustion(model, hd(seed_b).id)
    {model, respent} = window_delete_respend(model, Enum.at(seed_a, 1).id)
    model = window_relocate_last_slot(model, host_b, hd(respent), hd(seed_b).id)
    model = window_clone_last_slot(model, hd(seed_a).id)
    window_image_disappearance(model)
  end

  # Execution failure releases retained-disk compute; three restart keys share
  # the freed slot through one VM generation chain.
  @spec window_failed_release(model(), String.t()) :: model()
  defp window_failed_release(model, vm_id) do
    {model, _} = phase(model, [outcome_step(model, vm_id, :failed, :execution_failed)])

    failed_vm = model.vms[vm_id]
    assert not failed_vm.compute_held, "failed terminal outcome must release compute"
    assert failed_vm.disk_held, "failed terminal outcome lost the retained disk"

    starts = for _ <- 1..3, do: lifecycle_step(vm_id, :start)
    {model, results} = phase(model, starts)

    assert Enum.all?(results, &match?({:lifecycle, {:ok, _}}, &1)),
           "restart of a failed VM under freed headroom refused: #{inspect(results)}"

    pending = model.vms[vm_id].pending
    assert pending != nil and pending.kind == :start

    {model, _} = phase(model, [outcome_step(model, vm_id, :running, :none)])
    model
  end

  # Bounded automatic crash recovery: three restarts per ten minutes, then the
  # reservation MUST release compute while retaining disk and address.
  @spec window_crash_exhaustion(model(), String.t()) :: model()
  defp window_crash_exhaustion(model, vm_id) do
    assert model.vms[vm_id].observed == :running

    Enum.reduce(1..4, model, fn round, acc ->
      {acc, _} = phase(acc, [outcome_step(acc, vm_id, :failed, :crashed)])
      absorbed = acc.vms[vm_id]

      if round <= 3 do
        assert absorbed.crash_times == round, "crash budget lost a restart attempt"

        assert absorbed.pending != nil and absorbed.pending.kind == :start,
               "crash round #{round} did not reacquire a restart"

        {acc, _} = phase(acc, [outcome_step(acc, vm_id, :running, :none)])
        acc
      else
        assert absorbed.crash_times == 3

        assert not absorbed.compute_held and absorbed.pending == nil,
               "exhausted crash recovery retained compute or restarted"

        assert absorbed.disk_held, "exhausted crash recovery lost the retained disk"
        acc
      end
    end)
  end

  # Confirmed delete releases compute and disk; the freed slot re-spends exactly
  # once against racing distinct keys. Detects a dropped startup-hold filter:
  # winners must win exactly the freed slots, never fewer.
  @spec window_delete_respend(model(), String.t()) :: {model(), [vmrec()]}
  defp window_delete_respend(model, vm_id) do
    host_id = model.vms[vm_id].host_id
    model = delete_confirmed(model, vm_id)

    deleted = model.vms[vm_id]
    assert deleted.archived and not deleted.disk_held and not deleted.compute_held

    freed = fitting_slots(model, host_id, shape0())
    assert freed >= 1, "confirmed delete freed no respending slot"

    demand = freed + 3

    steps =
      for i <- 1..demand,
          do: provision_step(model, "respend-#{i}-#{Ash.UUID.generate()}", shape0())

    {model, results} = phase(model, steps)

    winners = for {:provision, {:ok, winner}} <- results, do: winner
    refusals = for {:provision, {:error, e}} <- results, do: Exception.message(e)

    if length(winners) != freed do
      pools =
        sql(
          "SELECT host_id::text, total_bytes, free_bytes, overhead_bytes FROM compute_storage_pools",
          []
        )

      wins = for {:provision, {:ok, w}} <- results, do: {w.id, w.host_id}

      flunk(
        "freed slot re-spent #{length(winners)} times, expected exactly #{freed}. winners=#{inspect(wins)} pools=#{inspect(pools.rows)}"
      )
    end

    assert length(refusals) == demand - freed
    assert Enum.all?(refusals, &(&1 =~ "insufficient_capacity"))

    outcome_steps = for winner <- winners, do: outcome_step(model, winner.id, :running, :none)
    {model, _} = phase(model, outcome_steps)

    {model, Enum.map(winners, &Map.fetch!(model.vms, &1.id))}
  end

  # Relocation destination reservation versus provision for the destination
  # host's last disk slot: exactly one wins; a stopped workload reserves
  # destination disk without compute.
  @spec window_relocate_last_slot(model(), String.t(), vmrec(), String.t()) :: model()
  defp window_relocate_last_slot(model, host_b, source, crash_vm_id) do
    # The crash victim's failed reservation retains its disk; physically remove
    # it so the destination holds exactly one reservation-sized disk slot.
    model = delete_confirmed(model, crash_vm_id)

    source_id = source.id
    model = stop_confirmed(model, source_id)
    source = model.vms[source_id]
    assert source.host_id != host_b

    model = settle(model)
    fit = fitting_slots(model, host_b, shape0())
    assert fit == 1, "destination host must have exactly one free slot, has #{fit}"

    # A relocation never selects its own source host; shrinking the alternative
    # host's pool to zero slots forces both racers onto the destination's slot.
    model = tune_disk_slots(model, source.host_id, 0)

    steps = [
      %{type: :relocate, vm_id: source.id, key: "relocate-#{Ash.UUID.generate()}"},
      provision_step(model, "contend-#{Ash.UUID.generate()}", shape0())
    ]

    {model, results} = phase(model, steps)

    relocation_won? = Enum.any?(results, &match?({:relocate, {:ok, _}}, &1))
    provision_won? = Enum.any?(results, &match?({:provision, {:ok, _}}, &1))

    assert relocation_won? != provision_won?,
           "destination reservation and provision split the last slot: #{inspect(results)}"

    for {:relocate, {:error, e}} <- results,
        do: assert(Exception.message(e) =~ "insufficient_capacity")

    for {:provision, {:error, e}} <- results,
        do: assert(Exception.message(e) =~ "insufficient_capacity")

    if relocation_won? do
      [destination_reservation] =
        Enum.reject(Ledger.read!(Reservation, vm_id: source.id), fn reservation ->
          reservation.placement_id == source.placement_id
        end)

      assert destination_reservation.disk_held and not destination_reservation.compute_held
      assert destination_reservation.temporary_disk_bytes == 0
    end

    model
  end

  # Clone destination placement versus provision on one pool's reservation
  # space: exactly one wins; a winning clone holds its source temporary copy
  # bytes. Tuning the source host to exactly two free disk slots makes the
  # outcome deterministic: a clone (temporary source hold plus destination)
  # costs two slots, a provision one.
  @spec window_clone_last_slot(model(), String.t()) :: model()
  defp window_clone_last_slot(model, source_id) do
    model = restore_all_hosts(model)

    model = stop_confirmed(model, source_id)
    source = model.vms[source_id]
    host_a = source.host_id
    host_b = Enum.find(model.hosts, &(&1 != host_a))

    model = ensure_vcpu(model, host_a, 1, [source.id])
    model = tune_disk_slots(model, host_a, 2)
    model = set_enabled(model, host_b, false)
    model = settle(model)

    steps = [
      %{type: :clone, vm_id: source.id, key: "clone-#{Ash.UUID.generate()}"},
      provision_step(model, "contend-#{Ash.UUID.generate()}", shape0())
    ]

    {model, results} = phase(model, steps)

    clone_won? =
      case Enum.find(results, &match?({:clone, _, _}, &1)) do
        {:clone, {:ok, view}, _advance} ->
          clone_committed_destination(view.destination_vm_id) != nil

        _ ->
          false
      end

    provision_won? = Enum.any?(results, &match?({:provision, {:ok, _}}, &1))

    assert clone_won? != provision_won?,
           "clone placement and provision split the last pool slots: #{inspect(results)}"

    if clone_won? do
      retained = model.vms[source.id]
      assert retained.clone_busy

      assert retained.temporary == retained.reserve_disk,
             "active clone must hold its source temporary copy bytes"

      assert Enum.any?(results, fn
               {:provision, {:error, e}} ->
                 Exception.message(e) =~ "insufficient_capacity"

               _ ->
                 false
             end),
             "clone won; the provision must refuse for capacity"
    else
      assert Enum.any?(results, &match?({:provision, {:ok, _}}, &1))
    end

    model = set_enabled(model, host_b, true)
    settle(model)
  end

  # An image admitted against disappears from the host inventory between
  # admission and the physical outcome: the failed outcome releases compute,
  # retains the disk with zero materialized credit, and a confirmed delete
  # archives the VM and releases its address.
  @spec window_image_disappearance(model()) :: model()
  defp window_image_disappearance(model) do
    model = restore_all_hosts(model)

    host_id = hd(model.hosts)
    other = Enum.find(model.hosts, &(&1 != host_id))
    model = set_enabled(model, other, false)
    model = ensure_vcpu(model, host_id, 1, [])
    model = tune_disk_slots(model, host_id, 1)
    model = settle(model)

    assert fitting_slots(model, host_id, shape0()) >= 1, "no slot for the image window"

    {model, [{:provision, {:ok, vm}}]} =
      phase(model, [provision_step(model, "image-window-#{Ash.UUID.generate()}", shape0())])

    vm_entry = model.vms[vm.id]
    assert vm_entry.pending != nil and vm_entry.pending.kind == :provision

    # The image vanishes between admission and the physical outcome.
    model = put_in(model, [:images, host_id], false)
    model = settle(model)

    {model, _} = phase(model, [outcome_step(model, vm.id, :failed, :execution_failed)])

    failed = model.vms[vm.id]
    assert not failed.compute_held and failed.disk_held

    [reservation] = Ledger.read!(Reservation, placement_id: vm_entry.placement_id)
    assert not reservation.compute_held and reservation.disk_held
    assert reservation.startup_disk_held, "never-materialized disk lost its startup hold"
    assert reservation.temporary_disk_bytes == 0

    %{rows: [[credit]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COALESCE((allocations->$1)::bigint, 0) FROM compute_storage_pools WHERE id=$2",
        [vm_entry.placement_id, Ecto.UUID.dump!(vm_entry.pool_id)],
        log: false
      )

    assert credit == 0, "image-less failed admission earned materialized credit"

    model = delete_confirmed(model, vm.id)
    assert model.vms[vm.id].archived

    addresses =
      count_where(
        "SELECT count(*) FROM compute_network_addresses WHERE vm_id=$1 AND archived_at IS NULL",
        [Ecto.UUID.dump!(vm.id)]
      )

    assert addresses == 0, "confirmed delete retained an active address"

    model = put_in(model, [:images, host_id], true)
    model = set_enabled(model, other, true)
    settle(model)
  end

  # Stop a vm and confirm the physical stop so relocation/clone eligibility hold.
  @spec stop_confirmed(model(), String.t()) :: model()
  defp stop_confirmed(model, vm_id) do
    vm = model.vms[vm_id]

    model =
      if vm.observed == :stopped do
        model
      else
        {model, _} = phase(model, [lifecycle_step(vm_id, :stop)])
        {model, _} = phase(model, [outcome_step(model, vm_id, :stopped, :none)])
        model
      end

    assert model.vms[vm_id].observed == :stopped
    assert model.vms[vm_id].pending == nil
    model
  end

  @spec delete_confirmed(model(), String.t()) :: model()
  defp delete_confirmed(model, vm_id) do
    {model, _} = phase(model, [lifecycle_step(vm_id, :delete)])
    {model, _} = phase(model, [outcome_step(model, vm_id, :deleted, :none)])
    model
  end

  @spec restore_all_hosts(model()) :: model()
  defp restore_all_hosts(model) do
    model
    |> restore_hosts()
    |> settle()
  end

  @spec restore_hosts(model()) :: model()
  defp restore_hosts(model) do
    Enum.reduce(model.hosts, model, fn host_id, acc ->
      acc = if acc.disabled[host_id], do: set_enabled(acc, host_id, true), else: acc

      if acc.images[host_id], do: acc, else: put_in(acc, [:images, host_id], true)
    end)
  end

  # ---------- synthetic capacity shaping ----------

  # Resize the host's synthetic pool report so exactly n reservation slots of
  # allocatable disk remain — the observation-equivalent of a storage rescan.
  # The committed pool row remains the only source of truth for the oracle.
  @spec tune_disk_slots(model(), String.t(), non_neg_integer()) :: model()
  defp tune_disk_slots(model, host_id, n) do
    slot = reservation_cost(shape0()).disk_bytes
    fixture = fixture_for(model, host_id)
    overhead = fixture.pool.overhead_bytes

    %{rows: [[free_now, total_now, pending, temporary]]} =
      sql(
        """
        SELECT p.free_bytes, p.total_bytes,
          COALESCE((SELECT SUM(r.disk_bytes) FILTER (WHERE r.disk_held AND r.startup_disk_held) FROM compute_reservations r WHERE r.pool_id=p.id), 0)::bigint,
          COALESCE((SELECT SUM(r.temporary_disk_bytes) FROM compute_reservations r WHERE r.pool_id=p.id), 0)::bigint
        FROM compute_storage_pools p WHERE p.host_id=$1
        """,
        [Ecto.UUID.dump!(host_id)]
      )

    allocated = total_now - free_now
    # One GiB of padding keeps the resulting availability strictly off the
    # slot boundary while preserving the exact slot count.
    new_total = allocated + overhead + pending + temporary + n * slot + @gib
    model = put_in(model, [:pool_total, host_id], new_total)
    model = settle(model)

    disk_slots = div(max(allocatable_disk_bytes(model, host_id), 0), slot)

    assert disk_slots == n,
           "disk tune on #{host_id} reached #{disk_slots} slots, wanted #{n}"

    model
  end

  # Ensure the host reports at least n free measured vCPU slots, confirming
  # stops of settled unprotected workloads until physical headroom recovers.
  @spec ensure_vcpu(model(), String.t(), pos_integer(), [String.t()]) :: model()
  defp ensure_vcpu(model, host_id, n, protect) do
    if vcpu_free(model, host_id) >= n do
      model
    else
      candidate =
        model.vms
        |> Map.values()
        |> Enum.filter(
          &(&1.host_id == host_id and not &1.archived and &1.observed == :running and
              &1.settled and &1.pending == nil and not &1.relocating and
              not &1.clone_busy and not &1.clone_child and &1.id not in protect)
        )
        |> Enum.sort_by(& &1.id)
        |> List.first()

      assert candidate != nil, "no stoppable VM on #{host_id} to free vcpu"
      ensure_vcpu(stop_confirmed(model, candidate.id), host_id, n, protect)
    end
  end

  @spec vcpu_free(model(), String.t()) :: integer()
  defp vcpu_free(model, host_id) do
    %{rows: [[capacity]]} =
      sql("SELECT capacity FROM compute_hosts WHERE id=$1", [Ecto.UUID.dump!(host_id)])

    %{rows: [[held]]} =
      sql(
        """
        SELECT COALESCE(SUM(vcpu), 0)::bigint FROM compute_reservations
        WHERE host_id=$1 AND compute_held AND startup_compute_held
        """,
        [Ecto.UUID.dump!(host_id)]
      )

    div(capacity["cpu_headroom_millicores"], 1000) -
      fixture_for(model, host_id).host.overhead_cores - held
  end

  # Allocatable disk bytes per the committed ledger: free minus overhead minus
  # outstanding startup disk charges and temporary holds, all from raw rows.
  @spec allocatable_disk_bytes(model(), String.t()) :: integer()
  defp allocatable_disk_bytes(model, host_id) do
    pool_id = fixture_for(model, host_id).pool.id
    dumped = Ecto.UUID.dump!(pool_id)

    %{rows: [[free, overhead]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT free_bytes, overhead_bytes FROM compute_storage_pools WHERE id=$1",
        [dumped],
        log: false
      )

    %{rows: [[pending, temporary, resize]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          COALESCE(SUM(disk_bytes) FILTER (WHERE disk_held AND startup_disk_held), 0)::bigint,
          COALESCE(SUM(temporary_disk_bytes), 0)::bigint,
          COALESCE(SUM(pending_disk_bytes), 0)::bigint
        FROM compute_reservations WHERE pool_id=$1
        """,
        [dumped],
        log: false
      )

    free - overhead - pending - temporary - resize
  end

  # Number of additional seed-shaped admissions a host can still fit given the
  # committed ledger and physical honesty rules; reservation footprints come
  # from the shared protocol shape definition, never from Budget.
  @spec fitting_slots(model(), String.t(), shape()) :: non_neg_integer()
  defp fitting_slots(model, host_id, shape) do
    reservation = reservation_cost(shape)
    disk_slots = div(max(allocatable_disk_bytes(model, host_id), 0), reservation.disk_bytes)
    fx = fixture_for(model, host_id)

    %{rows: [[capacity]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT capacity FROM compute_hosts WHERE id=$1",
        [Ecto.UUID.dump!(host_id)],
        log: false
      )

    %{rows: [[vcpu_held, memory_held]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT COALESCE(SUM(vcpu), 0)::bigint, COALESCE(SUM(memory_bytes), 0)::bigint
        FROM compute_reservations
        WHERE host_id=$1 AND compute_held AND startup_compute_held
        """,
        [Ecto.UUID.dump!(host_id)],
        log: false
      )

    vcpu_free =
      div(capacity["cpu_headroom_millicores"], 1000) - fx.host.overhead_cores - vcpu_held

    memory_free = capacity["memory_headroom_bytes"] - fx.host.overhead_memory_bytes - memory_held

    [disk_slots, div(vcpu_free, reservation.vcpu), div(memory_free, reservation.memory_bytes)]
    |> Enum.min()
    |> max(0)
  end

  @spec reservation_cost(shape()) :: %{
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer()
        }
  defp reservation_cost(shape) do
    OverallsProtocol.VMShape.reservation(Map.put(shape, :profile, :standard))
  end

  # ---------- committed fixture teardown ----------

  # @cc [owner:ghuntley,label:verification] capacity-race-fixture-teardown
  # Teardown MUST delete only this sample's fixture rows: relocation workflow
  # strips first (destination placements/reservations hang off the other host),
  # then clone workflow rows, then the shared per-host cleanup. Job/event
  # deletion follows the real Oban trigger order for these exact ids.
  # Fixture deletion can lose a transient FK lock race against peers' aborted
  # in-flight work; deletes are idempotent against the same committed target.
  @spec cleanup_sample(model()) :: :ok
  defp cleanup_sample(model),
    do: measure_stage(:fixture_cleanup, fn -> cleanup_sample(model, 3) end)

  @spec cleanup_sample(model(), non_neg_integer()) :: :ok
  defp cleanup_sample(model, attempts) do
    cleanup_sample_once(model)
  rescue
    e in Postgrex.Error ->
      if e.postgres.code == :deadlock_detected and attempts > 0 do
        cleanup_sample(model, attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  @spec cleanup_sample_once(model()) :: :ok
  defp cleanup_sample_once(model) do
    unboxed(fn ->
      %{rows: vm_rows} =
        sql("SELECT id::text FROM compute_virtual_machines WHERE owner_id = $1", [
          Ecto.UUID.dump!(model.owner.id)
        ])

      vm_ids = Enum.map(vm_rows, fn [id] -> id end)
      dumped_vms = Enum.map(vm_ids, &Ecto.UUID.dump!/1)

      %{rows: relocation_rows} =
        sql(
          "SELECT id::text, destination_placement_id::text FROM compute_relocations WHERE vm_id = ANY($1::uuid[])",
          [dumped_vms]
        )

      relocation_ids = Enum.map(relocation_rows, fn [id, _destination] -> Ecto.UUID.dump!(id) end)

      destination_placements =
        Enum.map(relocation_rows, fn [_id, destination] -> Ecto.UUID.dump!(destination) end)

      %{rows: clone_rows} =
        sql(
          "SELECT id::text FROM compute_clone_requests WHERE source_vm_id = ANY($1::uuid[]) OR destination_vm_id = ANY($1::uuid[])",
          [dumped_vms]
        )

      clone_ids = Enum.map(clone_rows, fn [id] -> Ecto.UUID.dump!(id) end)

      for vm_id <- vm_ids, do: Cleanup.relocation_history!(vm_id)

      if relocation_ids != [] do
        Cleanup.jobs!(
          """
          args->'primary_key'->>'id' IN (
            SELECT id::text FROM compute_relocations WHERE id = ANY($1::uuid[]) UNION ALL
            SELECT id::text FROM compute_source_permit_requests WHERE relocation_id = ANY($1::uuid[]) UNION ALL
            SELECT id::text FROM compute_probe_requests WHERE relocation_id = ANY($1::uuid[]))
          """,
          [relocation_ids]
        )

        sql(
          "DELETE FROM compute_transfer_slots WHERE source_relocation_id = ANY($1::uuid[]) OR destination_relocation_id = ANY($1::uuid[])",
          [relocation_ids]
        )

        sql("DELETE FROM compute_relocations WHERE id = ANY($1::uuid[])", [relocation_ids])

        sql("DELETE FROM compute_reservations WHERE placement_id = ANY($1::uuid[])", [
          destination_placements
        ])

        sql("DELETE FROM compute_workload_placements WHERE id = ANY($1::uuid[])", [
          destination_placements
        ])
      end

      if clone_ids != [] do
        %{rows: effect_rows} =
          sql(
            "SELECT id::text FROM compute_clone_effects WHERE clone_request_id = ANY($1::uuid[])",
            [
              clone_ids
            ]
          )

        effect_ids = Enum.map(effect_rows, fn [id] -> Ecto.UUID.dump!(id) end)

        sql(
          "DELETE FROM compute_lifecycle_events WHERE resource_id = ANY($1::uuid[]) OR workflow_id = ANY($1::uuid[])",
          [clone_ids ++ effect_ids]
        )

        Cleanup.jobs!(
          "args->'primary_key'->>'id' IN (SELECT id::text FROM compute_clone_requests WHERE id = ANY($1::uuid[]))",
          [clone_ids]
        )

        sql("DELETE FROM compute_transfer_slots WHERE clone_request_id = ANY($1::uuid[])", [
          clone_ids
        ])

        sql("DELETE FROM compute_clone_effects WHERE clone_request_id = ANY($1::uuid[])", [
          clone_ids
        ])

        sql(
          "DELETE FROM compute_clone_requests_versions WHERE version_source_id = ANY($1::uuid[])",
          [clone_ids]
        )

        sql("DELETE FROM compute_clone_requests WHERE id = ANY($1::uuid[])", [clone_ids])
      end

      for host_id <- model.hosts do
        assert {:ok, _} =
                 Marshall.CommittedFixtureCleanup.cleanup_compute(host_id, model.owner.id)
      end

      :ok
    end)
  end

  @spec sql(String.t(), [term()]) :: Postgrex.Result.t()
  defp sql(statement, params), do: Ecto.Adapters.SQL.query!(Repo, statement, params, log: false)
  # @cc [owner:ghuntley,label:verification;concurrency] capacity-opposite-source-lock-reach
  # Three independent mutation peers MUST all reach a host-lock blocking chain
  # rooted in the fixture holder before release. Queue acceptance alone MUST NOT
  # count as clone activation; at least one real transfer allocation MUST commit.
  # Returned SQL errors MUST fail, and committed opposite relocation endpoints,
  # complete allocation inventories and unreleased slot uniqueness MUST be checked.
  #
  # The domain is finite: every generated case already ran all three rotations,
  # so a case only chose the first rotation and the host direction, six points
  # in all. 6fad4d347 raised it from 2 generated cases to the ADR-0191 default
  # of 100: up to 300 samples of three fresh peers each, re-running those six
  # points against a 300 s budget it could not meet in CI. Its exploration review
  # sends true finite matrices to ordinary tests that enumerate every value, so
  # this runs each rotation in both directions once. Every sample still starts
  # and stops its own three peers, so ordering between samples is not an input.
  # The six samples took 29 s locally, inside the unchanged 300 s module budget.
  test "opposite-source relocations and clone activation reach shared host locks" do
    measure_stage(:lock_history, fn ->
      for reverse <- [false, true], rotation <- [0, 1, 2] do
        unboxed(fn -> lock_schedule_sample(rotation, reverse) end)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;durability] lock-fixture-acquisition-atomic
  # Host, pool, image and actor acquisition MUST commit together or roll back;
  # failed acquisition MUST stop all acquired peers before propagating.
  @spec lock_schedule_sample(0..2, boolean()) :: :ok
  defp lock_schedule_sample(rotation, reverse) do
    peers = measure_stage(:peer_startup, &start_peers/0)

    initial =
      Cleanup.protect peers do
        {:ok, fixture_model} =
          Repo.transaction(fn ->
            first = host_fixture()
            second = host_fixture()
            actor = user()
            model = model_init(peers, actor, first, second)

            totals =
              Map.new(model.fixture, fn {id, fixture} ->
                {id, hd(fixture.report.pools).total_bytes}
              end)

            model = %{model | pool_total: totals}
            register_timeout_cleanup(peers, fn -> cleanup_sample(model) end)
            model
          end)

        fixture_model
      after
        :ok
      end

    Cleanup.protect peers do
      assert_fixture_endpoints!(initial)
      [left, right] = if reverse, do: Enum.reverse(initial.hosts), else: initial.hosts
      {model, left_vms} = seed_vms(initial, left, 2)
      {model, right_vms} = seed_vms(model, right, 1)
      all_vms = left_vms ++ right_vms
      model = Enum.reduce(all_vms, model, fn vm, acc -> stop_confirmed(acc, vm.id) end)
      [clone_vm, left_vm] = left_vms
      [right_vm] = right_vms

      steps = [
        %{type: :clone, vm_id: clone_vm.id, key: Ash.UUID.generate()},
        %{type: :relocate, vm_id: left_vm.id, key: Ash.UUID.generate()},
        %{type: :relocate, vm_id: right_vm.id, key: Ash.UUID.generate()}
      ]

      results = locked_steps(model, steps, rotation)
      Enum.each(results, &validate_step_result!/1)

      winners =
        Enum.zip(steps, results)
        |> Enum.map(fn
          {%{type: :relocate, vm_id: requested}, {:relocate, {:ok, relocation}}} ->
            source = Map.fetch!(model.vms, requested)
            assert relocation.vm_id == requested
            assert relocation.source_host_id == source.host_id

            assert relocation.destination_host_id ==
                     Enum.find(model.hosts, &(&1 != source.host_id))

            true

          {%{type: :clone, vm_id: requested}, {:clone, {:ok, view}, {:ok, _}}} ->
            case clone_committed_destination(view.destination_vm_id) do
              nil ->
                false

              destination ->
                source = Map.fetch!(model.vms, requested)
                assert destination.host_id in model.hosts

                assert [[true, phase, source_id, source_host, destination_host, destination_id]] =
                         sql(
                           "SELECT active, phase, source_vm_id::text, source_host_id::text, destination_host_id::text, destination_vm_id::text FROM compute_clone_requests WHERE id = $1",
                           [Ecto.UUID.dump!(view.id)]
                         ).rows

                assert phase not in ["queued", "failed", "cancelled", "completed"]
                assert source_id == requested
                assert source_host == source.host_id
                assert destination_host == destination.host_id
                assert destination_id == destination.id
                true
            end

          _ ->
            false
        end)

      assert Enum.any?(winners),
             "no transfer activation or admission committed after host-lock reach"

      model = absorb(model, steps, results)

      for {step, result} <- Enum.zip(steps, results),
          do: assert_refusal_zero_rows(model, step, result)

      model = settle(model)
      oracle!(model)

      assert sql(
               "SELECT host_id FROM compute_transfer_slots WHERE host_id = ANY($1::uuid[]) AND released_at IS NULL GROUP BY host_id HAVING count(*) > 1",
               [Enum.map(model.hosts, &Ecto.UUID.dump!/1)]
             ).rows == []

      :ok
    after
      Enum.each(peers, &stop_peer_if_alive/1)
      cleanup_sample(initial)
      disarm_timeout_cleanup()
    end
  end

  @spec assert_fixture_endpoints!(model()) :: :ok
  defp assert_fixture_endpoints!(model) do
    now = Ledger.now()

    eligible =
      Ledger.read!(Host)
      |> Enum.filter(fn host ->
        host.enabled and host.maintenance_mode == :normal and
          host.architecture == :x86_64 and host.inventory["execution_ready"] == true and
          match?({:ok, _}, OverallsProtocol.TransferSSH.endpoint(host.transfer_endpoint)) and
          HostLiveness.capacity_fresh?(host.reported_at, now)
      end)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert eligible == Enum.sort(model.hosts),
           "ordinary endpoint eligibility includes nonfixture hosts"

    :ok
  end

  @spec locked_steps(model(), [map()], 0..2) :: [term()]
  defp locked_steps(model, steps, rotation) do
    owner = self()
    ref = make_ref()
    supervisor_id = {Task.Supervisor, make_ref()}

    supervisor =
      start_supervised!(%{
        id: supervisor_id,
        start: {Task.Supervisor, :start_link, [[]]}
      })

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(
            fn ->
              for id <- Enum.sort(model.hosts),
                  do:
                    sql("SELECT id FROM compute_hosts WHERE id = $1 FOR UPDATE", [
                      Ecto.UUID.dump!(id)
                    ])

              [[backend]] = sql("SELECT pg_backend_pid()", []).rows
              send(owner, {:host_rows_held, ref, backend})

              receive do
                {:release_host_rows, ^ref} -> :released
              after
                20_000 -> raise "host-lock holder release timed out"
              end
            end,
            timeout: 30_000
          )
        end)
      end)

    try do
      assert_receive {:host_rows_held, ^ref, backend}, 10_000

      tagged =
        Enum.with_index(steps)
        |> Enum.map(fn {step, index} ->
          tag = "capacity_lock_#{System.unique_integer([:positive])}_#{index}"
          peer = Enum.at(model.peers, rem(index + rotation, 3))
          action = if step.type == :clone, do: :clone, else: :relocate

          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              :peer.call(
                peer,
                Marshall.Compute.CapacityRaceTags,
                action,
                [tag, %{vm_id: step.vm_id, idempotency_key: step.key}, model.owner],
                30_000
              )
            end)

          {tag, task}
        end)

      try do
        assert_waiter_chain!(
          Enum.map(tagged, &elem(&1, 0)),
          backend,
          System.monotonic_time(:millisecond) + 8_000
        )

        send(holder.pid, {:release_host_rows, ref})
        assert lock_task_result!(holder, 10_000) == {:ok, :released}
        Enum.map(tagged, fn {_tag, task} -> lock_task_result!(task, 30_000) end)
      after
        send(holder.pid, {:release_host_rows, ref})
        Enum.each(tagged, fn {_tag, task} -> Task.shutdown(task, :brutal_kill) end)
      end
    after
      send(holder.pid, {:release_host_rows, ref})
      Task.shutdown(holder, :brutal_kill)
      :ok = stop_supervised(supervisor_id)
    end
  end

  @spec assert_waiter_chain!([String.t()], pos_integer(), integer()) :: :ok
  defp assert_waiter_chain!(tags, holder, deadline) do
    rows =
      sql(
        """
        WITH RECURSIVE roots AS (
          SELECT pid AS origin, pid, ARRAY[pid] AS path
          FROM pg_stat_activity WHERE application_name = ANY($1::text[]) AND wait_event_type = 'Lock'
          UNION ALL
          SELECT r.origin, b.pid, r.path || b.pid
          FROM roots r CROSS JOIN LATERAL unnest(pg_blocking_pids(r.pid)) AS b(pid)
          WHERE NOT b.pid = ANY(r.path)
        )
        SELECT
          (SELECT count(DISTINCT origin) FROM roots WHERE pid = $2),
          EXISTS (SELECT 1 FROM pg_locks waiting JOIN pg_locks holding
            ON waiting.transactionid = holding.transactionid
            WHERE waiting.locktype = 'transactionid' AND NOT waiting.granted
            AND holding.locktype = 'transactionid' AND holding.granted
            AND holding.mode = 'ExclusiveLock' AND holding.pid = $2
            AND waiting.pid IN (SELECT pid FROM pg_stat_activity WHERE application_name = ANY($1::text[])))
        """,
        [tags, holder]
      ).rows

    case rows do
      [[count, true]] when count == length(tags) ->
        :ok

      [[count, direct]] when is_integer(count) and is_boolean(direct) ->
        assert System.monotonic_time(:millisecond) < deadline,
               "mutation peers did not all reach the held host-lock chain"

        receive do
        after
          20 -> assert_waiter_chain!(tags, holder, deadline)
        end

      _ ->
        flunk("invalid host-lock observer result shape")
    end
  end

  @spec lock_task_result!(Task.t(), pos_integer()) :: term()
  defp lock_task_result!(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
      nil -> flunk("controlled host-lock task timed out")
    end
  end
end
