{ pkgs, nixpkgs, module, sysctlModule }:
let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } extra ];
  }).config;
  marshall = {
    services.marshall = {
      enable = true;
      publicHost = "control.example.test";
      databaseConnectionBudget = 43;
      instances = {
        one = { port = 4443; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; };
        two = { port = 4444; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; };
        three = { port = 4445; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; };
      };
    };
  };
  wildcardMarshall = evaluate {
    imports = [ marshall ];
    services.marshall.ingress = {
      zone = "apps.example.test";
      wildcardAcme = {
        issuerInstance = "one";
        directory = "https://ca.example.test/directory";
        issuerCaFile = "/run/ca.pem";
        certificateRootsFile = "/run/roots.pem";
        nameservers = [ { address = "192.0.2.1"; } { address = "192.0.2.2"; } ];
      };
    };
  };
  runtimeWildcardMarshall = evaluate {
    imports = [ marshall ];
    services.marshall.ingress = {
      zone = "apps.example.test";
      wildcardAcme = {
        issuerInstance = "one";
        directory = "https://ca.example.test/directory";
        issuerCaFile = "/run/ca.pem";
        certificateRootsFile = "/run/roots.pem";
        nameservers = [ { address = "192.0.2.1"; } { addressFile = "/run/fleet/ns2"; port = 5353; } ];
      };
    };
  };
  lilly = {
    networking.hostId = "aabbccdd";
    services.ziggy.secretsFile = "/etc/overalls/ziggy-fixture.enc.json";
    services.lilly = {
      enable = true;
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = "https://control.example.test";
      egressInterface = "eth0";
      pools = lib.mkDefault [ zfsPool ];
    };
  };
  proxy = {
    services.marshallProxy = {
      enable = true;
      publicHost = "control.example.test";
      certificateFile = "/run/proxy/full.pem";
      backends.one = { address = "127.0.0.1"; serverName = "backend.example.test"; };
    };
  };
  secrets = {
    services.overallsSecrets = {
      enable = true;
      bundles.example = {
        encryptedFile = "/etc/overalls/example.enc.json";
        outputs.credential = { format = "raw"; secrets = [ "TOKEN" ]; };
      };
    };
  };
  acme = {
    security.acme.acceptTerms = true;
    services.marshallProxy = (builtins.removeAttrs proxy.services.marshallProxy [ "certificateFile" ]) // {
      acme = {
        enable = true;
        email = "operator@example.test";
      };
    };
  };
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  neither = evaluate {};
  tuned = evaluate { overalls.sysctl.enable = true; };
  tunedRoles = evaluate { imports = [ marshall lilly proxy ]; overalls.sysctl.enable = true; };
  tunedOverrides = evaluate {
    overalls.sysctl.enable = true;
    boot.kernel.sysctl = {
      "net.ipv4.tcp_congestion_control" = "cubic";
      "net.core.default_qdisc" = "fq_codel";
      "net.core.wmem_max" = 8388608;
    };
  };
  standalone = enabled: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ sysctlModule { system.stateVersion = "26.05"; overalls.sysctl.enable = enabled; } ];
  }).config;
  untunedStandalone = standalone false;
  tunedStandalone = standalone true;
  profileKeys = [ "net.ipv4.tcp_congestion_control" "net.core.default_qdisc" ];
  onlyMarshall = evaluate marshall;
  windowsEditor = pkgs.runCommand "windows-editor-module-fixture" {
    passthru = { editorProtocol = 1; sourceCommit = lib.concatStrings (lib.replicate 40 "a"); releaseId = lib.concatStrings (lib.replicate 64 "d"); };
  } ''touch "$out"'';
  dualEditorMarshall = evaluate {
    imports = [ marshall ];
    services.marshall.editorPackages = {
      linux-x64 = onlyMarshall.services.marshall.editorPackages.linux-x64;
      win32-x64 = windowsEditor;
    };
  };
  editorRegistry = builtins.fromJSON dualEditorMarshall.systemd.services.marshall-one.environment.MARSHALL_INGRESS_EDITOR_RELEASES;
  sshCa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  pinnedMarshall = evaluate {
    imports = [ marshall ];
    services.marshall.sshHostCa = { publicKey = sshCa; keyFile = "/run/ssh-ca"; };
    services.marshall.ingress.zone = "apps.example.test";
  };
  runtimeHost = evaluate {
    imports = [ marshall ];
    services.marshall.publicHostFile = "/run/inception/public-host";
  };
  marvinRuntimeOverride = evaluate {
    imports = [ marshall ];
    systemd.services.marshall-one.environment.OVERALLS_MARVIN_RELEASE = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-unselected-browser";
  };
  marvinDisabled = evaluate {
    imports = [ marshall ];
    services.marshall.marvinPackage = null;
    systemd.services.marshall-one.environment.OVERALLS_MARVIN_RELEASE = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-unselected-browser";
  };
  publicInception = evaluate {
    imports = [ marshall ];
    services.marshall.ingress.inceptionPublicFile = "/etc/overalls/inception-public.json";
  };
  onlyLilly = evaluate lilly;
  both = evaluate { imports = [ marshall lilly ]; };
  fleetNetwork = {
    overalls.fleetNetwork = {
      enable = true;
      address = "10.90.0.1";
      endpointAddress = "192.0.2.1";
      privateKeyFile = "/run/fleet/private-key";
      secretUnits = [ "fleet-key.service" ];
      tcpPorts = [ 5443 ];
      peers.worker = {
        address = "10.90.0.2";
        endpointAddress = "192.0.2.2";
        publicKey = lib.concatStrings (lib.replicate 43 "A") + "=";
      };
    };
  };
  fleetTunnel = evaluate fleetNetwork;
  fleetTunnelNft = evaluate { imports = [ fleetNetwork ]; networking.nftables.enable = true; };
  onlyProxy = evaluate proxy;
  onlySecrets = evaluate secrets;
  onlyAcme = evaluate acme;
  dnsAcme = evaluate {
    imports = [ acme ];
    services.marshallProxy.acme = {
      challengeType = "dns-01";
      route53 = { hostedZoneId = "ZEXAMPLE"; credentialsFile = "/run/route53/credentials"; };
    };
  };
  peers = {
    services.marshallProxy.acme.http01 = {
      bindAddress = "192.168.1.1";
      peers = [ { address = "192.168.1.2"; } { address = "192.168.1.3"; } ];
    };
  };
  sharedAcme = evaluate { imports = [ acme peers ]; };
  noFirewallAcme = evaluate { imports = [ acme peers ]; services.marshallProxy.openFirewall = false; };
  nftAcme = evaluate { imports = [ acme peers ]; networking.nftables.enable = true; };
  acmeTypeRejected = value: !(builtins.tryEval (builtins.deepSeq
    (evaluate { imports = [ acme ]; services.marshallProxy.acme = value; }).services.marshallProxy.acme true)).success;
  updater = {
    services.overallsAutoUpdate = {
      enable = true;
      repository = "https://github.com/ghuntley/overalls";
      flakeAttr = "test-host";
    };
  };
  onlyUpdater = evaluate updater;
  updatingMarshall = evaluate {
    imports = [ marshall updater ];
    services.marshall.databaseConnectionBudget = lib.mkForce 49;
  };
  invalidAcme = settings: !(valid (evaluate { imports = [ acme settings ]; }));
  contentHost = "usercontent.example.test";
  contentMarshall = settings: evaluate { imports = [ marshall settings ]; services.marshall.artifactContent.host = contentHost; };
  artifactMarshall = contentMarshall {};
  contentProxySettings = {
    services.marshallProxy.artifactContent = { host = contentHost; certificateFile = "/run/proxy/content.pem"; };
  };
  contentProxy = evaluate { imports = [ proxy contentProxySettings ]; };
  contentProxyConfig = contentProxy.services.haproxy.config;
  invalidProxy = settings: !(valid (evaluate { imports = [ proxy settings ]; }));
  contentAcme = evaluate { imports = [ acme ]; services.marshallProxy.artifactContent.host = contentHost; };
  contentDnsAcme = evaluate {
    imports = [ acme ];
    services.marshallProxy.artifactContent.host = contentHost;
    services.marshallProxy.acme = {
      challengeType = "dns-01";
      route53 = { hostedZoneId = "ZEXAMPLE"; credentialsFile = "/run/route53/credentials"; };
    };
  };
  invalidSecrets = settings: !(valid (evaluate { imports = [ secrets settings ]; }));
  invalid = settings: !(valid (evaluate { imports = [ marshall lilly settings ]; }));
  zfsPool = {
    id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    path = "/pool";
    filesystem_id = "zfs:123:456";
    storage = { backend = "zfs"; zpool_guid = "123"; dataset_guid = "456"; dataset = "tank/lilly"; };
  };
  zfs = pools: evaluate { imports = [ lilly ]; networking.hostId = "aabbccdd"; services.lilly.pools = pools; };
  validZfs = pools: let
    cfg = zfs pools;
    result = builtins.tryEval (builtins.deepSeq cfg.services.lilly.pools (valid cfg));
    in result.success && result.value;
  typeRejected = settings: !(builtins.tryEval (builtins.deepSeq
    (evaluate { imports = [ marshall settings ]; }).services.marshall.environmentFile true)).success;
  urlRejected = url: !(builtins.tryEval (builtins.deepSeq
    (evaluate { imports = [ lilly { services.lilly.controlPlane = lib.mkForce url; } ]; })
    .services.lilly.controlPlane true)).success;

  # @cc [owner:ghuntley,label:verification] module-configuration-rejection
  # These checks MUST force actual module assertions/types for all role
  # combinations and negative cases, without substituting service packages.
  encryptedDiagnostics = evaluate {
    imports = [ marshall lilly ];
    services.marshall.crashDumps = { enable = true; publicKeyFile = "/run/keys/dump.pem"; };
    services.lilly.crashDumps = { enable = true; publicKeyFile = "/run/keys/dump.pem"; };
  };
  sdkHealthModule = {
    services.overallsOtelFleet = { enable = true; role = "worker"; hosts = { central = "panterloons"; worker = "dungarees"; }; };
    services.overallsLogging.enable = true;
    # This observer-only fixture has no Lilly/Audi guest binding. Keep the real
    # fleet/SDK modules and their assertions; guest intake is a separate graph.
    services.overallsOtelGuest.enable = lib.mkForce false;
    overalls.fleetNetwork = {
      enable = true; address = "10.90.0.2"; endpointAddress = "192.0.2.2";
      privateKeyFile = "/run/keys/disposable-fleet";
      peers.central = { address = "10.90.0.1"; endpointAddress = "192.0.2.1";
        publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
    };
  };
  sdkHealth = evaluate sdkHealthModule;
  cases = {
    # @cc [owner:ghuntley,label:verification;security] browser-final-runtime-selection
    # Evaluated wrappers MUST clear conflicting inherited download selections and
    # bind the selected package for each replica. Null MUST remain disabled even
    # with an inherited Nix store path; these checks prove wrapper construction,
    # not service startup or HTTP artifact delivery.
    marvinFinalSelection = lib.all (name:
      let service = marvinRuntimeOverride.systemd.services."marshall-${name}";
          expected = lib.escapeShellArg (toString marvinRuntimeOverride.services.marshall.marvinPackage);
          bindings = lib.splitString "OVERALLS_MARVIN_RELEASE=" service.script;
      in lib.hasInfix "-u OVERALLS_MARVIN_RELEASE" service.script
        && builtins.length bindings == 2
        && lib.hasPrefix "${expected} " (builtins.elemAt bindings 1)
        && !(lib.hasInfix "unselected-browser" service.script)
    ) [ "one" "two" "three" ];
    marvinFinalDisabled = lib.all (name:
      let service = marvinDisabled.systemd.services."marshall-${name}";
      in lib.hasInfix "-u OVERALLS_MARVIN_RELEASE" service.script
        && lib.hasInfix "OVERALLS_MARVIN_RELEASE=''" service.script
        && !(lib.hasInfix "unselected-browser" service.script)
    ) [ "one" "two" "three" ];
    # @cc [owner:ghuntley,label:verification;recovery] collector-trace-custody-configuration
    # Evaluated application and guest trace delivery MUST use separate bounded
    # fsynced queues, unlimited retry and no volatile batch before queue custody.
    collectorTraceCustody = let
      settings = sdkHealth.services.opentelemetry-collector.settings;
    in valid sdkHealth && lib.all (binding:
      settings.extensions.${binding.storage}.fsync
      && settings.exporters.${binding.exporter}.sending_queue.enabled
      && settings.exporters.${binding.exporter}.sending_queue.storage == binding.storage
      && settings.exporters.${binding.exporter}.sending_queue.queue_size == 64
      && settings.exporters.${binding.exporter}.retry_on_failure.enabled
      && settings.exporters.${binding.exporter}.retry_on_failure.max_elapsed_time == "0s"
      && !(builtins.elem "batch" settings.service.pipelines.${binding.pipeline}.processors)
    ) [
      { storage = "file_storage/traces"; exporter = "otlp/tempo"; pipeline = "traces"; }
      { storage = "file_storage/application-traces"; exporter = "otlp/tempo-application"; pipeline = "traces/application"; }
    ];
    sdkHealthGraph = valid sdkHealth
      && sdkHealth.services.overallsLogging.outputs.sdk-metrics.plugin == "prometheus_exporter"
      && sdkHealth.services.overallsLogging.outputs.sdk-metrics.settings.host == "127.0.0.1"
      && sdkHealth.services.overallsLogging.outputs.sdk-metrics.settings.port == 9468
      && sdkHealth.services.overallsLogging.outputs.sdk-metrics.queueBytes == 4194304
      && sdkHealth.services.opentelemetry-collector.settings.receivers."prometheus/sdk-health".config.scrape_configs != []
      && builtins.elem "prometheus/sdk-health"
        sdkHealth.services.opentelemetry-collector.settings.service.pipelines."metrics/host".receivers
      && !(builtins.elem 9468 sdkHealth.networking.firewall.allowedTCPPorts);
    sdkHealthPortCollision = !valid (evaluate {
      imports = [ sdkHealthModule ]; services.overallsLogging.sdkMetricsPort = 9467;
    });
    sdkHealthPublicBindRejected = !valid (evaluate {
      imports = [ sdkHealthModule ];
      services.overallsLogging.outputs.sdk-metrics.settings.host = lib.mkForce "0.0.0.0";
    });
    marshallRejectsIPv6 = lib.all (address:
      !(builtins.tryEval (builtins.deepSeq
        (evaluate { services.marshall.instances.one.bindAddress = address; })
          .services.marshall.instances.one.bindAddress true)).success
    ) [ "::" "::1" "2001:db8::1" "::ffff:192.0.2.1" "127.1" ];
    transferRejectsIPv6 = lib.all (address:
      !(builtins.tryEval (builtins.deepSeq
        (evaluate { services.lillyTransfer.listenAddress = address; })
          .services.lillyTransfer.listenAddress true)).success
    ) [ "::" "::1" "2001:db8::1" "::ffff:192.0.2.1" "127.1" "192.000.2.1" ];
    transferAcceptsIPv4 = lib.all (address:
      (evaluate { services.lillyTransfer.listenAddress = address; })
        .services.lillyTransfer.listenAddress == address
    ) [ "0.0.0.0" "127.0.0.1" "192.0.2.1" ];
    inceptionPublicRuntimeFile = valid publicInception
      && publicInception.systemd.services.marshall-one.environment.MARSHALL_INCEPTION_PUBLIC_FILE == "/run/credentials/marshall-one.service/inception-public.json"
      && builtins.elem "inception-public.json:/etc/overalls/inception-public.json"
        publicInception.systemd.services.marshall-one.serviceConfig.LoadCredential
      && !(onlyMarshall.systemd.services.marshall-one.environment ? MARSHALL_INCEPTION_PUBLIC_FILE);
    runtimePublicHost = valid runtimeHost
      && builtins.elem "public-host:/run/inception/public-host" runtimeHost.systemd.services.marshall-one.serviceConfig.LoadCredential
      && lib.hasInfix ''PHX_HOST="$public_host"'' runtimeHost.systemd.services.marshall-one.script
      && runtimeHost.systemd.services.marshall-one.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" ];
    mandatoryTransfer = both.services.lillyTransfer.enable
      && both.services.lillyTransfer.port == 2223
      && builtins.elem 2223 both.networking.firewall.allowedTCPPorts
      && both.systemd.services ? lilly-transfer-sshd;
    transferCannotBeDisabled = invalid { services.lillyTransfer.enable = false; };
    transferSshCollision = invalid { services.openssh.enable = true; services.openssh.ports = [ 2223 ]; };
    audiControlConfiguration = let
      cfg = evaluate { imports = [ marshall ]; services.marshall.ingress = {
        zone = "apps.example.test"; httpsPort = 8443;
      }; };
      env = cfg.systemd.services.marshall-one.environment;
    in valid cfg && env.MARSHALL_INGRESS_ZONE == "apps.example.test"
      && env.MARSHALL_INGRESS_HTTPS_PORT == "8443";
    # Static nameservers keep the evaluated JSON; a runtime address reaches
    # only the selected issuer as a credential rendered at start.
    wildcardStaticNameservers = wildcardMarshall.systemd.services.marshall-one.environment.MARSHALL_FLEET_ACME_NAMESERVERS
      == builtins.toJSON [ { address = "192.0.2.1"; port = 53; } { address = "192.0.2.2"; port = 53; } ];
    wildcardRuntimeNameservers = valid runtimeWildcardMarshall
      && !(runtimeWildcardMarshall.systemd.services.marshall-one.environment ? MARSHALL_FLEET_ACME_NAMESERVERS)
      && builtins.elem "acme-nameserver-1:/run/fleet/ns2" runtimeWildcardMarshall.systemd.services.marshall-one.serviceConfig.LoadCredential
      && !(lib.any (lib.hasPrefix "acme-nameserver") runtimeWildcardMarshall.systemd.services.marshall-two.serviceConfig.LoadCredential)
      && lib.hasInfix ''MARSHALL_FLEET_ACME_NAMESERVERS="$acme_nameservers"'' runtimeWildcardMarshall.systemd.services.marshall-one.script
      && !(lib.hasInfix "acme_nameservers" runtimeWildcardMarshall.systemd.services.marshall-two.script)
      # Pre-start never renders the runtime nameservers, so it must not boot
      # the release with the issuer selected.
      && lib.hasInfix "-u MARSHALL_FLEET_ACME_DIRECTORY" runtimeWildcardMarshall.systemd.services.marshall-one.preStart;
    wildcardNameserverOneForm = !valid (evaluate {
      imports = [ marshall ];
      services.marshall.ingress = {
        zone = "apps.example.test";
        wildcardAcme = {
          issuerInstance = "one";
          directory = "https://ca.example.test/directory";
          issuerCaFile = "/run/ca.pem";
          certificateRootsFile = "/run/roots.pem";
          nameservers = [ { address = "192.0.2.1"; addressFile = "/run/fleet/ns1"; } { address = "192.0.2.2"; } ];
        };
      };
    });
    wildcardIssuerCredentialsOnlyOnSelectedReplica = valid wildcardMarshall
      && (wildcardMarshall.systemd.services.marshall-one.environment ? MARSHALL_FLEET_ACME_DIRECTORY)
      && lib.all (name: !(wildcardMarshall.systemd.services."marshall-${name}".environment ? MARSHALL_FLEET_ACME_DIRECTORY)) [ "two" "three" ];

    encryptedDiagnostics = valid encryptedDiagnostics
      && encryptedDiagnostics.systemd.coredump.settings.Coredump.Storage == "none"
      && encryptedDiagnostics.systemd.coredump.settings.Coredump.ProcessSizeMax == 0
      && encryptedDiagnostics.systemd.services.lilly.serviceConfig.StateDirectory == [ "lilly-crash-dumps" ]
      && encryptedDiagnostics.systemd.services.marshall-one.serviceConfig.StateDirectory == [ "marshall-one-crash-dumps" ];
    missingDiagnosticKey = invalid { services.lilly.crashDumps.enable = true; };

    sysctlOptIn = lib.all (cfg: !cfg.overalls.sysctl.enable
      && !(builtins.elem "tcp_bbr" cfg.boot.kernelModules)
      && !(builtins.elem "sch_fq" cfg.boot.kernelModules)
      && lib.all (key: !(builtins.hasAttr key cfg.boot.kernel.sysctl)) profileKeys)
      [ neither onlyMarshall onlyLilly both onlyProxy ];
    sysctlDefaults = tuned.boot.kernel.sysctl."net.ipv4.tcp_congestion_control" == "bbr"
      && tuned.boot.kernel.sysctl."net.core.default_qdisc" == "fq"
      && builtins.elem "tcp_bbr" tuned.boot.kernelModules
      && builtins.elem "sch_fq" tuned.boot.kernelModules;
    sysctlInheritedPolicy = builtins.removeAttrs tuned.boot.kernel.sysctl profileKeys == neither.boot.kernel.sysctl
      && builtins.removeAttrs tunedStandalone.boot.kernel.sysctl profileKeys == untunedStandalone.boot.kernel.sysctl;
    sysctlStandalone = tunedStandalone.boot.kernel.sysctl == tuned.boot.kernel.sysctl
      && tunedStandalone.boot.kernelModules == tuned.boot.kernelModules
      && !(tunedStandalone.systemd.services ? lilly);
    sysctlOverrides = tunedOverrides.boot.kernel.sysctl."net.ipv4.tcp_congestion_control" == "cubic"
      && tunedOverrides.boot.kernel.sysctl."net.core.default_qdisc" == "fq_codel"
      && tunedOverrides.boot.kernel.sysctl."net.core.wmem_max" == 8388608;
    sysctlRoles = valid tunedRoles && tunedRoles.boot.kernel.sysctl."net.ipv4.ip_forward" == 1
      && tunedRoles.systemd.services.lilly.serviceConfig.LimitNOFILE == 65536
      && tunedRoles.systemd.services.marshall-one.serviceConfig.LimitNOFILE == 65536;
    smtpDisabled = !(onlyMarshall.systemd.services ? overalls-smtprelay);
    smtpPresets = lib.all (provider:
      let cfg = evaluate { imports = [ marshall ];
        services.marshall.githubBootstrapRelease = pkgs.hello;
        services.marshall.smtpRelay = {
        enable = true; from = "noreply@example.test";
        upstream = { inherit provider; region = "us-east-1";
          usernameFile = "/run/smtp/username"; passwordFile = "/run/smtp/password";
        } // lib.optionalAttrs (provider == "generic") { host = "smtp.example.test"; };
      }; }; relay = cfg.services.marshall.smtpRelay;
        launch = cfg.systemd.services.marshall-one.script; in
      valid cfg && cfg.systemd.services.overalls-smtprelay.serviceConfig.DynamicUser
      && relay.upstream.port == (if provider == "resend" then 465 else 587)
      && !(builtins.elem 2525 cfg.networking.firewall.allowedTCPPorts)
      && lib.hasInfix "MARSHALL_MAIL_TRANSPORT=local_relay" launch
      && lib.hasInfix "MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE=" launch
      && lib.hasInfix "-u MARSHALL_SMTP_CA_CERTFILE"
        (builtins.head (lib.splitString "MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE=" launch))
      && lib.all (name:
        let preStart = cfg.systemd.services."marshall-${name}".preStart; in
        lib.hasInfix "MARSHALL_MAIL_TRANSPORT=local_relay" preStart
        && lib.hasInfix "MARSHALL_SMTP_HOST=127.0.0.1" preStart
        && lib.hasInfix "-u MARSHALL_SMTP_USERNAME -u MARSHALL_SMTP_PASSWORD" preStart
      ) [ "one" "two" "three" ]
    ) [ "generic" "ses" "resend" ];
    smtpMissing = !(valid (evaluate { imports = [ marshall ]; services.marshall.smtpRelay.enable = true; }));
    smtpCollision = !(valid (evaluate { imports = [ marshall ]; services.marshall.smtpRelay = {
      enable = true; from = "noreply@example.test"; port = 4443;
      upstream = { provider = "resend"; passwordFile = "/run/smtp/password"; };
    }; }));
    smtpResendUsername = valid (evaluate { imports = [ marshall ]; services.marshall.smtpRelay = {
      enable = true; from = "noreply@example.test";
      upstream = { provider = "resend"; passwordFile = "/run/smtp/password"; };
    }; });
    smtpInvalidTypes = lib.all (upstream:
      !(builtins.tryEval (builtins.deepSeq (evaluate { imports = [ marshall ];
        services.marshall.smtpRelay.upstream = upstream;
      }).services.marshall.smtpRelay.upstream true)).success
    ) [ { passwordFile = "/nix/store/plaintext"; } { tls = "plaintext"; } { auth = "none"; } ];
    updaterDisabled = !(neither.systemd.services ? overalls-auto-update);
    updaterIndependent = valid onlyUpdater && !onlyUpdater.services.marshall.enable && !onlyUpdater.services.lilly.enable;
    updaterBudget = valid updatingMarshall && !(valid (evaluate { imports = [ marshall updater ]; }));
    updaterSurvivesSwitch = !onlyUpdater.systemd.services.overalls-auto-update.restartIfChanged
      && !onlyUpdater.systemd.services.overalls-auto-update.stopIfChanged;
    updaterBoundedHealth = onlyUpdater.services.overallsAutoUpdate.healthTimeout == 120;
    updaterPolling = onlyUpdater.systemd.timers.overalls-auto-update.timerConfig.OnUnitInactiveSec == "10s"
      && onlyUpdater.systemd.timers.overalls-auto-update.timerConfig.RandomizedDelaySec == "300s";
    updaterNoCompetingActivation = !(valid (evaluate { imports = [ updater ]; system.autoUpgrade.enable = true; }));
    updaterGitPreparationDoesNotStopUpdater = (evaluate {
      imports = [ updater ]; services.overallsAutoUpdate.secretUnits = [ "overalls-secrets-git.service" ];
    }).systemd.services.overalls-auto-update.requires == [];
    updaterDescriptor = builtins.deepSeq updatingMarshall.system.build.overallsDeployment.drvPath true;
    neither = valid neither && !(neither.systemd.services ? lilly) && !(neither.systemd.services ? marshall-one);
    marshallOnly = valid onlyMarshall && !(onlyMarshall.systemd.services ? lilly);
    lillyOnly = valid onlyLilly && !(onlyLilly.systemd.services ? marshall-one);
    both = valid both && both.systemd.services ? lilly && both.systemd.services ? marshall-three;
    nativeZfs = validZfs [ zfsPool ];
    zfsRetiredBudgetRejected = !(validZfs [ (zfsPool // { logical_budget_bytes = 1099511627776; }) ]);
    zfsWrongGuid = !valid (zfs [ (zfsPool // { filesystem_id = "zfs:123:999"; }) ]);
    zfsDuplicateBacking = !valid (zfs [ zfsPool (zfsPool // { id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"; }) ]);
    missingZfsIdentity = !(validZfs [ (builtins.removeAttrs zfsPool [ "storage" ]) ]);
    ext4Rejected = !(validZfs [ (zfsPool // { filesystem_id = "ext4:123"; storage = null; }) ]);
    unprivilegedMarshall = both.systemd.services.marshall-one.serviceConfig.DynamicUser;
    separateGuestSlice = !(both.systemd.services.lilly.serviceConfig ? Slice) && both.systemd.slices ? lilly;
    noPrivateLillyMounts = !(both.systemd.services.lilly.serviceConfig ? ProtectSystem) && !(both.systemd.services.lilly.serviceConfig ? PrivateTmp);
    guestBudget = both.systemd.slices.lilly.sliceConfig.MemoryMax == "98304M";
    duplicatePorts = invalid { services.marshall.instances.two.port = lib.mkForce 4443; };
    editorSingleLabelZone = invalid { services.marshall.ingress.zone = "local"; };
    editorCanonicalZone = valid (evaluate { imports = [ marshall ]; services.marshall.ingress.zone = "apps.example.test"; });
    nonEditorSingleLabelZone = valid (evaluate { imports = [ marshall ]; services.marshall = { editorPackages = {}; ingress.zone = "local"; }; });
    editorTargetRegistry = valid dualEditorMarshall && editorRegistry.version == 1
      && builtins.attrNames editorRegistry.targets == [ "linux-x64" "win32-x64" ]
      && editorRegistry.targets.win32-x64 == { protocol = 1; commit = windowsEditor.sourceCommit; release = windowsEditor.releaseId; }
      && lib.hasInfix "MARSHALL_INGRESS_EDITOR_RELEASES=" dualEditorMarshall.systemd.services.marshall-one.script;
    editorEmptyRegistry = (builtins.fromJSON (evaluate {
      imports = [ marshall ]; services.marshall.editorPackages = {};
    }).systemd.services.marshall-one.environment.MARSHALL_INGRESS_EDITOR_RELEASES) == { version = 1; targets = {}; };
    editorUnknownTarget = !(builtins.tryEval (builtins.deepSeq (evaluate {
      imports = [ marshall ]; services.marshall.editorPackages.windows-x64 = windowsEditor;
    }).services.marshall.editorPackages true)).success;
    fleetTunnelHostRoutes = valid fleetTunnel
      && fleetTunnel.networking.wireguard.interfaces.fleet0.ips == [ "10.90.0.1/32" ]
      && (builtins.head fleetTunnel.networking.wireguard.interfaces.fleet0.peers).allowedIPs == [ "10.90.0.2/32" ]
      && fleetTunnel.systemd.services.wireguard-fleet0.requires == [ "fleet-key.service" ]
      && !fleetTunnel.networking.wireguard.interfaces.fleet0.generatePrivateKeyFile;
    fleetTunnelFirewall = valid fleetTunnelNft
      && !(builtins.elem 5443 fleetTunnel.networking.firewall.allowedTCPPorts)
      && lib.hasInfix "-i fleet0 -s 10.90.0.2 -d 10.90.0.1 -p tcp --dport 5443" fleetTunnel.networking.firewall.extraCommands
      && lib.hasInfix ''iifname "fleet0" ip saddr 10.90.0.2 ip daddr 10.90.0.1 tcp dport 5443'' fleetTunnelNft.networking.firewall.extraInputRules
      && lib.hasInfix ''iifname "fleet0" counter drop'' fleetTunnelNft.networking.nftables.tables.overalls-fleet.content;
    fleetTunnelIPv6Refused = !(valid (evaluate { imports = [ fleetNetwork ]; networking.enableIPv6 = true; }));
    fleetTunnelFirewallRequired = !(valid (evaluate { imports = [ fleetNetwork ]; networking.firewall.enable = false; }));
    fleetTunnelTrustRefused = !(valid (evaluate { imports = [ fleetNetwork ]; networking.firewall.trustedInterfaces = [ "fleet0" ]; }));
    fleetTunnelSelfRefused = !(valid (evaluate { imports = [ fleetNetwork ]; overalls.fleetNetwork.address = lib.mkForce "10.90.0.2"; }));
    duplicateFleetPorts = invalid { services.marshall.instances.two.fleetPort = 5443; };
    fleetBrowserCollision = invalid { services.marshall.instances.one.fleetPort = 4444; };
    fleetLoopbackDefault = onlyMarshall.services.marshall.instances.one.fleetBindAddress == "127.0.0.1"
      && onlyMarshall.services.marshall.instances.one.fleetPort == 5443
      && lib.hasInfix "MARSHALL_FLEET_TLS_PORT=5443" onlyMarshall.systemd.services.marshall-one.script;
    fleetFirewallClosed = !(builtins.elem 5443 (evaluate {
      imports = [ marshall ]; services.marshall.openFirewall = true;
    }).networking.firewall.allowedTCPPorts);
    fleetDualBind = let cfg = evaluate {
      imports = [ marshall ];
      services.marshall.instances.one = { fleetBindAddress = "10.90.0.1"; fleetLoopback = true; };
    }; in valid cfg && lib.hasInfix "MARSHALL_FLEET_LOOPBACK=true" cfg.systemd.services.marshall-one.script;
    missingInstances = invalid { services.marshall.instances = lib.mkForce {}; };
    connectionBudget = invalid { services.marshall.databaseConnectionBudget = lib.mkForce 42; };
    memoryBudget = invalid { services.marshall.memoryMiB = 512; };
    badIdentity = invalid { services.marshall.instances."bad.name" = { port = 4446; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; }; };
    collidingState = invalid { services.lilly.vmStateDirectory = "/var/lib/lilly/control"; };
    longSocketPath = invalid { services.lilly.vmStateDirectory = "/var/lib/lilly/this-path-is-too-long-to-fit-within-the-unix-socket-budget"; };
    flushingFirewall = invalid { networking.nftables.flushRuleset = true; };
    storeSecret = typeRejected { services.marshall.environmentFile = "/nix/store/example-secret"; };
    specifierSecret = typeRejected { services.marshall.environmentFile = "/run/%n.env"; };
    traversalSecret = typeRejected { services.marshall.environmentFile = "/run/../etc/secret"; };
    embeddedCredentialURL = urlRejected "https://user:secret@control.example.test";
    queryURL = urlRejected "https://control.example.test?token=secret";
    plaintextURL = urlRejected "http://control.example.test";
    ipv6URL = !urlRejected "https://[::1]:4443";
    proxyOnly = valid onlyProxy && !onlyProxy.services.marshall.enable && !onlyProxy.services.lilly.enable;
    proxyPortCollision = invalid { imports = [ proxy ]; services.marshallProxy.port = 4443; };
    emptyProxyBackends = invalid { imports = [ proxy ]; services.marshallProxy.backends = lib.mkForce {}; };
    secretBootstrap = valid onlySecrets && !onlySecrets.services.openssh.enable && onlySecrets.services.openssh.generateHostKeys && !onlySecrets.services.marshall.enable && !onlySecrets.services.lilly.enable;
    absentHostIdentity = invalidSecrets { services.openssh.hostKeys = lib.mkForce []; };
    absentRecipientGroup = invalidSecrets { services.overallsSecrets.bundles.example.group = "nonexistent"; };
    emptySecretBundle = invalidSecrets { services.overallsSecrets.bundles.example.outputs = lib.mkForce {}; };
    multipleRawSecrets = invalidSecrets { services.overallsSecrets.bundles.example.outputs.credential.secrets = lib.mkForce [ "ONE" "TWO" ]; };
    unsafeSecretFilename = invalidSecrets { services.overallsSecrets.bundles.example.outputs."../escape" = { format = "raw"; secrets = [ "TOKEN" ]; }; };
    httpDefault = onlyAcme.services.marshallProxy.acme.challengeType == "http-01"
      && onlyAcme.security.acme.certs."control.example.test".listenHTTP == "127.0.0.1:9080"
      && onlyAcme.security.acme.certs."control.example.test".credentialFiles == {}
      && !(onlyAcme.system.build ? marshallRoute53Policy);
    dnsExplicit = valid dnsAcme && dnsAcme.security.acme.certs."control.example.test".dnsProvider == "route53"
      && dnsAcme.security.acme.certs."control.example.test".listenHTTP == null
      && !(dnsAcme.systemd.services ? marshall-acme-http)
      && !(builtins.elem 80 dnsAcme.networking.firewall.allowedTCPPorts)
      && dnsAcme.system.build ? marshallRoute53Policy;
    missingDnsInputs = invalidAcme { services.marshallProxy.acme.challengeType = "dns-01"; };
    badChallenge = acmeTypeRejected { challengeType = "tls-alpn-01"; };
    ipv6DnsResolver = acmeTypeRejected { route53.dnsResolver = "[::1]:53"; };
    ipv6ProxyBackend = !(builtins.tryEval (builtins.deepSeq
      (evaluate { imports = [ proxy ]; services.marshallProxy.backends.one.address = lib.mkForce "[::1]"; })
      .services.marshallProxy.backends true)).success;
    acmeIPv4Sandbox = onlyAcme.systemd.services.marshall-acme-http.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" ]
      && onlyAcme.systemd.services.marshall-certificate.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" ];
    acmePublicationCleanup = let cleanup = onlyAcme.systemd.services.marshall-certificate.serviceConfig.ExecStopPost;
      in lib.hasInfix "publish.py --cleanup" cleanup && !(lib.hasInfix "prepare.py --cleanup" cleanup);
    badDnsSecret = acmeTypeRejected { route53.credentialsFile = "/nix/store/secret"; };
    badResponderIP = acmeTypeRejected { http01.bindAddress = "999.1.1.1"; };
    badResponderPort = acmeTypeRejected { http01.port = 80; };
    httpPeers = valid sharedAcme && builtins.length sharedAcme.services.marshallProxy.acme.http01.peers == 2;
    httpPrivateFirewall = builtins.elem 80 sharedAcme.networking.firewall.allowedTCPPorts
      && !(builtins.elem 9080 sharedAcme.networking.firewall.allowedTCPPorts)
      && lib.hasInfix "-s 192.168.1.2 -d 192.168.1.1" sharedAcme.networking.firewall.extraCommands;
    httpFirewallOptOut = noFirewallAcme.networking.firewall.allowedTCPPorts == []
      && !(lib.hasInfix "9080" noFirewallAcme.networking.firewall.extraCommands);
    httpNftFirewall = nftAcme.networking.firewall.extraCommands == ""
      && lib.hasInfix "ip saddr 192.168.1.2 ip daddr 192.168.1.1 tcp dport 9080 accept" nftAcme.networking.firewall.extraInputRules;
    httpIPv6 = acmeTypeRejected { http01 = {
      bindAddress = "fd00::1"; peers = [ { address = "fd00::2"; } ];
    }; };
    httpWildcard = invalidAcme { services.marshallProxy.acme.http01.bindAddress = "0.0.0.0"; };
    httpLoopbackPeers = invalidAcme { services.marshallProxy.acme.http01.peers = [{ address = "192.168.1.2"; }]; };
    httpPublicPeer = invalidAcme { imports = [ peers ]; services.marshallProxy.acme.http01.peers = lib.mkForce [{ address = "8.8.8.8"; }]; };
    httpSelfPeer = invalidAcme { imports = [ peers ]; services.marshallProxy.acme.http01.peers = lib.mkForce [{ address = "192.168.1.1"; }]; };
    httpDuplicatePeers = invalidAcme { imports = [ peers ]; services.marshallProxy.acme.http01.peers = lib.mkForce [{ address = "192.168.1.2"; } { address = "192.168.1.2"; port = 9090; }]; };
    httpMixedFamilies = acmeTypeRejected { http01.peers = [{ address = "fd00::2"; }]; };
    httpPortCollision = invalidAcme { services.marshallProxy.port = 80; };
    httpResponderCollision = invalidAcme { services.marshallProxy.port = 9080; };
    httpBackendCollision = invalidAcme { imports = [ marshall ]; services.marshallProxy.acme.http01.port = 4443; };
    httpIndependentBootstrap = !(builtins.elem "haproxy.service" onlyAcme.systemd.services.marshall-acme-http.after)
      && builtins.elem "marshall-acme-http.service" onlyAcme.systemd.services."acme-order-renew-control.example.test".after;
    acmeProxyOnly = valid onlyAcme && !onlyAcme.services.marshall.enable && !onlyAcme.services.lilly.enable;
    acmeWithoutProxy = invalidAcme { services.marshallProxy.enable = lib.mkForce false; };
    acmeRootProxy = invalidAcme { services.haproxy.user = "root"; };
    acmeWithoutTerms = invalidAcme { security.acme.acceptTerms = lib.mkForce false; };
    acmeWrongPublication = invalidAcme { services.marshallProxy.certificateFile = lib.mkForce "/run/other/full.pem"; };
    # @cc [owner:ghuntley,label:verification;security] artifact-content-module-rendering
    # The content origin MUST be absent by default, MUST reach Marshall only
    # through the final wrapper with a distinct per-instance port, and the
    # proxy MUST render the content ACL, credential deletes, method denial,
    # Set-Cookie deletion and a health-tracking content backend while keeping
    # request logs free of URLs and headers.
    artifactContentDefault = let script = onlyMarshall.systemd.services.marshall-one.script; in
      onlyMarshall.services.marshall.artifactContent.host == null
      && onlyMarshall.services.marshall.instances.one.artifactPort == 6443
      && lib.hasInfix "-u MARSHALL_ARTIFACT_CONTENT_HOST -u MARSHALL_ARTIFACT_TLS_PORT -u MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO" script
      && !(lib.hasInfix "MARSHALL_ARTIFACT_CONTENT_HOST=" script)
      && !(lib.hasInfix "MARSHALL_ARTIFACT_TLS_PORT=" script)
      && !(lib.hasInfix "MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO=" script)
      && lib.hasInfix "-u MARSHALL_ARTIFACT_CONTENT_HOST" onlyMarshall.systemd.services.marshall-one.preStart
      && !(builtins.elem 6443 (evaluate { imports = [ marshall ]; services.marshall.openFirewall = true; }).networking.firewall.allowedTCPPorts);
    artifactContentRendered = valid artifactMarshall
      && lib.all ({ name, port }: lib.hasInfix "MARSHALL_ARTIFACT_CONTENT_HOST=${contentHost} MARSHALL_ARTIFACT_TLS_PORT=${toString port}"
        artifactMarshall.systemd.services."marshall-${name}".script)
        [ { name = "one"; port = 6443; } { name = "two"; port = 6444; } { name = "three"; port = 6445; } ]
      && !(lib.hasInfix "MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO=" artifactMarshall.systemd.services.marshall-one.script)
      && !(artifactMarshall.systemd.services.marshall-one.environment ? MARSHALL_ARTIFACT_CONTENT_HOST);
    artifactContentFirewall = builtins.elem 6443 (contentMarshall { services.marshall.openFirewall = true; }).networking.firewall.allowedTCPPorts;
    artifactPortCollision = !(valid (contentMarshall { services.marshall.instances.two.artifactPort = 5443; }));
    artifactBrowserPortCollision = !(valid (contentMarshall { services.marshall.instances.two.artifactPort = 4445; }));
    artifactSamePublicHost = !(valid (evaluate { imports = [ marshall ]; services.marshall.artifactContent.host = "control.example.test"; }));
    artifactHostType = lib.all (host: !(builtins.tryEval (builtins.deepSeq
      (evaluate { imports = [ marshall ]; services.marshall.artifactContent.host = host; }).services.marshall.artifactContent.host true)).success)
      [ "UserContent.Example.Test" "usercontent" "*.example.test" "usercontent.example.test:443" ];
    artifactDebugEchoRefused = !(valid (contentMarshall { services.marshall.artifactContent.debugEcho = true; }))
      && !(valid (evaluate { imports = [ marshall ]; services.marshall = { machineTestFixture = true; artifactContent.debugEcho = true; }; }));
    artifactDebugEchoFixture = let cfg = contentMarshall { services.marshall = { machineTestFixture = true; artifactContent.debugEcho = true; }; };
      in valid cfg && lib.hasInfix "MARSHALL_ARTIFACT_CONTENT_DEBUG_ECHO=true" cfg.systemd.services.marshall-one.script;
    proxyContentDefault = !(lib.hasInfix "content_host" onlyProxy.services.haproxy.config)
      && !(lib.hasInfix "marshall_artifact_nodes" onlyProxy.services.haproxy.config)
      && lib.hasInfix "http-request deny deny_status 421 unless public_host\n" onlyProxy.services.haproxy.config;
    proxyContentRendered = valid contentProxy && lib.all (fragment: lib.hasInfix fragment contentProxyConfig) [
      "ssl crt /run/proxy/full.pem crt /run/proxy/content.pem alpn h2,http/1.1"
      "acl content_host hdr(host),lower -m str ${contentHost} ${contentHost}:443"
      "http-request deny deny_status 421 unless public_host || content_host"
      "http-request deny deny_status 405 if content_host !METH_GET"
      "http-request del-header Cookie if content_host"
      "http-request del-header Authorization if content_host"
      "http-request del-header Proxy-Authorization if content_host"
      "http-request set-header X-Forwarded-Host ${contentHost} if content_host"
      "use_backend marshall_artifact_nodes if content_host"
      "use_backend marshall_nodes if public_host"
      "backend marshall_artifact_nodes"
      "http-response del-header Set-Cookie"
      "server one 127.0.0.1:6443 resolve-prefer ipv4 ssl verify required verifyhost backend.example.test sni str(backend.example.test) ca-file"
      "track marshall_nodes/one"
      "server one 127.0.0.1:4443 resolve-prefer ipv4 ssl verify required verifyhost backend.example.test sni str(backend.example.test) check check-ssl"
    ] && !(lib.hasInfix "default_backend" contentProxyConfig)
      && !(lib.any (field: lib.hasInfix field contentProxyConfig) [ "%r" "%HU" "%HP" "%hr" "%hs" "capture" ]);
    proxyContentWithoutCertificate = invalidProxy { services.marshallProxy.artifactContent.host = contentHost; };
    proxyContentCertificateWithoutHost = invalidProxy { services.marshallProxy.artifactContent.certificateFile = "/run/proxy/content.pem"; };
    proxyContentSameHost = invalidProxy { services.marshallProxy.artifactContent = { host = "control.example.test"; certificateFile = "/run/proxy/content.pem"; }; };
    proxyContentSharedCertificate = invalidProxy { services.marshallProxy.artifactContent = { host = contentHost; certificateFile = "/run/proxy/full.pem"; }; };
    proxyContentColocatedMismatch = invalid { imports = [ proxy contentProxySettings ]; services.marshallProxy.port = 8443; };
    proxyContentColocated = valid (evaluate { imports = [ marshall proxy contentProxySettings ];
      services.marshallProxy.port = 8443; services.marshall.artifactContent.host = contentHost; });
    proxyArtifactPortCollision = !(valid (evaluate { imports = [ marshall proxy contentProxySettings ];
      services.marshallProxy.port = 6443; services.marshall.artifactContent.host = contentHost; }))
      && valid (evaluate { imports = [ marshall proxy ]; services.marshallProxy.port = 6443; });
    acmeContentCertificate = valid contentAcme
      && contentAcme.services.marshallProxy.artifactContent.certificateFile == "/var/lib/overalls-certificates/marshall-artifact-content/full.pem"
      && contentAcme.security.acme.certs.${contentHost}.listenHTTP == "127.0.0.1:9080"
      && contentAcme.security.acme.certs.${contentHost}.extraDomainNames == []
      && contentAcme.security.acme.certs."control.example.test".extraDomainNames == []
      && builtins.elem "acme-order-renew-control.example.test.service" contentAcme.systemd.services."acme-order-renew-${contentHost}".after
      && builtins.elem "marshall-acme-http.service" contentAcme.systemd.services."acme-order-renew-${contentHost}".after
      && contentAcme.systemd.services ? marshall-artifact-certificate
      && contentAcme.systemd.timers ? marshall-artifact-certificate
      && builtins.elem "marshall-artifact-certificate.service" contentAcme.systemd.services.haproxy.wants
      && builtins.length (lib.filter (lib.hasInfix "publish.py --cached") contentAcme.systemd.services.haproxy.serviceConfig.ExecStartPre) == 2
      && lib.hasInfix "crt /var/lib/overalls-certificates/marshall/full.pem crt /var/lib/overalls-certificates/marshall-artifact-content/full.pem" contentAcme.services.haproxy.config
      && !(onlyAcme.systemd.services ? marshall-artifact-certificate)
      && builtins.length (lib.filter (lib.hasInfix "publish.py --cached") onlyAcme.systemd.services.haproxy.serviceConfig.ExecStartPre) == 1;
    acmeContentDns = valid contentDnsAcme && contentDnsAcme.security.acme.certs.${contentHost}.dnsProvider == "route53"
      && !(contentDnsAcme.systemd.services ? marshall-acme-http);
    acmeContentWrongPublication = invalidAcme {
      services.marshallProxy.artifactContent = { host = contentHost; certificateFile = lib.mkForce "/run/other/content.pem"; };
    };
  };
  failed = lib.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert !(onlyMarshall.systemd.services.marshall-one.environment ? MARSHALL_SSH_HOST_TRUST);
assert lib.all (name: (builtins.fromJSON pinnedMarshall.systemd.services.${"marshall-" + name}.environment.MARSHALL_SSH_HOST_TRUST).ca == sshCa) [ "one" "two" "three" ];
assert !(builtins.tryEval (evaluate { imports = [ marshall ]; services.marshall.sshHostCa.publicKey = "invalid"; }).systemd.services.marshall-one.environment.MARSHALL_SSH_HOST_TRUST).success;
assert lib.assertMsg (failed == []) "NixOS configuration checks failed: ${lib.concatStringsSep ", " failed}";
# Runs the issuer's rendered nameserver line against a credential directory.
pkgs.runCommand "overalls-module-configuration-check.json" {
  nativeBuildInputs = [ pkgs.gnugrep ];
  script = pkgs.writeText "marshall-one-script" runtimeWildcardMarshall.systemd.services.marshall-one.script;
  cases = pkgs.writeText "overalls-module-configuration-cases.json" (builtins.toJSON cases);
} ''
  mkdir credentials
  printf '198.51.100.53\n' > credentials/acme-nameserver-1
  CREDENTIALS_DIRECTORY="$PWD/credentials"
  render="$(grep -E '^ *acme_nameservers=' "$script")"
  eval "$render"
  test "$acme_nameservers" = '[{"address":"192.0.2.1","port":53},{"address":"198.51.100.53","port":5353}]'
  cp "$cases" "$out"
''
