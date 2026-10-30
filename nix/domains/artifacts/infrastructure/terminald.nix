{ pkgs, antithesisObserver ? false, toolchain ? (import ./lyra.nix { inherit pkgs; }).toolchain }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "lilly-terminald";
  version = "0.1.0";
  src = workspace.source { name = "lilly-terminald-source"; crates = [ "nix/domains/artifacts/terminald" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "nix/domains/artifacts/terminald";
  # Cargo profiles live at the workspace root (ADR-0273); `hardened` keeps
  # terminald's LTO, abort-on-panic release settings.
  cargoBuildType = "hardened";
  cargoBuildFlags = pkgs.lib.optionals antithesisObserver [ "--features" "antithesis-observer" ];
  doCheck = false;
  strictDeps = true;
  meta = {
    description = "Overalls guest terminal multiplexer over AF_VSOCK";
    platforms = [ "x86_64-linux" ];
  };
  passthru.native = import ./terminald-native.nix { inherit pkgs toolchain; };
}
