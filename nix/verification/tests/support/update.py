"""Publish immutable offline Buck2 fixture revisions of actual prebuilt NixOS candidates.

Each node imports support/update-fixture.nix, whose skeleton carries the real
tools/buck2, .buckconfig, toolchains and fleet rules plus a pinned cells
closure. The updater builds //fleet/hosts/host:deployment from it (ADR-0271).
"""

import json as _update_json
from typing import Protocol, TypedDict


class SucceedingMachine(Protocol):
    """Command execution supplied by the composed NixOS test driver machine."""

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...


class UpdateRevision(TypedDict):
    revision: str
    repository: str
    branch: str


class UpdateStatus(TypedDict, total=False):
    phase: str
    failedPhase: str
    failure: str
    candidate: UpdateRevision
    lastHealthy: UpdateRevision


UPDATE_FIXTURE = "/etc/overalls-update-fixture"


def update_fixture_flake(candidate: str, cells: str, systems: str = "") -> str:
    """A fixture flake whose lib.assemble returns the candidate bundle.

    nix_assemble evaluates lib.assemble under restrict-eval, which refuses path
    inputs, so the prebuilt candidate is named with builtins.storePath; the
    wrapper's buckCells stays a locked path input. `systems` replaces the
    default system set for histories that need another bundle.
    """
    body = (
        systems
        or f'{{ host.config.system.build.overallsDeployment = builtins.storePath "{candidate}"; }}'
    )
    return f"""{{
  inputs.cells = {{ url = "path:{cells}"; flake = false; }};
  outputs = {{ self, cells }}: {{
    buckCells.x86_64-linux = cells.outPath;
    lib.assemble = {{ revision ? null, artifacts ? {{ }}, params ? {{ }} }}: {{ systems = {body}; }};
  }};
}}"""


def update_repository(machine: SucceedingMachine) -> tuple[str, dict[str, str]]:
    machine.succeed("systemctl stop overalls-auto-update.timer")
    candidates: dict[str, str] = _update_json.loads(
        machine.succeed("cat /etc/overalls-update-candidates.json")
    )
    repo = "/var/lib/overalls-update-test/git"
    machine.succeed(f"mkdir -p {repo} && git -C {repo} init -b main")
    machine.succeed(f"git -C {repo} config user.email fixture@example.test")
    machine.succeed(f"git -C {repo} config user.name Fixture")
    machine.succeed(f"cp -rL --no-preserve=mode {UPDATE_FIXTURE}/. {repo}/")
    machine.succeed(f"chmod 0755 {repo}/tools/buck2 {repo}/buck/nix_assemble.sh && rm {repo}/cells")
    return repo, candidates


def update_publish(
    machine: SucceedingMachine, repository: str, candidate: str, message: str
) -> str:
    cells = machine.succeed(f"cat {UPDATE_FIXTURE}/cells").strip()
    flake = update_fixture_flake(candidate, cells)
    machine.succeed(f"cat > {repository}/flake.nix <<'NIX'\n{flake}\nNIX")
    machine.succeed(f"git -C {repository} add -A")
    machine.succeed(f"cd {repository} && nix flake lock --offline")
    machine.succeed(
        f"git -C {repository} add flake.lock && git -C {repository} commit --allow-empty -m {message}"
    )
    return machine.succeed(f"git -C {repository} rev-parse HEAD").strip()


def update_status(machine: SucceedingMachine) -> UpdateStatus:
    return _update_json.loads(machine.succeed("overalls-auto-update status"))


def update_success(machine: SucceedingMachine) -> None:
    machine.succeed("systemctl start overalls-auto-update.service", timeout=300)
    assert update_status(machine)["phase"] == "healthy"
