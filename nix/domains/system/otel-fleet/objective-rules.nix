{ expectedSamples ? (import ./cadence.nix).sevenDaySamples, hosts }:
let
  objectives = import ./objectives.nix { inherit hosts; };
  # Burn rate = budget fraction consumed * objective horizon / long window.
  # Two percent in one hour and five percent in six hours use the seven-day
  # horizon; conventional 14.4 and 6 multipliers assume thirty days.
  objectiveHours = 7 * 24;
  fastBurn = 0.02 * objectiveHours / 1;
  slowBurn = 0.05 * objectiveHours / 6;
  sourceReady = import ./source-ready.nix { inherit hosts; };
  coverageReady = import ./coverage-ready.nix;
  underclassReady = import ./underclass-ready.nix { inherit hosts; };
  ingressReady = import ./ingress-ready.nix;
  hostChecks = metric: labels: hosts: window: builtins.concatStringsSep " and on() "
    (builtins.map (host: ''
      (count(${metric}{${labels},host_name="${host}"}) == 1)
      and on() (count_over_time(${metric}{${labels},host_name="${host}"}[${window}]) >= ${toString expectedSamples})
    '') hosts);
  exactRoster = metric: labels: hosts: ''
    (count(${metric}{${labels}}) == ${toString (builtins.length hosts)})
    and on() (${hostChecks metric labels hosts "7d"})
  '';
  collectorCoverage = builtins.concatStringsSep "\nand on() " (builtins.map (address:
    ''(count_over_time(up{job="overalls-otel",instance="${address}:9464",overalls_telemetry_origin=""}[7d]) >= ${toString expectedSamples})'')
    (import ./roster-addresses.nix hosts)) + "\n";
  collectors = toString (builtins.length hosts);
  query = source:
    let
      service = source.service or source.id;
      metric = "overalls_outer_${service}";
      labels = ''overalls_telemetry_origin="application",service_name="${service}"'';
      requests = "${metric}_requests_total";
      successes = "${metric}_successes_total";
      requestCount = ''sum(increase(${requests}{${labels}}[7d]))'';
    in
      if source.kind == "collector" then ''
        min(avg_over_time(up{job="overalls-otel",overalls_telemetry_origin=""}[7d]))
        and on() (${collectorCoverage})
        and on() (count(up{job="overalls-otel",overalls_telemetry_origin=""}) == ${collectors})
      '' else if source.kind == "ingress" then ''
        (sum(increase(haproxy_frontend_http_responses_total{proxy="marshall_public",code=~"2xx|3xx|4xx"}[7d]))
          / sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[7d])))
        and on() (sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[7d])) >= ${toString source.minRequests})
        and on() (${collectorCoverage})
        and on() (${ingressReady})
        and on() (min(up{job="overalls-otel",overalls_telemetry_origin=""}) == 1)
      '' else if source.kind == "latency" then ''
        (sum(increase(${metric}_duration_seconds_bucket{${labels},le="${source.bound}"}[7d])) / ${requestCount})
        and on() (${requestCount} >= ${toString source.minRequests})
        and on() (${exactRoster requests labels source.hosts})
        and on() (max(${metric}_source_start_time{${labels}}) < time() - 604800)
        and on() (${sourceReady service})
        and on() (${coverageReady service 604800})
        and on() (${collectorCoverage})
        and on() (min(up{job="overalls-otel",overalls_telemetry_origin=""}) == 1)
      '' else if source.kind == "monitor" then ''
        avg(avg_over_time(overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor"}[7d]))
        and on() (${exactRoster "overalls_underclass_monitor_ready" ''overalls_telemetry_origin="application",service_name="underclass_monitor"'' source.hosts})
        and on() (${underclassReady})
        and on() (${collectorCoverage})
        and on() (min(up{job="overalls-otel",overalls_telemetry_origin=""}) == 1)
      '' else ''
        (sum(increase(${successes}{${labels}}[7d])) / ${requestCount})
        and on() (${requestCount} >= ${toString source.minRequests})
        and on() (${exactRoster requests labels source.hosts})
        and on() (count(${successes}{${labels}}) == ${toString (builtins.length source.hosts)})
        and on() (max(${metric}_source_start_time{${labels}}) < time() - 604800)
        and on() (${sourceReady service})
        and on() (${coverageReady service 604800})
        and on() (${collectorCoverage})
        and on() (min(up{job="overalls-otel",overalls_telemetry_origin=""}) == 1)
      '';
  objectiveRule = source: {
    record = "overalls:slo_${source.id}:ratio7d";
    expr = query source;
  };
  windowRatio = source: window:
    let
      service = source.service or source.id;
      labels = ''overalls_telemetry_origin="application",service_name="${service}"'';
    in if source.kind == "collector" then
      ''min(avg_over_time(up{job="overalls-otel",overalls_telemetry_origin=""}[${window}]))''
    else if source.kind == "monitor" then
      ''avg(avg_over_time(overalls_underclass_monitor_ready{${labels}}[${window}]))''
    else if source.kind == "ingress" then ''
      (sum(increase(haproxy_frontend_http_responses_total{proxy="marshall_public",code=~"2xx|3xx|4xx"}[${window}]))
        / sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[${window}])))
      and on() (sum(increase(haproxy_frontend_http_requests_total{proxy="marshall_public"}[${window}])) >= 20)
    '' else if source.kind == "latency" then ''
      (sum(increase(overalls_outer_${service}_duration_seconds_bucket{${labels},le="${source.bound}"}[${window}]))
        / sum(increase(overalls_outer_${service}_requests_total{${labels}}[${window}])))
      and on() (sum(increase(overalls_outer_${service}_requests_total{${labels}}[${window}])) >= 20)
    '' else ''
      (sum(increase(overalls_outer_${service}_successes_total{${labels}}[${window}]))
        / sum(increase(overalls_outer_${service}_requests_total{${labels}}[${window}])))
      and on() (sum(increase(overalls_outer_${service}_requests_total{${labels}}[${window}])) >= 20)
    '';
  burnRule = source: name: short: long: multiplier: {
    alert = "OverallsSLOBurn_${name}_${source.id}";
    expr = ''
      ((1 - (${windowRatio source short})) > ${toString multiplier} * (1 - ${toString source.target}))
      and on() ((1 - (${windowRatio source long})) > ${toString multiplier} * (1 - ${toString source.target}))
      and on() (time() - timestamp(overalls:slo_${source.id}:ratio7d) < 360)
      ${if source.kind == "candidate" then "and on() (${sourceReady source.id}) and on() (${coverageReady source.id 604800})"
        else if source.kind == "latency" then "and on() (${sourceReady source.service}) and on() (${coverageReady source.service 604800})"
        else if source.kind == "monitor" then "and on() (${underclassReady})"
        else if source.kind == "ingress" then ''and on() (${ingressReady}) and on() (min(up{job="overalls-otel",overalls_telemetry_origin=""}) == 1)''
        else ''and on() (count(up{job="overalls-otel",overalls_telemetry_origin=""}) == ${collectors})''}
    '';
    "for" = "5m";
    labels = { severity = "warning"; slo = source.id; status = "provisional"; window = name; };
    annotations.summary = "Provisional ${source.id} ${name} error-budget burn";
  };
in
# @cc [owner:ghuntley,label:reliability] seven-day-objective-unknown
# The seven-day ratio and burn state MUST be absent until enrolled source
# coverage, collector coverage, source lifetime and minimum volume are present.
# Guest claims MUST NOT enter an outer-fleet objective.
# Burn thresholds MUST derive from fractions of the seven-day budget:
# two percent in one hour and five percent in six hours.

# @cc [owner:ghuntley,label:reliability] latency-objective-missing-duration-fails
# A latency objective MUST divide requests whose duration sample lies within
# its fixed bucket bound by every admitted request of its source, so a request
# without a duration sample never counts as fast.
{
  groups = [{
    name = "overalls-otel-seven-day-objectives";
    interval = "5m";
    rules = builtins.map objectiveRule objectives;
  } {
    name = "overalls-otel-budget-burn";
    interval = "1m";
    rules = (builtins.map (source: burnRule source "fast" "5m" "1h" fastBurn) objectives)
      ++ (builtins.map (source: burnRule source "slow" "30m" "6h" slowBurn) objectives);
  }];
}
