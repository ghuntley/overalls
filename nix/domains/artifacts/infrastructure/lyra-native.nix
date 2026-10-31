{ pkgs, source, vendor, lockSha256, toolchain, nativeBinaries }:
let
  inherit (pkgs) lib;
  sdk = import ../guest/native-kernels/illumos/sdk.nix { inherit pkgs; };
  targets = [ "x86_64-unknown-freebsd" "x86_64-unknown-illumos" ];
  probeBinary = "overalls-native-transport-probe";
  builtBinaries = nativeBinaries ++ [ probeBinary ];
  buildMetadata = pkgs.writeText "lyra-native-build.json" (builtins.toJSON {
    cargo_lock_sha256 = lockSha256;
    illumos_sdk_nar_hash = sdk.sysroot.outputHash;
    clang_version = sdk.clang.version;
    clang_patch_sha256 = builtins.hashFile "sha256" ../guest/native-kernels/illumos/overalls-clang-solaris-linker-path.patch;
    binutils_version = sdk.binutils.version;
    rust_version = toolchain.version;
  });
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
    cd lyra
    export CARGO_HOME="$TMPDIR/cargo-home"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    export CARGO_BUILD_JOBS="$NIX_BUILD_CORES"
    export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export RUSTC="${toolchain}/bin/rustc"
    export RUSTFLAGS="--remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
    mkdir -p "$CARGO_HOME"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-freebsd \
      ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") builtBinaries}
    export CC_x86_64_unknown_illumos="${sdk.compiler}/bin/illumos-clang"
    export AR_x86_64_unknown_illumos="${sdk.binutils}/bin/x86_64-pc-solaris2.11-ar"
    export CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER="$CC_x86_64_unknown_illumos"
    cargo build --profile hardened --locked --offline --target x86_64-unknown-illumos \
      ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") builtBinaries}
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$probes/bin"
    for target in ${lib.concatStringsSep " " targets}; do
      for binary in ${lib.concatStringsSep " " nativeBinaries}; do
        install -m 0755 "$CARGO_TARGET_DIR/$target/hardened/$binary" "$out/bin/$target-$binary"
        test "$(stat -c %s "$out/bin/$target-$binary")" -le 104857600
      done
      install -m 0755 "$CARGO_TARGET_DIR/$target/hardened/${probeBinary}" "$probes/bin/$target-${probeBinary}"
    done
    python3.13 ${./native_manifest.py} "$out" ${buildMetadata} ${pkgs.binutils}/bin/readelf
    python3.13 ${./native_manifest.py} "$probes" ${buildMetadata} ${pkgs.binutils}/bin/readelf --probes
    runHook postInstall
  '';
  passthru = { illumosSdk = sdk; inherit nativeBinaries; tests = sdk.tests; };
  meta = {
    description = "Pinned Lyra native guest agents for FreeBSD and illumos";
    platforms = [ "x86_64-linux" ];
  };
}
