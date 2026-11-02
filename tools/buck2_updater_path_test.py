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
  nix-store's realises the cells' pinned nsc as a stub that answers
  `nsc bazel setup --token` (ADR-0276), and curl's answers the cache probe;
- nothing else, and bash's command_not_found_handle recording every missing
  command, including ones a `2>/dev/null` or `|| true` would hide.

It also checks the Namespace endpoint handling a host relies on: the
addresses come from the pinned nsc with the token on a file descriptor, a
rotated address is looked up again, and a cache that answers 404 or 401, or
no lookup at all, leaves the include out. No stub ever sees the token in argv.

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
import time
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
NSC_DRV = "/nix/store/00000000000000000000000000000000-nsc-0.0.0.drv"
LIVE = "storageh-live.example.invalid:443"
ROTATED = "storageh-rotated.example.invalid:443"
ENGINE = "reapih-live.example.invalid:443"
HANDLER = '() {  printf "%s\\n" "$1" >> "$OVERALLS_MISSING_LOG"; return 127; }'


class Run(NamedTuple):
    status: int
    stdout: str
    stderr: str
    missing: list[str]
    calls: str


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
    (cells / "nsc.drv").write_text(NSC_DRV + "\n")
    write_executable(cells / "bin/buck2", 'echo "buck2-stub $*"\n')
    # The pinned nsc: the token must arrive as {"bearer_token": ...} on the
    # file named by --token; it prints the endpoints `nsc bazel setup -o json`
    # prints for a token, or fails like a rejected one.
    nsc = scratch / "nsc"
    (nsc / "bin").mkdir(parents=True)
    write_executable(
        nsc / "bin/nsc",
        'printf "nsc %s\\n" "$*" >> "$STUB_CALLS"\n'
        "file=\n"
        'while (($#)); do [[ "$1" == --token ]] && file=$2; shift; done\n'
        '[[ -n "$file" && "$(<"$file")" == \'{"bearer_token":"\'"$STUB_TOKEN"\'"}\' ]] || exit 1\n'
        '[[ -z "${STUB_NSC_FAIL:-}" ]] || exit 1\n'
        'echo "nsc-token-on-fd" >> "$STUB_CALLS"\n'
        'printf \'{\\n  "scheduler_endpoint": "grpcs://%s",\\n  "storage_endpoint": "grpcs://%s"\\n}\\n\' '
        f'"{ENGINE}" "${{STUB_NSC_STORAGE:-{LIVE}}}"\n',
    )
    stubs = scratch / "stubs"
    stubs.mkdir()
    write_executable(stubs / "nix", f'[[ "$1" == build ]] && echo {cells}\nexit 0\n')
    write_executable(
        stubs / "nix-store",
        'printf "nix-store %s\\n" "$*" >> "$STUB_CALLS"\n'
        f'if [[ "$1" == --add-root && "$3" == --realise && "$4" == {NSC_DRV} ]]; then\n'
        f'  ln -sfn {nsc} "$2" && echo "$2"\n'
        "fi\nexit 0\n",
    )
    # The cache probe: an authenticated GetCapabilities on a live host
    # answers 200 with grpc-status 0; a host in STUB_CURL_DEAD answers 404;
    # a missing or wrong bearer header gets 401.
    write_executable(
        stubs / "curl",
        'printf "curl %s\\n" "$*" >> "$STUB_CALLS"\n'
        "header= url=\n"
        "while (($#)); do\n"
        '  [[ "$1" == -H && "$2" == @* ]] && header=$(<"${2#@}")\n'
        '  [[ "$1" == https://* ]] && url=$1\n'
        "  shift\n"
        "done\n"
        "host=${url#https://}; host=${host%%/*}\n"
        'if [[ " ${STUB_CURL_DEAD:-} " == *" $host "* ]]; then echo "code=404"; exit 0; fi\n'
        'if [[ "$header" != "x-nsc-ingress-auth: Bearer $STUB_TOKEN" ]]; then echo "code=401"; exit 0; fi\n'
        'printf "HTTP/2 200\\r\\ngrpc-status: 0\\r\\n\\r\\ncode=200\\n"\n',
    )
    assert sorted(path.name for path in stubs.iterdir()) == sorted(STUBBED)
    return checkout, stubs, image


def host_path() -> str:
    """This check's PATH without a developer's nsc, which the updater lacks."""
    entries = os.environ["PATH"].split(os.pathsep)
    return os.pathsep.join(entry for entry in entries if not (Path(entry) / "nsc").exists())


