{ pkgs, module, packages }:
let
  # @cc [owner:ghuntley,label:verification] held-browser-request-fixture
  # This zero-argument fixture MUST hold a real TLS request inside Marshall's
  # body parser without sending credentials or invoking a domain mutation.
  heldRequest = pkgs.writeShellScript "otel-held-browser-request" ''
    test "$#" -eq 0
    {
      printf 'POST /sign_in HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 4096\r\n\r\n{"probe":'
      ${pkgs.coreutils}/bin/sleep 30
    } | ${pkgs.openssl}/bin/openssl s_client -connect localhost:4443 -servername localhost \
      -CAfile /run/overalls-test/ca.crt -verify_return_error -quiet >/dev/null 2>/dev/null
  '';
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # @cc [owner:ghuntley,label:verification] slo-browser-helper-typed
  # The packaged browser helper MUST pass ty against its actual Playwright
  # interpreter before the NixOS machine test can run.
  checkedBrowser = pkgs.runCommand "otel-slo-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  keys = pkgs.runCommand "otel-marshall-disposable-wireguard-keys" {
    nativeBuildInputs = [ pkgs.wireguard-tools ];
  } ''
    mkdir -p "$out"
    for name in panterloons dungarees; do
      wg genkey > "$out/$name.key"
      wg pubkey < "$out/$name.key" > "$out/$name.pub"
    done
  '';
  fleetHost = name: other: address: peerAddress: { config, nodes, lib, ... }: {
    overalls.fleetNetwork = {
      enable = true;
      inherit address;
      endpointAddress = config.networking.primaryIPAddress;
      privateKeyFile = "/run/fleet-key/private";
      secretUnits = [ "fleet-fixture-key.service" ];
      peers.${other} = {
        address = peerAddress;
        endpointAddress = nodes.${other}.networking.primaryIPAddress;
        publicKey = lib.removeSuffix "\n" (builtins.readFile "${keys}/${other}.pub");
      };
    };
    systemd.services.fleet-fixture-key = {
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "fleet-key";
        RuntimeDirectoryMode = "0700";
      };
      script = "install -m 0600 ${keys}/${name}.key /run/fleet-key/private";
    };
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-otel-marshall";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.panterloons = { config, lib, ... }: {
    imports = [ (fleetHost "panterloons" "dungarees" "10.90.0.1" "10.90.0.2") ];
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall.enable = true;
    services.marshall.publicHost = lib.mkForce "localhost";
    # Production layout: the panterloons host runs the Overalls Marshall instance,
    # not an instance named after the host as the shared role node defaults to.
    services.marshall.instances = lib.mkForce {
      overalls = {
        port = 4443;
        certificateFile = "/run/overalls-test/tls.crt";
        keyFile = "/run/overalls-test/tls.key";
      };
    };
    services.overallsOtelFleet = { enable = true; role = "central"; hosts = { central = "panterloons"; worker = "dungarees"; }; };
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools ];
    systemd.services.otel-slo-reader-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=otel-slo-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
    # This check exercises trusted Marshall application export, not guest intake.
    services.overallsOtelGuest.enable = lib.mkForce false;
  };
  nodes.dungarees = { ... }: {
    imports = [ (fleetHost "dungarees" "panterloons" "10.90.0.2" "10.90.0.1") ];
  };

  # @cc [owner:ghuntley,label:verification] packaged-marshall-request-to-collector
  # A real packaged Marshall response MUST increase its private source counter
  # and reach the collector through the separate Rust exporter with fixed
  # Overalls identity. The source UID MUST lack direct collector access, and the
  # exporter MUST lack source-directory write access.
  # The actual Prometheus API MUST expose the evaluated 48-rule burn roster.
  # Real LiveView callbacks MUST reach the separate marshall_live recorder
  # through Marshall's suffixed producer configuration.
  # Retired diagnostic pages MUST return 404 before and after ordinary login,
  # with no overview links. Revoked current and remembered credentials MUST
  # still refuse the retained overview.
  testScript = ''
    start_all()
    panterloons.wait_for_unit("wireguard-fleet0.service")
    dungarees.wait_for_unit("wireguard-fleet0.service")
    panterloons.wait_for_unit("postgresql-setup.service")
    panterloons.succeed("systemctl start overalls-test-migrate.service")
    panterloons.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120)
    panterloons.wait_for_unit("opentelemetry-collector.service")
    panterloons.wait_for_unit("overalls-request-marshall-overalls.service")
    panterloons.wait_for_unit("overalls-request-marshall-overalls-exporter.service")
    for service in ["marshall_ready", "lilly_physical", "porsche_physical", "porsche_clone", "porsche_relocate", "porsche_retry", "porsche_cancel"]:
        panterloons.wait_for_unit(f"marshall-overalls-{service}-exporter.service")
        snapshot = f"/run/marshall-slo-overalls/{service}.json"
        panterloons.wait_until_succeeds(f"test -s {snapshot}")
        panterloons.succeed(f"test $(stat -c %a {snapshot}) = 640")
        panterloons.succeed(f"runuser -u otel-{service}-exporter -- test -r {snapshot}")
        panterloons.fail(f"runuser -u otel-{service}-exporter -- test -w {snapshot}")
        panterloons.fail(f"runuser -u otel-{service}-exporter -- test -w /run/marshall-slo-overalls")
        panterloons.succeed(f"test $(id -u otel-{service}-exporter) != $(id -u marshall-overalls)")
        panterloons.wait_until_succeeds(f"curl -fsSG --data-urlencode 'query=overalls_outer_{service}_requests_total{{overalls_telemetry_origin=\"application\",service_name=\"{service}\",host_name=\"panterloons\",service_instance_id=\"overalls\"}}' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result | length == 1'", timeout=90)
    request_snapshot = "/run/overalls-request-marshall-overalls-source/slo.json"
    request_state = "/var/lib/overalls-request-marshall-overalls/state.json"
    exporter_user = "${(import ../../../../domains/system/otel-fleet/request-identities.nix).exporterUser "marshall-overalls"}"
    panterloons.wait_until_succeeds(f"test -s {request_snapshot}")
    before = int(panterloons.succeed(f"jq -r .requests {request_snapshot}").strip())
    panterloons.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' --cacert /run/overalls-test/ca.crt https://localhost:4443/otel-missing-page) = 404")
    panterloons.wait_until_succeeds(f"test $(jq -r .requests {request_snapshot}) -gt {before}")
    panterloons.succeed(f"test $(stat -c %a {request_snapshot}) = 640")
    panterloons.succeed(f"runuser -u {exporter_user} -- test -r {request_snapshot}")
    panterloons.fail(f"runuser -u {exporter_user} -- test -w {request_snapshot}")
    panterloons.fail(f"runuser -u {exporter_user} -- test -w /run/overalls-request-marshall-overalls-source")
    panterloons.fail(f"runuser -u {exporter_user} -- test -r {request_state}")
    with subtest("real Marshall and collector preserve source lifetime across recorder crash"):
        source_history = panterloons.succeed(f"jq -c '[.started_at_ns,.incarnation,.totals]' {request_state}").strip()
        source_sample = int(panterloons.succeed(f"jq -r .sampled_at_unix_nano {request_snapshot}").strip())
        application_pid = panterloons.succeed("systemctl show -p MainPID --value marshall-overalls.service").strip()
        panterloons.succeed("systemctl kill --kill-whom=main --signal=SIGKILL overalls-request-marshall-overalls.service")
        panterloons.wait_for_unit("overalls-request-marshall-overalls.service")
        source_sample = int(panterloons.succeed(f"jq -r .sampled_at_unix_nano {request_snapshot}").strip())
        panterloons.wait_until_succeeds(f"test $(jq -r .sampled_at_unix_nano {request_snapshot}) -gt {source_sample}", timeout=30)
        assert panterloons.succeed(f"jq -c '[.started_at_ns,.incarnation,.totals]' {request_state}").strip() == source_history
        assert panterloons.succeed("systemctl show -p MainPID --value marshall-overalls.service").strip() == application_pid
        panterloons.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' --cacert /run/overalls-test/ca.crt https://localhost:4443/otel-after-recorder-restart) = 404")
        panterloons.wait_until_succeeds(f"test $(jq -r .requests {request_snapshot}) -gt {before + 1}")
    with subtest("real clean Marshall deployment preserves recording coverage and totals"):
        clean_history = panterloons.succeed(f"jq -c '[.started_at_ns,.incarnation,.coverage_started_at_ns,.totals]' {request_state}").strip()
        clean_sample = int(panterloons.succeed(f"jq -r .sampled_at_unix_nano {request_snapshot}").strip())
        panterloons.succeed("systemctl restart marshall-overalls.service")
        panterloons.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120)
        panterloons.wait_until_succeeds(f"test $(jq -r .sampled_at_unix_nano {request_snapshot}) -gt {clean_sample}", timeout=30)
        assert panterloons.succeed(f"jq -c '[.started_at_ns,.incarnation,.coverage_started_at_ns,.totals]' {request_state}").strip() == clean_history
    with subtest("real admitted browser request survives producer loss as one failure without invented duration"):
        failure_base = int(panterloons.succeed(f"jq -r .totals.failures {request_state}").strip())
        duration_base = int(panterloons.succeed(f"jq -r .totals.duration_count {request_state}").strip())
        panterloons.succeed("systemd-run --unit=otel-held-request ${heldRequest}")
        panterloons.wait_until_succeeds(f"jq -e '(.pending | length) == 1' {request_state}", timeout=10)
        panterloons.succeed("systemctl kill --kill-whom=main --signal=SIGKILL marshall-overalls.service")
        panterloons.wait_until_succeeds(f"jq -e '.totals.failures == {failure_base + 1} and .totals.duration_count == {duration_base} and (.pending | length) == 0' {request_state}", timeout=30)
        panterloons.succeed("systemctl stop otel-held-request.service")
        panterloons.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120)
        panterloons.wait_until_succeeds(f"test $(jq -r .failures {request_snapshot}) -eq {failure_base + 1}", timeout=30)
    panterloons.succeed("code=$(runuser -u marshall-overalls -g overalls-otel-marshall-source -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-marshall/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    panterloons.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_marshall_web_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_instance_id=\"overalls\"[^}]*\\} [1-9]'", timeout=90)
    panterloons.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls:telemetry_collector_up:ratio1h{overalls_telemetry_origin=\"\"}' http://127.0.0.1:9090/api/v1/query | jq -e '[.data.result[].metric.instance] | sort == [\"10.90.0.1:9464\", \"10.90.0.2:9464\"]'", timeout=90)
    panterloons.wait_until_succeeds("curl -fsSG --data-urlencode 'query=overalls:telemetry_collector_up:ratio1h{overalls_telemetry_origin=\"\"}' http://127.0.0.1:9090/api/v1/query | jq -e 'any(.data.result[]; .metric.instance == \"10.90.0.2:9464\" and .value[1] == \"0\")'", timeout=90)
    panterloons.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/rules?type=alert' | jq -e '[.data.groups[] | select(.name == \"overalls-otel-budget-burn\") | .rules[] | select(.health == \"ok\" and .state == \"inactive\")] | length == 48'", timeout=90)
    panterloons.succeed("systemctl start otel-slo-reader-seed.service")
    panterloons.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    panterloons.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    panterloons.succeed("env NODE_EXTRA_CA_CERTS=/run/overalls-test/ca.crt ${python}/bin/python ${checkedBrowser}/browser.py", timeout=120)
    with subtest("real LiveView callbacks reach the independent marshall_live recorder"):
        live_snapshot = "/run/overalls-request-marshall-live-overalls-source/slo.json"
        panterloons.wait_for_unit("overalls-request-marshall-live-overalls.service")
        panterloons.wait_for_unit("overalls-request-marshall-live-overalls-exporter.service")
        panterloons.succeed("systemctl show -p Environment marshall-overalls.service | grep -q 'OVERALLS_REQUEST_ACCOUNTING_SOCKET_MARSHALL_LIVE=/run/overalls-request-marshall-live-overalls/recorder.sock'")
        panterloons.wait_until_succeeds(f"test $(jq -r .requests {live_snapshot}) -gt 0", timeout=60)
        panterloons.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_marshall_live_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_instance_id=\"overalls\"[^}]*\\} [1-9]'", timeout=90)
  '';
}
