{ pkgs, module, packages }:
let
  tls = pkgs.runCommand "enrico-test-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=enrico-test-ca -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=enrico.fleet.internal -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:enrico.fleet.internal,DNS:github.com\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-enrico-service";
  nodes.mirror = { ... }: {
    imports = [ module (import ../../support/request-source.nix {
      inherit pkgs packages; name = "enrico"; source = "enrico";
      producerUser = "enrico"; producerUnit = "enrico.service";
      deadlineSeconds = 3720; collectorGroup = "overalls-otel-enrico";
    }) ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    networking.extraHosts = "127.0.0.1 github.com enrico.fleet.internal\n";
    environment.systemPackages = [ pkgs.git pkgs.curl pkgs.jq ];
    services.nginx.enable = true;
    services.nginx.virtualHosts."github.com" = {
      forceSSL = true;
      sslCertificate = "${tls}/server.pem";
      sslCertificateKey = "${tls}/server.key";
      root = "/var/lib/git-fixture";
      listen = [{ addr = "127.0.0.1"; port = 443; ssl = true; }];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/git-fixture 0755 root root -" ];
    services.enrico = {
      enable = true;
      bindAddress = "127.0.0.1";
      tokenFile = "${pkgs.writeText "enrico-test-token" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}";
      certificateFile = "${tls}/server.pem";
      keyFile = "${tls}/server.key";
      cpuCores = 2;
      memoryMiB = 1024;
    };
    users.groups.overalls-otel-enrico = {};
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      settings = {
        receivers."otlp/application-enrico".protocols.http = {
          endpoint = "/run/overalls-otel-enrico/collector.sock";
          transport = "unix";
          max_request_body_size = 4096;
        };
        processors."resource/application-enrico".attributes = [
          { key = "service.name"; value = "enrico"; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
        ];
        exporters.prometheus = {
          endpoint = "127.0.0.1:9464";
          resource_to_telemetry_conversion.enabled = true;
        };
        service.pipelines."metrics/application-enrico" = {
          receivers = [ "otlp/application-enrico" ];
          processors = [ "resource/application-enrico" ];
          exporters = [ "prometheus" ];
        };
      };
    };
    systemd.services.opentelemetry-collector.serviceConfig = {
      Group = "overalls-otel-enrico";
      RuntimeDirectory = "overalls-otel-enrico";
      RuntimeDirectoryMode = "0750";
      UMask = "0007";
    };
    systemd.services.enrico.postStart = ''
      for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
        if test -S /run/enrico/status.sock; then
          ${pkgs.coreutils}/bin/chmod 0660 /run/enrico/status.sock
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 0.1
      done
      exit 1
    '';
    systemd.services.enrico.environment.GIT_SSL_CAINFO = "${tls}/ca.pem";
    environment.etc."enrico-test-ca.pem".source = "${tls}/ca.pem";
  };
  # @cc [owner:ghuntley,label:verification] enrico-private-mirror-machine
  # Exercise the packaged release, verified HTTPS Git fixture, token and
  # source-label boundaries, idempotent refresh attempts, the read API,
  # preservation of a published mirror on fetch failure and refresh recovery
  # after the source returns. It also verifies fixed source-owned SLO outcomes
  # through the Rust exporter and isolated collector intake.
  # Recorder SIGKILL MUST preserve completed history with the producer alive.
  # Producer SIGKILL during an admitted fetch MUST add one failure without a
  # duration sample, preserve the published mirror and never replay that work.
  testScript = builtins.readFile ./driver.py;
}
