"""A Nix toolchain path change MUST change the target hash of a consumer
(ADR-0269): compares //buck/probes:elixir_version's unconfigured hash under the
pinned and a substituted elixir path. Loads targets only, in its own daemon.

Contract nix-toolchain-paths-in-action-keys: see toolchains/CONTRACTS.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

BUCK2 = Path(".buck-cells/bin/buck2")
TARGET = "//buck/probes:elixir_version"
ISOLATION = "--isolation-dir=toolchain-hash-test"


def target_hash(*config: str) -> str:
    out = subprocess.run(
        [
            str(BUCK2),
            ISOLATION,
            "targets",
            TARGET,
            "--show-unconfigured-target-hash",
            "--target-hash-recursive=true",
            "--json",
            *config,
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data: object = json.loads(out)
    if not isinstance(data, list) or not data or not isinstance(data[0], dict):
        raise TypeError("unexpected buck2 targets output")
    return str(data[0]["buck.target_hash"])


def main() -> int:
    try:
        pinned = target_hash()
        again = target_hash()
        changed = target_hash(
            "-c", "nix.elixir=/nix/store/00000000000000000000000000000000-elixir-test"
        )
    finally:
        subprocess.run([str(BUCK2), ISOLATION, "kill"], capture_output=True, check=False)
    if pinned != again:
        print(f"{TARGET} hash is not stable: {pinned} != {again}", file=sys.stderr)
        return 1
    if pinned == changed:
        print(f"{TARGET} hash ignores the elixir toolchain path", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
