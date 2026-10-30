{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsLogging;
  observabilityRuntimes = packages.observabilityRuntimes;
  fleetEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  paths = import ../types.nix { inherit lib; };
  sources = [ "marshall" "lilly" "porsche" "audi" "ziggy" "enrico" "brady" "galileo" "underclass" "haproxy" "audit" "firecracker" "auth" "kernel" "storage" "mail" "operations" "system" "metrics" ];
  traceHealthNames = [ "trace_available" "trace_pending" "trace_queue_dropped" "trace_export_failed" "trace_observed_at_seconds" ];
  metricNames = [ "beam_memory_bytes" "beam_processes" "beam_atoms" "beam_run_queue" "agent_stuck_turns"
    "terminal_host_streams" "terminal_viewer_sockets" "terminal_peer_sockets"
    "firecracker_dropped_logs" "firecracker_evicted_files" "queue_bytes" "oldest_chunk_seconds" "free_bytes" "export_errors" "export_retries" "export_dropped" ]
    ++ traceHealthNames ++ [ "runtime_observed_at_seconds" ]
    ++ lib.concatMap (prefix: map (suffix: "${prefix}_${suffix}") [ "count" "duration_ms" "errors" ])
      [ "http" "control" "ssh" "terminal_authority" "terminal_input" "database" "database_queue" "jobs" "job_failures" "control_fenced" "control_errors" ]
    ++ lib.concatMap (view: map (suffix: "live_${view}_${suffix}") [ "count" "duration_ms" "queries" ])
      [ "overview" "machines" "machine_new" "machine" ]
    ++ lib.concatMap (phase: map (suffix: "liveview_${phase}_${suffix}") [ "count" "duration_ms" "queries" ])
      [ "mount" "params" "event" "info" ];
  metricProcessors = map (metric: {
    name = "log_to_metrics"; tag = "metrics.${metric}"; emitter_name = "metric_${metric}"; match = "raw.journal.*";
    metric_mode = "gauge"; metric_name = metric;
    metric_namespace = "overalls"; metric_description = "Overalls ${metric}";
    value_field = "$metrics['${metric}']";
    regex = "$metric_present['${metric}'] ^yes$";
    add_label = [ "environment $origin['environment']" "service $metric_service"
      "hostname $origin['hostname']" "unit $origin['unit']" ];
    flush_interval_sec = 60; emitter_mem_buf_limit = "1M";
  }) metricNames;
  valueType = (pkgs.formats.json {}).type;
  outputType = types.submodule ({ ... }: {
    options = {
      enable = mkOption { type = types.bool; default = true; };
      type = mkOption { type = types.enum [ "cloudwatch" "otlp" "native" ]; };
      sources = mkOption { type = types.listOf (types.enum sources); default = []; description = "Explicit sources; audit is never implicitly selected."; };
      queueBytes = mkOption { type = types.ints.positive; description = "Queue limit per effective output group. Native/OTLP platform sources share a group; CloudWatch sources have separate groups."; };
      credentialFiles = mkOption { type = types.attrsOf paths.privatePath; default = {}; description = "Plugin setting names mapped to root-only runtime secret files."; };
      settings = mkOption { type = types.attrsOf valueType; default = {}; description = "Non-secret native output settings; routing and queue keys are reserved."; };
      plugin = mkOption { type = types.strMatching "[a-z][a-z0-9_]*"; default = "http"; description = "Native preset's compiled-in output plugin."; };
      endpoint = mkOption { type = types.str; default = ""; description = "OTLP hostname, without scheme, path or credentials."; };
      port = mkOption { type = types.port; default = 443; };
      region = mkOption { type = types.strMatching "[a-z0-9-]*"; default = ""; };
      groupPrefix = mkOption { type = types.strMatching "/[A-Za-z0-9_./-]+"; default = "/overalls/${cfg.environment}"; };
    };
  });
  outputs = lib.filterAttrs (_: out: out.enable) cfg.outputs;
  cloudwatch = lib.any (out: out.type == "cloudwatch") (builtins.attrValues outputs);
  reserved = [ "log_level" "name" "match" "match_regex" "alias" "storage.total_limit_size" "retry_limit" "_credential_files" ];
  settingKeys = out: map lib.toLower (builtins.attrNames out.settings ++ builtins.attrNames out.credentialFiles);
  managedReserved = out: reserved ++ lib.optionals (out.type == "cloudwatch") [
    "region" "log_group_name" "log_group_template" "log_stream_name" "log_stream_prefix"
    "log_stream_template" "auto_create_group" "metric_namespace" "metric_dimensions"
  ] ++ lib.optionals (out.type == "otlp") [ "host" "port" ];
  outputSettings = name: out: source:
    (if out.type == "cloudwatch" then {
      name = "cloudwatch_logs";
      tls = true; "tls.verify" = true; "tls.verify_hostname" = true;
      region = out.region;
      log_group_name = "${out.groupPrefix}/${source}";
      log_stream_prefix = "${config.networking.hostName}/";
      auto_create_group = false;
      metric_namespace = "Overalls/${cfg.environment}";
      metric_dimensions = "environment,service";
    } else if out.type == "otlp" then {
      name = "opentelemetry";
      host = out.endpoint;
      inherit (out) port;
      tls = true;
      "tls.verify" = true; "tls.verify_hostname" = true;
      log_response_payload = false;
    } else { name = out.plugin; }) // out.settings // {
      alias = "${name}-${source}";
      retry_limit = "no_limits";
      "storage.total_limit_size" = toString out.queueBytes;
      _credential_files = out.credentialFiles;
    } // lib.optionalAttrs (source == "metrics") { match = "metrics.*"; };
  luaText = ''
    OVERALLS_METRIC_NAMES = { ${lib.concatMapStringsSep ", " (name: builtins.toJSON name) metricNames} }
    package.path = "${pkgs.luajitPackages.dkjson}/share/lua/5.1/?.lua;" .. package.path
    ${builtins.readFile ./normalize.lua}
  '';
  lua = pkgs.writeText "overalls-normalize.lua" luaText;
  # Stable shards retain their cursor across source and destination additions.
  # Every shard drops records outside its trusted source set BEFORE routing,
  # preventing default output matching from leaking an unselected source.
  state = "/var/lib/overalls-logging";
  traceEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config
    && lib.attrByPath [ "services" "overallsOtelFleet" "traceSpool" "enable" ] false config;
  traceProducers = lib.optionals traceEnabled
    (lib.attrByPath [ "services" "overallsOtelFleet" "traceSpool" "producers" ] [] config);
  traceSnapshots = builtins.listToAttrs (map (producer: lib.nameValuePair producer.instance
    "/run/overalls-trace-${producer.instance}-source/metrics.prom") traceProducers);
  platformClasses = [ "auth" "kernel" "storage" "mail" "operations" "system" ];
  shardClasses = {
    applications-a = [ "marshall" "lilly" "porsche" "audi" ];
    applications-b = [ "ziggy" "enrico" "brady" "galileo" "underclass" ];
    platform = platformClasses ++ [ "platform" ];
    edge = [ "haproxy" "metrics" ];
  };
  routeClass = source: if builtins.elem source platformClasses then "platform" else source;
  groupFor = out: if out.type == "cloudwatch" then out.sources else lib.unique (map routeClass out.sources);
  aliasFor = name: out: group: "${name}-${group}";
  routesFor = name: out:
    lib.forEach (groupFor out) (group: {
      name = group;
      condition = {
        op = "or";
        rules = map (source: { field = "$source"; op = "eq"; value = source; })
          (lib.filter (source: (if out.type == "cloudwatch" then source else routeClass source) == group) out.sources);
      };
      to.outputs = [ (aliasFor name out group) ];
    });
  rawRoutes = lib.concatLists (lib.mapAttrsToList routesFor outputs);
  routeKey = route: builtins.toJSON route.condition;
  routes = map (route: route // {
    name = "source-${builtins.substring 0 16 (builtins.hashString "sha256" (routeKey route))}";
  }) (builtins.attrValues (lib.foldl' (acc: route:
    let key = routeKey route; in acc // { ${key} = route // {
      to.outputs = lib.unique ((acc.${key}.to.outputs or []) ++ route.to.outputs);
    }; }) {} rawRoutes));
  routesForShard = classes: lib.filter
    (route: builtins.elem (builtins.head route.condition.rules).value classes) routes;
  journalShards = if outputs == {} then { inherit (shardClasses) platform; }
    else lib.filterAttrs (_: classes: routesForShard classes != []) shardClasses;
  loggedSources = lib.unique (lib.filter (source: source != "metrics")
    (lib.concatMap (out: out.sources) (builtins.attrValues outputs)));
  shardLua = pkgs.writeText "overalls-journal-shards.lua" ''
    ${luaText}
    ${lib.concatMapStringsSep "\n" (name: let
      selected = if outputs == {} then shardClasses.${name}
        else lib.unique (lib.filter (source: builtins.elem source shardClasses.${name})
          (lib.concatMap (out: out.sources) (builtins.attrValues outputs)));
    in ''
      function normalize_${builtins.replaceStrings [ "-" ] [ "_" ] name}(tag, timestamp, record)
        local code, stamp, event = normalize(tag, timestamp, record)
        local allowed = { ${lib.concatMapStringsSep ", " (source: "[" + builtins.toJSON source + "]=true") selected} }
        local logged = { ${lib.concatMapStringsSep ", " (source: "[" + builtins.toJSON source + "]=true") loggedSources} }
        local numeric_only = allowed.metrics and type(event.metrics) == "table" and not logged[event.source]
        if not allowed[event.source] and not numeric_only then return -1, timestamp, record end
        return code, stamp, event
      end
    '') (builtins.attrNames journalShards)}
  '';
  processing = name: selectedRoutes: {
    processors.logs = [ { name = "lua"; script = toString shardLua; call = "normalize_${builtins.replaceStrings [ "-" ] [ "_" ] name}"; time_as_table = true; } ];
  } // lib.optionalAttrs (selectedRoutes != []) { routes.logs = selectedRoutes; };
  tail = name: path: {
    name = "tail"; tag = "raw.${name}"; inherit path;
    db = "${state}/${name}.db"; "db.sync" = "full";
    read_from_head = true; rotate_wait = 30;
    buffer_max_size = "1M"; skip_long_lines = true;
    path_key = "source_file"; offset_key = "source_offset";
    "storage.type" = "filesystem";
    processors.logs = [ { name = "lua"; script = toString lua; call = "normalize"; time_as_table = true; } ];
    routes.logs = routesForShard [ name ];
  };
  configuration = {
    service = {
      flush = 1; grace = 30; log_level = "warn";
      "storage.path" = "${state}/chunks";
      "storage.sync" = "full"; "storage.checksum" = true;
      "storage.max_chunks_up" = 32;
      http_server = true; http_listen = "127.0.0.1"; http_port = cfg.metricsPort;
    };
    pipeline = {
      filters = lib.optionals (lib.any (out: builtins.elem "metrics" out.sources) (builtins.attrValues outputs)) metricProcessors;
      inputs = lib.mapAttrsToList (name: classes: ({
        name = "systemd"; tag = "raw.journal.${name}"; alias = "journal-${name}";
        db = "${state}/journal-${name}.db"; "db.sync" = "full";
        read_from_tail = false; strip_underscores = false;
        "storage.type" = "filesystem";
      } // processing name (routesForShard classes))) journalShards
        # Tail inputs exist only when their restricted source is selected:
        # unrouted records would otherwise fall through default ("*") output
        # matching, leaking restricted evidence past the source allowlist.
        ++ lib.optional ((config.services.overallsSecurityAudit.enable or false)
            && builtins.elem "audit" (lib.concatMap (out: out.sources) (builtins.attrValues outputs)))
        (tail "audit" "/var/log/audit/audit.log*")
        ++ lib.optional ((config.services.lilly.firecrackerLogging.enable or false)
            && builtins.elem "firecracker" (lib.concatMap (out: out.sources) (builtins.attrValues outputs)))
        (tail "firecracker" "/var/log/overalls/firecracker/*.log*");
      outputs = lib.concatLists (lib.mapAttrsToList (name: out:
        map (group: outputSettings name out group) (groupFor out)) outputs)
        ++ lib.optional (outputs == {}) { name = "null"; alias = "local-only"; };
    };
  };
  descriptor = pkgs.writeText "overalls-logging.json" (builtins.toJSON {
    inherit configuration traceSnapshots;
    journalShards = builtins.attrNames journalShards;
    queueBudgets = builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: out:
      map (group: lib.nameValuePair (aliasFor name out group) out.queueBytes) (groupFor out)) outputs));
    hostname = config.networking.hostName;
    inherit (cfg) environment aws;
    executable = lib.getExe cfg.package;
  });
