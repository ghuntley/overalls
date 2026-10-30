{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "overalls-vscode-web-broker";
  version = "0.1.0";
  src = workspace.source { name = "overalls-vscode-web-broker-source"; crates = [ "nix/domains/artifacts/vscode-web-broker" ]; };
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "nix/domains/artifacts/vscode-web-broker";
  # Cargo profiles live at the workspace root (ADR-0273); `hardened` keeps
  # the broker's LTO, abort-on-panic release settings.
  cargoBuildType = "hardened";
  doCheck = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    popd
  '';
  meta = {
    description = "Account-bound Overalls guest broker for source-built VS Code";
    platforms = [ "x86_64-linux" ];
    mainProgram = "overalls-vscode-web-broker";
  };
}
