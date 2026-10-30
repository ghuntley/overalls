{ config, lib, pkgs, packages }:
let
  cfg = config.services.overallsOtelFleet;
  package = packages.otelReceiver;
  metric = store: ''overalls_telemetry_storage_used_bytes{job="overalls-telemetry-storage",store="${store}"}'';
  used = metric "traces";
  limit = cfg.tempoQuotaGiB * 1024 * 1024 * 1024;
  alert = name: severity: expr: {
    alert = name; inherit expr;
    "for" = "10m";
    labels = { inherit severity; };
    annotations.summary = "Telemetry storage capacity threatens configured retention";
  };
in {
  # @cc [owner:ghuntley,label:security;capacity] telemetry-storage-custody
  # The probe MUST expose only loopback aggregate metrics, retain read-only
  # telemetry access and receive no application credentials. Capacity failures
  # MUST be alerted separately from SLO compliance.
  module = { systemd.services.overalls-telemetry-storage = lib.mkIf (cfg.enable && cfg.role == "central") {
    description = "Bounded telemetry storage capacity diagnostics";
    wantedBy = [ "multi-user.target" ];
    after = [ "prometheus.service" "tempo.service" ];
    wants = [ "prometheus.service" "tempo.service" ];
    serviceConfig = {
      ExecStart = "${package}/bin/storage_probe ${pkgs.coreutils}/bin/du";
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      TemporaryFileSystem = [ "/var/lib:ro" "/run:ro" "/etc:ro" ];
      BindReadOnlyPaths = [ "/var/lib/prometheus2" "/var/lib/tempo" ];
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictNamespaces = true;
      InaccessiblePaths = [ "-/run/overalls-secrets" "-/var/lib/overalls-secrets" ];
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
      MemoryMax = "64M";
      CPUQuota = "10%";
      TasksMax = 8;
    };
  }; };
  rules = [{
    name = "overalls-telemetry-capacity";
    interval = "1m";
    rules = [
      (alert "OverallsMetricsStorageBudget" "warning" ''${metric "metrics"} > 10737418240'')
      (alert "OverallsTraceStorageWarning" "warning" ''${used} > ${toString limit} * 0.70'')
      (alert "OverallsTraceStorageCritical" "critical" ''${used} > ${toString limit} * 0.85'')
      (alert "OverallsTraceRetentionCapacity" "warning"
        ''predict_linear(${used}[6h], ${toString (cfg.tracesRetentionDays * 86400)}) > ${toString limit}'')
      (alert "OverallsTelemetryRootCapacity" "critical" ''overalls_telemetry_root_available_bytes{job="overalls-telemetry-storage"} < 214748364800'')
      (alert "OverallsTelemetryStorageProbeMissing" "warning" ''up{job="overalls-telemetry-storage"} == 0 or absent(up{job="overalls-telemetry-storage"}) or absent(overalls_telemetry_storage_used_bytes{store="metrics"}) or absent(overalls_telemetry_storage_used_bytes{store="traces"}) or absent(overalls_telemetry_root_available_bytes)'')
      (alert "OverallsTelemetryIngestionFailure" "warning"
        ''sum(increase({__name__=~"otelcol_(exporter_send_failed|receiver_refused)_(metric_points|spans)(_total)?",overalls_telemetry_origin="host"}[5m])) > 0'')
    ];
  }];
}