in {
  # Several modules import this one; the key keeps one instance per system,
  # as path imports did before it took { packages }.
  key = toString ./default.nix;
  _file = ./default.nix;
  options.services.overallsLogging = {
    enable = mkEnableOption "host-local Fluent Bit collection and pluggable direct export";
    package = mkOption { type = types.package; default = import ../../artifacts/fluent-bit { inherit pkgs; }; };
    environment = mkOption { type = paths.identifier; default = "production"; };
    outputs = mkOption { type = types.attrsOf outputType; default = {}; };
    secretUnits = mkOption { type = types.listOf types.str; default = []; };
    queueBudgetBytes = mkOption { type = types.ints.positive; default = 1073741824; description = "Host queue budget; selected per-source output limits must fit. Size from measured rate for 24 hours plus 50% headroom."; };
    journalMaxBytes = mkOption { type = types.ints.positive; default = 1073741824; };
    journalKeepFreeBytes = mkOption { type = types.ints.positive; default = 2147483648; };
    memoryMiB = mkOption { type = types.ints.positive; default = 512; };
    cpuPercent = mkOption { type = types.ints.positive; default = 100; };
    metricsPort = mkOption { type = types.port; default = 2020; };
    sdkMetricsPort = mkOption { type = types.port; default = 9468;
      description = "Loopback-only Fluent Bit numeric application health exporter when fleet telemetry and logging are enabled."; };
    healthPort = mkOption { type = types.port; default = 9467; description = "Independent logging health metrics; never carries records."; };
    healthAddress = mkOption { type = paths.ipv4; default = "127.0.0.1"; description = "Loopback or authenticated fleet address for independent health scraping."; };
    aws = {
      mode = mkOption { type = types.enum [ "none" "ec2" "file" ]; default = "none"; };
      credentialsFile = mkOption { type = types.nullOr paths.privatePath; default = null; };
    };
  };
  config = mkIf cfg.enable {
    services.overallsLogging.outputs.sdk-metrics = lib.mkIf fleetEnabled {
      type = "native";
      plugin = "prometheus_exporter";
      sources = [ "metrics" ];
      queueBytes = 4194304;
      settings = { host = "127.0.0.1"; port = cfg.sdkMetricsPort; };
    };
    assertions = [
      { assertion = !fleetEnabled || (cfg.sdkMetricsPort != cfg.metricsPort && cfg.sdkMetricsPort != cfg.healthPort);
        message = "SDK numeric exporter requires a distinct loopback port."; }
      { assertion = !fleetEnabled || (cfg.outputs.sdk-metrics.enable
          && cfg.outputs.sdk-metrics.type == "native" && cfg.outputs.sdk-metrics.plugin == "prometheus_exporter"
          && cfg.outputs.sdk-metrics.sources == [ "metrics" ]
          && (cfg.outputs.sdk-metrics.settings.host or null) == "127.0.0.1"
          && (cfg.outputs.sdk-metrics.settings.port or null) == cfg.sdkMetricsPort);
        message = "Fleet SDK numeric output must retain its enabled loopback-only metrics boundary."; }
      { assertion = !config.services.fluent-bit.enable; message = "Overalls logging owns its collector; disable the independent Fluent Bit service."; }
      { assertion = cfg.healthPort != cfg.metricsPort && (cfg.healthAddress == "127.0.0.1"
          || ((lib.attrByPath [ "overalls" "fleetNetwork" "enable" ] false config)
            && cfg.healthAddress == lib.attrByPath [ "overalls" "fleetNetwork" "address" ] null config));
        message = "Logging health must use a separate port on loopback or the authenticated fleet address."; }
      { assertion = cloudwatch == (cfg.aws.mode != "none"); message = "Select explicit AWS authentication exactly when using CloudWatch."; }
      { assertion = (cfg.aws.mode == "file") == (cfg.aws.credentialsFile != null); message = "File AWS authentication requires one private credentials file."; }
      { assertion = lib.foldl' (sum: out: sum + out.queueBytes * builtins.length (groupFor out)) 0 (builtins.attrValues outputs) <= cfg.queueBudgetBytes;
        message = "Logging destination queues exceed the host queue budget."; }
      { assertion = lib.all (classes: builtins.length (routesForShard classes) <= 8) (builtins.attrValues journalShards)
          && lib.all (source: builtins.length (routesForShard [ source ]) <= 8) [ "audit" "firecracker" ];
        message = "Logging input shards must carry at most eight conditional routes."; }
    ] ++ lib.concatLists (lib.mapAttrsToList (name: out: [
      { assertion = lib.unique (settingKeys out) == settingKeys out && lib.all (key: builtins.match "[a-z][a-z0-9_.]*" key != null) (settingKeys out);
        message = "Output settings require distinct valid keys, ignoring case, including credential settings."; }
      { assertion = builtins.match "[a-zA-Z0-9_-]+" name != null && out.sources != [] && lib.unique out.sources == out.sources;
        message = "Logging outputs require safe names and distinct explicit sources."; }
      { assertion = lib.intersectLists (managedReserved out) (settingKeys out) == [];
        message = "Logging output settings cannot replace managed routing, identity or storage controls."; }
      { assertion = out.type != "cloudwatch" || out.region != ""; message = "CloudWatch outputs require a region."; }
      { assertion = out.type != "otlp" || builtins.match "[a-zA-Z0-9.:-]+" out.endpoint != null; message = "OTLP outputs require a hostname without credentials or path."; }
      { assertion = !(builtins.elem out.type [ "otlp" "cloudwatch" ]) || lib.intersectLists [ "log_response_payload" "tls.verify" "tls.verify_hostname" "tls" ] (settingKeys out) == [];
        message = "Managed OTLP requires verified TLS and disabled response-body logging."; }
    ]) outputs);
    services.journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=${toString cfg.journalMaxBytes}
      SystemKeepFree=${toString cfg.journalKeepFreeBytes}
    '';
    systemd.services.overalls-logging = {
      description = "Overalls host-local Fluent Bit exporter";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-journal-flush.service" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python ${./runtime.py} ${descriptor}";
        ExecStartPre = "${pkgs.python3}/bin/python ${./check_cursors.py} ${descriptor}";
        Restart = "always"; RestartSec = 5; TimeoutStopSec = 45;
        User = "root"; UMask = "0077";
        StateDirectory = "overalls-logging"; StateDirectoryMode = "0700";
        RuntimeDirectory = "overalls-logging"; RuntimeDirectoryMode = "0700";
        MemoryMax = "${toString cfg.memoryMiB}M"; CPUQuota = "${toString cfg.cpuPercent}%";
        CPUWeight = 10; IOWeight = 10; TasksMax = 128;
        NoNewPrivileges = true; CapabilityBoundingSet = ""; ProtectSystem = "strict"; ProtectHome = true;
        ProtectKernelLogs = true; ProtectHostname = true; RestrictSUIDSGID = true; RestrictNamespaces = true;
        PrivateTmp = true; PrivateDevices = true; ProtectKernelTunables = true;
        ProtectKernelModules = true; ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        InaccessiblePaths = [ "/etc/ssh" ];
      };
    };
    # Health does not depend on the logging unit, its queue or its destination.
    systemd.services.overalls-logging-health = {
      description = "Independent bounded logging queue and delivery health";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        ExecStart = "${observabilityRuntimes}/bin/overalls-logging-health ${descriptor} ${cfg.healthAddress} ${toString cfg.healthPort} ${toString cfg.metricsPort}";
        Restart = "always"; RestartSec = 5;
        User = "root"; UMask = "0077";
        SupplementaryGroups = lib.optional traceEnabled "overalls-telemetry-health";
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
        PrivateTmp = true; PrivateDevices = true; ProtectProc = "invisible";
        ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        Environment = [
          "PYTHONDONTWRITEBYTECODE=1"
          "OVERALLS_LOGGING_HEALTH_PYTHON=${pkgs.python3}/bin/python3"
          "OVERALLS_LOGGING_HEALTH_SCRIPT=${./health.py}"
        ];
        CapabilityBoundingSet = "";
        InaccessiblePaths = [ "-/etc/ssh" "-/run/overalls-secrets" "-/var/lib/overalls-secrets" ];
        ReadOnlyPaths = [ "-/var/lib/overalls-logging" ];
        StateDirectory = "overalls-logging"; StateDirectoryMode = "0700";
        TemporaryFileSystem = [ "/var/lib:ro" "/run:ro" "/etc:ro" ];
        BindReadOnlyPaths = [ "/var/lib/overalls-logging" ]
          ++ map (producer: "/run/overalls-trace-${producer.instance}-source") traceProducers;
        MemoryMax = "64M"; CPUQuota = "10%"; TasksMax = 8;
      };
    };
  };
}
