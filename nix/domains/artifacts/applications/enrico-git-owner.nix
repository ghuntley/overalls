{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "enrico-git-owner";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../../../../enrico/native/git-owner;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name ||
          builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" "clippy.toml" ]);
  };
  cargoLock.lockFile = ../../../../enrico/native/git-owner/Cargo.lock;
  strictDeps = true;
  doCheck = true;
  # Generated histories fork native owners and must not inherit another
  # concurrent history's live pipe descriptors.
  checkFlags = [ "--test-threads=1" ];
  nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
  ENRICO_TEST_SHELL = "${pkgs.bash}/bin/bash";
  ENRICO_TEST_SETSID = "${pkgs.util-linux}/bin/setsid";
  preCheck = ''export PATH=${pkgs.coreutils}/bin:$PATH'';
  postCheck = ''
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
  '';
  meta.platforms = [ "x86_64-linux" ];
}
