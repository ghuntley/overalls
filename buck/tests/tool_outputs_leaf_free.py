"""Fails when a BUCK.v2 `_TOOL_OUTPUTS` package reads any assembly artifact.

Those packages assemble without ASSEMBLY_ARTIFACTS so `tools/buck2 run
//:host` does not build every leaf first. That is sound only while their
derivations do not depend on the artifacts; otherwise they would ship a
second, Nix-built copy that bypasses the leaf parity tests. The arguments are
every ASSEMBLY_ARTIFACTS key (buck/BUCK passes them), so a new Rust leaf or
Mix release is covered without editing this test. Each tool's drvPath without
artifacts must equal its drvPath with every key bound to a distinct stand-in
store path. Evaluates derivations only; builds nothing.

Contract tool-outputs-read-no-swapped-leaf: see buck/CONTRACTS.
"""

from __future__ import annotations

import ast
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# A bare path would make a `path:` flake that copies the whole working tree,
# buck-out included, and fails on a concurrent test's PostgreSQL socket there.
# `git+file:` takes tracked files only; shallow allows CI's shallow checkouts.
FLAKE = '(builtins.getFlake ("git+file://" + toString ./. + "?shallow=1"))'


def tool_outputs() -> list[str]:
    match = re.search(r"^_TOOL_OUTPUTS = (\[.*?\])$", Path("BUCK.v2").read_text(), re.M)
    if match is None:
        raise ValueError("BUCK.v2 has no _TOOL_OUTPUTS")
    value: object = ast.literal_eval(match.group(1))
    if not isinstance(value, list):
        raise TypeError("_TOOL_OUTPUTS is not a list")
    return [str(v) for v in value]


def drv_paths(nix: str, tools: list[str], keys: list[str], poisoned: bool) -> dict[str, str]:
    names = " ".join(json.dumps(t) for t in tools)
    # A distinct, existing store path per key: any read changes the drvPath.
    artifacts = (
        "builtins.listToAttrs (map (k: { name = k; value = { path = "
        'builtins.unsafeDiscardStringContext (builtins.toFile "stand-in-${k}" k); }; }) '
        f"[ {' '.join(json.dumps(k) for k in keys)} ])"
        if poisoned
        else "{ }"
    )
    expr = (
        f"let a = {FLAKE}.lib.assemble {{ artifacts = {artifacts}; }}; in "
        f"builtins.listToAttrs (map (n: {{ name = n; value = a.outputPackages.${{n}}.drvPath; }}) [ {names} ])"
    )
    result = subprocess.run(
        [nix, "eval", "--json", "--impure", "--expr", expr],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # The expression is ours, not secret; Nix's reason is the diagnosis.
        print(result.stderr, file=sys.stderr)
        raise RuntimeError(f"nix eval failed (poisoned={poisoned}, exit {result.returncode})")
    data: object = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise TypeError("expected an attribute set of drvPaths")
    return {str(k): str(v) for k, v in data.items()}


def main(keys: list[str]) -> int:
    if not keys:
        print("no ASSEMBLY_ARTIFACTS keys passed", file=sys.stderr)
        return 1
    nix = os.environ.get("BUCK2_TEST_NIX", "nix")
    tools = tool_outputs()
    plain = drv_paths(nix, tools, keys, poisoned=False)
    standing_in = drv_paths(nix, tools, keys, poisoned=True)
    failed = False
    for name in sorted(plain):
        if plain[name] != standing_in.get(name):
            failed = True
            print(
                f"{name} depends on assembly artifacts; remove it from _TOOL_OUTPUTS",
                file=sys.stderr,
            )
    print(f"{len(tools)} tool outputs independent of {len(keys)} artifacts")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
