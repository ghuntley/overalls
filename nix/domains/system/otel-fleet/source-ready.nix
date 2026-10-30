# @cc [owner:ghuntley,label:reliability] source-sample-clock-freshness
# Collector cache and Prometheus scrape time MUST NOT establish source freshness.
# Every request series MUST have a matching source clock within 45 seconds and
# no more than two seconds in the future. Missing clocks remain unknown.
# A source restart resets in-memory counters. A candidate window is unknown
# until each request series has a matching, fresh source marker older than 5m.
{ hosts }:
service: let
  coverageReady = import ./coverage-ready.nix;
  roster = import ./source-roster.nix { inherit hosts; };
in ''
  (${roster service}) and on()
  (count(overalls_outer_${service}_source_start_time{overalls_telemetry_origin="application",service_name="${service}"})
    == count(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}))
  and (count(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}
    and on(host_name,service_instance_id) overalls_outer_${service}_source_start_time{overalls_telemetry_origin="application",service_name="${service}"})
    == count(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}))
  and (max(overalls_outer_${service}_source_start_time{overalls_telemetry_origin="application",service_name="${service}"}) < time() - 300)
  and (count((time() - timestamp(overalls_outer_${service}_source_start_time{overalls_telemetry_origin="application",service_name="${service}"})) < 45)
    == count(overalls_outer_${service}_source_start_time{overalls_telemetry_origin="application",service_name="${service}"}))
  and (count(overalls_outer_${service}_source_sample_time{overalls_telemetry_origin="application",service_name="${service}"})
    == count(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}))
  and (count(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}
    and on(host_name,service_instance_id) overalls_outer_${service}_source_sample_time{overalls_telemetry_origin="application",service_name="${service}"})
    == count(overalls_outer_${service}_requests_total{overalls_telemetry_origin="application",service_name="${service}"}))
  and (max(time() - overalls_outer_${service}_source_sample_time{overalls_telemetry_origin="application",service_name="${service}"}) < 45)
  and (min(time() - overalls_outer_${service}_source_sample_time{overalls_telemetry_origin="application",service_name="${service}"}) >= -2)
  and on() (${coverageReady service 300})
''
