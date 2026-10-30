{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.audiPrivateIssuer;
  paths = import ./types.nix { inherit lib; };
  encrypted = cfg.secretsFile != null;
  credentialUnits = cfg.secretUnits ++ lib.optional encrypted "overalls-secrets-audi-private-issuer.service";
  keyFile = if encrypted then "/run/overalls-secrets/audi-private-issuer/issuer.key" else cfg.issuerKeyFile;
  certificateFile = if encrypted then "/run/overalls-secrets/audi-private-issuer/issuer.pem" else cfg.issuerCertificateFile;
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
  runtime = pkgs.writeText "audi-private-issuer-runtime.json" (builtins.toJSON {
    version = 1;
    role = "private-issuer";
    socket = "/run/audi-private-issuer/issuer.sock";
    python = "${python}/bin/python3";
    issuer_key = "/run/audi-private-issuer/credentials/issuer.key";
    issuer_certificate = "/run/audi-private-issuer/credentials/issuer.pem";
  });
in {
  options.services.audiPrivateIssuer = {
    enable = lib.mkEnableOption "restricted Audi private intermediate issuer on the selected Marshall node";
    package = lib.mkOption { type = lib.types.package; default = packages.audi; };
    secretsFile = lib.mkOption { type = lib.types.nullOr paths.absolutePath; default = null; description = "Issuer-only SOPS document, excluding the recovery root key."; };
    issuerKeyFile = lib.mkOption { type = lib.types.nullOr paths.privatePath; default = null; description = "Private runtime intermediate key when independently generated on this instance."; };
    issuerCertificateFile = lib.mkOption { type = lib.types.nullOr paths.absolutePath; default = null; description = "Matching public intermediate certificate for the runtime key."; };
    secretUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
  };
  # @cc [owner:ghuntley,label:security] private-issuer-exclusive-custody
  # Enabled issuers MUST select exactly one complete custody source: an encrypted
  # issuer-only bundle or a runtime intermediate key/certificate pair. The root
  # private key MUST NOT be delivered to the online issuer. Direct keys MUST stay
  # outside the Nix store and readiness MUST await their producing units.
  config = lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [
      { assertion = config.services.marshall.enable; message = "Audi's private issuer requires the local Marshall authority."; }
      { assertion = if encrypted then cfg.issuerKeyFile == null && cfg.issuerCertificateFile == null
                    else cfg.issuerKeyFile != null && cfg.issuerCertificateFile != null;
        message = "Audi private issuer requires exactly one complete encrypted or runtime credential source."; }
    ];
    users.groups.audi-private-issuer = {};
    users.groups.audi-private-signing = {};
    users.users.audi-private-issuer = { isSystemUser = true; group = "audi-private-issuer"; extraGroups = [ "audi-private-signing" ]; };
    systemd.services = (lib.genAttrs (map (name: "marshall-${name}") (builtins.attrNames config.services.marshall.instances)) (_: {
      environment.MARSHALL_PRIVATE_ISSUER_SOCKET = "/run/audi-private-issuer/issuer.sock";
      serviceConfig.SupplementaryGroups = [ "audi-private-signing" ];
    })) // {
      audi-private-issuer = {
        description = "Audi restricted private CA issuer";
        wantedBy = [ "multi-user.target" ];
        after = credentialUnits;
        requires = credentialUnits;
        environment = {
          AUDI_CONFIG_FILE = runtime;
          RELEASE_DISTRIBUTION = "none";
          RELEASE_TMP = "/run/audi-private-issuer";
          ERL_CRASH_DUMP = "/dev/null";
          ERL_FLAGS = "+S 2:2";
        };
        preStart = ''
          ${pkgs.coreutils}/bin/chgrp audi-private-signing /run/audi-private-issuer
          ${pkgs.coreutils}/bin/chmod 0750 /run/audi-private-issuer
          ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/audi-private-issuer/credentials
          for credential in issuer.key issuer.pem; do
            ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/audi-private-issuer/credentials/$credential"
          done
          ${pkgs.coreutils}/bin/rm -f /run/audi-private-issuer/issuer.sock
        '';
        postStart = ''
          ${pkgs.coreutils}/bin/chgrp audi-private-signing /run/audi-private-issuer
          for attempt in $(${pkgs.coreutils}/bin/seq 1 900); do
            if test -S /run/audi-private-issuer/issuer.sock; then
              ${pkgs.coreutils}/bin/chgrp audi-private-signing /run/audi-private-issuer/issuer.sock
              ${pkgs.coreutils}/bin/chmod 0660 /run/audi-private-issuer/issuer.sock
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          exit 1
        '';
        script = ''
          export RELEASE_COOKIE
          RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
          exec ${cfg.package}/bin/audi start
        '';
        serviceConfig = {
          Type = "exec";
          User = "audi-private-issuer";
          Group = "audi-private-issuer";
          UMask = "0007";
          LoadCredential = lib.optionals (keyFile != null && certificateFile != null) [
            "issuer.key:${keyFile}" "issuer.pem:${certificateFile}"
          ];
          RuntimeDirectory = "audi-private-issuer";
          RuntimeDirectoryMode = "0750";
          Restart = "on-failure";
          RestartSec = 5;
          MemoryMax = "512M";
          CapabilityBoundingSet = [];
          NoNewPrivileges = true;
          PrivateNetwork = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          RestrictSUIDSGID = true;
          LockPersonality = true;
        };
      };
    };
  } (lib.mkIf encrypted {
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.audi-private-issuer = {
      encryptedFile = cfg.secretsFile;
      outputs = {
        "issuer.key" = { format = "raw"; secrets = [ "AUDI_PRIVATE_ISSUER_KEY" ]; };
        "issuer.pem" = { format = "raw"; secrets = [ "AUDI_PRIVATE_ISSUER_CERTIFICATE" ]; };
      };
    };
  })]);
}
