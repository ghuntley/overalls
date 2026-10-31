{ pkgs, source, vendor, lockSha256, toolchain, nativeBinaries, buildVars, exports }:
let
  sdk = import ../guest/native-kernels/illumos/sdk.nix { inherit pkgs; };
  buildMetadata = pkgs.writeText "lyra-native-build.json" (builtins.toJSON {
    cargo_lock_sha256 = lockSha256;
    illumos_sdk_nar_hash = sdk.sysroot.outputHash;
    clang_version = sdk.clang.version;
    clang_patch_sha256 = builtins.hashFile "sha256" ../guest/native-kernels/illumos/overalls-clang-solaris-linker-path.patch;
    binutils_version = sdk.binutils.version;
    rust_version = toolchain.version;
  });
  nativeVars = {
    LYRA_ILLUMOS_CC = "${sdk.compiler}/bin/illumos-clang";
    LYRA_ILLUMOS_AR = "${sdk.binutils}/bin/x86_64-pc-solaris2.11-ar";
    LYRA_NATIVE_MANIFEST = "${./native_manifest.py}";
    LYRA_NATIVE_METADATA = "${buildMetadata}";
    LYRA_READELF = "${pkgs.binutils}/bin/readelf";
  };
in
# @cc [owner:ghuntley,label:build;verification] lyra-native-offline-build
# All ten native/helper binaries MUST link for both native targets from the
# pinned Rust toolchain and vendored Lyra dependencies without network access.
# Each output MUST be at most 100 MiB and identified in the complete manifest.
# The bounded transport test helper MUST be installed only in the separate
# probes output and MUST NOT enter the production native agent payload.
# Cross-linking and stock-guest probes MUST NOT open native catalog admission.
pkgs.stdenv.mkDerivation {
  pname = "lyra-native";
  version = "0.1.0";
  outputs = [ "out" "probes" ];
  src = source;
  strictDeps = true;
  dontStrip = true;
  allowedReferences = [ ];
  nativeBuildInputs = [ toolchain ] ++ (with pkgs; [ cargo-zigbuild zig coreutils python313 ]);
  dontConfigure = true;
  doCheck = false;
  buildPhase = ''
    runHook preBuild
    ${exports (buildVars // nativeVars)}
    export LYRA_JOBS="$NIX_BUILD_CORES"
    bash ${./lyra-build.sh} native "$out" "$probes"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    runHook postInstall
  '';
  passthru = { illumosSdk = sdk; inherit nativeBinaries; tests = sdk.tests; buildVars = nativeVars; };
  meta = {
    description = "Pinned Lyra native guest agents for FreeBSD and illumos";
    platforms = [ "x86_64-linux" ];
  };
}
