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
  # Inputs of lyra-build.sh, which both these derivations and the Buck2
  # `lyra_cross` rule run (contract lyra-shared-build).
  buildVars = {
    LYRA_RUST = "${toolchain}";
    LYRA_VENDOR = "${vendor}";
    LYRA_PYTHON = "${pkgs.python313}/bin/python3.13";
    LYRA_MANIFEST = "${./lyra_manifest.py}";
    LYRA_MACOS_SDK = "${sdk}";
  };
  exports = vars: lib.concatStrings (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}\n") vars);
  buildEnv = exports buildVars;
  native = import ./lyra-native.nix {
    inherit pkgs source vendor toolchain nativeBinaries buildVars exports;
    inherit (workspace) lockSha256;
  };
  # Every tool lyra-build.sh runs, for the Buck2 rule: the Nix builds get the
  # same set from nativeBuildInputs and stdenv. The tools and both SDKs are
  # this derivation's references, so realising it fetches them; Buck2's cells
  # name only its .drv (buck/lyra.bzl).
  buckInputs = pkgs.writeTextDir "env.sh" (exports (buildVars // native.buildVars // {
    PATH = lib.makeBinPath ([ toolchain ] ++ (with pkgs; [ cargo-zigbuild zig jq perl python313 stdenv.cc stdenv.cc.bintools ]) ++ pkgs.stdenv.initialPath);
    LYRA_BWRAP = "${pkgs.bubblewrap}/bin/bwrap";
    LYRA_SH = "${pkgs.bash}/bin/bash";
  }));
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
    # cargo, rustc, clippy and rustfmt all come from the one toolchain
    # (ADR-0273), never from nixpkgs.
    nativeBuildInputs = [ toolchain ] ++ (with pkgs; [ openssh openssl perl util-linux git ]);
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
    nativeBuildInputs = [ toolchain ] ++ (with pkgs; [ cargo-zigbuild zig jq coreutils gnutar xz perl ]);
    dontConfigure = true;
    doCheck = false;
    buildPhase = ''
      runHook preBuild
      ${buildEnv}
      bash ${./lyra-build.sh} windows "$out"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
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
  nativeBuildInputs = [ toolchain ] ++ (with pkgs; [ cargo-zigbuild zig jq coreutils gnutar xz perl ]);
  dontConfigure = true;
  doCheck = false;
  buildPhase = ''
    runHook preBuild
    ${buildEnv}
    bash ${./lyra-build.sh} client "$out"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
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
  passthru.native = native;
  passthru.buckInputs = buckInputs;
  passthru.macosSdk = sdk;
}
