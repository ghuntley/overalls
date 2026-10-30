{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "overalls-trace-spool";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../../../../elixir/diagnostics/native/spool;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" && (type == "directory" || pkgs.lib.hasSuffix ".rs" name ||
        builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ../../../../elixir/diagnostics/native/spool/Cargo.lock;
  doCheck = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
  meta = { description = "Independent private durable OpenTelemetry trace custody";
    mainProgram = "overalls-trace-spool"; platforms = [ "x86_64-linux" ]; };
}
