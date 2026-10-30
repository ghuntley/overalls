{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsFleetExporter;
  observabilityRuntimes = packages.observabilityRuntimes;
  runtime = pkgs.runCommand "overalls-fleet-exporter" {} ''
    mkdir -p $out
    cp ${./runtime.py} $out/runtime.py
    cp ${./exporter.py} $out/exporter.py
    cp ${./metrics.py} $out/metrics.py
    cp ${./backup_status.py} $out/backup_status.py
    cp ${./terminal_metrics.py} $out/terminal_metrics.py
  '';
  descriptor = pkgs.writeText "overalls-fleet-exporter.json" (builtins.toJSON {
    port = cfg.port;
    external_interfaces = cfg.externalInterfaces;
    services = cfg.units;
    backups_enabled = lib.attrByPath [ "services" "overallsBackups" "enable" ] false config;
    inherit (cfg) roles;
    lilly_host_id = if config.services.lilly.enable or false then config.services.lilly.hostId else null;
    ziggy = if config.services.ziggy.enable or false then {
      socket = "/run/ziggy/proxy.sock";
      host_id = config.services.ziggy.hostId;
    } else null;
    galileo = if config.services.galileo.enable or false then {
      socket = "/run/galileo/proxy.sock";
      host_id = config.services.galileo.hostId;
    } else null;
    curl = "${pkgs.curl}/bin/curl";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    ip = "${pkgs.iproute2}/bin/ip";
    zfs = if cfg.zfs then "${pkgs.zfs}/bin/zfs" else null;
    zpool = if cfg.zfs then "${pkgs.zfs}/bin/zpool" else null;
  });
in {
  options.services.overallsFleetExporter = {
    enable = mkEnableOption "independent fleet infrastructure Prometheus exporter";
    port = mkOption { type = types.port; default = 9466; description = "Loopback Prometheus resource exporter; no application credentials or ingestion."; };
    externalInterfaces = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}"); default = []; description = "Interfaces counted as external network traffic; excludes bridges and taps unless explicitly selected."; };
    roles = mkOption {
      type = types.listOf (types.enum [ "marshall" "lilly" "audi" "porsche" "ziggy" "galileo" "enrico" "brady" "underclass" ]);
      default = lib.filter (role: config.services.${role}.enable or false) [ "marshall" "lilly" "audi" "porsche" "ziggy" "galileo" "enrico" "brady" "underclass" ];
    };
    units = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@:-]+\\.service");
      default = lib.concatMap (role:
        if role == "marshall" then map (name: "marshall-${name}.service") (builtins.attrNames (config.services.marshall.instances or {}))
        else if role == "underclass" then [ "underclass.service" "underclass-tailscale-serve.service" ]
        else [ "${role}.service" ]) cfg.roles
        ++ lib.optionals (config.services.audiDns.enable or false) [ "audi-dns.service" ];
      description = "Explicit platform service units; VM units are discovered by bounded systemd metadata.";
    };
    zfs = mkOption { type = types.bool; default = config.services.lilly.enable or false; };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = builtins.length cfg.units <= 128 && builtins.length cfg.externalInterfaces <= 128;
        message = "Fleet monitor service/interface configuration must remain bounded."; }
    ];
    systemd.services.brady = mkIf (config.services.brady.enable or false) {
      environment.BRADY_FLEET_MONITOR = "1";
    };
    systemd.services.overalls-fleet-exporter = {
      description = "Independent fleet infrastructure exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${observabilityRuntimes}/bin/overalls-fleet-exporter ${descriptor}";
        Restart = "always"; RestartSec = 5;
        SupplementaryGroups = lib.optional config.services.ziggy.enable "ziggy-proxy"
          ++ lib.optional config.services.galileo.enable "galileo-proxy";
        User = "root"; UMask = "0077";
        MemoryMax = "256M"; CPUQuota = "25%";
        CPUWeight = 5; IOWeight = 5; TasksMax = 16;
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
        PrivateTmp = true;
        # Read-only network-namespace entry and ZFS inspection require these;
        # guest lifecycle remains exclusively with Lilly's existing services.
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" "CAP_SYS_ADMIN" "CAP_NET_ADMIN" ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_NETLINK" ];
        Environment = [
          "PYTHONDONTWRITEBYTECODE=1"
          "OVERALLS_FLEET_EXPORTER_PYTHON=${pkgs.python3}/bin/python3"
          "OVERALLS_FLEET_EXPORTER_SCRIPT=${runtime}/runtime.py"
        ];
      };
    };
  };
}
