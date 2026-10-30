{ pkgs, module, packages }:
let
  # @cc [owner:ghuntley,label:verification;security] dns-fixture-local-process-control
  # Only the disposable VM MAY enable this loopback release RPC with a synthetic
  # cookie. DNS MUST execute the actual packaged release; production remains
  # non-distributed. No DNS authority or measurement result may be injected.
  nativeDns = pkgs.writeShellScriptBin "audi" ''
    export RELEASE_DISTRIBUTION=name
    export RELEASE_NODE=audi_dns_native@127.0.0.1
    export RELEASE_COOKIE=native_dns_fixture_cookie
    export ERL_EPMD_ADDRESS=127.0.0.1
    export ERL_FLAGS="''${ERL_FLAGS:-} -kernel inet_dist_use_interface {127,0,0,1}"
    if [ "''${1:-}" = start ]; then
      export ERL_FLAGS="$ERL_FLAGS -kernel inet_dist_listen_min 22555 inet_dist_listen_max 22555"
    fi
    exec ${packages.audi}/bin/audi "$@"
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-audi-dns";
  nodes.server = { ... }: {
    imports = [ module (import ../../support/request-source.nix {
      inherit pkgs packages; name = "audi-dns"; source = "audi_dns";
      producerUser = "audi-dns"; producerUnit = "audi-dns.service";
      deadlineSeconds = 30; collectorGroup = "overalls-otel-audi-dns";
    }) ];
    virtualisation.memorySize = 1024;
    services.audiDns = {
      enable = true;
      package = nativeDns;
      controlPlane = "https://127.0.0.1:9443";
      credentialFile = "/run/audi-dns-test/token";
      caFile = "${../../../../../marshall/test/fixtures/tls/ca.pem}";
      secretUnits = [ "audi-dns-test-credential.service" ];
      zone = "apps.example";
      nameservers = [ "ns1.example" "ns2.example" ];
      mailbox = "hostmaster.example";
      openFirewall = true;
    };
    environment.systemPackages = [ pkgs.dig pkgs.python3 pkgs.jq pkgs.curl nativeDns ];
    environment.etc."dns-native-hold.exs".source = ./hold.exs;
    users.groups.overalls-otel-audi-dns = {};
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      settings = {
        receivers."otlp/application-audi-dns".protocols.http = {
          endpoint = "/run/overalls-otel-audi-dns/collector.sock";
          transport = "unix"; max_request_body_size = 4096;
        };
        processors."resource/application-audi-dns".attributes = [
          { key = "service.name"; value = "audi_dns"; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
        ];
        exporters.prometheus = {
          endpoint = "127.0.0.1:9464";
          resource_to_telemetry_conversion.enabled = true;
        };
        service.pipelines."metrics/application-audi-dns" = {
          receivers = [ "otlp/application-audi-dns" ];
          processors = [ "resource/application-audi-dns" ];
          exporters = [ "prometheus" ];
        };
      };
    };
    systemd.services.opentelemetry-collector.serviceConfig = {
      Group = "overalls-otel-audi-dns"; RuntimeDirectory = "overalls-otel-audi-dns";
      RuntimeDirectoryMode = "0750"; UMask = "0007";
    };
    systemd.services.audi-dns.environment = {
      AUDI_SLO_SNAPSHOT = "/run/audi-dns/slo.json";
      AUDI_SLO_SERVICE = "audi_dns";
    };
    systemd.services.audi-dns-test-credential = {
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      script = ''
        install -d -m 0700 /run/audi-dns-test
        printf 'audi_service_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > /run/audi-dns-test/token
        chmod 0400 /run/audi-dns-test/token
      '';
    };
    systemd.services.audi-dns-control = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        StateDirectory = "audi-dns-control";
        ExecStart = "${pkgs.python3}/bin/python3 ${./control.py} ${../../../../../marshall/test/fixtures/tls/localhost.pem} ${../../../../../marshall/test/fixtures/tls/localhost.key}";
      };
    };
  };
  # @cc [owner:ghuntley,label:verification] audi-dns-startup-evidence
  # This check MUST boot the packaged DNS role on port 53 over UDP and TCP.
  # Without authenticated publication it MUST return SERVFAIL, never NXDOMAIN
  # or fabricated addresses. Verified HTTPS fixture publication MUST drive
  # answers, removal, outage expiry and restart recovery. The isolated publisher
  # does not establish real Marshall/Firecracker or multi-host acceptance.
  # Explicit 426 MUST stop snapshot requests without restarting the process,
  # keep readiness false after fixture recovery, expire existing answers and
  # recover only after operator restart. Counts MUST witness real HTTPS requests.

  # @cc [owner:ghuntley,label:verification] audi-dns-durable-restart-evidence
  # Recorder loss MUST preserve settled source identity and counters with the
  # producer alive. Clean producer restart MUST preserve coverage; unclean
  # producer restart MUST advance coverage without resetting completed history.

  testScript = ''
    def status() -> str:
        return server.succeed("python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(7); s.connect('/run/audi-dns/status.sock'); print(s.recv(4096).decode()); s.close()\"").strip()

    start_all()
    server.wait_for_unit("audi-dns.service")
    server.wait_for_open_port(53)
    server.wait_for_open_port(9443)
    server.wait_for_open_port(22555)
    assert server.succeed("ss -ltnH | awk '$4 ~ /:4369$/ {print $4}'").strip() == "127.0.0.1:4369"
    assert server.succeed("ss -ltnH | awk '$4 ~ /:22555$/ {print $4}'").strip() == "127.0.0.1:22555"
    import json
    assert json.loads(status()) == {"version": 1, "role": "dns", "ready": False}
    for transport in ["", "+tcp"]:
        response = server.succeed(f"dig @127.0.0.1 vm.apps.example A +time=2 +tries=1 {transport}")
        assert "status: SERVFAIL" in response, response
        assert "ANSWER: 0" in response, response
        refused = server.succeed(f"dig @127.0.0.1 outside.example A +time=2 +tries=1 {transport}")
        assert "status: REFUSED" in refused, refused
    server.wait_until_succeeds("jq -e '.service == \"audi_dns\" and .requests == 2 and .successes == 0 and .failures == 2 and ([.duration.bucket_counts[]] | add) == 2' /run/audi-dns/slo.json")
    assert server.succeed("stat -c '%a %U' /run/audi-dns/slo.json").strip() == "600 audi-dns"
    server.wait_for_unit("overalls-request-audi-dns-exporter.service")
    server.wait_until_succeeds("jq -e '.service == \"audi_dns\" and .requests == 2 and .failures == 2' /run/overalls-request-audi-dns-source/slo.json")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep -E 'overalls_outer_audi_dns_failures_total.* 2'")
    assert server.succeed("systemctl show audi-dns -p User --value").strip() == "audi-dns"
    server.fail("test -e /var/lib/audi/keys/ssh_host_ed25519_key")
    server.fail("systemctl is-active audi.service")
    server.succeed("systemctl restart audi-dns.service")
    server.wait_for_open_port(53)
    assert "status: SERVFAIL" in server.succeed("dig @127.0.0.1 apps.example SOA +time=2 +tries=1")
    label = "demo-0123456789abcdef0123456789abcdef.apps.example"
    server.succeed("echo ready > /var/lib/audi-dns-control/mode")
    server.wait_until_succeeds(f"dig @127.0.0.1 {label} A +short | grep -Fx 192.0.2.9")
    server.wait_until_succeeds("jq -e '.service == \"audi_dns\" and .requests >= 2 and .successes >= 1 and .requests == (.successes + .failures)' /run/audi-dns/slo.json")
    assert json.loads(status()) == {"version": 1, "role": "dns", "ready": True}
    for transport in ["", "+tcp"]:
        assert "192.0.2.9" in server.succeed(f"dig @127.0.0.1 p3000-{label} A +short {transport}")
        assert '"' + "A" * 43 + '"' in server.succeed(f"dig @127.0.0.1 _acme-challenge.{label} TXT +short {transport}")
    server.succeed("echo empty > /var/lib/audi-dns-control/mode")
    server.wait_until_succeeds(f"dig @127.0.0.1 {label} A | grep 'status: NXDOMAIN'")
    server.succeed("echo unavailable > /var/lib/audi-dns-control/mode")
    assert json.loads(status()) == {"version": 1, "role": "dns", "ready": False}
    server.wait_until_succeeds(f"dig @127.0.0.1 {label} A | grep 'status: SERVFAIL'")
    server.succeed("echo ready > /var/lib/audi-dns-control/mode")
    server.wait_until_succeeds(f"dig @127.0.0.1 {label} A +short | grep -Fx 192.0.2.9")
    server.succeed("systemctl restart audi-dns.service")
    server.wait_until_succeeds(f"dig @127.0.0.1 {label} A +short +tcp | grep -Fx 192.0.2.9")
    assert json.loads(status()) == {"version": 1, "role": "dns", "ready": True}
    assert server.succeed("stat -c '%a %U' /run/audi-dns/status.sock").strip() == "600 audi-dns"
    assert server.succeed("stat -c '%a %U' /run/audi-dns/dns.token").strip() == "600 audi-dns"
    server.fail("su -s /bin/sh nobody -c 'cat /run/audi-dns/dns.token'")

    with subtest("explicit version refusal halts packaged DNS until operator restart"):
        original_pid = server.succeed("systemctl show audi-dns.service -p MainPID --value").strip()
        server.succeed("echo unsupported > /var/lib/audi-dns-control/mode")
        server.wait_until_succeeds("test -f /var/lib/audi-dns-control/version_refusals")
        server.wait_until_succeeds("journalctl -u audi-dns.service --no-pager | grep -F audi.control_version_refused")
        requests = server.succeed("cat /var/lib/audi-dns-control/snapshot_requests").strip()
        assert json.loads(status()) == {"version": 1, "role": "dns", "ready": False}
        server.succeed("echo ready > /var/lib/audi-dns-control/mode")
        assert json.loads(status()) == {"version": 1, "role": "dns", "ready": False}
        server.succeed("sleep 6")
        assert server.succeed("cat /var/lib/audi-dns-control/snapshot_requests").strip() == requests
        assert server.succeed("systemctl show audi-dns.service -p MainPID --value").strip() == original_pid
        for transport in ["", "+tcp"]:
            response = server.succeed(f"dig @127.0.0.1 {label} A +time=2 +tries=1 {transport}")
            assert "status: SERVFAIL" in response, response
            assert "ANSWER: 0" in response, response
        server.succeed("systemctl restart audi-dns.service")
        server.wait_until_succeeds(f"dig @127.0.0.1 {label} A +short +tcp | grep -Fx 192.0.2.9")
        assert json.loads(status()) == {"version": 1, "role": "dns", "ready": True}
  '' + builtins.readFile ./slo-faults.py;

}
