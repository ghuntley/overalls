{ pkgs }:
let
  inherit (pkgs) lib;
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
  # Mila's Rust core: every member under mila/rust of the root workspace
  # (ADR-0273), named exactly as its directory.
  crates = builtins.filter (lib.hasPrefix "mila/rust/") workspace.members;
  packages = lib.concatMapStringsSep " " (crate: "-p ${builtins.baseNameOf crate}") crates;
  source = workspace.source {
    name = "mila-rust-source";
    inherit crates;
    # Keep every file of the Mila crates (headers, fixtures) and only the
    # protocol vectors their tests read at `../../../protocol`.
    crateFile = _name: _rel: true;
    extraFiles = [
      "protocol/test/fixtures/app_routes.json"
      "protocol/test/fixtures/porsche_device_results.json"
      "protocol/test/fixtures/ssh_command_lines.json"
      "protocol/test/fixtures/ssh_host_certificates.json"
    ];
  };
  common = {
    version = "0.1.0";
    src = source;
    inherit (workspace) cargoLock;
    cargoBuildFlags = map (crate: "-p=${builtins.baseNameOf crate}") crates;
    strictDeps = true;
    nativeBuildInputs = [ workspace.rustTools ];
    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  # @cc [owner:ghuntley,label:build] mila-rust-source-build
  # The Mila Rust workspace MUST compile every tracked workspace member from
  # the root workspace Cargo.lock without reading build output or ambient sources.
  package = workspace.rustPlatform.buildRustPackage (common // {
    pname = "mila-rust";
    doCheck = false;
    installPhase = ''
      mkdir -p "$out/lib/mila-rust"
      cp -a target/release/. "$out/lib/mila-rust/"
      # The headless journey driver (ADR-0264) links the production C FFI.
      journey=$(find target -type f -path '*/release/mila-journey' | head -n 1)
      install -Dm755 "$journey" "$out/bin/mila-journey"
    '';
    meta.description = "Mila's Rust workspace libraries";
  });

  # @cc [owner:ghuntley,label:verification] mila-rust-workspace-check
  # The Mila Rust check MUST format, test and lint every workspace member with
  # the locked, vendored dependency set and warnings promoted to failures, and
  # compile the C header as strict C and C++.
  check = workspace.rustPlatform.buildRustPackage (common // {
    pname = "mila-rust-check";
    doCheck = false;
    buildPhase = ''
      runHook preBuild
      cargo fmt ${packages} -- --check
      # The one C header (mila-ffi-single-c-header) compiles as strict C and
      # C++; tests/header.rs keeps its declarations equal to the exports.
      for language in c c++; do
        $CC -x "$language" -fsyntax-only -Wall -Wextra -pedantic -Werror \
          mila/rust/mila-ffi/include/mila_ffi.h
      done
      cargo test ${packages} --locked --offline
      cargo clippy ${packages} --all-targets --locked --offline -- -D warnings
      runHook postBuild
    '';
    installPhase = "touch $out";
    meta.description = "Mila Rust workspace format, test and Clippy check";
  });
}
