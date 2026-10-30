{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsAutoUpdate;
  localTypes = import ../types.nix { inherit lib; };
  marshall = config.services.marshall or { enable = false; };
  mailEnvironment = import ../smtp-relay/environment.nix { inherit lib; cfg = marshall.smtpRelay or { enable = false; }; };
  relayUnits = lib.optional (marshall.smtpRelay.enable or false) "overalls-smtprelay.service";
  lilly = config.services.lilly or { enable = false; };
  porsche = config.services.porsche or { enable = false; };
  audi = config.services.audi or { enable = false; };
  audiDns = config.services.audiDns or { enable = false; };
  audiPrivate = config.services.audiPrivate or { enable = false; };
  ziggy = config.services.ziggy or { enable = false; };
  galileo = config.services.galileo or { enable = false; };
  peach = config.services.peach or { enable = false; };
  enrico = config.services.enrico or { enable = false; };
  brady = config.services.brady or { enable = false; };
  underclass = config.services.underclass or { enable = false; tailscaleServe.enable = false; };
  underclassUnits = lib.optionals underclass.enable ([ "underclass.service" ]
    ++ lib.optional underclass.tailscaleServe.enable "underclass-tailscale-serve.service"
    ++ lib.optional (underclass.egress.enable or false) "underclass-egress.service");
  privateUnits = lib.optional audiPrivate.enable "audi-private.service"
    ++ lib.optional ziggy.enable "ziggy.service"
    ++ lib.optional galileo.enable "galileo.service"
    ++ lib.optional peach.enable "peach.service";
  enricoUnits = lib.optional enrico.enable "enrico.service";
  bradyUnits = lib.optional brady.enable "brady.service";
  activationSocketServices = map (socket:
    "${lib.removeSuffix ".socket" socket}.service") cfg.activationSockets;
  audiUnits = lib.optional audi.enable "audi.service" ++ lib.optional audiDns.enable "audi-dns.service";
  descriptors = config.services.overallsSecrets.descriptors or {};
  marshallUnits = lib.optionals marshall.enable
    (map (name: "marshall-${name}.service") (builtins.attrNames marshall.instances));
  secretUnits = map (name: "overalls-secrets-${name}.service") (builtins.attrNames descriptors);
  dependents = units: map (item: item.key) (lib.filter
    (item: !(builtins.elem item.key units))
    (builtins.genericClosure {
      startSet = map (key: { inherit key; }) units;
      operator = item: map (name: { key = "${name}.service"; })
        (lib.attrNames (lib.filterAttrs (name: unit:
          unit.enable && name != "overalls-auto-update" && builtins.elem item.key
            (unit.requires ++ unit.bindsTo ++ unit.partOf)
        ) config.systemd.services));
    }));
  secretConsumers = dependents secretUnits;
  # Which consumers each secret bundle feeds, so activation restarts only the
  # consumers of a bundle whose contents changed (ADR-0036, 2026-10-13).
  bundleConsumers = lib.mapAttrs (name: _: dependents [ "overalls-secrets-${name}.service" ]) descriptors;
  # Consumers that require, bind to or are part of each consumer, so a unit
  # that restarts takes its dependents (and their activation sockets) down
  # deliberately before the switch: a retained socket-activated dependent
  # would otherwise pull the stopped unit back up through Requires= on the
  # next connection during the stop phase (overalls, 2026-10-13).
  consumerDependents = lib.genAttrs consumers (unit:
    lib.filter (name: builtins.elem name consumers) (dependents [ unit ]));
  consumers = lib.unique (marshallUnits ++ relayUnits ++ lib.optional lilly.enable "lilly.service"
    ++ lib.optional porsche.enable "porsche.service" ++ audiUnits ++ privateUnits
    ++ enricoUnits ++ bradyUnits ++ underclassUnits ++ secretConsumers ++ activationSocketServices);
  migration = pkgs.writeShellScript "overalls-candidate-migrate" ''
    exec ${pkgs.coreutils}/bin/env -u PORT -u MARSHALL_TLS_CERTFILE -u MARSHALL_TLS_KEYFILE \
      ${mailEnvironment}      PHX_SERVER=false RELEASE_DISTRIBUTION=none RELEASE_COOKIE=deploymentmigration \
      ${lib.optionalString (marshall.crashDumps.enable or false) "ERL_CRASH_DUMP_PUBLIC_KEY=${lib.escapeShellArg marshall.crashDumps.publicKeyFile}"} \
      RELEASE_TMP=/run/overalls-migration ERL_CRASH_DUMP=/dev/null \
      PHX_HOST=${lib.escapeShellArg marshall.publicHost} MARSHALL_INSTANCE_ID=deployment-migration \
      MARSHALL_REPLICA_COUNT=${toString marshall.replicaCount} \
      MARSHALL_DB_CONNECTION_BUDGET=${toString marshall.databaseConnectionBudget} \
      POOL_SIZE=2 MARSHALL_DB_TLS=verify \
      MARSHALL_DB_CA_CERTFILE="$CREDENTIALS_DIRECTORY/database-ca.crt" \
      ${marshall.package}/bin/marshall eval 'Marshall.Vault.keyring!(System.fetch_env!("MARSHALL_CLOAK_KEYS")); Marshall.Operations.Migrate.main()'
  '';
  manifest = pkgs.writeText "overalls-deployment.json" (builtins.toJSON {
    version = 1;
    installationBinding = cfg.installationBinding;
    resourcePolicy = cfg.resourcePolicy;
    diagnosticPreflight = map (app: [
      "${pkgs.python3}/bin/python" "${../crash-dumps/runtime.py}" "check" "/unused"
      app.crashDumps.publicKeyFile "${app.package}/overalls-release.json" "${pkgs.openssl}/bin/openssl"
    ]) (lib.filter (app: app.enable && (app.crashDumps.enable or false)) [ marshall lilly porsche ]);
    secrets = descriptors;
    inherit consumers bundleConsumers consumerDependents;
    socketUnits = cfg.activationSockets;
    healthUnits = marshallUnits ++ relayUnits ++ lib.optionals lilly.enable [ "lilly-hostd.service" "lilly.service" ]
      ++ lib.optional porsche.enable "porsche.service" ++ audiUnits ++ privateUnits ++ enricoUnits ++ bradyUnits ++ underclassUnits;
    enrico = if !enrico.enable then null else { statusSocket = "/run/enrico/status.sock"; };
    audi = lib.optional audi.enable { role = "gateway"; statusSocket = "/run/audi/status.sock"; }
      ++ lib.optional audiDns.enable { role = "dns"; statusSocket = "/run/audi-dns/status.sock"; }
      ++ lib.optional audiPrivate.enable { role = "private"; statusSocket = "/run/audi-private/status.sock"; };
    ziggy = if !ziggy.enable then null else { socket = "/run/ziggy/proxy.sock"; hostId = ziggy.hostId; };
    porsche = if !porsche.enable then null else { statusSocket = "/run/porsche/status.sock"; };
    marshall = if !marshall.enable then null else {
      inherit (marshall) environmentFile databaseCAFile;
      migrate = migration;
      instances = lib.mapAttrsToList (name: instance:
        let
          check = cfg.marshallHealth.${name} or {};
          host = check.serverName or marshall.publicHost;
          configuredAddress = instance.bindAddress;
          address = if configuredAddress == "0.0.0.0" then "127.0.0.1" else configuredAddress;
        in {
          caFile = check.caFile or instance.certificateFile;
          resolve = "${host}:${toString instance.port}:${address}";
          url = "https://${host}:${toString instance.port}/health/ready";
        }) marshall.instances;
    };
    lilly = if !lilly.enable then null else {
      inherit (lilly) credentialFile hostId;
      release = lilly.package;
      transferStateDirectory = config.services.lillyTransfer.stateDirectory;
      crashDumpPublicKey = if lilly.crashDumps.enable then lilly.crashDumps.publicKeyFile else null;
      binding = {
        inherit (lilly) hostId stateDirectory vmStateDirectory networkStateDirectory
          egressInterface protectedCidrs protectedAddressFiles pools guestCpuCores guestMemoryMiB;
      };
      owner = {
        host_id = lilly.hostId;
        state_dir = lilly.stateDirectory;
        vm_state_dir = lilly.vmStateDirectory;
        network_state_dir = lilly.networkStateDirectory;
        pools = lib.sort (a: b: a.id < b.id) (map (pool: {
          inherit (pool) id path filesystem_id storage;
        }) lilly.pools);
      };
    };
  });
  configuration = pkgs.writeText "overalls-auto-update.json" (builtins.toJSON {
    inherit (cfg) repository branch flakeAttr healthTimeout buildTimeout verbose secretUnits remoteCache;
    secretHelper = "${../secrets/prepare.py}";
    resourcePolicyHelper = "${./resources.py}";
  });
  python = pkgs.python3;
  # git, Nix, bash and findutils run the candidate's tools/buck2, which
  # realises the candidate's pinned buck2 and cells (ADR-0271).
  commandPath = lib.makeBinPath [ pkgs.git pkgs.nix pkgs.nixos-rebuild pkgs.openssh
    pkgs.systemd pkgs.curl pkgs.coreutils pkgs.bash pkgs.findutils config.boot.zfs.package python ];
  runner = pkgs.writeShellScriptBin "overalls-auto-update" ''
    export PATH=${commandPath}
    exec ${python}/bin/python ${./runtime.py} "$@"
  '';
in
{
  options.services.overallsAutoUpdate = {
    enable = mkEnableOption "independent Git-driven host updates with migration and health verification";
    installationBinding = mkOption { type = types.nullOr types.attrs; default = null; description = "Immutable platform, disk and persistent identity bindings."; };
    resourcePolicy = mkOption { type = types.nullOr types.attrs; default = null; description = "Reviewed live CPU/RAM/quota tuning, bound to immutable storage identity."; };
    enrollmentReceipt = mkOption { type = types.nullOr localTypes.privatePath; default = null; description = "Host-tool receipt required before polling."; };
    repository = mkOption {
      type = types.strMatching "(https://[A-Za-z0-9./:_-]+|ssh://[A-Za-z0-9@./:_-]+|[A-Za-z0-9_-]+@[A-Za-z0-9.-]+:[A-Za-z0-9./_-]+|/[^[:space:]]+)";
      description = "Trusted Git repository. HTTPS credentials in URLs are forbidden; local paths support isolated fixtures.";
    };
    branch = mkOption { type = types.strMatching "[A-Za-z0-9][A-Za-z0-9._/-]*"; default = "main"; };
    flakeAttr = mkOption { type = localTypes.identifier; description = "Fleet host name; the updater builds //fleet/hosts/<name>:deployment (ADR-0271)."; };
    interval = mkOption { type = types.strMatching "[1-9][0-9]*(s|min|h)"; default = "10s"; };
    healthTimeout = mkOption { type = types.ints.between 10 1800; default = 120; };
    buildTimeout = mkOption { type = types.ints.between 30 10800; default = 7200; description = "Seconds before a candidate build is stopped, its Buck2 daemon included."; };
    verbose = mkOption { type = types.bool; default = false; description = "Retain verbose build output in the private attempt log."; };
    remoteCache = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          address = mkOption { type = localTypes.ipv4; description = "Tailnet IPv4 address of the NativeLink cache."; };
          port = mkOption { type = types.port; description = "The cache's read-only listener."; };
          instanceName = mkOption { type = types.strMatching "[A-Za-z0-9_-]{1,64}"; default = "main"; };
          caCertificate = mkOption { type = localTypes.absolutePath; description = "Public CA that issued the cache server certificate."; };
          clientIdentity = mkOption { type = localTypes.absolutePath; description = "Decrypted read-only client certificate and key; absent means local builds."; };
        };
      });
      default = null;
      description = "Read-only Buck2 cache for candidate builds (ADR-0272). Used only while the identity exists and the cache answers; otherwise builds are local.";
    };
    sshKeyFile = mkOption { type = types.nullOr localTypes.privatePath; default = null; };
    knownHostsFile = mkOption { type = localTypes.absolutePath; default = "/etc/ssh/ssh_known_hosts"; };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Current-generation preparation dependencies for Git authentication.";
    };
    activationSockets = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.socket");
      default = [];
      description = "Socket activators to quiesce before stopping consumers and restore after activation.";
    };
    marshallHealth = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          serverName = mkOption { type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*"; };
          caFile = mkOption { type = localTypes.absolutePath; };
        };
      });
      default = {};
      description = "Per-instance TLS health overrides; default uses publicHost and the configured certificate as trust anchor.";
    };
  };

  config = lib.mkMerge [
    (mkIf (cfg.resourcePolicy != null) {
      systemd.services.overalls-resource-policy = {
        description = "Apply reviewed guest limits without restarting guests";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs-mount.service" "lilly.slice" ];
        requires = [ "lilly.slice" ];
        before = [ "lilly.service" ];
        # Its ExecStart names the deployment manifest, which changes with every
        # release; a switch-time restart of this oneshot would stop Lilly (which
        # requires it) by propagation. The updater applies the policy itself
        # after every switch and the unit still runs at boot (ADR-0165).
        restartIfChanged = false;
        stopIfChanged = false;
        path = [ pkgs.systemd config.boot.zfs.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${python}/bin/python ${./resources.py} ${manifest}";
        };
      };
      systemd.services.lilly.requires = [ "overalls-resource-policy.service" ];
    })
    {
      # @cc [owner:ghuntley,label:deployment] deployment-descriptor-baseline
      # Every imported host MUST retain its public deployment descriptor in its
      # system closure, including while polling is disabled. Secrets remain runtime
      # paths; candidate bundles MUST bind this descriptor to the exact system.
      # overallsDeployment is the output of //fleet/hosts/<host>:deployment, the
      # only bundle the updater activates (revised for ADR-0271: it was the
      # nixosConfigurations attribute the updater built).
      system.systemBuilderCommands = ''
        ln -s ${manifest} $out/overalls-deployment.json
      '';
      system.build.overallsHostEnrollment = pkgs.writeShellScript "overalls-host-enroll" ''
        exec ${pkgs.systemd}/bin/systemd-run --unit=overalls-host-enrollment --wait --pipe --collect \
          --property=Type=exec --property=UMask=0077 --property=RuntimeMaxSec=3h \
          --property=ExecStopPost=${lib.escapeShellArg "${runner}/bin/overalls-auto-update --cleanup ${configuration}"} \
          ${pkgs.writeShellScript "overalls-enrollment-runtime" ''
            export PATH=${lib.makeBinPath [ pkgs.util-linux config.boot.zfs.package pkgs.iproute2 ]}:${commandPath}
            exec ${python}/bin/python ${../../artifacts/host/enrollment.py} ${./runtime.py} ${configuration} ${config.system.build.overallsDeployment} ${../../artifacts/host/remote.py} "$@"
          ''} "$@"
      '';
      system.build.overallsDeployment = pkgs.runCommand "overalls-deployment" {} ''
        mkdir -p "$out"
        ln -s ${config.system.build.toplevel} "$out/system"
        ln -s ${manifest} "$out/manifest.json"
      '';
    }
    (mkIf cfg.enable {
      assertions = [
        { assertion = lib.all (socket:
            builtins.hasAttr (lib.removeSuffix ".socket" socket) config.systemd.sockets)
            cfg.activationSockets;
          message = "Every updater activation socket must name a declared systemd socket."; }
        { assertion = !marshall.enable || marshall.databaseConnectionBudget >= marshall.replicaCount * (marshall.poolSize + 3) + 10;
          message = "Automatic Marshall updates require serving pools, two migration connections per replica and ten operator connections."; }
        { assertion = !config.system.autoUpgrade.enable;
          message = "overallsAutoUpdate and system.autoUpgrade must not compete for activation."; }
        { assertion = lib.all (name: marshall.enable && builtins.hasAttr name marshall.instances) (builtins.attrNames cfg.marshallHealth);
          message = "Every Marshall health override must name a configured local instance."; }
      ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      environment.systemPackages = [ runner ];
      systemd.services.overalls-auto-update = {
        description = "Build, migrate, activate and verify the selected Git revision";
        wants = [ "network-online.target" ] ++ cfg.secretUnits;
        after = [ "network-online.target" ] ++ cfg.secretUnits;
        unitConfig = lib.optionalAttrs (cfg.enrollmentReceipt != null) { ConditionPathExists = cfg.enrollmentReceipt; };
        restartIfChanged = false;
        stopIfChanged = false;
        # @cc [owner:ghuntley,label:isolation;recovery] update-builds-use-isolated-daemon
        # Root would otherwise build in the local store from this service's
        # namespace, whose sandboxes take locked copies of guest dataset mounts
        # and stall fenced deletion (ADR-0144). Builds MUST go through nix-daemon,
        # including the Nix actions of the updater's Buck2 daemon: the updater
        # restarts buckd before each build so it inherits this environment
        # (revised for ADR-0271).
        environment = {
          NIX_REMOTE = "daemon";
          GIT_SSH_COMMAND = "${pkgs.openssh}/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ${lib.escapeShellArg "UserKnownHostsFile=${cfg.knownHostsFile}"}"
            + lib.optionalString (cfg.sshKeyFile != null) " -o IdentitiesOnly=yes -i ${lib.escapeShellArg cfg.sshKeyFile}";
        };
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          UMask = "0077";
          StateDirectory = "overalls-auto-update";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "overalls-auto-update";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = "yes";
          ExecStart = "${runner}/bin/overalls-auto-update ${configuration}";
          ExecStopPost = "${runner}/bin/overalls-auto-update --cleanup ${configuration}";
          TimeoutStartSec = "3h";
        };
      };
      systemd.timers.overalls-auto-update = {
        wantedBy = [ "timers.target" ];
        unitConfig = lib.optionalAttrs (cfg.enrollmentReceipt != null) { ConditionPathExists = cfg.enrollmentReceipt; };
        timerConfig = {
          OnBootSec = cfg.interval;
          OnUnitInactiveSec = cfg.interval;
          RandomizedDelaySec = "300s";
          AccuracySec = "1s";
        };
      };
    })
  ];
}
