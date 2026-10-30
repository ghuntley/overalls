{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-zfs-namespace-unmount";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../../../../lilly/native/zfs-namespace-unmount;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name || builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ../../../../lilly/native/zfs-namespace-unmount/Cargo.lock;
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
  meta.platforms = [ "x86_64-linux" ];
}
