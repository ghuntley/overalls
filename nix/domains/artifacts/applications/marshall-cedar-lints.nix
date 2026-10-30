# ADR-0265 gate for Marshall's Cedar NIF crate: rustfmt and clippy with
# -D warnings over the same vendored lockfile the release compiles. The crate is
# a Rustler cdylib whose test harness cannot link without the BEAM, so the gate
# lints every target and does not run tests.
{ pkgs, cedarCargo }:
pkgs.rustPlatform.buildRustPackage {
  pname = "marshall-cedar-lints";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../../../../marshall/native/marshall_cedar;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name || builtins.elem name [ "Cargo.toml" "Cargo.lock" "clippy.toml" ]);
  };
  cargoDeps = cedarCargo;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  buildPhase = ''
    runHook preBuild
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    runHook postBuild
  '';
  doCheck = false;
  installPhase = "touch $out";
}
