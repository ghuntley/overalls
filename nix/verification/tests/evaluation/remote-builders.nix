{ pkgs, nixpkgs, module }:
let
  inherit (pkgs) lib;
  key = builtins.head (import ../../../policy/identity/users.nix).ghuntley.sshKeys;
  machine = address: {
    inherit address;
    logicalCpus = 32;
    systems = [ "x86_64-linux" ];
    supportedFeatures = [ "kvm" "big-parallel" ];
    clientPublicKeys = [ key ];
    hostPublicKey = key;
    encryptedFile = "/run/fixture.enc.json";
  };
  machines = { alpha = machine "192.0.2.1"; beta = machine "192.0.2.2"; };
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      overalls.access.enable = true;
      overalls.remoteBuilders = { enable = true; localName = "alpha"; inherit machines; };
      nix.settings.substituters = [ "https://cache.example.test" ];
      nix.settings.trusted-public-keys = [ "fixture:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ];
    } extra ];
  }).config;
  cfg = evaluate {};
  reverse = evaluate { overalls.remoteBuilders.localName = lib.mkForce "beta"; };
  valid = c: lib.all (a: a.assertion) c.assertions;
  fails = extra: let result = builtins.tryEval (builtins.deepSeq (evaluate extra).system.build.toplevel.drvPath true);
    in !result.success;
  fleet = import ../../../../fleet/remote-builders.nix { inherit lib; };
  inventory = (import ../../../platform/hosts/inventory.nix { inherit lib; }).hosts;
  # nproc --all over pinned administrative SSH (the replacement Dungarees and
  # Panterloons AX162 hosts 2026-10-20), restated independently of the roster.
  measuredCpus = { dungarees = 96; panterloons = 96; };
  cases = {
    fleet-inputs = lib.all (name: builtins.pathExists fleet.${name}.encryptedFile
      && fleet.${name}.hostPublicKey == builtins.head inventory.${name}.identity.sshKeys
      && fleet.${name}.logicalCpus == measuredCpus.${name}) (builtins.attrNames fleet)
      && fleet ? dungarees && fleet ? panterloons;
    # A base declaration awaiting its installed key is not a builder peer.
    unkeyed-omitted = lib.all (name: inventory.${name}.identity.sshKeys != []) (builtins.attrNames fleet);
    disabled = !(evaluate { overalls.remoteBuilders.enable = lib.mkForce false; }).nix.sshServe.enable;
    empty-systems = !valid (evaluate { overalls.remoteBuilders.machines.beta.systems = lib.mkForce []; });
    unsigned-global = !valid (evaluate { nix.settings.require-sigs = lib.mkForce false; });
    valid = valid cfg && valid reverse;
    cache-only = cfg.nix.buildMachines == [] && !cfg.nix.distributedBuilds;
    reciprocal-caches = lib.any (url: lib.hasInfix "ssh-ng://nix-ssh@overalls-builder-beta?trusted=true" url) cfg.nix.settings.substituters
      && lib.any (url: lib.hasInfix "ssh-ng://nix-ssh@overalls-builder-alpha?trusted=true" url) reverse.nix.settings.substituters;
    caches-preserved = builtins.elem "https://cache.example.test" cfg.nix.settings.substituters
      && builtins.elem "https://cache.nixos.org/" cfg.nix.settings.substituters;
    signing-preserved = cfg.nix.settings.require-sigs && builtins.elem "fixture:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" cfg.nix.settings.trusted-public-keys;
    restrictions = cfg.nix.sshServe.trusted && cfg.nix.sshServe.protocol == "ssh-ng"
      && lib.hasInfix "ForceCommand" cfg.services.openssh.extraConfig
      && lib.hasInfix "DisableForwarding yes" cfg.services.openssh.extraConfig
      && cfg.services.openssh.settings.AllowUsers == [ "ghuntley" "nix-ssh" ];
    pins = lib.hasInfix "StrictHostKeyChecking yes" cfg.programs.ssh.extraConfig
      && cfg.environment.etc."ssh/overalls-builders-known-hosts".text == "overalls-builder-beta ${key}\n";
    custody = cfg.services.overallsSecrets.bundles.remote-builders.group == "root"
      && cfg.systemd.services.nix-daemon.requires == []
      && builtins.elem "overalls-secrets-remote-builders.service" cfg.systemd.services.nix-daemon.partOf;
    unknown-local = !valid (evaluate { overalls.remoteBuilders.localName = lib.mkForce "missing"; });
    no-peer = !valid (evaluate { overalls.remoteBuilders.machines = lib.mkForce { alpha = machine "192.0.2.1"; }; });
    duplicate-endpoint = !valid (evaluate { overalls.remoteBuilders.machines.beta.address = lib.mkForce "192.0.2.1"; });
    reserved-account = !valid (evaluate { overalls.access.users.nix-ssh = { login = true; sshKeys = [ key ]; }; });
    missing-keys = !valid (evaluate { overalls.remoteBuilders.machines.beta.clientPublicKeys = lib.mkForce []; });
    zero-cpus = fails { overalls.remoteBuilders.machines.beta.logicalCpus = lib.mkForce 0; };
    bad-key = fails { overalls.remoteBuilders.machines.beta.hostPublicKey = lib.mkForce "untrusted"; };
    bad-address = fails { overalls.remoteBuilders.machines.beta.address = lib.mkForce "peer ProxyCommand=bad"; };
  };
in
assert lib.assertMsg (lib.all (v: v) (lib.attrValues cases)) ("Remote builders evaluation failed: " + lib.concatStringsSep "," (lib.attrNames (lib.filterAttrs (_: v: !v) cases)));
pkgs.writeText "remote-builders-evaluation.json" (builtins.toJSON cases)
