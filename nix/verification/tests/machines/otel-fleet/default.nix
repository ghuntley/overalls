{ pkgs }:
let
  sloExporter = pkgs.callPackage ../../../../domains/system/otel-guest/receiver.nix {};
  underclassModule = import ../../../../domains/system/underclass.nix {
    packages.underclass = pkgs.callPackage ../../../../domains/artifacts/underclass/default.nix {};
  };
  keys = pkgs.runCommand "otel-fleet-disposable-wireguard-keys" {
    nativeBuildInputs = [ pkgs.wireguard-tools ];
  } ''
    mkdir -p "$out"
    for name in central worker; do
      wg genkey > "$out/$name.key"
      wg pubkey < "$out/$name.key" > "$out/$name.pub"
    done
  '';
  # @cc [owner:ghuntley,label:verification;security] otel-fleet-tunnel-fixture
  # The two-node telemetry test MUST use the production fleet WireGuard module
  # and disposable keys. Collector and Tempo traffic MUST use authenticated
  # tunnel addresses, never physical test-network aliases.
  fleetHost = name: other: address: peerAddress: { config, nodes, lib, ... }: {
    imports = [ ../../../../domains/system/fleet-network.nix ];
    overalls.fleetNetwork = {
      enable = true;
      inherit address;
      endpointAddress = config.networking.primaryIPAddress;
      privateKeyFile = "/run/otel-fleet-key/private";
      secretUnits = [ "otel-fleet-key.service" ];
      tcpPorts = if name == "central" then [ 4317 9464 ] else [ 9464 ];
      peers.${other} = {
        address = peerAddress;
        endpointAddress = nodes.${other}.networking.primaryIPAddress;
        publicKey = lib.removeSuffix "\n" (builtins.readFile "${keys}/${other}.pub");
      };
    };
    systemd.services.otel-fleet-key = {
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "otel-fleet-key";
        RuntimeDirectoryMode = "0700";
      };
      script = "install -m 0600 ${keys}/${name}.key /run/otel-fleet-key/private";
    };
  };
  metric = pkgs.runCommand "otel-guest-test-metric" { nativeBuildInputs = [ pkgs.xxd ]; } ''
    xxd -r -p ${./metric.hex} > $out
  '';
  forged = pkgs.runCommand "otel-guest-forged-metric" { nativeBuildInputs = [ pkgs.xxd pkgs.gnused ]; } ''
    sed 's/6775657374/6f75746572/' ${./metric.hex} | xxd -r -p > $out
  '';
  traceFixture = pkgs.runCommand "otel-trace-replay-fixture" {
    nativeBuildInputs = [ pkgs.rustc pkgs.stdenv.cc ];
  } ''
    mkdir -p "$out/bin"
    rustc --edition=2021 -D warnings ${./trace_fixture.rs} -o "$out/bin/otel-trace-replay-fixture"
  '';
  binding = "eyJob3N0X2lkIjoiMTIzNDU2NzgtMTIzNC0xMjM0LTEyMzQtMTIzNDU2Nzg5YWJjIiwidm1faWQiOiIyMjM0NTY3OC0xMjM0LTEyMzQtMTIzNC0xMjM0NTY3ODlhYmMiLCJwbGFjZW1lbnRfaWQiOiIzMjM0NTY3OC0xMjM0LTEyMzQtMTIzNC0xMjM0NTY3ODlhYmMiLCJleGVjdXRpb25fZXBvY2giOjF9";
  groupSnapshotFixtures = { lib, ... }: {
    # Snapshots use the request recorder's group custody: a non-root writer,
    # a 0750 source directory and a 0640 file owned by the exporter's group.
    users.groups.otel-test-brady-source = {};
    users.users.otel-test-brady-exporter = { isSystemUser = true; group = "otel-test-brady-source"; };
    users.groups.otel-test-audi-private-source = {};
    users.users.otel-test-audi-private-exporter = { isSystemUser = true; group = "otel-test-audi-private-source"; };
    users.groups.otel-test-audi-dns-source = {};
    users.users.otel-test-audi-dns-exporter = { isSystemUser = true; group = "otel-test-audi-dns-source"; };
    systemd.services = lib.mkMerge (map (fixture: {
      "otel-test-${fixture.unit}-snapshot" = {
        serviceConfig = {
          Type = "oneshot"; User = fixture.writer; Group = "otel-test-${fixture.unit}-source";
          RuntimeDirectory = "${fixture.unit}-slo-test"; RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = "yes"; UMask = "0027";
        };
        script = ''
          now=$(${pkgs.coreutils}/bin/date +%s%N)
          start=$((now - 1000000000))
          ${pkgs.coreutils}/bin/printf '{"version":1,"service":"${fixture.service}","sampled_at_unix_nano":%s,"started_at_unix_nano":%s,"incarnation":"${fixture.identity}","invocation_id":"${fixture.identity}","requests":2,"successes":1,"failures":1,"duration":{"count":2,"sum_us":20000,"explicit_bounds_us":[10000,50000,100000,500000,1000000,5000000,10000000],"bucket_counts":[1,1,0,0,0,0,0,0]}}' "$now" "$start" > /run/${fixture.unit}-slo-test/slo.json
          ${pkgs.coreutils}/bin/chmod 0640 /run/${fixture.unit}-slo-test/slo.json
        '';
      };
      "otel-test-${fixture.unit}-exporter" = {
        serviceConfig = {
          Type = "exec"; User = "otel-test-${fixture.unit}-exporter";
          Group = "otel-test-${fixture.unit}-source";
          SupplementaryGroups = [ fixture.collectorGroup ];
          ProtectSystem = "strict";
          ExecStart = "${sloExporter}/bin/slo_exporter --recorder-group-source ${fixture.service} /run/${fixture.unit}-slo-test/slo.json /run/${fixture.collectorGroup}/collector.sock";
        };
      };
    }) [
      { unit = "brady"; service = "brady"; writer = "brady"; collectorGroup = "overalls-otel-app";
        identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
      { unit = "audi-private"; service = "audi_private"; writer = "audi"; collectorGroup = "overalls-otel-audi-private";
        identity = "cccccccccccccccccccccccccccccccc"; }
      { unit = "audi-dns"; service = "audi_dns"; writer = "audi-dns"; collectorGroup = "overalls-otel-audi-dns";
        identity = "dddddddddddddddddddddddddddddddd"; }
    ]);
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-otel-fleet";
  nodes.central = { lib, ... }: {
    imports = [ ../../../../domains/system/otel-fleet ../../../../domains/system/otel-guest underclassModule groupSnapshotFixtures (fleetHost "central" "worker" "10.90.0.1" "10.90.0.2") ];
    options = {
      services.audiPrivate.enable = lib.mkOption { type = lib.types.bool; default = false; };
      services.lilly.enable = lib.mkOption { type = lib.types.bool; default = false; };
    };
    config = {
    networking.hostName = "panterloons";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    services.audiPrivate.enable = true;
    services.lilly.enable = true;
    services.overallsOtelFleet = { enable = true; role = "central"; hosts = { central = "panterloons"; worker = "dungarees"; }; };
    services.overallsLogging = {
      enable = true;
      outputs.fixture = { type = "native"; plugin = "stdout"; sources = [ "galileo" "marshall" ]; queueBytes = 8388608; };
    };
    systemd.services.galileo = {
      serviceConfig = { Type = "simple"; User = "galileo"; Group = "galileo"; };
      script = ''
        while true; do
          printf '%s\n' '{"message":"Observability producer health observed","metadata":{"event":"galileo.observability_health","trace_available":1,"trace_pending":17,"trace_queue_dropped":23,"trace_export_failed":29,"trace_observed_at_seconds":1}}'
          sleep 30
        done
      '';
    };
    systemd.services.marshall-runtime-fixture = {
      serviceConfig = { Type = "simple"; DynamicUser = true; };
      script = ''
        while true; do
          printf '%s\n' '{"message":"Runtime metrics observed","metadata":{"event":"marshall.runtime_metrics","beam_memory_bytes":123456,"beam_run_queue":7,"terminal_host_streams":4,"runtime_observed_at_seconds":1}}'
          sleep 30
        done
      '';
    };
    services.underclass = { enable = true; tailscaleServe.enable = false; environmentFile = "/etc/underclass-test.env"; };
    environment.etc."underclass-test.env".text = ''
      UNDERCLASS_PROXY_KEY=synthetic-proxy-key
      UNDERCLASS_UI_TOKEN=synthetic-admin-token
    '';
    services.haproxy = {
      enable = true;
      config = ''
        global
          maxconn 100
        defaults
          mode http
          timeout connect 1s
          timeout client 3s
          timeout server 1s
        frontend marshall_public
          bind 127.0.0.1:18085
          http-request return status 200 content-type text/plain string ok if { path /ok }
          http-request return status 503 content-type text/plain string unavailable
        frontend marshall_slo_metrics
          bind 127.0.0.1:8405
          http-request use-service prometheus-exporter if { path /metrics }
          http-request deny
      '';
    };
    users.groups.audi = {};
    users.users.audi = { isSystemUser = true; group = "audi"; extraGroups = [ "overalls-otel-guest" ]; };
    users.groups.audi-dns = {};
    users.users.audi-dns = { isSystemUser = true; group = "audi-dns"; };
    users.groups.brady = {};
    users.users.brady = { isSystemUser = true; group = "brady"; };
    users.groups.galileo = {};
    users.users.galileo = { isSystemUser = true; group = "galileo"; };
    systemd.services.otel-test-marshall-snapshot = {
      serviceConfig = {
        Type = "oneshot"; RemainAfterExit = true;
        DynamicUser = true; User = "marshall-slo-test";
        Group = "overalls-otel-marshall-source";
        RuntimeDirectory = "marshall-slo-test";
        RuntimeDirectoryMode = "0750";
        ReadWritePaths = [ "/run/marshall-slo-test" ];
        UMask = "0077";
      };
      script = ''
        now=$(${pkgs.coreutils}/bin/date +%s%N)
        start=$((now - 1000000000))
        ${pkgs.coreutils}/bin/printf '{"version":1,"service":"marshall_web","sampled_at_unix_nano":%s,"started_at_unix_nano":%s,"incarnation":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","invocation_id":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","requests":2,"successes":1,"failures":1,"duration":{"count":2,"sum_us":20000,"explicit_bounds_us":[10000,50000,100000,500000,1000000,5000000,10000000],"bucket_counts":[1,1,0,0,0,0,0,0]}}' "$now" "$start" > /run/marshall-slo-test/slo.json
        ${pkgs.coreutils}/bin/chmod 0640 /run/marshall-slo-test/slo.json
      '';
    };
    systemd.services.otel-test-marshall-exporter = {
      serviceConfig = {
        Type = "exec"; User = "overalls-otel-marshall-exporter";
        Group = "overalls-otel-marshall-source";
        SupplementaryGroups = [ "overalls-otel-marshall" ];
        ProtectSystem = "strict";
        ExecStart = "${sloExporter}/bin/slo_exporter --recorder-group-source marshall_web /run/marshall-slo-test/slo.json /run/overalls-otel-marshall/collector.sock overalls";
      };
    };
    users.groups.overalls-otel-audi-ssh-source = {};
    users.users.overalls-otel-audi-ssh-exporter = {
      isSystemUser = true;
      group = "overalls-otel-audi-ssh-source";
    };
    systemd.services.otel-test-audi-ssh-snapshot = {
      serviceConfig = {
        Type = "oneshot"; User = "audi"; Group = "overalls-otel-audi-ssh-source";
        RuntimeDirectory = "audi-ssh-test"; RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "yes"; UMask = "0027";
      };
      script = ''
        now=$(${pkgs.coreutils}/bin/date +%s%N)
        start=$((now - 1000000000))
        ${pkgs.coreutils}/bin/printf '{"version":1,"service":"audi_ssh","sampled_at_unix_nano":%s,"started_at_unix_nano":%s,"incarnation":"ffffffffffffffffffffffffffffffff","invocation_id":"ffffffffffffffffffffffffffffffff","requests":2,"successes":1,"failures":1,"duration":{"count":2,"sum_us":20000,"explicit_bounds_us":[10000,50000,100000,500000,1000000,5000000,10000000],"bucket_counts":[1,1,0,0,0,0,0,0]}}' "$now" "$start" > /run/audi-ssh-test/slo.json
        ${pkgs.coreutils}/bin/chmod 0640 /run/audi-ssh-test/slo.json
      '';
    };
    systemd.services.otel-test-audi-ssh-exporter = {
      serviceConfig = {
        Type = "exec"; User = "overalls-otel-audi-ssh-exporter";
        Group = "overalls-otel-audi-ssh-source";
        SupplementaryGroups = [ "overalls-otel-audi-ssh" ];
        ProtectSystem = "strict";
        ExecStart = "${sloExporter}/bin/slo_exporter --recorder-group-source audi_ssh /run/audi-ssh-test/slo.json /run/overalls-otel-audi-ssh/collector.sock";
      };
    };
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
    };
  };
  nodes.worker = { lib, ... }: {
    imports = [ ../../../../domains/system/otel-fleet ../../../../domains/system/otel-guest underclassModule (fleetHost "worker" "central" "10.90.0.2" "10.90.0.1") ];
    options = {
      services.audiPrivate.enable = lib.mkOption { type = lib.types.bool; default = false; };
      services.lilly.enable = lib.mkOption { type = lib.types.bool; default = false; };
    };
    config = {
      networking.hostName = "dungarees";
      virtualisation.memorySize = 2048;
      virtualisation.cores = 1;
      services.audiPrivate.enable = true;
      services.lilly.enable = true;
      services.overallsOtelFleet = { enable = true; role = "worker"; hosts = { central = "panterloons"; worker = "dungarees"; }; };
      services.underclass = { enable = true; tailscaleServe.enable = false; environmentFile = "/etc/underclass-test.env"; };
      environment.etc."underclass-test.env".text = ''
        UNDERCLASS_PROXY_KEY=synthetic-proxy-key
        UNDERCLASS_UI_TOKEN=synthetic-admin-token
      '';
      users.groups.audi = {};
      users.users.audi = { isSystemUser = true; group = "audi"; extraGroups = [ "overalls-otel-guest" ]; };
      environment.systemPackages = [ pkgs.curl ];
    };
  };
  testScript = ''
    # @cc [owner:ghuntley,label:verification] otel-machine-boundary
    # The fixture MUST boot both collectors, prove central scraping and
    # failure recovery, exact collector recording selection, and reject forged
    # guest provenance at the Unix socket.
    # It does not claim native Firecracker or physical-host acceptance.
    start_all()
    central.wait_for_unit("wireguard-fleet0.service")
    worker.wait_for_unit("wireguard-fleet0.service")
    central.wait_for_unit("opentelemetry-collector.service")
    worker.wait_for_unit("opentelemetry-collector.service")
    central.wait_for_unit("prometheus.service")
    central.wait_for_unit("haproxy.service")
    central.wait_for_unit("tempo.service")
    central.wait_for_unit("grafana.service")
    central.wait_for_unit("overalls-otel-guest.service")
    central.wait_for_unit("overalls-logging.service")
    central.succeed("systemctl start galileo.service")
    central.succeed("systemctl start marshall-runtime-fixture.service")
    central.wait_until_succeeds("curl -fsS http://127.0.0.1:9468/metrics | grep -E '^overalls_gauge_trace_pending\\{[^}]*service=\"galileo\"[^}]*\\} 17'", timeout=120)
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls_gauge_trace_pending{host_name=\"panterloons\",service=\"galileo\",unit=\"galileo.service\"} == 17' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1'", timeout=120)
    central.succeed("journalctl -u overalls-logging.service --no-pager | grep 'galileo.observability_health' | grep 'galileo.service'")
    worker.fail("curl --max-time 2 -fsS http://10.90.0.1:9468/metrics")
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=time() - overalls_gauge_trace_observed_at_seconds{host_name=\"panterloons\",service=\"galileo\",unit=\"galileo.service\"} < 90' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1'", timeout=120)
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls_gauge_beam_memory_bytes{host_name=\"panterloons\",service=\"marshall\",unit=\"marshall-runtime-fixture.service\"} == 123456' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1'", timeout=120)
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls_gauge_terminal_host_streams{host_name=\"panterloons\",service=\"marshall\",unit=\"marshall-runtime-fixture.service\"} == 4' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1'", timeout=120)
    central.wait_for_unit("underclass.service")
    worker.wait_for_unit("underclass.service")
    central.wait_for_unit("underclass-monitor-probe.service")
    worker.wait_for_unit("underclass-monitor-probe.service")
    # Confirm the real source clock stays inside the production freshness
    # guard after probe, collector and Prometheus scheduling are active.
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=max(time() - overalls_underclass_monitor_sample_time{overalls_telemetry_origin=\"application\",service_name=\"underclass_monitor\"}) < 45' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1'", timeout=120)
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_underclass_monitor_ready\\{[^}]*host_name=\\\"panterloons\\\"[^}]*\\} 1'")
    worker.wait_until_succeeds("curl -fsS http://10.90.0.2:9464/metrics | grep -E 'overalls_underclass_monitor_ready\\{[^}]*host_name=\\\"dungarees\\\"[^}]*\\} 1'")
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls:underclass_monitor_local_readiness:ratio5m' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1 and .[0].value[1] == \"1\"'", timeout=420)
    worker.succeed("systemctl stop underclass.service")
    worker.wait_until_succeeds("curl -fsS http://10.90.0.2:9464/metrics | grep -E 'overalls_underclass_monitor_ready\\{[^}]*host_name=\\\"dungarees\\\"[^}]*\\} 0'", timeout=60)
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls:underclass_monitor_local_readiness:ratio5m' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1 and (.[0].value[1] | tonumber) < 1'", timeout=90)
    worker.succeed("systemctl start underclass.service")
    worker.wait_until_succeeds("curl -fsS http://10.90.0.2:9464/metrics | grep -E 'overalls_underclass_monitor_ready\\{[^}]*host_name=\\\"dungarees\\\"[^}]*\\} 1'", timeout=60)
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -q system_cpu")
    central.succeed("curl -fsS http://127.0.0.1:18085/ok | grep -q ok")
    central.succeed("curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18085/failure | grep -q '^503$'")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics > /tmp/otel-exported-metrics && grep -q 'haproxy_frontend_http_responses_total' /tmp/otel-exported-metrics")
    central.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Binstance%3D%2210.90.0.1%3A9464%22%7D' | jq -e '.data.result[0].value[1] == \"1\"'")
    worker.wait_until_succeeds("curl -fsS http://10.90.0.2:9464/metrics | grep -q system_cpu")
    central.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Binstance%3D%2210.90.0.2%3A9464%22%7D' | jq -e '.data.result[0].value[1] == \"1\"'")
    central.succeed("wg show fleet0 latest-handshakes | awk '$2 > 0 {ok=1} END {exit !ok}'")
    worker.succeed("wg show fleet0 latest-handshakes | awk '$2 > 0 {ok=1} END {exit !ok}'")
    worker.fail("curl -fsS --max-time 3 http://central:9464/metrics")
    central.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls:telemetry_collector_up:ratio1h{overalls_telemetry_origin=\"\"}' http://127.0.0.1:9090/api/v1/query | jq -e '[.data.result[].metric.instance] | sort == [\"10.90.0.1:9464\", \"10.90.0.2:9464\"]'")
    worker.succeed("systemctl stop opentelemetry-collector.service")
    central.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Binstance%3D%2210.90.0.2%3A9464%22%7D' | jq -e '.data.result[0].value[1] == \"0\"'")
    worker.succeed("systemctl start opentelemetry-collector.service")
    central.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Binstance%3D%2210.90.0.2%3A9464%22%7D' | jq -e '.data.result[0].value[1] == \"1\"'")
    central.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/health | grep -q ok")
    central.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' --user operator:wrong http://127.0.0.1:3000/api/user) = 401")
    worker.fail("curl --max-time 2 -fsS http://10.90.0.1:3000/api/user")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/user | jq -e '.login == \"operator\"'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '.dashboard.panels[0].targets[0].expr == \"overalls:telemetry_collector_up:ratio1h{overalls_telemetry_origin=\\\"\\\"}\"'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '([.dashboard.panels[] | select(.title | startswith(\"Audi DNS candidate authoritative answer\"))][0]).targets[0].expr | contains(\"overalls_outer_audi_dns_source_start_time\")'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '.dashboard.panels | length == 67'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '[.dashboard.panels[].targets[0].expr] | any(contains(\"overalls:slo_collectors:ratio7d\")) and any(contains(\"overalls:slo_underclass_monitor:ratio7d\")) and any(contains(\"overalls:slo_marshall_ready:ratio7d\")) and any(contains(\"overalls:slo_lilly_physical:ratio7d\")) and any(contains(\"overalls:slo_porsche_physical:ratio7d\"))'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '([.dashboard.panels[] | select(.title | startswith(\"Brady admitted terminal request, provisional\"))][0]).targets[0].expr | contains(\"overalls_outer_brady_source_start_time\")'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '([.dashboard.panels[] | select(.title | startswith(\"Brady admitted terminal request candidate p95\"))][0]).targets[0].expr | (contains(\"overalls:brady_candidate_duration:p95_5m\") and contains(\"overalls_outer_brady_source_start_time\") and contains(\"rate(overalls_outer_brady_requests_total\"))'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '([.dashboard.panels[] | select(.title | startswith(\"Audi guest SSH establishment candidate p95\"))][0]).targets[0].expr | (contains(\"overalls:audi_ssh_candidate_duration:p95_5m\") and contains(\"overalls_outer_audi_ssh_source_start_time\") and contains(\"rate(overalls_outer_audi_ssh_requests_total\"))'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-otel-baseline | jq -e '([.dashboard.panels[] | select(.title | startswith(\"Underclass local monitor readiness candidate\"))][0]).targets[0].expr | (contains(\"overalls:underclass_monitor_local_readiness:ratio5m\") and contains(\"host_name=\\\"panterloons\\\"\") and contains(\"host_name=\\\"dungarees\\\"\"))'")
    central.succeed("password=$(cat /var/lib/grafana/admin-password); curl -fsS --user \"operator:$password\" http://127.0.0.1:3000/api/dashboards/uid/overalls-marshall-pages | jq -e '(.dashboard.panels | length == 14) and (.dashboard.panels[0].targets[0].expr | contains(\"overalls:slo_marshall_live:ratio7d\")) and (.dashboard.panels[1].targets[0].expr | contains(\"overalls:slo_marshall_live_latency:ratio7d\")) and ([.dashboard.panels[] | select(.title | startswith(\"SLI\")) | .targets[0].expr] | all(contains(\"overalls_outer_marshall_live_source_start_time\"))) and ([.dashboard.panels[] | select(.title | startswith(\"SLI\") or contains(\"objective\")) | .targets[0].expr] | all(contains(\"overalls_gauge_\") | not))'")
    central.succeed("curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-guest/receiver.sock -H 'Content-Type: application/x-protobuf' -H 'Transfer-Encoding: chunked' --data-binary x http://localhost/v1/metrics | grep -q '^403$'")
    central.succeed("runuser -u audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-guest/receiver.sock -H 'Content-Type: application/x-protobuf' -H 'Transfer-Encoding: chunked' --data-binary x http://localhost/v1/metrics | grep -q '^400$'")
    central.succeed("runuser -u audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-guest/receiver.sock -H 'Content-Type: application/x-protobuf' -H 'Transfer-Encoding: chunked' -H 'X-Overalls-Binding: ${binding}' --data-binary @${metric} http://localhost/v1/metrics | grep -q '^200$'")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -q 'overalls_guest_requests'")
    # deployment-info-series: one revision series per host, unlabelled elsewhere.
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E '^overalls_deployment_info[a-z_]*\\{.*overalls_deployment_revision=\"unknown\"' | grep -q host_name")
    central.fail("curl -fsS http://10.90.0.1:9464/metrics | grep -v '^overalls_deployment_info' | grep -q overalls_deployment_revision")
    central.succeed("systemctl start otel-test-brady-snapshot.service")
    central.succeed("code=$(runuser -u brady -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-app/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("test $(stat -c %G /run/overalls-otel-galileo/collector.sock) = overalls-otel-galileo")
    central.succeed("code=$(runuser -u galileo -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-galileo/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("code=$(runuser -u brady -g overalls-otel-app -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-galileo/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("test -d /var/lib/opentelemetry-collector/traces-queue")
    central.fail("runuser -u brady -g overalls-otel-app -- ls /var/lib/opentelemetry-collector/traces-queue")
    central.succeed("printf '\\172\\001\\000' > /tmp/small-otlp; test $(curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-app/collector.sock -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/small-otlp http://localhost/v1/metrics) = 200")
    central.succeed("test $(runuser -u galileo -g overalls-otel-galileo -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-galileo/collector.sock -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/small-otlp http://localhost/v1/metrics) = 200")
    central.succeed("printf '\\172\\200\\100' > /tmp/oversized-otlp; head -c 8192 /dev/zero >> /tmp/oversized-otlp")
    central.succeed("code=$(curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-app/collector.sock -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/oversized-otlp http://localhost/v1/metrics); case \"$code\" in 400|413) exit 0;; *) echo \"unexpected status $code\"; exit 1;; esac")
    central.succeed("systemctl start otel-test-brady-exporter.service")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -q 'overalls_outer_brady_requests_total.* 2'")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_brady_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_name=\"brady\"[^}]*\\} 2'")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_brady_source_start_time\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_name=\"brady\"[^}]*\\}'")
    central.succeed("systemctl start otel-test-audi-private-snapshot.service")
    central.succeed("code=$(runuser -u audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-audi-private/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("systemctl start otel-test-audi-private-exporter.service")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_audi_private_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_name=\"audi_private\"[^}]*\\} 2'")
    central.succeed("systemctl start otel-test-audi-dns-snapshot.service")
    central.succeed("code=$(runuser -u audi-dns -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-audi-dns/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("systemctl start otel-test-audi-dns-exporter.service")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_audi_dns_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_name=\"audi_dns\"[^}]*\\} 2'")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_audi_dns_requests_total\\{[^}]*host_name=\"panterloons\"[^}]*\\} 2'")
    central.succeed("systemctl start otel-test-marshall-snapshot.service")
    print(central.succeed("stat -c 'slo directory mode=%a uid=%u gid=%g' /run/marshall-slo-test"))
    directory_mode = int(central.succeed("stat -c %a /run/marshall-slo-test").strip(), 8)
    assert directory_mode & 0o777 == 0o750, f"unexpected directory mode {directory_mode:o}"
    central.fail("runuser -u overalls-otel-marshall-exporter -- test -w /run/marshall-slo-test")
    snapshot_uid = central.succeed("stat -c %u /run/marshall-slo-test/slo.json").strip()
    directory_uid = central.succeed("stat -c %u /run/marshall-slo-test").strip()
    assert snapshot_uid == directory_uid and snapshot_uid != "0", f"snapshot UID {snapshot_uid}, directory UID {directory_uid}"
    central.succeed("test $(stat -c %g /run/marshall-slo-test/slo.json) = $(getent group overalls-otel-marshall-source | cut -d: -f3)")
    central.succeed("runuser -u marshall-slo-test -g overalls-otel-marshall-source -- test -r /run/marshall-slo-test/slo.json")
    central.succeed("code=$(runuser -u marshall-slo-test -g overalls-otel-marshall-source -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-marshall/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("systemctl start otel-test-marshall-exporter.service")
    central.succeed("systemctl is-active --quiet otel-test-marshall-exporter.service")
    central.succeed("pid=$(systemctl show -P MainPID otel-test-marshall-exporter.service); test $pid -gt 0; test $(stat -c %u /proc/$pid) = $(id -u overalls-otel-marshall-exporter)")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -q 'overalls_outer_marshall_web_requests_total'")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_marshall_web_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_instance_id=\"overalls\"[^}]*\\} 2'")
    central.succeed("systemctl start otel-test-audi-ssh-snapshot.service")
    central.succeed("test $(stat -c %a /run/audi-ssh-test) = 750")
    central.succeed("test $(stat -c %a /run/audi-ssh-test/slo.json) = 640")
    central.fail("runuser -u overalls-otel-audi-ssh-exporter -- test -w /run/audi-ssh-test")
    central.succeed("code=$(runuser -u audi -g audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-audi-ssh/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    central.succeed("systemctl start otel-test-audi-ssh-exporter.service")
    central.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_audi_ssh_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_name=\"audi_ssh\"[^}]*\\} 2'")
    central.succeed("runuser -u audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-guest/receiver.sock -H 'Content-Type: application/x-protobuf' -H 'Transfer-Encoding: chunked' -H 'X-Overalls-Binding: ${binding}' --data-binary @${forged} http://localhost/v1/metrics | grep -q '^400$'")
    central.fail("curl -fsS http://10.90.0.1:9464/metrics | grep -q 'overalls_outer_requests'")
    central.succeed("for i in $(seq 1 70); do code=$(runuser -u audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-guest/receiver.sock -H 'Content-Type: application/x-protobuf' -H 'Transfer-Encoding: chunked' -H 'X-Overalls-Binding: ${binding}' --data-binary @${metric} http://localhost/v1/metrics); case $code in 429) exit 0;; 200) ;; *) echo unexpected_receiver_status=$code; exit 1;; esac; done; exit 1")
    # @cc [owner:ghuntley,label:verification;reliability] otel-worker-trace-queue-replay
    # A trace accepted by the worker while central Tempo is unavailable MUST
    # survive an immediate worker Collector SIGKILL and become queryable after Tempo
    # returns across the authenticated fleet tunnel.
    central.succeed("systemctl stop tempo.service")
    central.fail("curl -fsS http://127.0.0.1:3200/ready")
    worker.succeed("${traceFixture}/bin/otel-trace-replay-fixture /tmp/otel-replay-trace.pb")
    worker.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otel-replay-trace.pb http://127.0.0.1:4318/v1/traces) = 200")
    worker.succeed("systemctl kill --kill-whom=main --signal=KILL opentelemetry-collector.service")
    worker.succeed("systemctl restart opentelemetry-collector.service")
    worker.wait_for_unit("opentelemetry-collector.service")
    central.fail("curl -fsS http://127.0.0.1:3200/ready")
    central.succeed("systemctl start tempo.service")
    central.wait_for_unit("tempo.service")
    central.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/api/traces/00112233445566778899aabbccddeeff | grep -q 'otel.replay.fixture'", timeout=90)
    # @cc [owner:ghuntley,label:verification;reliability] otel-wireguard-outage-replay
    # A second trace admitted while the authenticated tunnel is down MUST
    # survive an immediate worker Collector SIGKILL and reach central Tempo only after
    # the tunnel returns. No direct physical route may bypass the outage.
    worker.succeed("ip link set fleet0 down")
    central.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Binstance%3D%2210.90.0.2%3A9464%22%7D' | jq -e '.data.result[0].value[1] == \"0\"'", timeout=90)
    worker.succeed("${traceFixture}/bin/otel-trace-replay-fixture /tmp/otel-wireguard-trace.pb 1")
    worker.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otel-wireguard-trace.pb http://127.0.0.1:4318/v1/traces) = 200")
    worker.succeed("systemctl kill --kill-whom=main --signal=KILL opentelemetry-collector.service")
    worker.succeed("systemctl restart opentelemetry-collector.service")
    worker.wait_for_unit("opentelemetry-collector.service")
    central.fail("curl -fsS http://127.0.0.1:3200/api/traces/00112233445566778899aabbccddee01")
    worker.succeed("systemctl restart wireguard-fleet0.service")
    worker.wait_until_succeeds("curl -fsS --max-time 3 http://10.90.0.1:9464/metrics | grep -q system_cpu", timeout=60)
    central.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/api/traces/00112233445566778899aabbccddee01 | grep -q 'otel.replay.fixture'", timeout=180)
    # @cc [owner:ghuntley,label:verification;reliability] application-trace-queue-ack-custody
    # A trace acknowledged through the dedicated application socket MUST survive
    # an immediate Collector SIGKILL while Tempo is down, then reach Tempo.
    # The application queue MUST remain private and separate from guest traces.
    central.succeed("systemctl stop tempo.service")
    worker.succeed("test -d /var/lib/opentelemetry-collector/application-traces-queue")
    worker.fail("runuser -u brady -g overalls-otel-app -- ls /var/lib/opentelemetry-collector/application-traces-queue")
    worker.succeed("${traceFixture}/bin/otel-trace-replay-fixture /tmp/otel-application-trace.pb 2")
    worker.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-traces/collector.sock -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otel-application-trace.pb http://localhost/v1/traces) = 200")
    worker.succeed("systemctl kill --kill-whom=main --signal=KILL opentelemetry-collector.service")
    worker.succeed("systemctl restart opentelemetry-collector.service")
    worker.wait_for_unit("opentelemetry-collector.service")
    central.fail("curl -fsS http://127.0.0.1:3200/ready")
    central.succeed("systemctl start tempo.service")
    central.wait_for_unit("tempo.service")
    central.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/api/traces/00112233445566778899aabbccddee02 | grep -q 'otel.replay.fixture'", timeout=180)
    # @cc [owner:ghuntley,label:verification;reliability] ingress-source-health-refusal
    # A stopped HAProxy source MUST turn direct scrape health to zero while
    # collector health stays one; recovery MUST restore source health.
    ingress_health: str = "curl -fsSG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=up{job=\"overalls-ingress-source\"}'"
    central.wait_until_succeeds(ingress_health + " | jq -e '.data.result | length == 1 and .[0].value[1] == \"1\"'")
    central.succeed("systemctl stop haproxy.service")
    central.wait_until_succeeds(ingress_health + " | jq -e '.data.result | length == 1 and .[0].value[1] == \"0\"'", timeout=90)
    central.wait_until_succeeds("curl -fsSG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=up{job=\"overalls-otel\",overalls_telemetry_origin=\"\"}' | jq -e '.data.result | length == 2 and all(.[]; .value[1] == \"1\")'", timeout=90)
    central.succeed("systemctl start haproxy.service")
    central.wait_until_succeeds(ingress_health + " | jq -e '.data.result | length == 1 and .[0].value[1] == \"1\"'", timeout=90)
  '';
}
