{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.marshall;
  dumps = import ./crash-dumps { inherit lib pkgs; };
  mailEnvironment = import ./smtp-relay/environment.nix { inherit lib; cfg = cfg.smtpRelay; };
  localTypes = import ./types.nix { inherit lib; };
  names = builtins.attrNames cfg.instances;
  ports = map (instance: instance.port) (builtins.attrValues cfg.instances);
  fleetPorts = map (instance: instance.fleetPort) (builtins.attrValues cfg.instances);
  artifactContent = cfg.artifactContent.host != null;
  artifactPorts = lib.optionals artifactContent (map (instance: instance.artifactPort) (builtins.attrValues cfg.instances));
  fleetOtelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  editorReleases = {
    version = 1;
    targets = lib.mapAttrs (_: package: {
      protocol = package.editorProtocol;
      commit = package.sourceCommit;
      release = package.releaseId;
    }) cfg.editorPackages;
  };
  acme = cfg.ingress.wildcardAcme;
  acmeNameservers = if acme == null then [] else acme.nameservers;
  # Runtime nameserver addresses (for example SOPS-delivered fleet addresses)
  # reach the issuer only as credentials; Marshall validates the rendered JSON.
  acmeRuntime = lib.any (nameserver: nameserver.addressFile != null) acmeNameservers;
  acmeCredential = index: "acme-nameserver-${toString index}";
  acmeArguments = lib.concatStringsSep " " (lib.concatLists (lib.imap0 (index: nameserver:
    lib.optional (nameserver.addressFile != null)
      ''--rawfile n${toString index} "$CREDENTIALS_DIRECTORY/${acmeCredential index}"'') acmeNameservers));
  acmeAddress = index: nameserver: if nameserver.addressFile == null
    then builtins.toJSON nameserver.address
    else "($n${toString index} | rtrimstr(\"\\n\"))";
  acmeFilter = "[" + lib.concatStringsSep ", " (lib.imap0 (index: nameserver:
    "{address: ${acmeAddress index nameserver}, port: ${toString nameserver.port}}") acmeNameservers) + "]";
  acmeRender = lib.optionalString acmeRuntime ''
    acme_nameservers="$(${pkgs.jq}/bin/jq -cn ${acmeArguments} ${lib.escapeShellArg acmeFilter})" || exit 1
  '';
  sloCatalog = pkgs.writeText "marshall-fleet-slo-catalog.json" (builtins.toJSON (import ./otel-fleet/slo-catalog.nix {
    # The deployment's telemetry roster; a host without fleet telemetry is its own roster.
    hosts = if lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config
      then config.services.overallsOtelFleet.roster
      else [ config.networking.hostName ];
  }));
in
{
  imports = [ ./marshall-operator.nix ./crash-dumps/retention.nix (import ./smtp-relay { inherit packages; }) ];
  options.services.marshall = {
    githubRestoreEpochFile = mkOption {
      type = localTypes.absolutePath;
      default = "/var/lib/overalls-marshall-recovery/github-restore-epoch";
      description = "Root-controlled public UUID restored-authority fence, shared identically across all replicas before recovery startup. The marker persists after invalidation.";
    };
    githubBootstrapRelease = mkOption {
      type = types.nullOr types.package;
      default = packages.githubBootstrapRelease or null;
      description = "Immutable source-built executor inventory for retained-machine tool maintenance.";
    };
    githubToolsRelease = mkOption {
      type = types.nullOr types.package;
      default = if packages ? githubTools then packages.githubTools.release else null;
      description = "Immutable manifest for the managed guest GitHub tools release.";
    };
    enable = mkEnableOption "Marshall control plane instances";
    crashDumps = dumps.options;
    package = mkOption {
      type = types.package;
      default = if cfg.crashDumps.enable then packages.encrypted.marshall else packages.marshall;
      description = "Source-built Marshall release.";
    };
    # @cc [owner:ghuntley,label:protocol;security] editor-package-target-registry
    # Only the finite reviewed target names may select immutable packages. The
    # module MUST emit each exact package descriptor; an empty map disables
    # admission and MUST NOT inherit an environment-file release override.
    editorPackages = mkOption {
      type = types.addCheck (types.attrsOf types.package)
        (value: lib.all (target: builtins.elem target [ "linux-x64" "win32-x64" ]) (builtins.attrNames value));
      default = lib.optionalAttrs (packages ? vscodeWeb) { linux-x64 = packages.vscodeWeb; };
      description = "Immutable official-source browser editor packages by linux-x64 or win32-x64 target; their exact descriptors govern image and gateway admission. Empty disables editor authority.";
    };
    marvinPackage = mkOption {
      type = types.nullOr types.package;
      default = packages.marvin or null;
      description = "Immutable unsigned Chrome and Firefox browser extension package served at the public /bin routes. Null disables browser extension downloads.";
    };
    environmentFile = mkOption {
      type = localTypes.privatePath;
      default = "/run/overalls-secrets/marshall.env";
      description = "Private systemd environment file containing database, signing, Cloak and SMTP configuration.";
    };
    serperKeyFile = mkOption {
      type = types.nullOr localTypes.privatePath;
      default = null;
      description = "Private runtime Serper API key, delivered to each Marshall instance through systemd credentials.";
    };
    serperOrigin = mkOption {
      type = types.enum [ "https://google.serper.dev" "http://127.0.0.1:18080" ];
      default = "https://google.serper.dev";
      description = "Fixed Serper origin; loopback is reserved for the machine-test fixture.";
    };
    integrations.github = {
      clientId = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9_.-]{1,200}");
        default = null;
        description = "Public GitHub OAuth application client identity. Configure together with clientSecretFile and redirectUri.";
      };
      clientSecretFile = mkOption {
        type = types.nullOr localTypes.privatePath;
        default = null;
        description = "Private runtime GitHub OAuth client secret, delivered through systemd credentials.";
      };
      redirectUri = mkOption {
        type = types.nullOr (types.strMatching "https://[A-Za-z0-9.-]+(:[0-9]+)?/auth/github-com/callback");
        default = null;
        description = "Registered HTTPS GitHub OAuth callback URL.";
      };
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Required preparation services that publish runtime secrets before startup.";
    };
    publicHost = mkOption {
      type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
      description = "Public DNS name used by sign-in links and origin checks.";
    };
    # @cc [owner:ghuntley,label:security;deployment] marshall-notifications-switch
    # services.marshall.notifications.enable (default true) MUST reach Marshall
    # only through the final launch wrapper, overriding any EnvironmentFile
    # value. false refuses `device register` with push_disabled and makes the
    # needs-input producer a no-op (ADR-0225).
    notifications.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Send content-free, end-to-end encrypted Mila push pokes through the Susan relay at https://notifications.overalls.dev. When false, device registration is refused with push_disabled and no deliveries are produced.";
    };
    inference = {
      detailDays = mkOption { type = types.ints.between 1 36500; default = 90; description = "Inference request metadata retention in days."; };
      aggregateDays = mkOption { type = types.ints.between 1 36500; default = 365; description = "Daily inference usage retention in days."; };
    };
    sshHostCa = {
      publicKey = mkOption { type = types.nullOr (types.strMatching "ssh-ed25519 [A-Za-z0-9+/]{68}"); default = null; description = "Dedicated SSH host CA public key."; };
      keyFile = mkOption { type = types.nullOr localTypes.privatePath; default = null; description = "Runtime SSH CA private key delivered only to Marshall."; };
      retirement = mkOption { type = types.ints.positive; default = 2421446400; description = "SSH CA operational retirement in Unix seconds (2046-09-25)."; };
    };
    # @cc [owner:ghuntley,label:security;deployment] marshall-artifact-content-origin
    # services.marshall.artifactContent.host selects the separate artifact
    # content origin. Only when it is non-null MUST the final launch wrapper set
    # MARSHALL_ARTIFACT_CONTENT_HOST and the per-instance
    # MARSHALL_ARTIFACT_TLS_PORT; otherwise both are cleared, so an
    # EnvironmentFile cannot start a content listener. The content port MUST be
    # distinct from every browser and fleet port. debugEcho is a machine-test
    # fixture knob and MUST be refused unless machineTestFixture is set.
    artifactContent = {
      host = mkOption {
        type = types.nullOr ((types.addCheck types.str (value: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+" value != null)) // { description = "lowercase multi-label DNS hostname"; });
        default = null;
        description = "Lowercase public DNS name of the isolated artifact content origin (for example usercontent.ghuntley.dev). It must differ from publicHost. Null disables the content listener and the artifact viewer reports that it is unavailable.";
      };
      debugEcho = mkOption {
        type = types.bool;
        default = false;
        description = "Machine-test only: makes GET /v/<ticket>/__echo report whether Cookie and Authorization reached Marshall and emit a probe Set-Cookie. Requires machineTestFixture; never enable in a deployment.";
      };
    };
    machineTestFixture = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = "Marks a disposable NixOS machine-test fixture. Test-only knobs such as artifactContent.debugEcho are refused unless this is set.";
    };
    publicHostFile = mkOption {
      type = types.nullOr localTypes.privatePath;
      default = null;
      description = "Optional operator-owned runtime public hostname, delivered through systemd credentials. Overrides publicHost; invalid or missing input prevents startup.";
    };
    defaultImageIdFile = mkOption {
      type = types.nullOr localTypes.privatePath;
      default = null;
      description = "Optional operator-owned runtime default image identity, delivered through systemd credentials. Overrides defaultImageId; empty input disables the default and invalid input prevents startup.";
    };
    ingress = {
      wildcardAcme = mkOption {
        default = null;
        description = "One Marshall instance authorized to issue the public Audi wildcard.";
        type = types.nullOr (types.submodule { options = {
          issuerInstance = mkOption { type = types.str; description = "Local Marshall instance consuming the certificate queue."; };
          directory = mkOption { type = types.strMatching "https://[^ ]+"; description = "Operator selected ACME directory."; };
          issuerCaFile = mkOption { type = localTypes.absolutePath; description = "CA roots authenticating the ACME directory."; };
          certificateRootsFile = mkOption { type = localTypes.absolutePath; description = "CA roots validating issued certificate chains."; };
          acceptTerms = mkOption { type = types.bool; default = false; description = "Explicit consent to register an ACME account."; };
          nameservers = mkOption { type = types.listOf (types.submodule { options = {
            address = mkOption { type = types.nullOr localTypes.ipv4; default = null; };
            addressFile = mkOption {
              type = types.nullOr (types.strMatching "/run/[A-Za-z0-9_./-]+");
              default = null;
              description = "Runtime file holding the replica's IPv4 address; list its publishing unit in secretUnits.";
            };
            port = mkOption { type = types.port; default = 53; };
          }; }); description = "Authoritative Audi DNS replicas checked before challenge acknowledgement."; };
        }; });
      };
      inceptionPublicFile = mkOption {
        type = types.nullOr localTypes.absolutePath;
        default = null;
        description = "Operator-owned JSON public Inception issuer, consent, DNS and trust settings, delivered through systemd credentials. Contains no parent credentials. Null leaves public bootstrap disabled.";
      };
      zone = mkOption {
        type = types.nullOr (types.strMatching "[a-z0-9][a-z0-9.-]*");
        default = null;
        description = "Delegated Audi application zone, shared by all gateways and DNS replicas. Editor authority requires at least two canonical lowercase DNS labels.";
      };
      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = "Public HTTPS port shared by Audi gateways; used for browser callbacks.";
      };
    };
    defaultImageId = mkOption {
      type = types.nullOr (types.strMatching "sha256:[0-9a-f]{64}");
      default = null;
      description = "Default immutable image for new SSH machines and initial browser drafts; admission still requires image availability.";
    };
    inceptionImageId = mkOption {
      type = types.nullOr (types.strMatching "sha256:[0-9a-f]{64}");
      default = null;
      description = "Immutable image bound exclusively to the Inception development profile; native host eligibility is also required.";
    };
    replicaCount = mkOption {
      type = types.ints.between 1 100;
      default = 3;
      description = "Total planned Marshall instances across the fleet.";
    };
    poolSize = mkOption {
      type = types.ints.between 1 100;
      default = 10;
      description = "Database pool connections per instance.";
    };
    databaseConnectionBudget = mkOption {
      type = types.ints.between 1 100000;
      description = "Fleet database allocation, including one notifier per instance and ten operator connections.";
    };
    databaseCAFile = mkOption {
      type = localTypes.absolutePath;
      default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      description = "CA bundle authenticating the PostgreSQL endpoint.";
    };
    cpuCores = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "Aggregate CPU quota in logical cores for Marshall instances.";
    };
    memoryMiB = mkOption {
      type = types.ints.positive;
      default = 8192;
      description = "Aggregate Marshall memory limit in MiB.";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open backend TLS ports; unnecessary for a colocated proxy.";
    };
    instances = mkOption {
      default = {};
      description = "Local instances keyed by distinct fleet-wide identities.";
      type = types.attrsOf (types.submodule ({ config, ... }: {
        options = {
          port = mkOption { type = types.port; description = "Backend HTTPS port."; };
          terminalPeerUrl = mkOption {
            type = types.nullOr (types.strMatching "https://[A-Za-z0-9.-]+(:[0-9]+)?/?");
            default = null;
            description = "Verified HTTPS origin of this instance's fleet listener for terminal peer routing.";
          };
          terminalPeerCAFile = mkOption {
            type = types.nullOr localTypes.absolutePath;
            default = null;
            description = "Optional private CA bundle for terminal peer TLS; system roots otherwise.";
          };
          fleetPort = mkOption {
            type = types.port;
            default = config.port + 1000;
            description = "Separate machine HTTPS port; never opened by openFirewall.";
          };
          artifactPort = mkOption {
            type = types.port;
            default = config.port + 2000;
            description = "Separate artifact content HTTPS port, bound on bindAddress with the backend certificate only when artifactContent.host is set. Opened by openFirewall like port.";
          };
          fleetBindAddress = mkOption {
            type = types.addCheck localTypes.ipv4 (address: address != "0.0.0.0");
            default = "127.0.0.1";
            description = "Explicit IPv4 fleet listener address. Remote access requires separate interface-scoped firewall policy.";
          };
          fleetLoopback = mkOption {
            type = types.bool;
            default = false;
            description = "Also bind fleet TLS to loopback for colocated clients when the main fleet bind uses a private interface.";
          };
          bindAddress = mkOption {
            type = localTypes.ipv4;
            default = "127.0.0.1";
            description = "Literal IPv4 backend bind address.";
          };
          certificateFile = mkOption {
            type = localTypes.privatePath;
            description = "Runtime backend certificate delivered through systemd credentials.";
          };
          keyFile = mkOption {
            type = localTypes.privatePath;
            description = "Runtime backend private key delivered through systemd credentials.";
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    services.overallsCrashDumpRetention.directories = lib.mkIf cfg.crashDumps.enable (map (name: "/var/lib/marshall-${name}-crash-dumps") (builtins.attrNames cfg.instances));
    systemd.coredump.settings.Coredump = lib.mkIf cfg.crashDumps.enable { Storage = "none"; ProcessSizeMax = 0; };
    assertions = [
      { assertion = (cfg.integrations.github.clientId == null) == (cfg.integrations.github.clientSecretFile == null) &&
          (cfg.integrations.github.clientId == null) == (cfg.integrations.github.redirectUri == null);
        message = "Marshall GitHub OAuth clientId, clientSecretFile and redirectUri must be configured together."; }
      # @cc [owner:ghuntley,label:protocol;reliability] editor-module-zone-boundary
      # A configured editor zone MUST satisfy the canonical multi-label protocol
      # boundary before service rendering. Null leaves discovery unconfigured.
      { assertion = cfg.editorPackages == {} || cfg.ingress.zone == null ||
          (builtins.stringLength cfg.ingress.zone <= 189 &&
           builtins.length (lib.splitString "." cfg.ingress.zone) >= 2 &&
           lib.all (label: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" label != null) (lib.splitString "." cfg.ingress.zone));
        message = "Marshall editor authority requires a canonical zone with at least two DNS labels."; }
      { assertion = (cfg.sshHostCa.publicKey == null) == (cfg.sshHostCa.keyFile == null) && (cfg.sshHostCa.publicKey == null || cfg.ingress.zone != null); message = "SSH CA requires public key, private runtime key and ingress zone together."; }

      { assertion = cfg.ingress.wildcardAcme == null ||
          (cfg.ingress.zone != null && builtins.elem cfg.ingress.wildcardAcme.issuerInstance names &&
           builtins.length cfg.ingress.wildcardAcme.nameservers >= 2 &&
           builtins.length cfg.ingress.wildcardAcme.nameservers <= 8 &&
           builtins.length (lib.unique cfg.ingress.wildcardAcme.nameservers) == builtins.length cfg.ingress.wildcardAcme.nameservers
           && lib.all (nameserver: (nameserver.address == null) != (nameserver.addressFile == null)) acmeNameservers);
        message = "Wildcard ACME requires a local issuer instance, ingress zone and two to eight distinct DNS peers."; }
      { assertion = !cfg.crashDumps.enable || cfg.crashDumps.publicKeyFile != null; message = "Encrypted dumps require an operator public key file."; }
      { assertion = names != [] && builtins.length names <= cfg.replicaCount;
        message = "Marshall requires 1..replicaCount local instances."; }
      { assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}" name != null) names;
        message = "Marshall instance names must be valid distinct runtime identities."; }
      { assertion = builtins.length ports == builtins.length (lib.unique ports);
        message = "Marshall backend ports must be distinct on a host."; }
      { assertion = builtins.length (ports ++ fleetPorts) == builtins.length (lib.unique (ports ++ fleetPorts));
        message = "Marshall browser and fleet ports must be distinct across local instances."; }
      { assertion = builtins.length (ports ++ fleetPorts ++ artifactPorts) == builtins.length (lib.unique (ports ++ fleetPorts ++ artifactPorts));
        message = "Marshall artifact content ports must be distinct from every browser and fleet port."; }
      { assertion = !artifactContent || cfg.artifactContent.host != lib.toLower cfg.publicHost;
        message = "Marshall artifactContent.host must differ from publicHost."; }
      { assertion = !cfg.artifactContent.debugEcho || (cfg.machineTestFixture && artifactContent);
        message = "Marshall artifactContent.debugEcho is a machine-test fixture knob; it requires machineTestFixture and a content host."; }
      { assertion = cfg.databaseConnectionBudget >= cfg.replicaCount * (cfg.poolSize + 1) + 10;
        message = "Marshall database budget must cover replicas * (poolSize + 1) + 10."; }
      { assertion = cfg.memoryMiB >= 256 * builtins.length names;
        message = "Marshall aggregate memory must provide at least 256 MiB per local instance."; }
    ];

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall (ports ++ artifactPorts);
    systemd.slices.marshall = {
      description = "Marshall control plane resource budget";
      sliceConfig = {
        CPUAccounting = true;
        MemoryAccounting = true;
        IOAccounting = true;
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
      };
    };

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (name: instance: lib.nameValuePair "marshall-${name}" {
      description = "Marshall control plane (${name})";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ] ++ lib.optional cfg.smtpRelay.enable "overalls-smtprelay.service";
      after = [ "network-online.target" ] ++ cfg.secretUnits ++ lib.optional cfg.smtpRelay.enable "overalls-smtprelay.service";
      requires = cfg.secretUnits;
      startLimitIntervalSec = 60;
      startLimitBurst = 5;
      environment = {
        MARSHALL_INFERENCE_DETAIL_DAYS = toString cfg.inference.detailDays;
        MARSHALL_INFERENCE_AGGREGATE_DAYS = toString cfg.inference.aggregateDays;
        MARSHALL_SERPER_ORIGIN = cfg.serperOrigin;
      } // lib.optionalAttrs (cfg.sshHostCa.publicKey != null) {
        MARSHALL_SSH_HOST_TRUST = builtins.toJSON { version = 1; ca = cfg.sshHostCa.publicKey; management_host = cfg.publicHost; zone = cfg.ingress.zone; retirement = cfg.sshHostCa.retirement; };
        MARSHALL_SSH_HOST_CA_KEY_FILE = "/run/credentials/marshall-${name}.service/ssh-host-ca";
      } // lib.optionalAttrs (cfg.serperKeyFile != null) {
        MARSHALL_SERPER_KEY_FILE = "/run/credentials/marshall-${name}.service/serper.key";
      } // lib.optionalAttrs (packages ? lyra) {
        OVERALLS_LYRA_RELEASE = toString packages.lyra;
      } // lib.optionalAttrs (cfg.githubToolsRelease != null) {
        MARSHALL_GITHUB_TOOLS_MANIFEST_FILE = "${cfg.githubToolsRelease}/manifest.json";
      } // lib.optionalAttrs (cfg.ingress.zone != null) {
        MARSHALL_INGRESS_ZONE = cfg.ingress.zone;
      } // {
        MARSHALL_INGRESS_EDITOR_RELEASES = builtins.toJSON editorReleases;
      } // lib.optionalAttrs (cfg.ingress.wildcardAcme != null && cfg.ingress.wildcardAcme.issuerInstance == name) {
        MARSHALL_FLEET_ACME_DIRECTORY = cfg.ingress.wildcardAcme.directory;
        MARSHALL_FLEET_ACME_ISSUER_CA_FILE = "/run/credentials/marshall-${name}.service/fleet-issuer-ca.pem";
        MARSHALL_FLEET_ACME_ROOTS_FILE = "/run/credentials/marshall-${name}.service/fleet-roots.pem";
      } // lib.optionalAttrs (acme != null && acme.issuerInstance == name && !acmeRuntime) {
        MARSHALL_FLEET_ACME_NAMESERVERS = builtins.toJSON (map (nameserver: { inherit (nameserver) address port; }) acmeNameservers);
      } // lib.optionalAttrs (acme != null && acme.issuerInstance == name) {
        MARSHALL_FLEET_ACME_ACCEPT_TERMS = if cfg.ingress.wildcardAcme.acceptTerms then "true" else "false";
      } // lib.optionalAttrs (cfg.ingress.inceptionPublicFile != null) {
        MARSHALL_INCEPTION_PUBLIC_FILE = "/run/credentials/marshall-${name}.service/inception-public.json";
      } // {
        MARSHALL_INGRESS_HTTPS_PORT = toString cfg.ingress.httpsPort;
        RELEASE_TMP = "/run/marshall-${name}";
        ERL_CRASH_DUMP = "/dev/null";
      };

      # @cc [owner:ghuntley,label:coordination] module-instance-runtime-authority
      # The launch wrapper MUST enforce the module's identity, TLS listener and
      # fleet budget even if a shared environment file contains conflicting values.

      # @cc [owner:ghuntley,label:security] marvin-package-runtime-authority
      # The final wrapper MUST clear inherited Marvin release selection and bind
      # the module's immutable package, or an empty value when downloads are
      # disabled. EnvironmentFile MUST NOT select or re-enable Marvin artifacts.

      # @cc [owner:ghuntley,label:security] marshall-cookie-argument-alphabet
      # The generated cookie MUST contain only hexadecimal digits so erlexec cannot
      # interpret a leading base64 '+' as a VM flag or echo it in usage diagnostics.

      # @cc [owner:ghuntley,label:security] github-module-runtime-authority
      # The final wrapper MUST remove inherited OAuth configuration and select
      # only module settings. Disabled OAuth MUST remain disabled; secret bytes
      # MUST stay in systemd credentials and never enter Nix or command arguments.

      # @cc [owner:ghuntley,label:security;deployment] marshall-prestart-mail-authority
      # Pre-start release evaluation MUST apply the module's selected mail
      # transport, clearing inherited provider credentials in local-relay mode
      # exactly as the serving and migration launchers do. It never issues
      # certificates, so it drops the fleet ACME issuer, whose runtime
      # nameserver addresses only the serving script renders (ADR-0233).
      preStart = ''
          export RELEASE_COOKIE
          RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
          ${pkgs.coreutils}/bin/env -u PORT -u MARSHALL_FLEET_TLS_PORT -u MARSHALL_FLEET_BIND_IP \
            -u MARSHALL_ARTIFACT_CONTENT_HOST -u MARSHALL_ARTIFACT_TLS_PORT -u MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO \
            -u MARSHALL_FLEET_ACME_DIRECTORY \
            -u MARSHALL_GITHUB_CLIENT_ID -u MARSHALL_GITHUB_CLIENT_SECRET_FILE -u MARSHALL_GITHUB_REDIRECT_URI \
            -u MARSHALL_GITHUB_TOOLS_MANIFEST_FILE -u MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE \
            ${mailEnvironment} \
            PHX_SERVER=false RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null RELEASE_TMP=/run/marshall-${name} \
            PHX_HOST=${lib.escapeShellArg cfg.publicHost} MARSHALL_INSTANCE_ID=${lib.escapeShellArg name} \
            MARSHALL_GITHUB_RESTORE_EPOCH_FILE=${lib.escapeShellArg cfg.githubRestoreEpochFile} \
            MARSHALL_DB_TLS=verify MARSHALL_DB_CA_CERTFILE="$CREDENTIALS_DIRECTORY/database-ca.crt" \
            MARSHALL_REPLICA_COUNT=${toString cfg.replicaCount} POOL_SIZE=${toString cfg.poolSize} \
            MARSHALL_DB_CONNECTION_BUDGET=${toString cfg.databaseConnectionBudget} \
            MARSHALL_NOTIFICATIONS_ENABLED=${if cfg.notifications.enable then "true" else "false"} \
            ${cfg.package}/bin/marshall eval 'Marshall.GitHub.invalidate_restored_credentials_before_serving!()'
      '';
      script = ''
        ${lib.optionalString fleetOtelEnabled "${pkgs.coreutils}/bin/chmod 0700 /run/marshall-${name}"}
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        ${lib.optionalString (cfg.publicHostFile != null) ''
          public_host="$(${pkgs.python3}/bin/python3 ${./marshall-public-host.py} "$CREDENTIALS_DIRECTORY/public-host")" || exit 1
        ''}
        ${lib.optionalString (acme != null && acme.issuerInstance == name) acmeRender}
        ${lib.optionalString (cfg.defaultImageIdFile != null) ''
          default_image="$(${pkgs.python3}/bin/python3 ${./marshall-default-image.py} "$CREDENTIALS_DIRECTORY/default-image-id")" || exit 1
        ''}
        exec ${pkgs.coreutils}/bin/env -u PORT -u MARSHALL_SLO_SNAPSHOT -u MARSHALL_SERVICE_LEVEL_DIRECTORY -u MARSHALL_INGRESS_EDITOR_RELEASES -u OVERALLS_MARVIN_RELEASE \
          -u MARSHALL_ARTIFACT_CONTENT_HOST -u MARSHALL_ARTIFACT_TLS_PORT -u MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO \
          -u MARSHALL_GITHUB_CLIENT_ID -u MARSHALL_GITHUB_CLIENT_SECRET_FILE -u MARSHALL_GITHUB_REDIRECT_URI -u MARSHALL_GITHUB_TOOLS_MANIFEST_FILE -u MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE \
          ${mailEnvironment}          PHX_SERVER=true RELEASE_DISTRIBUTION=none \
          ${lib.optionalString (cfg.githubBootstrapRelease != null) ("MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE=" + lib.escapeShellArg "${cfg.githubBootstrapRelease}/manifest.json")} \
          ${lib.optionalString (cfg.integrations.github.clientId != null) ("MARSHALL_GITHUB_CLIENT_ID=" + lib.escapeShellArg cfg.integrations.github.clientId)} \
          ${lib.optionalString (cfg.integrations.github.clientSecretFile != null) ''MARSHALL_GITHUB_CLIENT_SECRET_FILE="$CREDENTIALS_DIRECTORY/github-oauth-secret"''} \
          ${lib.optionalString (cfg.integrations.github.redirectUri != null) ("MARSHALL_GITHUB_REDIRECT_URI=" + lib.escapeShellArg cfg.integrations.github.redirectUri)} \
          ${lib.optionalString (cfg.githubToolsRelease != null) ("MARSHALL_GITHUB_TOOLS_MANIFEST_FILE=" + lib.escapeShellArg "${cfg.githubToolsRelease}/manifest.json")} \
          ${lib.optionalString fleetOtelEnabled "MARSHALL_SLO_SNAPSHOT=/run/marshall-slo-${name}/slo.json"} \
          ${lib.optionalString fleetOtelEnabled "MARSHALL_SLO_CATALOG=${sloCatalog}"} \
          MARSHALL_INGRESS_EDITOR_RELEASES=${lib.escapeShellArg (builtins.toJSON editorReleases)} \
          MARSHALL_NOTIFICATIONS_ENABLED=${if cfg.notifications.enable then "true" else "false"} \
          ${lib.optionalString (acmeRuntime && acme.issuerInstance == name) ''MARSHALL_FLEET_ACME_NAMESERVERS="$acme_nameservers"''} \
          OVERALLS_MARVIN_RELEASE=${lib.escapeShellArg (if cfg.marvinPackage == null then "" else toString cfg.marvinPackage)} \
          ${lib.optionalString (fleetOtelEnabled && name == "overalls") "MARSHALL_SERVICE_LEVEL_DIRECTORY=/run/marshall-slo-overalls"} \
          ERL_CRASH_DUMP=/dev/null RELEASE_TMP=/run/marshall-${name} \
          PHX_HOST=${if cfg.publicHostFile == null then lib.escapeShellArg cfg.publicHost else ''"$public_host"''} \
          MARSHALL_DEFAULT_IMAGE_ID=${if cfg.defaultImageIdFile != null then ''"$default_image"'' else lib.escapeShellArg (if cfg.defaultImageId == null then "" else cfg.defaultImageId)} \
          MARSHALL_INCEPTION_IMAGE_ID=${lib.escapeShellArg (if cfg.inceptionImageId == null then "" else cfg.inceptionImageId)} \
          MARSHALL_INSTANCE_ID=${lib.escapeShellArg name} \
          MARSHALL_TERMINAL_PEER_URL=${lib.escapeShellArg (if instance.terminalPeerUrl == null then "" else instance.terminalPeerUrl)} \
          MARSHALL_TERMINAL_PEER_CA_CERTFILE=${if instance.terminalPeerCAFile == null then "''" else ''"$CREDENTIALS_DIRECTORY/terminal-peer-ca.crt"''} \
          MARSHALL_REPLICA_COUNT=${toString cfg.replicaCount} \
          POOL_SIZE=${toString cfg.poolSize} \
          MARSHALL_DB_CONNECTION_BUDGET=${toString cfg.databaseConnectionBudget} \
          MARSHALL_DB_TLS=verify \
          MARSHALL_DB_CA_CERTFILE="$CREDENTIALS_DIRECTORY/database-ca.crt" \
          MARSHALL_BIND_IP=${lib.escapeShellArg instance.bindAddress} \
          MARSHALL_TLS_PORT=${toString instance.port} \
          ${lib.optionalString artifactContent ("MARSHALL_ARTIFACT_CONTENT_HOST=" + lib.escapeShellArg cfg.artifactContent.host + " MARSHALL_ARTIFACT_TLS_PORT=" + toString instance.artifactPort)} \
          ${lib.optionalString cfg.artifactContent.debugEcho "MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO=true"} \
          MARSHALL_FLEET_BIND_IP=${lib.escapeShellArg instance.fleetBindAddress} \
          MARSHALL_FLEET_TLS_PORT=${toString instance.fleetPort} \
          MARSHALL_FLEET_LOOPBACK=${if instance.fleetLoopback then "true" else "false"} \
          MARSHALL_TLS_CERTFILE="$CREDENTIALS_DIRECTORY/tls.crt" \
          MARSHALL_TLS_KEYFILE="$CREDENTIALS_DIRECTORY/tls.key" \
          ${dumps.launch cfg.crashDumps cfg.package "/var/lib/marshall-${name}-crash-dumps" "${cfg.package}/bin/marshall start"}
      '';
      serviceConfig = {
        StateDirectory = lib.optional cfg.crashDumps.enable "marshall-${name}-crash-dumps";
        StateDirectoryMode = "0700";
        ExecStopPost = lib.optional cfg.crashDumps.enable (dumps.finish "/var/lib/marshall-${name}-crash-dumps");
        Type = "exec";
        DynamicUser = true;
        User = "marshall-${name}";
        ReadWritePaths = lib.optionals fleetOtelEnabled [ "/run/marshall-slo-${name}" ];
        Slice = "marshall.slice";
        UMask = "0077";
        EnvironmentFile = cfg.environmentFile;
        # @cc [owner:ghuntley,label:security] marshall-runtime-input-custody
        # Optional public settings MUST reach the dynamic service user through
        # systemd credentials. Root-only operator files MUST NOT require relaxed
        # filesystem permissions or privileged application execution.
        LoadCredential = [
          "tls.crt:${instance.certificateFile}" "tls.key:${instance.keyFile}"
          "database-ca.crt:${cfg.databaseCAFile}"
        ] ++ lib.optional (cfg.sshHostCa.keyFile != null) "ssh-host-ca:${cfg.sshHostCa.keyFile}"
          ++ lib.optional (cfg.serperKeyFile != null) "serper.key:${cfg.serperKeyFile}"
          ++ lib.optional (cfg.integrations.github.clientSecretFile != null) "github-oauth-secret:${cfg.integrations.github.clientSecretFile}"
          ++ lib.optional (cfg.publicHostFile != null) "public-host:${cfg.publicHostFile}"
          ++ lib.optional (instance.terminalPeerCAFile != null) "terminal-peer-ca.crt:${instance.terminalPeerCAFile}"
          ++ lib.optional (cfg.defaultImageIdFile != null) "default-image-id:${cfg.defaultImageIdFile}"
          ++ lib.optional (cfg.ingress.inceptionPublicFile != null)
            "inception-public.json:${cfg.ingress.inceptionPublicFile}"
          ++ lib.optionals (cfg.ingress.wildcardAcme != null && cfg.ingress.wildcardAcme.issuerInstance == name) [
            "fleet-issuer-ca.pem:${cfg.ingress.wildcardAcme.issuerCaFile}"
            "fleet-roots.pem:${cfg.ingress.wildcardAcme.certificateRootsFile}"
          ] ++ lib.optionals (acme != null && acme.issuerInstance == name) (lib.concatLists (lib.imap0 (index: nameserver:
            lib.optional (nameserver.addressFile != null) "${acmeCredential index}:${nameserver.addressFile}") acmeNameservers));
        RuntimeDirectory = [ "marshall-${name}" ] ++ lib.optional fleetOtelEnabled "marshall-slo-${name}";
        RuntimeDirectoryMode = if fleetOtelEnabled then "0750" else "0700";
        WorkingDirectory = cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 45;
        KillMode = "control-group";
        LimitNOFILE = 65536;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      } // lib.optionalAttrs fleetOtelEnabled {
        Group = "overalls-otel-marshall-source";
      };
      }) cfg.instances)
    ];
  };
}
