{ hosts }:
let
  sources = import ./candidate-sources.nix;
  candidateQuery = import ./candidate-query.nix { inherit hosts; };
  underclassReady = import ./underclass-ready.nix { inherit hosts; };
  objectives = import ./objectives.nix { inherit hosts; };
  objectiveQuery = import ./objective-query.nix { inherit hosts; };
  objective = id: builtins.head (builtins.filter (entry: entry.id == id) objectives);
  withObjective = entry: entry // {
    target = (objective entry.id).target;
    objective_query = objectiveQuery (objective entry.id);
  };
in
# @cc [owner:ghuntley,label:security;reliability] signed-in-slo-catalog
# Only fixed Nix-owned, source-guarded queries MAY reach Grafana's provisioned
# SLO dashboards. A candidate MUST keep its limited journey name visible.
 builtins.map withObjective ([
  {
    id = "collectors";
    title = "Fleet telemetry collection";
    recording = "overalls:telemetry_collector_up:ratio1h";
    query = ''overalls:telemetry_collector_up:ratio1h{overalls_telemetry_origin=""}'';
    kind = "collectors";
  }
  {
    id = "ingress";
    title = "Public ingress HTTP completion";
    recording = "overalls:web_ingress_completion:ratio5m";
    query = ''overalls:web_ingress_completion:ratio5m and on() (${import ./ingress-ready.nix})'';
    kind = "candidate";
  }
] ++ builtins.map (source: {
  id = source.service;
  title = source.title;
  recording = "overalls:${source.ratio}:ratio5m";
  query = candidateQuery source.service "overalls:${source.ratio}:ratio5m";
  kind = "candidate";
}) sources ++ builtins.map (entry: {
  inherit (entry) id title;
  recording = "overalls:${entry.id}:ratio5m";
  query = candidateQuery entry.service "overalls:${entry.id}:ratio5m";
  kind = "latency";
}) (builtins.filter (entry: entry.kind == "latency") objectives) ++ [{
  id = "underclass_monitor";
  title = "Underclass local monitor readiness";
  recording = "overalls:underclass_monitor_local_readiness:ratio5m";
  query = ''overalls:underclass_monitor_local_readiness:ratio5m and on() (${underclassReady})'';
  kind = "candidate";
}])
