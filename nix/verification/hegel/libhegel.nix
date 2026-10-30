# @cc [owner:ghuntley,label:verification] libhegel-pin
# The Hegel engine MUST be pinned by tag and content hash; the Python binding
# in ./python verifies `hegel_version` against expectedVersion at load time.
{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "libhegel";
  version = "0.47.4";

  src = pkgs.fetchFromGitHub {
    owner = "hegeldev";
    repo = "hegel-rust";
    rev = "v0.47.4";
    hash = (import ../../domains/artifacts/pins.nix).libhegelSource;
  };

  # Build only the C-ABI engine crate (cdylib/staticlib); the Rust frontend
  # at the workspace root is not needed by the Python binding.
  cargoBuildFlags = [
    "-p"
    "hegeltest-c"
  ];
  doCheck = false;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    for candidate in \
      target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release \
      target/*/release \
      target/release; do
      if [ -e "$candidate/libhegel_c.so" ]; then
        cp "$candidate/libhegel_c.so" "$candidate/libhegel_c.a" $out/lib/
        break
      fi
    done
    test -e $out/lib/libhegel_c.so
    cp hegel-c/include/hegel.h $out/include/hegel.h
    runHook postInstall
  '';

  cargoHash = (import ../../domains/artifacts/pins.nix).libhegelCargo;

  meta = with pkgs.lib; {
    description = "Native property-based testing engine (C ABI) from the Hypothesis authors";
    homepage = "https://hegel.dev";
    license = licenses.mit;
    platforms = platforms.linux ++ platforms.darwin;
  };

  # hegel_version reports the hegeltest-c crate version (engine), which
  # differs from the repository tag (frontend version).
  passthru.expectedVersion = "0.43.7";
}
