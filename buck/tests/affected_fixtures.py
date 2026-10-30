"""Selection fixtures for tools/affected (ADR-0270).

Copies the tracked tree into a scratch repository, commits it as the base,
applies one change per fixture to the working tree and checks the selection.
Runs Buck2 queries only; no target is built.

Contract affected-targets-selection: see buck/CONTRACTS.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = Path("nix/verification/tests/machines/fleet/scenarios.json")
FLEET = "root//nix/verification/tests/machines/fleet:"
BUCK2 = ".buck-cells/bin/buck2"


def run(cwd: Path, *args: str) -> str:
    proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise AssertionError(f"{' '.join(args[:3])} failed:\n{proc.stderr[-3000:]}")
    return proc.stdout


def make_repo(tmp: Path) -> Path:
    repo = tmp / "repo"
    files = run(ROOT, "git", "ls-files", "-z").split("\0")
    for name in filter(None, files):
        source = ROOT / name
        if not source.exists() and not source.is_symlink():
            continue
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
    os.symlink(os.path.realpath(ROOT / ".buck-cells"), repo / ".buck-cells")
    run(repo, "git", "init", "-q", "-b", "base")
    run(repo, "git", "add", "-A")
    run(
        repo,
        "git",
        "-c",
        "user.name=fixture",
        "-c",
        "user.email=fixture@invalid",
        "commit",
        "-qm",
        "base",
    )
    return repo


def select(repo: Path) -> dict[str, object]:
    python = sys.executable
    out = run(repo, python, "buck/affected.py", "--base", "base")
    data: object = json.loads(out)
    if not isinstance(data, dict):
        raise AssertionError("selection is not an object")
    return {str(k): v for k, v in data.items()}


def targets(selection: dict[str, object], group: str) -> set[str]:
    value = selection[group]
    assert isinstance(value, list)
    return {str(e["target"]) for e in value if isinstance(e, dict)}


def reset(repo: Path) -> None:
    run(repo, "git", "reset", "-q", "--hard", "base")
    run(repo, "git", "clean", "-qfdx", "-e", ".buck-cells", "-e", "buck-out")


def touch(repo: Path, path: str) -> None:
    with (repo / path).open("a") as f:
        f.write("\n")


def first_lilly_lib(repo: Path) -> str:
    names = run(repo, "git", "ls-files", "lilly/lib").split()
    return sorted(n for n in names if n.endswith(".ex"))[0]


def main() -> int:
    scenarios: dict[str, list[str]] = json.loads((ROOT / SCENARIOS).read_text())
    fleet = {FLEET + v for v in scenarios}
    tmp = Path(tempfile.mkdtemp(prefix="overalls-affected-fixtures-"))
    repo = make_repo(tmp)
    failures: list[str] = []

    def fixture(
        name: str, change: Callable[[], None], check: Callable[[dict[str, object]], None]
    ) -> None:
        reset(repo)
        change()
        try:
            check(select(repo))
            print(f"ok   {name}")
        except AssertionError as error:
            failures.append(f"{name}: {error}")
            print(f"FAIL {name}: {error}")

    def docs_only(s: dict[str, object]) -> None:
        assert s["everything"] is False, s["reasons"]
        assert not targets(s, "machine_tests"), "docs selected machine tests"
        # Only repository-wide targets read docs/: the whole-tree flake
        # (bootstrap checks, assembly probes) and the per-file checks over
        # every owned file. Both also depend on the root package's files.
        query = "rdeps(//..., set(//:flake_srcs //:srcs_files))"
        wide = set(json.loads(run(repo, BUCK2, "uquery", query, "--json")))
        extra = sorted((targets(s, "tests") | targets(s, "builds")) - wide)
        assert not extra, f"docs selected targets that are not repository-wide: {extra}"

    def everything(s: dict[str, object]) -> None:
        assert s["everything"] is True, "expected everything"
        assert fleet <= targets(s, "machine_tests")
        assert "root//nix/verification/tests/machines/sysctl:sysctl" in targets(s, "machine_tests")

    def lilly(s: dict[str, object]) -> None:
        assert s["everything"] is False, s["reasons"]
        machines = targets(s, "machine_tests")
        assert fleet <= machines, f"missing fleet variants {sorted(fleet - machines)[:5]}"
        assert "root//nix/verification/tests/machines/zfs-guest:zfs-guest" in machines
        # Suites that take no application package are not Lilly-dependent.
        for free in ("sysctl:sysctl", "nix-ld:nix-ld", "fleet-network:fleet-network"):
            assert f"root//nix/verification/tests/machines/{free}" not in machines, free

    scenario = "scenarios/porsche-threads.py"
    expected = {FLEET + v for v, used in scenarios.items() if scenario in used}

    def one_scenario(s: dict[str, object]) -> None:
        assert s["everything"] is False, s["reasons"]
        assert expected, f"no variant uses {scenario}"
        assert targets(s, "machine_tests") == expected, sorted(targets(s, "machine_tests"))

    def unowned(s: dict[str, object]) -> None:
        assert s["everything"] is True, "an unowned file must select everything"
        assert s["unowned"] == ["vendor/node_modules/stray.txt"], s["unowned"]

    def add_unowned() -> None:
        (repo / "vendor/node_modules").mkdir(parents=True, exist_ok=True)
        (repo / "vendor/node_modules/stray.txt").write_text("stray\n")
        run(repo, "git", "add", "-f", "vendor/node_modules/stray.txt")

    fixture(
        "docs-only change selects only repository-wide targets",
        lambda: touch(repo, "docs/README.md"),
        docs_only,
    )
    fixture("flake.lock change selects everything", lambda: touch(repo, "flake.lock"), everything)
    fixture(
        "lilly/lib change selects Lilly tests and fleet variants",
        lambda: touch(repo, first_lilly_lib(repo)),
        lilly,
    )
    fixture(
        "one fleet scenario selects only its variants",
        lambda: touch(repo, f"nix/verification/tests/machines/fleet/{scenario}"),
        one_scenario,
    )
    fixture("deleted file resolves on base", lambda: (repo / first_lilly_lib(repo)).unlink(), lilly)
    fixture("unowned file selects everything", add_unowned, everything)
    fixture("unowned file is reported", add_unowned, unowned)

    subprocess.run(
        [str(repo / ".buck-cells/bin/buck2"), "kill"], cwd=repo, capture_output=True, check=False
    )
    shutil.rmtree(tmp, ignore_errors=True)
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
