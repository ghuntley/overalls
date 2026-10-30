{ pkgs }:
let
  # The fixture deployment roster: central host first, then the worker.
  fixtureHosts = [ "panterloons" "dungarees" ];
  yaml = pkgs.formats.yaml {};
  candidateQuery = import ../../../domains/system/otel-fleet/candidate-query.nix { hosts = fixtureHosts; };
  objectiveQuery = import ../../../domains/system/otel-fleet/objective-query.nix { hosts = fixtureHosts; };
  lifecycleSources = builtins.filter (source: builtins.elem source.service [ "marshall_ready" "lilly_physical" "porsche_physical" ])
    (import ../../../domains/system/otel-fleet/candidate-sources.nix);
  lifecycleCase = source: { host, clock, visible }: {
    interval = "30s";
    input_series = [
      { series = ''overalls_outer_${source.service}_requests_total{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${host}"}''; values = "0+10x20"; }
      { series = ''overalls_outer_${source.service}_successes_total{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${host}"}''; values = "0+5x20"; }
      { series = ''overalls_outer_${source.service}_source_start_time{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${host}"}''; values = "1+0x20"; }
      { series = ''overalls_outer_${source.service}_source_sample_time{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${host}"}''; values = clock; }
    ];
    promql_expr_test = [{
      expr = "overalls:${source.ratio}:ratio5m";
      eval_time = "10m";
      exp_samples = pkgs.lib.optional visible { labels = "overalls:${source.ratio}:ratio5m"; value = 0.5; };
    }];
  };
  underclassReady = import ../../../domains/system/otel-fleet/underclass-ready.nix { hosts = fixtureHosts; };
  # Existing source-marker fixtures represent a live producer unless they
  # explicitly supply a frozen source sampling clock. Keep cadence separate
  # from Prometheus scrape freshness to exercise retained collector values.
  withSourceSamples = seconds: steps: scenario:
    let
      clockName = name: builtins.replaceStrings [ "_source_start_time{" "overalls_underclass_monitor_ready{" ] [ "_source_sample_time{" "overalls_underclass_monitor_sample_time{" ] name;
      markers = builtins.filter (point:
        (pkgs.lib.hasInfix "_source_start_time{" point.series
          || pkgs.lib.hasInfix "overalls_underclass_monitor_ready{" point.series)
        && !(builtins.any (other: other.series == clockName point.series) scenario.input_series)
      ) scenario.input_series;
      coverageName = name: builtins.replaceStrings [ "_source_start_time{" ] [ "_source_coverage_start_time{" ] name;
      coverageMarkers = builtins.filter (point:
        pkgs.lib.hasInfix "_source_start_time{" point.series
        && !(builtins.any (other: other.series == coverageName point.series) scenario.input_series)
      ) scenario.input_series;
    in scenario // {
      input_series = scenario.input_series ++ builtins.map (point: {
        series = clockName point.series;
        values = "0+${toString seconds}x${toString steps}";
      }) markers ++ builtins.map (point: {
        series = coverageName point.series;
        values = point.values;
      }) coverageMarkers;
    };
  proxyCase = { hosts, stale ? false, marker ? true }: {
    interval = "30s";
    input_series = builtins.concatMap (host: [
      { series = ''overalls_outer_underclass_proxy_requests_total{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = if stale && host == "dungarees" then "0+10x16 _ _ _ _" else "0+10x20"; }
      { series = ''overalls_outer_underclass_proxy_successes_total{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = "0+5x20"; }
    ] ++ pkgs.lib.optional marker {
      series = ''overalls_outer_underclass_proxy_source_start_time{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
      values = "1+0x20";
    }) hosts;
    promql_expr_test = [{
      expr = "overalls:underclass_proxy_candidate_completion:ratio5m";
      eval_time = "10m";
      exp_samples = pkgs.lib.optional (hosts == [ "panterloons" "dungarees" ] && !stale && marker) {
        labels = "overalls:underclass_proxy_candidate_completion:ratio5m";
        value = 0.5;
      };
    }];
  };
  # @cc [owner:ghuntley,label:verification;reliability] underclass-unified-p95-rule
  # The Underclass p95 MUST read the single 15-bound duration histogram and
  # its ordinary request counter. Day-scale durations stay finite; overflow,
  # partial samples, a missing 86400-second bucket (retired seven-bound shape),
  # warmup and a missing replica MUST withhold the candidate.
  underclassLatencyCase = { name, value ? null, hosts ? [ "panterloons" "dungarees" ], start ? "1+0x20",
      counted ? 10, finite ? 10, lastBucket ? true, zero ? "10.0", bucket ? "30.0" }: {
    interval = "30s";
    input_series = builtins.concatMap (host: let
      labels = ''overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"'';
      point = suffix: values: { series = "overalls_outer_underclass_proxy_${suffix}{${labels}}"; inherit values; };
      le = bound: values: { series = ''overalls_outer_underclass_proxy_duration_seconds_bucket{${labels},le="${bound}"}''; inherit values; };
    in [
      (point "requests_total" "0+10x20") (point "successes_total" "0+10x20")
      (point "source_start_time" start)
      (point "duration_seconds_count" "0+${toString counted}x20")
      (le zero "0+0x20") (le bucket "0+${toString finite}x20")
      (le "+Inf" "0+${toString counted}x20")
    ] ++ pkgs.lib.optionals (lastBucket && bucket != "86400.0") [ (le "86400.0" "0+${toString finite}x20") ]) hosts;
    promql_expr_test = [{
      expr = "overalls:underclass_proxy_candidate_duration:p95_5m";
      eval_time = "10m";
      exp_samples = pkgs.lib.optional (value != null) {
        labels = "overalls:underclass_proxy_candidate_duration:p95_5m"; inherit value;
      };
    }];
  };
  cachedProxyCase = { clock, visible, coverage ? "-604800+0x20" }: {
    interval = "30s";
    input_series = [
      { series = "overalls:slo_underclass_proxy:ratio7d"; values = "1+0x20"; }
      { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x20"; }
      { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "1+0x20"; }
    ] ++ builtins.concatMap (host: [
      { series = ''overalls_outer_underclass_proxy_requests_total{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = "7+0x20"; }
      { series = ''overalls_outer_underclass_proxy_source_start_time{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = "-604800+0x20"; }
      { series = ''overalls_outer_underclass_proxy_source_coverage_start_time{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = coverage; }
      { series = ''overalls_outer_underclass_proxy_source_sample_time{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = clock; }
    ]) [ "panterloons" "dungarees" ];
    promql_expr_test = [{
      expr = objectiveQuery { id = "underclass_proxy"; kind = "candidate"; };
      eval_time = "10m";
      exp_samples = pkgs.lib.optional visible {
        labels = "overalls:slo_underclass_proxy:ratio7d";
        value = 1;
      };
    }];
  };
  cachedMonitorCase = { clock, visible }: {
    interval = "30s";
    input_series = builtins.concatMap (host: [
      { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="${host}"}'';
        values = "1+0x20"; }
      { series = ''overalls_underclass_monitor_sample_time{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="${host}"}'';
        values = clock; }
    ]) [ "panterloons" "dungarees" ];
    promql_expr_test = [{
      expr = "overalls:underclass_monitor_local_readiness:ratio5m";
      eval_time = "10m";
      exp_samples = pkgs.lib.optional visible {
        labels = "overalls:underclass_monitor_local_readiness:ratio5m";
        value = 1;
      };
    }];
  };
  cachedIngressCase = { health, visible }: {
    interval = "30s";
    input_series = [
      { series = "overalls:slo_ingress:ratio7d"; values = "1+0x20"; }
      { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x20"; }
      { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "1+0x20"; }
      { series = ''up{job="overalls-ingress-source",instance="127.0.0.1:8405"}''; values = health; }
    ];
    promql_expr_test = [{
      expr = objectiveQuery { id = "ingress"; kind = "ingress"; };
      eval_time = "10m";
      exp_samples = pkgs.lib.optional visible { labels = "overalls:slo_ingress:ratio7d"; value = 1; };
    }];
  };
  rules = yaml.generate "overalls-otel-slo-rules.yml" {
    groups = (import ../../../domains/system/otel-fleet/rules.nix { hosts = fixtureHosts; }).groups
      ++ (import ../../../domains/system/otel-fleet/objective-rules.nix { hosts = fixtureHosts; }).groups;
  };
  longObjectiveGroup = builtins.head ((import ../../../domains/system/otel-fleet/objective-rules.nix {
    # Promtool caps query samples below production Prometheus. Preserve the
    # full seven-day time window with a two-minute synthetic scrape cadence.
    expectedSamples = 5040;
    hosts = fixtureHosts;
  }).groups);
  longRules = yaml.generate "overalls-otel-slo-long-rules.yml" {
    groups = [ (longObjectiveGroup // {
      rules = builtins.filter (rule: builtins.elem (rule.record or "") [
        "overalls:slo_collectors:ratio7d" "overalls:slo_brady:ratio7d" "overalls:slo_underclass_proxy:ratio7d"
        "overalls:slo_marshall_ready:ratio7d" "overalls:slo_lilly_physical:ratio7d" "overalls:slo_porsche_physical:ratio7d"
      ]) longObjectiveGroup.rules;
    }) ];
  };
  longTest = yaml.generate "overalls-otel-slo-long-test.yml" {
    rule_files = [ longRules ];
    evaluation_interval = "1h";
    tests = builtins.map (withSourceSamples 120 5070) [{
      interval = "2m";
      input_series = [
        { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x5070"; }
        { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "1+0x5070"; }
        { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+1x5070"; }
        { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+1x5070"; }
        { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+0x5070"; }
        { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+1x5070"; }
        { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+1x5070"; }
        { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+0x5070"; }
      ] ++ builtins.concatMap (host: builtins.map (metric: {
        series = ''overalls_outer_underclass_proxy_${metric}{overalls_telemetry_origin="application",service_name="underclass_proxy",host_name="${host}"}'';
        values = if metric == "source_start_time" then "0+0x5070" else "0+1x5070";
      }) [ "requests_total" "successes_total" "source_start_time" ]) [ "panterloons" "dungarees" ]
      ++ builtins.concatMap (source: builtins.map (metric: {
        series = ''overalls_outer_${source.service}_${metric}{overalls_telemetry_origin="application",service_name="${source.service}",host_name="panterloons"}'';
        values = if metric == "source_start_time" then "0+0x5070" else "0+1x5070";
      }) [ "requests_total" "successes_total" "source_start_time" ]) lifecycleSources;
      promql_expr_test = [
        { expr = "overalls:slo_collectors:ratio7d"; eval_time = "7d1h";
          exp_samples = [{ labels = "overalls:slo_collectors:ratio7d"; value = 1; }]; }
        { expr = "overalls:slo_brady:ratio7d"; eval_time = "7d1h";
          exp_samples = [{ labels = "overalls:slo_brady:ratio7d"; value = 1; }]; }
        { expr = "overalls:slo_underclass_proxy:ratio7d"; eval_time = "7d1h";
          exp_samples = [{ labels = "overalls:slo_underclass_proxy:ratio7d"; value = 1; }]; }
      ] ++ builtins.map (source: {
        expr = "overalls:slo_${source.service}:ratio7d";
        eval_time = "7d1h";
        exp_samples = [{ labels = "overalls:slo_${source.service}:ratio7d"; value = 1; }];
      }) lifecycleSources;
    } {
      # Scraped up=0 is an observed collector failure, not missing data.
      interval = "2m";
      input_series = [
        { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x5070"; }
        { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "0+0x5070"; }
      ];
      promql_expr_test = [
        { expr = "overalls:slo_collectors:ratio7d"; eval_time = "7d1h";
          exp_samples = [{ labels = "overalls:slo_collectors:ratio7d"; value = 0; }]; }
      ];
    }] ++ [ (withSourceSamples 120 5100 {
      interval = "2m";
      input_series = [
        { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x5100"; }
        { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "1+0x5100"; }
      ] ++ builtins.concatMap (host: [
        { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}''; values = "0+1x5100"; }
        { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}''; values = "0+1x5100"; }
        { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}''; values = "0+0x5100"; }
        { series = ''overalls_outer_brady_source_coverage_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}'';
          values = if host == "dungarees" then "0+0x29 3600+0x5070" else "0+0x5100"; }
      ]) [ "panterloons" "dungarees" ];
      promql_expr_test = [
        { expr = "overalls:slo_brady:ratio7d"; eval_time = "7d1h"; exp_samples = []; }
        { expr = "overalls:slo_brady:ratio7d"; eval_time = "7d2h";
          exp_samples = [{ labels = "overalls:slo_brady:ratio7d"; value = 1; }]; }
      ];
    }) ];
  };
  productionCollectorRule = builtins.head (builtins.filter
    (rule: (rule.record or "") == "overalls:slo_collectors:ratio7d")
    (builtins.head (import ../../../domains/system/otel-fleet/objective-rules.nix { hosts = fixtureHosts; }).groups).rules);
  productionHistoryRule = builtins.head (builtins.filter
    (rule: (rule.record or "") == "overalls:slo_evidence"
      && (rule.labels.slo or "") == "collectors" && (rule.labels.kind or "") == "history_days")
    (builtins.head (import ../../../domains/system/otel-fleet/diagnostics.nix { hosts = fixtureHosts; }).groups).rules);
  cadenceTest = yaml.generate "overalls-otel-production-cadence.yml" {
    rule_files = []; evaluation_interval = "1h";
    tests = [{
      # Promtool's 50,000-sample query cap cannot execute a production seven-day
      # series. Exercise the actual daily denominator at ten-second cadence;
      # the production coverage threshold is checked against that cadence below.
      interval = "10s";
      input_series = builtins.map (host: {
        series = ''up{job="overalls-otel",instance="${host}:9464"}'';
        values = "_ 1+0x8639";
      }) [ "10.90.0.1" "10.90.0.2" ];
      promql_expr_test = [
        { expr = productionHistoryRule.expr; eval_time = "1d";
          exp_samples = [{ labels = "{}"; value = 1; }]; }
      ];
    }];
  };
  burnRules = yaml.generate "overalls-otel-burn-rules.yml" {
    groups = builtins.filter (group: group.name == "overalls-otel-budget-burn")
      (import ../../../domains/system/otel-fleet/objective-rules.nix { hosts = fixtureHosts; }).groups;
  };
  burnAlert = window: {
    exp_labels = { severity = "warning"; slo = "brady"; status = "provisional"; inherit window; };
    exp_annotations.summary = "Provisional brady ${window} error-budget burn";
  };
  burnCase = { name, successes, fast, slow, recovered ? false, sparse ? false, eligible ? true, gap ? false }: {
    inherit name;
    interval = "30s";
    input_series = (builtins.map (host: {
      series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}'';
      values = if sparse then "0+0x819 1+0x20" else "0+1000x840";
    }) [ "panterloons" "dungarees" ]) ++ (builtins.map (host: {
      series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}'';
      values = if sparse then "0+0x840"
        else if recovered then "0+${toString successes}x779 ${toString (successes * 779 + 1000)}+1000x60"
        else "0+${toString successes}x840";
    }) [ "panterloons" "dungarees" ]) ++ (builtins.map (host: {
      series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}'';
      values = "-604800+0x840";
    }) [ "panterloons" "dungarees" ]) ++ [{
      # The alert evaluator consumes an eligible recording. Full seven-day
      # eligibility is independently exercised by longTest above.
      series = "overalls:slo_brady:ratio7d";
      values = if eligible then "0.99+0x840" else "0.99+0x800";
    }] ++ builtins.map (host: {
      series = ''overalls_outer_brady_source_sample_time{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}'';
      values = "0+30x840";
    }) [ "panterloons" "dungarees" ] ++ builtins.map (host: {
      series = ''overalls_outer_brady_source_coverage_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="${host}"}'';
      # Relative fixture clocks place the eligible source seven days before t=0.
      values = if gap && host == "dungarees" then "-604800+0x799 24000+0x40" else "-604800+0x840";
    }) [ "panterloons" "dungarees" ];
    alert_rule_test = builtins.map (window: {
      eval_time = "7h";
      alertname = "OverallsSLOBurn_${window}_brady";
      exp_alerts = if (if window == "fast" then fast else slow) then [ (burnAlert window) ] else [];
    }) [ "fast" "slow" ];
  };
  burnTest = yaml.generate "overalls-otel-burn-test.yml" {
    rule_files = [ burnRules ];
    evaluation_interval = "1m";
    tests = builtins.map burnCase [
      { name = "four percent errors consumes both seven-day budget thresholds"; successes = 960; fast = true; slow = true; }
      { name = "two percent errors consumes only the slow threshold"; successes = 980; fast = false; slow = true; }
      { name = "half percent errors stays below both thresholds"; successes = 995; fast = false; slow = false; }
      { name = "healthy short windows clear both warnings after recovery"; successes = 960; recovered = true; fast = false; slow = false; }
      { name = "one request per host cannot produce burn warnings"; successes = 0; sparse = true; fast = false; slow = false; }
      { name = "expired eligible history cannot produce burn warnings"; successes = 960; eligible = false; fast = false; slow = false; }
      { name = "recording gap suppresses retained eligible burn history after five-minute warmup"; successes = 960; gap = true; fast = false; slow = false; }
    ];
  };
  test = yaml.generate "overalls-otel-slo-rules-test.yml" {
    rule_files = [ rules ];
    evaluation_interval = "30s";
    tests = builtins.map (withSourceSamples 30 20) ([
      (cachedIngressCase { health = "1+0x20"; visible = true; })
      (cachedIngressCase { health = "0+0x20"; visible = false; })
      (cachedIngressCase { health = "1+0x17 _ _ _"; visible = false; })
      (cachedIngressCase { health = "_ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _"; visible = false; })
      (cachedMonitorCase { clock = "1+0x20"; visible = false; })
      (cachedMonitorCase { clock = "0+30x20"; visible = true; })
      (cachedMonitorCase { clock = "_ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _"; visible = false; })
      (cachedMonitorCase { clock = "3+30x20"; visible = false; })
      {
        # A complete two-host local monitor window retains observed zeros.
        interval = "30s";
        input_series = [
          { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="dungarees"}''; values = "0+0x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:underclass_monitor_local_readiness:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:underclass_monitor_local_readiness:ratio5m"; value = 0.5; }]; }
        ];
      }
      {
        # One absent host cannot make the other host look fleet ready.
        interval = "30s";
        input_series = [
          { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="panterloons"}''; values = "1+0x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:underclass_monitor_local_readiness:ratio5m";
            eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # Missing two scrapes makes the candidate unknown even when the last
        # observed gauge happens to be one.
        interval = "30s";
        input_series = [
          { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="dungarees"}''; values = "1+0x13 _ _ 1+0x4"; }
        ];
        promql_expr_test = [
          { expr = "overalls:underclass_monitor_local_readiness:ratio5m";
            eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # Retained central recording is hidden once a host probe disappears.
        interval = "30s";
        input_series = [
          { series = ''overalls:underclass_monitor_local_readiness:ratio5m''; values = "1+0x20"; }
          { series = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="panterloons"}''; values = "1+0x20"; }
        ];
        promql_expr_test = [
          { expr = ''overalls:underclass_monitor_local_readiness:ratio5m and on() (${underclassReady})'';
            eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        interval = "30s";
        input_series = [
          { series = ''haproxy_frontend_http_requests_total{proxy="marshall_public"}''; values = "0+10x20"; }
          { series = ''haproxy_frontend_http_responses_total{proxy="marshall_public",code="2xx"}''; values = "0+3x20"; }
          { series = ''haproxy_frontend_http_responses_total{proxy="marshall_public",code="4xx"}''; values = "0+2x20"; }
          { series = ''haproxy_frontend_http_responses_total{proxy="marshall_public",code="5xx"}''; values = "0+5x20"; }
          { series = ''up{job="overalls-otel",instance="panterloons"}''; values = "1+0x20"; }
          { series = ''up{job="overalls-otel",instance="panterloons",overalls_telemetry_origin="host",service_name="haproxy-local"}''; values = "0+0x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_count{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_count{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.01",host_name="panterloons"}''; values = "0+0x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.01",host_name="dungarees"}''; values = "0+0x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.05",host_name="panterloons"}''; values = "0+2x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.05",host_name="dungarees"}''; values = "0+2x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.1",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.1",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.5",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.5",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="10.0",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="10.0",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="+Inf",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="+Inf",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_galileo_requests_total{overalls_telemetry_origin="application",service_name="galileo",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_galileo_requests_total{overalls_telemetry_origin="application",service_name="galileo",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_galileo_source_start_time{overalls_telemetry_origin="application",service_name="galileo",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_galileo_source_start_time{overalls_telemetry_origin="application",service_name="galileo",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_galileo_successes_total{overalls_telemetry_origin="application",service_name="galileo",host_name="panterloons"}''; values = "0+7x20"; }
          { series = ''overalls_outer_galileo_successes_total{overalls_telemetry_origin="application",service_name="galileo",host_name="dungarees"}''; values = "0+7x20"; }
          { series = ''overalls_outer_enrico_requests_total{overalls_telemetry_origin="application",service_name="enrico",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_enrico_source_start_time{overalls_telemetry_origin="application",service_name="enrico",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_enrico_successes_total{overalls_telemetry_origin="application",service_name="enrico",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_porsche_requests_total{overalls_telemetry_origin="application",service_name="porsche",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_porsche_source_start_time{overalls_telemetry_origin="application",service_name="porsche",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_porsche_successes_total{overalls_telemetry_origin="application",service_name="porsche",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_ziggy_requests_total{overalls_telemetry_origin="application",service_name="ziggy",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_ziggy_requests_total{overalls_telemetry_origin="application",service_name="ziggy",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_ziggy_source_start_time{overalls_telemetry_origin="application",service_name="ziggy",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_ziggy_source_start_time{overalls_telemetry_origin="application",service_name="ziggy",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_ziggy_successes_total{overalls_telemetry_origin="application",service_name="ziggy",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_ziggy_successes_total{overalls_telemetry_origin="application",service_name="ziggy",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_private_requests_total{overalls_telemetry_origin="application",service_name="audi_private",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_private_requests_total{overalls_telemetry_origin="application",service_name="audi_private",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_private_source_start_time{overalls_telemetry_origin="application",service_name="audi_private",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_audi_private_source_start_time{overalls_telemetry_origin="application",service_name="audi_private",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_audi_private_successes_total{overalls_telemetry_origin="application",service_name="audi_private",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_private_successes_total{overalls_telemetry_origin="application",service_name="audi_private",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_dns_source_start_time{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_audi_dns_successes_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_dns_source_start_time{overalls_telemetry_origin="application",service_name="audi_dns",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_audi_dns_successes_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_marshall_web_requests_total{overalls_telemetry_origin="application",service_name="marshall_web",host_name="panterloons",service_instance_id="overalls"}''; values = "0+10x20"; }
          { series = ''overalls_outer_marshall_web_source_start_time{overalls_telemetry_origin="application",service_name="marshall_web",host_name="panterloons",service_instance_id="overalls"}''; values = "1+0x20"; }
          { series = ''overalls_outer_marshall_web_successes_total{overalls_telemetry_origin="application",service_name="marshall_web",host_name="panterloons",service_instance_id="overalls"}''; values = "0+7x20"; }
          { series = ''overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="panterloons",service_instance_id="overalls"}''; values = "0+8x20"; }
          { series = ''overalls_outer_marshall_live_source_start_time{overalls_telemetry_origin="application",service_name="marshall_live",host_name="panterloons",service_instance_id="overalls"}''; values = "1+0x20"; }
          { series = ''overalls_outer_marshall_live_successes_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="panterloons",service_instance_id="overalls"}''; values = "0+6x20"; }
          { series = ''overalls_outer_marshall_live_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="marshall_live",host_name="panterloons",service_instance_id="overalls",le="1.0"}''; values = "0+4x20"; }
          { series = ''overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_ssh_source_start_time{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_audi_ssh_successes_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_ssh_source_start_time{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_audi_ssh_successes_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="dungarees"}''; values = "0+5x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:slo_collectors:ratio7d"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:slo_brady:ratio7d"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:web_ingress_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:web_ingress_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:telemetry_collector_up:ratio1h";
            eval_time = "10m";
            exp_samples = [{ labels = ''overalls:telemetry_collector_up:ratio1h{instance="panterloons",job="overalls-otel"}''; value = 1; }]; }
          { expr = "overalls:brady_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:brady_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:brady_candidate_duration:p95_5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:brady_candidate_duration:p95_5m"; value = 0.4600000000000001; }]; }
          { expr = candidateQuery "brady" "overalls:brady_candidate_duration:p95_5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:brady_candidate_duration:p95_5m"; value = 0.4600000000000001; }]; }
          { expr = "overalls:galileo_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:galileo_candidate_completion:ratio5m"; value = 0.7; }]; }
          { expr = "overalls:enrico_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:enrico_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:porsche_candidate_dispatch:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:porsche_candidate_dispatch:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:ziggy_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:ziggy_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:audi_private_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:audi_private_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:audi_dns_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:audi_dns_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:marshall_web_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:marshall_web_candidate_completion:ratio5m"; value = 0.7; }]; }
          { expr = "overalls:audi_ssh_candidate_establishment:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:audi_ssh_candidate_establishment:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:marshall_live_candidate_completion:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:marshall_live_candidate_completion:ratio5m"; value = 0.75; }]; }
          # Callbacks without a duration sample count as slower than the bound.
          { expr = "overalls:marshall_live_latency:ratio5m";
            eval_time = "10m";
            exp_samples = [{ labels = "overalls:marshall_live_latency:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:slo_marshall_live_latency:ratio7d"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        interval = "30s";
        input_series = [
          { series = ''haproxy_frontend_http_requests_total{proxy="marshall_public"}''; values = "0+0x20"; }
          { series = ''haproxy_frontend_http_responses_total{proxy="marshall_public",code="2xx"}''; values = "0+0x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:web_ingress_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:brady_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:brady_candidate_duration:p95_5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:galileo_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:enrico_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:porsche_candidate_dispatch:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:ziggy_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:audi_private_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:audi_dns_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:marshall_web_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:audi_ssh_candidate_establishment:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:marshall_live_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:marshall_live_latency:ratio5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_dns_successes_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_ssh_successes_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "0+5x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:audi_dns_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:audi_ssh_candidate_establishment:ratio5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "0+10x18 _ _"; }
          { series = ''overalls_outer_audi_dns_successes_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="panterloons"}''; values = "0+5x18 _ _"; }
          { series = ''overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_dns_successes_total{overalls_telemetry_origin="application",service_name="audi_dns",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "0+10x18 _ _"; }
          { series = ''overalls_outer_audi_ssh_successes_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="panterloons"}''; values = "0+5x18 _ _"; }
          { series = ''overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_audi_ssh_successes_total{overalls_telemetry_origin="application",service_name="audi_ssh",host_name="dungarees"}''; values = "0+5x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:audi_dns_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:audi_ssh_candidate_establishment:ratio5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        interval = "30s";
        input_series = [
          { series = ''up{job="overalls-otel",instance="panterloons",overalls_telemetry_origin="host",service_name="haproxy-local"}''; values = "1+0x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:telemetry_collector_up:ratio1h"; eval_time = "10m"; exp_samples = []; }
          { expr = "overalls:telemetry_collector_missing:bool"; eval_time = "10m";
            exp_samples = [{ labels = ''overalls:telemetry_collector_missing:bool{job="overalls-otel"}''; value = 1; }]; }
        ];
      }
      {
        # A partial duration sample must not create a reassuring latency p95.
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_duration_seconds_count{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_count{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.5",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.5",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="10.0",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="10.0",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="+Inf",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="+Inf",host_name="dungarees"}''; values = "0+5x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:brady_candidate_completion:ratio5m"; eval_time = "10m";
            exp_samples = [{ labels = "overalls:brady_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:brady_candidate_duration:p95_5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # The exporter saturates durations beyond its 10-second last bucket.
        # Such a window cannot yield a finite p95 candidate.
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_duration_seconds_count{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_count{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.5",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="0.5",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="10.0",host_name="panterloons"}''; values = "0+9x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="10.0",host_name="dungarees"}''; values = "0+9x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="+Inf",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="brady",le="+Inf",host_name="dungarees"}''; values = "0+10x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:brady_candidate_completion:ratio5m"; eval_time = "10m";
            exp_samples = [{ labels = "overalls:brady_candidate_completion:ratio5m"; value = 0.5; }]; }
          { expr = "overalls:brady_candidate_duration:p95_5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # A source restart can lose outcomes after its last exported snapshot.
        # A reset inside the window must suppress the candidate ratio.
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x13 0+10x6"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x13 0+10x6"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x13 0+5x6"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x13 0+5x6"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "1+0x13 420+0x6"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "1+0x13 420+0x6"; }
        ];
        promql_expr_test = [
          { expr = "overalls:brady_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # Legacy or interrupted exports without a trusted marker are unknown.
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:brady_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # Equal series counts cannot substitute a marker from another host.
        interval = "30s";
        input_series = [
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+5x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="retired"}''; values = "1+0x20"; }
        ];
        promql_expr_test = [
          { expr = "overalls:brady_candidate_completion:ratio5m"; eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # A retained recording from before a Prometheus restart cannot make
        # Grafana show a ratio while the current source is still warming up.
        interval = "30s";
        input_series = [
          { series = ''overalls:brady_candidate_completion:ratio5m''; values = "0.5+0x20"; }
          { series = ''overalls:brady_candidate_duration:p95_5m''; values = "0.46+0x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "0+10x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "420+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "420+0x20"; }
        ];
        promql_expr_test = [
          { expr = candidateQuery "brady" "overalls:brady_candidate_completion:ratio5m";
            eval_time = "10m"; exp_samples = []; }
          { expr = candidateQuery "brady" "overalls:brady_candidate_duration:p95_5m";
            eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # A retained recording must not display after the request rate reaches
        # zero, even when the source marker is old and fresh.
        interval = "30s";
        input_series = [
          { series = ''overalls:brady_candidate_completion:ratio5m''; values = "0.5+0x20"; }
          { series = ''overalls:brady_candidate_duration:p95_5m''; values = "0.46+0x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "7+0x20"; }
          { series = ''overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "7+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="panterloons"}''; values = "1+0x20"; }
          { series = ''overalls_outer_brady_source_start_time{overalls_telemetry_origin="application",service_name="brady",host_name="dungarees"}''; values = "1+0x20"; }
        ];
        promql_expr_test = [
          { expr = candidateQuery "brady" "overalls:brady_candidate_completion:ratio5m";
            eval_time = "10m"; exp_samples = []; }
          { expr = candidateQuery "brady" "overalls:brady_candidate_duration:p95_5m";
            eval_time = "10m"; exp_samples = []; }
        ];
      }
      {
        # Query-time readiness hides a retained seven-day objective after the
        # application source disappears between five-minute rule evaluations.
        interval = "30s";
        input_series = [
          { series = ''overalls:slo_brady:ratio7d''; values = "1+0x20"; }
          { series = ''up{job="overalls-otel",instance="10.90.0.1:9464"}''; values = "1+0x20"; }
          { series = ''up{job="overalls-otel",instance="10.90.0.2:9464"}''; values = "1+0x20"; }
        ];
        promql_expr_test = [
          { expr = objectiveQuery { id = "brady"; kind = "candidate"; };
            eval_time = "10m"; exp_samples = []; }
        ];
      }
    ] ++ builtins.map proxyCase [
      { hosts = [ "panterloons" "dungarees" ]; }
      { hosts = [ "panterloons" ]; }
      { hosts = [ "panterloons" "dungarees" ]; stale = true; }
      { hosts = [ "panterloons" "dungarees" ]; marker = false; }
    ] ++ builtins.concatMap (source: builtins.map (lifecycleCase source) [
      { host = "panterloons"; clock = "0+30x20"; visible = true; }
      { host = "dungarees"; clock = "0+30x20"; visible = false; }
      { host = "panterloons"; clock = "_"; visible = false; }
      { host = "panterloons"; clock = "1+0x20"; visible = false; }
      { host = "panterloons"; clock = "603+0x20"; visible = false; }
    ]) lifecycleSources ++ builtins.map underclassLatencyCase [
      { name = "unified histogram yields a finite thirty-second-bucket p95"; value = 29; }
      { name = "day-scale durations remain inside the finite histogram"; zero = "21600.0"; bucket = "86400.0"; value = 83160; }
      { name = "overflow beyond one day withholds p95"; finite = 9; }
      { name = "requests without duration samples withhold p95"; counted = 9; finite = 9; }
      { name = "retired seven-bound shape without the one-day bucket withholds p95"; lastBucket = false; }
      { name = "warming source withholds p95"; start = "420+0x20"; }
      { name = "missing replica withholds p95"; hosts = [ "panterloons" ]; }
    ] ++ builtins.map cachedProxyCase [
      { clock = "1+0x20"; visible = false; }
      { clock = "0+30x20"; visible = true; }
      { clock = "_"; visible = false; }
      { clock = "603+0x20"; visible = false; }
      { clock = "0+30x20"; coverage = "60+0x20"; visible = false; }
      { clock = "0+30x20"; coverage = "_"; visible = false; }
    ]);
  };
in
assert (import ../../../domains/system/otel-fleet/cadence.nix).scrapeSeconds == 10;
assert (import ../../../domains/system/otel-fleet/cadence.nix).samplesPerDay == 8640;
assert (import ../../../domains/system/otel-fleet/cadence.nix).sevenDaySamples == 60480;
assert pkgs.lib.hasInfix ">= 60480" productionCollectorRule.expr;
pkgs.runCommand "overalls-otel-slo-rules-test" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
  promtool test rules ${test}
  promtool test rules ${longTest}
  promtool test rules ${cadenceTest}
  promtool test rules ${burnTest}
  touch $out
''
