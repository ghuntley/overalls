{ lib, rustPlatform, clippy, rustfmt }:
rustPlatform.buildRustPackage {
  pname = "overalls-otel-guest-receiver";
  version = "0.1.0";
  # examples/ stays: the otel-request-recorder machine test builds
  # examples/request_fixture.rs from this source.
  src = lib.cleanSourceWith {
    src = ./receiver;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" && (type == "directory" || lib.hasSuffix ".rs" name ||
        builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ./receiver/Cargo.lock;
  nativeBuildInputs = [ clippy rustfmt ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
}
