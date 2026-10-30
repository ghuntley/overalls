# Every NixOS module, instantiated over one package set (ADR-0269). The flake
# exports these over its own set; lib.assemble instantiates them over the set
# that includes Buck2 artifacts, so no module captures a different build.
{ packages, nixCompact, tribuchet, nix-grpc-store, nixpkgs, pkgs }:
let
  modules = {
    default = import ../domains/system/catalog.nix { packages = packages; nixCompact = nixCompact; };
    # Kept out of the default catalog: only flake-packages hosts and tests that
    # pass the locked inputs import tribuchet and nix-grpc-store (ADR-0248).
    fleetBuilds = import ../domains/system/fleet-builds.nix { inherit tribuchet; nixGrpcStore = nix-grpc-store; };
    services = {
      marshall = import ../domains/system/marshall.nix { packages = packages; };
      lilly = import ../domains/system/lilly.nix { packages = packages; };
      brady = import ../domains/system/brady { packages = packages; };
      porsche = import ../domains/system/porsche.nix { packages = packages; };
      audi-private = import ../domains/system/audi-private.nix { packages = packages; };
      ziggy = import ../domains/system/ziggy.nix { packages = packages; };
      galileo = import ../domains/system/galileo.nix { packages = packages; };
      enrico = import ../domains/system/enrico.nix { packages = packages; };
      peach = import ../domains/system/peach.nix { packages = packages; };
      susan = import ../domains/system/susan.nix { packages = packages; };
      audi = import ../domains/system/audi.nix { packages = packages; };
    };
    platform = {
      nix-cache = ../domains/system/nix-cache.nix;
      nix-compact = import ../domains/system/nix-compact.nix { nixCompact = nixCompact; };
      remote-builders = { imports = [ ../domains/system/remote-builders.nix modules.security.secrets ]; };
      sysctl = ../domains/system/sysctl.nix;
      auto-update = import ../domains/system/auto-update/default.nix { packages = packages; };
    };
    network = {
      proxy = { imports = [ modules.services.marshall ../domains/system/proxy.nix ]; };
      acme = { imports = [ modules.network.proxy ../domains/system/acme/default.nix ]; };
      fleet-firewall = ../domains/system/fleet-firewall.nix;
      tailscale = ../domains/system/tailscale.nix;
    };
    security = {
      access = ../domains/system/access.nix;
      audit = ../domains/system/security-audit.nix;
      host-identity = ../domains/system/host-identity.nix;
      secrets = import ../domains/system/secrets/default.nix { packages = packages; };
    };
    storage = {
      backups = { imports = [ (import ../domains/system/backups { packages = packages; }) modules.services.lilly modules.services.marshall modules.security.secrets ]; };
      crash-dumps = import ../domains/system/crash-dumps { lib = nixpkgs.lib; pkgs = pkgs; };
    };
    observability = {
      logging = ../domains/system/logging/default.nix;
      cloudwatch = ../domains/system/cloudwatch/default.nix;
      fleet-exporter = ../domains/system/fleet-exporter/default.nix;
      otel-guest = import ../domains/system/otel-guest/default.nix { inherit packages; };
      otel-fleet = ../domains/system/otel-fleet/default.nix;
      underclass = import ../domains/system/underclass.nix { packages = packages; };
      log-store = ../domains/system/log-store/default.nix;
    };
  };
in
modules
