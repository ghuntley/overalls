{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.galileo;
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  paths = import ./types.nix { inherit lib; };
  runtime = pkgs.writeText "galileo-public-config.json" (builtins.toJSON {
    version = 1;
    # @cc [owner:ghuntley,label:deployment] galileo-replacement-runtime-host-binding
    # Only a bounded test fixture may carry the placeholder host marker; deployed
    # configurations keep the enrolled host identity.
    host_id = if cfg.configurationFile != null then "@replacement-host-id@" else cfg.hostId;
    control_plane = cfg.controlPlane;
    ca_file = "/run/galileo/credentials/ca.pem";
    credential_file = "/run/galileo/credentials/control.token";
    socket = "/run/galileo/proxy.sock";
  });
in {
  options.services.galileo = {
    enable = (mkEnableOption "private node-local named integration proxy") // { default = config.services.lilly.enable; };
    package = mkOption { type = types.package; default = packages.galileo; };
    hostId = mkOption { type = paths.uuid; default = config.services.lilly.hostId; description = "Enrolled local Lilly host identity."; };
    configurationFile = mkOption { type = types.nullOr types.path; default = null; description = "Release-independent runtime configuration; null uses the deployed configuration."; };
    controlPlane = mkOption { type = types.str; default = config.services.lilly.controlPlane; description = "Verified HTTPS Marshall origin."; };
    caFile = mkOption { type = paths.absolutePath; default = config.services.lilly.controlPlaneCAFile; };
    secretsFile = mkOption { type = paths.absolutePath; description = "SOPS document containing GALILEO_CREDENTIAL."; };
    credentialFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/galileo/control.token"; readOnly = true; description = "Dedicated Galileo control credential runtime file."; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
    cpuCores = mkOption { type = types.ints.positive; default = 2; };
    memoryMiB = mkOption { type = types.ints.positive; default = 2048; };
  };
  # @cc [owner:ghuntley,label:deployment] galileo-required-with-lilly
  # Enabling Lilly MUST enable Galileo automatically. Explicitly disabling
  # Galileo on a Lilly node MUST fail evaluation, including a forced override.
  # The control credential remains a required input; missing credentials MUST
  # NOT disable Galileo. Galileo health MUST NOT gate guest execution.
  config = lib.mkMerge [ {
    assertions = [{
      assertion = !config.services.lilly.enable || cfg.enable;
      message = "Lilly requires Galileo; services.galileo.enable cannot be false on a Lilly node.";
    }];
  } (mkIf cfg.enable {
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.galileo = {
      encryptedFile = cfg.secretsFile;
      outputs = {
        "control.token" = { format = "raw"; secrets = [ "GALILEO_CREDENTIAL" ]; };
      };
    };
    services.galileo.secretUnits = [ "overalls-secrets-galileo.service" ];

    assertions = [
      { assertion = lib.attrByPath [ "services" "lilly" "enable" ] false config;
        message = "Galileo must run on an enabled Lilly node."; }
      { assertion = cfg.hostId == config.services.lilly.hostId;
        message = "Galileo and local Lilly identities must match."; }
    ];
    users.groups.galileo = {};
    users.groups.galileo-proxy = {};
    users.users.galileo = { isSystemUser = true; group = "galileo"; extraGroups = [ "galileo-proxy" ]; };
    users.users.audi = { isSystemUser = true; group = "audi"; extraGroups = [ "galileo-proxy" ]; };
    systemd.services.galileo = {
      description = "Galileo named integration proxy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "ziggy.service" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment = {
        GALILEO_CONFIG_FILE = if cfg.configurationFile != null then cfg.configurationFile else runtime;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "/run/galileo";
        ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores}";
      };
      preStart = ''
        ${pkgs.lib.optionalString (cfg.configurationFile != null) ''
          ${pkgs.coreutils}/bin/install -m 0644 ${runtime} ${cfg.configurationFile}.seed
          ${pkgs.python3}/bin/python3 -c "import pathlib,sys; p=pathlib.Path(sys.argv[2]); seed=pathlib.Path(sys.argv[1]).read_text().replace(\"@replacement-host-id@\", pathlib.Path(sys.argv[3]).read_text().strip()); p.write_text(seed)" ${cfg.configurationFile}.seed ${cfg.configurationFile} /run/lilly-release-host-id
        ''}
        ${pkgs.coreutils}/bin/chgrp galileo-proxy /run/galileo
        ${pkgs.coreutils}/bin/chmod 0750 /run/galileo
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/galileo/credentials
        for credential in control.token ca.pem; do
          ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/galileo/credentials/$credential"
        done
        ${pkgs.coreutils}/bin/rm -f /run/galileo/proxy.sock
      '';
      postStart = ''
        ${pkgs.coreutils}/bin/chgrp galileo-proxy /run/galileo
        for attempt in $(${pkgs.coreutils}/bin/seq 1 900); do
          if test -S /run/galileo/proxy.sock; then
            ${pkgs.coreutils}/bin/chgrp galileo-proxy /run/galileo/proxy.sock
            ${pkgs.coreutils}/bin/chmod 0660 /run/galileo/proxy.sock
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        exit 1
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${cfg.package}/bin/galileo start
      '';
      serviceConfig = {
        Type = "exec";
        User = "galileo";
        Group = "galileo";
        UMask = "0007";
        LoadCredential = [ "control.token:${cfg.credentialFile}" "ca.pem:${cfg.caFile}" ];
        RuntimeDirectory = "galileo";
        RuntimeDirectoryMode = "0750";
        WorkingDirectory = cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
        KillMode = "control-group";
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
        LimitNOFILE = 65536;
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
  }) ];
}
