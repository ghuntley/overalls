{ pkgs, lib, root }:
let
  source = lib.cleanSourceWith {
    name = "mila-native-linux-source";
    src = root;
    filter = path: type:
      let
        text = toString path;
        name = builtins.baseNameOf path;
      in !(lib.hasInfix "/target" text || name == ".git" || name == ".hegel");
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "mila-native-linux";
  version = "0.1.0";
  src = source;
  sourceRoot = "mila-native-linux-source/mila/native/linux";
  cargoLock.lockFile = root + "/mila/native/linux/Cargo.lock";
  nativeBuildInputs = [ pkgs.pkg-config pkgs.python3 pkgs.clippy pkgs.rustfmt ];
  buildInputs = [ pkgs.gtk4 pkgs.libadwaita ];
  # ADR-0265 gates: formatting and clippy over both feature sets.
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    cargo clippy --all-targets --locked --offline --features gtk-journey -- -D warnings
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/applications"
    binary=$(find target -type f -name mila-native-linux -perm -0100 | head -n 1)
    test -n "$binary"
    cp "$binary" "$out/bin/mila"
    cp data/dev.overalls.Mila.desktop "$out/share/applications/"
    runHook postInstall
  '';
  meta = {
    description = "Mila native GTK4/libadwaita Linux client";
    mainProgram = "mila";
    platforms = [ "x86_64-linux" ];
  };
}
