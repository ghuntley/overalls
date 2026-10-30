{ pkgs, toolchain }:
# @cc [owner:ghuntley,label:build;guest] terminald-windows-cross-build
# The Windows terminal daemon MUST be cross-built from the same terminald
# source as the Linux daemon, for `x86_64-pc-windows-gnu` with Lyra's pinned
# toolchain and a hash-pinned vendored dependency set, without network access;
# the `.exe` MUST stay at or below 100 MiB and MUST be listed with its SHA-256
# in the output manifest so the image builder pins what it ships (ADR-0171).
let
  inherit (pkgs) lib;
  source = lib.cleanSourceWith {
    src = ../terminald;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || lib.hasSuffix ".rs" name ||
          builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  vendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "terminald-vendor";
    src = source;
    hash = (builtins.fromJSON (builtins.readFile ../dependency-hashes.json)).terminaldVendor;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "lilly-terminald-windows";
  passthru.vendor = vendor;
  version = "0.1.0";
  allowedReferences = [ ];
  src = source;
  strictDeps = true;
  dontStrip = true;
  dontConfigure = true;
  doCheck = false;
  nativeBuildInputs = with pkgs; [ cargo cargo-zigbuild zig coreutils ];
  buildPhase = ''
    runHook preBuild
    export CARGO_HOME="$TMPDIR/cargo-home"
    export RUSTC="${toolchain}/bin/rustc"
    export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    # Keep vendored-crate store paths out of panic locations (see lyra.nix).
    export RUSTFLAGS="--remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
    mkdir -p "$CARGO_HOME"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
    # ADR-0265: the cfg(windows) modules never compile on Linux, so the lint
    # gate runs here with the toolchain's own clippy for the Windows target.
    PATH="${toolchain}/bin:$PATH" cargo clippy --all-targets --locked --offline \
      --target x86_64-pc-windows-gnu -- -D warnings
    cargo zigbuild --release --locked --offline --target x86_64-pc-windows-gnu --bin lilly-terminald
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/lilly-terminald.exe" "$out/bin/overalls-terminald.exe"
    test "$(stat -c %s "$out/bin/overalls-terminald.exe")" -le 104857600
    digest="$(sha256sum "$out/bin/overalls-terminald.exe" | cut -d' ' -f1)"
    bytes="$(stat -c %s "$out/bin/overalls-terminald.exe")"
    printf '{"artifacts":{"overalls-terminald":{"bytes":%s,"path":"/bin/overalls-terminald.exe","sha256":"%s"}},"version":"0.1.0"}' \
      "$bytes" "$digest" > "$out/manifest.json"
    runHook postInstall
  '';
  meta = {
    description = "Overalls guest terminal multiplexer for Windows guests (ConPTY over viosock)";
    platforms = [ "x86_64-linux" ];
  };
}
