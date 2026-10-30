{ config, lib, pkgs, ... }:
let
  cfg = config.services.overallsOtelFleet;
  address = config.overalls.fleetNetwork.address;
  central = cfg.role == "central";
  hosts = cfg.roster;
  cadence = import ./cadence.nix;
  loggingEnabled = lib.attrByPath [ "services" "overallsLogging" "enable" ] false config;
  logsEnabled = lib.attrByPath [ "services" "overallsLogStore" "enable" ] false config;
  fleetExporterEnabled = lib.attrByPath [ "services" "overallsFleetExporter" "enable" ] false config;
  candidateQuery = import ./candidate-query.nix { inherit hosts; };
  deploymentRevision = import ./deployment-revision.nix { inherit config lib; };
  latencySources = import ./candidate-sources.nix;
  sloCatalog = import ./slo-catalog.nix { inherit hosts; };
  underclassReady = import ./underclass-ready.nix { inherit hosts; };
  rules = pkgs.writeText "overalls-otel-baseline-rules.yml" (builtins.toJSON {
    groups = (import ./rules.nix { inherit hosts; }).groups ++ (import ./objective-rules.nix { inherit hosts; }).groups
      ++ (import ./diagnostics.nix { inherit hosts; }).groups ++ (import ./infrastructure-rules.nix {
        inherit hosts loggingEnabled fleetExporterEnabled;
      }).groups ++ (import ./storage.nix {
        inherit config lib pkgs;
      }).rules;
  });
  dashboard = pkgs.writeText "overalls-otel-baseline.json" (builtins.toJSON {
    uid = "overalls-otel-baseline";
    title = "Overalls fleet telemetry baseline";
    tags = [ "overalls" "baseline" ];
    schemaVersion = 41;
    version = 1;
    refresh = "30s";
    time = { from = "now-${toString cfg.metricsRetentionDays}d"; to = "now"; };
    panels = builtins.map (panel: panel // {
      maxDataPoints = 2000;
      description = "Unavailable values remain unknown. See the source status and evidence tables above. Retention is 90 days; this panel's calculation window is stated in its title.";
      gridPos = panel.gridPos // { y = panel.gridPos.y + 28; };
    }) ([
      { id = 1; title = "Collector availability, 1 hour"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 0; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = ''overalls:telemetry_collector_up:ratio1h{overalls_telemetry_origin=""}''; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 2; title = "Public ingress completed without server error, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 8; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = ''overalls:web_ingress_completion:ratio5m and on() (${import ./ingress-ready.nix})''; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 3; title = "Brady candidate admitted request completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 16; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "brady" "overalls:brady_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 4; title = "Galileo candidate authorized integration completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 24; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "galileo" "overalls:galileo_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 5; title = "Enrico candidate mirror refresh completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 32; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "enrico" "overalls:enrico_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 6; title = "Porsche candidate SSH command dispatch completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 40; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "porsche" "overalls:porsche_candidate_dispatch:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 7; title = "Ziggy candidate inference completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 48; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "ziggy" "overalls:ziggy_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 8; title = "Audi candidate bound private request completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 56; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "audi_private" "overalls:audi_private_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 9; title = "Audi DNS candidate authoritative answer completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 64; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "audi_dns" "overalls:audi_dns_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 10; title = "Marshall candidate browser HTTP completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 72; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "marshall_web" "overalls:marshall_web_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 11; title = "Audi candidate guest SSH establishment, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 80; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "audi_ssh" "overalls:audi_ssh_candidate_establishment:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
      { id = 12; title = "Underclass durable proxy completion, 5 minutes"; type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 88; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery "underclass_proxy" "overalls:underclass_proxy_candidate_completion:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }
    ] ++ builtins.genList (index:
      let source = builtins.elemAt (builtins.filter (source: builtins.elem source.service (import ./durable-services.nix)) latencySources) index; in {
        id = 13 + index;
        title = "${source.title}, 5 minutes";
        type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 96 + index * 8; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{ refId = "A"; expr = candidateQuery source.service "overalls:${source.ratio}:ratio5m"; }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }) (builtins.length (import ./durable-services.nix)) ++ builtins.genList (index:
      let source = builtins.elemAt latencySources index; in {
        id = 13 + builtins.length (import ./durable-services.nix) + index;
        title = "${source.title} candidate p95 observed duration, 5 minutes";
        type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 96 + (builtins.length (import ./durable-services.nix) + index) * 8; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{
          refId = "A";
          expr = candidateQuery source.service "overalls:${source.service}_candidate_duration:p95_5m";
        }];
        fieldConfig.defaults = { unit = "s"; min = 0; };
      }) (builtins.length latencySources) ++ [{
        id = 13 + builtins.length (import ./durable-services.nix) + builtins.length latencySources;
        title = "Underclass local monitor readiness candidate, 5 minutes";
        type = "timeseries";
        gridPos = { h = 8; w = 24; x = 0; y = 96 + (builtins.length (import ./durable-services.nix) + builtins.length latencySources) * 8; };
        datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
        targets = [{
          refId = "A";
          expr = ''overalls:underclass_monitor_local_readiness:ratio5m and on() (${underclassReady})'';
        }];
        fieldConfig.defaults = { unit = "percentunit"; min = 0; max = 1; };
      }] ++ builtins.genList (index:
        let slo = builtins.elemAt sloCatalog index; in {
          id = 14 + builtins.length (import ./durable-services.nix) + builtins.length latencySources + index;
          title = "${slo.title}, provisional seven-day objective (target ${toString (slo.target * 100)}%)";
          type = "timeseries";
          gridPos = { h = 8; w = 24; x = 0; y = 104 + (builtins.length (import ./durable-services.nix) + builtins.length latencySources + index) * 8; };
          datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
          targets = [{ refId = "A"; expr = slo.objective_query; }];
          fieldConfig.defaults = {
            unit = "percentunit"; min = 0; max = 1;
            thresholds = { mode = "absolute"; steps = [
              { color = "red"; value = null; }
              { color = "green"; value = slo.target; }
            ]; };
          };
        }) (builtins.length sloCatalog)) ++ (import ./diagnostic-panels.nix { inherit hosts; });
  });
