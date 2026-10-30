{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-vm-watch";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../../../../lilly/native/vm-watch;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name || builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ../../../../lilly/native/vm-watch/Cargo.lock;
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
  meta.platforms = [ "x86_64-linux" ];
}
