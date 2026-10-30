{ pkgs }:
# @cc [owner:ghuntley,label:build;security] locked-cargo-vendor
# Cargo dependencies whose sources a reviewed Cargo.lock fully pins MUST be
# vendored from that lock with importCargoLock, not by a separately hashed
# fixed-output fetch: the lock's per-crate checksums are the single pin. The
# result keeps fetchCargoVendor's layout (`.cargo/config.toml` with an
# `@vendor@` placeholder) so cross-toolchain builds substitute it unchanged.
{ name, lockFile }:
let
  locked = pkgs.rustPlatform.importCargoLock { inherit lockFile; };
in
pkgs.runCommand name { } ''
  mkdir -p "$out/.cargo"
  for crate in ${locked}/*; do
    ln -s "$(readlink -f "$crate")" "$out/$(basename "$crate")"
  done
  sed 's|^directory = "cargo-vendor-dir"$|directory = "@vendor@"|' \
    ${locked}/.cargo/config.toml > "$out/.cargo/config.toml"
  grep -q '^directory = "@vendor@"$' "$out/.cargo/config.toml"
''
