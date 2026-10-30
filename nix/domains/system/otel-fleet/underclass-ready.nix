{ hosts }:
let
  metric = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name=~"${builtins.concatStringsSep "|" hosts}"}'';
  clock = ''overalls_underclass_monitor_sample_time{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name=~"${builtins.concatStringsSep "|" hosts}"}'';
  # Exactly one series from each roster host, joined without a dangling clause.
  once = name: builtins.concatStringsSep "\nand " (builtins.map (host:
    ''count(${name}{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="${host}"}) == 1'') hosts);
in
# @cc [owner:ghuntley,label:reliability;verification] underclass-both-hosts-observed
# A local monitor candidate exists only with exactly one fresh, complete probe
# series and source sampling clock from each enrolled host. Missing, cached older
# than 45 seconds or more than two seconds future observations MUST remain unknown.
''
  ${once "overalls_underclass_monitor_ready"}
  and (min(count_over_time(${metric}[5m])) >= 10)
  and (max(time() - timestamp(${metric})) < 45)
  and ${once "overalls_underclass_monitor_sample_time"}
  and (max(time() - ${clock}) < 45)
  and (min(time() - ${clock}) >= -2)
''
