{ hosts }:
let
  central = builtins.head hosts;
  # One fresh request series from each roster host.
  fresh = selector: builtins.concatStringsSep " and " (builtins.map (host:
    "count((time() - timestamp(${selector},host_name=\"${host}\"})) < 45) == 1") hosts);
  sourceReady = import ./source-ready.nix { inherit hosts; };
  latencySources = import ./candidate-sources.nix;
  underclassReady = import ./underclass-ready.nix { inherit hosts; };
  # @cc [owner:ghuntley,label:verification;reliability] candidate-latency-full-coverage
  # A candidate p95 MUST disappear when its source is warming up, an expected
  # replica is missing, any admitted request lacks a duration sample, or any
  # measured duration exceeds the largest finite histogram bucket.
  # A sampled subset must never be presented as fleet latency compliance.
  latencyRule = { service, ratio, ... }:
    let
      metric = "overalls_outer_${service}";
      labels = ''overalls_telemetry_origin="application",service_name="${service}"'';
      lastBucket = if service == "underclass_proxy" then "86400.0" else
        if builtins.elem service [ "vscode_browser_nixos" "vscode_browser_ubuntu" ] then "60.0" else
        if builtins.elem service (import ./durable-services.nix) then "3000.0" else "10.0";
      duration = "${metric}_duration_seconds";
      requests = "${metric}_requests_total";
    in {
      record = "overalls:${service}_candidate_duration:p95_5m";
      expr = ''
        histogram_quantile(0.95, sum by (le) (rate(${duration}_bucket{${labels}}[5m])))
        and on() (sum(rate(${duration}_count{${labels}}[5m])) == sum(rate(${requests}{${labels}}[5m])))
        and on() (sum(rate(${requests}{${labels}}[5m])) > 0)
        and on() (sum(rate(${duration}_bucket{${labels},le="+Inf"}[5m])) == sum(rate(${duration}_bucket{${labels},le="${lastBucket}"}[5m])))
        and on() (overalls:${ratio}:ratio5m)
        and on() (${sourceReady service})
      '';
    };
