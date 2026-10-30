{ loggingEnabled ? true, fleetExporterEnabled ? true, hosts }:
let
  any = builtins.concatStringsSep " or ";
  addresses = import ./roster-addresses.nix hosts;
  fresh = " and on(host_name,unit) (time() - overalls_gauge_trace_observed_at_seconds >= 0) and on(host_name,unit) (time() - overalls_gauge_trace_observed_at_seconds < 90)";
  alert = name: expr: summary: {
    alert = name; inherit expr;
    "for" = "5m";
    labels = { severity = "warning"; category = "infrastructure"; };
    annotations.summary = summary;
  };
  eventAlert = name: expr: summary: (alert name expr summary) // { "for" = "1m"; };
in {
  groups = [{
    name = "overalls-infrastructure-health"; interval = "30s";
    rules = (if loggingEnabled then [
      (alert "OverallsLoggingHealthMissing"
        ''up{job="overalls-logging-health"} == 0 or ${any (builtins.map (address: ''absent(up{job="overalls-logging-health",instance="${address}:9467"})'') addresses)}''
        "Independent logging health is unavailable")
      (alert "OverallsLoggingCollectorUnavailable"
        ''overalls_logging_collector_metrics_valid == 0 or overalls_logging_output_counters_valid == 0''
        "Logging delivery counters are unavailable")
      (alert "OverallsLoggingFilesystemUnavailable" ''overalls_logging_filesystem_valid == 0''
        "Logging queue or disk observation is unavailable")
      (alert "OverallsLoggingQueueOld" ''overalls_logging_oldest_chunk_seconds > 3600''
        "Logging backlog has not drained for an hour")
      (eventAlert "OverallsLoggingDrop" ''sum by(instance,output) (increase(overalls_logging_output_dropped_records_total[5m])) > 0''
        "A bounded logging destination dropped records")
      (alert "OverallsLoggingDiskLow" ''overalls_logging_free_bytes < 2147483648''
        "Logging disk headroom is below two GiB")
      (alert "OverallsLoggingCursorMissing" ''overalls_logging_shard_cursor_present == 0''
        "An enrolled journal shard lacks a durable cursor")
      (alert "OverallsTraceSpoolUnavailable"
        ''overalls_trace_spool_snapshot_valid == 0 or time() - overalls_trace_spool_sample_time > 45''
        "Independent trace custody health is invalid or stale")
      (alert "OverallsTraceSpoolPoisoned" ''overalls_trace_spool_poisoned == 1''
        "Trace custody stopped acknowledgment after a storage failure")
      (eventAlert "OverallsTraceSpoolRefused" ''increase(overalls_trace_spool_refused_total[5m]) > 0''
        "Independent trace custody refused diagnostics")
      (alert "OverallsTraceSpoolBacklog" ''overalls_trace_spool_oldest_pending_seconds > 3600''
        "Trace diagnostics have remained unacknowledged for an hour")
      (alert "OverallsTraceSpoolCapacity" ''overalls_trace_spool_retained_bytes / overalls_trace_spool_quota_bytes > 0.7''
        "Retained trace custody exceeds seventy percent of its configured budget")
      (alert "OverallsSDKHealthMissing"
        ''label_replace(overalls_trace_spool_snapshot_valid,"unit","$1.service","producer","(.+)") unless on(host_name,unit) overalls_gauge_trace_observed_at_seconds''
        "A configured trace producer has no SDK health observation")
      (alert "OverallsSDKHealthStale"
        ''time() - overalls_gauge_trace_observed_at_seconds > 90 or overalls_gauge_trace_observed_at_seconds - time() > 5''
        "SDK health observations are stale or ahead of the trusted clock")
      (alert "OverallsSDKUnavailable" (''overalls_gauge_trace_available == 0'' + fresh)
        "An application SDK processor is unavailable")
      (alert "OverallsSDKQueuePressure" (''overalls_gauge_trace_pending >= 192'' + fresh)
        "An application volatile trace queue exceeds seventy-five percent of its capacity")
      (eventAlert "OverallsSDKQueueRefused" (''increase(overalls_gauge_trace_queue_dropped[5m]) > 0'' + fresh)
        "An application SDK refused volatile trace admission")
      (eventAlert "OverallsSDKExportFailed" (''increase(overalls_gauge_trace_export_failed[5m]) > 0'' + fresh)
        "An application SDK failed a trace custody handoff")
      (alert "OverallsAgentStuckTurns" ''overalls_gauge_agent_stuck_turns > 0''
        "One or more agent turns have waited for context beyond two minutes")
    ] else []) ++ (if fleetExporterEnabled then [
      (alert "OverallsFleetCollectionMissing"
        ''${any (builtins.map (host: ''absent(overalls_fleet_collection_valid{host_name="${host}"})'') hosts)}''
        "An enrolled fleet infrastructure exporter is unavailable")
      (alert "OverallsFleetCollectionUnavailable" ''overalls_fleet_collection_valid == 0 or time() - overalls_fleet_sampled_at_seconds > 45''
        "Fleet infrastructure observation is invalid or stale")
      (alert "OverallsFleetCollectionPartial" ''overalls_fleet_collection_partial == 1''
        "One or more fleet infrastructure sources are unavailable")
      (alert "OverallsBackupState" ''overalls_fleet_state_info{kind="backup",field="backup_state",state=~"unknown|never-run|degraded|failed|stale"} == 1''
        "Backup health requires operational review")
      (alert "OverallsBackupCleanupPending" ''overalls_fleet_gauge{kind="backup",measure="cleanup_pending"} > 0''
        "Backup cleanup remains pending")
      (alert "OverallsUpdateState" ''overalls_fleet_state_info{kind="updater",field="updater_phase",state="unknown"} == 1 or overalls_fleet_gauge{kind="updater",measure="status_valid"} == 0''
        "Updater phase is unknown")
      (alert "OverallsUpdateFailures" ''overalls_fleet_gauge{kind="updater",measure="failure_present"} == 1''
        "Automatic update reports a bounded failure state")
    ] else []);
  }];
}
