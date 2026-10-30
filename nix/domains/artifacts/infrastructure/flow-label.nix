{ pkgs }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-flow-label";
  version = "0.1.0";
  src = workspace.source { name = "lilly-flow-label-source"; crates = [ "lilly/native/flow-label" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/flow-label";
  # The ADR-0273 workspace keeps Cargo's default `release`; Lilly helpers
  # build with the workspace `hardened` profile (LTO, abort on panic).
  cargoBuildType = "hardened";
  strictDeps = true;
  doCheck = true;
  # Typed FFI shim against libnetfilter_conntrack.
  buildInputs = [ pkgs.libnetfilter_conntrack ];
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
