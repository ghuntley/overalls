{ hosts }:
let
  sourceReady = import ./source-ready.nix { inherit hosts; };
  coverageReady = import ./coverage-ready.nix;
  underclassReady = import ./underclass-ready.nix { inherit hosts; };
  ingressReady = import ./ingress-ready.nix;
  collectorFresh = ''
    (count(up{job="overalls-otel",overalls_telemetry_origin=""}) == ${toString (builtins.length hosts)})
    and (max(time() - timestamp(up{job="overalls-otel",overalls_telemetry_origin=""})) < 45)
  '';
in
# @cc [owner:ghuntley,label:reliability] objective-read-freshness
# A retained seven-day recording MUST disappear from the UI and Grafana when
# the enrolled source or collector is no longer fresh at read time.
source: ''
  overalls:slo_${source.id}:ratio7d
  and on() (time() - timestamp(overalls:slo_${source.id}:ratio7d) < 360)
  and on() (${collectorFresh})
  ${if source.kind == "candidate" then "and on() (${sourceReady source.id}) and on() (${coverageReady source.id 604800})"
    else if source.kind == "latency" then "and on() (${sourceReady source.service}) and on() (${coverageReady source.service 604800})"
    else if source.kind == "monitor" then "and on() (${underclassReady})"
    else if source.kind == "ingress" then ''and on() (${ingressReady}) and on() (min(up{job="overalls-otel",overalls_telemetry_origin=""}) == 1)''
    else ""}
''
