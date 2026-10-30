{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-vm-watch";
  version = "0.1.0";
  src = workspace.source { name = "lilly-vm-watch-source"; crates = [ "lilly/native/vm-watch" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/vm-watch";
  # The ADR-0273 workspace keeps Cargo's default `release`; Lilly helpers
  # build with the workspace `hardened` profile (LTO, abort on panic).
  cargoBuildType = "hardened";
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
