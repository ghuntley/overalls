{ pkgs }:
let
  inherit (pkgs) lib;
  workspace = import ./cargo-workspace.nix { inherit pkgs; };
  source = workspace.source {
    name = "lyra-source";
    crates = [ "lyra" ];
    crateFile = name: rel:
      # Shared WorkspaceSource vectors (ADR-0128) are read by `cargo test`.
      (lib.hasSuffix ".json" name && lib.hasSuffix "/tests/fixtures" (builtins.dirOf rel))
      || lib.hasSuffix ".rs" name
      || builtins.elem name [ "Cargo.toml" "CONTRACTS" "LICENSE-APACHE" "LICENSE-MIT" "OVERALLS.md" "README.md" ];
  };
  inherit (workspace) vendor;
  # The single rust-overlay toolchain with every target std (ADR-0273).
  inherit (import ../../../rust-toolchain.nix { inherit pkgs; }) toolchain;
  sdk = pkgs.fetchurl {
    url = "https://github.com/joseluisq/macosx-sdks/releases/download/11.3/MacOSX11.3.sdk.tar.xz";
    hash = (import ../pins.nix).macosSdk113;
  };
  # @cc [owner:ghuntley,label:build;verification] lyra-native-tls-check-toolchain
  # The sandboxed Lyra check MUST supply the build tools required by its
  # vendored Linux OpenSSL backend and run tests without network downloads, and
  # MUST type-check the crate for `x86_64-pc-windows-gnu` so Unix-only code
  # cannot creep into the shared modules the Windows agents link. The native
  # library and agent binaries MUST also type-check for both FreeBSD and illumos;
  # that evidence MUST NOT establish native runtime acceptance (ADR-0190).
  tests = pkgs.stdenv.mkDerivation {
    pname = "lyra-tests";
    version = "0.1.0";
    src = source;
    # git: tests/workspace_object_format.rs drives the production clone plan
    # against a real repository.
    nativeBuildInputs = with pkgs; [ cargo rustc clippy rustfmt openssh openssl perl util-linux git ];
    dontConfigure = true;
    buildPhase = ''
      cd lyra
      export HOME="$TMPDIR/home"
      export CARGO_HOME="$TMPDIR/cargo-home"
      export OVERALLS_SSH_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      # The managed-skills unit tests intentionally refuse PATH lookup and
      # only recognize production system locations. Point their cfg(test)
      # override at the hermetic Nix input instead of weakening that runtime
      # policy for shipped agents.
      export OVERALLS_TEST_GIT="${pkgs.git}/bin/git"
      export OVERALLS_TEST_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      export OVERALLS_TEST_PATH="${pkgs.coreutils}/bin:${pkgs.git}/bin"
      mkdir -p "$HOME" "$CARGO_HOME"
      substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
      # Native private-directory checks include every ancestor. Normalize only
      # the nonroot builder-owned sandbox root, never a root-owned host root.
      if [ "$(id -u)" != 0 ] && [ "$(stat -c %u /)" = "$(id -u)" ]; then
        chmod go-w /
      fi
      cargo fmt --check
      cargo test --locked --offline
      cargo clippy --all-targets --locked --offline -- -D warnings
      # Windows guest agents: type-check the shared library and every Windows
      # bin for x86_64-pc-windows-gnu with the pinned toolchain (no linking, so
      # zig is not needed here). The Linux-only bins are not built for Windows.
      RUSTC="${toolchain}/bin/rustc" CARGO_TARGET_DIR="$TMPDIR/windows-check" \
        cargo check --locked --offline --target x86_64-pc-windows-gnu --lib --bin overalls \
          ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") windowsBinaries}
      # These checks require target Rust metadata only. FreeBSD also has a
      # supported Zig libc target; the separate native package links illumos
      # against its immutable OmniOS userland sysroot.
      for target in x86_64-unknown-freebsd x86_64-unknown-illumos; do
        RUSTC="${toolchain}/bin/rustc" CARGO_TARGET_DIR="$TMPDIR/native-$target" \
          cargo check --locked --offline --target "$target" --lib \
            ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") nativeBinaries}
        # Official target std metadata and Clippy must come from the same
        # compiler distribution; Nixpkgs's source-built Clippy has a different
        # compiler identity even when its release version is identical.
        PATH="${toolchain}/bin:$PATH" RUSTC="${toolchain}/bin/rustc" \
          CARGO_TARGET_DIR="$TMPDIR/native-$target" \
          ${toolchain}/bin/cargo-clippy clippy --locked --offline --target "$target" --lib \
            ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") nativeBinaries} \
            --bin overalls-native-transport-probe -- -D warnings
      done
    '';
    installPhase = ''
      touch "$out"
    '';
  };
  windowsBinaries = [
    "overalls-winprobe"
    "overalls-readinessd"
    "overalls-trustd-windows"
    "overalls-ssh-sync-windows"
    "overalls-host-certificate-windows"
    "overalls-workspaced-windows"
    "overalls-agentd-windows"
  ];
  nativeBinaries = [
    "overalls-native-bootstrap"
    "overalls-native-grow-root"
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
    "overalls-native-kernel-probed"
    "overalls-native-agentd"
    "overalls-native-flushd"
    "overalls-ssh-authorize"
    "overalls-host-certificate"
  ];
  # @cc [owner:ghuntley,label:build;guest] lyra-windows-cross-build
  # Windows guest agents MUST be cross-built from the shared Lyra crate for
  # `x86_64-pc-windows-gnu` with the pinned toolchain and vendored dependency
  # set used by the Linux build, without network access; every produced
  # `.exe` MUST stay at or below 100 MiB and MUST be listed with its SHA-256 in
  # the output manifest so the image builder can pin what it ships.
  windows = pkgs.stdenv.mkDerivation {
    pname = "lyra-windows";
    version = "0.1.0";
    allowedReferences = [ ];
    src = source;
    strictDeps = true;
    dontStrip = true;
    nativeBuildInputs = with pkgs; [ cargo cargo-zigbuild zig jq coreutils gnutar xz perl ];
    dontConfigure = true;
    doCheck = false;
    buildPhase = ''
      runHook preBuild
      cd lyra
      export CARGO_HOME="$TMPDIR/cargo-home"
      export RUSTC="${toolchain}/bin/rustc"
      export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$CARGO_HOME"
      substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
      export CARGO_TARGET_DIR="$TMPDIR/target"
      # Panic locations would otherwise embed vendored-crate store paths in the
      # executables, and the Windows disk image would keep them alive.
      export RUSTFLAGS="--remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
      for binary in ${lib.concatStringsSep " " windowsBinaries}; do
        cargo zigbuild --profile hardened --locked --offline --target x86_64-pc-windows-gnu --bin "$binary"
      done
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      for binary in ${lib.concatStringsSep " " windowsBinaries}; do
        cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/hardened/$binary.exe" "$out/bin/$binary.exe"
        test "$(stat -c %s "$out/bin/$binary.exe")" -le 104857600
      done
      ${pkgs.python3}/bin/python3 - "$out" ${lib.concatStringsSep " " windowsBinaries} <<'PY'
import hashlib
import json
import pathlib
import sys

root: pathlib.Path = pathlib.Path(sys.argv[1])
names: list[str] = sys.argv[2:]
artifacts: dict[str, dict[str, str | int]] = {
    name: {
        "path": "/bin/" + name + ".exe",
        "sha256": hashlib.sha256((root / "bin" / (name + ".exe")).read_bytes()).hexdigest(),
        "bytes": (root / "bin" / (name + ".exe")).stat().st_size,
    }
    for name in names
}
(root / "manifest.json").write_text(json.dumps({"version": "0.1.0", "artifacts": artifacts}, sort_keys=True))
PY
      runHook postInstall
    '';
    meta = {
      description = "Lyra guest agents for Windows guests";
      platforms = [ "x86_64-linux" ];
    };
  };
