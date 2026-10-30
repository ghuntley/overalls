{ pkgs }:
let
  # Contract python-static-toolchain: see nix/buck/python.nix.
  python = import ../../../buck/python.nix { inherit pkgs; };
in
# @cc [owner:ghuntley,label:verification] python-static-repository-root
# Formatting, lint and type checks MUST run from the repository root with its
# reviewed pyproject.toml and all maintained Python trees in scope. The Buck2
# //:py-static target is the canonical gate; this Nix check stays until M11.
pkgs.runCommand "overalls-python-static" {
  nativeBuildInputs = [ python.ruff python.ty ];
} ''
  export RUFF_CACHE_DIR="$TMPDIR/ruff"
  export XDG_CACHE_HOME="$TMPDIR/cache"
  cd ${../../../..}
  ruff format --check .
  ruff check .
  ${pkgs.bash}/bin/bash antithesis/verification/static-check.sh \
    ${python.ty}/bin/ty ${python.tyPython}/bin/python3 ${python.harnessPython}/bin/python3 ${python.antithesisWheels}
  touch $out
''
