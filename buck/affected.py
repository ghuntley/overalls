"""Select the Buck2 targets affected by a change (ADR-0270).

Compares unconfigured target hashes (file mode paths_and_contents) of the base
revision against the working tree, adds the reverse dependencies of every
changed file's owners, and groups the result as machine_tests, tests and
builds. Only Buck2 loading and queries run: no action and no Nix derivation is
built. Run it through tools/affected.

Contract affected-targets-selection: see buck/CONTRACTS.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Generator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import TypedDict

# Paths whose change alters the cells, the toolchains or Buck2's own
# configuration: every target's inputs change, so everything is selected.
# These mirror the key inputs of tools/buck2.
GLOBAL_FILES = frozenset(
    {
        ".buckconfig",
        "flake.lock",
        "flake.nix",
        "tools/buck2",
        "nix/domains/artifacts/dependency-hashes.json",
        "nix/domains/artifacts/infrastructure/toolchain.nix",
        # The nixos_machine_test command, part of the rule implementation.
        "buck/machine_tests.py",
    }
)
GLOBAL_PREFIXES = ("toolchains/", "nix/buck/")
GLOBAL_SUFFIXES = ("Cargo.lock", "package-lock.json")
# Rule implementations are not part of unconfigured target hashes.
RULE_FILES_PREFIX = "buck/"
RULE_FILES_SUFFIX = ".bzl"
# Architecture records and prose have no owning target (ownership.bxl).
UNOWNED_ALLOWED = "docs/"


def needs_owner(path: str) -> bool:
    """BUCK files enter through target hashes rather than ownership."""
    name = path.rsplit("/", 1)[-1]
    return not path.startswith(UNOWNED_ALLOWED) and name not in ("BUCK", "BUCK.v2")


class Entry(TypedDict):
    target: str
    labels: list[str]


class Failure(TypedDict):
    side: str
    package: str
    error: str


class Selection(TypedDict):
    base: str
    everything: bool
    reasons: list[str]
    changed_files: list[str]
    unowned: list[str]
    machine_tests: list[Entry]
    tests: list[Entry]
    builds: list[Entry]
    errors: list[Failure]


@dataclass
class Graph:
    hashes: dict[str, str] = field(default_factory=dict)
    errors: list[Failure] = field(default_factory=list)
    failed_packages: set[str] = field(default_factory=set)


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout


def changed_files(root: Path, base: str) -> tuple[list[str], list[str]]:
    """Files present on head (added or modified) and files only on base."""
    present: list[str] = []
    deleted: list[str] = []
    out = git(root, "diff", "--no-renames", "--name-status", "-z", base, "--")
    fields = out.split("\0")
    for status, path in zip(fields[0::2], fields[1::2], strict=False):
        if not status:
            continue
        (deleted if status.startswith("D") else present).append(path)
    return sorted(present), sorted(deleted)


def global_reasons(files: Sequence[str]) -> list[str]:
    reasons: list[str] = []
    for f in files:
        if (
            f in GLOBAL_FILES
            or f.startswith(GLOBAL_PREFIXES)
            or f.endswith(GLOBAL_SUFFIXES)
            or (f.startswith(RULE_FILES_PREFIX) and f.endswith(RULE_FILES_SUFFIX))
        ):
            reasons.append(f"{f} changes toolchains, cells or rules")
    return reasons


def buck2_json(buck2: str, cwd: Path, args: Sequence[str]) -> object:
    proc = subprocess.run([buck2, *args], cwd=cwd, capture_output=True, text=True, check=False)
    if proc.returncode != 0 and not proc.stdout.strip():
        raise RuntimeError(f"buck2 {' '.join(args[:2])} failed in {cwd}:\n{proc.stderr[-4000:]}")
    return json.loads(proc.stdout or "null")


def target_hashes(buck2: str, cwd: Path, side: str) -> Graph:
    data = buck2_json(
        buck2,
        cwd,
        [
            "targets",
            "//...",
            "--show-unconfigured-target-hash",
            "--target-hash-file-mode=paths_and_contents",
            "--target-hash-recursive=true",
            "--keep-going",
            "--json",
        ],
    )
    graph = Graph()
    if not isinstance(data, list):
        raise RuntimeError(f"buck2 targets on {side}: expected a list")
    for item in data:
        if not isinstance(item, dict):
            continue
        package = str(item.get("buck.package", ""))
        if "buck.error" in item:
            graph.failed_packages.add(package)
            graph.errors.append(Failure(side=side, package=package, error=str(item["buck.error"])))
            continue
        label = f"{package}:{item.get('name', '')}"
        graph.hashes[label] = str(item.get("buck.target_hash", ""))
    return graph


def owners(buck2: str, cwd: Path, files: Sequence[str]) -> dict[str, list[str]]:
    if not files:
        return {}
    data = buck2_json(buck2, cwd, ["uquery", "owner(%s)", *files, "--json"])
    result: dict[str, list[str]] = {f: [] for f in files}
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, list):
                result[str(key)] = [str(v) for v in value]
    return result


@contextmanager
def base_checkout(root: Path, base: str) -> Generator[Path]:
    """A detached worktree of base that reuses head's cells (identical when no
    global input changed, which is checked first)."""
    tmp = Path(tempfile.mkdtemp(prefix="overalls-affected-"))
    tree = tmp / "base"
    git(root, "worktree", "add", "--detach", "--quiet", str(tree), base)
    try:
        os.symlink(os.path.realpath(root / ".buck-cells"), tree / ".buck-cells")
        yield tree
    finally:
        cells = root / ".buck-cells" / "bin" / "buck2"
        subprocess.run([str(cells), "kill"], cwd=tree, capture_output=True, check=False)
        git(root, "worktree", "remove", "--force", str(tree))
        shutil.rmtree(tmp, ignore_errors=True)


def bxl(
    buck2: str, root: Path, files: Sequence[str], targets: Sequence[str], everything: bool
) -> dict[str, object]:
    args = ["bxl", "//buck/bxl/affected.bxl:main", "--"]
    if everything:
        args += ["--all", "true"]
    if files:
        args += ["--files", *files]
    if targets:
        args += ["--targets", *targets]
    data = buck2_json(buck2, root, args)
    if not isinstance(data, dict):
        raise RuntimeError("affected.bxl: expected an object")
    return {str(k): v for k, v in data.items()}


def _entries(value: object) -> list[Entry]:
    result: list[Entry] = []
    if isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                labels = item.get("labels", [])
                result.append(
                    Entry(
                        target=str(item.get("target", "")),
                        labels=[str(x) for x in labels] if isinstance(labels, list) else [],
                    )
                )
    return result


def select(root: Path, base: str, everything: bool) -> Selection:
    # The cells' own buck2: selection must not rebuild the cells (a changed
    # global input selects everything regardless of which cells list it).
    cells = root / ".buck-cells" / "bin" / "buck2"
    buck2 = str(cells if cells.exists() else root / "tools" / "buck2")
    # Selecting everything needs no base: the scheduled full run checks out
    # one commit, so HEAD^ does not exist there.
    present, deleted = ([], []) if everything else changed_files(root, base)
    files = present + deleted
    reasons = ["requested"] if everything else global_reasons(files)
    errors: list[Failure] = []
    seeds: set[str] = set()
    unowned: list[str] = []
    head = target_hashes(buck2, root, "head")
    errors += head.errors
    if not reasons:
        with base_checkout(root, base) as tree:
            old = target_hashes(buck2, tree, "base")
            errors += old.errors
            for f, found in owners(buck2, tree, [f for f in deleted if needs_owner(f)]).items():
                if not found:
                    unowned.append(f)
                seeds.update(t for t in found if t in head.hashes)
        for label, digest in head.hashes.items():
            package = label.rsplit(":", 1)[0]
            if old.hashes.get(label) != digest or package in old.failed_packages:
                seeds.add(label)
    result = bxl(buck2, root, [f for f in present if needs_owner(f)], sorted(seeds), bool(reasons))
    owned = result.get("unowned", [])
    unowned += [str(f) for f in owned] if isinstance(owned, list) else []
    if unowned and not reasons:
        reasons = [f"{f} has no owning target" for f in sorted(unowned)]
        result = bxl(buck2, root, [], [], True)
    return Selection(
        base="" if everything else git(root, "rev-parse", base).strip(),
        everything=bool(reasons),
        reasons=reasons,
        changed_files=files,
        unowned=sorted(unowned),
        machine_tests=_entries(result.get("machine_tests")),
        tests=_entries(result.get("tests")),
        builds=_entries(result.get("builds")),
        errors=errors,
    )


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="tools/affected")
    parser.add_argument("--base", default="HEAD^", help="base revision (default HEAD^)")
    parser.add_argument("--all", action="store_true", help="select every target")
    parser.add_argument("--output", type=Path, help="write the JSON here instead of stdout")
    args = parser.parse_args(argv)
    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    selection = select(root, str(args.base), bool(args.all))
    text = json.dumps(selection, indent=2) + "\n"
    output: Path | None = args.output
    if output is None:
        sys.stdout.write(text)
    else:
        output.write_text(text)
    for failure in selection["errors"]:
        print(
            f"selection error ({failure['side']}) {failure['package']}: {failure['error']}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
