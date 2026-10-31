{ pkgs, toolchain }:
let
  inherit (pkgs) lib;
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
  source = workspace.source { name = "overalls-vscode-web-broker-source"; crates = [ "nix/domains/artifacts/vscode-web-broker" ]; };
  inherit (workspace) vendor;
in
# @cc [owner:ghuntley,label:build;security] windows-editor-broker-offline-build
# The Windows broker MUST cross-link the maintained source for the reviewed
# Windows target with the pinned Lyra Rust toolchain and locked crate inputs.
# Its executable MUST contain no Nix store references. A built executable MUST
# NOT establish Windows image capability or native browser acceptance.
pkgs.stdenv.mkDerivation {
  pname = "overalls-vscode-web-broker-windows";
  version = "0.1.0";
  src = source;
  strictDeps = true;
  allowedReferences = [ ];
  dontConfigure = true;
  dontStrip = true;
  doCheck = false;
  nativeBuildInputs = [ toolchain ] ++ (with pkgs; [ cargo-zigbuild zig coreutils ]);
  buildPhase = ''
    runHook preBuild
    cd ${lib.escapeShellArg "nix/domains/artifacts/vscode-web-broker"}
    export CARGO_HOME="$TMPDIR/cargo-home"
    export RUSTC="${toolchain}/bin/rustc"
    export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    export RUSTFLAGS="--remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
    mkdir -p "$CARGO_HOME"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
    cargo zigbuild --profile hardened --locked --offline --target x86_64-pc-windows-gnu --bin overalls-vscode-web-broker
    # Tests cannot run on the build host; rustfmt and a cross-target clippy
    # with the pinned toolchain gate the cfg(windows) modules instead.
    cargo fmt --check
    PATH="${toolchain}/bin:$PATH" cargo clippy --target x86_64-pc-windows-gnu --all-targets --locked --offline -- -D warnings
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/hardened/overalls-vscode-web-broker.exe" "$out/bin/overalls-vscode-web-broker.exe"
    test "$(stat -c %s "$out/bin/overalls-vscode-web-broker.exe")" -le 104857600
    digest="$(sha256sum "$out/bin/overalls-vscode-web-broker.exe" | cut -d' ' -f1)"
    bytes="$(stat -c %s "$out/bin/overalls-vscode-web-broker.exe")"
    printf '{"version":1,"target":"win32-x64","editor_capability":false,"broker":{"path":"bin/overalls-vscode-web-broker.exe","bytes":%s,"sha256":"%s"}}' \
      "$bytes" "$digest" > "$out/manifest.json"
    runHook postInstall
  '';
  passthru = {
    targetPlatform = "win32-x64";
    editorCapability = false;
    inherit vendor;
  };
  meta = {
    description = "Account-bound Windows broker for the source-built Overalls browser editor";
    platforms = [ "x86_64-linux" ];
  };
}
