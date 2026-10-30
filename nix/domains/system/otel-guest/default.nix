{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.overallsOtelGuest;
  receiver = packages.otelReceiver;
in {
  options.services.overallsOtelGuest = {
    enable = lib.mkEnableOption "bounded guest OTLP intake behind Audi";
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.services.audiPrivate.enable && config.services.lilly.enable;
      message = "Guest OTLP intake requires local Audi private services and Lilly binding.";
    }];
    users.groups.overalls-otel-guest = {};
    users.users.overalls-otel-guest = {
      isSystemUser = true;
      group = "overalls-otel-guest";
    };
    systemd.services.overalls-otel-guest = {
      description = "Restricted guest OpenTelemetry intake";
      wantedBy = [ "multi-user.target" ];
      after = [ "opentelemetry-collector.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${receiver}/bin/overalls-otel-guest-receiver /run/overalls-otel-guest/receiver.sock";
        User = "overalls-otel-guest";
        Group = "overalls-otel-guest";
        RuntimeDirectory = "overalls-otel-guest";
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 2;
        MemoryMax = "128M";
        CPUQuota = "50%";
        TasksMax = 64;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictSUIDSGID = true;
      };
    };
  };
}
