"""Targets whose ci.yml job failed since the last green trunk run (ADR-0270).

ci.yml selects from the head of the newest earlier started run, so a target
that failed there and was not touched again would not be selected again, and
a later run could pass while the failure persists. This module lists the
earlier push runs of ci.yml on the branch, newest first, back to the newest
one that succeeded, and maps each failed or timed-out job of the runs in
between to the targets it ran, using that run's `affected` artifact (the
affected.json that planned it). tools/affected then reselects them
(--reselect).

Run as: python buck/ci_failures.py --repo OWNER/NAME --branch trunk
--before RUN_NUMBER --output failed.json, with GH_TOKEN in the environment.

Contract ci-reselect-failed: see buck/CONTRACTS.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import urllib.request
import zipfile
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

API = "https://api.github.com"
# How far back to look for a green run; older failures go to the daily run.
MAX_RUNS = 50
# Mirrors ci.yml's Plan jobs step: evaluations shard 20 per runner; flake
# output assemblies (labelled bootstrap before e39019a21) are evaluated, not
# built; expected_failure probes never build; whole host systems and the
# kexec image build in their own `build <target>` jobs.
EVALUATE_SHARD = 20
EVALUATED = frozenset({"flake_output", "bootstrap"})
HOST_PREFIXES = ("root//fleet/hosts/", "root//nix/platform:")
FAILED = frozenset({"failure", "timed_out"})
# Jobs that run no selected target of their own.
UNMAPPED = frozenset({"affected", "ci", "precommit"})


@dataclass(frozen=True)
class Run:
    id: int
    number: int
    status: str
    conclusion: str


@dataclass(frozen=True)
class Job:
    name: str
    conclusion: str


@dataclass(frozen=True)
class Affected:
    """The parts of one run's affected.json that its jobs were planned from."""

    machine_tests: tuple[tuple[str, tuple[str, ...]], ...]
    tests: tuple[str, ...]
    builds: tuple[tuple[str, tuple[str, ...]], ...]


def _str(value: object) -> str:
    return value if isinstance(value, str) else ""


