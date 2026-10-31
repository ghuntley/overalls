# Run alone in a Marshall test BEAM with the instrumenter's output selected by
# CLONE_REPORT_INSTRUMENTED; it replaces HostReports only in this disposable VM.
Code.require_file("report_rejection.ex", __DIR__)
original = Path.expand("../../../../../marshall/lib/marshall/compute/host_reports.ex", __DIR__)
instrumented = System.fetch_env!("CLONE_REPORT_INSTRUMENTED")
Application.put_env(:marshall, :clone_report_sources, {original, instrumented})
previous = Code.get_compiler_option(:ignore_module_conflict)
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file(instrumented)
Code.put_compiler_option(:ignore_module_conflict, previous)

defmodule Marshall.CloneReportRejectionFixtureTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  import Bitwise
  alias Marshall.CloneReportRejectionFixture, as: Fixture
  alias Marshall.Compute.{Credentials, Host, Ledger, ProvisionerControl, StoragePool}
  @moduletag :tmp_dir

  setup %{tmp_dir: runtime} do
    old = System.get_env("RELEASE_TMP")
    System.put_env("RELEASE_TMP", runtime)

    on_exit(fn ->
      if old, do: System.put_env("RELEASE_TMP", old), else: System.delete_env("RELEASE_TMP")
    end)

    root = Path.join(runtime, "clone-report-rejections")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.write!(Path.join(root, "armed"), "")
    File.chmod!(Path.join(root, "armed"), 0o600)
    %{root: root}
  end

  # @cc [owner:ghuntley,label:verification] report-instrumentation-semantic-equivalence
  # Removing only the diagnostic check/reject calls MUST recover the original
  # complete source AST. This protects original conditions, order, short-circuit
  # operators, single evaluation, returned values and rollback sites together.
  test "erasing diagnostic calls recovers the exact original AST" do
    {original, instrumented} = Application.fetch_env!(:marshall, :clone_report_sources)
    expected = original |> File.read!() |> Code.string_to_quoted!() |> erase_diagnostics()
    actual = instrumented |> File.read!() |> Code.string_to_quoted!() |> erase_diagnostics()
    assert actual == expected
  end

  test "original and instrumented exchange return the same acceptance and refusals" do
    {original, instrumented} = Application.fetch_env!(:marshall, :clone_report_sources)

    try do
      results =
        for path <- [original, instrumented] do
          reload(path)
          source = host_fixture()
          {token, session, epoch} = connection(source.host)
          report = %{source.report | sampled_at: Ledger.now()}

          message = %{
            session_id: session,
            epoch: epoch,
            report: report,
            outcomes: [],
            acknowledgements: []
          }

          accepted = ProvisionerControl.exchange_execution(token, message)
          assert {:ok, %{"commands" => [], "outcome_acknowledgements" => []}} = accepted
          assert [%{report_sequence: 1}] = Ledger.read!(Host, id: source.host.id)

          [
            {:ok, :accepted},
            ProvisionerControl.exchange_execution(token, message),
            ProvisionerControl.exchange_execution(token, %{message | epoch: epoch + 1}),
            ProvisionerControl.exchange_execution(token, %{
              message
              | report: %{report | sequence: 2, pools: []}
            }),
            ProvisionerControl.exchange_execution(token, %{
              message
              | report: %{
                  report
                  | sequence: 2,
                    sampled_at:
                      DateTime.add(
                        Ledger.now(),
                        -Marshall.Compute.HostLiveness.authority_ms() - 1000,
                        :millisecond
                      )
                }
            })
          ]
        end

      assert [baseline, observed] = results
      assert baseline == observed

      assert baseline == [
               {:ok, :accepted},
               {:error, :stale_report},
               {:error, :stale_connection},
               {:error, :invalid_report},
               {:error, :invalid_report}
             ]
    after
      reload(instrumented)
    end
  end

  test "first false predicate survives throw and preserves short circuit and result", %{
    root: root
  } do
    parent = self()

    predicate = fn ->
      send(parent, :once)
      false
    end

    assert catch_throw(
             if Fixture.check(:sample_expired, predicate.(), 5001) and
                  Fixture.check(:pool_schema, raise("must not evaluate"), 5001),
                do: :accepted,
                else: throw(:original_rollback)
           ) == :original_rollback

    assert_received :once
    refute_received :once
    assert read(root, :sample_expired) == %{"stage" => "sample_expired", "sample_age_ms" => 5001}
    refute File.exists?(Path.join(root, "pool_schema.json"))
    assert Fixture.check(:sample_future, true, -1000)
    assert :ok == Fixture.reject(:sample_expired, 9999)
    assert read(root, :sample_expired)["sample_age_ms"] == 5001
  end

  test "disabled, malformed permissions and unwritable sinks preserve rejection", %{root: root} do
    File.rm!(Path.join(root, "armed"))
    refute Fixture.check(:sample_future, false, -1001)
    assert File.ls!(root) == []
    File.write!(Path.join(root, "armed"), "")
    File.chmod!(Path.join(root, "armed"), 0o644)
    refute Fixture.check(:sample_future, false, -1001)
    File.chmod!(Path.join(root, "armed"), 0o600)
    File.chmod!(root, 0o755)
    refute Fixture.check(:sample_future, false, -1001)
    File.chmod!(root, 0o700)
    File.mkdir!(Path.join(root, "sample_future.json.tmp"))
    refute Fixture.check(:sample_future, false, -1001)
    refute File.exists?(Path.join(root, "sample_future.json"))
  end

  test "concurrent publication stays private, finite and bounded", %{root: root} do
    stages =
      ~w(report_shape sample_future sample_expired pool_schema pool_observed_at pool_set storage_identity capacity_schema capacity_bounds image_ids architecture)a

    for stage <- stages do
      age = if stage == :report_shape, do: nil, else: -1234

      1..32
      |> Task.async_stream(fn _ -> Fixture.reject(stage, age) end, max_concurrency: 8)
      |> Enum.each(fn result -> assert result == {:ok, :ok} end)
    end

    files = File.ls!(root)
    assert length(files) == 12
    refute Enum.any?(files, &String.ends_with?(&1, ".tmp"))

    for stage <- stages do
      path = Path.join(root, Atom.to_string(stage) <> ".json")
      assert File.stat!(path).size <= 160
      assert band(File.stat!(path).mode, 0o777) == 0o600
      assert Map.keys(read(root, stage)) |> Enum.sort() == ["sample_age_ms", "stage"]
    end
  end

  test "authenticated exchange preserves rollback, records exact guard age and recovers", %{
    root: root
  } do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)
    {token, session, epoch} = connection(source.host)
    before_host = Ledger.read!(Host, id: source.host.id)
    before_pool = Ledger.read!(StoragePool, id: source.pool.id)
    before_clock = Ledger.now()

    sampled_at =
      DateTime.add(
        before_clock,
        -Marshall.Compute.HostLiveness.authority_ms() - 1000,
        :millisecond
      )

    report = %{source.report | sampled_at: sampled_at}

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    message = %{
      session_id: session,
      epoch: epoch,
      report: report,
      outcomes: [outcome],
      acknowledgements: []
    }

    assert {:error, :invalid_report} = ProvisionerControl.exchange_execution(token, message)
    after_clock = Ledger.now()
    assert Ledger.read!(Host, id: source.host.id) == before_host
    assert Ledger.read!(StoragePool, id: source.pool.id) == before_pool
    assert [] == Ledger.read!(Marshall.Compute.PhysicalOutcome, id: outcome.id)

    assert [%{observed_state: :pending}] =
             Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id)

    assert %{"stage" => "sample_expired", "sample_age_ms" => age} = read(root, :sample_expired)
    assert age >= DateTime.diff(before_clock, sampled_at, :millisecond)
    assert age <= DateTime.diff(after_clock, sampled_at, :millisecond)

    valid = %{message | report: %{report | sampled_at: Ledger.now()}}
    assert {:ok, _} = ProvisionerControl.exchange_execution(token, valid)
    assert [_] = Ledger.read!(Marshall.Compute.PhysicalOutcome, id: outcome.id)

    assert [%{observed_state: :running}] =
             Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id)

    assert read(root, :sample_expired)["sample_age_ms"] == age
    assert Enum.sort(File.ls!(root)) == ["armed", "sample_expired.json"]
  end

  test "guard ordering distinguishes malformed shape, future, pool and later refusals", %{
    root: root
  } do
    source = host_fixture()
    {token, session, epoch} = connection(source.host)
    base = %{source.report | sampled_at: Ledger.now()}

    reports = [
      {:report_shape, %{base | sequence: 0, sampled_at: :malformed}},
      {:sample_future,
       %{base | sampled_at: DateTime.add(Ledger.now(), 10, :second), pools: [nil]}},
      {:pool_schema, %{base | pools: [nil]}},
      {:pool_observed_at,
       put_in(
         base,
         [:pools, Access.at(0), :observed_at],
         DateTime.add(base.sampled_at, 1, :second)
       )},
      {:pool_set, %{base | pools: []}},
      {:storage_identity, put_in(base, [:pools, Access.at(0), :storage, :dataset_guid], "999")},
      {:capacity_schema, %{base | capacity: %{}}},
      {:capacity_bounds, put_in(base, [:capacity, "cpu_headroom_millicores"], 999_000)},
      {:image_ids, put_in(base, [:inventory, "images"], ["invalid"])},
      {:architecture, put_in(base, [:inventory, "architecture"], "aarch64")}
    ]

    for {stage, report} <- reports do
      assert {:error, :invalid_report} =
               ProvisionerControl.exchange_execution(token, %{
                 session_id: session,
                 epoch: epoch,
                 report: report,
                 outcomes: [],
                 acknowledgements: []
               })

      assert read(root, stage)["stage"] == Atom.to_string(stage)
      if stage == :report_shape, do: assert(read(root, stage)["sample_age_ms"] == nil)
      File.rm!(Path.join(root, Atom.to_string(stage) <> ".json"))
      assert File.ls!(root) == ["armed"]
    end
  end

  @spec connection(Host.t()) :: {String.t(), String.t(), pos_integer()}
  defp connection(host) do
    {:ok, issued} = Credentials.rotate(host.id, 3600)
    session = Ash.UUID.generate()

    {:ok, reply} =
      ProvisionerControl.open_execution(issued.token, %{
        session_id: session,
        machine_id: host.machine_id
      })

    {issued.token, session, reply["epoch"]}
  end

  @spec reload(Path.t()) :: :ok
  defp reload(path) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      [{Marshall.Compute.HostReports, _}] = Code.compile_file(path)
      :ok
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  @spec read(Path.t(), Fixture.stage()) :: map()
  defp read(root, stage),
    do: root |> Path.join(Atom.to_string(stage) <> ".json") |> File.read!() |> JSON.decode!()

  @spec erase_diagnostics(Macro.t()) :: Macro.t()
  defp erase_diagnostics(ast) do
    ast
    |> Macro.prewalk(fn
      {{:., _, [{:__aliases__, _, [:Marshall, :CloneReportRejectionFixture]}, :check]}, _,
       [_stage, result, _age]} ->
        result

      {:__block__, _,
       [
         {{:., _, [{:__aliases__, _, [:Marshall, :CloneReportRejectionFixture]}, :reject]}, _, _},
         rollback
       ]} ->
        rollback

      node ->
        node
    end)
    |> Macro.prewalk(fn
      {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
      node -> node
    end)
  end
end
