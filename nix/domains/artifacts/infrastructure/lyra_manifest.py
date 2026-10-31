"""Write the manifest of Lyra's client or Windows agent executables.

Usage: lyra_manifest.py OUT SUFFIX NAME...

Each NAME is OUT/bin/NAME+SUFFIX. OUT/manifest.json lists every one with its
SHA-256 and size so the image builder and installer can pin what they ship
(contract lyra-windows-cross-build in lyra.nix). The bytes are those of the
inline scripts it replaced: sorted keys, no trailing newline.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import TypedDict


class Artifact(TypedDict):
    """One executable in the manifest."""

    path: str
    sha256: str
    bytes: int


class Manifest(TypedDict):
    """manifest.json."""

    version: str
    artifacts: dict[str, Artifact]


def manifest(root: Path, suffix: str, names: list[str]) -> Manifest:
    artifacts: dict[str, Artifact] = {}
    for name in names:
        executable = root / "bin" / (name + suffix)
        artifacts[name] = {
            "path": "/bin/" + name + suffix,
            "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "bytes": executable.stat().st_size,
        }
    return {"version": "0.1.0", "artifacts": artifacts}


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(argv[1])
    (root / "manifest.json").write_text(
        json.dumps(manifest(root, argv[2], argv[3:]), sort_keys=True)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
