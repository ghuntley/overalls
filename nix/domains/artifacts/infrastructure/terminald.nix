{ pkgs, antithesisObserver ? false, toolchain ? (import ./lyra.nix { inherit pkgs; }).toolchain }:
let
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
in
# A static musl executable from the one toolchain (ADR-0273), linked by
# rust-lld against rustc's self-contained musl CRT.
(workspace.buildStaticMusl {
  pname = "lilly-terminald";
  crate = "nix/domains/artifacts/terminald";
  binaries = [ "lilly-terminald" ];
  # The workspace `hardened` profile (strip, fat LTO, one codegen unit, abort
  # on panic), as its Buck2 build (ADR-0273). Changing it changes both.
  buildType = "hardened";
  features = pkgs.lib.optionals antithesisObserver [ "antithesis-observer" ];
  meta = {
    description = "Overalls guest terminal multiplexer over AF_VSOCK";
    platforms = [ "x86_64-linux" ];
  };
}).overrideAttrs {
  passthru.native = import ./terminald-native.nix { inherit pkgs toolchain; };
}
