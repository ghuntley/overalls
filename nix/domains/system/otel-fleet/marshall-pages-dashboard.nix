# @cc [owner:ghuntley,label:reliability;observability] marshall-pages-dashboard-sources
# Objective and SLI panels MUST read only the recorder-backed marshall_live
# recordings and catalog queries, which withhold values when the source is not
# ready. Log-derived gauges and traces MUST appear only in panels titled as
# diagnostics and MUST NOT be presented as objective compliance.
{ hosts }:
let
  prometheus = { type = "prometheus"; uid = "overalls-prometheus"; };
  tempo = { type = "tempo"; uid = "overalls-tempo"; };
  catalog = import ./slo-catalog.nix { inherit hosts; };
  candidateQuery = import ./candidate-query.nix { inherit hosts; };
  slo = id: builtins.head (builtins.filter (entry: entry.id == id) catalog);
  completion = slo "marshall_live";
  latency = slo "marshall_live_latency";
  labels = ''overalls_telemetry_origin="application",service_name="marshall_live"'';
  percent = target: let tenths = builtins.floor (target * 1000 + 0.5);
    in "${toString (tenths / 10)}.${toString (tenths - tenths / 10 * 10)}%";
  grid = id: h: w: x: y: { gridPos = { inherit h w x y; }; inherit id; };
  objective = id: x: entry: grid id 6 12 x 0 // {
    title = "${entry.title}, provisional seven-day objective (target ${percent entry.target})";
    type = "stat"; datasource = prometheus;
    targets = [{ refId = "A"; expr = entry.objective_query; }];
    fieldConfig.defaults = {
      unit = "percentunit"; decimals = 3; min = 0; max = 1;
      thresholds = { mode = "absolute"; steps = [
        { color = "red"; value = null; }
        { color = "green"; value = entry.target; }
      ]; };
    };
  };
  timeseries = id: x: y: title: expr: unit: grid id 8 12 x y // {
    inherit title; type = "timeseries"; datasource = prometheus;
    targets = [{ refId = "A"; inherit expr; }];
    fieldConfig.defaults = { inherit unit; } // (if unit == "percentunit" then { min = 0; max = 1; } else { min = 0; });
  };
  table = id: y: title: expr: grid id 8 24 0 y // {
    inherit title; type = "table"; datasource = prometheus;
    targets = [{ refId = "A"; inherit expr; instant = true; format = "table"; }];
  };
  # Diagnostic gauges: per-minute totals divided by their count for the same
  # interval. They come from Marshall's own log summaries and are not SLIs.
  ratio = prefix: label: measure:
    ''label_replace({__name__=~"overalls_gauge_${prefix}_.+_${measure}"}, "${label}", "$1", "__name__", "overalls_gauge_${prefix}_(.+)_${measure}") / on(host_name,unit,${label}) (label_replace({__name__=~"overalls_gauge_${prefix}_.+_count"}, "${label}", "$1", "__name__", "overalls_gauge_${prefix}_(.+)_count") > 0)'';
in {
  uid = "overalls-marshall-pages";
  title = "Marshall pages";
  tags = [ "overalls" "marshall" "slo" ];
  schemaVersion = 41; version = 1; refresh = "30s";
  time = { from = "now-24h"; to = "now"; };
  description = "Marshall LiveView page service levels from the independent marshall_live request recorder, with diagnostic page timings and traces. Unavailable values remain unknown; objectives are provisional.";
  panels = [
    (objective 1 0 completion)
    (objective 2 12 latency)
    (timeseries 3 0 6 "SLI · page interactions completed without exception, 5 minutes"
      (candidateQuery "marshall_live" completion.recording) "percentunit")
    (timeseries 4 12 6 "SLI · page interactions within 1 s, 5 minutes"
      (candidateQuery "marshall_live" latency.recording) "percentunit")
    (timeseries 5 0 14 "SLI · page interaction p95 observed duration, 5 minutes"
      (candidateQuery "marshall_live" "overalls:marshall_live_candidate_duration:p95_5m") "s")
    (timeseries 6 12 14 "SLI · admitted page interactions per second"
      (candidateQuery "marshall_live" ''sum(rate(overalls_outer_marshall_live_requests_total{${labels}}[5m]))'') "reqps")
    (table 7 22 "Error-budget burn alerts · provisional"
      ''ALERTS{alertname=~"OverallsSLOBurn_.+",slo=~"marshall_live|marshall_live_latency"}'')
    (table 8 30 "Objective status and evidence · 0 means available"
      ''{__name__=~"overalls:slo_status|overalls:slo_evidence",slo=~"marshall_live|marshall_live_latency"}'')
    (timeseries 9 0 38 "Diagnostic · page refresh mean duration by view"
      (ratio "live" "view" "duration_ms") "ms")
    (timeseries 10 12 38 "Diagnostic · page refresh mean database queries by view"
      (ratio "live" "view" "queries") "short")
    (timeseries 11 0 46 "Diagnostic · LiveView callback mean duration by phase"
      (ratio "liveview" "phase" "duration_ms") "ms")
    (timeseries 12 12 46 "Diagnostic · LiveView callback mean database queries by phase"
      (ratio "liveview" "phase" "queries") "short")
    (grid 13 10 24 0 54 // {
      title = "Diagnostic · slowest LiveView callback traces";
      type = "table"; datasource = tempo;
      targets = [{ refId = "A"; datasource = tempo; queryType = "traceql"; limit = 20;
        query = ''{ name = "marshall.live.callback" && duration > 500ms }''; }];
    })
    (grid 14 10 24 0 64 // {
      title = "Diagnostic · failed LiveView callbacks by reason and deployed revision";
      type = "table"; datasource = tempo;
      targets = [{ refId = "A"; datasource = tempo; queryType = "traceql"; limit = 50;
        query = ''{ name = "marshall.live.callback" && status = error } | select(span.live_view, span.phase, span.reason, span.query_count, resource.service.version)''; }];
    })
  ];
}
