{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-terminald-native-checks";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../terminald;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name ||
          builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" ]);
  };
  cargoLock.lockFile = ../terminald/Cargo.lock;
  doCheck = false;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  TERMINALD_TEST_SHELL = "${pkgs.bash}/bin/bash";
  TERMINALD_TEST_HEAD = "${pkgs.coreutils}/bin/head";
  buildPhase = ''
    runHook preBuild
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