def run(checkout: Path, stubs: Path, scratch: Path, **extra: str) -> Run:
    log = scratch / "missing.log"
    log.write_text("")
    calls = scratch / "calls.log"
    calls.write_text("")
    environment = {
        "PATH": f"{stubs}:{host_path()}",
        "HOME": str(scratch / "home"),
        "LC_ALL": "C.UTF-8",
        "NAMESPACE_RBE_TOKEN": TOKEN,
        "OVERALLS_MISSING_LOG": str(log),
        "STUB_CALLS": str(calls),
        "STUB_TOKEN": TOKEN,
        "BASH_FUNC_command_not_found_handle%%": HANDLER,
        **extra,
    }
    # As the updater calls it (buck2_command in runtime.py).
    result = subprocess.run(
        ["tools/buck2", "--isolation-dir", "v2", "--version"],
        cwd=checkout,
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return Run(
        result.returncode, result.stdout, result.stderr, log.read_text().split(), calls.read_text()
    )


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
        "buck2-stub --isolation-dir v2 --version" in outcome.stdout,
        f"{case}: did not exec the cells' buck2",
        outcome,
    )
    expect(TOKEN not in outcome.calls, f"{case}: the token reached a command's argv", outcome)


def reset(checkout: Path) -> None:
    """Forget the endpoint lookup and the probe, as on a fresh checkout."""
    for name in (".buck-remote.endpoints", ".buck-remote.probe"):
        (checkout / name).unlink(missing_ok=True)


def addresses(include: Path) -> str:
    if not include.is_file():
        return ""
    text = include.read_text()
    match = re.search(r"cas_address = (\S+)", text)
    return match.group(1) if match else ""


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
        expect("nsc-token-on-fd" in outcome.calls, "the pinned nsc did not get the token", outcome)
        expect((checkout / ".buck-nsc.gcroot").is_symlink(), "pinned nsc not rooted", outcome)
        text = include.read_text()
        expect("<file:tools/namespace.buckconfig>" in text, "include lacks the config")
        expect(f"engine_address = {ENGINE}" in text, "include lacks the looked-up engine")
        expect(addresses(include) == LIVE, "include lacks the looked-up cache", outcome)
        expect(f"re_image = {image}" in text, "include lacks the worker image")
        expect(TOKEN not in text, "the token was written into the include")

        # Within the hour the recorded endpoints serve without a lookup.
        (checkout / ".buck-remote.probe").unlink()
        outcome = run(checkout, stubs, scratch)
        check_run(outcome, "token, recorded endpoints")
        expect("nsc " not in outcome.calls, "looked up again within the hour", outcome)
        expect(addresses(include) == LIVE, "recorded endpoints not used", outcome)

        # Namespace rotated the cache host since the last lookup: the probe
        # finds the recorded one gone and a new lookup finds the new one.
        (checkout / ".buck-remote.probe").unlink()
        old = time.time() - 600
        os.utime(checkout / ".buck-remote.endpoints", (old, old))
        outcome = run(checkout, stubs, scratch, STUB_CURL_DEAD=LIVE, STUB_NSC_STORAGE=ROTATED)
        check_run(outcome, "token, rotated cache host")
        expect(addresses(include) == ROTATED, "rotated host not looked up again", outcome)

        # A cache that answers 404 even after a fresh lookup: the include
        # goes, and the build stays local.
        reset(checkout)
        outcome = run(checkout, stubs, scratch, STUB_CURL_DEAD=LIVE)
        check_run(outcome, "token, dead cache")
        expect(not include.exists(), "include kept for a dead cache", outcome)
        expect("does not answer (HTTP 404)" in outcome.stderr, "no dead-cache notice", outcome)

        # A token the cache rejects (401): local too.
        reset(checkout)
        outcome = run(checkout, stubs, scratch, STUB_TOKEN="nsrt_other-token")
        check_run(outcome, "rejected token")
        expect(not include.exists(), "include kept for a rejected token", outcome)

        # No lookup succeeds and none is recorded: local, with no committed
        # address to fall back on.
        reset(checkout)
        outcome = run(checkout, stubs, scratch, STUB_NSC_FAIL="1")
        check_run(outcome, "token, failed lookup")
        expect(not include.exists(), "include written without an endpoint", outcome)
        expect("no Namespace cache endpoint" in outcome.stderr, "no lookup notice", outcome)

        outcome = run(checkout, stubs, scratch, OVERALLS_BUCK2_REMOTE="off")
        check_run(outcome, "OVERALLS_BUCK2_REMOTE=off")
        expect(not include.exists(), "include written with the remote off", outcome)
    print("tools/buck2 runs with only the updater's commandPath tools")


if __name__ == "__main__":
    sys.exit(main())
