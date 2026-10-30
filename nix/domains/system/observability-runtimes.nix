{ pkgs }:
let
  workspace = import ../artifacts/infrastructure/cargo-workspace.nix { inherit pkgs; };
in
workspace.rustPlatform.buildRustPackage {
  pname = "overalls-observability-runtimes";
  version = "0.1.0";
  src = workspace.source { name = "overalls-observability-runtimes-source"; crates = [ "nix/domains/system/observability-runtimes" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "nix/domains/system/observability-runtimes";
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ workspace.rustTools ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
}
