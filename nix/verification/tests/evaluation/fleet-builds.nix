{ pkgs, nixpkgs, module, fleetModule, hosts }:
let
  inherit (pkgs) lib;
  # The production deployment delegates no builds (ADR-0284), so a synthetic
  # scheduler and peer exercise the module with the reviewed shapes (ADR-0248).
  ciphertext = name: "${pkgs.writeText "${name}.enc.json" "{}"}";
  certificate = ../../../../fleet/fleet-builds/grpc-ca.crt;
  keyOf = suffix: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI${suffix}";
  builders = lib.mapAttrs (name: address: {
    inherit address; port = 2222; logicalCpus = 96;
    systems = [ "x86_64-linux" ];
    supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" "nested-kvm" ];
    clientPublicKeys = [ (keyOf "GoXLPkh3fZaCVQkZnoYqCCTTuCCnlt2FIs4LV1Cj6IH ${name}-remote-builders") ];
    hostPublicKey = keyOf "ML9xc+noYLHshIEx68vs9wbTO6IaehIrei3EQeDjlYd";
    encryptedFile = ciphertext "${name}-remote-builders";
  }) { sched = "100.64.0.1"; peer = "100.64.0.2"; };
  registry = {
    scheduler = "sched";
    grpcCaCertificate = certificate;
    machines = lib.mapAttrs (name: builder: {
      inherit (builder) address logicalCpus systems supportedFeatures;
      grpcCertificate = certificate;
      encryptedFile = ciphertext "${name}-fleet-builds";
    }) builders;
  };
  participant = name: evaluate {
    overalls.fleetBuilds.localName = lib.mkForce name;
    overalls.remoteBuilders = { enable = true; localName = name; machines = builders; };
  };
  sched = participant "sched";
  peer = participant "peer";
  # Keep nonparticipant coverage independent of production hosts.
  other = evaluate {
    overalls.fleetBuilds.enable = lib.mkForce false;
    overalls.remoteBuilders = {
      enable = true;
      localName = "cache-only";
      machines = builders // {
        cache-only = builders.peer // { address = "192.0.2.10"; };
      };
    };
  };
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ module fleetModule {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      overalls.fleetBuilds = { enable = true; localName = "peer"; } // registry;
    } extra ];
  }).config;
  valid = c: lib.all (a: a.assertion) c.assertions;
  fails = extra: let result = builtins.tryEval (builtins.deepSeq (evaluate extra).system.build.toplevel.drvPath true);
    in !result.success;
  grpcSubs = c: lib.filter (lib.hasPrefix "grpc://") c.nix.settings.substituters;
  sshSubs = c: lib.filter (lib.hasPrefix "ssh-ng://") c.nix.settings.substituters;
  rules = c: c.services.nix-grpc-daemon.accessRules;
  cases = {
    # Production has no build delegation; the hosts still evaluate without it.
    production-no-delegation = !hosts.overalls.config.overalls.fleetBuilds.enable
      && !hosts.overalls.config.nix.distributedBuilds;
    scheduler-no-delegation = sched.nix.buildMachines == [] && !sched.nix.distributedBuilds;
    # No external builders (ADR-0282): both run the unmodified compact-log Nix.
    no-external-builders = !(sched.nix.settings ? external-builders) && !(peer.nix.settings ? external-builders);
    compact-nix = sched.nix.package.outPath == sched.programs.nix-compact.package.outPath
      && peer.nix.package.outPath == peer.programs.nix-compact.package.outPath;
    peer-delegates-once = map (m: m.hostName) peer.nix.buildMachines
      == [ "grpc://${registry.machines.sched.address}:50051?system=x86_64-linux&connect-timeout=5&ca-cert=/etc/nix-grpc-store/ca.crt" ]
      # Nix derives a lock file name from the URI; it must fit NAME_MAX.
      && lib.all (m: builtins.stringLength m.hostName < 200) peer.nix.buildMachines
      && builtins.elem "L+ /run/nix-grpc-store/client.key - - - - /run/overalls-secrets/fleet-builds/grpc.key" peer.systemd.tmpfiles.rules;
    grpc-caches = lib.length (grpcSubs sched) == 1 && lib.length (grpcSubs peer) == 1
      && lib.all (url: lib.hasInfix "trusted=true" url && lib.hasInfix "connect-timeout=5" url) (grpcSubs sched ++ grpcSubs peer)
      && !(lib.any (lib.hasInfix "overalls-builder-peer") (sshSubs sched))
      && !(lib.any (lib.hasInfix "overalls-builder-sched") (sshSubs peer));
    # An evaluated nonparticipant keeps its ssh-ng caches to both hosts.
    others-unchanged = valid other && !(other.overalls.fleetBuilds.enable) && grpcSubs other == []
      && lib.any (lib.hasInfix "overalls-builder-sched") (sshSubs other)
      && lib.any (lib.hasInfix "overalls-builder-peer") (sshSubs other);
    access-rules = rules sched == [ { cn = "build-peer"; role = "trusted"; } ]
      && rules peer == [ { cn = "build-sched"; role = "read-only"; } ]
      && sched.services.nix-grpc-daemon.trustClients && !peer.services.nix-grpc-daemon.trustClients;
    signatures = sched.nix.settings.require-sigs && peer.nix.settings.require-sigs;
    closed-listeners = lib.all (c: !(lib.elem 50051 c.networking.firewall.allowedTCPPorts)) [ sched peer ];
    valid = valid sched && valid peer && valid (evaluate {});
    scheduler-builders = !valid (evaluate { overalls.fleetBuilds.localName = lib.mkForce "sched";
      nix.buildMachines = [ { hostName = "localhost"; system = "x86_64-linux"; } ]; });
    open-port = !valid (evaluate { networking.firewall.allowedTCPPorts = [ 50051 ]; });
    unsigned = !valid (evaluate { nix.settings.require-sigs = lib.mkForce false; });
    unknown-local = fails { overalls.fleetBuilds.localName = lib.mkForce "missing"; };
    bad-address = fails { overalls.fleetBuilds.machines.peer.address = lib.mkForce "peer ProxyCommand=bad"; };
  };
in
assert lib.assertMsg (lib.all (v: v) (lib.attrValues cases)) ("Fleet builds evaluation failed: " + lib.concatStringsSep "," (lib.attrNames (lib.filterAttrs (_: v: !v) cases)));
pkgs.writeText "fleet-builds-evaluation.json" (builtins.toJSON cases)