in
{
  groups = [{
    name = "overalls-otel-baseline";
    interval = "10s";
    rules = [
      { record = "overalls:telemetry_collector_up:ratio1h";
        expr = ''avg_over_time(up{job="overalls-otel",overalls_telemetry_origin=""}[1h])''; }
      { record = "overalls:telemetry_collector_missing:bool";
        expr = ''absent(up{job="overalls-otel",overalls_telemetry_origin=""})''; }
      { record = "overalls:web_ingress_completion:ratio5m";
        expr = ''(sum(rate(haproxy_frontend_http_responses_total{proxy="marshall_public",code=~"2xx|3xx|4xx"}[5m])) / sum(rate(haproxy_frontend_http_requests_total{proxy="marshall_public"}[5m]))) and (sum(rate(haproxy_frontend_http_requests_total{proxy="marshall_public"}[5m])) > 0)''; }
      { record = "overalls:brady_candidate_completion:ratio5m";
        expr = ''(sum(rate(overalls_outer_brady_successes_total{overalls_telemetry_origin="application",service_name="brady"}[5m])) / sum(rate(overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady"}[5m]))) and (sum(rate(overalls_outer_brady_requests_total{overalls_telemetry_origin="application",service_name="brady"}[5m])) > 0) and on() (${sourceReady "brady"})''; }
      { record = "overalls:galileo_candidate_completion:ratio5m";
        expr = ''(sum(rate(overalls_outer_galileo_successes_total{overalls_telemetry_origin="application",service_name="galileo"}[5m])) / sum(rate(overalls_outer_galileo_requests_total{overalls_telemetry_origin="application",service_name="galileo"}[5m]))) and (sum(rate(overalls_outer_galileo_requests_total{overalls_telemetry_origin="application",service_name="galileo"}[5m])) > 0) and on() (${sourceReady "galileo"})''; }
      { record = "overalls:enrico_candidate_completion:ratio5m";
        expr = ''(sum(rate(overalls_outer_enrico_successes_total{overalls_telemetry_origin="application",service_name="enrico"}[5m])) / sum(rate(overalls_outer_enrico_requests_total{overalls_telemetry_origin="application",service_name="enrico"}[5m]))) and (sum(rate(overalls_outer_enrico_requests_total{overalls_telemetry_origin="application",service_name="enrico"}[5m])) > 0) and on() (${sourceReady "enrico"})''; }
      { record = "overalls:porsche_candidate_dispatch:ratio5m";
        expr = ''(sum(rate(overalls_outer_porsche_successes_total{overalls_telemetry_origin="application",service_name="porsche"}[5m])) / sum(rate(overalls_outer_porsche_requests_total{overalls_telemetry_origin="application",service_name="porsche"}[5m]))) and (sum(rate(overalls_outer_porsche_requests_total{overalls_telemetry_origin="application",service_name="porsche"}[5m])) > 0) and on() (${sourceReady "porsche"})''; }
      { record = "overalls:ziggy_candidate_completion:ratio5m";
        expr = ''(sum(rate(overalls_outer_ziggy_successes_total{overalls_telemetry_origin="application",service_name="ziggy"}[5m])) / sum(rate(overalls_outer_ziggy_requests_total{overalls_telemetry_origin="application",service_name="ziggy"}[5m]))) and (sum(rate(overalls_outer_ziggy_requests_total{overalls_telemetry_origin="application",service_name="ziggy"}[5m])) > 0) and on() (${sourceReady "ziggy"})''; }
      { record = "overalls:audi_private_candidate_completion:ratio5m";
        expr = ''(sum(rate(overalls_outer_audi_private_successes_total{overalls_telemetry_origin="application",service_name="audi_private"}[5m])) / sum(rate(overalls_outer_audi_private_requests_total{overalls_telemetry_origin="application",service_name="audi_private"}[5m]))) and (sum(rate(overalls_outer_audi_private_requests_total{overalls_telemetry_origin="application",service_name="audi_private"}[5m])) > 0) and on() (${sourceReady "audi_private"})''; }
      { record = "overalls:audi_dns_candidate_completion:ratio5m";
        expr = ''((sum(rate(overalls_outer_audi_dns_successes_total{overalls_telemetry_origin="application",service_name="audi_dns"}[5m])) / sum(rate(overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns"}[5m]))) and (sum(rate(overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns"}[5m])) > 0)) and on() (${fresh ''overalls_outer_audi_dns_requests_total{overalls_telemetry_origin="application",service_name="audi_dns"''}) and on() (${sourceReady "audi_dns"})''; }
      { record = "overalls:marshall_web_candidate_completion:ratio5m";
        expr = ''((sum(rate(overalls_outer_marshall_web_successes_total{overalls_telemetry_origin="application",service_name="marshall_web",host_name="${central}",service_instance_id="overalls"}[5m])) / sum(rate(overalls_outer_marshall_web_requests_total{overalls_telemetry_origin="application",service_name="marshall_web",host_name="${central}",service_instance_id="overalls"}[5m]))) and (sum(rate(overalls_outer_marshall_web_requests_total{overalls_telemetry_origin="application",service_name="marshall_web",host_name="${central}",service_instance_id="overalls"}[5m])) > 0)) and on() (count((time() - timestamp(overalls_outer_marshall_web_requests_total{overalls_telemetry_origin="application",service_name="marshall_web",host_name="${central}",service_instance_id="overalls"})) < 45) == 1) and on() (${sourceReady "marshall_web"})''; }
      { record = "overalls:marshall_live_candidate_completion:ratio5m";
        expr = ''((sum(rate(overalls_outer_marshall_live_successes_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"}[5m])) / sum(rate(overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"}[5m]))) and (sum(rate(overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"}[5m])) > 0)) and on() (count((time() - timestamp(overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"})) < 45) == 1) and on() (${sourceReady "marshall_live"})''; }
      # Admitted callbacks without a duration sample count as slower than the bound.
      { record = "overalls:marshall_live_latency:ratio5m";
        expr = ''((sum(rate(overalls_outer_marshall_live_duration_seconds_bucket{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls",le="1.0"}[5m])) / sum(rate(overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"}[5m]))) and (sum(rate(overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"}[5m])) > 0)) and on() (count((time() - timestamp(overalls_outer_marshall_live_requests_total{overalls_telemetry_origin="application",service_name="marshall_live",host_name="${central}",service_instance_id="overalls"})) < 45) == 1) and on() (${sourceReady "marshall_live"})''; }
      { record = "overalls:audi_ssh_candidate_establishment:ratio5m";
        expr = ''((sum(rate(overalls_outer_audi_ssh_successes_total{overalls_telemetry_origin="application",service_name="audi_ssh"}[5m])) / sum(rate(overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh"}[5m]))) and (sum(rate(overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh"}[5m])) > 0)) and on() (${fresh ''overalls_outer_audi_ssh_requests_total{overalls_telemetry_origin="application",service_name="audi_ssh"''}) and on() (${sourceReady "audi_ssh"})''; }
      { record = "overalls:underclass_monitor_local_readiness:ratio5m";
        expr = ''avg(avg_over_time(overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name=~"${builtins.concatStringsSep "|" hosts}"}[5m])) and on() (${underclassReady})''; }
      { record = "overalls:underclass_proxy_candidate_completion:ratio5m";
        expr = ''((sum(rate(overalls_outer_underclass_proxy_successes_total{overalls_telemetry_origin="application",service_name="underclass_proxy"}[5m])) / sum(rate(overalls_outer_underclass_proxy_requests_total{overalls_telemetry_origin="application",service_name="underclass_proxy"}[5m]))) and (sum(rate(overalls_outer_underclass_proxy_requests_total{overalls_telemetry_origin="application",service_name="underclass_proxy"}[5m])) > 0)) and on() (${fresh ''overalls_outer_underclass_proxy_requests_total{overalls_telemetry_origin="application",service_name="underclass_proxy"''}) and on() (${sourceReady "underclass_proxy"})''; }
    ] ++ builtins.map (source: {
      record = "overalls:${source.ratio}:ratio5m";
      expr = ''
        (sum(rate(overalls_outer_${source.service}_successes_total{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${central}"}[5m]))
          / sum(rate(overalls_outer_${source.service}_requests_total{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${central}"}[5m])))
        and on() (sum(rate(overalls_outer_${source.service}_requests_total{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${central}"}[5m])) > 0)
        and on() (count(overalls_outer_${source.service}_requests_total{overalls_telemetry_origin="application",service_name="${source.service}"}) == 1)
        and on() (count((time() - timestamp(overalls_outer_${source.service}_requests_total{overalls_telemetry_origin="application",service_name="${source.service}",host_name="${central}"})) < 45) == 1)
        and on() (${sourceReady source.service})
      '';
    }) (builtins.filter (source: builtins.elem source.service ((import ./durable-services.nix)
        ++ [ "vscode_browser_nixos" "vscode_browser_ubuntu" ])) latencySources)
      ++ builtins.map latencyRule latencySources;
  }];
}
