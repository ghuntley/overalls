{ pkgs }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-transfer-stream";
  version = "0.1.0";
  src = workspace.source { name = "lilly-transfer-stream-source"; crates = [ "lilly/native/transfer-stream" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/transfer-stream";
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
