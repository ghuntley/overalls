defmodule Marshall.ObservabilityTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  test "aggregation retains only bounded numeric observations" do
    if Process.whereis(Marshall.Observability) == nil,
      do: start_supervised!(Marshall.Observability)

    Marshall.Observability.snapshot()

    Marshall.Observability.observe(
      [:marshall, :control, :request],
      %{duration: 1_000_000},
      %{status: 503, sql: "secret SQL", credential: "secret token", vm_id: "unbounded"},
      nil
    )

    snapshot = Marshall.Observability.snapshot()
    assert snapshot["control_count"] == 1
    assert snapshot["control_errors"] == 1
    assert Enum.all?(Map.values(snapshot), &is_number/1)
    refute inspect(snapshot) =~ "secret"
    refute Map.has_key?(Marshall.Observability.snapshot(), "control_count")
  end

  test "terminal authority and input aggregation keeps only counts and durations" do
    if Process.whereis(Marshall.Observability) == nil,
      do: start_supervised!(Marshall.Observability)

    Marshall.Observability.snapshot()

    for status <- [200, 503] do
      Marshall.Observability.observe(
        [:marshall, :terminal, :authority],
        %{duration: 2_000_000},
        %{status: status, session_id: "secret-session", bytes: "secret-input"},
        nil
      )
    end

    Marshall.Observability.observe([:marshall, :terminal, :input], %{duration: 0}, %{}, nil)
    snapshot = Marshall.Observability.snapshot()
    assert snapshot["terminal_authority_count"] == 2
    assert snapshot["terminal_authority_errors"] == 1
    assert snapshot["terminal_input_count"] == 1
    assert Marshall.Observability.sanitize_metrics(snapshot)["terminal_authority_count"] == 2
    refute inspect(snapshot) =~ "secret"
  end

  test "SSH gateway aggregation excludes all connection and credential metadata" do
    if Process.whereis(Marshall.Observability) == nil,
      do: start_supervised!(Marshall.Observability)

    Marshall.Observability.snapshot()

    Marshall.Observability.observe(
      [:marshall, :ssh, :request],
      %{duration: 1_000_000},
      %{
        status: 503,
        session_token: "secret-session",
        gateway_token: "secret-gateway",
        approval_path: "secret-approval"
      },
      nil
    )

    snapshot = Marshall.Observability.snapshot()
    assert snapshot["ssh_count"] == 1
    assert snapshot["ssh_errors"] == 1
    assert Enum.all?(Map.values(snapshot), &is_number/1)
    refute inspect(snapshot) =~ "secret"
  end

  test "current snapshot is non-destructive while interval snapshot resets counters" do
    if Process.whereis(Marshall.Observability) == nil,
      do: start_supervised!(Marshall.Observability)

    Marshall.Observability.snapshot()
    Marshall.Observability.observe([:oban, :job, :stop], %{duration: 1_000}, %{}, nil)
    assert Marshall.Observability.snapshot(:current)["jobs_count"] == 1
    assert Marshall.Observability.snapshot(:current)["jobs_count"] == 1
    assert Marshall.Observability.snapshot()["jobs_count"] == 1
    refute Map.has_key?(Marshall.Observability.snapshot(:current), "jobs_count")
  end

  def log(event, %{config: owner}) do
    send(owner, {:metric_event, event})
    :ok
  end

  test "retired metric-summary reports translate to a redacted category" do
    report = %{
      event: "metrics.summary",
      service: "marshall",
      interval_seconds: 60,
      metrics: %{"beam_processes" => 7}
    }

    assert {:ok, "OTP runtime_report (process data redacted)", _} =
             Marshall.OTPReports.translate(:debug, :info, :report, {:logger, report})
  end

  test "actual metric emission survives formatted logging and source handlers" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok = Marshall.OTPReports.install()

    if Process.whereis(Marshall.Observability) == nil,
      do: start_supervised!(Marshall.Observability)

    :ok = :logger.add_handler(:marshall_metric_test, __MODULE__, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:marshall_metric_test) end)

    output =
      ExUnit.CaptureLog.capture_log(
        [formatter: {LoggerJSON.Formatters.Basic, metadata: [:event, :beam_processes]}],
        fn ->
          send(Marshall.Observability, :report)
          :sys.get_state(Marshall.Observability)
        end
      )

    assert output =~ "Runtime metrics observed"
    assert output =~ "beam_processes"

    assert_receive {:metric_event,
                    %{meta: %{event: "marshall.runtime_metrics", beam_processes: processes}}}

    assert is_integer(processes) and processes > 0
  end

  property "metric sanitization keeps only bounded numeric allowlisted values" do
    entries =
      draw(
        "entries",
        list(tuple({binary(0, 32), one_of([integer(-1_000, 10_000), binary(0, 32)])}),
          min: 0,
          max: 16
        )
      )

    metrics = Map.new(entries)
    sanitized = Marshall.Observability.sanitize_metrics(metrics)

    assert Enum.all?(sanitized, fn {key, value} ->
             is_binary(key) and is_number(value) and value >= 0 and value <= 9_007_199_254_740_991
           end)

    refute Enum.any?(Map.keys(sanitized), &String.contains?(&1, "secret"))
  end
end
