"""tools/buck2 runs under the host updater's command PATH (ADR-0271).

Contract buck2-wrapper-updater-path: see tools/CONTRACTS.

The host updater runs the candidate's `tools/buck2 --version` with a fixed
PATH (`commandPath` in nix/domains/system/auto-update/default.nix). A wrapper
that calls a command outside it fails every host update with
`build_tool_unavailable`, as `sed` and `awk` did on 2026-11-01. This check
runs the wrapper in a scratch checkout with:

- bash, coreutils, findutils, git and python3 from the cells (this check's
  own PATH, which BUCK.v2 sets), the commandPath tools the wrapper may use;
- stubs for nix, nix-store and curl, so no cells build or network is needed;
- nothing else, and bash's command_not_found_handle recording every missing
  command, including ones a `2>/dev/null` or `|| true` would hide.

It first checks that commandPath still names exactly UPDATER_COMMAND_PATH, so
the two lists cannot drift apart.

    python3 tools/buck2_updater_path_test.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "nix/domains/system/auto-update/default.nix"
# commandPath's entries, in order. Change both together.
UPDATER_COMMAND_PATH = (
    "pkgs.git",
    "pkgs.nix",
    "pkgs.nixos-rebuild",
    "pkgs.openssh",
    "pkgs.systemd",
    "pkgs.curl",
    "pkgs.coreutils",
    "pkgs.bash",
    "pkgs.findutils",
    "config.boot.zfs.package",
    "python",
)
# Commands from commandPath that this check stubs; the rest of the PATH is the
# real bash, coreutils, findutils, git and python3. nixos-rebuild, openssh,
# systemd and zfs are absent: the wrapper has no business calling them.
STUBBED = ("nix", "nix-store", "curl")
WRAPPER_FILES = ("tools/buck2", "tools/namespace.buckconfig", "tools/namespace-re-image.lock")
TOKEN = "nsrt_dummy-updater-path-check"
HANDLER = '() {  printf "%s\\n" "$1" >> "$OVERALLS_MISSING_LOG"; return 127; }'


class Run(NamedTuple):
    status: int
    stdout: str
    stderr: str
    missing: list[str]


def command_path_entries() -> tuple[str, ...]:
    match = re.search(r"commandPath = lib\.makeBinPath \[(.*?)\];", MODULE.read_text(), re.DOTALL)
    if match is None:
        raise SystemExit(f"{MODULE}: no `commandPath = lib.makeBinPath [ ... ];`")
    return tuple(match.group(1).split())


def write_executable(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)


def first_lock_entry(checkout: Path) -> tuple[str, str]:
    for line in (checkout / "tools/namespace-re-image.lock").read_text().splitlines():
        fields = line.split()
        if len(fields) >= 2 and re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            return fields[0], fields[1]
    raise SystemExit("tools/namespace-re-image.lock: no cells_id entry")


def prepare(scratch: Path) -> tuple[Path, Path, str]:
    """A git checkout with the wrapper's files, fake cells and the stubs."""
    checkout = scratch / "checkout"
    for name in WRAPPER_FILES:
        (checkout / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, checkout / name)
    subprocess.run(["git", "init", "-q", str(checkout)], check=True)
    subprocess.run(["git", "-C", str(checkout), "add", *WRAPPER_FILES], check=True)
    cells_id, image = first_lock_entry(checkout)
    cells = scratch / "cells"
    (cells / "bin").mkdir(parents=True)
    (cells / "toolchains.buckconfig").write_text(f"[nix]\n  cells_id = {cells_id}\n")
    write_executable(cells / "bin/buck2", 'echo "buck2-stub $*"\n')
    stubs = scratch / "stubs"
    stubs.mkdir()
    write_executable(stubs / "nix", f'[[ "$1" == build ]] && echo {cells}\nexit 0\n')
    write_executable(stubs / "nix-store", "exit 0\n")
    # The probe's answer: 401 is a live endpoint without credentials.
    write_executable(stubs / "curl", 'printf "%s" "${STUB_CURL_CODE:-401}"\n')
    assert sorted(path.name for path in stubs.iterdir()) == sorted(STUBBED)
    return checkout, stubs, image


def run(checkout: Path, stubs: Path, scratch: Path, **extra: str) -> Run:
    log = scratch / "missing.log"
    log.write_text("")
    environment = {
        "PATH": f"{stubs}:{os.environ['PATH']}",
        "HOME": str(scratch / "home"),
        "LC_ALL": "C.UTF-8",
        "NAMESPACE_RBE_TOKEN": TOKEN,
        "OVERALLS_MISSING_LOG": str(log),
        "BASH_FUNC_command_not_found_handle%%": HANDLER,
        **extra,
    }
    # As the updater calls it (buck2_command in runtime.py).
    result = subprocess.run(
        ["tools/buck2", "--isolation-dir", "overalls-update", "--version"],
        cwd=checkout,
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return Run(result.returncode, result.stdout, result.stderr, log.read_text().split())


def expect(condition: bool, message: str, outcome: Run | None = None) -> None:
    if not condition:
        detail = f"\nstatus {outcome.status}\n{outcome.stderr}" if outcome else ""
        raise SystemExit(f"tools/buck2 under the updater PATH: {message}{detail}")


def check_run(outcome: Run, case: str) -> None:
    expect(
        not outcome.missing,
        f"{case}: called commands outside the updater's commandPath: "
        + ", ".join(sorted(set(outcome.missing))),
        outcome,
    )
    expect(outcome.status == 0, f"{case}: exited non-zero", outcome)
    expect(
        "buck2-stub --isolation-dir overalls-update --version" in outcome.stdout,
        f"{case}: did not exec the cells' buck2",
        outcome,
    )


def main() -> None:
    entries = command_path_entries()
    expect(
        entries == UPDATER_COMMAND_PATH,
        f"commandPath in {MODULE.relative_to(ROOT)} is {list(entries)}; update "
        "UPDATER_COMMAND_PATH and this check's PATH together with it",
    )
    for tool in ("bash", "git", "find", "sha256sum", "python3"):
        expect(shutil.which(tool) is not None, f"this check's PATH lacks {tool}")
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory)
        checkout, stubs, image = prepare(scratch)
        include = checkout / ".buck-remote.buckconfig"

        outcome = run(checkout, stubs, scratch)
        check_run(outcome, "token, live cache")
        expect((checkout / ".buck-cells").is_symlink(), "no .buck-cells link", outcome)
        expect(include.is_file(), "no Namespace include with a token", outcome)
        text = include.read_text()
        expect("<file:tools/namespace.buckconfig>" in text, "include lacks the config")
        expect(f"re_image = {image}" in text, "include lacks the worker image")
        expect(TOKEN not in text, "the token was written into the include")

        # A recreated cluster answers 404: the include goes, the build stays local.
        (checkout / ".buck-remote.probe").unlink(missing_ok=True)
        outcome = run(checkout, stubs, scratch, STUB_CURL_CODE="404")
        check_run(outcome, "token, dead cache")
        expect(not include.exists(), "include kept for a dead cache", outcome)

        outcome = run(checkout, stubs, scratch, OVERALLS_BUCK2_REMOTE="off")
        check_run(outcome, "OVERALLS_BUCK2_REMOTE=off")
        expect(not include.exists(), "include written with the remote off", outcome)
    print("tools/buck2 runs with only the updater's commandPath tools")


if __name__ == "__main__":
    sys.exit(main())
