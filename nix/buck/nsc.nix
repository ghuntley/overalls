{ pkgs }:
# @cc [owner:ghuntley,label:build;security] namespace-cli-pinned
# The Namespace CLI that tools/buck2 runs, where no nsc is on PATH (fleet
# hosts and GitHub-hosted runners), to resolve the current Namespace cache
# endpoints from the tenant token (ADR-0276) MUST be this release, fetched
# with the pin registry's SHA-256. buckCells carries only its derivation, so
# the cells closure and the remote-execution worker image never contain it;
# tools/buck2 realises it on first use.
let
  version = "0.0.588";
in
pkgs.runCommandLocal "nsc-${version}" {
  src = pkgs.fetchurl {
    url = "https://github.com/namespacelabs/foundation/releases/download/v${version}/nsc_${version}_linux_amd64.tar.gz";
    hash = (import ../domains/artifacts/pins.nix).nscLinuxAmd64;
  };
} ''
  mkdir -p "$out/bin"
  tar -xzf "$src" -C "$out/bin" nsc
  chmod 0555 "$out/bin/nsc"
''
