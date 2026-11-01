"""lib.assemble's per-target params channel validates and resolves its input.

nix_assemble passes a target's `params` (fleet_host(params = ...)) to
lib.assemble as JSON. Every known parameter must resolve to the value the
assembly uses, and every unknown key, wrong type or path outside the
repository must be an evaluation error rather than silently ignored. All
cases run in one evaluation (builtins.tryEval), so the flake is copied once.
Evaluates only; builds nothing.

Contract assembly-params-validated: see nix/assemble/default.nix.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import TypedDict

FLAKE = "(builtins.getFlake (toString ./.))"

ROOTS = ["secrets/brady-root.pem"]


class Case(TypedDict):
    name: str
    params: object
    ok: bool


CASES: list[Case] = [
    {"name": "no parameters keep the defaults", "params": {}, "ok": True},
    {"name": "a known parameter resolves", "params": {"privateServiceRoots": ROOTS}, "ok": True},
    {"name": "an unknown key fails", "params": {"privateServiceRoot": ROOTS}, "ok": False},
    {
        "name": "a wrong type fails",
        "params": {"privateServiceRoots": "secrets/brady-root.pem"},
        "ok": False,
    },
    {"name": "an empty list fails", "params": {"privateServiceRoots": []}, "ok": False},
    {
        "name": "an absolute path fails",
        "params": {"privateServiceRoots": ["/etc/passwd"]},
        "ok": False,
    },
    {
        "name": "a parent path fails",
        "params": {"privateServiceRoots": ["../secrets/x.pem"]},
        "ok": False,
    },
]


def evaluate(nix: str) -> list[object]:
    cases = " ".join(
        f"(builtins.fromJSON {json.dumps(json.dumps(case['params']))})" for case in CASES
    )
    expr = (
        f"let assemble = {FLAKE}.lib.assemble; "
        "probe = params: let r = builtins.tryEval (let p = (assemble { inherit params; }).params; "
        "in builtins.deepSeq p (builtins.mapAttrs (_: map toString) p)); "
        "in if r.success then r.value else null; "
        f"in map probe [ {cases} ]"
    )
    out = subprocess.run(
        [nix, "eval", "--json", "--impure", "--expr", expr],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data: object = json.loads(out)
    if not isinstance(data, list) or len(data) != len(CASES):
        raise TypeError("expected one result per case")
    return data


def main() -> int:
    nix = os.environ.get("BUCK2_TEST_NIX", "nix")
    results = evaluate(nix)
    failures: list[str] = []
    for case, result in zip(CASES, results, strict=True):
        if case["ok"] != (result is not None):
            failures.append(f"{case['name']}: got {json.dumps(result)}")
    resolved = results[1]
    if not (
        isinstance(resolved, dict)
        and isinstance(roots := resolved.get("privateServiceRoots"), list)
        and len(roots) == 1
        and isinstance(roots[0], str)
        and roots[0].endswith("/" + ROOTS[0])
    ):
        failures.append(f"privateServiceRoots resolved to {json.dumps(resolved)}")
    if results[0] != {}:
        failures.append(f"no parameters resolved to {json.dumps(results[0])}")
    for failure in failures:
        print(failure, file=sys.stderr)
    if not failures:
        print(f"{len(CASES)} params cases behave")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
