{ pkgs }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-terminald-native-checks";
  version = "0.1.0";
  src = workspace.source { name = "lilly-terminald-source"; crates = [ "nix/domains/artifacts/terminald" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "nix/domains/artifacts/terminald";
  doCheck = false;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  TERMINALD_TEST_SHELL = "${pkgs.bash}/bin/bash";
  TERMINALD_TEST_HEAD = "${pkgs.coreutils}/bin/head";
  buildPhase = ''
    runHook preBuild
    cd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    # Each generated PTY history owns concurrent sessions and workers. Isolate
    # those histories from other top-level properties so their finite CPU/process
    # budgets and generator health checks measure their own declared workload.
    cargo test --locked --offline -- --test-threads=1
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out
  '';
  meta = {
    description = "Overalls terminald native test and clippy gate";
    platforms = [ "x86_64-linux" ];
  };
}
