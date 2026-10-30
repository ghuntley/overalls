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
  # Declared profile: the workspace `hardened` (LTO, abort on panic). Open T2
  # regression (ADR-0273): `cargoBuildType` never took effect, so since
  # a89cde0de this leaf has shipped `release` (unwind). It stays `release`,
  # what hosts run, until `hardened` is restored with Buck2 after the panic
  # paths abort would expose are found.
  buildType = "release";
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