def _int(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def _entries(value: object) -> tuple[tuple[str, tuple[str, ...]], ...]:
    result: list[tuple[str, tuple[str, ...]]] = []
    if isinstance(value, list):
        for item in value:
            if not isinstance(item, dict):
                continue
            target = _str(item.get("target"))
            labels = item.get("labels")
            names = tuple(_str(x) for x in labels) if isinstance(labels, list) else ()
            if target:
                result.append((target, names))
    return tuple(result)


def parse_affected(data: object) -> Affected:
    if not isinstance(data, dict):
        raise ValueError("affected.json is not an object")
    return Affected(
        machine_tests=_entries(data.get("machine_tests")),
        tests=tuple(t for t, _ in _entries(data.get("tests"))),
        builds=_entries(data.get("builds")),
    )


def parse_runs(data: object) -> list[Run]:
    runs = data.get("workflow_runs") if isinstance(data, dict) else None
    result: list[Run] = []
    if isinstance(runs, list):
        for item in runs:
            if isinstance(item, dict):
                result.append(
                    Run(
                        id=_int(item.get("id")),
                        number=_int(item.get("run_number")),
                        status=_str(item.get("status")),
                        conclusion=_str(item.get("conclusion")),
                    )
                )
    return result


def parse_jobs(data: object) -> list[Job]:
    jobs = data.get("jobs") if isinstance(data, dict) else None
    result: list[Job] = []
    if isinstance(jobs, list):
        for item in jobs:
            if isinstance(item, dict):
                result.append(
                    Job(name=_str(item.get("name")), conclusion=_str(item.get("conclusion")))
                )
    return result


def since_green(runs: Sequence[Run], before: int) -> list[Run]:
    """Completed runs older than `before`, newest first, up to (excluding)
    the newest run that succeeded. Runs still in progress are left to the
    run that follows them."""
    result: list[Run] = []
    for run in sorted(runs, key=lambda r: r.number, reverse=True):
        if run.number >= before or run.status != "completed":
            continue
        if run.conclusion == "success":
            break
        result.append(run)
    return result


def _evaluation_targets(affected: Affected) -> list[str]:
    # Mirrors ci.yml's Plan jobs step: every machine test's assembly, then
    # the bootstrap builds. Each evaluation stands for its owning target.
    return [t for t, _ in affected.machine_tests] + [
        t for t, labels in affected.builds if EVALUATED & set(labels)
    ]


def job_targets(name: str, affected: Affected) -> list[str]:
    """The targets a ci.yml job ran, by job name (see ci.yml's job names)."""
    builds = [
        t
        for t, labels in affected.builds
        if not (EVALUATED | {"expected_failure"}) & set(labels) and not t.startswith(HOST_PREFIXES)
    ]
    if name in UNMAPPED:
        return []
    if name == "build":
        return builds
    if name == "test":
        return list(affected.tests)
    if name.startswith("build "):
        return ["root//" + name.removeprefix("build ")]
    if name.startswith("evaluate "):
        index = name.removeprefix("evaluate ")
        if index.isdigit() and int(index) >= 1:
            start = (int(index) - 1) * EVALUATE_SHARD
            return _evaluation_targets(affected)[start : start + EVALUATE_SHARD]
        return []
    # A machine test job is named after its target's name.
    return [t for t, _ in affected.machine_tests if t.rsplit(":", 1)[-1] == name]


def failed_targets(
    runs: Sequence[Run],
    jobs_of: Callable[[Run], list[Job]],
    affected_of: Callable[[Run], Affected | None],
) -> tuple[list[str], list[str]]:
    """Targets of every failed job in `runs`, and notes on what was skipped."""
    targets: set[str] = set()
    notes: list[str] = []
    for run in runs:
        failed = [j.name for j in jobs_of(run) if j.conclusion in FAILED]
        if not failed:
            continue
        affected = affected_of(run)
        if affected is None:
            notes.append(f"run {run.id}: no affected artifact; jobs {failed} not reselected")
            continue
        for name in failed:
            found = job_targets(name, affected)
            if not found and name not in UNMAPPED:
                notes.append(f"run {run.id}: job {name!r} maps to no target")
            targets.update(found)
    return sorted(targets), notes


class GitHub:
    def __init__(self, repo: str, token: str) -> None:
        self.repo = repo
        self.token = token

    def _get(self, url: str) -> bytes:
        request = urllib.request.Request(url)
        # Artifact downloads redirect to presigned storage, which must not
        # receive the token.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        request.add_header("Accept", "application/vnd.github+json")
        with urllib.request.urlopen(request, timeout=60) as response:
            body: bytes = response.read()
            return body

    def json(self, path: str) -> object:
        data: object = json.loads(self._get(f"{API}/repos/{self.repo}/{path}"))
        return data

    def runs(self, branch: str) -> list[Run]:
        return parse_runs(
            self.json(
                f"actions/workflows/ci.yml/runs?event=push&branch={branch}&per_page={MAX_RUNS}"
            )
        )

    def jobs(self, run: Run) -> list[Job]:
        return parse_jobs(self.json(f"actions/runs/{run.id}/jobs?per_page=100&filter=latest"))

    def affected(self, run: Run) -> Affected | None:
        listing = self.json(f"actions/runs/{run.id}/artifacts?name=affected")
        artifacts = listing.get("artifacts") if isinstance(listing, dict) else None
        if not isinstance(artifacts, list) or not artifacts or not isinstance(artifacts[0], dict):
            return None
        url = _str(artifacts[0].get("archive_download_url"))
        if not url or artifacts[0].get("expired") is True:
            return None
        with zipfile.ZipFile(io.BytesIO(self._get(url))) as archive:
            data: object = json.loads(archive.read("affected.json"))
        return parse_affected(data)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="buck/ci_failures.py")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--before", type=int, required=True, help="this run's number")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    github = GitHub(str(args.repo), os.environ.get("GH_TOKEN", ""))
    runs = since_green(github.runs(str(args.branch)), int(args.before))
    targets, notes = failed_targets(runs, github.jobs, github.affected)
    output: Path = args.output
    output.write_text(json.dumps(targets, indent=2) + "\n")
    for note in notes:
        print(f"ci_failures: {note}", file=sys.stderr)
    print(
        f"ci_failures: {len(targets)} targets failed in {len(runs)} runs since the last green run",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
