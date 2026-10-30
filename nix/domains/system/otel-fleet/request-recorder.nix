# @cc [owner:ghuntley,label:security;recovery] request-recorder-independent-custody
# Every configured request source MUST have a separate unprivileged recorder,
# private permanent state, read-only exporter group and exact producer-unit
# attribution. Recorder restart MUST NOT restart or stop its application.
{ packages }:
{ config, lib, pkgs, ... }:
let
  instances = config.services.overallsRequestRecorder.instances;
  package = packages.otelReceiver;
  active = lib.filterAttrs (_: instance: instance.enable) instances;
  identities = import ./request-identities.nix;
  group = identities.rpcGroup;
  sourceGroup = identities.readerGroup;
  user = identities.recorderUser;
  runtime = name: "overalls-request-${name}";
in {
  # Several modules import this one; the key keeps one instance per system,
  # as path imports did before it took { packages }.
  key = toString ./request-recorder.nix;
  _file = ./request-recorder.nix;
  options.services.overallsRequestRecorder.instances = lib.mkOption {
    default = {};
    description = "Independent durable request recorders; enabling requires reviewed producer hooks and source-specific deadlines.";
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        enable = lib.mkEnableOption "this source recorder" // { default = true; };
        source = lib.mkOption {
          type = lib.types.enum [ "marshall_web" "marshall_live" "galileo" "enrico" "brady" "porsche" "audi_private" "audi_dns" "audi_ssh" "vscode_browser_nixos" "vscode_browser_ubuntu" ];
          description = "Closed trusted request-source name; physical measurements stay in PostgreSQL.";
        };
        producerUser = lib.mkOption { type = lib.types.str; description = "Expected Unix peer account, including dynamically allocated application users."; };
        producerUnit = lib.mkOption { type = lib.types.str; description = "Exact cgroup v2 systemd service allowed to admit requests."; };
        environmentSuffix = lib.mkOption {
          type = lib.types.strMatching "(_[A-Z0-9]+)*";
          default = "";
          description = "Suffix of the producer's socket and marker variables, so one unit can admit to several sources without reading another source's recorder.";
        };
        deadlineSeconds = lib.mkOption { type = lib.types.ints.between 1 86400; description = "Immutable measurement deadline reconciled with this source's request budget."; };
        package = lib.mkOption { type = lib.types.package; default = package; description = "Pinned Rust request recorder package."; };
      };
    }));
  };
  config = lib.mkIf (active != {}) {
    assertions = [{
      assertion = builtins.length (lib.unique (map user (builtins.attrNames active)))
        == builtins.length (builtins.attrNames active);
      message = "Request recorder instance identities must not share an account hash.";
    }] ++ lib.mapAttrsToList (name: instance: {
      assertion = builtins.match "[a-zA-Z0-9_-]{1,48}" name != null
        && builtins.match "[a-zA-Z0-9_-]{1,64}" instance.producerUser != null
        && builtins.match "[a-zA-Z0-9_.@-]{1,120}\\.service" instance.producerUnit != null;
      message = "Request recorder ${name} requires a bounded instance name, account and exact .service unit.";
    }) active ++ lib.mapAttrsToList (name: instance: {
      assertion = builtins.length (lib.filter (other: other.producerUnit == instance.producerUnit
        && other.environmentSuffix == instance.environmentSuffix) (builtins.attrValues active)) == 1;
      message = "Request recorder ${name} shares ${instance.producerUnit} with another source; give each source in one unit a distinct environmentSuffix.";
    }) active;
    users.groups = lib.mkMerge (lib.mapAttrsToList (name: _: {
      ${group name} = {};
      ${sourceGroup name} = {};
    }) active);
    users.users = lib.mapAttrs' (name: _: lib.nameValuePair (user name) {
      isSystemUser = true; group = sourceGroup name; extraGroups = [ (group name) ];
    }) active;
    systemd.tmpfiles.rules = lib.mapAttrsToList (name: _:
      "d /run/${runtime name} 2750 ${user name} ${group name} -"
    ) active;
    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: instance: {
      "overalls-request-${name}" = {
        description = "Durable ${instance.source} request admission recorder";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = lib.escapeShellArgs [ "${instance.package}/bin/slo_recorder" instance.source
            "/var/lib/${runtime name}" "/run/${runtime name}/recorder.sock"
            "/run/${runtime name}-source/slo.json" "640" instance.producerUser instance.producerUnit
            (toString instance.deadlineSeconds) ];
          User = user name; Group = sourceGroup name;
          StateDirectory = runtime name; StateDirectoryMode = "0700";
          # systemd reapplies primary-group custody before every command. Keep
          # the setgid RPC directory in tmpfiles so those resets cannot change it.
          RuntimeDirectory = "${runtime name}-source"; RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = "yes";
          ReadWritePaths = [ "/run/${runtime name}" ];
          Restart = "always"; RestartSec = 1;
          UMask = "0027"; NoNewPrivileges = true; ProtectSystem = "strict";
          ProtectHome = true; PrivateTmp = true; PrivateDevices = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          CapabilityBoundingSet = []; MemoryMax = "128M"; TasksMax = 8;
        };
      };
      ${lib.removeSuffix ".service" instance.producerUnit} = {
        wants = [ "overalls-request-${name}.service" ];
        after = [ "overalls-request-${name}.service" ];
        environment = {
          "OVERALLS_REQUEST_ACCOUNTING_SOCKET${instance.environmentSuffix}" = "/run/${runtime name}/recorder.sock";
          "OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY${instance.environmentSuffix}" = "/var/lib/${runtime name}-producer/marker";
        };
        serviceConfig = {
          SupplementaryGroups = [ (group name) ];
          StateDirectory = [ "${runtime name}-producer" ];
          StateDirectoryMode = "0700";
          # The inner directory stays a real directory when DynamicUser makes
          # the StateDirectory entry a symlink into systemd's private storage.
          ExecStartPre = [ "${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/${runtime name}-producer/marker" ];
        };
      };
    }) active);
  };
}
