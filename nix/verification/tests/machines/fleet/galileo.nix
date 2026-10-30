{ pkgs, root }:
let
  # @cc [owner:ghuntley,label:verification;security] fleet-private-issuer-chain
  # Audi's fixture leaf MUST be signed by a name-constrained intermediate and
  # contain only the supported private names, so guest TLS exercises the same
  # chain and DNS-name validation as production.
  pki = pkgs.runCommand "galileo-fleet-private-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=galileo-fleet-private-root -keyout root.key -out $out/root.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=galileo-fleet-private-issuer -keyout issuer.key -out issuer.csr 2>/dev/null
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nnameConstraints=critical,permitted;DNS:internal\n' > issuer.ext
    openssl x509 -req -in issuer.csr -CA $out/root.pem -CAkey root.key -CAcreateserial \
      -days 3650 -extfile issuer.ext -out issuer.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=integration.internal -keyout $out/private.key -out private.csr 2>/dev/null
    printf 'subjectAltName=DNS:llm.internal,DNS:reflection.internal,DNS:*.integration.internal\nextendedKeyUsage=serverAuth\n' > private.ext
    openssl x509 -req -in private.csr -CA issuer.pem -CAkey issuer.key -CAcreateserial \
      -days 3650 -extfile private.ext -out leaf.pem 2>/dev/null
    openssl verify -CAfile $out/root.pem -untrusted issuer.pem \
      -verify_hostname ssh.integration.internal leaf.pem >/dev/null
    openssl verify -CAfile $out/root.pem -untrusted issuer.pem \
      -verify_hostname reflection.internal leaf.pem >/dev/null
    cat leaf.pem issuer.pem > $out/private.pem
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=origin.galileo.test -keyout $out/origin.key -out origin.csr 2>/dev/null
    printf 'subjectAltName=DNS:origin.galileo.test\nextendedKeyUsage=serverAuth\n' > origin.ext
    openssl x509 -req -in origin.csr -CA $out/root.pem -CAkey root.key -CAcreateserial \
      -days 3650 -extfile origin.ext -out $out/origin.pem 2>/dev/null
  '';
in {
  inherit pki;

  # @cc [owner:ghuntley,label:verification;security] galileo-fleet-real-private-edge
  # The Galileo fleet check MUST run packaged Galileo and Audi private on both
  # enrolled Lilly hosts with credentials issued by the real Marshall domain.
  # Only public synthetic CA material may enter the guest image; wildcard keys
  # and control credentials MUST travel through the runtime SOPS bundles. The
  # fixture-issued public Audi root MUST be trusted by Galileo before startup.
  lilly = { nodes, lib, ... }: {
    networking.extraHosts = "11.0.0.1 origin.galileo.test\n";
    networking.nameservers = [ nodes.m2.networking.primaryIPAddress nodes.m3.networking.primaryIPAddress ];
    security.pki.certificateFiles = [ "${pki}/root.pem" ];
    services.galileo = {
      enable = true;
      secretsFile = "${root}/galileo.enc.json";
      cpuCores = 1;
      memoryMiB = 512;
    };
    systemd.services.galileo = {
      environment.ERL_AFLAGS =
        "-eval 'public_key:cacerts_load(\"/run/galileo/credentials/upstream-roots.pem\").'";
      preStart = lib.mkAfter ''
        cat /etc/ssl/certs/ca-bundle.crt /run/galileo-audi-root.pem > /run/galileo/credentials/upstream-roots.pem
        chmod 0400 /run/galileo/credentials/upstream-roots.pem
      '';
    };
    # @cc [owner:ghuntley,label:verification;security] peach-fleet-explicit-start
    # Peach is packaged on every fleet Lilly host but starts only after the
    # Galileo scenario seals a credential issued by the real Marshall domain;
    # other fleet scenarios see reflection.internal as unavailable.
    services.peach = {
      enable = true;
      secretsFile = "${root}/peach.enc.json";
    };
    systemd.services.peach.wantedBy = lib.mkForce [];
    services.audiPrivate = {
      enable = true;
      secretsFile = "${root}/audi-private.enc.json";
      rootsFile = "${pki}/root.pem";
    };
    systemd.services.fleet-galileo-credentials = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 900; };
      # @cc [owner:ghuntley,label:verification;security;recovery] fleet-public-trust-survives-reboot
      # The public Audi root obtained from the real fixture issuer MUST survive
      # a host reboot and be restored before Galileo starts. Missing trust MUST
      # postpone startup; this fixture MUST NOT substitute another CA or persist
      # private keys or control credentials outside their encrypted bundles.
      script = ''
        while [ ! -f ${root}/galileo.enc.json ] || [ ! -f ${root}/audi-private.enc.json ] ||
          { [ ! -s /run/galileo-audi-root.pem ] && [ ! -s ${root}/galileo-audi-root.pem ]; }; do
          sleep 1
        done
        if [ -s /run/galileo-audi-root.pem ]; then
          ${pkgs.coreutils}/bin/install -m 0444 /run/galileo-audi-root.pem ${root}/galileo-audi-root.pem
        else
          ${pkgs.coreutils}/bin/install -m 0444 ${root}/galileo-audi-root.pem /run/galileo-audi-root.pem
        fi
      '';
    };
    systemd.services.overalls-secrets-galileo = {
      after = [ "fleet-galileo-credentials.service" ];
      requires = [ "fleet-galileo-credentials.service" ];
    };
    systemd.services.overalls-secrets-audi-private = {
      after = [ "fleet-galileo-credentials.service" ];
      requires = [ "fleet-galileo-credentials.service" ];
    };
  };

  origin = {
    networking.firewall.allowedTCPPorts = [ 443 ];
    systemd.services.fleet-galileo-origin = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./galileo-origin.py} ${pki}/origin.pem ${pki}/origin.key";
        DynamicUser = true;
        RuntimeDirectory = "galileo-origin";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
