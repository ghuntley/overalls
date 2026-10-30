{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.overallsOtelFleet.traceSpool;
  enabled = config.services.overallsOtelFleet.enable && cfg.enable;
  serviceEnabled = name: lib.attrByPath [ "services" name "enable" ] false config;
  fixed = lib.concatMap (name: lib.optional (serviceEnabled name) {
    instance = name; service = name; user = if name == "lilly" then "root" else name;
  }) [ "lilly" "porsche" "brady" "ziggy" "enrico" "galileo" ];
  audi = lib.concatMap (entry: lib.optional (serviceEnabled entry.option) {
    inherit (entry) instance user; service = "audi";
  }) [
    { option = "audi"; instance = "audi"; user = "audi"; }
    { option = "audiPrivate"; instance = "audi-private"; user = "audi"; }
    { option = "audiDns"; instance = "audi-dns"; user = "audi-dns"; }
  ];
  marshall = lib.optionals (serviceEnabled "marshall") (map (name: {
    instance = "marshall-${name}"; service = "marshall"; user = "marshall-${name}";
  }) (builtins.attrNames config.services.marshall.instances));
  producers = fixed ++ audi ++ marshall;
  unit = producer: "overalls-trace-${producer.instance}";
  account = producer: "ktr-${builtins.substring 0 16 (builtins.hashString "sha256" producer.instance)}";
  group = producer: "ktp-${builtins.substring 0 16 (builtins.hashString "sha256" producer.instance)}";
  source = producer: "overalls-trace-${producer.instance}-source";
  schema = ../../../../elixir/diagnostics/priv/trace-schema.json;
  deploymentRevision = import ./deployment-revision.nix { inherit config lib; };
  producerCgroup = producer:
    let
      slice = lib.attrByPath [ "systemd" "services" producer.instance "serviceConfig" "Slice" ] "system.slice" config;
      components = lib.splitString "-" (lib.removeSuffix ".slice" slice);
      paths = lib.imap0 (index: _: "/${lib.concatStringsSep "-" (lib.take (index + 1) components)}.slice") components;
    in (if slice == "-.slice" then "" else lib.concatStrings paths) + "/${producer.instance}.service";
  runtime = producer: pkgs.writeText "${account producer}.json" (builtins.toJSON {
    inherit (producer) service;
    host = config.networking.hostName;
    # The host build's source revision; producers never supply provenance.
    revision = deploymentRevision;
    producer_user = producer.user;
    producer_unit = "${producer.instance}.service";
    producer_cgroup = producerCgroup producer;
    state = "/var/lib/${unit producer}";
    socket = "/run/${unit producer}/ingest.sock";
    sink = "/run/overalls-otel-traces/collector.sock";
    metrics = "/run/${source producer}/metrics.prom";
    inherit schema;
    quota_bytes = cfg.quotaBytes;
    pending_quota_bytes = cfg.pendingQuotaBytes;
    retention_seconds = cfg.retentionDays * 86400;
  });
in {
  options.services.overallsOtelFleet.traceSpool = {
    enable = lib.mkOption { type = lib.types.bool; default = true;
      description = "Independent per-producer durable trace custody; failures leave producers running."; };
    quotaBytes = lib.mkOption { type = lib.types.ints.between 4194304 68719476736; default = 2147483648;
      description = "Logical archive/SQLite budget per producer, distinct from Tempo quota. New data refuses when full."; };
    traceSampling = lib.mkOption {
      type = lib.types.addCheck (lib.types.either lib.types.int lib.types.float) (value: value >= 0 && value <= 1);
      default = 1.0;
      description = "Official parent/trace-ID ratio for routine spans; committed lifecycle diagnostics always sample and SLO accounting is independent.";
    };
    pendingQuotaBytes = lib.mkOption { type = lib.types.ints.between 262144 68719476736; default = 268435456;
      description = "Pending export admission budget per producer, within retained archive budget."; };
    hostBudgetBytes = lib.mkOption { type = lib.types.ints.between 4194304 1099511627776; default = 34359738368;
      description = "Reviewed aggregate per-host producer archive allocation ceiling; evaluation refuses an overcommitted inventory."; };
    retentionDays = lib.mkOption { type = lib.types.ints.between 1 365; default = 90;
      description = "Immutable per-batch retention, including traces already acknowledged upstream."; };
    package = lib.mkOption { type = lib.types.package; default = packages.traceSpool;
      description = "Reviewed typed OTLP custody implementation."; };
    producers = lib.mkOption { type = lib.types.listOf (lib.types.submodule { options = {
      instance = lib.mkOption { type = lib.types.str; };
      service = lib.mkOption { type = lib.types.str; };
      user = lib.mkOption { type = lib.types.str; };
    }; }); readOnly = true; default = producers;
      description = "Evaluated producer identity inventory for topology and independent health."; };
  };
  config = lib.mkIf enabled {
    assertions = [
      { assertion = cfg.pendingQuotaBytes <= cfg.quotaBytes;
        message = "Trace pending admission budget must fit retained archive budget."; }
      { assertion = builtins.length producers * cfg.quotaBytes <= cfg.hostBudgetBytes;
        message = "Trace producer archives exceed the reviewed host aggregate storage budget."; }
    ];
    users.groups = lib.mkMerge ([{ overalls-telemetry-health = {}; }] ++ map (producer: {
      "${account producer}" = {};
      "${group producer}" = {};
    }) producers);
    users.users = lib.mkMerge (map (producer: {
      "${account producer}" = { isSystemUser = true; group = account producer;
        extraGroups = [ (group producer) "overalls-otel-traces" "overalls-telemetry-health" ]; };
    }) producers);
    systemd.tmpfiles.rules = lib.concatMap (producer: [
      "d /run/${unit producer} 2750 ${account producer} ${group producer} - -"
      "d /run/${source producer} 2750 ${account producer} overalls-telemetry-health - -"
    ]) producers;
    # @cc [owner:ghuntley,label:security;recovery] trace-spool-independent-producer
    # Each receiver MUST authenticate exact UID/cgroup and have independent
    # private custody. Observer failure MUST NOT require, restart or stop producer.
    systemd.services = lib.mkMerge (map (producer: {
      "${producer.instance}" = {
        environment.OVERALLS_TRACE_SOCKET = "/run/${unit producer}/ingest.sock";
        environment.OTEL_TRACES_EXPORTER = "none";
        environment.OVERALLS_TRACE_SAMPLE_RATIO = toString cfg.traceSampling;
        serviceConfig.SupplementaryGroups = [ (group producer) ];
      };
      "${unit producer}" = {
        description = "Independent ${producer.instance} trace custody";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${lib.getExe cfg.package} ${runtime producer}";
          User = account producer; Group = account producer;
          SupplementaryGroups = [ (group producer) "overalls-otel-traces" "overalls-telemetry-health" ];
          StateDirectory = unit producer; StateDirectoryMode = "0700";
          UMask = "0077";
          Restart = "on-failure"; RestartSec = "5s";
          ProtectSystem = "strict"; ProtectHome = true;
          PrivateTmp = true; NoNewPrivileges = true;
          ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
          CapabilityBoundingSet = []; RestrictAddressFamilies = [ "AF_UNIX" ];
          ReadWritePaths = [ "/run/${unit producer}" "/run/${source producer}" ];
          MemoryMax = "128M"; TasksMax = 16; LimitNOFILE = 64;
          CPUQuota = "25%";
        };
      };
    }) producers);
  };
}
