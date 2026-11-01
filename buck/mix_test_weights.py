"""Prints a Mix suite's `test_shard_weights` from its shard logs (ADR-0269).

Each shard log ends with ExUnit's `--slowest-modules` report:

    Marshall.Terminal.AttachmentHistoryTest (760123.5ms)
     [test/marshall/terminal/attachment_history_test.exs]

usage: python3 buck/mix_test_weights.py PROJECT MIN_SECONDS TEST_LOG...

Prints a Starlark dict of repository-relative test file -> whole seconds for
every module at or above MIN_SECONDS, heaviest first, to paste into the
project's BUCK as `test_shard_weights`. Contract mix-test-sharded: see
buck/CONTRACTS.
"""

from __future__ import annotations

import re
import sys
from itertools import pairwise
from pathlib import Path

MODULE = re.compile(r"^\S+ \((?P<ms>[0-9.]+)ms\)$")
FILE = re.compile(r"^ \[(?P<path>test/\S+_test\.exs)\]$")


def weights(logs: list[Path]) -> dict[str, float]:
    """Seconds per project-relative test file, from every log's slowest list."""
    found: dict[str, float] = {}
    for log in logs:
        lines = log.read_text(errors="replace").splitlines()
        for current, following in pairwise(lines):
            module = MODULE.match(current)
            path = FILE.match(following)
            if module and path:
                seconds = float(module.group("ms")) / 1000
                found[path.group("path")] = max(found.get(path.group("path"), 0.0), seconds)
    return found


def main(argv: list[str]) -> int:
    """Prints the dict; returns the process status."""
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    project, minimum = argv[0], float(argv[1])
    found = weights([Path(a) for a in argv[2:]])
    print("{")
    for path, seconds in sorted(found.items(), key=lambda item: (-item[1], item[0])):
        if seconds >= minimum:
            print(f'    "{project}/{path}": {round(seconds)},')
    print("}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
