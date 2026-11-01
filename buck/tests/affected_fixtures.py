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
    # The base commit holds the whole tree as loose objects, which starts a
    # detached `git gc --auto`. It removed .git/objects/NN while a nested
    # Buck2 crawled the root, and the query failed with read_dir ENOENT
    # (ci run 41228962477). Nothing here needs packing.
    run(repo, "git", "config", "gc.auto", "0")
    run(repo, "git", "config", "maintenance.auto", "false")
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


def select(repo: Path, *extra: str) -> dict[str, object]:
    python = sys.executable
    out = run(repo, python, "buck/affected.py", "--base", "base", *extra)
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
        name: str,
        change: Callable[[], None],
        check: Callable[[dict[str, object]], None],
        extra: tuple[str, ...] = (),
    ) -> None:
        reset(repo)
        change()
        try:
            check(select(repo, *extra))
            print(f"ok   {name}")
        except AssertionError as error:
            failures.append(f"{name}: {error}")
            print(f"FAIL {name}: {error}")

    def docs_only(s: dict[str, object]) -> None:
        assert s["everything"] is False, s["reasons"]
        assert not targets(s, "machine_tests"), "docs selected machine tests"
        # Only repository-wide targets read docs/: the whole-tree flake
        # (flake package and check assemblies, assembly probes) and the per-file checks over
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

    # Replays of two regressions that reached trunk before graph selection
    # (ADR-0270): each fix's source change must select the suite that covers it.
    def replay_ab3816ebb() -> None:
        touch(repo, "lilly/lib/lilly/network/guest.ex")
        touch(repo, "lilly/native/hostd/src/policy.rs")

    def guest_reachability(s: dict[str, object]) -> None:
        # hostd is a host package, so host-only suites are selected too; the
        # Lilly-only exclusions of `lilly` do not apply.
        assert s["everything"] is False, s["reasons"]
        machines = targets(s, "machine_tests")
        assert fleet <= machines, f"missing fleet variants {sorted(fleet - machines)[:5]}"
        for suite in ("galileo-fleet", "memory-suspension-fleet"):
            assert FLEET + suite in machines, f"{suite} not selected"

    audi = "scenarios/audi.py"
    audi_variants = {FLEET + v for v, used in scenarios.items() if audi in used}

    def audi_scenario(s: dict[str, object]) -> None:
        assert s["everything"] is False, s["reasons"]
        assert FLEET + "audi-fleet" in audi_variants, "audi-fleet no longer uses audi.py"
        fleet_selected = targets(s, "machine_tests") & fleet
        assert fleet_selected == audi_variants, sorted(fleet_selected ^ audi_variants)

    fixture(
        "replay ab3816ebb: guest network change selects galileo-fleet",
        replay_ab3816ebb,
        guest_reachability,
    )
    fixture(
        "replay 8fab8c411: audi scenario selects only its fleet variants",
        lambda: touch(repo, f"nix/verification/tests/machines/fleet/{audi}"),
        audi_scenario,
    )
    # A target whose ci.yml job failed since the last green run, untouched by
    # this range, is selected again; a label head no longer has is dropped.
    # A fleet scenario change selects only its fleet variants among the
    # machine tests, so sysctl is selected only through --reselect.
    failing = "root//nix/verification/tests/machines/sysctl:sysctl"
    gone = "root//nix/verification/tests/machines/sysctl:removed-since"
    failed = tmp / "failed.json"
    failed.write_text(json.dumps([failing, gone]))

    def untouched(s: dict[str, object]) -> None:
        assert failing not in targets(s, "machine_tests"), "the change already selects it"
        assert s["reselected"] == [], s["reselected"]

    def reselected(s: dict[str, object]) -> None:
        assert s["everything"] is False, s["reasons"]
        assert targets(s, "machine_tests") == expected | {failing}, sorted(
            targets(s, "machine_tests") ^ expected
        )
        assert s["reselected"] == [failing], s["reselected"]

    def unreadable(s: dict[str, object]) -> None:
        errors = s["errors"]
        assert isinstance(errors, list) and errors, "an unreadable history must be an error"
        assert failing not in targets(s, "machine_tests"), "nothing is reselected from it"

    def touch_scenario() -> None:
        touch(repo, f"nix/verification/tests/machines/fleet/{scenario}")

    fixture("untouched target is not selected without reselection", touch_scenario, untouched)
    fixture(
        "failed then untouched target is reselected",
        touch_scenario,
        reselected,
        ("--reselect", str(failed)),
    )
    fixture(
        "unreadable failure history is a selection error",
        touch_scenario,
        unreadable,
        ("--reselect", str(tmp / "missing.json")),
    )
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
