{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.overalls.buckRemoteCache;
  server = cfg.server;
  client = cfg.client;
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
  services = { cas, acReadOnly }: {
    cas = [ { instance_name = instance; cas_store = cas; } ];
    bytestream = [ { instance_name = instance; cas_store = cas; } ];
    ac = [ { instance_name = instance; ac_store = "AC"; read_only = acReadOnly; } ];
    capabilities = [ { instance_name = instance; } ];
  };
  # One process, one store set, two mTLS listeners. NativeLink cannot
  # authorise per certificate, so each listener trusts one CA: the reader CA
  # signs host certificates, the uploader CA signs only the CI certificate.
  serverConfig = (pkgs.formats.json {}).generate "nativelink.json" {
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
        services = services { cas = "CAS"; acReadOnly = false; }; }
    ];
    global = { max_open_files = 4096; default_digest_hash_function = "sha256"; };
  };
  # Buck2 reads root's ~/.buckconfig.d but ignores symlinks and includes
  # there, so the unit installs a regular file, and only while the identity
  # exists: a missing bundle means local execution, not a broken client.
  # Other users' builds on the host are unaffected.
  rootConfig = "/root/.buckconfig.d/overalls-remote-cache";
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
        { assertion = server.readPort != server.uploadPort; message = "The buck-re read and upload ports must differ."; }
        { assertion = lib.all (port: !(lib.elem port config.networking.firewall.allowedTCPPorts)) [ server.readPort server.uploadPort ]
            && lib.all (iface: lib.all (port: !(lib.elem port (iface.allowedTCPPorts or [])))
                 [ server.readPort server.uploadPort ]) (lib.attrValues config.networking.firewall.interfaces);
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
    })
  ];
}
