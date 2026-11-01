{
  description = "Marshall control plane and Lilly Firecracker hosts";

  # @cc [owner:ghuntley,label:build] flake-package-inputs
  # Application packages MUST use the same locked package input as devenv;
  # NixOS host modules MUST use the separately locked stable NixOS input.
  # buildNixpkgs follows the same devenv-nixpkgs branch as devenv.yaml and is
  # pinned only by flake.lock; the package-input-lock check MUST fail when
  # flake.lock and devenv.lock lock different revisions.
  inputs = {
    nix-compact.url = "github:ghuntley/nix-compact/84475ca7652fcdabd36428d80d4c1122bb03bab6";
    buildNixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-images = {
      url = "github:nix-community/nixos-images/4fcaaefd02b5bc777f99afd620cb1a9aa1fb5b83";
      inputs.nixos-stable.follows = "nixpkgs";
      inputs.nixos-unstable.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/ff8702b4de27f72b4c78573dfb89ec74e36abdf1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Fleet build scheduling (ADR-0248): host modules and packages follow the
    # stable NixOS input; crane stays separately locked.
    tribuchet = {
      url = "github:Mic92/tribuchet/1a1002096f3c1f6d7b32b3ef9822e542b095a948";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "";
      inputs.nix-darwin.follows = "";
    };
    nix-grpc-store = {
      url = "github:Mic92/nix-grpc-store/17f4ff97a6fdac3c68458a0f15210762eba261ea";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.niks3.inputs.treefmt-nix.follows = "";
    };
    # The one Rust toolchain (ADR-0273). nix/rust-toolchain.nix reads this
    # lock entry, so Buck2's cells, the Nix builds and devenv share one pin.
    rust-overlay = {
      url = "github:oxalica/rust-overlay/19ecdd08213836b36c4296a3a4f4af5a3d5308db";
      inputs.nixpkgs.follows = "buildNixpkgs";
    };
  };

  # @cc [owner:ghuntley,label:build] flake-exports-pins-and-assembly
  # Buck2 is the only build entry point (ADR-0269). The flake MUST export only
  # what Buck2 and the hosts consume: buckCells (pinned buck2, prelude and
  # toolchains), lib.assemble (NixOS assembly over Buck2 artifacts),
  # lib.dependencyPins (the pin refresh builds) and nixosModules. It MUST NOT
  # export packages, checks, legacyPackages, apps or nixosConfigurations.
  outputs = { buildNixpkgs, nixpkgs, disko, nixos-images, nix-compact, tribuchet, nix-grpc-store, ... }:
    let
      system = "x86_64-linux";
      pkgs = buildNixpkgs.legacyPackages.${system};
      assemble = import ./nix/assemble {
        inherit nixpkgs buildNixpkgs disko nixos-images nix-compact tribuchet nix-grpc-store;
      };
      # Revision-independent: the toolchain, the pin builds and the modules.
      # Systems name their revision through Buck2 (`-c overalls.revision`).
      assembled = assemble { };
    in
    {
      # NixOS assembly from Buck2 artifacts (ADR-0269); see nix/assemble.
      # Buck2's nix_assemble targets build every system, image, package
      # output and check through it.
      lib.assemble = assemble;
      # Lock files, builds and fixed-output hash keys for the scheduled
      # Mix and Cargo security upgrades and the fetch-pin refresh.
      lib.dependencyPins = assembled.dependencyPins;

      # Buck2 prelude and Nix toolchain paths (ADR-0269); tools/buck2 links it.
      buckCells.${system} = import ./nix/buck/cells.nix { inherit pkgs; inherit (assembled.packages) toolchain; artifacts = assembled.packages; };
      # macOS runners build the Mila Apple targets (non_hermetic) through the
      # same wrapper; these cells carry buck2, the prelude and host tools only.
      buckCells.aarch64-darwin = import ./nix/buck/cells.nix { pkgs = buildNixpkgs.legacyPackages.aarch64-darwin; };

      nixosModules = assembled.modules;
    };
}
