{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  names = [ "primary" "secondary" "tertiary" ];
  python = pkgs.python3.withPackages (p: [ p.cryptography p.dnslib p.websockets ]);
  fixture = "${python}/bin/python ${../../support/acme-fixture.py}";
  pebbleConfig = pkgs.writeText "overalls-http01-pebble.json" (builtins.toJSON {
    pebble = {
      listenAddress = "0.0.0.0:14000";
      managementListenAddress = "0.0.0.0:15000";
      certificate = "/run/overalls-test/tls.crt";
      privateKey = "/run/overalls-test/tls.key";
      httpPort = 80;
      tlsPort = 5001;
      certificateValidityPeriod = 172800;
      retryAfter = { authz = 1; order = 1; };
    };
  });
  frontend = name: { config, nodes, ... }: {
    services.marshall.enable = true;
    networking.extraHosts = "${nodes.validator.networking.primaryIPAddress} control.example.test\n";
    services.marshallProxy = {
      enable = true;
      bindAddress = lib.mkForce "0.0.0.0";
      acme = {
        enable = true;
        email = "${name}@example.test";
        server = "https://control.example.test:14000/dir";
        caFile = "/run/overalls-test-acme-public/trust.crt";
        secretUnits = [ "overalls-http01-trust.service" ];
        http01 = {
          bindAddress = config.networking.primaryIPAddress;
          peers = map (peer: { address = nodes.${peer}.networking.primaryIPAddress; }) (lib.remove name names);
        };
      };
    };
    security.acme = {
      acceptTerms = true;
      certs."control.example.test".validMinDays = 3;
    };
    systemd.services.overalls-http01-trust = {
      after = [ "overalls-test-fixture.service" ];
      requires = [ "overalls-test-fixture.service" ];
      script = ''
        ${fixture} setup-http
        while [ ! -f /run/overalls-test-acme-public/issuer-ca.crt ]; do sleep 1; done
        ${fixture} trust-http
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 180; UMask = "0077"; };
    };
    # Explicit driver control makes validation land on another frontend.
    systemd.services."acme-control.example.test".wants = lib.mkForce [ "acme-setup.service" ];
    systemd.timers."acme-control.example.test".wantedBy = lib.mkForce [];
    systemd.services."acme-order-renew-control.example.test".environment = {
      AWS_SHARED_CREDENTIALS_FILE = "/missing-aws-profile";
      AWS_ACCESS_KEY_ID = "ignored-http-ambient-input";
    };
    environment.systemPackages = [ python ];
    specialisation = lib.optionalAttrs (name == "primary") {
      standalone.configuration = {
        services.marshallProxy.acme.http01 = {
          bindAddress = lib.mkForce "127.0.0.1";
          peers = lib.mkForce [];
        };
        environment.etc."http01-standalone".enable = lib.mkForce false;
      };
    };
    environment.etc = {
      "http01-addresses.json".text = builtins.toJSON (map (peer: nodes.${peer}.networking.primaryIPAddress) names);
    } // lib.optionalAttrs (name == "primary") {
      "http01-standalone".text = "${config.specialisation.standalone.configuration.system.build.toplevel}";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "overalls-acme-http01";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes = lib.genAttrs names frontend // {
    validator = { ... }: {
      virtualisation.memorySize = lib.mkForce 1024;
      networking.firewall.allowedTCPPorts = [ 14000 15000 ];
      systemd.services.overalls-http01-dns = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${python}/bin/python ${./dns.py}";
          RuntimeDirectory = "overalls-http01-dns";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
      };
      systemd.services.overalls-test-pebble = {
        wantedBy = [ "multi-user.target" ];
        after = [ "overalls-test-fixture.service" "overalls-http01-dns.service" ];
        requires = [ "overalls-test-fixture.service" "overalls-http01-dns.service" ];
        environment = {
          PEBBLE_VA_NOSLEEP = "1";
          PEBBLE_VA_ALWAYS_VALID = "0";
          PEBBLE_WFE_NONCEREJECT = "0";
          PEBBLE_AUTHZREUSE = "0";
        };
        serviceConfig = {
          ExecStart = "${pkgs.pebble}/bin/pebble -config ${pebbleConfig} -dnsserver 127.0.0.1:53";
          # The CA fixture must not put raw challenge URLs into retained logs.
          StandardOutput = "null";
          StandardError = "null";
        };
      };
      environment.systemPackages = [ python ];
    };
  };
  testScript = ''
    fixture = ${builtins.toJSON fixture}
  '' + builtins.readFile ./driver.py;
}
