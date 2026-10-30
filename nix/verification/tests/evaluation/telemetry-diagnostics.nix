{ pkgs }:
let
  yaml = pkgs.formats.yaml {};
  otel = ../../../domains/system/otel-fleet;
  # The fixture deployment roster: central host first, then the worker.
  fixtureHosts = [ "panterloons" "dungarees" ];
  ruleGroups = hosts: (import (otel + "/rules.nix") { inherit hosts; }).groups
    ++ (import (otel + "/diagnostics.nix") { inherit hosts; }).groups
    ++ (import (otel + "/infrastructure-rules.nix") { inherit hosts; }).groups;
  rulesFor = hosts: yaml.generate "telemetry-diagnostics-rules-${builtins.concatStringsSep "-" hosts}.yml" {
    groups = ruleGroups hosts;
  };
  rules = rulesFor fixtureHosts;
  sourcesFor = hosts: builtins.filter (s: builtins.elem s.id [ "brady" "marshall_ready" ])
    (import (otel + "/objectives.nix") { inherit hosts; });
  sources = sourcesFor fixtureHosts;
  collectorSeries = hosts: builtins.map (address:
    { series = ''up{job="overalls-otel",instance="${address}:9464"}''; values = "1+0x20"; })
    (import (otel + "/roster-addresses.nix") hosts);
  scenarioFor = hosts: source: { code, missing ? false, stale ? false, warm ? false, gap ? false, traffic ? 0 }: {
    interval = "30s";
    input_series = collectorSeries hosts ++ builtins.concatMap (host:
      let labels = ''overalls_telemetry_origin="application",service_name="${source.id}",host_name="${host}"'';
          series = suffix: values: { series = "overalls_outer_${source.id}_${suffix}{${labels}}"; inherit values; };
      in [
        (series "requests_total" "0+${toString traffic}x20")
        (series "source_start_time" (if warm then "500+0x20" else "1+0x20"))
        (series "source_sample_time" (if stale then "1+0x20" else "0+30x20"))
        (series "source_coverage_start_time" (if gap then "500+0x20" else "1+0x20"))
      ]) (if missing then [] else source.hosts);
    promql_expr_test = [{
      expr = ''overalls:slo_status{slo="${source.id}",window="candidate"}'';
      eval_time = "10m";
      exp_samples = [{ labels = ''overalls:slo_status{slo="${source.id}",window="candidate"}''; value = code; }];
    } {
      expr = ''overalls:slo_status{slo="${source.id}",window="objective"}'';
      eval_time = "10m";
      exp_samples = [{ labels = ''overalls:slo_status{slo="${source.id}",window="objective"}'';
        value = if code == 5 || code == 10 then 6 else code;
      }];
    }];
  };
  scenario = scenarioFor fixtureHosts;
  # @cc [owner:ghuntley,label:verification;deployment] telemetry-roster-per-deployment
  # A deployment's rules MUST expect exactly its own roster: no host label or
  # collector from another deployment, and a collector count equal to the roster.
  rosterTest = hosts: let
    text = builtins.toJSON (ruleGroups hosts ++ (import (otel + "/objective-rules.nix") { inherit hosts; }).groups
      ++ [ (import (otel + "/slo-catalog.nix") { inherit hosts; }) ]);
    foreign = builtins.filter (host: !builtins.elem host hosts) [ "dungarees" "panterloons" "salopettes" ];
    leaks = builtins.filter (host: contains ''host_name=\"${host}\"'') foreign;
    collectors = toString (builtins.length hosts);
    # Regex-based hasInfix overflows the evaluator stack on megabyte rule text.
    contains = needle: builtins.replaceStrings [ needle ] [ "" ] text != text;
  in assert leaks == [];
    assert contains ''overalls_telemetry_origin=\"\"}) == ${collectors}'';
    assert builtins.length hosts == 1 -> !contains "10.90.0.2";
    yaml.generate "telemetry-roster-${builtins.concatStringsSep "-" hosts}-tests.yml" {
      fuzzy_compare = true;
      rule_files = [ (rulesFor hosts) ]; evaluation_interval = "30s";
      tests = builtins.concatMap (source: builtins.map (scenarioFor hosts source) [
        { code = 1; missing = true; }
        { code = 2; stale = true; }
        { code = 5; }
        { code = 10; traffic = 10; }
      ]) (sourcesFor hosts);
    };
  rosterTests = builtins.map rosterTest [ [ "panterloons" ] [ "panterloons" "dungarees" ] ];
  # The unified Underclass histogram uses the ordinary source clock and
  # request counter; an overflow beyond 86400 s reports status 9.
  latencyCase = clock: visible: traffic: status: overflowCase traffic clock visible traffic status;
  overflowCase = overflow: clock: visible: traffic: status: {
    interval = "30s";
    input_series = [
      { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x20"; }
      { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "1+0x20"; }
    ] ++ builtins.concatMap (host:
      let labels = ''overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"'';
          point = suffix: values: { series = "overalls_outer_underclass_proxy_${suffix}{${labels}}"; inherit values; };
          bucket = le: values: { series = ''overalls_outer_underclass_proxy_duration_seconds_bucket{${labels},le="${le}"}''; inherit values; };
      in [
        (point "requests_total" "0+${toString traffic}x20") (point "successes_total" "0+${toString traffic}x20")
        (point "source_start_time" "1+0x20") (point "source_sample_time" clock)
        (point "source_coverage_start_time" "1+0x20")
        (point "duration_seconds_count" "0+${toString traffic}x20")
        (bucket "10.0" "0+0x20") (bucket "30.0" "0+${toString traffic}x20")
        (bucket "86400.0" "0+${toString traffic}x20") (bucket "+Inf" "0+${toString overflow}x20")
      ]) [ "panterloons" "dungarees" ];
    promql_expr_test = [{
      expr = "overalls:underclass_proxy_candidate_duration:p95_5m";
      eval_time = "10m";
      exp_samples = pkgs.lib.optional visible { labels = "overalls:underclass_proxy_candidate_duration:p95_5m"; value = 29; };
    } {
      expr = ''overalls:slo_status{slo="underclass_proxy",window="latency"}'';
      eval_time = "10m";
      exp_samples = [{ labels = ''overalls:slo_status{slo="underclass_proxy",window="latency"}''; value = status; }];
    }];
  };
  sdkCase = { stale ? false, missing ? false, isolated ? false, reset ? false }: {
    interval = "30s";
    input_series = [{
      series = ''overalls_trace_spool_snapshot_valid{host_name="panterloons",producer="galileo"}'';
      values = "1+0x20";
    }] ++ pkgs.lib.optionals (!missing) (map (entry: {
      series = ''overalls_gauge_trace_${entry.name}{host_name="panterloons",service="galileo",unit="galileo.service"}'';
      inherit (entry) values;
    }) [
      { name = "available"; values = "1+0x20"; }
      { name = "pending"; values = "17+0x20"; }
      { name = "observed_at_seconds"; values = if stale then "1+0x20" else "0+30x20"; }
      { name = "queue_dropped"; values = if isolated then "0 1+0x19" else if reset then "5 0+0x19" else "0+0x20"; }
      { name = "export_failed"; values = if isolated then "0 1+0x19" else if reset then "5 0+0x19" else "0+0x20"; }
    ]);
    alert_rule_test = (map (entry: {
      alertname = entry.name;
      eval_time = "2m";
      exp_alerts = pkgs.lib.optional isolated {
        exp_labels = { host_name = "panterloons"; service = "galileo"; unit = "galileo.service";
          category = "infrastructure"; severity = "warning";
        };
        exp_annotations.summary = entry.summary;
      };
    }) [
      { name = "OverallsSDKQueueRefused"; summary = "An application SDK refused volatile trace admission"; }
      { name = "OverallsSDKExportFailed"; summary = "An application SDK failed a trace custody handoff"; }
    ]) ++ [{
      alertname = "OverallsSDKHealthStale";
      eval_time = "10m";
      exp_alerts = pkgs.lib.optional (stale && !missing) {
        exp_labels = { host_name = "panterloons"; service = "galileo"; unit = "galileo.service";
          category = "infrastructure"; severity = "warning";
        };
        exp_annotations.summary = "SDK health observations are stale or ahead of the trusted clock";
      };
    } {
      alertname = "OverallsSDKHealthMissing";
      eval_time = "10m";
      exp_alerts = pkgs.lib.optional missing {
        exp_labels = { host_name = "panterloons"; producer = "galileo"; unit = "galileo.service";
          category = "infrastructure"; severity = "warning";
        };
        exp_annotations.summary = "A configured trace producer has no SDK health observation";
      };
    }];
  };
  browserCase = service: { idle ? false, success ? false, unknown ? null }: let
    labels = ''overalls_telemetry_origin="application",service_name="${service}",host_name="panterloons"'';
    point = suffix: values: { series = "overalls_outer_${service}_${suffix}{${labels}}"; inherit values; };
    completions = "0+0x9 1+0x9 2+0x9 3+0x2";
    diagnostic = kind: value: {
      expr = ''overalls:browser_probe_diagnostic{slo="${service}",kind="${kind}"}'';
      eval_time = "16m";
      exp_samples = pkgs.lib.optional (unknown == null) {
        labels = ''overalls:browser_probe_diagnostic{slo="${service}",kind="${kind}"}'';
        inherit value;
      };
    };
  in {
    interval = "30s";
    input_series = [
      { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x32"; }
      { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}'';
        values = if unknown == "collector" then "0+0x32" else "1+0x32"; }
      (point "requests_total" (if idle then "0+0x32" else completions))
      (point "successes_total" (if success then completions else "0+0x32"))
      (point "failures_total" (if idle || success then "0+0x32" else completions))
      (point "source_start_time" (if unknown == "warm" then "800+0x32" else "1+0x32"))
      (point "source_sample_time" (if unknown == "stale" then "1+0x32" else "0+30x32"))
      (point "source_coverage_start_time" (if unknown == "gap" || unknown == "warm" then "800+0x32" else "1+0x32"))
    ];
    promql_expr_test = [
      (diagnostic "failures_without_success_15m" (if idle || success then 0 else 1))
      (diagnostic "no_completion_10m" (if idle then 1 else 0))
    ];
  };
  test = yaml.generate "telemetry-diagnostics-tests.yml" {
    fuzzy_compare = true;
    rule_files = [ rules ]; evaluation_interval = "30s";
    tests = builtins.concatMap (source: builtins.map (scenario source) [
      { code = 1; missing = true; }
      { code = 2; stale = true; }
      { code = 3; warm = true; }
      { code = 4; gap = true; }
      { code = 5; }
      { code = 10; traffic = 1; }
      { code = 10; traffic = 10; }
      { code = 2; stale = true; traffic = 10; }
    ]) sources ++ [
      (latencyCase "0+30x20" true 2 0)
      (latencyCase "1+0x20" false 2 2)
      (latencyCase "3+30x20" false 2 2)
      (latencyCase "_" false 0 1)
      (latencyCase "1+0x20" false 0 2)
      (latencyCase "0+30x20" false 0 5)
      (overflowCase 3 "0+30x20" false 2 9)
      (sdkCase {})
      (sdkCase { isolated = true; })
      (sdkCase { reset = true; })
      (sdkCase { stale = true; })
      (sdkCase { missing = true; })
    ] ++ builtins.concatMap (service: builtins.map (browserCase service) [
      {} { idle = true; } { success = true; }
      { unknown = "collector"; } { unknown = "stale"; }
      { unknown = "warm"; } { unknown = "gap"; }
    ]) [ "vscode_browser_nixos" "vscode_browser_ubuntu" ];
  };
in pkgs.runCommand "overalls-telemetry-diagnostics" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
  promtool check rules ${rules}
  promtool test rules ${test}
  ${pkgs.lib.concatMapStringsSep "\n" (test: "promtool test rules ${test}") rosterTests}
  touch "$out"
''
