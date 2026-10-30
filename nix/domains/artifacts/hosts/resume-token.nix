{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-resume-token";
  version = "0.1.0";
  src = workspace.source { name = "lilly-resume-token-source"; crates = [ "lilly/native/resume-token" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/resume-token";
  # The ADR-0273 workspace keeps Cargo's default `release`; Lilly helpers
  # build with the workspace `hardened` profile (LTO, abort on panic).
  cargoBuildType = "hardened";
  strictDeps = true;
  doCheck = true;
  # The typed FFI shim links libzfs + libnvpair; the library stays a runtime
  # boundary: no zfs module or /dev/zfs is required to evaluate tokens.
  buildInputs = [ pkgs.zfs ];
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
