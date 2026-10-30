{ lib, rustPlatform, fetchFromGitHub, cmake, perl }:
# NativeLink REv2 cache server for Buck2 (ADR-0272). Not packaged in the
# pinned nixpkgs, so it is built from a reviewed release tag here.
rustPlatform.buildRustPackage rec {
  pname = "nativelink";
  version = "1.8.3";

  src = fetchFromGitHub {
    owner = "TraceMachina";
    repo = "nativelink";
    rev = "bd336137d794a6a4e7ac32e561ab55e2d7e70ff3"; # v1.8.3
    hash = (import ../pins.nix).nativelinkSource;
  };

  cargoHash = (import ../pins.nix).nativelinkCargo;
  cargoDepsName = pname;
  # aws-lc-sys builds its C library with CMake and Perl.
  nativeBuildInputs = [ cmake perl ];
  dontUseCmakeConfigure = true;
  # Upstream's release profile uses fat LTO; thin LTO keeps the binary
  # optimised at a fraction of the link time.
  env.CARGO_PROFILE_RELEASE_LTO = "thin";
  cargoBuildFlags = [ "--bin" "nativelink" ];
  # The upstream suite needs Redis, MongoDB and cloud emulators. The fleet
  # behaviour is verified by the buck-remote-cache NixOS machine test.
  doCheck = false;

  meta = {
    description = "Remote execution and cache server implementing the Bazel REv2 API";
    homepage = "https://github.com/TraceMachina/nativelink";
    # FSL-1.1-ALv2: internal self-hosting is a permitted purpose; each release
    # becomes Apache-2.0 two years after publication (ADR-0272).
    license = lib.licenses.fsl11Asl20;
    mainProgram = "nativelink";
    platforms = [ "x86_64-linux" ];
  };
}