in {
  imports = [ ../logging/default.nix ./trace-spool.nix ./public-grafana.nix ./grafana-logs.nix ./burn-delivery.nix ./service-levels.nix ./request-recorder.nix ./request-sources.nix ./browser-probes.nix
    (import ./storage.nix { inherit config lib pkgs; }).module ];
  options.services.overallsOtelFleet = {
    metricsRetentionDays = lib.mkOption {
      type = lib.types.ints.between 7 365;
      default = 90;
      description = "Prometheus time retention in days; distinct from the seven-day SLO window.";
    };
    tracesRetentionDays = lib.mkOption {
      type = lib.types.ints.between 7 365;
      default = 90;
      description = "Tempo trace retention in days, subject to its monitored storage quota.";
    };
    enable = lib.mkEnableOption "bounded fleet OpenTelemetry collection";
    role = lib.mkOption {
      type = lib.types.enum [ "central" "worker" ];
      description = "Central metrics/traces/Grafana store or worker collector.";
    };
    hosts = {
      central = lib.mkOption {
        type = lib.types.strMatching "[a-z][a-z0-9-]*";
        # No default: each deployment names its own hosts (nix/policy/fleet/hosts.nix).
        description = "Host name of this deployment's central telemetry host (fleet address 10.90.0.1).";
      };
      worker = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[a-z][a-z0-9-]*");
        description = "Host name of this deployment's worker telemetry host (fleet address 10.90.0.2), or null for a single-host deployment. Required, like central.";
      };
    };
    roster = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = [ cfg.hosts.central ] ++ lib.optional (cfg.hosts.worker != null) cfg.hosts.worker;
      description = "Telemetry roster derived from hosts: the central host first, then the worker.";
    };
    tempoDataset = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional ZFS dataset mounted at /var/lib/tempo with a hard refquota.";
    };
    tempoQuotaGiB = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 20;
    };
  };

  # @cc [owner:ghuntley,label:security;capacity] fleet-otel-separated-trust
  # Only host-owned infrastructure receivers receive the host origin.
  # Application intake MUST retain its fixed application identity. Guest OTLP
  # retains guest origin and namespace, which SLO rules MUST NOT consume.
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = config.overalls.fleetNetwork.enable;
        message = "Fleet OpenTelemetry requires authenticated fleet WireGuard."; }
      { assertion = !central || address == "10.90.0.1";
        message = "Central OpenTelemetry storage belongs on the deployment's 10.90.0.1 host."; }
      { assertion = central || address == "10.90.0.2";
        message = "Worker OpenTelemetry collection belongs on the deployment's 10.90.0.2 host."; }
      { assertion = cfg.hosts.worker != cfg.hosts.central;
        message = "Fleet telemetry roster hosts must be distinct."; }
      { assertion = central || cfg.hosts.worker != null;
        message = "A worker collector requires a worker in the deployment's telemetry roster."; }
      { assertion = cfg.tempoDataset == null || (central && builtins.match "[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+" cfg.tempoDataset != null);
        message = "Tempo dataset must be a central host ZFS dataset."; }
      # @cc [owner:ghuntley,label:security;reliability] collector-socket-custody
      # Every per-source collector socket directory MUST keep its source group
      # once the collector is started. systemd re-applies RuntimeDirectory
      # ownership (collector user and group) each time it spawns an exec
      # command, so all socket regrouping MUST happen in the one postStart
      # ExecStartPost; a second ExecStartPost would undo it.
      { assertion = lib.length (lib.toList (config.systemd.services.opentelemetry-collector.serviceConfig.ExecStartPost or [])) == 1;
        message = "Collector socket custody must run as the collector's only ExecStartPost (extend postStart instead)."; }
    ];
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      # @cc [owner:ghuntley,label:recovery] collector-trace-persistent-custody
      # Both bounded trace queues MUST fsync storage writes and retain unlimited
      # elapsed retry. Neither trace pipeline may acknowledge through an
      # asynchronous batch processor before its separate persistent queue.
      settings = {
        extensions."file_storage/traces" = {
          directory = "/var/lib/opentelemetry-collector/traces-queue";
          create_directory = true;
          fsync = true;
          compaction = { on_start = true; directory = "/var/lib/opentelemetry-collector/traces-compact"; };
        };
        extensions."file_storage/application-traces" = {
          directory = "/var/lib/opentelemetry-collector/application-traces-queue";
          create_directory = true;
          fsync = true;
          compaction = { on_start = true; directory = "/var/lib/opentelemetry-collector/application-traces-compact"; };
        };
        receivers = {
          otlp.protocols.http.endpoint = "127.0.0.1:4318";
          "otlp/application".protocols.http = {
            endpoint = "/run/overalls-otel-app/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-galileo".protocols.http = {
            endpoint = "/run/overalls-otel-galileo/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-enrico".protocols.http = {
            endpoint = "/run/overalls-otel-enrico/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-porsche".protocols.http = {
            endpoint = "/run/overalls-otel-porsche/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-ziggy".protocols.http = {
            endpoint = "/run/overalls-otel-ziggy/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-audi-private".protocols.http = {
            endpoint = "/run/overalls-otel-audi-private/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-audi-dns".protocols.http = {
            endpoint = "/run/overalls-otel-audi-dns/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-marshall".protocols.http = {
            endpoint = "/run/overalls-otel-marshall/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-marshall-live".protocols.http = {
            endpoint = "/run/overalls-otel-marshall-live/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-audi-ssh".protocols.http = {
            endpoint = "/run/overalls-otel-audi-ssh/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-underclass".protocols.http = {
            endpoint = "/run/overalls-otel-underclass/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-underclass-proxy".protocols.http = {
            endpoint = "/run/overalls-otel-underclass-proxy/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-traces".protocols.http = {
            endpoint = "/run/overalls-otel-traces/collector.sock";
            transport = "unix";
            max_request_body_size = 262144;
          };
          hostmetrics = {
            collection_interval = "30s";
            scrapers = { cpu = {}; memory = {}; load = {}; filesystem = {}; disk = {}; network = {}; };
          };
          # @cc [owner:ghuntley,label:observability] deployment-info-series
          # The deployed revision MUST reach Prometheus as one separate
          # overalls_deployment_info series per host and MUST NOT label any other
          # series, so roster and exact-count rules keep their series identity.
          "hostmetrics/deployment" = {
            collection_interval = "60s";
            scrapers.system = {};
          };
          "prometheus/collector-health".config.scrape_configs = [{
            job_name = "otel-local";
            scrape_interval = "30s";
            static_configs = [{ targets = [ "127.0.0.1:8888" ]; }];
            metric_relabel_configs = [{
              source_labels = [ "__name__" ];
              regex = "otelcol_(exporter_send_failed|receiver_refused)_(metric_points|spans)(_total)?";
              action = "keep";
            }];
          }];
        } // lib.optionalAttrs loggingEnabled {
          # @cc [owner:ghuntley,label:security] sdk-health-host-receiver
          # SDK health MUST enter only from the local numeric exporter and its
          # closed metric names; host pipeline provenance MUST override origin.
          "prometheus/sdk-health".config.scrape_configs = [{
            job_name = "overalls-sdk-health";
            scrape_interval = "30s";
            static_configs = [{ targets = [ "127.0.0.1:${toString config.services.overallsLogging.sdkMetricsPort}" ]; }];
            metric_relabel_configs = [{
              source_labels = [ "__name__" ];
              regex = "overalls_gauge_(trace_(available|pending|queue_dropped|export_failed|observed_at_seconds)|runtime_observed_at_seconds|beam_(memory_bytes|processes|atoms|run_queue)|terminal_(host_streams|viewer_sockets|peer_sockets|authority_(count|duration_ms|errors)|input_(count|duration_ms|errors))|database(_queue)?_(count|duration_ms|errors)|live_(overview|machines|machine_new|machine)_(count|duration_ms|queries)|liveview_(mount|params|event|info)_(count|duration_ms|queries))";
              action = "keep";
            }];
          }];
        } // lib.optionalAttrs fleetExporterEnabled {
          "prometheus/fleet".config.scrape_configs = [{
            job_name = "overalls-fleet"; scrape_interval = "30s";
            static_configs = [{ targets = [ "127.0.0.1:9466" ]; }];
          }];
        } // lib.optionalAttrs central {
          "prometheus/haproxy".config.scrape_configs = [{
            job_name = "haproxy-local";
            scrape_interval = "15s";
            static_configs = [{ targets = [ "127.0.0.1:8405" ]; }];
          }];
        };
        processors = {
          memory_limiter = { check_interval = "1s"; limit_mib = 256; spike_limit_mib = 64; };
          batch = { timeout = "5s"; send_batch_size = 512; send_batch_max_size = 1024; };
          "resource/host".attributes = [
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "host"; action = "upsert"; }
          ];
          "resource/deployment".attributes = [
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "host"; action = "upsert"; }
            { key = "overalls.deployment.revision"; value = deploymentRevision; action = "upsert"; }
          ];
          # Guest spans name their own build; this records the host deployment
          # that received them, under its own key so guests cannot claim it.
          "resource/guest-traces".attributes = [
            { key = "overalls.host.deployment.revision"; value = deploymentRevision; action = "upsert"; }
          ];
          "filter/deployment".metrics.include = {
            match_type = "strict";
            metric_names = [ "system.uptime" ];
          };
          "metricstransform/deployment".transforms = [{
            include = "system.uptime";
            action = "update";
            new_name = "overalls.deployment.info";
          }];
          "resource/application".attributes = [
            { key = "service.name"; value = "brady"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-galileo".attributes = [
            { key = "service.name"; value = "galileo"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-enrico".attributes = [
            { key = "service.name"; value = "enrico"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-porsche".attributes = [
            { key = "service.name"; value = "porsche"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-ziggy".attributes = [
            { key = "service.name"; value = "ziggy"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-audi-private".attributes = [
            { key = "service.name"; value = "audi_private"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-audi-dns".attributes = [
            { key = "service.name"; value = "audi_dns"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-marshall".attributes = [
            { key = "service.name"; value = "marshall_web"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-marshall-live".attributes = [
            { key = "service.name"; value = "marshall_live"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-audi-ssh".attributes = [
            { key = "service.name"; value = "audi_ssh"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-underclass".attributes = [
            { key = "service.name"; value = "underclass_monitor"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
          "resource/application-underclass-proxy".attributes = [
            { key = "service.name"; value = "underclass_proxy"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          ];
        };
        exporters = {
          prometheus = {
            endpoint = "${address}:9464";
            resource_to_telemetry_conversion.enabled = true;
          };
          "otlp/tempo" = {
            endpoint = "10.90.0.1:4317";
            tls.insecure = true;
            sending_queue = {
              enabled = true;
              storage = "file_storage/traces";
              queue_size = 64;
            };
            retry_on_failure = { enabled = true; max_elapsed_time = "0s"; };
          };
          "otlp/tempo-application" = {
            endpoint = "10.90.0.1:4317";
            tls.insecure = true;
            sending_queue = {
              enabled = true;
              storage = "file_storage/application-traces";
              queue_size = 64;
            };
            retry_on_failure = { enabled = true; max_elapsed_time = "0s"; };
          };
        };
        service = {
          extensions = [ "file_storage/traces" "file_storage/application-traces" ];
          pipelines = {
            "metrics/host" = {
              receivers = [ "hostmetrics" "prometheus/collector-health" ]
                ++ lib.optional loggingEnabled "prometheus/sdk-health"
                ++ lib.optional central "prometheus/haproxy" ++ lib.optional fleetExporterEnabled "prometheus/fleet";
              processors = [ "memory_limiter" "resource/host" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/deployment" = {
              receivers = [ "hostmetrics/deployment" ];
              processors = [ "memory_limiter" "filter/deployment" "metricstransform/deployment" "resource/deployment" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/guest" = {
              receivers = [ "otlp" ];
              processors = [ "memory_limiter" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application" = {
              receivers = [ "otlp/application" ];
              processors = [ "memory_limiter" "resource/application" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-galileo" = {
              receivers = [ "otlp/application-galileo" ];
              processors = [ "memory_limiter" "resource/application-galileo" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-enrico" = {
              receivers = [ "otlp/application-enrico" ];
              processors = [ "memory_limiter" "resource/application-enrico" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-porsche" = {
              receivers = [ "otlp/application-porsche" ];
              processors = [ "memory_limiter" "resource/application-porsche" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-ziggy" = {
              receivers = [ "otlp/application-ziggy" ];
              processors = [ "memory_limiter" "resource/application-ziggy" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-audi-private" = {
              receivers = [ "otlp/application-audi-private" ];
              processors = [ "memory_limiter" "resource/application-audi-private" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-audi-dns" = {
              receivers = [ "otlp/application-audi-dns" ];
              processors = [ "memory_limiter" "resource/application-audi-dns" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-marshall" = {
              receivers = [ "otlp/application-marshall" ];
              processors = [ "memory_limiter" "resource/application-marshall" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-marshall-live" = {
              receivers = [ "otlp/application-marshall-live" ];
              processors = [ "memory_limiter" "resource/application-marshall-live" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-audi-ssh" = {
              receivers = [ "otlp/application-audi-ssh" ];
              processors = [ "memory_limiter" "resource/application-audi-ssh" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-underclass" = {
              receivers = [ "otlp/application-underclass" ];
              processors = [ "memory_limiter" "resource/application-underclass" "batch" ];
              exporters = [ "prometheus" ];
            };
            "metrics/application-underclass-proxy" = {
              receivers = [ "otlp/application-underclass-proxy" ];
              processors = [ "memory_limiter" "resource/application-underclass-proxy" "batch" ];
              exporters = [ "prometheus" ];
            };
            traces = {
              receivers = [ "otlp" ];
              processors = [ "memory_limiter" "resource/guest-traces" ];
              exporters = [ "otlp/tempo" ];
            };
            # @cc [owner:ghuntley,label:recovery] application-trace-durable-ack
            # Application trace intake MUST acknowledge only after fsynced persistent
            # exporter queue custody, with unlimited retry and a separate guest
            # queue. An asynchronous batch MUST NOT precede this custody boundary.
            "traces/application" = {
              receivers = [ "otlp/application-traces" ];
              # ACK follows persistent queue custody. An asynchronous batch here
              # would acknowledge before storage and lose accepted spans on crash.
              processors = [ "memory_limiter" ];
              exporters = [ "otlp/tempo-application" ];
            };
          };
        };
      };
    };
    users.groups.overalls-otel-app = {};
    users.groups.overalls-otel-traces = {};
    users.groups.overalls-otel-galileo = {};
    users.groups.overalls-otel-enrico = {};
    users.groups.overalls-otel-porsche = {};
    users.groups.overalls-otel-ziggy = {};
    users.groups.overalls-otel-audi-private = {};
    users.groups.overalls-otel-audi-dns = {};
    users.groups.overalls-otel-marshall = {};
    users.groups.overalls-otel-marshall-live = {};
    users.groups.overalls-otel-marshall-source = {};
    users.groups.overalls-otel-audi-ssh = {};
    users.groups.overalls-otel-underclass = {};
    users.groups.overalls-otel-underclass-proxy = {};
    users.users.overalls-otel-underclass-probe = {
      isSystemUser = true;
      group = "overalls-otel-underclass";
    };
    users.users.overalls-otel-marshall-exporter = {
      isSystemUser = true;
      group = "overalls-otel-marshall-source";
    };
    systemd.services.opentelemetry-collector = {
      after = [ "wireguard-fleet0.service" ];
      requires = [ "wireguard-fleet0.service" ];
      serviceConfig = {
        Group = "overalls-otel-app";
        SupplementaryGroups = [ "overalls-otel-traces" "overalls-otel-galileo" "overalls-otel-enrico" "overalls-otel-porsche" "overalls-otel-ziggy" "overalls-otel-audi-private" "overalls-otel-audi-dns" "overalls-otel-marshall" "overalls-otel-marshall-live" "overalls-otel-audi-ssh" "overalls-otel-underclass" "overalls-otel-underclass-proxy" ];
        RuntimeDirectory = [ "overalls-otel-traces" "overalls-otel-app" "overalls-otel-galileo" "overalls-otel-enrico" "overalls-otel-porsche" "overalls-otel-ziggy" "overalls-otel-audi-private" "overalls-otel-audi-dns" "overalls-otel-marshall" "overalls-otel-marshall-live" "overalls-otel-audi-ssh" "overalls-otel-underclass" "overalls-otel-underclass-proxy" ];
        RuntimeDirectoryMode = "0750";
        StateDirectoryMode = "0700";
        UMask = "0007";
        MemoryMax = "384M";
        CPUQuota = "100%";
        TasksMax = 128;
      };
      postStart = ''
        for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
          if test -S /run/overalls-otel-traces/collector.sock && test -S /run/overalls-otel-galileo/collector.sock && test -S /run/overalls-otel-enrico/collector.sock && test -S /run/overalls-otel-porsche/collector.sock && test -S /run/overalls-otel-ziggy/collector.sock && test -S /run/overalls-otel-audi-private/collector.sock && test -S /run/overalls-otel-audi-dns/collector.sock && test -S /run/overalls-otel-marshall/collector.sock && test -S /run/overalls-otel-marshall-live/collector.sock && test -S /run/overalls-otel-audi-ssh/collector.sock && test -S /run/overalls-otel-underclass/collector.sock && test -S /run/overalls-otel-underclass-proxy/collector.sock; then
            ${pkgs.coreutils}/bin/chgrp overalls-otel-traces /run/overalls-otel-traces /run/overalls-otel-traces/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-traces
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-traces/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-galileo /run/overalls-otel-galileo /run/overalls-otel-galileo/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-galileo
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-galileo/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-enrico /run/overalls-otel-enrico /run/overalls-otel-enrico/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-enrico
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-enrico/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-porsche /run/overalls-otel-porsche /run/overalls-otel-porsche/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-porsche
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-porsche/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-ziggy /run/overalls-otel-ziggy /run/overalls-otel-ziggy/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-ziggy
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-ziggy/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-audi-private /run/overalls-otel-audi-private /run/overalls-otel-audi-private/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-audi-private
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-audi-private/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-audi-dns /run/overalls-otel-audi-dns /run/overalls-otel-audi-dns/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-audi-dns
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-audi-dns/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-marshall /run/overalls-otel-marshall /run/overalls-otel-marshall/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-marshall
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-marshall/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-marshall-live /run/overalls-otel-marshall-live /run/overalls-otel-marshall-live/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-marshall-live
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-marshall-live/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-audi-ssh /run/overalls-otel-audi-ssh /run/overalls-otel-audi-ssh/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-audi-ssh
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-audi-ssh/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-underclass /run/overalls-otel-underclass /run/overalls-otel-underclass/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-underclass
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-underclass/collector.sock
            ${pkgs.coreutils}/bin/chgrp overalls-otel-underclass-proxy /run/overalls-otel-underclass-proxy /run/overalls-otel-underclass-proxy/collector.sock
            ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-underclass-proxy
            ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-underclass-proxy/collector.sock
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        exit 1
      '';
    };
    services.overallsOtelGuest.enable = true;

    services.tempo = lib.mkIf central {
      enable = true;
      settings = {
        server = { http_listen_address = "127.0.0.1"; http_listen_port = 3200; };
        distributor.receivers.otlp.protocols.grpc.endpoint = "10.90.0.1:4317";
        ingester = { max_block_duration = "5m"; };
        compactor.compaction.block_retention = "${toString (cfg.tracesRetentionDays * 24)}h";
        storage.trace = {
          backend = "local";
          local.path = "/var/lib/tempo/traces";
          wal.path = "/var/lib/tempo/wal";
        };
      };
    };
    users.groups.tempo = lib.mkIf (central && cfg.tempoDataset != null) {};
    users.users.tempo = lib.mkIf (central && cfg.tempoDataset != null) {
      isSystemUser = true;
      group = "tempo";
    };
    systemd.services.otel-tempo-data = lib.mkIf (central && cfg.tempoDataset != null) {
      description = "Prepare quota-bound Tempo trace dataset";
      wantedBy = [ "tempo.service" ];
      before = [ "tempo.service" ];
      after = [ "zfs-mount.service" ];
      requires = [ "zfs-mount.service" ];
      path = [ config.boot.zfs.package pkgs.coreutils ];
      script = ''
        if ! zfs list -H ${lib.escapeShellArg cfg.tempoDataset} >/dev/null 2>&1; then
          zfs create -o mountpoint=/var/lib/tempo -o refquota=${toString cfg.tempoQuotaGiB}G ${lib.escapeShellArg cfg.tempoDataset}
        fi
        test "$(zfs get -H -o value mountpoint ${lib.escapeShellArg cfg.tempoDataset})" = /var/lib/tempo
        zfs set refquota=${toString cfg.tempoQuotaGiB}G ${lib.escapeShellArg cfg.tempoDataset}
        zfs mount ${lib.escapeShellArg cfg.tempoDataset} || true
        test "$(zfs get -H -o value mounted ${lib.escapeShellArg cfg.tempoDataset})" = yes
        chown tempo:tempo /var/lib/tempo
        chmod 0700 /var/lib/tempo
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    };
    systemd.services.tempo = lib.mkIf central {
      after = [ "wireguard-fleet0.service" ] ++ lib.optional (cfg.tempoDataset != null) "otel-tempo-data.service";
      requires = [ "wireguard-fleet0.service" ] ++ lib.optional (cfg.tempoDataset != null) "otel-tempo-data.service";
      serviceConfig = { MemoryMax = "1024M"; CPUQuota = "100%"; }
        // lib.optionalAttrs (cfg.tempoDataset != null) {
          DynamicUser = lib.mkForce false;
          User = "tempo";
          Group = "tempo";
        };
    };
    services.prometheus = lib.mkIf central {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      retentionTime = "${toString cfg.metricsRetentionDays}d";
      extraFlags = [];
      ruleFiles = [ rules ];
      scrapeConfigs = [{
        job_name = "overalls-telemetry-storage";
        scrape_interval = "60s";
        static_configs = [{ targets = [ "127.0.0.1:9465" ]; }];
      } {
        job_name = "overalls-otel";
        scrape_interval = "${toString cadence.scrapeSeconds}s";
        static_configs = [{ targets = map (address: "${address}:9464") (import ./roster-addresses.nix hosts); }];
      } {
        job_name = "overalls-ingress-source";
        scrape_interval = "30s";
        static_configs = [{ targets = [ "127.0.0.1:8405" ]; }];
        # Keep scrape-generated health only; SLIs continue through OTLP.
        metric_relabel_configs = [{ source_labels = [ "__name__" ]; regex = ".*"; action = "drop"; }];
      }] ++ lib.optional loggingEnabled {
        job_name = "overalls-logging-health";
        scrape_interval = "30s";
        static_configs = lib.zipListsWith (host: address: {
          targets = [ "${address}:9467" ]; labels.host_name = host;
        }) hosts (import ./roster-addresses.nix hosts);
      };
    };
    systemd.services.prometheus = lib.mkIf central {
      serviceConfig = { MemoryMax = "2048M"; CPUQuota = "150%"; };
    };
    services.grafana = lib.mkIf central {
      enable = true;
      settings = {
        server = { http_addr = "127.0.0.1"; http_port = 3000; };
        security = {
          admin_user = "operator";
          admin_password = "$__file{/var/lib/grafana/admin-password}";
          secret_key = "$__file{/var/lib/grafana/secret-key}";
          disable_gravatar = true;
        };
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
      };
      provision.datasources.settings = {
        apiVersion = 1;
        datasources = [
          { name = "Prometheus"; uid = "overalls-prometheus"; type = "prometheus";
            access = "proxy"; url = "http://127.0.0.1:9090"; isDefault = true; }
          { name = "Tempo"; uid = "overalls-tempo"; type = "tempo";
            access = "proxy"; url = "http://127.0.0.1:3200";
            jsonData = lib.optionalAttrs logsEnabled {
              tracesToLogsV2 = {
                datasourceUid = "overalls-victorialogs";
                spanStartTimeShift = "-1m"; spanEndTimeShift = "1m";
                customQuery = true; query = "trace_id:\"$\${__span.traceId}\"";
              };
            };
          }
        ];
      };
      provision.dashboards.settings.providers = [{
        name = "Overalls";
        options.path = pkgs.linkFarm "overalls-grafana-dashboards" ([
          { name = "baseline.json"; path = dashboard; }
          { name = "operations.json"; path = pkgs.writeText "overalls-operations.json" (builtins.toJSON (import ./operations-dashboard.nix)); }
          { name = "marshall-pages.json"; path = pkgs.writeText "overalls-marshall-pages.json" (builtins.toJSON (import ./marshall-pages-dashboard.nix { inherit hosts; })); }
        ] ++ lib.optional logsEnabled {
          name = "logs.json"; path = pkgs.writeText "overalls-logs.json" (builtins.toJSON (import ./logs-dashboard.nix));
        });
      }];
    };
    systemd.services.grafana = lib.mkIf central {
      preStart = ''
        if [ ! -s /var/lib/grafana/admin-password ]; then
          umask 077
          ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base64 -w0 > /var/lib/grafana/admin-password
        fi
        if [ ! -s /var/lib/grafana/secret-key ]; then
          umask 077
          ${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base64 -w0 > /var/lib/grafana/secret-key
        fi
      '';
      serviceConfig = { MemoryMax = "1024M"; CPUQuota = "100%"; };
    };
    services.overallsLogging.healthAddress = lib.mkIf loggingEnabled address;
  };
}
