{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.overalls.buckRemoteCache;
  server = cfg.server;
  execution = server.execution;
  client = cfg.client;
  worker = cfg.worker;
  addressType = types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
  localTypes = import ./types.nix { inherit lib; };
  bundle = config.services.overallsSecrets.bundles.buck-re;
  secretFile = name: "${bundle.directory}/${name}";
  stateDirectory = "/var/lib/nativelink";
  instance = "main";
  # Lilly guest datasets never enter the server's view (ADR-0144).
  poolPaths = map (pool: pool.path) (config.services.lilly.pools or []);
  filesystem = name: maxBytes: {
    filesystem = {
      content_path = "${stateDirectory}/${name}/content";
      temp_path = "${stateDirectory}/${name}/tmp";
      eviction_policy.max_bytes = maxBytes;
    };
  };
  listener = port: clientCa: {
    http = {
      socket_address = "${server.listenAddress}:${toString port}";
      # Bind the tailnet address even before tailscaled has assigned it, so
      # the listener never falls back to a wildcard address.
      freebind = true;
      tls = {
        cert_file = "${server.certificate}";
        key_file = "$CREDENTIALS_DIRECTORY/server.key";
        client_ca_file = "${clientCa}";
      };
    };
  };
  scheduler = "MAIN";
  # The one platform property actions carry (buck/platforms.bzl): the
  # buckCells id, so an action runs only where its toolchains exist.
  cellsProperty = "overalls-cells";
  services = { cas, acReadOnly, execute ? false }: {
    cas = [ { instance_name = instance; cas_store = cas; } ];
    bytestream = [ { instance_name = instance; cas_store = cas; } ];
    ac = [ { instance_name = instance; ac_store = "AC"; read_only = acReadOnly; } ];
    capabilities = [ ({ instance_name = instance; }
      // lib.optionalAttrs execute { remote_execution.scheduler = scheduler; }) ];
  } // lib.optionalAttrs execute {
    execution = [ { instance_name = instance; cas_store = cas; inherit scheduler; } ];
  };
  # One process, one store set, one mTLS listener per CA. NativeLink cannot
  # authorise per certificate, so each listener trusts one CA: the reader CA
  # signs host certificates, the uploader CA only the CI certificate, the
  # executor CA developer certificates and the worker CA worker certificates.
  serverConfig = (pkgs.formats.json {}).generate "nativelink.json" ({
    stores = [
      { name = "CAS"; verify = { backend = filesystem "cas" server.casMaxBytes; verify_size = true; verify_hash = true; }; }
      ({ name = "AC"; } // filesystem "ac" server.acMaxBytes)
      # Reads reach the shared CAS; writes are discarded, never persisted.
      { name = "CAS_READ_ONLY"; fast_slow = {
          fast.noop = {};
          slow.ref_store.name = "CAS";
          slow_direction = "read_only";
        }; }
    ];
    servers = [
      { name = "read"; listener = listener server.readPort server.readerCaCertificate;
        services = services { cas = "CAS_READ_ONLY"; acReadOnly = true; }; }
      { name = "upload"; listener = listener server.uploadPort server.uploaderCaCertificate;
        services = services { cas = "CAS"; acReadOnly = false; execute = execution.enable; }; }
    ] ++ lib.optionals execution.enable [
      # Developers execute and upload inputs, but never write the action
      # cache: only workers (and CI) record results.
      { name = "execute"; listener = listener execution.executePort execution.executorCaCertificate;
        services = services { cas = "CAS"; acReadOnly = true; execute = true; }; }
      { name = "worker"; listener = listener execution.workerPort execution.workerCaCertificate;
        services = services { cas = "CAS"; acReadOnly = false; } // { worker_api.scheduler = scheduler; }; }
    ];
    global = { max_open_files = 4096; default_digest_hash_function = "sha256"; };
  } // lib.optionalAttrs execution.enable {
    schedulers = [ { name = scheduler; simple = {
      supported_platform_properties.${cellsProperty} = "exact";
      # An action no connected worker can run (another cells id) or one
      # queued with no worker at all fails, so the client falls back to
      # local execution instead of waiting (ADR-0272).
      unsatisfiable_action_timeout_s = execution.unmatchedTimeout;
      no_worker_action_timeout_s = execution.unmatchedTimeout;
    }; } ];
  });
  workerBundle = config.services.overallsSecrets.bundles.buck-re-worker;
  workerState = "/var/lib/nativelink-worker";
  cellsState = "/var/lib/nativelink-worker-cells";
  workerRuntime = "/run/nativelink-worker";
  # Action directories: the worker creates them, the action user writes in
  # them through the shared group, and neither reaches the other's state.
  workRoot = "/var/lib/nativelink-worker-work";
  workDirectory = "${workRoot}/work";
  # A private tmpfs in the worker's namespace, not mounted nosuid, holding the
  # one binary that carries capabilities there.
  sandboxDirectory = "/run/nativelink-worker-exec";
  sandboxBinary = "${sandboxDirectory}/action-sandbox";
  actionSandbox = pkgs.runCommandCC "buck-re-action-sandbox" { } ''
    mkdir -p $out/bin
    $CC -std=c11 -O2 -Wall -Wextra -Werror \
      -DWORK_ROOT='"${workDirectory}"' -DWORKER_USER='"nativelink-worker"' -DACTION_USER='"nativelink-action"' \
      -DHIDDEN_PATHS='${lib.concatMapStringsSep "," (path: ''"${path}"'') [ workerState workerRuntime sandboxDirectory ]}' \
      ${./buck-re-action-sandbox.c} -o $out/bin/buck-re-action-sandbox
  '';
  workerIdentity = "${workerRuntime}/identity.pem";
  workerTls = { ca_file = "${worker.caCertificate}"; cert_file = workerIdentity; key_file = workerIdentity; };
  remoteStore = storeType: { grpc = {
    instance_name = instance;
    endpoints = [ { address = "grpcs://${worker.schedulerAddress}:${toString worker.port}"; tls_config = workerTls; } ];
    store_type = storeType;
  }; };
  workerConfig = (pkgs.formats.json {}).generate "nativelink-worker.json" {
    stores = [
      ({ name = "REMOTE_CAS"; } // remoteStore "cas")
      ({ name = "REMOTE_AC"; } // remoteStore "ac")
      # Inputs are hardlinked (0444/0555, owned by the worker) from the fast
      # store into each action directory, so both live on /var/lib.
      { name = "WORKER_CAS"; fast_slow = {
          fast.filesystem = {
            content_path = "${workerState}/cas/content";
            temp_path = "${workerState}/cas/tmp";
            eviction_policy.max_bytes = worker.casMaxBytes;
          };
          slow.ref_store.name = "REMOTE_CAS";
        }; }
    ];
    workers = [ { local = {
      name = "${config.networking.hostName}-";
      worker_api_endpoint = { uri = "grpcs://${worker.schedulerAddress}:${toString worker.port}"; tls_config = workerTls; };
      cas_fast_slow_store = "WORKER_CAS";
      upload_action_result.ac_store = "REMOTE_AC";
      work_directory = workDirectory;
      # Every action runs through the sandbox as the action user, never as
      # the worker that holds the identity (ADR-0272).
      entrypoint = sandboxBinary;
      max_inflight_tasks = worker.maxInflightTasks;
      # Set by the start script from the published cells id.
      platform_properties.${cellsProperty}.values = [ "$OVERALLS_CELLS_ID" ];
    }; } ];
    servers = [];
    global = { max_open_files = 4096; default_digest_hash_function = "sha256"; };
  };
  # Publish the id of one buckCells closure this host holds, and root it, so
  # the worker advertises only toolchains that exist here. The first source
  # is the host updater's checkout, whose tools/buck2 realised the deployed
  # revision's cells from Cachix; `cells` are fixed store paths.
  publishCells = pkgs.writeShellScript "nativelink-worker-cells" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused config.nix.package pkgs.systemd ]}
    previous=$(cat ${cellsState}/id 2>/dev/null || true)
    found=
    for source in ${lib.escapeShellArgs (worker.cellsLinks ++ map toString worker.cells)}; do
      path=$(readlink -f "$source" 2>/dev/null) || continue
      case "$path" in /nix/store/*) ;; *) continue ;; esac
      # Substitutes the closure from the signed cache if it was collected.
      nix-store --realise "$path" >/dev/null 2>&1 || continue
      id=$(sed -n 's/^  cells_id = \([0-9a-f]\{64\}\)$/\1/p' "$path/toolchains.buckconfig" 2>/dev/null || true)
      [ -n "$id" ] || continue
      nix-store --add-root ${cellsState}/cells --realise "$path" >/dev/null
      found=$id
      break
    done
    if [ -n "$found" ]; then
      printf '%s\n' "$found" > ${cellsState}/id.new
      mv ${cellsState}/id.new ${cellsState}/id
    else
      rm -f ${cellsState}/id ${cellsState}/cells
    fi
    # Workers read their properties when they start.
    if [ "$found" != "$previous" ]; then
      systemctl --no-block restart nativelink-worker.service
    fi
  '';
  # ADR-0144: the worker runs in its own mount namespace, from which this
  # script (as root) first removes every Lilly pool mount, so later guest
  # dataset mounts have no parent to propagate into and actions never pin
  # one. It then drops to the worker user with no capabilities.
  # Host state the worker never sees (ADR-0144): Lilly's control state and
  # sockets, guest runtime, every secret bundle and the SOPS host identity.
  workerHiddenPaths = lib.unique ([
    "/run/overalls-secrets" "/etc/ssh" "/var/lib/overalls-auto-update"
    "/run/lilly" "/run/lilly-hostd" "/run/lilly-clone-copies" "/run/lilly-ingress" "/run/lilly-brady"
    "/run/lilly-inception" "/run/lilly-transfer" "/run/lilly-release" "/run/audi-private" "/run/ziggy"
    "/run/overalls-backups" "/var/lib/lilly" "/var/lib/lilly-crash-dumps" "/var/lib/overalls-firecracker"
  ] ++ lib.optionals (config.services.lilly.enable or false) [
    config.services.lilly.stateDirectory config.services.lilly.vmStateDirectory config.services.lilly.networkStateDirectory
  ]);
  startWorker = pkgs.writeShellScript "nativelink-worker-start" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.gnugrep pkgs.gawk pkgs.libcap ]}
    # Stop host mount propagation first: a pool or guest dataset mounted
    # after the worker starts must never appear in its namespace.
    mount --make-rprivate /
    # Fail closed: a worker never serves while a pool is still mounted here.
    ${lib.concatMapStringsSep "\n" (path: ''
      # Detaching the pool can leave its children reattached, and the
      # namespace's setup can stack copies; remove what remains, deepest
      # first, until nothing at or under the pool is mounted.
      for _ in $(seq 16); do
        points=$(awk -v p=${lib.escapeShellArg path} '$5 == p || index($5, p "/") == 1 { print $5 }' /proc/self/mountinfo | sort -r)
        [ -n "$points" ] || break
        for point in $points; do umount --lazy "$point" 2>/dev/null || true; done
      done
      if grep -q " ${path}[/ ]" /proc/self/mountinfo; then
        echo "nativelink-worker: ${path} is still mounted" >&2
        grep " ${path}[/ ]" /proc/self/mountinfo >&2
        exit 1
      fi'') worker.excludedMounts}
    OVERALLS_CELLS_ID=$(cat ${cellsState}/id)
    export OVERALLS_CELLS_ID
    install -m 0400 "$CREDENTIALS_DIRECTORY/worker.pem" ${workerIdentity}
    chown nativelink-worker:nativelink-worker ${workerIdentity} ${workerRuntime}
    # An action killed mid-run can leave files the worker cannot remove.
    rm -rf ${workDirectory}
    # The sandbox is the only file here that grants capabilities, and only
    # the worker's group may run it. The tmpfs lives in this namespace alone.
    worker_gid=$(id -g nativelink-worker)
    mount -t tmpfs -o "mode=0750,uid=0,gid=$worker_gid,nodev,size=4m" nativelink-worker-exec ${sandboxDirectory}
    install -m 0750 -o root -g "$worker_gid" ${actionSandbox}/bin/buck-re-action-sandbox ${sandboxBinary}
    setcap cap_setuid,cap_setgid,cap_sys_admin+ep ${sandboxBinary}
    # Directories the worker creates are group-writable for the action user.
    umask 0007
    # No capabilities and no no_new_privs: the worker gains the bounding
    # set's three only by running the sandbox, which drops to the action
    # user. Setuid wrappers are not visible in this namespace.
    exec setpriv --reuid=nativelink-worker --regid=nativelink-worker --init-groups \
      --inh-caps=-all --bounding-set=-all,+setuid,+setgid,+sys_admin \
      -- ${lib.getExe packages.nativelink} ${workerConfig}
  '';
  # Buck2 reads root's ~/.buckconfig.d but ignores symlinks and includes
  # there, so the unit installs a regular file, and only while the identity
  # exists: a missing bundle means local execution, not a broken client.
  # Other users' builds on the host are unaffected.
  rootConfig = "/root/.buckconfig.d/overalls-remote-cache";
  serverPorts = [ server.readPort server.uploadPort ]
    ++ lib.optionals execution.enable [ execution.executePort execution.workerPort ];
  clientConfig = pkgs.writeText "overalls-remote-cache.buckconfig" ''
    # Read-only NativeLink cache (ADR-0272). Installed by the buck-re module.
    [buck2_re_client]
      address = grpc://${client.address}:${toString client.readPort}
      tls = true
      instance_name = ${instance}
      tls_ca_certs = ${client.caCertificate}
      tls_client_cert = ${secretFile "client.pem"}
  '';
  publishClient = pkgs.writeShellScript "overalls-buck-re-client" ''
    set -eu
    if [ -s ${secretFile "client.pem"} ]; then
      ${pkgs.coreutils}/bin/install -D -m 0600 ${clientConfig} ${rootConfig}
    else
      ${pkgs.coreutils}/bin/rm -f ${rootConfig}
    fi
  '';
in {
  options.overalls.buckRemoteCache = {
    encryptedFile = mkOption {
      type = types.nullOr localTypes.absolutePath;
      default = null;
      description = "This host's SOPS document holding its buck-re server key and/or client identity.";
    };
    server = {
      enable = mkEnableOption "the NativeLink Buck2 remote cache (CAS and action cache) on the tailnet";
      listenAddress = mkOption { type = addressType; description = "Tailnet IPv4 address the listeners bind; the server certificate's IP SAN."; };
      interface = mkOption { type = types.strMatching "[a-zA-Z0-9_.-]+"; default = "tailscale0"; description = "The only non-loopback interface the server may use."; };
      readPort = mkOption { type = types.port; default = 50071; };
      uploadPort = mkOption { type = types.port; default = 50072; };
      certificate = mkOption { type = types.path; description = "Public server certificate, issued by the reader CA."; };
      readerCaCertificate = mkOption { type = types.path; description = "Public CA for read-only host clients; also the server's issuer."; };
      uploaderCaCertificate = mkOption { type = types.path; description = "Public CA that signs only the CI uploader certificate."; };
      casMaxBytes = mkOption { type = types.ints.positive; default = 200 * 1024 * 1024 * 1024; };
      acMaxBytes = mkOption { type = types.ints.positive; default = 2 * 1024 * 1024 * 1024; };
      execution = {
        enable = mkEnableOption "the NativeLink remote-execution scheduler (M10)";
        executePort = mkOption { type = types.port; default = 50073; description = "Developer listener: execute and upload inputs; the action cache is read-only."; };
        workerPort = mkOption { type = types.port; default = 50074; description = "Worker listener: the worker API, CAS and action cache."; };
        executorCaCertificate = mkOption { type = types.path; description = "Public CA that signs developer remote-execution certificates."; };
        workerCaCertificate = mkOption { type = types.path; description = "Public CA that signs worker certificates."; };
        unmatchedTimeout = mkOption { type = types.ints.positive; default = 15; description = "Seconds before an action no worker can run fails, so the client builds it locally."; };
      };
    };
    worker = {
      enable = mkEnableOption "a NativeLink remote-execution worker in the ADR-0144 pool-mount-free namespace";
      encryptedFile = mkOption { type = types.nullOr localTypes.absolutePath; default = null; description = "This host's SOPS document holding its worker identity."; };
      schedulerAddress = mkOption { type = addressType; description = "Tailnet IPv4 address of the scheduler."; };
      port = mkOption { type = types.port; default = 50074; };
      caCertificate = mkOption { type = types.path; description = "Public CA that issued the scheduler's server certificate."; };
      interface = mkOption { type = types.strMatching "[a-zA-Z0-9_.-]+"; default = "tailscale0"; description = "The only non-loopback interface the worker and its actions may use."; };
      maxInflightTasks = mkOption { type = types.ints.positive; default = 4; };
      casMaxBytes = mkOption { type = types.ints.positive; default = 50 * 1024 * 1024 * 1024; };
      cellsLinks = mkOption {
        type = types.listOf localTypes.absolutePath;
        default = [ "/var/lib/overalls-auto-update/checkout/.buck-cells" ];
        description = "Links to buckCells closures to advertise, first match wins; the default is the updater checkout's.";
      };
      cells = mkOption { type = types.listOf types.path; default = []; description = "Fixed buckCells store paths, tried after cellsLinks."; };
      excludedMounts = mkOption {
        type = types.listOf localTypes.absolutePath;
        default = poolPaths;
        defaultText = "every Lilly pool path";
        description = "Mounts removed from the worker's namespace before it starts (ADR-0144).";
      };
      # Guests come first: the worker's cgroup is capped so builds cannot
      # starve guests or delay Lilly's capacity reports.
      cpuQuota = mkOption {
        type = types.strMatching "[1-9][0-9]*%";
        default = "${toString (worker.maxInflightTasks * 100)}%";
        defaultText = "100% per in-flight task";
        description = "systemd CPUQuota for the worker cgroup.";
      };
      memoryHigh = mkOption { type = types.strMatching "[1-9][0-9]?%"; default = "20%"; description = "systemd MemoryHigh (throttling) for the worker cgroup."; };
      memoryMax = mkOption { type = types.strMatching "[1-9][0-9]?%"; default = "25%"; description = "systemd MemoryMax (hard limit) for the worker cgroup."; };
      tasksMax = mkOption { type = types.ints.positive; default = 8192; description = "systemd TasksMax for the worker cgroup."; };
    };
    client = {
      enable = mkEnableOption "a read-only Buck2 remote cache client configuration for root";
      address = mkOption { type = addressType; description = "Tailnet IPv4 address of the cache server."; };
      readPort = mkOption { type = types.port; default = 50071; };
      caCertificate = mkOption { type = types.path; description = "Public CA that issued the server certificate."; };
    };
  };

  # @cc [owner:ghuntley,label:security;deployment] buck-remote-cache-tailnet-mtls
  # The NativeLink listeners MUST bind only the configured tailnet address,
  # MUST NOT be opened in any firewall port list, MUST NOT use any interface
  # but loopback and the tailnet, and MUST require a client certificate from
  # the listener's own CA. Only the upload listener, trusting only the
  # uploader CA, MAY write the action cache or persist CAS blobs; host
  # identities, issued by the reader CA, are read-only (ADR-0272).

  # @cc [owner:ghuntley,label:security;isolation] buck-remote-execution-workers
  # Remote-execution listeners MUST follow buck-remote-cache-tailnet-mtls:
  # the executor listener trusts only the executor CA and keeps the action
  # cache read-only, and the worker API trusts only the worker CA. Workers
  # MUST run in their own mount namespace from which every Lilly pool mount is
  # removed before they serve actions and into which no later host mount
  # propagates (ADR-0144), as an unprivileged user without capabilities,
  # reaching only loopback and the scheduler's tailnet address, with no
  # devices and no view of Lilly state, secret bundles or the SSH host
  # identity. Their cgroup MUST be capped (CPU quota, memory high and max, no
  # swap, tasks) below guests and killed first under memory pressure. Actions
  # MUST run through buck-re-action-sandbox, never as the worker user, so the
  # worker identity and store reach only the worker process. They
  # MUST advertise only a buckCells id whose closure is valid and
  # rooted on the host. Unmatched actions MUST fail at the scheduler within
  # unmatchedTimeout so clients fall back to local execution (ADR-0272).

  # @cc [owner:ghuntley,label:recovery] buck-remote-cache-optional
  # A missing or undecryptable buck-re bundle MUST NOT block boot or Buck2:
  # root's client configuration MUST exist only while the identity does, so
  # builds fall back to local execution.
  config = lib.mkMerge [
    (lib.mkIf (server.enable || client.enable) {
      assertions = [
        { assertion = cfg.encryptedFile != null; message = "The buck-re cache requires this host's encrypted document."; }
      ];
      services.overallsSecrets = {
        enable = true;
        bundles.buck-re = {
          encryptedFile = cfg.encryptedFile;
          outputs = lib.optionalAttrs server.enable {
            "server.key" = { format = "raw"; secrets = [ "SERVER_KEY" ]; };
          } // lib.optionalAttrs client.enable {
            "client.pem" = { format = "raw"; secrets = [ "CLIENT_IDENTITY" ]; };
          };
        };
      };
      systemd.services.overalls-secrets-buck-re.wantedBy = [ "multi-user.target" ];
    })

    (lib.mkIf server.enable {
      assertions = [
        { assertion = lib.length (lib.unique serverPorts) == lib.length serverPorts; message = "The buck-re listener ports must differ."; }
        { assertion = lib.all (port: !(lib.elem port config.networking.firewall.allowedTCPPorts)) serverPorts
            && lib.all (iface: lib.all (port: !(lib.elem port (iface.allowedTCPPorts or [])))
                 serverPorts) (lib.attrValues config.networking.firewall.interfaces);
          message = "The buck-re listeners must never be opened in the firewall."; }
        { assertion = !(lib.hasPrefix "0." server.listenAddress) && !(lib.hasPrefix "127." server.listenAddress);
          message = "The buck-re listeners must bind the tailnet address, not a wildcard or loopback."; }
        { assertion = lib.all (path: !(lib.hasPrefix "${path}/" "${stateDirectory}/") && !(lib.hasPrefix "${stateDirectory}/" "${path}/")) poolPaths;
          message = "The buck-re cache storage must be outside every Lilly guest pool (ADR-0144)."; }
      ];

      users.groups.nativelink = {};
      users.users.nativelink = { isSystemUser = true; group = "nativelink"; home = stateDirectory; };

      systemd.services.nativelink = {
        description = "NativeLink Buck2 remote cache (CAS and action cache)";
        wantedBy = [ "multi-user.target" ];
        wants = [ bundle.unit "network-online.target" ];
        after = [ bundle.unit "network-online.target" ];
        restartTriggers = [ serverConfig ];
        serviceConfig = {
          ExecStart = "${lib.getExe packages.nativelink} ${serverConfig}";
          User = "nativelink";
          Group = "nativelink";
          LoadCredential = "server.key:${secretFile "server.key"}";
          StateDirectory = "nativelink";
          StateDirectoryMode = "0700";
          Restart = "on-failure";
          RestartSec = 10;
          LimitNOFILE = 16384;
          # Defence in depth beside the address binding: the process cannot
          # send or receive on any other interface.
          RestrictNetworkInterfaces = [ "lo" server.interface ];
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          InaccessiblePaths = map (path: "-${path}") poolPaths;
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          CapabilityBoundingSet = "";
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          UMask = "0077";
        };
      };
    })

    (lib.mkIf client.enable {
      systemd.services.overalls-buck-re-client = {
        description = "Publish or withdraw root's read-only Buck2 remote cache configuration";
        wantedBy = [ "multi-user.target" ];
        # Runs even when the bundle failed, so a stale file is withdrawn.
        wants = [ bundle.unit ];
        after = [ bundle.unit ];
        # Follows the bundle's stops and restarts, which remove its files.
        partOf = [ bundle.unit ];
        restartTriggers = [ clientConfig ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = publishClient;
          ExecStop = "${pkgs.coreutils}/bin/rm -f ${rootConfig}";
        };
      };
      systemd.tmpfiles.rules = [ "d /root/.buckconfig.d 0700 root root -" ];
      # The updater runs Buck2 with its own HOME, so it never reads root's
      # file; it writes the same read-only section into its checkout's
      # .buckconfig.local while the identity exists and the cache answers
      # (ADR-0271). No unit ordering: a missing cache never delays an update.
      services.overallsAutoUpdate.remoteCache = {
        inherit (client) address;
        port = client.readPort;
        instanceName = instance;
        caCertificate = "${client.caCertificate}";
        clientIdentity = secretFile "client.pem";
      };
    })
    (lib.mkIf worker.enable {
      assertions = [
        { assertion = worker.encryptedFile != null; message = "A buck-re worker requires this host's worker document."; }
        { assertion = !(lib.hasPrefix "0." worker.schedulerAddress) && !(lib.hasPrefix "127." worker.schedulerAddress);
          message = "A buck-re worker must reach the scheduler on its tailnet address."; }
        { assertion = lib.all (path: lib.elem path worker.excludedMounts) poolPaths;
          message = "A buck-re worker must remove every Lilly pool mount from its namespace (ADR-0144)."; }
        { assertion = lib.all (path: !(lib.hasPrefix "${path}/" "${workerState}/")) poolPaths;
          message = "The buck-re worker state must be outside every Lilly guest pool (ADR-0144)."; }
      ];
      services.overallsSecrets = {
        enable = true;
        bundles.buck-re-worker = {
          encryptedFile = worker.encryptedFile;
          outputs."worker.pem" = { format = "raw"; secrets = [ "WORKER_IDENTITY" ]; };
        };
      };
      systemd.services.overalls-secrets-buck-re-worker = {
        wantedBy = [ "multi-user.target" ];
        # A worker skipped at boot for want of its identity starts once the
        # bundle does.
        wants = [ "nativelink-worker.service" ];
      };

      users.groups.nativelink-worker = {};
      users.groups.nativelink-build = {};
      users.users.nativelink-worker = {
        isSystemUser = true; group = "nativelink-worker"; extraGroups = [ "nativelink-build" ]; home = workerState;
      };
      # Remote actions run as this user: it cannot read the worker's identity,
      # store or process, and writes only its own action directory.
      users.users.nativelink-action = { isSystemUser = true; group = "nativelink-build"; home = "/var/empty"; };
      systemd.tmpfiles.rules = [
        "d ${workerState} 0700 nativelink-worker nativelink-worker -"
        "d ${workRoot} 2770 nativelink-worker nativelink-build -"
        "d ${cellsState} 0755 root root -"
      ];

      systemd.services.nativelink-worker-cells = {
        description = "Publish the buckCells closure the NativeLink worker advertises";
        wantedBy = [ "multi-user.target" ];
        after = [ "nix-daemon.socket" "nix-daemon.service" ];
        environment.NIX_REMOTE = "daemon";
        serviceConfig = { Type = "oneshot"; ExecStart = publishCells; };
      };
      # The updater's checkout moves to new cells only when their key changes.
      systemd.paths.nativelink-worker-cells = lib.mkIf (worker.cellsLinks != []) {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = map (link: "${dirOf link}/.buck-cells.key") worker.cellsLinks;
      };

      systemd.services.nativelink-worker = {
        description = "NativeLink Buck2 remote-execution worker";
        wantedBy = [ "multi-user.target" ];
        wants = [ workerBundle.unit "nativelink-worker-cells.service" "network-online.target" ];
        after = [ workerBundle.unit "nativelink-worker-cells.service" "network-online.target" "zfs-mount.service" ];
        # Without a cells closure or an identity there is nothing to serve;
        # clients then fall back to local execution.
        unitConfig.ConditionPathExists = [ "${cellsState}/id" "${workerBundle.directory}/worker.pem" ];
        restartTriggers = [ workerConfig ];
        serviceConfig = {
          ExecStart = startWorker;
          # Root only for the namespace and identity steps of startWorker.
          User = "root";
          LoadCredential = "worker.pem:${workerBundle.directory}/worker.pem";
          PrivateMounts = true;
          Restart = "on-failure";
          RestartSec = 10;
          LimitNOFILE = 16384;
          # Guests come first: workers take what is left, within hard caps,
          # and the worker is the first thing the kernel kills under pressure.
          CPUWeight = 20;
          CPUQuota = worker.cpuQuota;
          IOWeight = 20;
          MemoryHigh = worker.memoryHigh;
          MemoryMax = worker.memoryMax;
          MemorySwapMax = 0;
          TasksMax = worker.tasksMax;
          OOMScoreAdjust = 1000;
          Nice = 10;
          RestrictNetworkInterfaces = [ "lo" worker.interface ];
          IPAddressDeny = "any";
          IPAddressAllow = [ "localhost" worker.schedulerAddress ];
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          # No Lilly, guest, secret or host-identity state: its own identity
          # arrives through LoadCredential, read by systemd before this applies.
          InaccessiblePaths = map (path: "-${path}") (workerHiddenPaths ++ [ "/run/wrappers" ]);
          ReadWritePaths = [ workerState workRoot ];
          RuntimeDirectory = [ "nativelink-worker" "nativelink-worker-exec" ];
          RuntimeDirectoryMode = "0700";
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          # Only the action sandbox's own namespaces.
          RestrictNamespaces = [ "mnt" "pid" "ipc" "uts" "net" ];
          NoNewPrivileges = false;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          # The start script's; the worker keeps only SETUID, SETGID and
          # SYS_ADMIN in its bounding set, for the sandbox.
          CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_SETUID" "CAP_SETGID" "CAP_SETPCAP" "CAP_CHOWN"
            "CAP_SETFCAP" "CAP_DAC_OVERRIDE" "CAP_FOWNER" ];
          SystemCallArchitectures = "native";
          UMask = "0077";
        };
      };
    })
  ];
}
