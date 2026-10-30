{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "overalls-observability-runtimes";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ./observability-runtimes;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name ||
          builtins.elem name [ "Cargo.toml" "Cargo.lock" "clippy.toml" ]);
  };
  cargoLock.lockFile = ./observability-runtimes/Cargo.lock;
  strictDeps = true;
  doCheck = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
}
