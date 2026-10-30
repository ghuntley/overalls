{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "lilly-resume-token";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../../../../lilly/native/resume-token;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name || builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ../../../../lilly/native/resume-token/Cargo.lock;
  strictDeps = true;
  doCheck = true;
  # The typed FFI shim links libzfs + libnvpair; the library stays a runtime
  # boundary: no zfs module or /dev/zfs is required to evaluate tokens.
  buildInputs = [ pkgs.zfs ];
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
  meta.platforms = [ "x86_64-linux" ];
}
