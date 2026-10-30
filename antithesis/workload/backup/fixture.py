"""Private repository fixture using the installed production backup operator."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from collections.abc import Generator, Sequence
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

MODULES = Path("/opt/overalls/backup-modules")
RESTIC = Path("/opt/overalls/restic/bin/restic")
GATE = Path(__file__).with_name("helper_restic_gate.py")
# STUB (harness): libfaketime and its spec-rewriting Restic wrapper step only a
# workload-selected coordinator's wall clock; see ``backward_clock_step``.
FAKETIME = Path("/opt/overalls/libfaketime/lib/libfaketimeMT.so.1")
CLOCK_STEP = Path(__file__).with_name("helper_clock_step.py")
CLOCK_STEP_SECONDS = 120


@dataclass(frozen=True)
class Component:
    kind: str
    snapshot_id: str
    source: Path
    sha256: str


@dataclass(frozen=True)
class Result:
    code: int
    output: bytes


class BackupFixture:
    """@cc [owner:ghuntley,label:verification] backup-real-repository-oracle
    Workload expectations come from independently captured source hashes and raw
    Restic IDs. The production operator is used for prune/inspect/restore and
    coordinator publication, never as the source of expected bytes or references.
    """

    def __init__(self, root: Path, keep_last: int = 2) -> None:
        if keep_last not in (1, 2, 3, 12):
            raise ValueError("unsupported retention menu")
        self.root = root.resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.repository = self.root / "repository"
        self.source = self.root / "source"
        self.source.mkdir(mode=0o700)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.password = self.root / "password"
        self.password.write_text(uuid.uuid4().hex + "\n", encoding="ascii")
        self.password.chmod(0o600)
        self.cache = self.root / "cache"
        self.config_file = self.root / "config.json"
        self.config: dict[str, object] = {
            "hostname": "antithesis-backup",
            "repository": str(self.repository),
            "region": "fixture",
            "password_file": str(self.password),
            "cache_directory": str(self.cache),
            "state_directory": str(self.state),
            "revision": "antithesis-fixture",
            "restic": str(RESTIC),
            "zfs": "/unavailable-fixture-zfs",
            "findmnt": "/unavailable-fixture-findmnt",
            "mount": "/unavailable-fixture-mount",
            "umount": "/unavailable-fixture-umount",
            "command_timeout": 30,
            "upload_limit_kib": 0,
            "keep_last": keep_last,
            "initialize": False,
            "paths": [],
            "materialize": [],
            "images": [],
            "protected_datasets": [],
            "excludes": [],
            "lilly": None,
            "postgres": None,
        }
        self.environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.root),
            "RESTIC_REPOSITORY": str(self.repository),
            "RESTIC_PASSWORD_FILE": str(self.password),
            "RESTIC_CACHE_DIR": str(self.cache),
            "LC_ALL": "C",
            "TZ": "UTC",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        initialized = self.raw("init")
        if initialized.code != 0:
            raise RuntimeError("disposable Restic initialization failed")

    def _run(self, command: Sequence[str], timeout: float = 90) -> Result:
        with subprocess.Popen(
            list(command),
            env=self.environment,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        ) as process:
            try:
                output, _ = process.communicate(timeout=timeout)
                return Result(process.returncode, output)
            except subprocess.TimeoutExpired:
                groups = {process.pid}
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children")
                with suppress(FileNotFoundError, ProcessLookupError):
                    for child in children.read_text(encoding="ascii").split():
                        identity = int(child)
                        if os.getpgid(identity) == identity:
                            groups.add(identity)
                with suppress(ProcessLookupError):
                    process.send_signal(signal.SIGTERM)
                with suppress(subprocess.TimeoutExpired):
                    process.communicate(timeout=8)
                for group in groups:
                    with suppress(ProcessLookupError):
                        os.killpg(group, signal.SIGKILL)
                output, _ = process.communicate(timeout=8)
                return Result(124, output)

    def raw(self, *arguments: str) -> Result:
        return self._run([str(RESTIC), *arguments])

    def operator(self, operation: str, *arguments: str, timeout: float = 90) -> Result:
        if operation not in ("backup", "cleanup", "prune", "list", "inspect", "restore"):
            raise ValueError("unsupported backup operation")
        self.config_file.write_text(json.dumps(self.config), encoding="utf-8")
        return self._run(
            [
                sys.executable,
                str(MODULES / "runtime.py"),
                str(self.config_file),
                operation,
                *arguments,
            ],
            timeout=timeout,
        )

    def operator_process(self, operation: str, *arguments: str) -> subprocess.Popen[bytes]:
        if operation not in ("backup", "restore"):
            raise ValueError("unsupported interrupt operation")
        self.config_file.write_text(json.dumps(self.config), encoding="utf-8")
        return subprocess.Popen(
            [
                sys.executable,
                str(MODULES / "runtime.py"),
                str(self.config_file),
                operation,
                *arguments,
            ],
            env=self.environment,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def snapshots(self) -> list[dict[str, object]]:
        result = self.raw(
            "snapshots", "--json", "--host", "antithesis-backup", "--tag", "overalls-backup"
        )
        if result.code != 0:
            raise RuntimeError("raw Restic enumeration unavailable")
        parsed: object = json.loads(result.output)
        if not isinstance(parsed, list):
            raise ValueError("invalid Restic snapshot inventory")
        rows: list[dict[str, object]] = []
        for value in parsed:
            if not isinstance(value, dict) or not isinstance(value.get("id"), str):
                raise ValueError("invalid Restic snapshot row")
            rows.append(value)
        return rows

    def ids(self) -> set[str]:
        return {str(row["id"]) for row in self.snapshots()}

    def manifests(self) -> list[dict[str, object]]:
        result: list[dict[str, object]] = []
        for row in self.snapshots():
            tags = row.get("tags")
            if isinstance(tags, list) and "host-manifest" in tags:
                result.append(row)
        return result

    def capture(self, name: str, body: bytes, kind: str) -> Component:
        if kind not in ("host-state", "guest", "postgres") or "/" in name:
            raise ValueError("unsupported component")
        source = self.source / name
        source.write_bytes(body)
        result = self.raw(
            "backup",
            "--json",
            "--host",
            "antithesis-backup",
            "--tag",
            "overalls-backup",
            "--tag",
            kind,
            "--",
            str(source),
        )
        if result.code != 0:
            raise RuntimeError("Restic component upload failed")
        summary: object = json.loads(result.output.splitlines()[-1])
        if not isinstance(summary, dict) or not isinstance(summary.get("snapshot_id"), str):
            raise ValueError("missing Restic snapshot receipt")
        prefix = summary["snapshot_id"]
        matches = [identity for identity in self.ids() if identity.startswith(prefix)]
        if len(matches) != 1:
            raise ValueError("ambiguous Restic snapshot receipt")
        return Component(kind, matches[0], source, hashlib.sha256(body).hexdigest())

    def publish(self, components: Sequence[Component], serial: int) -> str:
        if not components or not any(component.kind == "host-state" for component in components):
            raise ValueError("complete manifest requires host-state")
        manifest: dict[str, object] = {
            "version": 1,
            "hostname": "antithesis-backup",
            "run_id": str(uuid.UUID(int=serial)),
            "started_at": serial,
            "completed_at": serial + 1,
            "revision": "antithesis-fixture",
            "complete": True,
            "components": [
                {"kind": item.kind, "snapshot_id": item.snapshot_id} for item in components
            ],
        }
        source = self.source / "manifest.json"
        source.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.raw(
            "backup",
            "--json",
            "--host",
            "antithesis-backup",
            "--tag",
            "overalls-backup",
            "--tag",
            "host-manifest",
            "--time",
            (datetime.now(UTC) - timedelta(minutes=10) + timedelta(seconds=serial)).strftime(
                "%Y-%m-%d %H:%M:%S"
            ),
            "--",
            str(source),
        )
        if result.code != 0:
            raise RuntimeError("Restic manifest upload failed")
        summary: object = json.loads(result.output.splitlines()[-1])
        if not isinstance(summary, dict) or not isinstance(summary.get("snapshot_id"), str):
            raise ValueError("missing Restic manifest receipt")
        matches = [
            str(row["id"])
            for row in self.manifests()
            if str(row["id"]).startswith(summary["snapshot_id"])
        ]
        if len(matches) != 1:
            raise ValueError("ambiguous Restic manifest receipt")
        return matches[0]

    def dump_manifest(self, row: dict[str, object]) -> dict[str, object]:
        identity = row.get("id")
        paths = row.get("paths")
        if (
            not isinstance(identity, str)
            or not isinstance(paths, list)
            or len(paths) != 1
            or not isinstance(paths[0], str)
        ):
            raise ValueError("invalid raw manifest row")
        result = self.raw("dump", identity, paths[0])
        if result.code != 0:
            raise RuntimeError("raw manifest dump unavailable")
        value: object = json.loads(result.output)
        if not isinstance(value, dict):
            raise ValueError("invalid raw manifest")
        return value

    def restored_hash(self, component: Component, target: Path) -> str | None:
        result = self.raw(
            "restore", component.snapshot_id, "--sparse", "--verify", "--target", str(target)
        )
        if result.code != 0:
            return None
        restored = target / component.source.relative_to("/")
        if not restored.is_file():
            return None
        return hashlib.sha256(restored.read_bytes()).hexdigest()

    def gate(
        self, verb: str, marker: Path, target: Path | None = None, *, after: bool = False
    ) -> None:
        if verb not in ("restore", "backup"):
            raise ValueError("unsupported gate verb")
        wrapper = self.root / "gate-restic.py"
        shutil.copyfile(GATE, wrapper)
        wrapper.chmod(0o700)
        (self.root / "gate.json").write_text(
            json.dumps(
                {
                    "real": str(RESTIC),
                    "verb": verb,
                    "marker": str(marker),
                    "target": str(target) if target is not None else "",
                    "after": after,
                }
            ),
            encoding="utf-8",
        )
        self.config["restic"] = str(wrapper)

    def ungate(self) -> None:
        self.config["restic"] = str(RESTIC)

    @contextmanager
    def backward_clock_step(self) -> Generator[None]:
        """@cc [owner:ghuntley,label:verification] backup-backward-clock-step-stub
        STUB (harness): operator runs inside this context preload libfaketime
        with a spec file that starts at real time. The Restic wrapper rewrites
        it to a fixed backward offset when the coordinator begins its
        host-state upload, after its journal recorded ``started_at``. Only the
        coordinator process is faked; Restic, raw oracle reads and production
        modules are unchanged, and the environment and Restic path are
        restored on exit. This is not evidence of real host clock steps.
        """
        if not FAKETIME.is_file():
            raise RuntimeError("harness libfaketime closure absent")
        spec = self.root / "faketime.spec"
        spec.write_text("+0\n", encoding="ascii")
        wrapper = self.root / "clock-step-restic.py"
        shutil.copyfile(CLOCK_STEP, wrapper)
        wrapper.chmod(0o700)
        (self.root / "clock-step.json").write_text(
            json.dumps(
                {"real": str(RESTIC), "spec": str(spec), "offset": f"-{CLOCK_STEP_SECONDS}"}
            ),
            encoding="utf-8",
        )
        saved = dict(self.environment)
        self.environment.update(
            LD_PRELOAD=str(FAKETIME),
            FAKETIME_TIMESTAMP_FILE=str(spec),
            FAKETIME_NO_CACHE="1",
            FAKETIME_DONT_FAKE_MONOTONIC="1",
        )
        self.config["restic"] = str(wrapper)
        try:
            yield
        finally:
            self.environment = saved
            self.ungate()

    def interrupt_at_gate(self, operation: str, marker: Path, *arguments: str) -> Result | None:
        process = self.operator_process(operation, *arguments)
        try:
            deadline = time.monotonic() + 90
            while not marker.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    return None
                time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                output, _ = process.communicate(timeout=10)
            return Result(process.returncode, output)
        finally:
            if process.poll() is None:
                groups = {process.pid}
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children")
                with suppress(FileNotFoundError, ProcessLookupError):
                    for child in children.read_text(encoding="ascii").split():
                        identity = int(child)
                        if os.getpgid(identity) == identity:
                            groups.add(identity)
                with suppress(ProcessLookupError):
                    process.send_signal(signal.SIGTERM)
                with suppress(subprocess.TimeoutExpired):
                    process.communicate(timeout=8)
                for group in groups:
                    with suppress(ProcessLookupError):
                        os.killpg(group, signal.SIGKILL)
                process.communicate(timeout=8)
            self.ungate()


def fixture_root() -> Path | None:
    """@cc [owner:ghuntley,label:verification;security] backup-fixture-volume
    A selected backup profile MAY place disposable repositories under the
    private Restic fixture volume named by ``ANTITHESIS_BACKUP_ROOT``. The root
    MUST be an absolute, non-symlink, root- or self-owned directory without group
    or other write access; anything else refuses the fixture rather than
    falling back to another location. Unset selects the process temporary root.
    """
    raw = os.environ.get("ANTITHESIS_BACKUP_ROOT")
    if raw is None:
        return None
    root = Path(raw)
    if not root.is_absolute() or ".." in root.parts or root.is_symlink():
        raise RuntimeError("Restic fixture root is not a canonical private directory")
    observed = root.lstat()
    if (
        not stat.S_ISDIR(observed.st_mode)
        or observed.st_uid not in (0, os.geteuid())
        or observed.st_mode & 0o022
    ):
        raise RuntimeError("Restic fixture root is not a canonical private directory")
    return root


@contextmanager
def fixture(keep_last: int = 2) -> Generator[BackupFixture]:
    if not MODULES.joinpath("runtime.py").is_file() or not RESTIC.is_file():
        raise RuntimeError("production backup modules or Restic closure absent")
    with tempfile.TemporaryDirectory(
        prefix="overalls-antithesis-backup-", dir=fixture_root()
    ) as temporary:
        yield BackupFixture(Path(temporary), keep_last)
