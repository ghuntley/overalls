{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-porsche-service";
  nodes.gateway = { lib, ... }: {
    imports = [ module (import ../../support/ssh-host-certificate.nix { inherit pkgs; role = "porsche"; })
      (import ../../support/request-source.nix {
        inherit pkgs packages; name = "porsche"; source = "porsche";
        producerUser = "porsche"; producerUnit = "porsche.service";
        deadlineSeconds = 3660; collectorGroup = "overalls-otel-porsche";
      }) ];
    virtualisation.memorySize = 1536;
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.overallsAutoUpdate = {
      enable = true;
      repository = "/var/lib/porsche-fixture/repository";
      flakeAttr = "gateway";
    };
    systemd.timers.overalls-auto-update.wantedBy = lib.mkForce [];
    services.overallsLogging = {
      enable = true;
      outputs.fixture = { type = "native"; plugin = "stdout";
        sources = [ "porsche" "metrics" ]; queueBytes = 8388608; };
    };
    services.porsche = {
      enable = true;
      package = packages.porsche;
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://control.example.test";
      credentialFile = "/run/porsche-fixture/gateway.token";
      secretUnits = [ "porsche-fixture.service" ];
      openFirewall = true;
    };
    systemd.services.porsche.environment.PORSCHE_SLO_SNAPSHOT = "/run/porsche/slo.json";
    users.groups.overalls-otel-porsche = {};
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      settings = {
        receivers."otlp/application-porsche".protocols.http = {
          endpoint = "/run/overalls-otel-porsche/collector.sock";
          transport = "unix";
          max_request_body_size = 4096;
        };
        processors."resource/application-porsche".attributes = [
          { key = "service.name"; value = "porsche"; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
        ];
        exporters.prometheus = {
          endpoint = "127.0.0.1:9464";
          resource_to_telemetry_conversion.enabled = true;
        };
        service.pipelines."metrics/application-porsche" = {
          receivers = [ "otlp/application-porsche" ];
          processors = [ "resource/application-porsche" ];
          exporters = [ "prometheus" ];
        };
      };
    };
    systemd.services.opentelemetry-collector.serviceConfig = {
      Group = "overalls-otel-porsche";
      RuntimeDirectory = "overalls-otel-porsche";
      RuntimeDirectoryMode = "0750";
      UMask = "0007";
    };
    systemd.services.porsche-fixture = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = ''
        mkdir -p /run/porsche-fixture
        printf '%s\n' 'porsche_gateway_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > /run/porsche-fixture/gateway.token
      '';
    };
    environment.systemPackages = [ pkgs.openssh pkgs.iproute2 pkgs.python3 pkgs.curl pkgs.jq ];
    environment.etc."porsche-status-check.py".text = ''
      import json, socket
      with open("/run/current-system/overalls-deployment.json") as stream:
          manifest = json.load(stream)
      assert manifest["porsche"] == {"statusSocket": "/run/porsche/status.sock"}
      assert "porsche.service" in manifest["healthUnits"]
      assert "porsche.service" in manifest["consumers"]
      with socket.socket(socket.AF_UNIX) as client:
          client.settimeout(8)
          client.connect("/run/porsche/status.sock")
          data = client.makefile("rb").readline(4097)
          assert json.loads(data) == {"version": 1, "ready": False}
    '';
  };
  # @cc [owner:ghuntley,label:verification] porsche-service-test-scope
  # This check MUST boot the actual source release and module, verify private
  # custody, port separation, persistent host identity and fail-closed startup.
  # It MUST NOT claim domain or guest execution: Marshall is absent here.
  testScript = ''
    # Porsche snapshot reaches the Rust exporter and isolated collector.
    start_all()
    gateway.wait_for_unit("porsche.service")
    gateway.wait_for_unit("opentelemetry-collector.service")
    gateway.wait_for_unit("overalls-request-porsche-exporter.service")
    gateway.wait_until_succeeds("test $(stat -c '%U:%a' /run/porsche/slo.json) = porsche:600")
    gateway.wait_until_succeeds("jq -e '.service == \"porsche\" and .requests == 0 and .successes == 0 and .failures == 0' /run/porsche/slo.json")
    gateway.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep -q 'overalls_outer_porsche_requests_total.* 0'")
    gateway.succeed("code=$(runuser -u porsche -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-porsche/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    try:
        gateway.wait_for_open_port(22, timeout=45)
    except Exception:
        print(gateway.succeed("journalctl -u porsche.service --no-pager"))
        raise
    gateway.wait_for_open_port(2222)
    gateway.wait_until_succeeds("test -S /run/porsche/status.sock")
    assert gateway.succeed("stat -c '%U:%a' /run/porsche/status.sock").strip() == "porsche:600"
    gateway.succeed("python3 /etc/porsche-status-check.py")
    fingerprint = gateway.succeed("ssh-keyscan -c -t ed25519 -p 22 127.0.0.1 2>/dev/null | ssh-keygen -lf -")
    admin = gateway.succeed("ssh-keyscan -t ed25519 -p 2222 127.0.0.1 2>/dev/null | ssh-keygen -lf -")
    assert fingerprint.split()[1] != admin.split()[1]
    assert gateway.succeed("stat -c '%U:%a' /var/lib/porsche/keys/ssh_host_ed25519_key").strip() == "porsche:600"
    assert gateway.succeed("stat -c '%U:%a:%h' /run/porsche/gateway.token").strip() == "porsche:400:1"
    assert gateway.succeed("systemctl show porsche.service -p User --value").strip() == "porsche"
    gateway.fail("su -s /bin/sh nobody -c 'cat /var/lib/porsche/keys/ssh_host_ed25519_key'")
    gateway.succeed("systemctl restart porsche.service")
    gateway.wait_for_open_port(22)
    assert gateway.succeed("ssh-keyscan -c -t ed25519 -p 22 127.0.0.1 2>/dev/null | ssh-keygen -lf -") == fingerprint
    gateway.wait_for_unit("overalls-logging.service")
    gateway.succeed("ssh-keygen -q -t ed25519 -N ${pkgs.lib.escapeShellArg ""} -f /tmp/metric-client")
    gateway.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes -i /tmp/metric-client -p 22 127.0.0.1 whoami")
    gateway.wait_until_succeeds("journalctl -u overalls-logging.service --no-pager | grep 'overalls_gauge_http_errors.*service=\"porsche\".* = [1-9][0-9]*'", timeout=180)
    gateway.fail("journalctl -u overalls-logging.service --no-pager | grep -F porsche_gateway_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    gateway.succeed("systemctl stop porsche.service; printf invalid > /run/porsche-fixture/gateway.token; systemctl start porsche.service")
    gateway.wait_until_succeeds("test $(systemctl show porsche.service -p NRestarts --value) -ge 1")
    gateway.fail("ss -ltnH 'sport = :22' | grep -q LISTEN")
    gateway.succeed("systemctl stop porsche.service")
    gateway.wait_for_open_port(2222)
  '';
}
