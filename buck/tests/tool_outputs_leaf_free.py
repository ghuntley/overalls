"""Fails when a BUCK.v2 `_TOOL_OUTPUTS` package reads a Buck2-swapped leaf.

Those packages assemble without ASSEMBLY_ARTIFACTS so `tools/buck2 run
//:host` does not build every leaf first. That is sound only while no
swapped leaf (rustArtifactNames in nix/domains/artifacts/default.nix) is in
their closure; otherwise they would ship a second, Nix-built copy that
bypasses the leaf parity tests. Evaluates derivations only; builds nothing.

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

ASSEMBLE = "((builtins.getFlake (toString ./.)).lib.assemble { })"
# Every swapLeaf in the package set, by an expression over `p` (the set).
LEAVES = (
    "p.terminald",
    "p.lyra",
    "p.lyra.windows",
    "p.lyra.native",
    "p.lyra.native.probes",
    "p.otelReceiver",
    "p.enricoGitOwner",
    "p.observabilityRuntimes",
    "p.traceSpool",
    "p.vscodeWebBroker",
    "p.hostLock",
)


def tool_outputs() -> list[str]:
    match = re.search(r"^_TOOL_OUTPUTS = (\[.*?\])$", Path("BUCK.v2").read_text(), re.M)
    if match is None:
        raise ValueError("BUCK.v2 has no _TOOL_OUTPUTS")
    value: object = ast.literal_eval(match.group(1))
    if not isinstance(value, list):
        raise TypeError("_TOOL_OUTPUTS is not a list")
    return [str(v) for v in value]


def evaluate(nix: str, tools: list[str]) -> tuple[set[str], dict[str, str]]:
    names = " ".join(json.dumps(t) for t in tools)
    expr = (
        f"let a = {ASSEMBLE}; p = a.packages; in {{ "
        f"leaves = map (d: d.drvPath) [ {' '.join(LEAVES)} ]; "
        f"tools = builtins.listToAttrs (map (n: {{ name = n; value = a.outputPackages.${{n}}.drvPath; }}) [ {names} ]); }}"
    )
    out = subprocess.run(
        [nix, "eval", "--json", "--impure", "--expr", expr],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data: object = json.loads(out)
    if not isinstance(data, dict):
        raise TypeError("expected an attribute set")
    leaves, drvs = data.get("leaves"), data.get("tools")
    if not isinstance(leaves, list) or not isinstance(drvs, dict):
        raise TypeError("expected leaves and tools")
    return {str(x) for x in leaves}, {str(k): str(v) for k, v in drvs.items()}


def main() -> int:
    nix = os.environ.get("BUCK2_TEST_NIX", "nix")
    store = str(Path(nix).parent / "nix-store")
    leaves, drvs = evaluate(nix, tool_outputs())
    failed = False
    for name, drv in sorted(drvs.items()):
        closure = set(
            subprocess.run(
                [store, "-qR", drv], check=True, capture_output=True, text=True
            ).stdout.split()
        )
        if hits := sorted(closure & leaves):
            failed = True
            print(
                f"{name} reads swapped leaves {hits}; remove it from _TOOL_OUTPUTS", file=sys.stderr
            )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
