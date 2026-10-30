{ pkgs }:
# @cc [owner:ghuntley,label:build] python-static-toolchain
# The Python gate MUST use one pinned ruff, ty and interpreter closure for the
# Buck2 py_static target, the precommit hook's direct fallback and the
# python-static Nix check, and third-party imports MUST resolve against these
# pinned closures instead of any ambient Python environment (ADR-0269).
{
  inherit (pkgs) ruff ty;
  # Third-party imports MUST resolve against pinned packages so the type check
  # rejects real interface drift instead of missing modules.
  tyPython = pkgs.python313.withPackages (p: [
    p.aiohttp
    p.boto3
    p.cryptography
    p.dnslib
    p.hypothesis
    p.playwright
    p.pyyaml
    p.websockets
  ]);
  harnessPython = pkgs.python313.withPackages (p: [ p.cryptography ]);
  antithesisWheels = import ../../antithesis/nix/python-wheels.nix { inherit pkgs; };
}
