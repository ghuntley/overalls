{ pkgs, hegel }:
let
  fixture = pkgs.runCommand "burn-webhook-fixture" { nativeBuildInputs = [ pkgs.rustc pkgs.stdenv.cc ]; } ''
    mkdir -p $out/bin
    rustc --edition=2024 -D warnings ${./receiver.rs} -o $out/bin/burn-webhook
  '';
  tls = pkgs.runCommand "burn-delivery-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=notify.test -addext subjectAltName=DNS:notify.test \
      -keyout $out/key.pem -out $out/ca.pem 2>/dev/null
  '';
  firing = pkgs.writeText "burn-delivery-fixture-rules.json" (builtins.toJSON {
    groups = [{ name = "isolated-delivery"; interval = "1s"; rules = [{
      alert = "OverallsSLOBurn_fast_galileo";
      expr = "vector(1)";
      labels = { severity = "warning"; status = "provisional"; slo = "galileo"; window = "fast"; };
    }]; }];
  });
in hegel.runTest {
  name = "overalls-otel-burn-delivery";
  properties = {
    enable = true;
    profile = "ci";
    testCases = 80;
    derandomize = true;
  };
  nodes.machine = { lib, ... }: {
    imports = [ ../../../../domains/system/otel-fleet/burn-delivery.nix ];
    options.services.overallsOtelFleet = {
      enable = lib.mkOption { type = lib.types.bool; default = true; };
      role = lib.mkOption { type = lib.types.enum [ "central" "worker" ]; default = "central"; };
    };
    config = {
      virtualisation.memorySize = 1024;
      networking.extraHosts = "127.0.0.1 notify.test\n";
      security.pki.certificateFiles = [ "${tls}/ca.pem" ];
      services.overallsOtelFleet.burnAlerts = {
        enable = true;
        webhookUrlFile = "/run/burn-fixture/url";
        bearerTokenFile = "/run/burn-fixture/token";
      };
      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        ruleFiles = [ firing ];
        globalConfig.evaluation_interval = "1s";
      };
      systemd.services.burn-fixture-credentials = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "burn-fixture"; RuntimeDirectoryMode = "0700"; };
        script = ''
          umask 077
          printf '%s\n' https://notify.test:8443/notify > /run/burn-fixture/url
          printf '%s\n' synthetic-delivery-token > /run/burn-fixture/token
        '';
      };
      systemd.services.alertmanager = {
        after = [ "burn-fixture-credentials.service" ];
        requires = [ "burn-fixture-credentials.service" ];
        # Speed up batching only inside the disposable native fixture. The
        # production route roster and runtime validation remain unchanged.
        preStart = lib.mkAfter ''
          ${pkgs.jq}/bin/jq '.route.group_wait = "1s" | .route.group_interval = "2s" | .route.repeat_interval = "1m"' \
            /tmp/alert-manager-substituted.yaml > /tmp/burn-fixture-config.json
          mv /tmp/burn-fixture-config.json /tmp/alert-manager-substituted.yaml
        '';
      };
      systemd.services.burn-webhook = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { ExecStart = "${fixture}/bin/burn-webhook"; StateDirectory = "burn-webhook"; DynamicUser = true; };
      };
      services.nginx = {
        enable = true;
        virtualHosts."notify.test" = {
          onlySSL = true;
          listen = [{ addr = "127.0.0.1"; port = 8443; ssl = true; }];
          sslCertificate = "${tls}/ca.pem";
          sslCertificateKey = "${tls}/key.pem";
          locations."/notify".proxyPass = "http://127.0.0.1:18080";
        };
      };
      environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.iproute2 pkgs.prometheus-alertmanager ];
      environment.etc."burn-fixture-roster.json".text = builtins.toJSON
        (map (objective: objective.id) (import ../../../../domains/system/otel-fleet/objectives.nix { hosts = [ "panterloons" "dungarees" ]; }));
    };
  };
  testScript = builtins.readFile ./driver.py;
}
