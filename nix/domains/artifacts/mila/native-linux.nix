{ pkgs, lib }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
  source = workspace.source {
    name = "mila-native-linux-source";
    # The GTK client and the Mila Rust crates it links by path.
    crates = [ "mila/native/linux" ] ++ builtins.filter (lib.hasPrefix "mila/rust/") workspace.members;
    crateFile = _name: _rel: true;
    # build.rs bundles the shared catalogs; tests read protocol vectors.
    extraFiles = [ "mila/localization" "protocol/test/fixtures" ];
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "mila-native-linux";
  version = "0.1.0";
  src = source;
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "mila/native/linux";
  nativeBuildInputs = [ pkgs.pkg-config pkgs.python3 pkgs.clippy pkgs.rustfmt ];
  buildInputs = [ pkgs.gtk4 pkgs.libadwaita ];
  # ADR-0265 gates: formatting and clippy over both feature sets.
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    cargo clippy --all-targets --locked --offline --features gtk-journey -- -D warnings
    popd
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/applications"
    binary=$(find target -type f -name mila-native-linux -perm -0100 | head -n 1)
    test -n "$binary"
    cp "$binary" "$out/bin/mila"
    cp "$buildAndTestSubdir/data/dev.overalls.Mila.desktop" "$out/share/applications/"
    runHook postInstall
  '';
  meta = {
    description = "Mila native GTK4/libadwaita Linux client";
    mainProgram = "mila";
    platforms = [ "x86_64-linux" ];
  };
}
