{ pkgs }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
workspace.rustPlatform.buildRustPackage {
  pname = "lilly-transfer-stream";
  version = "0.1.0";
  src = workspace.source { name = "lilly-transfer-stream-source"; crates = [ "lilly/native/transfer-stream" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/transfer-stream";
  # The workspace `hardened` profile (strip, fat LTO, one codegen unit, abort
  # on panic), as its Buck2 build (ADR-0273). Changing it changes both.
  buildType = "hardened";
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ workspace.rustTools ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
