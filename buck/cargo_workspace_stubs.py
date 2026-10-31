"""Give a copied Cargo workspace source empty target stubs for its other members.

Contract lyra-cross-buck2: see buck/CONTRACTS.

Usage: cargo_workspace_stubs.py ROOT CRATE...

ROOT holds the root Cargo.toml and every member manifest. For each member not
listed as a CRATE, create (empty) the files Cargo needs to load its manifest:
src/lib.rs, every declared lib, bin, test, example and bench path, and its
build script. This is the source layout of cargo-workspace.nix's `source`, so
a Buck2 Cargo build loads the same workspace as the Nix build it replaces,
and edits to other members cannot change its inputs.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

TARGET_KINDS = ("lib", "bin", "test", "example", "bench")


def as_tables(value: object) -> list[dict[str, object]]:
    """A manifest target entry as a list of tables ([lib] is one, [[bin]] many)."""
    items = value if isinstance(value, list) else [value]
    return [item for item in items if isinstance(item, dict)]


def stub_paths(manifest: dict[str, object]) -> list[str]:
    paths = ["src/lib.rs"]
    for kind in TARGET_KINDS:
        for target in as_tables(manifest.get(kind, [])):
            path = target.get("path")
            if isinstance(path, str):
                paths.append(path)
    package = manifest.get("package")
    if isinstance(package, dict):
        build = package.get("build")
        if isinstance(build, str):
            paths.append(build)
    return list(dict.fromkeys(paths))


def members(root: Path) -> list[str]:
    workspace = tomllib.loads((root / "Cargo.toml").read_text()).get("workspace")
    if not isinstance(workspace, dict):
        raise SystemExit("root Cargo.toml has no [workspace]")
    listed = workspace.get("members")
    if not isinstance(listed, list) or not all(isinstance(m, str) for m in listed):
        raise SystemExit("[workspace] members must be a list of paths")
    return [str(member) for member in listed]


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(argv[1])
    crates = set(argv[2:])
    for member in members(root):
        if member in crates:
            continue
        manifest = tomllib.loads((root / member / "Cargo.toml").read_text())
        for relative in stub_paths(manifest):
            stub = root / member / relative
            if not stub.exists():
                stub.parent.mkdir(parents=True, exist_ok=True)
                stub.touch()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
