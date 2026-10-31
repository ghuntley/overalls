#!/usr/bin/env bash

# @cc [owner:ghuntley,label:build;verification] lyra-shared-build
# The Nix derivations in lyra.nix and lyra-native.nix and the Buck2
# `lyra_cross` rule (buck/lyra.bzl) MUST build Lyra's shipped binaries with
# this one script, so the two build systems run the same commands and their
# outputs can be compared byte for byte (ADR-0273). It MUST stay offline:
# Cargo reads only LYRA_VENDOR.

# Usage: lyra-build.sh client|windows|native OUT [PROBES]
#
# Run from the root of a Cargo workspace source (cargo-workspace.nix's
# layout) with TMPDIR as scratch. The caller exports:
#   LYRA_RUST             the single Rust toolchain (nix/rust-toolchain.nix)
#   LYRA_VENDOR           the vendored root-lock crates
#   LYRA_PYTHON           python3.13
#   LYRA_MANIFEST         lyra_manifest.py (client, windows)
#   LYRA_MACOS_SDK        the MacOSX11.3.sdk tarball (client)
#   LYRA_ILLUMOS_CC       illumos-clang, LYRA_ILLUMOS_AR its ar (native)
#   LYRA_NATIVE_MANIFEST  native_manifest.py, LYRA_NATIVE_METADATA its build
#                         metadata and LYRA_READELF (native)
#   LYRA_JOBS             optional Cargo job limit
# with cargo-zigbuild, zig, coreutils, tar and xz on PATH.
set -euo pipefail

mode=$1
out=$2
probes=${3:-}

windows_binaries=(
  overalls-winprobe
  overalls-readinessd
  overalls-trustd-windows
  overalls-ssh-sync-windows
  overalls-host-certificate-windows
  overalls-workspaced-windows
  overalls-agentd-windows
)
native_binaries=(
  overalls-native-bootstrap
  overalls-native-grow-root
  overalls-native-readinessd
  overalls-native-trustd
  overalls-native-workspaced
  overalls-native-kernel-probed
  overalls-native-agentd
  overalls-native-flushd
  overalls-ssh-authorize
  overalls-host-certificate
)
probe_binary=overalls-native-transport-probe

cd lyra
# Vendored OpenSSL records its build date and the PE linker its timestamp:
# pin both to the Nix sandbox's values so every caller builds the same bytes.
export SOURCE_DATE_EPOCH=315532800
export TZ=UTC
export CARGO_HOME="$TMPDIR/cargo-home"
export CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
export XDG_CACHE_HOME="$TMPDIR/cache"
export RUSTC="$LYRA_RUST/bin/rustc"
export PATH="$LYRA_RUST/bin:$PATH"
if [ -n "${LYRA_JOBS:-}" ]; then
  export CARGO_BUILD_JOBS="$LYRA_JOBS"
fi
mkdir -p "$CARGO_HOME"
printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "%s"\n' \
  "$LYRA_VENDOR" > "$CARGO_HOME/config.toml"
# Panic locations would otherwise embed vendored-crate store paths, and one
# such reference keeps the whole vendor tree in the runtime closure.
export RUSTFLAGS="--remap-path-prefix=$LYRA_VENDOR=/vendor --remap-path-prefix=$PWD=/source"

# Every shipped executable stays at or below 100 MiB.
bounded() {
  test "$(stat -c %s "$1")" -le 104857600
}

case $mode in
  client)
    tar -xJf "$LYRA_MACOS_SDK" -C "$TMPDIR"
    export SDKROOT="$TMPDIR/MacOSX11.3.sdk"
    for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin x86_64-pc-windows-gnu; do
      cargo zigbuild --profile hardened --locked --offline --target "$target" --bin overalls
    done
    for binary in overalls-ssh-authorize overalls-host-certificate overalls-trustd overalls-workspaced; do
      cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-linux-musl --bin "$binary"
    done
    mkdir -p "$out/bin"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/overalls" "$out/bin/linux-amd64"
    for binary in overalls-ssh-authorize overalls-host-certificate overalls-trustd overalls-workspaced; do
      cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/$binary" "$out/bin/$binary"
    done
    cp "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/hardened/overalls" "$out/bin/linux-arm64"
    cp "$CARGO_TARGET_DIR/x86_64-apple-darwin/hardened/overalls" "$out/bin/darwin-amd64"
    cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/hardened/overalls" "$out/bin/darwin-arm64"
    # Windows workstations (x86_64; Windows on Arm runs it under emulation).
    # Published without .exe; the installer saves it as overalls.exe.
    cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/hardened/overalls.exe" "$out/bin/windows-amd64"
    for binary in "$out"/bin/*; do
      bounded "$binary"
    done
    "$LYRA_PYTHON" "$LYRA_MANIFEST" "$out" "" linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 windows-amd64
    ;;
  windows)
    for binary in "${windows_binaries[@]}"; do
      cargo zigbuild --profile hardened --locked --offline --target x86_64-pc-windows-gnu --bin "$binary"
    done
    mkdir -p "$out/bin"
    for binary in "${windows_binaries[@]}"; do
      cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/hardened/$binary.exe" "$out/bin/$binary.exe"
      bounded "$out/bin/$binary.exe"
    done
    "$LYRA_PYTHON" "$LYRA_MANIFEST" "$out" .exe "${windows_binaries[@]}"
    ;;
  native)
    selection=()
    for binary in "${native_binaries[@]}" "$probe_binary"; do
      selection+=(--bin "$binary")
    done
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-freebsd "${selection[@]}"
    export CC_x86_64_unknown_illumos="$LYRA_ILLUMOS_CC"
    export AR_x86_64_unknown_illumos="$LYRA_ILLUMOS_AR"
    export CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER="$CC_x86_64_unknown_illumos"
    cargo build --profile hardened --locked --offline --target x86_64-unknown-illumos "${selection[@]}"
    mkdir -p "$out/bin" "$probes/bin"
    for target in x86_64-unknown-freebsd x86_64-unknown-illumos; do
      for binary in "${native_binaries[@]}"; do
        install -m 0755 "$CARGO_TARGET_DIR/$target/hardened/$binary" "$out/bin/$target-$binary"
        bounded "$out/bin/$target-$binary"
      done
      install -m 0755 "$CARGO_TARGET_DIR/$target/hardened/$probe_binary" "$probes/bin/$target-$probe_binary"
    done
    "$LYRA_PYTHON" "$LYRA_NATIVE_MANIFEST" "$out" "$LYRA_NATIVE_METADATA" "$LYRA_READELF"
    "$LYRA_PYTHON" "$LYRA_NATIVE_MANIFEST" "$probes" "$LYRA_NATIVE_METADATA" "$LYRA_READELF" --probes
    ;;
  *)
    echo "lyra-build.sh: unknown mode $mode" >&2
    exit 2
    ;;
esac
