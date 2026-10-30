{ pkgs, module }:
let
  tls = pkgs.runCommand "public-grafana-disposable-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/key.pem" -out "$out/cert.pem" \
      -days 3650 -subj /CN=overalls.test -addext subjectAltName=DNS:overalls.test
    cat "$out/key.pem" "$out/cert.pem" > "$out/full.pem"
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-public-grafana";
  nodes.server = { config, lib, ... }: {
    imports = [ module ];
    virtualisation.memorySize = 3072;
    networking.nftables.enable = true;
    networking.enableIPv6 = false;
    overalls.fleetFirewall = { enable = true; allowedHosts = {}; };
    overalls.fleetNetwork = {
      enable = true; address = "10.90.0.1";
      endpointAddress = config.networking.primaryIPAddress;
      privateKeyFile = "/run/grafana-fixture/wg.key";
      peers.worker = { address = "10.90.0.2"; endpointAddress = "192.0.2.11"; publicKey = lib.concatStrings (lib.replicate 43 "A") + "="; };
      secretUnits = [ "grafana-fixture.service" ];
    };
    # This focused fixture has no guest intake or provisioner.
    services.overallsOtelGuest.enable = lib.mkForce false;
    services.overallsOtelFleet = {
      enable = true; role = "central";
      hosts = { central = "server"; worker = "worker"; };
      publicGrafana.enable = true;
    };
    services.marshallProxy = {
      enable = true; publicHost = "overalls.test";
      bindAddress = config.networking.primaryIPAddress;
      certificateFile = "/run/grafana-fixture/full.pem";
      secretUnits = [ "grafana-fixture.service" ];
      backends.local = { address = "127.0.0.1"; serverName = "overalls.test"; };
    };
    systemd.services.grafana-fixture = {
      before = [ "haproxy.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "grafana-fixture"; };
      path = [ pkgs.wireguard-tools ];
      script = ''
        install -m 0640 -g haproxy ${tls}/full.pem /run/grafana-fixture/full.pem
        wg genkey > /run/grafana-fixture/wg.key
        chmod 0600 /run/grafana-fixture/wg.key
      '';
    };
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
  };
  nodes.client = { nodes, ... }: {
    networking.hosts.${nodes.server.networking.primaryIPAddress} = [ "overalls.test" ];
    environment.etc."grafana-test-ca.pem".source = "${tls}/cert.pem";
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
  };
  # @cc [owner:ghuntley,label:verification;security] public-grafana-native-boundary
  # An untrusted client MUST verify TLS and Grafana login through the production
  # proxy and perimeter modules. Backend ports and foreign Host requests MUST
  # refuse. Disposable credentials prove no production identity or history.
  testScript = ''
    start_all()
    server.wait_for_unit("grafana.service")
    server.wait_for_unit("haproxy.service")
    client.wait_until_succeeds("curl --cacert /etc/grafana-test-ca.pem -fsS https://overalls.test:3443/api/health | jq -e '.database == \"ok\"'")
    with subtest("login and hostname boundaries"):
        client.succeed("test $(curl --cacert /etc/grafana-test-ca.pem -s -o /dev/null -w '%{http_code}' https://overalls.test:3443/api/user) = 401")
        client.succeed("test $(curl --cacert /etc/grafana-test-ca.pem -s -o /dev/null -w '%{http_code}' -u operator:wrong https://overalls.test:3443/api/user) = 401")
        client.succeed("test $(curl --cacert /etc/grafana-test-ca.pem -s -o /dev/null -w '%{http_code}' -H 'Host: foreign.test' https://overalls.test:3443/api/health) = 421")
        client.fail("curl --max-time 3 -fsS https://overalls.test:3443/api/health")
        client.fail("curl --max-time 3 -fsS http://overalls.test:3000/api/health")
        client.fail("curl --max-time 3 -fsS http://overalls.test:9090/-/healthy")
        client.fail("curl --max-time 3 -fsS http://overalls.test:3200/ready")
        client.fail("curl --max-time 3 -fsS https://overalls.test:3444/api/health")
    with subtest("authenticated public dashboard"):
        password: str = server.succeed("cat /var/lib/grafana/admin-password").strip()
        client.succeed("umask 077; printf '%s' 'user = \"operator:" + password + "\"' > /tmp/grafana-curl.cfg")
        client.succeed("curl --config /tmp/grafana-curl.cfg --cacert /etc/grafana-test-ca.pem -fsS https://overalls.test:3443/api/user | jq -e '.login == \"operator\"'")
        client.succeed("curl --config /tmp/grafana-curl.cfg --cacert /etc/grafana-test-ca.pem -fsS https://overalls.test:3443/api/dashboards/uid/overalls-otel-baseline | jq -e '.dashboard.panels | length == 67'")
        server.succeed("curl -fsS http://127.0.0.1:9090/api/v1/status/flags | jq -e '.data[\"storage.tsdb.retention.time\"] == \"90d\" and .data[\"storage.tsdb.retention.size\"] == \"0B\"'")
        server.succeed("curl -fsS http://127.0.0.1:9465/metrics | grep '^overalls_telemetry_root_available_bytes '")
        client.succeed("curl --config /tmp/grafana-curl.cfg --cacert /etc/grafana-test-ca.pem --http1.1 --max-time 3 -s -D /tmp/grafana-live.headers -o /dev/null -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Origin: https://overalls.test:3443' https://overalls.test:3443/api/live/ws || true")
        client.succeed("grep -q '^HTTP/1.1 101' /tmp/grafana-live.headers")
        client.succeed("rm /tmp/grafana-curl.cfg /tmp/grafana-live.headers")
    with subtest("validated proxy reload retains public TLS"):
        server.succeed("systemctl reload haproxy")
        client.wait_until_succeeds("curl --cacert /etc/grafana-test-ca.pem -fsS https://overalls.test:3443/api/health | jq -e '.database == \"ok\"'")
  '';
}
