{ pkgs, clippy, rustfmt, rustPlatform }:
let
  workspace = import ../../artifacts/infrastructure/cargo-workspace.nix { inherit pkgs; };
in
rustPlatform.buildRustPackage {
  pname = "overalls-otel-guest-receiver";
  version = "0.1.0";
  # examples/ stays: the otel-request-recorder machine test builds
  # examples/request_fixture.rs from this source.
  src = workspace.source {
    name = "overalls-otel-guest-receiver-source";
    crates = [ "nix/domains/system/otel-guest/receiver" ];
  };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "nix/domains/system/otel-guest/receiver";
  nativeBuildInputs = [ clippy rustfmt ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
}
