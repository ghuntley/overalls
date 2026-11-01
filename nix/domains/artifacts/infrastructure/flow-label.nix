{ pkgs }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
workspace.rustPlatform.buildRustPackage {
  pname = "lilly-flow-label";
  version = "0.1.0";
  src = workspace.source { name = "lilly-flow-label-source"; crates = [ "lilly/native/flow-label" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/flow-label";
  # The workspace `hardened` profile (strip, fat LTO, one codegen unit, abort
  # on panic), as its Buck2 build (ADR-0273). Changing it changes both.
  buildType = "hardened";
  strictDeps = true;
  doCheck = true;
  # Typed FFI shim against libnetfilter_conntrack.
  buildInputs = [ pkgs.libnetfilter_conntrack ];
  nativeBuildInputs = [ workspace.rustTools pkgs.pkg-config ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
