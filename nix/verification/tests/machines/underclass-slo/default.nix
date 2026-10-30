# @cc [owner:ghuntley,label:verification;security] underclass-proxy-slo-native
# The native check MUST use the patched pinned service, real local provider TLS,
# source-owned private state and a separate collector UID. Synthetic credentials
# and scenario selection MUST remain inside this disposable machine.
{ pkgs, packages, ... }:
let
  underclassModule = import ../../../../domains/system/underclass.nix { inherit packages; };
  fixturePackage = packages.underclass.overrideAttrs (previous: {
    postPatch = (previous.postPatch or "") + ''
      mkdir -p src/bin
      cp ${./fixture.rs} src/bin/slo_fixture.rs
    '';
  });
  tls = pkgs.runCommand "underclass-slo-local-provider-tls" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p "$out"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=underclass-test -keyout ca.key -out "$out/ca.pem" 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=provider.test -keyout "$out/server.key" -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:provider.test\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA "$out/ca.pem" -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out "$out/server.pem" 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-underclass-proxy-slo";
  nodes.machine = { lib, ... }: {
    imports = [ underclassModule ];
    options.services.overallsOtelFleet.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    config = {
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      networking.hostName = "panterloons";
      networking.extraHosts = "127.0.0.1 provider.test\n";
      security.pki.certificateFiles = [ "${tls}/ca.pem" ];
      users.groups.overalls-otel-underclass-proxy = {};
      users.groups.overalls-otel-underclass = {};
      users.users.overalls-otel-underclass-probe = {
        isSystemUser = true;
        group = "overalls-otel-underclass";
      };
      services.underclass = {
        enable = true;
        package = fixturePackage;
        tailscaleServe.enable = false;
        environmentFile = "/etc/underclass-test.env";
      };
      environment.etc."underclass-test.env".text = ''
        UNDERCLASS_PROXY_KEY=synthetic-proxy-key
        UNDERCLASS_UI_TOKEN=synthetic-admin-token
        UNDERCLASS_CODEX_UPSTREAM=https://provider.test:8443/responses
        UNDERCLASS_CODEX_USAGE_BASE=https://provider.test:8443
        UNDERCLASS_AUTO_CODEX_RESETS=false
      '';
      systemd.services.underclass = {
        after = [ "nginx.service" "underclass-fixture.service" ];
        requires = [ "nginx.service" "underclass-fixture.service" ];
        serviceConfig.ExecStartPre = lib.mkForce [
          "${pkgs.runtimeShell} -ec 'test -n \"$UNDERCLASS_PROXY_KEY\"; test -n \"$UNDERCLASS_UI_TOKEN\"; test \"$UNDERCLASS_PROXY_KEY\" != \"$UNDERCLASS_UI_TOKEN\"'"
          "${fixturePackage}/bin/slo_fixture seed /var/lib/underclass"
        ];
      };
      systemd.services.underclass-monitor-probe.wantedBy = lib.mkForce [];
      systemd.services.underclass-fixture = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${fixturePackage}/bin/slo_fixture serve /run/underclass-fixture";
          DynamicUser = true;
          RuntimeDirectory = "underclass-fixture";
          RuntimeDirectoryMode = "0755";
          Restart = "always";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts."provider.test" = {
          onlySSL = true;
          listen = [{ addr = "127.0.0.1"; port = 8443; ssl = true; }];
          sslCertificate = "${tls}/server.pem";
          sslCertificateKey = "${tls}/server.key";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8081";
            extraConfig = "proxy_buffering off;";
          };
        };
      };
      services.opentelemetry-collector = {
        enable = true;
        package = pkgs.opentelemetry-collector-contrib;
        settings = {
          receivers."otlp/application-underclass-proxy".protocols.http = {
            endpoint = "/run/overalls-otel-underclass-proxy/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          processors."resource/application-underclass-proxy".attributes = [
            { key = "service.name"; value = "underclass_proxy"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = "panterloons"; action = "upsert"; }
          ];
          exporters.prometheus = {
            endpoint = "127.0.0.1:9464";
            resource_to_telemetry_conversion.enabled = true;
          };
          service.pipelines."metrics/application-underclass-proxy" = {
            receivers = [ "otlp/application-underclass-proxy" ];
            processors = [ "resource/application-underclass-proxy" ];
            exporters = [ "prometheus" ];
          };
        };
      };
      systemd.services.opentelemetry-collector.serviceConfig = {
        Group = "overalls-otel-underclass-proxy";
        RuntimeDirectory = "overalls-otel-underclass-proxy";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";
      };
      environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.sqlite ];
    };
  };
  testScript = builtins.readFile ./driver.py;
}
