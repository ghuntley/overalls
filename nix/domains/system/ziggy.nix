{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.ziggy;
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  otelExporter = packages.otelReceiver;
  paths = import ./types.nix { inherit lib; };
  runtime = pkgs.writeText "ziggy-public-config.json" (builtins.toJSON {
    version = 1;
    # @cc [owner:ghuntley,label:deployment] ziggy-replacement-runtime-host-binding
    # Only a bounded test fixture may carry the placeholder host marker; deployed
    # configurations keep the enrolled host identity.
    host_id = if cfg.configurationFile != null then "@replacement-host-id@" else cfg.hostId;
    control_plane = cfg.controlPlane;
    ca_file = "/run/ziggy/credentials/ca.pem";
    credential_file = "/run/ziggy/credentials/control.token";
    openai_key_file = "/run/ziggy/credentials/openai.key";
    openai_origin = cfg.openaiOrigin;
    agent_enabled = cfg.agentEnable;
    lyra_release = toString cfg.lyraRelease;
    executor_bootstrap_release = if cfg.githubBootstrapRelease == null then null else toString cfg.githubBootstrapRelease;
    github_tools_release = if cfg.githubToolsRelease == null then null else toString cfg.githubToolsRelease;
    anthropic_key_file = "/run/ziggy/credentials/anthropic.key";
    socket = "/run/ziggy/proxy.sock";
    spool = "/var/lib/ziggy/spool";
    max_requests = cfg.maxPendingRequests;
    enabled_providers = cfg.enabledProviders;
  });
in {
  options.services.ziggy = {
    enable = (mkEnableOption "private node-local inference proxy") // { default = config.services.lilly.enable; };
    enabledProviders = mkOption {
      type = types.listOf (types.enum [ "openai" "anthropic" ]);
      default = [ "openai" "anthropic" ];
      description = "Nonempty set of providers enabled for discovery and inference; readiness requires all selected catalogs.";
    };
    package = mkOption { type = types.package; default = packages.ziggy; };
    hostId = mkOption { type = paths.uuid; default = config.services.lilly.hostId; description = "Enrolled local Lilly host identity."; };
    configurationFile = mkOption { type = types.nullOr types.path; default = null; description = "Release-independent runtime configuration; null uses the deployed configuration."; };
    controlPlane = mkOption { type = types.str; default = config.services.lilly.controlPlane; description = "Verified HTTPS Marshall origin."; };
    caFile = mkOption { type = paths.absolutePath; default = config.services.lilly.controlPlaneCAFile; };
    secretsFile = mkOption { type = paths.absolutePath; description = "SOPS document containing ZIGGY_CREDENTIAL, OPENAI_API_KEY and ANTHROPIC_API_KEY."; };
    credentialFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/ziggy/control.token"; readOnly = true; description = "Dedicated Ziggy control credential runtime file."; };
    openaiKeyFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/ziggy/openai.key"; description = "Private runtime OpenAI-compatible proxy key file."; };
    openaiOrigin = mkOption {
      type = types.enum [ "https://api.openai.com" "http://127.0.0.1:8080" ];
      default = "https://api.openai.com";
      description = "Fixed OpenAI-compatible origin; enrolled hosts use host-local Underclass.";
    };
    agentEnable = mkOption {
      type = types.bool;
      default = false;
      description = "Poll Marshall for host-bound agent model calls.";
    };
    lyraRelease = mkOption {
      type = types.package;
      default = packages.lyra;
      description = "Trusted local Overalls CLI artifacts for private guest updates.";
    };
    githubBootstrapRelease = mkOption {
      type = types.nullOr types.package;
      default = packages.githubBootstrapRelease or null;
      description = "Immutable executor artifacts for fenced retained-machine GitHub tools bootstrap.";
    };
    githubToolsRelease = mkOption {
      type = types.nullOr types.package;
      default = if packages ? githubTools then packages.githubTools.release else null;
      description = "Immutable managed GitHub CLI and LFS release for fenced guest maintenance.";
    };
    anthropicKeyFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/ziggy/anthropic.key"; readOnly = true; description = "Private runtime Anthropic API key file."; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
    maxPendingRequests = mkOption { type = types.ints.between 1 100000; default = 65536; };
    cpuCores = mkOption { type = types.ints.positive; default = 4; };
    memoryMiB = mkOption { type = types.ints.positive; default = 4096; };
  };
  # @cc [owner:ghuntley,label:deployment] ziggy-required-with-lilly
  # Enabling Lilly MUST enable Ziggy automatically. Explicitly disabling Ziggy
  # on a Lilly node MUST fail evaluation, including a forced override. Provider
  # secrets remain required inputs; missing credentials MUST NOT disable Ziggy.
  config = lib.mkMerge [ {
    assertions = [{
      assertion = !config.services.lilly.enable || cfg.enable;
      message = "Lilly requires Ziggy; services.ziggy.enable cannot be false on a Lilly node.";
    }];
  } (mkIf cfg.enable {
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.ziggy = {
      encryptedFile = cfg.secretsFile;
      outputs = {
        "control.token" = { format = "raw"; secrets = [ "ZIGGY_CREDENTIAL" ]; };
        "openai.key" = { format = "raw"; secrets = [ "OPENAI_API_KEY" ]; };
        "anthropic.key" = { format = "raw"; secrets = [ "ANTHROPIC_API_KEY" ]; };
      };
    };
    services.ziggy.secretUnits = [ "overalls-secrets-ziggy.service" ];

    assertions = [
      { assertion = cfg.enabledProviders != [] && lib.unique cfg.enabledProviders == cfg.enabledProviders;
        message = "Ziggy needs a nonempty, unique provider selection."; }
      { assertion = lib.attrByPath [ "services" "lilly" "enable" ] false config;
        message = "Ziggy must run on an enabled Lilly node."; }
      { assertion = cfg.hostId == config.services.lilly.hostId;
        message = "Ziggy and local Lilly identities must match."; }
    ];
    users.groups.ziggy = {};
    users.groups.ziggy-proxy = {};
    users.groups.audi = {};
    users.users.ziggy = { isSystemUser = true; group = "ziggy"; extraGroups = [ "ziggy-proxy" ]; };
    users.users.audi = { isSystemUser = true; group = "audi"; extraGroups = [ "ziggy-proxy" ]; };
    systemd.services.ziggy = import ./ziggy-service.nix { inherit pkgs cfg runtime otelEnabled; };
    systemd.services.ziggy-slo-exporter = lib.mkIf otelEnabled {
      description = "Export source-owned Ziggy inference completion metrics";
      wantedBy = [ "multi-user.target" ];
      after = [ "ziggy.service" "opentelemetry-collector.service" ];
      requires = [ "ziggy.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${otelExporter}/bin/slo_exporter ziggy /run/ziggy/slo.json /run/overalls-otel-ziggy/collector.sock";
        User = "ziggy"; Group = "ziggy";
        SupplementaryGroups = [ "overalls-otel-ziggy" ];
        Restart = "always"; RestartSec = 5;
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
        PrivateTmp = true; PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        MemoryMax = "64M"; CPUQuota = "10%"; TasksMax = 8;
      };
    };
  }) ];
}
