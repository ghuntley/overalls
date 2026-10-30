"""Fails when nix/buck/bootstrap_attrs.bzl differs from the flake's package and
check names (ADR-0269). Evaluates attribute names only; builds nothing.

Contract bootstrap-attrs-fresh: see buck/CONTRACTS.
"""

from __future__ import annotations

import ast
import json
import os
import subprocess
import sys
from pathlib import Path

ATTRS = Path("nix/buck/bootstrap_attrs.bzl")


def flake_names(nix: str, output: str) -> list[str]:
    out = subprocess.run(
        [nix, "eval", "--json", f".#{output}.x86_64-linux", "--apply", "builtins.attrNames"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    names: object = json.loads(out)
    if not isinstance(names, list):
        raise TypeError(f"{output}: expected a list of names")
    return sorted(str(n) for n in names)


def committed(name: str) -> list[str]:
    for line in ATTRS.read_text().splitlines():
        if line.startswith(f"{name} = "):
            value: object = ast.literal_eval(line.split(" = ", 1)[1])
            if isinstance(value, list):
                return sorted(str(v) for v in value)
    raise ValueError(f"{ATTRS} has no {name}")


def main() -> int:
    nix = os.environ.get("BUCK2_TEST_NIX", "nix")
    stale = False
    for output, name in (("packages", "BOOTSTRAP_PACKAGES"), ("checks", "BOOTSTRAP_CHECKS")):
        actual, recorded = flake_names(nix, output), committed(name)
        if actual != recorded:
            stale = True
            print(
                f"{ATTRS} {name} is stale: missing {sorted(set(actual) - set(recorded))}, "
                f"extra {sorted(set(recorded) - set(actual))}; run nix/buck/bootstrap-attrs.sh",
                file=sys.stderr,
            )
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
