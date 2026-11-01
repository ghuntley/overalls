"""An orphaned Mix sandbox MUST exit with every process in it (ADR-0269 M6).

Buck2 does not kill a local action's process tree when its daemon exits, so
buck/mix_sandbox.sh watches for its own reparenting. This starts the script
under a stand-in parent with a long-running process tree inside bwrap, kills
that parent, and requires the tree to be gone within a few seconds. Without
the watch the orphans kept writing into a scratch path the next daemon reused
("Directory not empty" when it prepared the output directories).

Contract mix-actions-sandboxed: see buck/CONTRACTS. Needs unprivileged user
namespaces, as every Mix action does.
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path

CELLS_CONFIG = Path(".buck-cells/toolchains.buckconfig")
SANDBOX = Path("buck/mix_sandbox.sh")
DEADLINE_S = 5.0


def cells_tools() -> dict[str, str]:
    """The `key = value` lines of the cells' toolchain config."""
    tools: dict[str, str] = {}
    for line in CELLS_CONFIG.read_text().splitlines():
        key, separator, value = line.strip().partition(" = ")
        if separator:
            tools[key] = value
    return tools


def processes_with(token: str) -> list[int]:
    """PIDs whose command line contains token."""
    found: list[int] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes()
        except OSError:
            continue
        if token.encode() in cmdline:
            found.append(int(entry.name))
    return found


def wait_until(condition: Callable[[], bool], timeout: float) -> bool:
    """Poll a predicate until it holds or timeout passes."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return condition()


def main() -> int:
    tools = cells_tools()
    bash, bwrap = tools["bash"], tools["bwrap"]
    sleep = f"{tools['coreutils']}/sleep"
    # A unique duration names this test's sleepers among the host's processes.
    token = f"{3000 + os.getpid() % 1000}.{time.monotonic_ns() % 10**6:06d}"
    sandbox = SANDBOX.resolve()
    with tempfile.TemporaryDirectory(prefix="mix-sandbox-orphan-") as directory:
        work = Path(directory)
        (work / "phases.sh").write_text("")
        (work / "tree").write_text("")
        # A process tree: one sleeper in the background and one in front.
        (work / "script.sh").write_text(
            f': > /io/started\n"{sleep}" {token} &\n"{sleep}" {token}\n'
        )
        env = {
            "PATH": f"{tools['coreutils']}:{tools['findutils']}",
            "BUCK_SCRATCH_PATH": "scratch",
        }
        sandbox_args = [bash, str(sandbox), bwrap, "/dev/null", "phases.sh", "script.sh", "tree"]
        # The stand-in parent for the Buck2 forkserver: it waits on the script.
        parent = subprocess.Popen(
            [bash, "-c", '"$@" & wait', "parent", *sandbox_args],
            cwd=work,
            env=env,
            start_new_session=True,
        )
        started = work / "scratch" / "io" / "started"
        try:
            if not wait_until(lambda: started.exists() and len(processes_with(token)) >= 2, 30.0):
                print(
                    "mix_sandbox_orphan: the sandbox did not start its process tree",
                    file=sys.stderr,
                )
                return 1
            os.kill(parent.pid, signal.SIGKILL)
            parent.wait()
            if not wait_until(lambda: not processes_with(token), DEADLINE_S):
                print(
                    f"mix_sandbox_orphan: sandbox processes outlived their parent: {processes_with(token)}",
                    file=sys.stderr,
                )
                return 1
            if not wait_until(lambda: not processes_with(str(sandbox)), DEADLINE_S):
                print("mix_sandbox_orphan: mix_sandbox.sh outlived its parent", file=sys.stderr)
                return 1
        finally:
            for pid in processes_with(token) + processes_with(str(sandbox)):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
            # The sandbox's copies are read-only; make them removable.
            subprocess.run(["chmod", "-R", "u+w", str(work)], env=env, check=False)
    print("mix_sandbox_orphan: the orphaned sandbox exited with its process tree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
