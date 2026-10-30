{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.overallsOtelFleet;
  services = import ./durable-services.nix;
  exporter = packages.otelReceiver;
  socketGroup = service: "overalls-otel-${service}";
  socketDirectory = service: "/run/${socketGroup service}";
  producer = "marshall-overalls";
in {
  # @cc [owner:ghuntley,label:security;deployment] durable-service-level-single-source
  # Shared PostgreSQL aggregates MUST have one enrolled Overalls publication
  # instance. Each fixed service MUST use its own group-restricted collector
  # intake and an independent exporter UID. Exporters MUST receive no database,
  # host or provider credentials and MUST NOT write producer snapshots.
  config = lib.mkIf (cfg.enable && cfg.role == "central" &&
    lib.attrByPath [ "services" "marshall" "enable" ] false config) {
    assertions = [{
      assertion = config.services.marshall.enable && builtins.hasAttr "overalls" config.services.marshall.instances;
      message = "Durable lifecycle SLO publication requires the Overalls Marshall instance.";
    }];
    users.groups = lib.genAttrs (map socketGroup services) (_: {});
    users.users = builtins.listToAttrs (map (service: lib.nameValuePair "otel-${service}-exporter" {
      isSystemUser = true;
      group = "overalls-otel-marshall-source";
    }) services);
    services.opentelemetry-collector.settings = {
      receivers = builtins.listToAttrs (map (service: lib.nameValuePair "otlp/${service}" {
        protocols.http = { endpoint = "${socketDirectory service}/collector.sock"; transport = "unix"; max_request_body_size = 4096; };
      }) services);
      processors = builtins.listToAttrs (map (service: lib.nameValuePair "resource/${service}" {
        attributes = [
          { key = "service.name"; value = service; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
          { key = "host.name"; value = cfg.hosts.central; action = "upsert"; }
        ];
      }) services);
      service.pipelines = builtins.listToAttrs (map (service: lib.nameValuePair "metrics/${service}" {
        receivers = [ "otlp/${service}" ];
        processors = [ "memory_limiter" "resource/${service}" "batch" ];
        exporters = [ "prometheus" ];
      }) services);
    };
    systemd.services = lib.mkMerge [ {
      opentelemetry-collector = {
        serviceConfig.RuntimeDirectory = map socketGroup services;
        serviceConfig.SupplementaryGroups = map socketGroup services;
        postStart = lib.mkBefore (lib.concatMapStringsSep "\n" (service: ''
          for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
            if test -S ${socketDirectory service}/collector.sock; then break; fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          test -S ${socketDirectory service}/collector.sock
          ${pkgs.coreutils}/bin/chgrp ${socketGroup service} ${socketDirectory service} ${socketDirectory service}/collector.sock
          ${pkgs.coreutils}/bin/chmod 0750 ${socketDirectory service}
          ${pkgs.coreutils}/bin/chmod 0660 ${socketDirectory service}/collector.sock
        '') services);
      };
    } (builtins.listToAttrs (map (service: lib.nameValuePair "${producer}-${service}-exporter" {
      description = "Export durable ${service} reliability measurements";
      wantedBy = [ "multi-user.target" ];
      after = [ "${producer}.service" "opentelemetry-collector.service" ];
      requires = [ "${producer}.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${exporter}/bin/slo_exporter ${service} /run/marshall-slo-overalls/${service}.json ${socketDirectory service}/collector.sock overalls";
        User = "otel-${service}-exporter";
        Group = "overalls-otel-marshall-source";
        SupplementaryGroups = [ (socketGroup service) ];
        Restart = "always"; RestartSec = 5;
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
        PrivateTmp = true; PrivateDevices = true; ProtectProc = "invisible";
        ProcSubset = "pid"; RestrictAddressFamilies = [ "AF_UNIX" ];
        InaccessiblePaths = [ "-/run/marshall-overalls" "-/var/lib/marshall" ];
        MemoryMax = "64M"; CPUQuota = "10%"; TasksMax = 8;
      };
    }) services)) ];
  };
}
