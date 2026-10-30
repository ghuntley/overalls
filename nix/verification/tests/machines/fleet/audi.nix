{ pkgs, role, hostId ? null, ubuntu ? false }:
{ nodes, config, lib, ... }:
let
  root = "/var/lib/overalls-fleet";
  gate = {
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "infinity"; };
    script = ''
      while [ ! -s ${root}/audi.token ]; do sleep 1; done
    '';
  };
  pebble = pkgs.writeText "audi-fleet-pebble.json" (builtins.toJSON {
    pebble = {
      listenAddress = "0.0.0.0:14000";
      managementListenAddress = "127.0.0.1:15000";
      certificate = "${root}/tls.crt";
      privateKey = "${root}/tls.key";
      httpPort = 5002;
      tlsPort = 5001;
      certificateValidityPeriod = 172800;
      retryAfter = { authz = 1; order = 1; };
    };
  });
in lib.mkMerge [
  (lib.mkIf (role == "gateway") {
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.lilly.ingress.enable = true;
    services.audi = {
      enable = true;
      inherit hostId;
      openFirewall = true;
      controlPlane = "https://control.example.test:5443";
      caFile = "${root}/ca.crt";
      credentialFile = "${root}/audi.token";
      secretUnits = [ "fleet-credentials.service" "fleet-audi-credentials.service" ];
      tls = {
        enable = true;
        zone = "apps.example.test";
        browserOrigin = "https://control.example.test";
        certificateRootsFile = "${root}/audi-root.pem";
      };
    };
    environment.systemPackages = [ (pkgs.writeShellScriptBin "fleet-audi-guest" ''
      export ERL_FLAGS="+S 2:2" RELEASE_DISTRIBUTION=none RELEASE_COOKIE=isolated-audi-guest
      export FLEET_GUEST_PYTHON=${if ubuntu then "/usr/bin/python3" else "${pkgs.python3}/bin/python3"}
      exec ${config.services.lilly.package}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./audi-guest.exs}")' "$@"
    '') (pkgs.writeShellScriptBin "fleet-ssh-bootstrap-guest" ''
      export ERL_FLAGS="+S 2:2" RELEASE_DISTRIBUTION=none RELEASE_COOKIE=isolated-bootstrap-guest
      exec ${config.services.lilly.package}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./ssh-bootstrap-guest.exs}")' "$@"
    '') ];
    systemd.services.fleet-audi-credentials = gate;
  })
  (lib.mkIf (role == "dns") {
    services.audiDns = {
      enable = true;
      openFirewall = true;
      controlPlane = "https://control.example.test:5443";
      caFile = "${root}/ca.crt";
      credentialFile = "${root}/audi.token";
      zone = "apps.example.test";
      nameservers = [ "m2" "m3" ];
      mailbox = "hostmaster.apps.example.test";
      secretUnits = [ "fleet-credentials.service" "fleet-audi-credentials.service" ];
    };
    systemd.services.fleet-audi-credentials = gate;
  })
  (lib.mkIf (role == "issuer") {
    services.marshall.secretUnits = [ "fleet-audi-ca-roots.service" ];
    services.marshall.ingress.wildcardAcme = {
      issuerInstance = "m1";
      directory = "https://m1:14000/dir";
      issuerCaFile = "${root}/ca.crt";
      certificateRootsFile = "${root}/audi-root.pem";
      acceptTerms = true;
      nameservers = map (node: { address = node.networking.primaryIPAddress; port = 53; }) [ nodes.m2 nodes.m3 ];
    };
    networking.firewall.allowedTCPPorts = [ 14000 ];
    systemd.services.fleet-audi-ca = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fleet-credentials.service" ];
      requires = [ "fleet-credentials.service" ];
      environment = {
        PEBBLE_VA_NOSLEEP = "1";
        PEBBLE_VA_ALWAYS_VALID = "0";
        PEBBLE_WFE_NONCEREJECT = "0";
        PEBBLE_AUTHZREUSE = "0";
      };
      serviceConfig = {
        ExecStart = "${pkgs.pebble}/bin/pebble -config ${pebble} -dnsserver ${nodes.m2.networking.primaryIPAddress}:53";
        UMask = "0077";
      };
    };
    systemd.services.fleet-audi-ca-roots = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fleet-audi-ca.service" ];
      requires = [ "fleet-audi-ca.service" ];
      path = [ pkgs.curl pkgs.coreutils ];
      script = ''
        set -eu
        until curl --fail --silent --cacert ${root}/ca.crt --resolve m1:15000:127.0.0.1 \
            https://m1:15000/roots/0 >${root}/audi-root.pem; do
          sleep 1
        done
        test -s ${root}/audi-root.pem
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 120; };
    };
  })
]
