"""Observe the actual VM-owned process tree without reading arguments or console data."""

import json
import sys
import uuid
from pathlib import Path
from typing import TypedDict


class ProcessRow(TypedDict):
    pid: int
    start: int
    executable: str
    device: int
    inode: int


class SurvivalRow(TypedDict):
    pid: int
    start: int
    command: str


# @cc [owner:ghuntley,label:verification] fleet-vmm-survival-identity
# Survival assertions MUST compare host PIDs and kernel start times of the actual
# Firecracker process tree. A newly started replacement or an active unit alone
# MUST NOT establish uninterrupted execution.
def pids(vm: str) -> list[int]:
    assert str(uuid.UUID(vm)) == vm
    group = Path(f"/sys/fs/cgroup/lilly.slice/lilly-vm-{vm}.service")
    assert group.is_dir()
    found: set[int] = set()
    for file in group.rglob("cgroup.procs"):
        found.update(int(value) for value in file.read_text().split())
    return sorted(found)


def start_time(process: Path) -> int:
    # Field 22 follows the potentially space-containing parenthesized comm.
    return int((process / "stat").read_text().rsplit(") ", 1)[1].split()[19])


def snapshot(vm: str) -> list[ProcessRow]:
    """Full identity, including the executable inode; needs root for the jailed VMM."""
    rows: list[ProcessRow] = []
    for pid in pids(vm):
        process = Path(f"/proc/{pid}")
        # procfs exposes a magic link: its text is relative to the process's
        # mount namespace (the jailed VMM reports /firecracker). Follow it in
        # the kernel for identity, without resolving that text in the host root.
        executable = (process / "exe").readlink().name
        identity = (process / "exe").stat()
        start = start_time(process)
        rows.append(
            ProcessRow(
                pid=pid,
                start=start,
                executable=executable,
                device=identity.st_dev,
                inode=identity.st_ino,
            )
        )
    assert any("firecracker" in row["executable"] for row in rows)
    return rows


def survival(vm: str) -> list[SurvivalRow]:
    """Host PIDs and kernel start times only, readable without privilege.

    An unprivileged caller (the probe BEAM runs as `lilly` with no capabilities)
    cannot read the jailed VMM's /proc/<pid>/exe; the root driver checks the
    executable identity with snapshot().
    """
    rows: list[SurvivalRow] = []
    for pid in pids(vm):
        process = Path(f"/proc/{pid}")
        command = (process / "comm").read_text().strip()
        rows.append(SurvivalRow(pid=pid, start=start_time(process), command=command))
    assert any("firecracker" in row["command"] for row in rows)
    return rows


if __name__ == "__main__":
    if sys.argv[1:2] == ["--survival"]:
        print(json.dumps(survival(sys.argv[2])))
    else:
        print(json.dumps(snapshot(sys.argv[1])))
