{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.enrico;
  gitOwner = pkgs.callPackage ../artifacts/applications/enrico-git-owner.nix {};
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  runtime = pkgs.writeText "enrico-config.json" (builtins.toJSON {
    bind = cfg.bindAddress;
    port = cfg.port;
    state_dir = cfg.stateDirectory;
    token_file = "/run/enrico/credentials/token";
    certificate_file = "/run/enrico/credentials/tls.crt";
    key_file = "/run/enrico/credentials/tls.key";
    status_socket = "/run/enrico/status.sock";
  });
in {
  options.services.enrico = {
    enable = mkEnableOption "private public-GitHub mirror service";
    package = mkOption { type = types.package; default = packages.enrico; };
    bindAddress = mkOption { type = types.strMatching "[0-9]+(\\.[0-9]+){3}"; default = "127.0.0.1"; };
    port = mkOption { type = types.port; default = 5445; };
    stateDirectory = mkOption { type = types.str; default = "/var/lib/enrico"; };
    cacheDataset = mkOption { type = types.nullOr types.str; default = null; };
    cacheQuotaGiB = mkOption { type = types.ints.positive; default = 100; };
    tokenFile = mkOption { type = types.str; };
    certificateFile = mkOption { type = types.str; };
    keyFile = mkOption { type = types.str; };
    secretUnits = mkOption { type = types.listOf types.str; default = []; };
    cpuCores = mkOption { type = types.ints.positive; default = 2; };
    memoryMiB = mkOption { type = types.ints.positive; default = 8192; };
  };

  # @cc [owner:ghuntley,label:security;capacity] enrico-private-bounded-cache
  # Enrico MUST bind an explicit private address, receive credentials through
  # systemd, and use a service-owned ZFS dataset capped at the configured quota.
  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.bindAddress != "0.0.0.0"; message = "Enrico must not bind a wildcard address."; }
      { assertion = cfg.cacheDataset == null || lib.hasPrefix "/var/lib/" cfg.stateDirectory;
        message = "Enrico ZFS cache must mount under /var/lib."; }
    ];
    users.groups.enrico = {};
    users.users.enrico = { isSystemUser = true; group = "enrico"; };
    systemd.services.enrico-cache = mkIf (cfg.cacheDataset != null) {
      description = "Prepare quota-bound Enrico cache dataset";
      wantedBy = [ "enrico.service" ];
      before = [ "enrico.service" ];
      after = [ "zfs-mount.service" ];
      requires = [ "zfs-mount.service" ];
      path = [ config.boot.zfs.package pkgs.coreutils ];
      script = ''
        if ! zfs list -H ${lib.escapeShellArg cfg.cacheDataset} >/dev/null 2>&1; then
          zfs create -o mountpoint=${lib.escapeShellArg cfg.stateDirectory} \
            -o refquota=${toString cfg.cacheQuotaGiB}G ${lib.escapeShellArg cfg.cacheDataset}
        fi
        test "$(zfs get -H -o value mountpoint ${lib.escapeShellArg cfg.cacheDataset})" = ${lib.escapeShellArg cfg.stateDirectory}
        zfs set refquota=${toString cfg.cacheQuotaGiB}G ${lib.escapeShellArg cfg.cacheDataset}
        zfs mount ${lib.escapeShellArg cfg.cacheDataset} || true
        test "$(zfs get -H -o value mounted ${lib.escapeShellArg cfg.cacheDataset})" = yes
        chown enrico:enrico ${lib.escapeShellArg cfg.stateDirectory}
        chmod 0700 ${lib.escapeShellArg cfg.stateDirectory}
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    };
    systemd.services.enrico = {
      description = "Enrico Git mirror";
      path = [ pkgs.git pkgs.coreutils gitOwner ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits ++ lib.optional (cfg.cacheDataset != null) "enrico-cache.service";
      requires = cfg.secretUnits ++ lib.optional (cfg.cacheDataset != null) "enrico-cache.service";
      wants = [ "network-online.target" ];
      environment = { ENRICO_CONFIG_FILE = runtime; RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "/run/enrico"; ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores}"; };
      preStart = ''
        mkdir -p -m 0700 /run/enrico/credentials
        for credential in token tls.crt tls.key; do
          install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/enrico/credentials/$credential"
        done
      '';
      postStart = lib.mkIf otelEnabled ''
        for attempt in $(${pkgs.coreutils}/bin/seq 1 900); do
          if test -S /run/enrico/status.sock; then
            ${pkgs.coreutils}/bin/chmod 0660 /run/enrico/status.sock
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        exit 1
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${cfg.package}/bin/enrico start
      '';
      serviceConfig = {
        Type = "exec"; User = "enrico"; Group = "enrico"; UMask = "0077";
        LoadCredential = [ "token:${cfg.tokenFile}" "tls.crt:${cfg.certificateFile}" "tls.key:${cfg.keyFile}" ];
        RuntimeDirectory = "enrico"; RuntimeDirectoryMode = "0700";
        StateDirectory = lib.optional (cfg.cacheDataset == null) "enrico";
        WorkingDirectory = cfg.package;
        Restart = "on-failure"; RestartSec = 5;
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
        NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
        ProtectSystem = "strict"; ProtectHome = true;
        ProtectKernelTunables = true; ProtectKernelModules = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ cfg.stateDirectory ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictSUIDSGID = true; LockPersonality = true;
      };
    };
  };
}
