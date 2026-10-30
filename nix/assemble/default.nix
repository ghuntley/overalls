# lib.assemble: the only NixOS assembly entry point (ADR-0269). Buck2's
# nix_assemble rule evaluates it through builtins.getFlake over a copied,
# declared-only source tree under restrict-eval.
{ nixpkgs, buildNixpkgs, disko, nixos-images, nix-compact, tribuchet, nix-grpc-store }:

# @cc [owner:ghuntley,label:build] assembly-revision-from-argument
# Assembly MUST name the deployed source through its revision argument, never
# self.rev: Buck2 evaluates a copied tree that carries no Git metadata, so the
# caller supplies the candidate revision (contract deployment-revision-source).
{ revision ? null, artifacts ? { }, params ? { } }:
let
  system = "x86_64-linux";
  pkgs = buildNixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  importArtifact = import ./import-artifact.nix { inherit pkgs; };

  # Buck2-built first-party artifacts, each { path, runtimeRefs }, imported
  # once and shared by every consumer of the package set.
  imported = lib.mapAttrs (name: artifact: importArtifact ({ inherit name; } // artifact)) artifacts;

  # One package set. Variants differ only by explicit parameters.
  packageSet = variant: import ../domains/artifacts/default.nix
    ({ inherit pkgs; artifacts = imported; } // variant);

  packages = packageSet { };
  modules = import ./modules.nix {
    inherit packages nixpkgs pkgs tribuchet nix-grpc-store;
    nixCompact = nix-compact;
  };
  fleetBuilds = modules.fleetBuilds;
  hostPackages = packageSet {
    privateServiceRoots = params.privateServiceRoots or [ ../../secrets/private-services-root.pem ../../secrets/brady-root.pem ];
  };

  inventory = import ../platform/hosts/inventory.nix { inherit lib; };

  hostSystem = name: enrolled: nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { overallsPackages = hostPackages; };
    modules = [ modules.default fleetBuilds
      # Telemetry and backups name the deployed source revision.
      { system.configurationRevision = revision; }
      (import ../platform/hosts/profile.nix {
        host = inventory.hosts.${name}; diskoModule = disko.nixosModules.disko; inherit enrolled;
      }) ] ++ lib.optionals (enrolled && builtins.pathExists (../../fleet/hosts + "/${name}/configuration.nix"))
      [ (../../fleet/hosts + "/${name}/configuration.nix") ];
  };

  enrolledHosts = lib.filterAttrs (name: host: host.identity.sshKeys != [ ]
    && host.git.knownHosts != "" && lib.any (document: document.name == "${name}-git") host.credentials) inventory.hosts;
  fixtures = import ../verification/tests/fixtures/hosts/configurations.nix { inherit nixpkgs disko modules; };

  kexec = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ nixos-images.nixosModules.kexec-installer nixos-images.nixosModules.noninteractive
      ../domains/system/nix-cache.nix
      ({ config, pkgs, ... }: {
        system.kexec-installer.name = "overalls-host-installer";
        environment.systemPackages = [ pkgs.python3 config.boot.zfs.package ];
        boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
      }) ];
  }).config.system.build.kexecInstallerTarball;

  # NixOS machine and evaluation tests over the same package set.
  checks = import ../verification/tests/catalog.nix {
    buildPkgs = pkgs;
    testPkgs = nixpkgs.legacyPackages.${system};
    inherit nixpkgs packages modules fixtures kexec;
    diskoModule = disko.nixosModules.disko;
    diskoSource = disko.outPath;
    imageSource = nixos-images.outPath;
  };
in
{
  inherit packages hostPackages imported kexec checks modules;
  systems = lib.mapAttrs (name: _: hostSystem name true) enrolledHosts
    // lib.mapAttrs' (name: _: lib.nameValuePair "${name}-base" (hostSystem name false)) inventory.hosts;
}
