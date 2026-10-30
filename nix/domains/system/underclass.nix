{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.underclass;
  localTypes = import ./types.nix { inherit lib; };
  tailscale = config.services.tailscale;
  tailscaleExe = lib.getExe tailscale.package;
  localOrigin = "http://127.0.0.1:${toString cfg.port}";
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  otelProbe = packages.otelReceiver;
  egress = cfg.egress;
  egressRouted = egress.route;
  egressSocket = "/run/underclass-egress/tailscaled.sock";
  egressProxy = "http://127.0.0.1:${toString egress.proxyPort}";
  # Operator entry point for the dedicated node, e.g. `sudo underclass-egress up`.
  # Joining (`up` or `login`) always advertises the node's tags.
  egressCli = pkgs.writeShellScriptBin "underclass-egress" ''
    case "''${1:-}" in
      up|login)
        command="$1"
        shift
        exec ${tailscaleExe} --socket=${egressSocket} "$command" \
          --advertise-tags=${lib.escapeShellArg (lib.concatStringsSep "," egress.tags)} "$@"
        ;;
    esac
    exec ${tailscaleExe} --socket=${egressSocket} "$@"
  '';
  # Runs with full privileges (`+`) before every Underclass start: re-asserts
  # the configured exit-node preference on the dedicated node (clearing any
  # stale one when no exit node is configured) and refuses to start while that
  # node is logged out or the preference does not match.
  egressGate = pkgs.writeShellScript "underclass-egress-gate" (''
    set -eu
    ts="${tailscaleExe} --socket=${egressSocket}"
  '' + (if egress.exitNode != null then ''
    if ! $ts set --exit-node=${egress.exitNode} --exit-node-allow-lan-access=false; then
      echo "underclass egress node cannot select exit node ${egress.exitNode}; log it in with: underclass-egress up" >&2
      exit 1
    fi
    $ts status --json | ${lib.getExe pkgs.jq} -e \
      '.BackendState == "Running" and ((.ExitNodeStatus.ID // "") != "")' >/dev/null || {
      echo "underclass egress node is not running with exit node ${egress.exitNode}" >&2
      exit 1
    }
  '' else ''
    if ! $ts set --exit-node=; then
      echo "underclass egress node cannot clear its exit node; log it in with: underclass-egress up" >&2
      exit 1
    fi
    $ts status --json | ${lib.getExe pkgs.jq} -e \
      '.BackendState == "Running" and ((.ExitNodeStatus.ID // "") == "")' >/dev/null || {
      echo "underclass egress node is not running without an exit node" >&2
      exit 1
    }
  ''));
