{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "overalls-otel-guest-receiver";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./receiver;
    filter = path: _:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel";
  };
  cargoLock.lockFile = ./receiver/Cargo.lock;
}
