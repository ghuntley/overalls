{ pkgs, module, packages, github ? false }:
let
  githubHosts = [ "github.com" "api.github.com" "uploads.github.com" "gist.github.com"
    "raw.githubusercontent.com" "gist.githubusercontent.com" "release-assets.githubusercontent.com"
    "github-cloud.githubusercontent.com" "github-cloud.s3.amazonaws.com" ];
  githubClients = if github then packages.githubTools.packages "linux-amd64" else [];
  tls = pkgs.runCommand "galileo-isolated-control-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=galileo-isolated-test \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=control.test -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:control.test,DNS:origin.test${pkgs.lib.optionalString github ("," + pkgs.lib.concatMapStringsSep "," (host: "DNS:" + host) githubHosts)}\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=integration.internal -keyout $out/audi.key -out audi.csr 2>/dev/null
    printf 'subjectAltName=DNS:integration.internal,DNS:*.integration.internal\nextendedKeyUsage=serverAuth\n' > audi-extensions
    openssl x509 -req -in audi.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile audi-extensions -out $out/audi.pem 2>/dev/null
  '';
  binding = pkgs.writeText "galileo-fixture-binding.json" (builtins.toJSON {
    host_id = "11111111-1111-4111-8111-111111111111";
    vm_id = "22222222-2222-4222-8222-222222222222";
    placement_id = "33333333-3333-4333-8333-333333333333";
    execution_epoch = 1;
  });
  clientNode = { nodes, ... }: {
    networking.extraHosts = "169.254.254.1 ${if github then "com-github" else "esample"}.integration.internal\n";
    environment.systemPackages = [ pkgs.curl pkgs.dig pkgs.python3 pkgs.git ] ++ githubClients;
    environment.etc."galileo-client.py".source = ./client.py;
    environment.etc."galileo-ca.pem".source = "${tls}/ca.pem";
    environment.etc."galileo-proxy-address".text = nodes.proxy.networking.primaryIPAddress;
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    programs.git = pkgs.lib.mkIf github {
      enable = true;
      config.include.path = "${packages.githubTools.configuration}";
    };
  };
in pkgs.testers.runNixOSTest {
  name = if github then "overalls-github-integration" else "overalls-galileo-service";
  nodes = {
  proxy = { lib, ... }: {
    imports = [ module (import ../../support/request-source.nix {
      inherit pkgs packages; name = "galileo"; source = "galileo";
      producerUser = "galileo"; producerUnit = "galileo.service";
      deadlineSeconds = 86400; collectorGroup = "overalls-otel-galileo";
    }) ];
    environment.etc."galileo-client.py".source = ./client.py;
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
    # This fixture exercises Galileo, not Lilly execution authority.
    systemd.services.lilly.wantedBy = lib.mkForce [];
    services.ziggy.secretsFile = "/run/galileo-fixture/ziggy-absent.enc.json";
    services.ziggy.enabledProviders = [ "openai" ];
    systemd.services.ziggy.wantedBy = lib.mkForce [];
    services.galileo = { caFile = "${tls}/ca.pem";
      secretsFile = "/run/galileo-fixture/galileo.enc.json"; cpuCores = 2; memoryMiB = 1024; };
    systemd.services.galileo.wantedBy = lib.mkForce [];
    users.groups.overalls-otel-galileo = {};
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      settings = {
        receivers."otlp/application-galileo".protocols.http = {
          endpoint = "/run/overalls-otel-galileo/collector.sock";
          transport = "unix";
          max_request_body_size = 4096;
        };
        processors."resource/application-galileo".attributes = [
          { key = "service.name"; value = "galileo"; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
        ];
        exporters.prometheus = {
          endpoint = "127.0.0.1:9464";
          resource_to_telemetry_conversion.enabled = true;
        };
        service.pipelines."metrics/application-galileo" = {
          receivers = [ "otlp/application-galileo" ];
          processors = [ "resource/application-galileo" ];
          exporters = [ "prometheus" ];
        };
      };
    };
    systemd.services.opentelemetry-collector.serviceConfig = {
      Group = "overalls-otel-galileo";
      RuntimeDirectory = "overalls-otel-galileo";
      RuntimeDirectoryMode = "0750";
      UMask = "0007";
    };
    networking.extraHosts = "127.0.0.1 control.test origin.test ${pkgs.lib.optionalString github (pkgs.lib.concatStringsSep " " githubHosts)}\n";
    networking.firewall.allowedTCPPorts = [ 443 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.python3 pkgs.openssh pkgs.git packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."galileo-seal.py".source = ./seal.py;
    environment.etc."galileo-binding.json".source = binding;
    systemd.services.galileo-fixture = {
      wantedBy = [ "multi-user.target" ];
      path = lib.optionals github [ pkgs.git ];
      preStart = ''
        install -o audi -g audi -m 0400 ${tls}/audi.key /run/galileo-fixture/audi.key
        install -o audi -g audi -m 0400 ${tls}/audi.pem /run/galileo-fixture/audi.pem
        install -o audi -g audi -m 0400 ${tls}/ca.pem /run/galileo-fixture/ca.pem
        cat > /run/galileo-fixture/audi.json <<'EOF'
        ${builtins.toJSON {
          version = 1;
          role = "private";
          host_id = "11111111-1111-4111-8111-111111111111";
          connector_path = "/run/galileo-fixture/connector.sock";
          connector_uid = 0;
          ziggy_socket = "/run/galileo-fixture/absent-ziggy.sock";
          galileo_socket = "/run/galileo/proxy.sock";
          certificate_file = "/run/galileo-fixture/audi.pem";
          key_file = "/run/galileo-fixture/audi.key";
          roots_file = "/run/galileo-fixture/ca.pem";
          status_socket = "/run/galileo-audi/status.sock";
        }}
        EOF
        chown audi:audi /run/galileo-fixture/audi.json
        chmod 0400 /run/galileo-fixture/audi.json
      '';
      serviceConfig = { ExecStart = "${pkgs.python3}/bin/python3 ${if github then ../github-integration/fixture.py else ./fixture.py} ${tls}/server.pem ${tls}/server.key";
        RuntimeDirectory = "galileo-fixture"; RuntimeDirectoryMode = "0755"; };
    };
    systemd.services.audi-private-fixture = {
      after = [ "galileo-fixture.service" "galileo.service" ];
      requires = [ "galileo-fixture.service" "galileo.service" ];
      environment = {
        AUDI_CONFIG_FILE = "/run/galileo-fixture/audi.json";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "isolated-galileo-audi";
        RELEASE_TMP = "/run/galileo-audi";
        ERL_FLAGS = "+S 2:2";
        ERL_CRASH_DUMP = "/dev/null";
      };
      serviceConfig = {
        User = "audi";
        Group = "audi";
        ExecStart = "${packages.audi}/bin/audi start";
        RuntimeDirectory = "galileo-audi";
        RuntimeDirectoryMode = "0700";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
    };
  };
  client = clientNode;
  } // pkgs.lib.optionalAttrs github { client2 = clientNode; };
  # @cc [owner:ghuntley,label:verification] galileo-service-fixture-scope
  # Use packaged Audi and Galileo releases across two NixOS machines with real TLS,
  # Unix forwarding, SecretSpec/SOPS credentials, durable recorder Rust OTLP export
  # and bounded streaming failures.
  # The synthetic binding/control fixtures MUST NOT be represented as real Lilly,
  # Marshall, relocation, attachment, independent-host or Firecracker acceptance.
  testScript = builtins.readFile (if github then ../github-integration/driver.py else ./driver.py);
}
