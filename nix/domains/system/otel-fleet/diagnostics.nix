{ hosts }:
let
  sources = import ./objectives.nix { inherit hosts; };
  collectors = toString (builtins.length hosts);
  candidates = import ./candidate-sources.nix;
  coverageReady = import ./coverage-ready.nix;
  sourceReady = import ./source-ready.nix { inherit hosts; };
  roster = import ./source-roster.nix { inherit hosts; };
  cadence = import ./cadence.nix;
  collector = ''up{job="overalls-otel",overalls_telemetry_origin=""}'';
  collectorPresent = ''count(${collector}) == ${collectors}'';
  collectorFresh = ''max(time() - timestamp(${collector})) < 45'';
  collectorHistory = ''count(count_over_time(${collector}[7d]) >= ${toString cadence.sevenDaySamples}) == ${collectors}'';
  check = code: good: { inherit code good; };
  checks = source: window: let
    s = source.service or source.id;
    sourced = builtins.elem source.kind [ "candidate" "latency" ];
    metric = "overalls_outer_${s}";
    labels = ''overalls_telemetry_origin="application",service_name="${s}"'';
    selector = suffix: ''${metric}_${suffix}{${labels}}'';
    horizon = if window == "objective" then 604800 else 300;
    range = if window == "objective" then "7d" else "5m";
    candidate = builtins.head (builtins.filter (entry: entry.service == s) candidates);
    duration = "${metric}_duration_seconds";
    requests = "${metric}_requests_total";
    lastBucket = if s == "underclass_proxy" then "86400.0" else
      if builtins.elem s [ "vscode_browser_nixos" "vscode_browser_ubuntu" ] then "60.0" else
      if builtins.elem s (import ./durable-services.nix) then "3000.0" else "10.0";
    recording = if window == "objective" then "overalls:slo_${source.id}:ratio7d"
      else if window == "latency" then "overalls:${s}_candidate_duration:p95_5m"
      else if source.kind == "collector" then "overalls:telemetry_collector_up:ratio1h"
      else if source.kind == "ingress" then "overalls:web_ingress_completion:ratio5m"
      else if source.kind == "monitor" then "overalls:underclass_monitor_local_readiness:ratio5m"
      else if source.kind == "latency" then "overalls:${source.id}:ratio5m"
      else "overalls:${candidate.ratio}:ratio5m";
  in [ (check 1 collectorPresent) (check 2 (collectorFresh +
    (if source.kind == "collector" then "" else " and on() min(${collector}) == 1"))) ] ++
    (if sourced then [
      (check 1 (roster s))
      (check 1 ''count(${selector "source_sample_time"}) == ${toString (builtins.length source.hosts)}'')
      (check 2 ''max(time() - ${selector "source_sample_time"}) < 45 and on() min(time() - ${selector "source_sample_time"}) >= -2'')
    ] ++ [
      (check 3 ''max(${selector "source_start_time"}) < time() - 300'')
      (check 4 (coverageReady s 300))
    ] else if source.kind == "ingress" then [ (check 2 (import ./ingress-ready.nix)) ]
    else if source.kind == "monitor" then [ (check 2 (import ./underclass-ready.nix { inherit hosts; })) ] else []) ++
    (if window == "objective" then [ (check 6 collectorHistory) ] ++
      (if sourced then [
        (check 6 (coverageReady s horizon))
        (check 7 ''sum(increase(${selector "requests_total"}[${range}])) >= ${toString source.minRequests}'')
      ] else if source.kind == "ingress" then [
        (check 7 ''sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[7d])) >= ${toString source.minRequests}'')
      ] else [])
    else if sourced then [
      (check 5 ''sum(increase(${selector "requests_total"}[5m])) > 0'')
    ] else if source.kind == "ingress" then [
      (check 5 ''sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[5m])) > 0'')
    ] else []) ++
    (if window == "latency" then [
      (check 8 ''sum(increase(${duration}_count{${labels}}[5m])) == sum(increase(${requests}{${labels}}[5m]))'')
      (check 9 ''sum(increase(${duration}_bucket{${labels},le="+Inf"}[5m])) == sum(increase(${duration}_bucket{${labels},le="${lastBucket}"}[5m]))'')
    ] else []) ++ [ (check 10 ''${recording} and on() (time() - timestamp(${recording}) < ${if window == "objective" then "360" else "90"})'') ];
  status = source: window: let
    ordered = checks source window;
    previous = index: builtins.concatStringsSep "" (builtins.map (item: " and on() (${item.good})")
      (builtins.genList (i: builtins.elemAt ordered i) index));
    failures = builtins.genList (index: let item = builtins.elemAt ordered index; in
      "(vector(${toString item.code}) unless on() (${item.good})${previous index})") (builtins.length ordered);
  in {
    record = "overalls:slo_status";
    labels = { slo = source.id; inherit window; };
    expr = builtins.concatStringsSep " or " (failures ++ [ "(vector(0)${previous (builtins.length ordered)})" ]);
  };
  evidence = source: let
    s = source.service or source.id;
    requests = ''overalls_outer_${s}_requests_total{overalls_telemetry_origin="application",service_name="${s}"}'';
    rule = kind: expr: { record = "overalls:slo_evidence"; labels = { slo = source.id; inherit kind; }; inherit expr; };
    duration = "overalls_outer_${s}_duration_seconds";
    lastBucket = if s == "underclass_proxy" then "86400.0" else
      if builtins.elem s [ "vscode_browser_nixos" "vscode_browser_ubuntu" ] then "60.0" else
      if builtins.elem s (import ./durable-services.nix) then "3000.0" else "10.0";
    labels = ''overalls_telemetry_origin="application",service_name="${s}"'';
    history = ''min(count_over_time(${collector}[90d])) / ${toString cadence.samplesPerDay}'';
  in if !(builtins.elem source.kind [ "candidate" "latency" ]) then [
    (rule "history_days" history)
    (rule "required_requests" "vector(${toString source.minRequests})")
  ] ++ (if source.kind == "monitor" then [
    (rule "freshness_seconds" ''clamp_min(max(time() - overalls_underclass_monitor_sample_time{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name=~"${builtins.concatStringsSep "|" hosts}"}), 0)'')
  ] else [])
  ++ (if source.kind == "ingress" then [
    (rule "requests5m" ''sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[5m]))'')
    (rule "requests7d" ''sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[7d]))'')
  ] else []) else [
    (rule "requests5m" ''sum(increase(${requests}[5m]))'')
    (rule "requests7d" ''sum(increase(${requests}[7d]))'')
    (rule "required_requests" "vector(${toString source.minRequests})")
    (rule "history_days" ''min(label_replace(${history}, "evidence", "collector", "", "") or label_replace(min(time() - overalls_outer_${s}_source_coverage_start_time{${labels}}) / 86400, "evidence", "source", "", ""))'')
    (rule "freshness_seconds" ''clamp_min(max(time() - overalls_outer_${s}_source_sample_time{overalls_telemetry_origin="application",service_name="${s}"}), 0)'')
    (rule "overflow5m" ''clamp_min(sum(increase(${duration}_bucket{${labels},le="+Inf"}[5m])) - sum(increase(${duration}_bucket{${labels},le="${lastBucket}"}[5m])), 0)'')
  ];
  # @cc [owner:ghuntley,label:verification;reliability] browser-diagnostics-fixed-window
  # Browser warnings MUST describe only fixed-window observations, never a
  # persistent consecutive failure streak. Recorder/collector gaps, missing
  # sources and incomplete warmup MUST withhold these observations.
  browserDiagnostics = service: let
    labels = ''overalls_telemetry_origin="application",service_name="${service}"'';
    metric = "overalls_outer_${service}";
    ready = seconds: ''
      (${sourceReady service}) and on() (${coverageReady service seconds})
      and on() (max(${metric}_source_start_time{${labels}}) < time() - ${toString seconds})
      and on() (${collectorPresent}) and on() (${collectorFresh})
      and on() (min(${collector}) == 1)
    '';
    rule = kind: expr: {
      record = "overalls:browser_probe_diagnostic";
      labels = { slo = service; inherit kind; };
      inherit expr;
    };
  in [
    (rule "failures_without_success_15m" ''
      (sum(increase(${metric}_failures_total{${labels}}[15m])) >= bool 3)
      * on() (sum(increase(${metric}_successes_total{${labels}}[15m])) == bool 0)
      and on() (${ready 900})
    '')
    (rule "no_completion_10m" ''
      (sum(increase(${metric}_requests_total{${labels}}[10m])) == bool 0)
      and on() (${ready 600})
    '')
  ];
in
# @cc [owner:ghuntley,label:reliability;product] diagnostic-precedence
# Exactly one bounded status MUST describe each candidate, objective and latency
# window. Missing/stale sources MUST precede inactivity; diagnostics MUST NOT
# manufacture completion ratios or bypass their readiness guards.
{ groups = [{
  name = "overalls-otel-diagnostics";
  interval = "10s";
  rules = builtins.concatMap (source:
    [ (status source "candidate") (status source "objective") ]
    ++ (if source.kind == "candidate" then [ (status source "latency") ] else [])
    ++ evidence source) sources
    ++ builtins.concatMap browserDiagnostics [ "vscode_browser_nixos" "vscode_browser_ubuntu" ];
}]; }
