{ pkgs }:
let
  inherit (pkgs) lib;
  root = ../../../../mila/rust;
  source = lib.cleanSourceWith {
    name = "mila-rust-source";
    # Keep the Rust workspace under the repository's `mila/rust` path so its
    # protocol fixture test resolves `../../../protocol` exactly as it does in
    # a checkout, while including only the two vectors that test needs.
    src = ../../../../.;
    filter = path: type:
      let
        name = builtins.baseNameOf path;
        relative = lib.removePrefix (toString ../../../../.) (toString path);
        rustPath = lib.hasPrefix "/mila/rust" relative;
        rustParent = relative == "/mila";
        fixture = builtins.elem relative [
          "/protocol"
          "/protocol/test"
          "/protocol/test/fixtures"
          "/protocol/test/fixtures/app_routes.json"
          "/protocol/test/fixtures/ssh_command_lines.json"
          "/protocol/test/fixtures/ssh_host_certificates.json"
        ];
      in
        (rustPath && name != "target" && name != ".hegel") || rustParent || fixture;
  };
  common = {
    version = "0.1.0";
    src = source;
    sourceRoot = "mila-rust-source/mila/rust";
    cargoLock.lockFile = root + "/Cargo.lock";
    cargoBuildFlags = [ "--workspace" ];
    strictDeps = true;
    nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  # @cc [owner:ghuntley,label:build] mila-rust-source-build
  # The Mila Rust workspace MUST compile every tracked workspace member from
  # its committed Cargo.lock without reading build output or ambient sources.
  package = pkgs.rustPlatform.buildRustPackage (common // {
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
  # the locked, vendored dependency set and warnings promoted to failures.
  check = pkgs.rustPlatform.buildRustPackage (common // {
    pname = "mila-rust-check";
    doCheck = false;
    buildPhase = ''
      runHook preBuild
      cargo fmt --all -- --check
      cargo test --workspace --locked --offline
      cargo clippy --workspace --all-targets --locked --offline -- -D warnings
      runHook postBuild
    '';
    installPhase = "touch $out";
    meta.description = "Mila Rust workspace format, test and Clippy check";
  });
}
