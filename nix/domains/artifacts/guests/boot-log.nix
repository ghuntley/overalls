{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
workspace.rustPlatform.buildRustPackage {
  pname = "lilly-boot-log";
  version = "0.1.0";
  src = workspace.source { name = "lilly-boot-log-source"; crates = [ "lilly/native/boot-log" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "lilly/native/boot-log";
  # Declared profile: the workspace `hardened` (LTO, abort on panic). Open T2
  # regression (ADR-0273): `cargoBuildType` never took effect, so since
  # a89cde0de this leaf has shipped `release` (unwind). It stays `release`,
  # what hosts run, until `hardened` is restored with Buck2 after the panic
  # paths abort would expose are found.
  buildType = "release";
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
