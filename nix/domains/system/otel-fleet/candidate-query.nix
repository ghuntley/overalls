{ hosts }:
let
  sourceReady = import ./source-ready.nix { inherit hosts; };
in
# @cc [owner:ghuntley,label:reliability;verification] candidate-panels-require-live-traffic
# A retained recording MUST disappear at read time when the current five-minute
# request window has no admitted traffic, even if its source marker is ready.
service: recording: ''
  ${recording}
  and on() (sum(rate(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}[5m])) > 0)
  and on() (${sourceReady service})
''
