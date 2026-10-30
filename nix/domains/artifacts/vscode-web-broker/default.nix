{ pkgs }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
in
# A static musl executable from the one toolchain (ADR-0273); the check runs
# its host tests, rustfmt and clippy.
workspace.buildStaticMusl {
  pname = "overalls-vscode-web-broker";
  crate = "nix/domains/artifacts/vscode-web-broker";
  binaries = [ "overalls-vscode-web-broker" ];
  # Declared `hardened`; built `release` (unwind) since T2 (a89cde0de), as
  # hosts run it now: an open regression in ADR-0273, restored with Buck2.
  buildType = "release";
  check = true;
  meta = {
    description = "Account-bound Overalls guest broker for source-built VS Code";
    platforms = [ "x86_64-linux" ];
    mainProgram = "overalls-vscode-web-broker";
  };
}
