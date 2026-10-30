{ pkgs }:
pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "overalls-vscode-web-broker";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" && (type == "directory" || pkgs.lib.hasSuffix ".rs" name ||
        builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
  meta = {
    description = "Account-bound Overalls guest broker for source-built VS Code";
    platforms = [ "x86_64-linux" ];
    mainProgram = "overalls-vscode-web-broker";
  };
}
