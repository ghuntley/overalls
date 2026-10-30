{ packages }:
{ config, lib, pkgs, ... }:
let
  active = lib.filterAttrs (_: instance: instance.enable) config.services.overallsBrowserProbes.instances;
  package = packages.otelReceiver;
  driver = import ../otel-guest/browser-driver.nix { inherit pkgs; };
  identities = import ./request-identities.nix;
  identity = name: "overalls-vscode-browser-${name}";
  recorder = name: "vscode-browser-${name}";
  group = name: "overalls-otel-code-${name}";
  source = name: "vscode_browser_${name}";
  runtimePath = path: lib.hasPrefix "/" path && !lib.hasPrefix "/nix/store/" path && !lib.hasInfix "\n" path;
  start = name: pkgs.writeShellScript "${identity name}-start" ''
    set -euo pipefail
    ${pkgs.jq}/bin/jq --arg state "$CREDENTIALS_DIRECTORY/session" \
      '.storage_state_path = $state' "$CREDENTIALS_DIRECTORY/fixture" > "$RUNTIME_DIRECTORY/fixture.json"
    chmod 0600 "$RUNTIME_DIRECTORY/fixture.json"
    exec ${package}/bin/browser_probe ${driver}/bin/overalls-browser-editor-journey \
      "$RUNTIME_DIRECTORY/fixture.json" ${pkgs.chromium}/bin/chromium
  '';
in {
  options.services.overallsBrowserProbes.instances = lib.mkOption {
    default = {};
    description = "Five-minute real authenticated editor journeys; fixtures and operator sessions are private runtime credentials.";
    type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
      options = {
        enable = lib.mkEnableOption "this browser editor probe" // { default = true; };
        fixtureFile = lib.mkOption { type = lib.types.str; description = "Private runtime JSON fixture identifying the real operator's guest, origin, UID and existing Markdown probe file."; };
        storageStateFile = lib.mkOption { type = lib.types.str; description = "Private Playwright storage state obtained from a real Marshall operator browser sign-in; no authentication bypass."; };
      };
    }));
  };
  # @cc [owner:ghuntley,label:security;reliability] browser-probe-source-custody
  # A browser supervisor MUST be the recorder's exact unprivileged producer;
  # independent exporters MUST receive only source-reader and collector groups.
  # Runtime credentials MUST NOT enter Nix outputs or metric identities.
  config = lib.mkIf (active != {}) {
    assertions = [{
      assertion = config.services.overallsOtelFleet.enable;
      message = "Editor browser probes require the independent fleet recorder/exporter pipeline.";
    }] ++ lib.mapAttrsToList (name: instance: {
      assertion = builtins.elem name [ "nixos" "ubuntu" ]
        && runtimePath instance.fixtureFile && runtimePath instance.storageStateFile;
      message = "Browser probe names must be nixos or ubuntu and both credentials must be private runtime paths.";
    }) active;
    services.overallsRequestRecorder.instances = lib.mapAttrs' (name: _: lib.nameValuePair (recorder name) {
      source = source name;
      producerUser = identity name;
      producerUnit = "${identity name}.service";
      deadlineSeconds = 60;
    }) active;
    users.users = lib.mkMerge (lib.mapAttrsToList (name: _: {
      ${identity name} = { isSystemUser = true; group = identity name; };
      ${identities.exporterUser (recorder name)} = {
        isSystemUser = true; group = identities.readerGroup (recorder name);
      };
    }) active);
    users.groups = lib.mkMerge ([ (lib.mapAttrs' (name: _: lib.nameValuePair (group name) {}) active) ]
      ++ lib.mapAttrsToList (name: _: { ${identity name} = {}; }) active);
    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: instance: {
      ${identity name} = {
        description = "Real ${name} browser editor journey every five minutes";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = start name;
          User = identity name; Group = identity name;
          RuntimeDirectory = identity name; RuntimeDirectoryMode = "0700";
          LoadCredential = [ "fixture:${instance.fixtureFile}" "session:${instance.storageStateFile}" ];
          Restart = "always"; RestartSec = 5;
          UMask = "0077"; NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
          PrivateTmp = true; PrivateDevices = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_NETLINK" ];
          CapabilityBoundingSet = []; MemoryMax = "1G"; CPUQuota = "100%"; TasksMax = 256;
          StandardOutput = "null"; StandardError = "null";
        };
      };
      "overalls-request-${recorder name}-exporter" = {
        description = "Export durable ${name} browser journey accounting";
        wantedBy = [ "multi-user.target" ];
        after = [ "overalls-request-${recorder name}.service" "opentelemetry-collector.service" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = lib.escapeShellArgs [ "${package}/bin/slo_exporter" "--recorder-group-source"
            (source name) "/run/overalls-request-${recorder name}-source/slo.json" "/run/${group name}/collector.sock" ];
          User = identities.exporterUser (recorder name); Group = identities.readerGroup (recorder name);
          SupplementaryGroups = [ (group name) ];
          Restart = "always"; RestartSec = 5;
          NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
          PrivateTmp = true; PrivateDevices = true; RestrictAddressFamilies = [ "AF_UNIX" ];
          CapabilityBoundingSet = []; MemoryMax = "64M"; TasksMax = 8;
        };
      };
    }) active ++ [{
      opentelemetry-collector = {
        serviceConfig = {
          SupplementaryGroups = map group (builtins.attrNames active);
          RuntimeDirectory = map group (builtins.attrNames active);
        };
        # Custody joins the collector's single postStart (see the
        # collector-socket-custody assertion): systemd resets RuntimeDirectory
        # ownership whenever it spawns a further ExecStartPost command.
        postStart = lib.mkBefore (lib.concatMapStringsSep "\n" (name: ''
          for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
            if test -S /run/${group name}/collector.sock; then break; fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          test -S /run/${group name}/collector.sock
          ${pkgs.coreutils}/bin/chgrp ${group name} /run/${group name} /run/${group name}/collector.sock
          ${pkgs.coreutils}/bin/chmod 0750 /run/${group name}
          ${pkgs.coreutils}/bin/chmod 0660 /run/${group name}/collector.sock
        '') (builtins.attrNames active));
      };
    }]);
    services.opentelemetry-collector.settings = {
      receivers = lib.mapAttrs' (name: _: lib.nameValuePair "otlp/application-${source name}" {
        protocols.http = { endpoint = "/run/${group name}/collector.sock"; transport = "unix"; max_request_body_size = 4096; };
      }) active;
      processors = lib.mapAttrs' (name: _: lib.nameValuePair "resource/application-${source name}" {
        attributes = [
          { key = "service.name"; value = source name; action = "upsert"; }
          { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
          { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
        ];
      }) active;
      service.pipelines = lib.mapAttrs' (name: _: lib.nameValuePair "metrics/application-${source name}" {
        receivers = [ "otlp/application-${source name}" ];
        processors = [ "memory_limiter" "resource/application-${source name}" "batch" ];
        exporters = [ "prometheus" ];
      }) active;
    };
  };
}
