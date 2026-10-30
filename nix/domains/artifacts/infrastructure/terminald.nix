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
  # Declared `hardened`; built `release` (unwind) since T2 (a89cde0de), as
  # hosts run it now: an open regression in ADR-0273, restored with Buck2.
  buildType = "release";
  features = pkgs.lib.optionals antithesisObserver [ "antithesis-observer" ];
  meta = {
    description = "Overalls guest terminal multiplexer over AF_VSOCK";
    platforms = [ "x86_64-linux" ];
  };
}).overrideAttrs {
  passthru.native = import ./terminald-native.nix { inherit pkgs toolchain; };
}
