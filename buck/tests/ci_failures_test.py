"""Fixtures for buck/ci_failures.py (ADR-0270): which earlier runs count and
which targets their failed jobs map to. Pure: no network and no Buck2.

Contract ci-reselect-failed: see buck/CONTRACTS.
"""

from __future__ import annotations

import sys
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ci_failures import (
    Affected,
    Job,
    Run,
    failed_targets,
    job_targets,
    parse_affected,
    since_green,
)

HOST = "root//fleet/hosts/panterloons:deployment"
LIB = "root//lilly:lib"
CHECK = "root//:check-python-static"
SYSCTL = "root//nix/verification/tests/machines/sysctl:sysctl"
NIXLD = "root//nix/verification/tests/machines/nix-ld:nix-ld"
UNIT = "root//lilly:test"

AFFECTED = parse_affected(
    {
        "machine_tests": [
            {"target": SYSCTL, "labels": ["machine_test"]},
            {"target": NIXLD, "labels": ["machine_test"]},
        ],
        "tests": [{"target": UNIT, "labels": []}],
        "builds": [
            {"target": LIB, "labels": []},
            {"target": HOST, "labels": []},
            {"target": CHECK, "labels": ["flake_output"]},
            {"target": "root//buck/probes:unsound", "labels": ["expected_failure"]},
        ],
    }
)


def run(number: int, conclusion: str, status: str = "completed") -> Run:
    return Run(id=1000 + number, number=number, status=status, conclusion=conclusion)


def check_since_green() -> None:
    runs = [
        run(1, "failure"),
        run(2, "success"),
        run(3, "failure"),
        run(4, "cancelled"),
        run(5, "", status="in_progress"),
        run(6, "failure"),
        run(7, "failure"),
    ]
    got = [r.number for r in since_green(runs, before=7)]
    assert got == [6, 4, 3], got
    assert since_green([run(1, "success")], before=2) == []
    assert [r.number for r in since_green([run(1, "failure")], before=2)] == [1]


def check_job_targets() -> None:
    assert job_targets("build fleet/hosts/panterloons:deployment", AFFECTED) == [HOST]
    # The build job never ran hosts, evaluated flake outputs or probes.
    assert job_targets("build", AFFECTED) == [LIB], job_targets("build", AFFECTED)
    assert job_targets("test", AFFECTED) == [UNIT]
    assert job_targets("nix-ld", AFFECTED) == [NIXLD]
    assert job_targets("evaluate 1", AFFECTED) == [SYSCTL, NIXLD, CHECK]
    assert job_targets("evaluate 2", AFFECTED) == []
    for name in ("affected", "ci", "precommit"):
        assert job_targets(name, AFFECTED) == [], name
    # Before e39019a21 flake outputs were labelled bootstrap.
    old = Affected(machine_tests=(), tests=(), builds=((CHECK, ("bootstrap",)),))
    assert job_targets("evaluate 1", old) == [CHECK]
    assert job_targets("build", old) == []


def check_failed_then_untouched() -> None:
    # Run 3 failed the Panterloons deployment and a machine test; run 4
    # touched neither and failed nothing, so its jobs did not run them. Run 5
    # (this one) must still select both: only a green run clears them.
    jobs = {
        3: [
            Job("build fleet/hosts/panterloons:deployment", "failure"),
            Job("sysctl", "timed_out"),
            Job("test", "success"),
            Job("ci", "failure"),
        ],
        4: [Job("build", "success"), Job("ci", "success")],
    }
    affected: dict[int, Affected | None] = {3: AFFECTED, 4: AFFECTED}
    runs = since_green([run(2, "success"), run(3, "failure"), run(4, "failure")], before=5)
    targets, notes = failed_targets(runs, lambda r: jobs[r.number], lambda r: affected[r.number])
    assert targets == sorted([HOST, SYSCTL]), targets
    assert notes == [], notes
    # A green run in between clears them.
    runs = since_green([run(3, "failure"), run(4, "success")], before=5)
    assert failed_targets(runs, lambda r: jobs[r.number], lambda r: affected[r.number]) == ([], [])


def check_missing_artifact() -> None:
    targets, notes = failed_targets(
        [run(3, "failure")], lambda r: [Job("sysctl", "failure")], lambda r: None
    )
    assert targets == [] and len(notes) == 1 and "no affected artifact" in notes[0], notes


def main() -> int:
    checks: list[tuple[str, Callable[[], None]]] = [
        ("since_green", check_since_green),
        ("job_targets", check_job_targets),
        ("failed then untouched is reselected", check_failed_then_untouched),
        ("missing artifact", check_missing_artifact),
    ]
    failures = 0
    for name, check in checks:
        try:
            check()
            print(f"ok   {name}")
        except AssertionError as error:
            failures += 1
            print(f"FAIL {name}: {error}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
