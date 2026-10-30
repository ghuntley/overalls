{ pkgs, module, packages }:
let
  otelExporter = packages.otelReceiver;
  tls = pkgs.runCommand "ziggy-isolated-provider-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=ziggy-isolated-test -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=control.test -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:control.test,DNS:api.openai.com,DNS:api.anthropic.com\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-ziggy-service";
  nodes.proxy = { lib, ... }: {
    imports = [ module ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    services.openssh.enable = true;
    networking.hostId = "12345678";
    services.lilly.pools = [{
      id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      path = "/pool";
      filesystem_id = "zfs:123:456";
      storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
    }];
    services.lilly = { enable = true; hostId = "11111111-1111-4111-8111-111111111111";
      controlPlane = "https://control.test"; egressInterface = "eth0"; guestCpuCores = 1; guestMemoryMiB = 256; };
    # This fixture exercises Ziggy, not Lilly execution authority.
    systemd.services.lilly.wantedBy = lib.mkForce [];
    services.ziggy = { caFile = "${tls}/ca.pem";
      secretsFile = "/run/ziggy-fixture/ziggy.enc.json"; cpuCores = 2; memoryMiB = 1024; maxPendingRequests = 8;
      agentEnable = true; };
    systemd.services.ziggy.environment.ZIGGY_SLO_SNAPSHOT = "/run/ziggy/slo.json";
    users.groups.overalls-otel-ziggy = {};
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      settings = {
        receivers."otlp/application-ziggy".protocols.http = {
          endpoint = "/run/overalls-otel-ziggy/collector.sock";
          transport = "unix";
          max_request_body_size = 4096;
        };
        processors."resource/application-ziggy".attributes = [
          { key = "service.name"; value = "ziggy"; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
        ];
        exporters.prometheus = {
          endpoint = "127.0.0.1:9464";
          resource_to_telemetry_conversion.enabled = true;
        };
        service.pipelines."metrics/application-ziggy" = {
          receivers = [ "otlp/application-ziggy" ];
          processors = [ "resource/application-ziggy" ];
          exporters = [ "prometheus" ];
        };
      };
    };
    systemd.services.opentelemetry-collector.serviceConfig = {
      Group = "overalls-otel-ziggy";
      RuntimeDirectory = "overalls-otel-ziggy";
      RuntimeDirectoryMode = "0750";
      UMask = "0007";
    };
    systemd.services.ziggy-slo-exporter = {
      wantedBy = lib.mkForce [];
      after = [ "ziggy.service" "opentelemetry-collector.service" ];
      requires = [ "ziggy.service" "opentelemetry-collector.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${otelExporter}/bin/slo_exporter ziggy /run/ziggy/slo.json /run/overalls-otel-ziggy/collector.sock";
        User = "ziggy"; Group = "ziggy";
        SupplementaryGroups = [ "overalls-otel-ziggy" ];
        Restart = "always"; RestartSec = 5;
      };
    };
    systemd.services.ziggy.wantedBy = lib.mkForce [];
    services.galileo.secretsFile = "/run/ziggy-fixture/galileo.enc.json";
    systemd.services.galileo.wantedBy = lib.mkForce [];
    networking.extraHosts = "127.0.0.1 control.test api.openai.com api.anthropic.com\n";
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.python3 pkgs.openssh packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."ziggy-seal.py".source = ./seal.py;
    systemd.services.ziggy-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { ExecStart = "${pkgs.python3}/bin/python3 ${./fixture.py} ${tls}/server.pem ${tls}/server.key";
        RuntimeDirectory = "ziggy-fixture"; RuntimeDirectoryMode = "0700"; };
    };
  };
  # @cc [owner:ghuntley,label:verification] ziggy-service-fixture-scope
  # Use the packaged proxy and real SecretSpec/SOPS credentials, verified provider
  # TLS, native streaming and disk accounting. Synthetic control authority MUST
  # NOT be represented as real Marshall or Firecracker execution acceptance.
  # SIGKILL MUST preserve acknowledged SLO totals and source lifetime. An
  # unfinished admission MUST recover as one failure without provider replay.
  testScript = builtins.readFile ./driver.py;
}
