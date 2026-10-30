{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
workspace.rustPlatform.buildRustPackage {
  pname = "enrico-git-owner";
  version = "0.1.0";
  src = workspace.source { name = "enrico-git-owner-source"; crates = [ "enrico/native/git-owner" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "enrico/native/git-owner";
  strictDeps = true;
  doCheck = true;
  # Generated histories fork native owners and must not inherit another
  # concurrent history's live pipe descriptors.
  checkFlags = [ "--test-threads=1" ];
  nativeBuildInputs = [ workspace.rustTools ];
  ENRICO_TEST_SHELL = "${pkgs.bash}/bin/bash";
  ENRICO_TEST_SETSID = "${pkgs.util-linux}/bin/setsid";
  preCheck = ''export PATH=${pkgs.coreutils}/bin:$PATH'';
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta.platforms = [ "x86_64-linux" ];
}
