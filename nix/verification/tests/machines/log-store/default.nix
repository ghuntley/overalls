{ pkgs, packages }:
let
  # Test-only fixture credentials; never used outside this machine test.
  insertPassword = "fixture-insert-a94f8c2b51d7406e9b3c2f1a7d5e8f00";
  readerPassword = "fixture-reader-3c5128f9a04b47de88c1e5f02a6b94d77";
  tls = pkgs.runCommand "logstore-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl ecparam -genkey -name prime256v1 -out ca.key 2>/dev/null
    openssl req -x509 -new -key ca.key -sha256 -days 3650 -out $out/ca.crt \
      -subj '/CN=overalls fleet log store fixture CA' \
      -addext 'basicConstraints=critical,CA:true,pathlen:0' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>/dev/null
    openssl ecparam -genkey -name prime256v1 -out $out/tls.key 2>/dev/null
    openssl req -new -key $out/tls.key -out leaf.csr -subj '/CN=logs.fleet.internal'
    printf 'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:logs.fleet.internal\n' > extensions
    openssl x509 -req -in leaf.csr -CA $out/ca.crt -CAkey ca.key -CAcreateserial \
      -days 3650 -sha256 -extfile extensions -out $out/tls.crt 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-log-store";
  # @cc [owner:ghuntley,label:verification] logstore-machine-verified-delivery
  # A real journald event MUST pass journal capture, trusted normalization,
  # verified-TLS insert through the authenticated fleet entry, storage, and a
  # reader-credential LogsQL query, while insert credentials and path escapes
  # are refused and entry outages backfill from bounded queues.
  nodes = {
    store = { lib, ... }: {
      imports = [ ../../../../domains/system/log-store ../../../../domains/system/otel-fleet/grafana-logs.nix ];
      options.services.overallsOtelFleet = {
        enable = lib.mkOption { type = lib.types.bool; default = true; };
        role = lib.mkOption { type = lib.types.enum [ "central" "worker" ]; default = "central"; };
      };
      config = {
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      # Alphabetically first node: the framework assigns it 192.168.1.1.
      networking.hosts."192.168.1.1" = [ "logs.fleet.internal" ];
      networking.firewall.allowedTCPPorts = [ 8443 ];
      systemd.services.logstore-fixture-credentials = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "logstore-fixture";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          install -m 0600 ${tls}/tls.crt /run/logstore-fixture/tls.crt
          install -m 0600 ${tls}/tls.key /run/logstore-fixture/tls.key
          install -m 0600 ${tls}/ca.crt /run/logstore-fixture/ca.crt
          printf '%s' '${insertPassword}' > /run/logstore-fixture/insert.password
          printf '%s' '${readerPassword}' > /run/logstore-fixture/reader.password
          chmod 0600 /run/logstore-fixture/*.password
        '';
      };
      services.overallsLogStore = {
        enable = true;
        address = "192.168.1.1";
        port = 8443;
        # The virtual test disk is smaller than the default free-space guard.
        minFreeBytes = 67108864;
        certificateFile = "/run/logstore-fixture/tls.crt";
        keyFile = "/run/logstore-fixture/tls.key";
        insertPasswordFile = "/run/logstore-fixture/insert.password";
        readerPasswordFile = "/run/logstore-fixture/reader.password";
        secretUnits = [ "logstore-fixture-credentials.service" ];
      };
      environment.etc."overalls/logstore-ca.crt".source = "${tls}/ca.crt";
      services.grafana = {
        enable = true;
        settings = {
          server = { http_addr = "127.0.0.1"; http_port = 3000; };
          security = {
            admin_user = "fixture"; admin_password = "fixture-private-grafana";
            secret_key = "isolated-logstore-grafana-secret-key-fixture";
          };
          users.allow_sign_up = false;
          "auth.anonymous".enabled = false;
        };
        provision.datasources.settings.apiVersion = 1;
        provision.dashboards.settings.providers = [{ name = "Overalls";
          options.path = pkgs.linkFarm "logstore-grafana-dashboards" [
            { name = "logs.json"; path = pkgs.writeText "logs.json" (builtins.toJSON (import ../../../../domains/system/otel-fleet/logs-dashboard.nix)); }
            { name = "operations.json"; path = pkgs.writeText "operations.json" (builtins.toJSON (import ../../../../domains/system/otel-fleet/operations-dashboard.nix)); }
          ];
        }];
      };
      environment.systemPackages = [ pkgs.curl pkgs.jq ];
      };
    };
    worker = { ... }: {
      imports = [ (import ../../../../domains/system/logging { inherit packages; }) ];
      virtualisation.memorySize = 1024;
      networking.hosts."192.168.1.1" = [ "logs.fleet.internal" ];
      systemd.services.logstore-fixture-credentials = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "logstore-fixture";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          install -m 0600 ${tls}/ca.crt /run/logstore-fixture/ca.crt
          printf '%s' '${insertPassword}' > /run/logstore-fixture/insert.password
          chmod 0600 /run/logstore-fixture/insert.password
        '';
      };
      services.overallsLogging = {
        enable = true;
        environment = "fixture";
        secretUnits = [ "logstore-fixture-credentials.service" ];
        outputs.logstore = {
          type = "native";
          plugin = "http";
          # The full production source surface exercises route-class folding.
          sources = [
            "marshall" "lilly" "porsche" "audi" "ziggy" "enrico" "brady" "galileo" "underclass"
            "haproxy" "auth" "kernel" "storage" "mail" "operations" "system"
          ];
          queueBytes = 50331648;
          credentialFiles.http_passwd = "/run/logstore-fixture/insert.password";
          settings = {
            host = "logs.fleet.internal";
            port = 8443;
            uri = "/insert/jsonline?_msg_field=message";
            format = "json_lines";
            http_user = "insert";
            tls = true;
            "tls.verify" = true;
            "tls.verify_hostname" = true;
            "tls.ca_file" = "${tls}/ca.crt";
          };
        };
      };
    };
  };
  testScript = builtins.readFile ./driver.py;
}
