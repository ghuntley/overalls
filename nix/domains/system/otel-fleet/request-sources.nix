# @cc [owner:ghuntley,label:security;deployment] request-source-production-custody
# Enabled fleet request sources MUST use independent recorder/exporter accounts
# and exact producer units. Exporters MUST receive only snapshot-reader and
# collector groups, never producer RPC, application identity or checkpoint access.
{ packages }:
{ config, lib, pkgs, ... }:
let
  enabled = application: lib.attrByPath [ "services" application "enable" ] false config;
  package = packages.otelReceiver;
  binding = source: producerUser: producerUnit: deadlineSeconds: collectorGroup: {
    inherit source producerUser producerUnit deadlineSeconds collectorGroup;
    instance = null;
    environmentSuffix = "";
  };
  # Streaming transports have renewable/idle budgets, not a total execution
  # timeout. Their provisional 24-hour measurement horizon does not close work.
  # Porsche permits a 3600-second wait plus bounded request overhead. Enrico
  # permits one 3600-second fetch/clone and bounded 10-second metadata commands.
  # DNS resolution and granted SSH establishment have bounded local/control I/O;
  # their 30-second horizon includes client admission and terminal-report overhead.
  sources = lib.filterAttrs (name: _: enabled name) {
    brady = binding "brady" "brady" "brady.service" 86400 "overalls-otel-app";
    galileo = binding "galileo" "galileo" "galileo.service" 86400 "overalls-otel-galileo";
    enrico = binding "enrico" "enrico" "enrico.service" 3720 "overalls-otel-enrico";
    porsche = binding "porsche" "porsche" "porsche.service" 3660 "overalls-otel-porsche";
  } // lib.optionalAttrs (enabled "audiPrivate") {
    audi-private = binding "audi_private" "audi" "audi-private.service" 86400 "overalls-otel-audi-private";
  } // lib.optionalAttrs (enabled "audiDns") {
    audi-dns = binding "audi_dns" "audi-dns" "audi-dns.service" 30 "overalls-otel-audi-dns";
  } // lib.optionalAttrs (enabled "audi") {
    audi-ssh = binding "audi_ssh" "audi" "audi.service" 30 "overalls-otel-audi-ssh";
  } // lib.optionalAttrs (enabled "marshall") (lib.mapAttrs' (name: _:
    lib.nameValuePair "marshall-${name}" ((binding "marshall_web" "marshall-${name}"
      "marshall-${name}.service" 86400 "overalls-otel-marshall") // {
        instance = name;
      })
  ) config.services.marshall.instances)
  # LiveView callbacks are bounded interactive work; a callback still open
  # after sixty seconds is settled as a failure.
  // lib.optionalAttrs (enabled "marshall") (lib.mapAttrs' (name: _:
    lib.nameValuePair "marshall-live-${name}" ((binding "marshall_live" "marshall-${name}"
      "marshall-${name}.service" 60 "overalls-otel-marshall-live") // {
        instance = name;
        environmentSuffix = "_MARSHALL_LIVE";
      })
  ) config.services.marshall.instances);
  identities = import ./request-identities.nix;
  inherit (identities) readerGroup exporterUser;
in {
  config = lib.mkIf config.services.overallsOtelFleet.enable {
    services.overallsRequestRecorder.instances = lib.mapAttrs (_: source: {
      inherit (source) source producerUser producerUnit deadlineSeconds environmentSuffix;
    }) sources;
    users.users = lib.mapAttrs' (name: _: lib.nameValuePair (exporterUser name) {
      isSystemUser = true;
      group = readerGroup name;
    }) sources;
    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: source: {
      "overalls-request-${name}-exporter" = {
        description = "Export durable ${source.source} request accounting";
        wantedBy = [ "multi-user.target" ];
        wants = [ "overalls-request-${name}.service" ];
        after = [ "overalls-request-${name}.service" "opentelemetry-collector.service" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = lib.escapeShellArgs ([ "${package}/bin/slo_exporter"
            "--recorder-group-source" source.source
            "/run/overalls-request-${name}-source/slo.json"
            "/run/${source.collectorGroup}/collector.sock"
          ] ++ lib.optional (source.instance != null) source.instance);
          User = exporterUser name;
          Group = readerGroup name;
          SupplementaryGroups = [ source.collectorGroup ];
          Restart = "always"; RestartSec = 5;
          NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
          PrivateTmp = true; PrivateDevices = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          CapabilityBoundingSet = []; MemoryMax = "64M"; CPUQuota = "10%"; TasksMax = 8;
        };
      };
    }) sources);
  };
}
