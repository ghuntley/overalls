{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.peach;
  paths = import ./types.nix { inherit lib; };
  runtime = pkgs.writeText "peach-config.json" (builtins.toJSON {
    version = 1;
    host_id = cfg.hostId;
    control_plane = cfg.controlPlane;
    ca_file = "/run/peach/credentials/ca.pem";
    credential_file = "/run/peach/credentials/control.token";
    socket = cfg.socket;
  });
in {
  options.services.peach = {
    enable = mkEnableOption "guest reflection service behind Audi's private frontend";
    package = mkOption { type = types.package; default = packages.peach; };
    hostId = mkOption { type = paths.uuid; default = config.services.lilly.hostId; description = "Enrolled local Lilly host identity."; };
    controlPlane = mkOption { type = types.str; default = config.services.lilly.controlPlane; description = "Verified HTTPS Marshall origin."; };
    caFile = mkOption { type = paths.absolutePath; default = config.services.lilly.controlPlaneCAFile; };
    secretsFile = mkOption { type = paths.absolutePath; description = "SOPS document containing PEACH_CREDENTIAL."; };
    credentialFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/peach/control.token"; readOnly = true; description = "Dedicated Peach control credential runtime file."; };
    socket = mkOption { type = paths.privatePath; default = "/run/peach/reflection.sock"; readOnly = true; description = "Unix socket Audi's private frontend forwards reflection.internal to."; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
  };

  # @cc [owner:ghuntley,label:security;deployment] peach-socket-and-credential-custody
  # Peach MUST receive only its dedicated host-bound control credential, copied
  # from systemd credentials into a 0700 runtime directory. Only Audi (through
  # peach-proxy) may connect to the reflection socket; Peach MUST NOT require
  # Lilly to be running, and its outage MUST NOT gate guest execution.
  config = mkIf cfg.enable {
    assertions = [
      { assertion = config.services.lilly.enable; message = "Peach must run on an enabled Lilly node."; }
      { assertion = cfg.hostId == config.services.lilly.hostId; message = "Peach and local Lilly identities must match."; }
    ];
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.peach = {
      encryptedFile = cfg.secretsFile;
      outputs."control.token" = { format = "raw"; secrets = [ "PEACH_CREDENTIAL" ]; };
    };
    services.peach.secretUnits = [ "overalls-secrets-peach.service" ];
    users.groups.peach = {};
    users.groups.peach-proxy = {};
    users.users.peach = { isSystemUser = true; group = "peach"; extraGroups = [ "peach-proxy" ]; };
    users.users.audi = { isSystemUser = true; group = "audi"; extraGroups = [ "peach-proxy" ]; };
    systemd.services.peach = {
      description = "Peach guest reflection service";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment = {
        PEACH_CONFIG_FILE = runtime;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "/run/peach";
        ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S 1:1";
      };
      preStart = ''
        ${pkgs.coreutils}/bin/chgrp peach-proxy /run/peach
        ${pkgs.coreutils}/bin/chmod 0750 /run/peach
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/peach/credentials
        for credential in control.token ca.pem; do
          ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/peach/credentials/$credential"
        done
        ${pkgs.coreutils}/bin/rm -f ${cfg.socket}
      '';
      postStart = ''
        ${pkgs.coreutils}/bin/chgrp peach-proxy /run/peach
        for attempt in $(${pkgs.coreutils}/bin/seq 1 900); do
          if test -S ${cfg.socket}; then
            ${pkgs.coreutils}/bin/chgrp peach-proxy ${cfg.socket}
            ${pkgs.coreutils}/bin/chmod 0660 ${cfg.socket}
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        exit 1
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${cfg.package}/bin/peach start
      '';
      serviceConfig = {
        Type = "exec";
        User = "peach";
        Group = "peach";
        UMask = "0007";
        LoadCredential = [ "control.token:${cfg.credentialFile}" "ca.pem:${cfg.caFile}" ];
        RuntimeDirectory = "peach";
        RuntimeDirectoryMode = "0750";
        WorkingDirectory = cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
        KillMode = "control-group";
        CPUQuota = "100%";
        MemoryMax = "512M";
        CapabilityBoundingSet = [];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