in
{
  options.services.underclass = {
    enable = mkEnableOption "independent host-local Underclass subscription pool";
    package = mkOption {
      type = types.package;
      default = packages.underclass;
      description = "Pinned Underclass package.";
    };
    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Loopback HTTP port. Underclass is never bound directly to a fleet interface.";
    };
    environmentFile = mkOption {
      type = localTypes.privatePath;
      default = "/run/overalls-secrets/underclass/environment";
      description = "Runtime environment file containing UNDERCLASS_PROXY_KEY and UNDERCLASS_UI_TOKEN.";
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [ ];
      description = "Secret preparation units required before Underclass starts.";
    };
    tailscaleServe = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Publish the loopback service through tailnet-only Tailscale Serve HTTPS.";
      };
      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = "Tailnet HTTPS port reserved for Underclass on this host.";
      };
    };
    egress = {
      enable = mkEnableOption ''
        a dedicated userspace Tailscale node whose loopback HTTP proxy can carry
        Underclass upstream traffic. The node starts logged out; an operator joins it
        once with `sudo underclass-egress up`'';
      exitNode = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9][A-Za-z0-9.:-]*");
        default = null;
        example = "mac-mini";
        description = ''
          Tailnet exit node (MagicDNS name or Tailscale IP) that all Underclass upstream
          traffic leaves through. Setting it implies `route`. Null with `route` keeps
          traffic behind the egress node's proxy but leaves from the host's own address,
          and every Underclass start clears any stale exit-node preference.
        '';
      };
      route = mkOption {
        type = types.bool;
        default = egress.exitNode != null;
        defaultText = lib.literalExpression "config.services.underclass.egress.exitNode != null";
        description = ''
          Send all Underclass upstream traffic through the egress node's loopback proxy.
          Underclass then reaches only loopback and refuses to start until the egress node
          is logged in with the configured exit-node preference (`exitNode`, or none).
        '';
      };
      proxyPort = mkOption {
        type = types.port;
        default = 1055;
        description = "Loopback port of the egress node's outbound HTTP proxy.";
      };
      tags = mkOption {
        type = types.nonEmptyListOf (types.strMatching "tag:[a-z0-9][a-z0-9-]*");
        default = [ "tag:underclass" ];
        description = ''
          Tailscale ACL tags the egress node advertises whenever an operator joins it with
          `underclass-egress up` or `login`. The tailnet policy must let the joining
          identity own each tag.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # @cc [owner:ghuntley,label:cli] underclass-commands-on-path
    # Enabling Underclass MUST put its configured package on the host PATH; with
    # egress enabled, `underclass-egress` MUST address only the egress node's socket
    # and MUST advertise the configured tags whenever it joins the node.
    environment.systemPackages = [ cfg.package ] ++ lib.optional egress.enable egressCli;

    assertions = [
      {
        assertion = !cfg.tailscaleServe.enable || tailscale.enable;
        message = "Underclass Tailscale Serve publication requires services.tailscale.enable.";
      }
      {
        assertion = !egressRouted || egress.enable;
        message = "services.underclass.egress.route and exitNode require services.underclass.egress.enable.";
      }
      {
        assertion = egress.exitNode == null || egressRouted;
        message = "services.underclass.egress.exitNode requires services.underclass.egress.route.";
      }
      {
        assertion = !egress.enable || egress.proxyPort != cfg.port;
        message = "services.underclass.egress.proxyPort must differ from the Underclass port.";
      }
    ];

    # @cc [owner:ghuntley,label:security] underclass-loopback-secrets
    # Underclass MUST listen only on loopback and receive its API/admin keys from
    # a private runtime file. Neither key may enter the Nix store or command line.

    # @cc [owner:ghuntley,label:security] underclass-credential-separation
    # Proxy and administrative credentials MUST both be present and distinct;
    # each credential MUST be rejected at the other authorization boundary.

    # @cc [owner:ghuntley,label:security] underclass-egress-fail-closed
    # When egress routing is enabled, Underclass MUST send upstream traffic only
    # through the egress node's loopback proxy: its unit MUST be unable to reach
    # any non-loopback address, and it MUST NOT start until the egress node is
    # logged in with the configured exit-node preference. With an exit node
    # configured, losing it MUST fail requests rather than fall back to the
    # host's own route; with none configured, each start MUST clear any stale
    # exit-node preference.
    systemd.services.underclass = {
      description = "Independent host-local Underclass subscription pool";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits
        ++ lib.optional egressRouted "underclass-egress.service";
      requires = cfg.secretUnits ++ lib.optional egressRouted "underclass-egress.service";
      environment = {
        UNDERCLASS_DATA_DIR = "/var/lib/underclass";
        UNDERCLASS_MONITOR_SOCKET = "/run/underclass/monitor.sock";
        RUST_LOG = "info";
      } // lib.optionalAttrs otelEnabled {
        UNDERCLASS_SLO_SNAPSHOT = "/run/underclass/slo/slo.json";
      } // lib.optionalAttrs egressRouted {
        HTTPS_PROXY = egressProxy;
        HTTP_PROXY = egressProxy;
      };
      # @cc [owner:ghuntley,label:security] underclass-local-monitor-socket
      # Only the limited monitor endpoint MAY be readable without a token on
      # the host-local Unix socket. Network administration retains its token.
      serviceConfig = {
        ExecStartPre = [
          "${pkgs.runtimeShell} -ec 'test -n \"$UNDERCLASS_PROXY_KEY\"; test -n \"$UNDERCLASS_UI_TOKEN\"; test \"$UNDERCLASS_PROXY_KEY\" != \"$UNDERCLASS_UI_TOKEN\"'"
        ] ++ lib.optional egressRouted "+${egressGate}";
        ExecStart = "${lib.getExe cfg.package} serve --bind 127.0.0.1:${toString cfg.port}";
        EnvironmentFile = cfg.environmentFile;
        DynamicUser = true;
        Group = lib.mkIf otelEnabled "overalls-otel-underclass-source";
        StateDirectory = "underclass";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "underclass";
        RuntimeDirectoryMode = "0755";
        UMask = "0077";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 30;
        MemoryMax = "1G";
        CPUQuota = "200%";
        TasksMax = 512;
        LimitNOFILE = 8192;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
      } // lib.optionalAttrs egressRouted {
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };

    # @cc [owner:ghuntley,label:security] underclass-egress-node-isolation
    # The egress node MUST be a separate unprivileged userspace tailscaled with
    # its own state and socket. It MUST NOT create a TUN device, install routes or
    # change the host's own tailscaled; its outbound proxy MUST listen only on
    # loopback. It starts logged out and the module MUST NOT hold Tailscale keys.
    systemd.services.underclass-egress = mkIf egress.enable {
      description = "Dedicated userspace Tailscale node for Underclass upstream egress";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.concatStringsSep " " [
          "${tailscale.package}/bin/tailscaled"
          "--tun=userspace-networking"
          "--port=0"
          "--statedir=/var/lib/underclass-egress"
          "--socket=${egressSocket}"
          "--outbound-http-proxy-listen=127.0.0.1:${toString egress.proxyPort}"
        ];
        DynamicUser = true;
        StateDirectory = "underclass-egress";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "underclass-egress";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 30;
        MemoryMax = "256M";
        CPUQuota = "100%";
        TasksMax = 256;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_NETLINK" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
      };
    };

    users.groups.overalls-otel-underclass-source = lib.mkIf otelEnabled {};
    users.users.otel-underclass-exporter = lib.mkIf otelEnabled {
      isSystemUser = true;
      group = "overalls-otel-underclass-source";
    };

    # @cc [owner:ghuntley,label:security;reliability] underclass-isolated-outcome-export
    # The exporter MUST have a separate UID, read only the source-group numeric
    # snapshot and write only its collector intake. Private provider state,
    # environment credentials and producer process data MUST remain inaccessible.
    systemd.services.underclass-proxy-slo-exporter = lib.mkIf otelEnabled {
      description = "Export durable Underclass proxy completion metrics";
      wantedBy = [ "multi-user.target" ];
      after = [ "underclass.service" "opentelemetry-collector.service" ];
      requires = [ "underclass.service" ];
      partOf = [ "underclass.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${otelProbe}/bin/slo_exporter underclass_proxy /run/underclass/slo/slo.json /run/overalls-otel-underclass-proxy/collector.sock";
        User = "otel-underclass-exporter";
        Group = "overalls-otel-underclass-source";
        SupplementaryGroups = [ "overalls-otel-underclass-proxy" ];
        InaccessiblePaths = [ cfg.environmentFile "-/var/lib/underclass" "-/var/lib/private/underclass" "-/run/overalls-secrets" ];
        ProtectProc = "invisible";
        ProcSubset = "pid";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        MemoryMax = "64M";
        CPUQuota = "10%";
        TasksMax = 8;
      };
    };

    # @cc [owner:ghuntley,label:security;reliability] underclass-local-readiness-probe
    # The independent probe MUST retain no Underclass credentials and MUST
    # report a local monitor refusal as zero while collector loss remains absent.
    systemd.services.underclass-monitor-probe = lib.mkIf otelEnabled {
      description = "Probe Underclass local monitor for candidate readiness";
      wantedBy = [ "multi-user.target" ];
      after = [ "underclass.service" "opentelemetry-collector.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${otelProbe}/bin/underclass_probe /run/underclass/monitor.sock /run/overalls-otel-underclass/collector.sock";
        User = "overalls-otel-underclass-probe";
        Group = "overalls-otel-underclass";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        MemoryMax = "64M";
        CPUQuota = "10%";
        TasksMax = 8;
      };
    };

    # @cc [owner:ghuntley,label:security] underclass-tailnet-only
    # Remote Underclass traffic MUST terminate at a systemd-supervised foreground
    # Tailscale Serve process and proxy to loopback. Funnel, detached publication
    # and direct fleet-interface listeners MUST NOT be enabled.
    systemd.services.underclass-tailscale-serve = mkIf cfg.tailscaleServe.enable {
      description = "Publish Underclass privately through Tailscale Serve";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscaled.service" "underclass.service" ];
      requires = [ "tailscaled.service" "underclass.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${tailscaleExe} serve --yes --https=${toString cfg.tailscaleServe.httpsPort} ${localOrigin}";
        TimeoutStartSec = 60;
        TimeoutStopSec = 30;
        Restart = "always";
        RestartSec = 10;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
