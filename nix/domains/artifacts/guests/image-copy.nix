{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-image-copy";
  version = "0.1.0";
  src = workspace.source { name = "lilly-image-copy-source"; crates = [ "lilly/native/image-copy" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/image-copy";
  # The ADR-0273 workspace keeps Cargo's default `release`; Lilly helpers
  # build with the workspace `hardened` profile (LTO, abort on panic).
  cargoBuildType = "hardened";
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
