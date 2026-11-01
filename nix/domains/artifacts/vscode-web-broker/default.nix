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
  # The workspace `hardened` profile (strip, fat LTO, one codegen unit, abort
  # on panic), as its Buck2 build (ADR-0273). Changing it changes both.
  buildType = "hardened";
  check = true;
  meta = {
    description = "Account-bound Overalls guest broker for source-built VS Code";
    platforms = [ "x86_64-linux" ];
    mainProgram = "overalls-vscode-web-broker";
  };
}
