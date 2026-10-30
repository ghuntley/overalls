{ pkgs }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "overalls-trace-spool";
  version = "0.1.0";
  src = workspace.source { name = "overalls-trace-spool-source"; crates = [ "elixir/diagnostics/native/spool" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "elixir/diagnostics/native/spool";
  doCheck = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta = { description = "Independent private durable OpenTelemetry trace custody";
    mainProgram = "overalls-trace-spool"; platforms = [ "x86_64-linux" ]; };
}
