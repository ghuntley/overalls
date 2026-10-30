{ pkgs, toolchain }:
let
  inherit (pkgs) lib;
  sdk = import ../guest/native-kernels/illumos/sdk.nix { inherit pkgs; };
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
  source = workspace.source { name = "lilly-terminald-source"; crates = [ "nix/domains/artifacts/terminald" ]; };
  inherit (workspace) vendor;
  targets = [ "x86_64-unknown-freebsd" "x86_64-unknown-illumos" ];
  buildMetadata = pkgs.writeText "terminald-native-build.json" (builtins.toJSON {
    cargo_lock_sha256 = workspace.lockSha256;
    illumos_sdk_nar_hash = sdk.sysroot.outputHash;
    clang_version = sdk.clang.version;
    clang_patch_sha256 = builtins.hashFile "sha256" ../guest/native-kernels/illumos/overalls-clang-solaris-linker-path.patch;
    binutils_version = sdk.binutils.version;
    rust_version = toolchain.version;
  });
in
# @cc [owner:ghuntley,label:build;verification] terminald-native-offline-build
# The shared terminal daemon MUST link for FreeBSD and illumos using Lyra's
# pinned Rust toolchain and vendored dependencies, plus the immutable illumos
# SDK, without network access. The two bounded native ELF outputs MUST appear
# in the verified manifest; cross-linking MUST NOT open native admission.
pkgs.stdenv.mkDerivation {
  pname = "lilly-terminald-native";
  version = "0.1.0";
  src = source;
  strictDeps = true;
  dontStrip = true;
  allowedReferences = [ ];
  nativeBuildInputs = with pkgs; [ cargo cargo-zigbuild zig coreutils python313 ];
  dontConfigure = true;
  doCheck = false;
  buildPhase = ''
    runHook preBuild
    cd ${lib.escapeShellArg "nix/domains/artifacts/terminald"}
    export CARGO_HOME="$TMPDIR/cargo-home"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    export CARGO_BUILD_JOBS="$NIX_BUILD_CORES"
    export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export RUSTC="${toolchain}/bin/rustc"
    export RUSTFLAGS="--remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
    mkdir -p "$CARGO_HOME"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-freebsd --bin lilly-terminald
    export CC_x86_64_unknown_illumos="${sdk.compiler}/bin/illumos-clang"
    export AR_x86_64_unknown_illumos="${sdk.binutils}/bin/x86_64-pc-solaris2.11-ar"
    export CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER="$CC_x86_64_unknown_illumos"
    cargo build --profile hardened --locked --offline --target x86_64-unknown-illumos --bin lilly-terminald
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    for target in ${lib.concatStringsSep " " targets}; do
      install -m 0755 "$CARGO_TARGET_DIR/$target/hardened/lilly-terminald" "$out/bin/$target-lilly-terminald"
    done
    python3.13 ${./native_manifest.py} "$out" ${buildMetadata} ${pkgs.binutils}/bin/readelf --terminald
    runHook postInstall
  '';
  passthru = { inherit toolchain; illumosSdk = sdk; };
  meta = {
    description = "Overalls guest terminal multiplexer for FreeBSD and illumos";
    platforms = [ "x86_64-linux" ];
  };
}
