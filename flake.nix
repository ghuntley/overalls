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

  outputs = { self, buildNixpkgs, nixpkgs, disko, nixos-images, nix-compact, tribuchet, nix-grpc-store, ... }:
    let
      system = "x86_64-linux";
      pkgs = buildNixpkgs.legacyPackages.${system};
      # The single package set (ADR-0269), also used by every module.
      built = assembled.packages;
      assemble = import ./nix/assemble {
        inherit nixpkgs buildNixpkgs disko nixos-images nix-compact tribuchet nix-grpc-store;
      };
      # Flake-evaluated hosts name the checkout revision; Buck2 passes it.
      assembled = assemble { revision = self.rev or self.dirtyRev or null; };
    in
    {
      # @cc [owner:ghuntley,label:build] flake-releases-from-source
      # Exported application packages MUST compile clean source and locked
      # dependencies; existing working-tree releases MUST NOT be build inputs.
      lib.mkUbuntuGuest = built.mkUbuntuGuest;
      lib.mkAndroidGuest = built.mkAndroidGuest;
      lib.mkArchGuest = built.mkArchGuest;
      lib.mkArchLinuxGuest = built.mkArchLinuxGuest;
      lib.mkAlmaLinuxGuest = built.mkAlmaLinuxGuest;
      lib.mkAlmaGuest = built.mkAlmaGuest;
      lib.mkWindowsGuest = built.mkWindowsGuest;
      lib.mkWindowsEditorCandidate = built.mkWindowsEditorCandidate;
      lib.mkWindowsEditorBundle = built.mkWindowsEditorBundle;
      lib.nativeKernels = built.nativeKernels;
      lib.mkFreeBSDGuest = built.mkFreeBSDGuest;
      lib.mkFreeBSDImageCandidate = built.mkFreeBSDImageCandidate;
      lib.mkOmniOSGuest = built.mkOmniOSGuest;
      lib.mkIllumosGuest = built.mkIllumosGuest;
      # Lock files, builds and fixed-output hash keys for the scheduled
      # Mix and Cargo security upgrade scripts.
      lib.dependencyPins = built.dependencyPins;
      # NixOS assembly from Buck2 artifacts (ADR-0269); see nix/assemble.
      lib.assemble = assemble;
      # Package outputs are lib.assemble's (nix/assemble/outputs.nix), which
      # Buck2 builds as //:package-<name>.
      packages.${system} = assembled.outputPackages;

      # Hermetic Mila journey backend for platform journey tests (ADR-0264).
      apps.${system}.mila-journey-fixture = {
        type = "app";
        program = "${self.packages.${system}.mila-journey-fixture}/bin/mila-journey-fixture";
        meta.description = "Boot the hermetic Mila journey backend and print its descriptor";
      };

      legacyPackages.${system} = built;

      # Buck2 prelude and Nix toolchain paths (ADR-0269); tools/buck2 links it.
      buckCells.${system} = import ./nix/buck/cells.nix { inherit pkgs; inherit (built) toolchain; };
      # macOS runners build the Mila Apple targets (non_hermetic) through the
      # same wrapper; these cells carry buck2, the prelude and host tools only.
      buckCells.aarch64-darwin = import ./nix/buck/cells.nix { pkgs = buildNixpkgs.legacyPackages.aarch64-darwin; };

      nixosModules = assembled.modules;

      nixosConfigurations = assembled.systems;

      # lib.assemble's checks (the machine-test catalog and outputs.nix), plus
      # the repository script checks that are Buck2 targets of their own.
      checks.${system} = import ./nix/verification/tests/ci.nix { inherit (pkgs) lib; checks = assembled.checks // {
        package-input-lock =
          let
            flakeNodes = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes;
            devenvNodes = (builtins.fromJSON (builtins.readFile ./devenv.lock)).nodes;
            flakeInput = name: flakeNodes.${flakeNodes.root.inputs.${name}}.locked;
            devenvInput = name: devenvNodes.${devenvNodes.root.inputs.${name}}.locked;
            pinned = lock: "${lock.owner}/${lock.repo}/${lock.rev}";
            # Inputs both locks carry: the application nixpkgs and nix-compact.
            shared = { buildNixpkgs = "nixpkgs"; nix-compact = "nix-compact"; };
            mismatches = nixpkgs.lib.filter (name: pinned (flakeInput name) != pinned (devenvInput shared.${name}))
              (builtins.attrNames shared);
          in
          if mismatches == [ ]
          then pkgs.runCommand "overalls-package-input-lock-check" { } "touch $out"
          else throw (nixpkgs.lib.concatMapStringsSep "; " (name:
            "flake.lock ${name} (${pinned (flakeInput name)}) differs from devenv.lock ${shared.${name}} (${pinned (devenvInput shared.${name})})")
            mismatches);
        conflict-markers = pkgs.runCommand "overalls-conflict-markers-check" {
          nativeBuildInputs = [ built.toolchain.elixir pkgs.git ];
          LC_ALL = "C.UTF-8";
          source = ./.;
        } ''
          export HOME="$TMPDIR"
          cd "$source"
          find . -type f -not -path './.git/*' -print0 > "$TMPDIR/files"
          xargs -0 elixir scripts/check_conflict_markers.exs < "$TMPDIR/files"
          touch "$out"
        '';
        pins = pkgs.runCommand "overalls-pins-check" {
          nativeBuildInputs = [ built.toolchain.elixir ];
          LC_ALL = "C.UTF-8";
          source = ./.;
        } ''
          export HOME="$TMPDIR"
          elixir "$source/scripts/check_pins.exs" "$source"
          touch "$out"
        '';
        rust-lints = pkgs.runCommand "overalls-rust-lints-check" {
          nativeBuildInputs = [ built.toolchain.elixir ];
          LC_ALL = "C.UTF-8";
          source = ./.;
        } ''
          export HOME="$TMPDIR"
          cd "$source"
          find . -type f -not -path './.git/*' \( -name Cargo.toml -o -name '*.rs' \) -print0 > "$TMPDIR/files"
          xargs -0 elixir scripts/check_rust_lints.exs --strict < "$TMPDIR/files"
          touch "$out"
        '';
        overalls-install-ps1 = import ./nix/verification/tests/overalls-install-ps1.nix { inherit pkgs; };
        marvin = built.marvin.tests;
      }; };
    };
}