in
pkgs.stdenv.mkDerivation {
  pname = "lyra";
  version = "0.1.0";
  src = source;
  strictDeps = true;
  dontStrip = true;
  nativeBuildInputs = with pkgs; [ cargo cargo-zigbuild zig jq coreutils gnutar xz perl ];
  dontConfigure = true;
  doCheck = false;
  buildPhase = ''
    runHook preBuild
    cd lyra
    export CARGO_HOME="$TMPDIR/cargo-home"
    export RUSTC="${toolchain}/bin/rustc"
    export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$CARGO_HOME"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
    tar -xJf ${sdk} -C "$TMPDIR"
    export SDKROOT="$TMPDIR/MacOSX11.3.sdk"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin x86_64-pc-windows-gnu; do
      cargo zigbuild --profile hardened --locked --offline --target "$target" --bin overalls
    done
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-linux-musl --bin overalls-ssh-authorize
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-linux-musl --bin overalls-host-certificate
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-linux-musl --bin overalls-trustd
    cargo zigbuild --profile hardened --locked --offline --target x86_64-unknown-linux-musl --bin overalls-workspaced
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/overalls" "$out/bin/linux-amd64"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/overalls-ssh-authorize" "$out/bin/overalls-ssh-authorize"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/overalls-host-certificate" "$out/bin/overalls-host-certificate"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/overalls-trustd" "$out/bin/overalls-trustd"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/hardened/overalls-workspaced" "$out/bin/overalls-workspaced"
    cp "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/hardened/overalls" "$out/bin/linux-arm64"
    cp "$CARGO_TARGET_DIR/x86_64-apple-darwin/hardened/overalls" "$out/bin/darwin-amd64"
    cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/hardened/overalls" "$out/bin/darwin-arm64"
    # Windows workstations (x86_64; Windows on Arm runs it under emulation).
    # Published without .exe; the installer saves it as overalls.exe.
    cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/hardened/overalls.exe" "$out/bin/windows-amd64"
    for binary in "$out"/bin/*; do
      test "$(stat -c %s "$binary")" -le 104857600
    done
    ${pkgs.python3}/bin/python3 - "$out" <<'PY'
import hashlib
import json
import pathlib
import sys

root: pathlib.Path = pathlib.Path(sys.argv[1])
names: tuple[str, ...] = ("linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64")
artifacts: dict[str, dict[str, str | int]] = {
    name: {
        "path": "/bin/" + name,
        "sha256": hashlib.sha256((root / "bin" / name).read_bytes()).hexdigest(),
        "bytes": (root / "bin" / name).stat().st_size,
    }
    for name in names
}
(root / "manifest.json").write_text(json.dumps({"version": "0.1.0", "artifacts": artifacts}, sort_keys=True))
PY
    runHook postInstall
  '';
  meta = {
    description = "Lyra SSH developer client for Linux, macOS and Windows";
    platforms = [ "x86_64-linux" ];
  };
  passthru.tests = tests;
  passthru.vendor = vendor;
  passthru.windows = windows;
  passthru.toolchain = toolchain;
  passthru.nativeBinaries = nativeBinaries;
  passthru.native = import ./lyra-native.nix {
    inherit pkgs source vendor toolchain nativeBinaries;
    inherit (workspace) lockSha256;
  };
}
