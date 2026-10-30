# @cc [owner:ghuntley,label:verification;security] native-request-source-custody
# Native source fixtures MUST use the production recorder module and explicit
# Rust recorder export selection. Exporters MUST have independent reader
# accounts, without producer RPC or private checkpoint access.
{ pkgs, packages, name, source, producerUser, producerUnit, deadlineSeconds, collectorGroup, collectorEnable ? false }:
{ ... }:
let
  identities = import ../../../domains/system/otel-fleet/request-identities.nix;
  package = packages.otelReceiver;
in {
  imports = [ (import ../../../domains/system/otel-fleet/request-recorder.nix { inherit packages; }) ];
  services.overallsRequestRecorder.instances.${name} = {
    inherit source producerUser producerUnit deadlineSeconds;
  };
  users.users.${identities.exporterUser name} = {
    isSystemUser = true; group = identities.readerGroup name;
  };
  users.groups.${collectorGroup} = {};
  services.opentelemetry-collector = pkgs.lib.mkIf collectorEnable {
    enable = true; package = pkgs.opentelemetry-collector-contrib;
    validateConfigFile = true;
    settings = {
      receivers."otlp/application-${name}".protocols.http = {
        endpoint = "/run/${collectorGroup}/collector.sock";
        transport = "unix"; max_request_body_size = 4096;
      };
      processors."resource/application-${name}".attributes = [
        { key = "service.name"; value = source; action = "upsert"; }
        { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
      ];
      exporters.prometheus = {
        endpoint = "127.0.0.1:9464"; resource_to_telemetry_conversion.enabled = true;
      };
      service.pipelines."metrics/application-${name}" = {
        receivers = [ "otlp/application-${name}" ];
        processors = [ "resource/application-${name}" ]; exporters = [ "prometheus" ];
      };
    };
  };
  systemd.services.opentelemetry-collector = pkgs.lib.mkIf collectorEnable {
    serviceConfig = {
      Group = collectorGroup; RuntimeDirectory = collectorGroup;
      RuntimeDirectoryMode = "0750"; UMask = "0007";
    };
  };
  systemd.services."overalls-request-${name}-exporter" = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "overalls-request-${name}.service" ];
    after = [ "overalls-request-${name}.service" "opentelemetry-collector.service" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = pkgs.lib.escapeShellArgs [ "${package}/bin/slo_exporter"
        "--recorder-group-source" source "/run/overalls-request-${name}-source/slo.json"
        "/run/${collectorGroup}/collector.sock" ];
      User = identities.exporterUser name; Group = identities.readerGroup name;
      SupplementaryGroups = [ collectorGroup ];
      Restart = "always"; RestartSec = 5;
      NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
      PrivateTmp = true; PrivateDevices = true;
      RestrictAddressFamilies = [ "AF_UNIX" ]; CapabilityBoundingSet = [];
    };
  };
}
