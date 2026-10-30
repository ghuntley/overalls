{ pkgs, cfg, runtime, otelEnabled ? false }:
# @cc [owner:ghuntley,label:security;deployment] shared-ziggy-service-custody
# Physical and nested Ziggy MUST use this unprivileged IPv4-only service with
# systemd credential snapshots and independent persistent spool state. Runtime
# configuration MUST NOT enable Erlang distribution, expose provider keys in
# arguments, or grant Ziggy access to the host's decryption identity.
{
  description = "Ziggy private inference proxy";
  wantedBy = [ "multi-user.target" ];
  wants = [ "network-online.target" ];
  after = [ "network-online.target" ] ++ cfg.secretUnits;
  requires = cfg.secretUnits;
  environment = {
    ZIGGY_CONFIG_FILE = if cfg.configurationFile != null then cfg.configurationFile else runtime;
    RELEASE_DISTRIBUTION = "none";
    RELEASE_TMP = "/run/ziggy";
    ERL_CRASH_DUMP = "/dev/null";
    ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores}";
  } // pkgs.lib.optionalAttrs otelEnabled { ZIGGY_SLO_SNAPSHOT = "/run/ziggy/slo.json"; };
  preStart = ''
    ${pkgs.lib.optionalString (cfg.configurationFile != null) ''
      ${pkgs.coreutils}/bin/install -m 0644 ${runtime} ${cfg.configurationFile}.seed
      ${pkgs.python3}/bin/python3 -c "import pathlib,sys; p=pathlib.Path(sys.argv[2]); seed=pathlib.Path(sys.argv[1]).read_text().replace(\"@replacement-host-id@\", pathlib.Path(sys.argv[3]).read_text().strip()); p.write_text(seed)" ${cfg.configurationFile}.seed ${cfg.configurationFile} /run/lilly-release-host-id
    ''}
    ${pkgs.coreutils}/bin/chgrp ziggy-proxy /run/ziggy
    ${pkgs.coreutils}/bin/chmod 0750 /run/ziggy
    ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/ziggy/credentials
    for credential in control.token openai.key anthropic.key ca.pem; do
      ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/ziggy/credentials/$credential"
    done
    ${pkgs.coreutils}/bin/mkdir -p -m 0700 /var/lib/ziggy/spool
    ${pkgs.coreutils}/bin/rm -f /run/ziggy/proxy.sock
  '';
  postStart = ''
      ${pkgs.coreutils}/bin/chgrp ziggy-proxy /run/ziggy
    # The release can take well over 10 s to open its socket on loaded
    # hosts; wait up to systemd's default 90 s start budget.
    for attempt in $(${pkgs.coreutils}/bin/seq 1 900); do
      if test -S /run/ziggy/proxy.sock; then
        ${pkgs.coreutils}/bin/chgrp ziggy-proxy /run/ziggy/proxy.sock
        ${pkgs.coreutils}/bin/chmod 0660 /run/ziggy/proxy.sock
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    exit 1
  '';
  script = ''
    export RELEASE_COOKIE
    RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
    exec ${cfg.package}/bin/ziggy start
  '';
  serviceConfig = {
    Type = "exec";
    User = "ziggy";
    Group = "ziggy";
    UMask = "0007";
    LoadCredential = [ "control.token:${cfg.credentialFile}" "openai.key:${cfg.openaiKeyFile}"
      "anthropic.key:${cfg.anthropicKeyFile}" "ca.pem:${cfg.caFile}" ];
    StateDirectory = "ziggy";
    StateDirectoryMode = "0700";
    RuntimeDirectory = "ziggy";
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
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
    RestrictSUIDSGID = true;
    LockPersonality = true;
  };
}
