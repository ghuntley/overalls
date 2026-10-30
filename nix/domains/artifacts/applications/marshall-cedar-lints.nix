# ADR-0265 gate for Marshall's Cedar NIF crate: rustfmt and clippy with
# -D warnings over the root workspace lockfile the release compiles
# (ADR-0273). The crate is a Rustler cdylib whose test harness cannot link
# without the BEAM, so the gate lints every target and does not run tests.
{ pkgs, cargoWorkspace, cedarSource }:
pkgs.rustPlatform.buildRustPackage {
  pname = "marshall-cedar-lints";
  version = "0.1.0";
  src = cedarSource;
  inherit (cargoWorkspace) cargoLock;
  buildAndTestSubdir = "marshall/native/marshall_cedar";
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  buildPhase = ''
    runHook preBuild
    cd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    runHook postBuild
  '';
  doCheck = false;
  installPhase = "touch $out";
}
