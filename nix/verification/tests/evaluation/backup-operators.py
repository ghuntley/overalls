"""Generated operator histories through the real CLI runtime and local encrypted Restic.

No systemd, S3, ZFS, PostgreSQL or production recovery authority is exercised here.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from collections.abc import Generator, Sequence
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from hypothesis import example, given, settings
from hypothesis import strategies as st

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
from schema import (  # ty: ignore[unresolved-import] # argv[1] Nix backups module
    JSON,
    Config,
    json_value,
    object_value,
    string,
    strings,
)

MODULES = Path(sys.argv.pop(1)).resolve()
RESTIC = Path(sys.argv.pop(1)).resolve()
SEED = 26001


def rows(value: object) -> list[dict[str, JSON]]:
    if not isinstance(value, list):
        raise AssertionError("expected JSON array")
    return [object_value(item) for item in value]


def inventory(root: Path) -> dict[str, tuple[int, str]]:
    """Inventory names, kinds, modes and file bytes without following symlinks."""
    if not root.exists():
        return {}
    result: dict[str, tuple[int, str]] = {}
    for path in [root, *sorted(root.rglob("*"))]:
        mode = path.lstat().st_mode
        content = (
            os.readlink(path)
            if stat.S_ISLNK(mode)
            else hashlib.sha256(path.read_bytes()).hexdigest()
            if stat.S_ISREG(mode)
            else ""
        )
        result[str(path.relative_to(root))] = (mode, content)
    return result


@dataclass(frozen=True)
class Point:
    identity: str
    references: frozenset[str]


class Fixture:
    """@cc [owner:ghuntley,label:verification] backup-operator-fixture-boundary
    Every command MUST use an explicit disposable repository, password, cache,
    state and restore target. Expected reference graphs and inventories MUST be
    derived from fixture inputs, never Repository.manifest or Repository.retain.
    """

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.repository = self.root / "repository"
        self.source = self.root / "source"
        self.source.mkdir(mode=0o700)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.password = self.root / "password"
        self.password.write_text("disposable-backup-operator-fixture\n")
        self.password.chmod(0o600)
        self.config = Config(
            hostname="fixture",
            repository=str(self.repository),
            region="test",
            password_file=str(self.password),
            cache_directory=str(self.root / "cache"),
            state_directory=str(self.state),
            revision="operator-property-fixture",
            restic=str(RESTIC),
            zfs="/unavailable-fixture-zfs",
            findmnt="/unavailable-fixture-findmnt",
            mount="/unavailable-fixture-mount",
            umount="/unavailable-fixture-umount",
            command_timeout=30,
            upload_limit_kib=0,
            keep_last=2,
            initialize=False,
            paths=[],
            materialize=[],
            images=[],
            protected_datasets=[],
            excludes=[],
            lilly=None,
            postgres=None,
        )
        self.descriptor = self.root / "config.json"
        self.tracked_shims: list[int] = []
        # Deliberately exclude ambient AWS, database, service and Restic settings.
        self.environment = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.root),
            "PYTHONDONTWRITEBYTECODE": "1",
            "RESTIC_REPOSITORY": str(self.repository),
            "RESTIC_PASSWORD_FILE": str(self.password),
            "RESTIC_CACHE_DIR": str(self.root / "cache"),
            "LC_ALL": "C",
            "TZ": "UTC",
        }
        self.direct(["init"])
        (self.state / "owner.lock").touch(mode=0o600)
        (self.state / "status.json").write_text(
            json.dumps(
                {"version": 1, "state": "healthy", "failure": "none", "last_success_at": 321}
            )
        )
        (self.state / "status.json").chmod(0o600)

    def invoke(
        self, arguments: Sequence[str], timeout: float
    ) -> subprocess.CompletedProcess[bytes]:
        """Drain the entire fixture process group before restoring or removing files."""
        with subprocess.Popen(
            arguments,
            env=self.environment,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        ) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
                return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
            finally:
                # common.run starts Restic in its own session. Record its exact
                # child group before signaling runtime.py, whose SIGTERM handler
                # interrupts common.run and reaps that reader in its finally block.
                groups = {process.pid}
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children")
                with suppress(FileNotFoundError, ProcessLookupError):
                    for child in children.read_text().split():
                        child_id = int(child)
                        if os.getpgid(child_id) == child_id:
                            groups.add(child_id)
                if process.poll() is None:
                    with suppress(ProcessLookupError):
                        process.send_signal(signal.SIGTERM)
                    with suppress(subprocess.TimeoutExpired):
                        process.communicate(timeout=8)
                # Escalation also targets the recorded reader session, even if
                # the runtime did not execute its normal signal cleanup.
                for group in groups:
                    with suppress(ProcessLookupError):
                        os.killpg(group, signal.SIGKILL)
                process.communicate(timeout=5)

    def direct(self, arguments: Sequence[str]) -> bytes:
        result = self.invoke([str(RESTIC), *arguments], timeout=60)
        if result.returncode != 0:
            raise AssertionError(f"fixture Restic {arguments[0]} failed: {result.returncode}")
        return result.stdout

    def cli(
        self, operation: str, *arguments: str, timeout: float = 90
    ) -> subprocess.CompletedProcess[bytes]:
        self.descriptor.write_text(json.dumps(self.config))
        return self.invoke(
            [
                sys.executable,
                str(MODULES / "runtime.py"),
                str(self.descriptor),
                operation,
                *arguments,
            ],
            timeout=timeout,
        )

    def capture(self, name: str, body: bytes, stamp: datetime, *, manifest: bool = False) -> str:
        path = self.source / name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(body)
        result = self.direct(
            [
                "backup",
                "--json",
                "--host",
                "fixture",
                "--tag",
                "overalls-backup",
                "--tag",
                "host-manifest" if manifest else "host-state",
                "--time",
                stamp.strftime("%Y-%m-%d %H:%M:%S"),
                "--",
                str(path),
            ]
        )
        summary = object_value(json.loads(result.splitlines()[-1]))
        identity = string(summary["snapshot_id"])
        matches = [item for item in self.ids() if item.startswith(identity)]
        if len(matches) != 1:
            raise AssertionError("fixture snapshot identity was not unique")
        return matches[0]

    def ids(self) -> set[str]:
        return {string(row["id"]) for row in rows(json.loads(self.direct(["snapshots", "--json"])))}

    def manifest(self, components: list[dict[str, JSON]], serial: int = 1) -> dict[str, JSON]:
        return {
            "version": 1,
            "hostname": "fixture",
            "run_id": str(uuid.UUID(int=serial)),
            "started_at": serial,
            "completed_at": serial + 1,
            "revision": self.config["revision"],
            "complete": True,
            "components": json_value(components),
        }

    def point(self, manifest: dict[str, JSON], stamp: datetime, name: str = "manifest.json") -> str:
        return self.capture(name, json.dumps(manifest).encode(), stamp, manifest=True)

    def target(self, name: str) -> Path:
        return self.root / ("restore-" + name)

    def restic_shim(self, rules: list[dict[str, JSON]]) -> None:
        """Route repository operations through a Restic-intercepting shim.

        Each rule fires when every listed token appears in the shim's argv.
        "block" records its pid in marker and sleeps; "delegate_then_block" runs
        the real Restic first (upload completes), then blocks before returning;
        "swap_then_delegate" rewrites the private password file and delegates;
        "mark_then_delegate" records its pid in marker and delegates.
        Unmatched invocations delegate transparently.
        """
        helper = self.root / "shim-restic"
        helper.write_text(
            "#!"
            + sys.executable
            + "\n"
            + "import json, os, subprocess, sys, time\n"
            + "from pathlib import Path\n"
            + "REAL = "
            + repr(str(RESTIC))
            + "\n"
            + "RULES = json.loads("
            + repr(json.dumps(rules))
            + ")\n"
            + "arguments = sys.argv[1:]\n"
            + "for rule in RULES:\n"
            + '    if all(token in arguments for token in rule["tokens"]):\n'
            + '        if rule["action"] == "delegate_then_block":\n'
            + "            completed = subprocess.run([REAL, *arguments])\n"
            + '            Path(rule["marker"]).write_text(str(os.getpid()))\n'
            + "            time.sleep(3600)\n"
            + "            sys.exit(completed.returncode)\n"
            + '        if rule["action"] == "mark_then_delegate":\n'
            + '            Path(rule["marker"]).write_text(str(os.getpid()))\n'
            + "            sys.exit(subprocess.run([REAL, *arguments]).returncode)\n"
            + '        if rule["action"] == "swap_then_delegate":\n'
            + '            Path(rule["password_file"]).write_text(rule["password"])\n'
            + '            Path(rule["marker"]).write_text(str(os.getpid()))\n'
            + "            sys.exit(subprocess.run([REAL, *arguments]).returncode)\n"
            + '        Path(rule["marker"]).write_text(str(os.getpid()))\n'
            + "        time.sleep(3600)\n"
            + "sys.exit(subprocess.run([REAL, *arguments]).returncode)\n"
        )
        helper.chmod(0o700)
        self.config["restic"] = str(helper)

    def launch(self, operation: str, arguments: Sequence[str]) -> subprocess.Popen[bytes]:
        """Start a runtime operation whose shim will block; caller signals later."""
        self.descriptor.write_text(json.dumps(self.config))
        return subprocess.Popen(
            [
                sys.executable,
                str(MODULES / "runtime.py"),
                str(self.descriptor),
                operation,
                *arguments,
            ],
            env=self.environment,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )

    def interrupt(
        self,
        operation: str,
        arguments: Sequence[str],
        marker: Path,
        signum: int,
        timeout: float = 120,
    ) -> subprocess.CompletedProcess[bytes]:
        """Run an operation and signal it exactly once the shim marker appears.

        The marker means the runtime is blocked inside the selected Restic
        invocation. Records the live reader session, signals the runtime, then
        drains and force-kills every recorded process group.
        """
        process = self.launch(operation, arguments)
        with process:
            if not wait_for_marker(process, marker):
                raise AssertionError(
                    f"{operation} finished before interruption: {process.returncode}"
                )
            self.tracked_shims.append(int(marker.read_text()))
            groups = {process.pid, *self.tracked_shims}
            with suppress(ProcessLookupError):
                process.send_signal(signum)
            try:
                stdout, stderr = process.communicate(timeout=30)
            finally:
                if process.poll() is None:
                    with suppress(ProcessLookupError):
                        process.send_signal(signal.SIGKILL)
                    with suppress(subprocess.TimeoutExpired):
                        process.communicate(timeout=8)
                for group in groups:
                    with suppress(ProcessLookupError):
                        os.killpg(group, signal.SIGKILL)
                process.communicate(timeout=5)
            return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def recover_killed(self) -> tuple[dict[str, JSON], dict[str, JSON]]:
        """Reconcile after an uncatchable kill and return (status, journal).

        Runs the cleanup operation twice: recovery marks the interrupted run
        failed exactly once, and a retry MUST NOT rewrite the terminal journal.
        Restores the direct Restic binary for subsequent fixture commands.
        """
        result = self.cli("cleanup", timeout=120)
        if result.returncode != 0 or result.stdout != b"":
            raise AssertionError(f"cleanup reconcile failed: {result.returncode}")
        status = object_value(json.loads((self.state / "status.json").read_bytes()))
        journal = object_value(json.loads((self.state / "run.json").read_bytes()))
        retry = self.cli("cleanup", timeout=120)
        if retry.returncode != 0 or retry.stdout != b"":
            raise AssertionError("retried cleanup reconcile failed")
        replayed = object_value(json.loads((self.state / "run.json").read_bytes()))
        if replayed != journal:
            raise AssertionError("cleanup retry rewrote the terminal journal")
        self.config["restic"] = str(RESTIC)
        return status, journal

    def manifest_journal(self) -> dict[str, JSON]:
        return object_value(json.loads((self.state / "run.json").read_bytes()))

    def shim_lives(self) -> bool:
        """False once all recorded reader sessions are reaped or zombies."""
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if not any(live(identity) for identity in self.tracked_shims):
                return False
            time.sleep(0.01)
        return any(live(identity) for identity in self.tracked_shims)


def live(identity: int) -> bool:
    """A reaped-by-init zombie is acceptable; a live reader session is not."""
    with suppress(FileNotFoundError):
        observed = (Path("/proc") / str(identity) / "stat").read_text()
        return observed.rsplit(") ", 1)[1].split()[0] != "Z"
    return False


def wait_for_marker(process: subprocess.Popen[bytes], marker: Path, timeout: float = 120) -> bool:
    """Wait for the shim marker pid; returns False only when the runtime died first."""
    deadline = time.monotonic() + timeout
    shim: int | None = None
    while shim is None:
        if process.poll() is not None:
            return False
        if time.monotonic() > deadline:
            raise AssertionError(f"runtime never reached {marker.name}")
        # write_text publishes the path before its content; require both.
        with suppress(FileNotFoundError, ValueError):
            shim = int(marker.read_text())
        if shim is None:
            time.sleep(0.01)
    # Record the live reader session before signaling; invoke() drains it.
    with suppress(FileNotFoundError):
        children = Path(f"/proc/{process.pid}/task/{process.pid}/children")
        for child in children.read_text().split():
            identity = int(child)
            with suppress(ProcessLookupError):
                if os.getpgid(identity) == identity and identity != shim:
                    raise AssertionError("runtime has an unexpected child session")
    return True


@contextmanager
def fixture() -> Generator[Fixture]:
    with tempfile.TemporaryDirectory(prefix="overalls-backup-operators-") as temporary:
        root = Path(temporary)
        # Assert cleanup even when a property or a subprocess fails.
        try:
            yield Fixture(root)
        finally:
            shutil.rmtree(root)
            if root.exists():
                raise AssertionError("operator fixture survived cleanup")


class OperatorHistories(unittest.TestCase):
    def succeeded(self, result: subprocess.CompletedProcess[bytes]) -> bytes:
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    def refused(self, result: subprocess.CompletedProcess[bytes], code: int = 1) -> None:
        self.assertEqual(result.returncode, code)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"Traceback", result.stderr)

    def test_fixture_cleanup_after_assertion_and_command_failure(self) -> None:
        with tempfile.TemporaryDirectory(prefix="backup-unrelated-") as unrelated:
            sentinel = Path(unrelated) / "preserve"
            sentinel.write_bytes(b"unrelated-operator-data")
            before = inventory(Path(unrelated))
            for failure in ("assertion", "command"):
                with self.subTest(failure=failure):
                    captured_root: Path | None = None
                    expected = (
                        "intentional fixture cleanup probe"
                        if failure == "assertion"
                        else "fixture Restic intentional-invalid-command failed"
                    )
                    with self.assertRaisesRegex(AssertionError, expected), fixture() as f:
                        captured_root = f.root
                        now = datetime.now(UTC)
                        host = f.capture("host.bin", b"cleanup-probe", now)
                        point = f.point(
                            f.manifest([{"kind": "host-state", "snapshot_id": host}]), now
                        )
                        self.succeeded(
                            f.cli(
                                "restore",
                                "--snapshot",
                                point,
                                "--target",
                                str(f.target("cleanup")),
                            )
                        )
                        if failure == "command":
                            f.direct(["intentional-invalid-command"])
                        raise AssertionError("intentional fixture cleanup probe")
                    self.assertIsNotNone(captured_root)
                    assert captured_root is not None
                    self.assertFalse(captured_root.exists())
                    self.assertEqual(inventory(Path(unrelated)), before)

    def test_cli_timeout_drains_the_runtime_restic_session(self) -> None:
        with fixture() as f:
            helper = f.root / "blocked-restic"
            receipt = f.root / "reader-pids.json"
            helper.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, subprocess, sys, time\n"
                "from pathlib import Path\n"
                "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\n"
                "Path("
                + repr(str(receipt))
                + ").write_text(json.dumps([os.getpid(), child.pid]))\n"
                "time.sleep(120)\n"
            )
            helper.chmod(0o700)
            f.config["restic"] = str(helper)
            before = inventory(f.repository), inventory(f.source)
            with self.assertRaises(subprocess.TimeoutExpired):
                f.cli("check", timeout=3)
            reader_ids: object = json.loads(receipt.read_bytes())
            self.assertIsInstance(reader_ids, list)
            assert isinstance(reader_ids, list)
            self.assertEqual(len(reader_ids), 2)
            for reader_id in reader_ids:
                self.assertIs(type(reader_id), int)
                assert isinstance(reader_id, int)

                # An orphan can briefly remain a reaped-by-init zombie. It must
                # never remain a live reader after the invocation returns.
                def live(identity: int) -> bool:
                    with suppress(FileNotFoundError):
                        observed = (Path("/proc") / str(identity) / "stat").read_text()
                        return observed.rsplit(") ", 1)[1].split()[0] != "Z"
                    return False

                deadline = time.monotonic() + 3
                while live(reader_id) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(live(reader_id))
            self.assertEqual((inventory(f.repository), inventory(f.source)), before)
            status = object_value(json.loads((f.state / "status.json").read_bytes()))
            self.assertEqual(status["last_success_at"], 321)
            self.assertEqual(status["failure"], "interrupted")

    def test_generated_complete_reference_graphs_and_expired_missing_reference(self) -> None:
        randomizer = random.Random(SEED)
        now = datetime.now(UTC)
        for history in range(8):
            with self.subTest(history=history), fixture() as f:
                f.config["keep_last"] = randomizer.randint(1, 3)
                host = f.capture("host.bin", b"host", now - timedelta(days=3))
                guests = [
                    f.capture(f"guest-{index}.bin", bytes([index]), now - timedelta(days=3))
                    for index in range(3)
                ]
                old = f.capture("old-orphan.bin", b"old", now - timedelta(days=3))
                recent = f.capture("recent-orphan.bin", b"recent", now)
                points: list[Point] = []
                for serial in range(1, f.config["keep_last"] + 3):
                    refs = randomizer.sample(guests, randomizer.randint(0, len(guests)))
                    components: list[dict[str, JSON]] = [
                        {"kind": "host-state", "snapshot_id": host}
                    ]
                    components.extend(
                        {"kind": "guest", "snapshot_id": identity} for identity in refs
                    )
                    # An expired point may reference already absent components;
                    # only retained points require complete reference existence.
                    if serial == 1:
                        components.append({"kind": "guest", "snapshot_id": "f" * 64})
                    manifest = f.manifest(components, serial)
                    identity = f.point(manifest, now - timedelta(hours=12 - serial))
                    points.append(Point(identity, frozenset([host, *refs])))
                    self.assertEqual(
                        object_value(
                            json.loads(self.succeeded(f.cli("inspect", "--snapshot", identity)))
                        ),
                        manifest,
                    )
                listed = rows(json.loads(self.succeeded(f.cli("list"))))
                self.assertEqual(
                    {row["id"] for row in listed}, {point.identity for point in points}
                )
                source_before = inventory(f.source)
                protected = {recent}
                for point in points[-f.config["keep_last"] :]:
                    protected.add(point.identity)
                    protected.update(point.references)
                self.succeeded(f.cli("prune"))
                self.assertEqual(f.ids(), protected)
                self.assertNotIn(old, f.ids())
                self.assertEqual(inventory(f.source), source_before)
                after = inventory(f.repository)
                self.succeeded(f.cli("prune"))
                self.assertEqual(inventory(f.repository), after)
                self.assertEqual(f.ids(), protected)

    def test_enumerated_malformed_complete_manifests_refuse_without_repository_or_target_changes(
        self,
    ) -> None:
        randomizer = random.Random(SEED + 1)
        cases = [
            "version",
            "hostname",
            "complete",
            "run_id",
            "negative_time",
            "reversed_time",
            "boolean_time",
            "revision",
            "empty",
            "missing_host",
            "duplicate_host",
            "duplicate_postgres",
            "unknown_kind",
            "snapshot_id",
            "missing_field",
            "extra_field",
            "nonobject",
            "truncated",
            "wrong_path",
        ]
        randomizer.shuffle(cases)
        now = datetime.now(UTC)
        for serial, case in enumerate(cases, 1):
            with self.subTest(case=case), fixture() as f:
                host = f.capture("host.bin", b"preserved-host", now - timedelta(days=3))
                good = f.point(f.manifest([{"kind": "host-state", "snapshot_id": host}]), now)
                value = f.manifest([{"kind": "host-state", "snapshot_id": host}], serial + 1)
                if case in {"version", "hostname", "complete", "run_id", "revision"}:
                    value[case] = {
                        "version": True,
                        "hostname": "foreign",
                        "complete": False,
                        "run_id": "invalid",
                        "revision": [],
                    }[case]
                elif case == "negative_time":
                    value["started_at"] = -1
                elif case == "reversed_time":
                    value["completed_at"] = 0
                elif case == "boolean_time":
                    value["started_at"] = True
                elif case == "empty":
                    value["components"] = []
                elif case == "missing_host":
                    value["components"] = [{"kind": "guest", "snapshot_id": host}]
                elif case in {
                    "duplicate_host",
                    "duplicate_postgres",
                    "unknown_kind",
                    "snapshot_id",
                }:
                    components = [{"kind": "host-state", "snapshot_id": host}]
                    if case == "duplicate_host":
                        components *= 2
                    elif case == "duplicate_postgres":
                        components.extend([{"kind": "postgres", "snapshot_id": host}] * 2)
                    elif case == "unknown_kind":
                        components.append({"kind": "unknown", "snapshot_id": host})
                    else:
                        components[0]["snapshot_id"] = "short"
                    value["components"] = json_value(components)
                elif case == "missing_field":
                    del value["revision"]
                elif case == "extra_field":
                    value["unexpected"] = True
                body = (
                    b"[]"
                    if case == "nonobject"
                    else b"{"
                    if case == "truncated"
                    else json.dumps(value).encode()
                )
                identity = f.capture(
                    "wrong.json" if case == "wrong_path" else "manifest.json",
                    body,
                    now + timedelta(seconds=serial),
                    manifest=True,
                )
                repository_before = inventory(f.repository)
                source_before = inventory(f.source)
                target = f.target("refused")
                # Listing reports candidates; inspect validates their contents.
                self.assertEqual(
                    {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))},
                    {good, identity},
                )
                self.refused(f.cli("inspect", "--snapshot", identity))
                self.refused(f.cli("restore", "--snapshot", identity, "--target", str(target)))
                self.refused(f.cli("prune"))
                self.assertEqual(inventory(f.repository), repository_before)
                self.assertEqual(inventory(f.source), source_before)
                self.assertFalse(target.exists())
                status = object_value(json.loads((f.state / "status.json").read_bytes()))
                self.assertEqual(status["last_success_at"], 321)
                self.assertEqual(status["state"], "failed")

    def test_generated_partial_restore_refusal_and_explicit_fresh_target_retry(self) -> None:
        randomizer = random.Random(SEED + 2)
        now = datetime.now(UTC)
        for history in range(6):
            with self.subTest(history=history), fixture() as f:
                payloads = {"host-state": b"host", "postgres": b"archive", "guest": b"guest"}
                entries = list(payloads.items())
                randomizer.shuffle(entries)
                components: list[dict[str, JSON]] = []
                identities: list[str] = []
                for kind, body in entries:
                    identity = f.capture(kind + ".bin", body, now)
                    identities.append(identity)
                    components.append({"kind": kind, "snapshot_id": identity})
                manifest = f.manifest(components)
                point = f.point(manifest, now)
                missing_index = randomizer.randint(1, 2)
                snapshot_file = f.repository / "snapshots" / identities[missing_index]
                encrypted_snapshot = snapshot_file.read_bytes()
                f.direct(["forget", identities[missing_index]])
                repository_before = inventory(f.repository)
                source_before = inventory(f.source)
                target = f.target("partial")
                self.refused(f.cli("prune"))
                self.assertEqual(inventory(f.repository), repository_before)
                self.refused(f.cli("restore", "--snapshot", point, "--target", str(target)))
                self.assertFalse((target / "manifest.json").exists())
                for index in range(missing_index):
                    kind, body = entries[index]
                    self.assertEqual(
                        (target / str(index) / str(f.source / (kind + ".bin"))[1:]).read_bytes(),
                        body,
                    )
                partial = inventory(target)
                self.assertTrue(partial)
                self.refused(f.cli("restore", "--snapshot", point, "--target", str(target)))
                self.assertEqual(inventory(target), partial)
                self.assertEqual(inventory(f.repository), repository_before)
                # Fixture-only repair restores the exact original encrypted snapshot
                # descriptor. No live source or service authority is restored.
                snapshot_file.write_bytes(encrypted_snapshot)
                repaired_repository = inventory(f.repository)
                fresh = f.target("fresh")
                self.succeeded(f.cli("restore", "--snapshot", point, "--target", str(fresh)))
                self.assertEqual(
                    object_value(json.loads((fresh / "manifest.json").read_bytes())), manifest
                )
                for index, (kind, body) in enumerate(entries):
                    self.assertEqual(
                        (fresh / str(index) / str(f.source / (kind + ".bin"))[1:]).read_bytes(),
                        body,
                    )
                self.assertEqual(inventory(target), partial)
                self.assertEqual(inventory(f.source), source_before)
                self.assertEqual(inventory(f.repository), repaired_repository)
                self.assertEqual(stat.S_IMODE(fresh.stat().st_mode), 0o700)

    def test_generated_credential_custody_refusal_symmetry(self) -> None:
        """Corrupt password custody or absent S3 keys close every repository operation.

        Capture was the historical gate: backup already refuses through ensure().
        Operator and scheduled operations MUST refuse identically, with a closed
        credentials failure, before touching repository content or restore output.
        """
        randomizer = random.Random(SEED + 4)
        now = datetime.now(UTC)

        def corrupt(f: Fixture, case: str) -> None:
            original = f.password.read_bytes()
            if case == "group_readable":
                f.password.chmod(0o640)
            elif case == "world_readable":
                f.password.chmod(0o644)
            elif case == "symlinked":
                real = f.root / "password-real"
                real.write_bytes(original)
                real.chmod(0o600)
                f.password.unlink()
                f.password.symlink_to(real)
            elif case == "multi_linked":
                os.link(f.password, f.root / "password-alias")
            elif case == "empty":
                f.password.write_bytes(b"")
            elif case == "whitespace":
                f.password.write_bytes(b"\n \n")
            elif case == "oversized":
                f.password.write_bytes(b"x" * 16385)
            elif case == "missing":
                f.password.unlink()

        cases = [
            "group_readable",
            "world_readable",
            "symlinked",
            "multi_linked",
            "empty",
            "whitespace",
            "oversized",
            "missing",
        ]
        randomizer.shuffle(cases)
        for case in cases:
            with self.subTest(case=case), fixture() as f:
                host = f.capture("host.bin", b"custody-probe", now)
                point = f.point(f.manifest([{"kind": "host-state", "snapshot_id": host}]), now)
                self.succeeded(f.cli("list"))
                repository_before = inventory(f.repository)
                source_before = inventory(f.source)
                corrupt(f, case)
                status_bytes = (f.state / "status.json").read_bytes()
                # init must not materialize a fresh repository without valid custody.
                fresh_repository = f.root / "fresh-repository"
                probes: list[tuple[str, list[str]]] = [
                    ("list", []),
                    ("inspect", ["--snapshot", point]),
                    (
                        "restore",
                        ["--snapshot", point, "--target", str(f.target("custody"))],
                    ),
                    ("init", []),
                    ("prune", []),
                    ("check", []),
                    ("read-check", []),
                ]
                for operation, arguments in probes:
                    with self.subTest(case=case, operation=operation):
                        if operation == "init":
                            f.config["repository"] = str(fresh_repository)
                        result = f.cli(operation, *arguments, timeout=120)
                        self.refused(result)
                        self.assertEqual(inventory(f.repository), repository_before)
                        self.assertEqual(inventory(f.source), source_before)
                        self.assertFalse(f.target("custody").exists())
                        self.assertFalse(fresh_repository.exists())
                        status = object_value(json.loads((f.state / "status.json").read_bytes()))
                        if operation in {"list", "inspect", "restore", "init"}:
                            self.assertEqual((f.state / "status.json").read_bytes(), status_bytes)
                        else:
                            self.assertEqual(status["state"], "failed")
                            self.assertEqual(status["failure"], "credentials")
                            self.assertEqual(status["last_success_at"], 321)
                # Capture was the pre-existing custody gate: identical refusal, with
                # a terminal interrupted-free failed journal and retained success.
                self.refused(f.cli("backup", timeout=120))
                status = object_value(json.loads((f.state / "status.json").read_bytes()))
                self.assertEqual(status["state"], "failed")
                self.assertEqual(status["failure"], "credentials")
                self.assertEqual(status["last_success_at"], 321)
                journal = object_value(json.loads((f.state / "run.json").read_bytes()))
                self.assertEqual(journal["phase"], "failed")
                self.assertEqual(journal["failures"], ["credentials"])
                self.assertEqual(inventory(f.repository), repository_before)
                self.assertEqual(inventory(f.source), source_before)

        with self.subTest(case="missing_s3_keys"), fixture() as f:
            f.config["repository"] = "s3:https://127.0.0.1:1/unreachable-fixture"
            repository_before = inventory(f.repository)
            status_bytes = (f.state / "status.json").read_bytes()
            for operation, arguments in [
                ("list", []),
                ("inspect", ["--snapshot", "a" * 64]),
                ("prune", []),
                ("check", []),
            ]:
                with self.subTest(operation=operation):
                    # The closed credentials refusal MUST precede any network use:
                    # the same operation against the unreachable repository with
                    # valid custody instead reports a generic repository failure.
                    self.refused(f.cli(operation, *arguments, timeout=120))
                    status = object_value(json.loads((f.state / "status.json").read_bytes()))
                    if operation in {"list", "inspect"}:
                        self.assertEqual((f.state / "status.json").read_bytes(), status_bytes)
                    else:
                        self.assertEqual(status["failure"], "credentials")
                    self.assertEqual(inventory(f.repository), repository_before)
            f.password.write_text("valid-custody-fixture\n")
            f.password.chmod(0o600)
            # Valid custody with S3 keys present reaches the repository: the
            # unreachable endpoint becomes a generic repository failure instead.
            f.environment["AWS_ACCESS_KEY_ID"] = "fixture-access"
            f.environment["AWS_SECRET_ACCESS_KEY"] = "fixture-secret-password"
            self.refused(f.cli("check", timeout=120))
            status = object_value(json.loads((f.state / "status.json").read_bytes()))
            self.assertEqual(status["failure"], "repository")

    def test_generated_restore_component_interruption_preserves_partial_verified_output(
        self,
    ) -> None:
        """Kill/timeout at each generated component index keeps verified prefixes.

        SIGTERM, SIGKILL and a real command timeout while Restic restores a
        selected component MUST abort publication: earlier components stay
        verify-byte-exact for inspection, no manifest.json is written, status is
        untouched, and a fresh-target retry recovers every original byte.
        """
        randomizer = random.Random(SEED + 5)
        now = datetime.now(UTC)
        modes = [
            (signal.SIGTERM, "sigterm", 1),
            (signal.SIGKILL, "sigkill", -signal.SIGKILL),
            (None, "timeout", 1),
        ]
        for history, (signum, mode, code) in enumerate(modes):
            with self.subTest(mode=mode), fixture() as f:
                total = randomizer.randint(2, 4)
                components: list[dict[str, JSON]] = []
                bodies: list[bytes] = []
                for index in range(total - 1):
                    body = randomizer.randbytes(64 + 16 * index)
                    bodies.append(body)
                    components.append(
                        {
                            "kind": "host-state" if index == 0 else "guest",
                            "snapshot_id": f.capture(f"data-{index}.bin", body, now),
                        }
                    )
                # The final component carries the generated interruption index.
                bodies.append(b"blocked-component")
                components.append(
                    {
                        "kind": "guest" if total > 2 else "postgres",
                        "snapshot_id": f.capture(f"data-{total - 1}.bin", bodies[-1], now),
                    }
                )
                point = f.point(f.manifest(components, 30 + history), now)
                interrupted_index = randomizer.randint(0, total - 1)
                target = f.target("interrupt")
                marker = f.root / f"interrupt-{mode}.mark"
                repository_before = inventory(f.repository)
                source_before = inventory(f.source)
                status_bytes = (f.state / "status.json").read_bytes()
                f.restic_shim(
                    [
                        {
                            "action": "block",
                            "tokens": ["restore", "--target", str(target / str(interrupted_index))],
                            "marker": str(marker),
                        }
                    ]
                )
                if signum is None:
                    f.config["command_timeout"] = 2
                    result = f.cli(
                        "restore", "--snapshot", point, "--target", str(target), timeout=120
                    )
                    self.assertTrue(marker.exists())
                    f.tracked_shims.append(int(marker.read_text()))
                    self.refused(result, code)
                else:
                    result = f.interrupt(
                        "restore",
                        ["--snapshot", point, "--target", str(target)],
                        marker,
                        signum,
                    )
                    self.refused(result, code)
                # Interruption awaits the bounded reader drain: no live shim.
                self.assertFalse(f.shim_lives())
                self.assertFalse((target / "manifest.json").exists())
                for index in range(interrupted_index):
                    self.assertEqual(
                        (
                            target / str(index) / str(f.source / f"data-{index}.bin")[1:]
                        ).read_bytes(),
                        bodies[index],
                    )
                if interrupted_index:
                    self.assertTrue(
                        inventory(target),
                        "verified partial output MUST remain inspectable",
                    )
                self.assertEqual(inventory(f.repository), repository_before)
                self.assertEqual(inventory(f.source), source_before)
                if signum is not None:
                    self.assertEqual((f.state / "status.json").read_bytes(), status_bytes)
                f.config["restic"] = str(RESTIC)
                f.config["command_timeout"] = 30
                fresh = f.target("recovered")
                self.succeeded(
                    f.cli("restore", "--snapshot", point, "--target", str(fresh), timeout=120)
                )
                for index in range(total):
                    self.assertEqual(
                        (fresh / str(index) / str(f.source / f"data-{index}.bin")[1:]).read_bytes(),
                        bodies[index],
                    )
                self.assertEqual(inventory(f.repository), repository_before)

    def test_kill_during_upload_marks_interrupted_and_retains_grace_orphan(self) -> None:
        """Killing the runtime during a real upload leaves an unreferenced orphan.

        SIGTERM lets the runtime write both the journal and status failure;
        SIGKILL leaves reconciliation to the next cleanup, which MUST mark the
        run failed(interrupted) exactly once, retryable. The uploaded component
        snapshot stays unreferenced by every manifest and survives retention
        inside its one-day grace; it is destroyed only after aging past it.
        """
        for signum, mode in [(signal.SIGTERM, "immediate"), (signal.SIGKILL, "recover")]:
            with self.subTest(mode=mode), fixture() as f:
                self.succeeded(f.cli("list"))
                # Block on the real host-state upload: the Restic child finishes
                # while the runtime still believes the upload is in flight.
                marker = f.root / f"upload-{mode}.mark"
                f.restic_shim(
                    [
                        {
                            "action": "delegate_then_block",
                            "tokens": ["backup", "--tag", "host-state"],
                            "marker": str(marker),
                        }
                    ]
                )
                interrupted = f.interrupt("backup", [], marker, signum)
                self.assertFalse(f.shim_lives())
                journal = object_value(json.loads((f.state / "run.json").read_bytes()))
                run_tag = "run:" + string(journal["run_id"])
                status = object_value(json.loads((f.state / "status.json").read_bytes()))
                if mode == "immediate":
                    self.refused(interrupted)
                    self.assertEqual(status["state"], "failed")
                    self.assertEqual(status["failure"], "interrupted")
                    self.assertEqual(journal["phase"], "failed")
                    f.config["restic"] = str(RESTIC)
                else:
                    self.assertEqual(interrupted.returncode, -signal.SIGKILL)
                    self.assertEqual(journal["phase"], "capturing")
                    self.assertEqual(status["state"], "running")
                    status, journal = f.recover_killed()
                self.assertEqual(journal["failures"], ["interrupted"])
                self.assertEqual(journal["phase"], "failed")
                self.assertEqual(journal["components"], [])
                self.assertEqual(status["last_success_at"], 321)
                # The interrupted upload created a genuinely unreferenced orphan.
                remaining = rows(
                    json.loads(f.direct(["snapshots", "--tag", "host-state", "--json"]))
                )
                orphans = [
                    string(row["id"])
                    for row in remaining
                    if run_tag in strings(row.get("tags", []))
                ]
                self.assertEqual(len(orphans), 1)
                orphan = orphans[0]
                self.assertNotIn(
                    orphan, {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                )
                # Grace: retention MUST NOT forget a fresh orphan; a second prune
                # is stable; only age beyond one day releases it (generated
                # retention histories cover the aged-out branch).
                self.succeeded(f.cli("prune", timeout=120))
                self.assertIn(orphan, f.ids())
                after = inventory(f.repository)
                self.succeeded(f.cli("prune", timeout=120))
                self.assertEqual(inventory(f.repository), after)
                self.assertIn(orphan, f.ids())
                # A fresh run replaces the failed journal and publishes again.
                self.succeeded(f.cli("backup", timeout=180))
                status = object_value(json.loads((f.state / "status.json").read_bytes()))
                self.assertEqual(status["state"], "healthy")
                self.assertEqual(
                    object_value(json.loads((f.state / "run.json").read_bytes()))["phase"],
                    "completed",
                )
                self.assertIn(orphan, f.ids())

    def test_backward_clock_step_publishes_a_retention_valid_point(self) -> None:
        """A wall clock stepped backward mid-capture still publishes a valid point.

        Antithesis run 6993853fa020fd46ed8e13c6c123ac86-65-0 published a
        manifest whose completed_at preceded started_at; retention and inspect
        then refused the newly published point.
        """
        with fixture() as f:
            marker = f.root / "clock-step.mark"
            hooks = f.root / "clock-hooks"
            hooks.mkdir(mode=0o700)
            # The runtime reads time.time after the host-state upload; once the
            # shim records that upload, every later reading is 120 s earlier.
            (hooks / "sitecustomize.py").write_text(
                "import os, time\n"
                + "_real = time.time\n"
                + "def _stepped() -> float:\n"
                + "    stepped = os.path.exists("
                + repr(str(marker))
                + ")\n"
                + "    return _real() - (120 if stepped else 0)\n"
                + "time.time = _stepped\n"
            )
            f.environment["PYTHONPATH"] = str(hooks)
            f.restic_shim(
                [
                    {
                        "action": "mark_then_delegate",
                        "tokens": ["backup", "--tag", "host-state"],
                        "marker": str(marker),
                    }
                ]
            )
            self.succeeded(f.cli("backup", timeout=180))
            self.assertTrue(marker.exists())
            journal = f.manifest_journal()
            self.assertEqual(journal["phase"], "completed")
            listed = rows(json.loads(self.succeeded(f.cli("list"))))
            self.assertEqual(len(listed), 1)
            manifest = object_value(
                json.loads(self.succeeded(f.cli("inspect", "--snapshot", string(listed[0]["id"]))))
            )
            started, completed = manifest["started_at"], manifest["completed_at"]
            assert isinstance(started, int) and isinstance(completed, int)
            self.assertLessEqual(started, completed)
            self.succeeded(f.cli("prune", timeout=120))

    def test_publication_window_interruption_pins_valid_point_with_failed_journal(
        self,
    ) -> None:
        """Kill between manifest upload and completion: point stays, run fails.

        The host-manifest snapshot becomes tag-visible only after its upload
        finishes, but before the journal records the manifest identity or the
        completed transition. Pin the accepted semantics: the published point
        remains listable, inspectable, restorable and retention-counted, while
        the local journal honestly records the run as failed(interrupted).
        """
        for signum, mode in [(signal.SIGKILL, "recover"), (signal.SIGTERM, "immediate")]:
            with self.subTest(mode=mode), fixture() as f:
                self.succeeded(f.cli("backup", timeout=180))
                status = object_value(json.loads((f.state / "status.json").read_bytes()))
                self.assertEqual(status["state"], "healthy")
                preserved_success = status["last_success_at"]
                identities = f.ids()
                recorded = {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                self.assertEqual(len(recorded), 1)
                first = next(iter(recorded))
                marker = f.root / f"publication-{mode}.mark"
                f.restic_shim(
                    [
                        {
                            "action": "delegate_then_block",
                            "tokens": ["backup", "--tag", "host-manifest"],
                            "marker": str(marker),
                        }
                    ]
                )
                previous_run = string(f.manifest_journal()["run_id"])
                interrupted = f.interrupt("backup", [], marker, signum)
                self.assertFalse(f.shim_lives())
                # The killed run uploaded its journaled host-state component
                # before the window, then the manifest snapshot itself.
                self.assertEqual(len(f.ids()), len(identities) + 2)
                journal = f.manifest_journal()
                self.assertNotEqual(string(journal["run_id"]), previous_run)
                listed = {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                self.assertIn(first, listed)
                unrecorded = listed - {first}
                self.assertEqual(len(unrecorded), 1)
                publisher = string(next(iter(unrecorded)))
                self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", publisher))
                # The tag-visible point is complete: inspect validates it and a
                # restore returns byte-exact content plus the final manifest.
                manifest = object_value(
                    json.loads(self.succeeded(f.cli("inspect", "--snapshot", publisher)))
                )
                components = manifest["components"]
                self.assertIsInstance(components, list)
                assert isinstance(components, list)
                self.assertEqual(
                    [object_value(item)["kind"] for item in components], ["host-state"]
                )
                target = f.target("published")
                self.succeeded(
                    f.cli("restore", "--snapshot", publisher, "--target", str(target), timeout=120)
                )
                self.assertEqual(
                    object_value(json.loads((target / "manifest.json").read_bytes())),
                    manifest,
                )
                found = list(target.rglob("paths.json"))
                self.assertEqual(len(found), 1)
                object_value(json.loads(found[0].read_bytes()))
                if mode == "immediate":
                    # The runtime's own signal handler reconciled the window.
                    self.refused(interrupted)
                    self.assertEqual(journal["phase"], "failed")
                    self.assertEqual(journal["failures"], ["interrupted"])
                    self.assertIsNone(journal["manifest_id"])
                    status = object_value(json.loads((f.state / "status.json").read_bytes()))
                    self.assertEqual(status["state"], "failed")
                    self.assertEqual(status["failure"], "interrupted")
                    f.config["restic"] = str(RESTIC)
                else:
                    # An uncatchable kill leaves the publishing journal for the
                    # next cleanup reconciliation.
                    self.assertEqual(interrupted.returncode, -signal.SIGKILL)
                    self.assertEqual(journal["phase"], "publishing")
                    self.assertEqual(journal["failures"], [])
                    self.assertIsNone(journal["manifest_id"])
                    self.assertTrue(journal["cleanup_confirmed"])
                    status, journal = f.recover_killed()
                    self.assertEqual(journal["phase"], "failed")
                    self.assertEqual(journal["failures"], ["interrupted"])
                    self.assertEqual(status["state"], "failed")
                    self.assertEqual(status["failure"], "interrupted")
                self.assertEqual(status["last_success_at"], preserved_success)
                # Retention counts the published-but-unrecorded point exactly
                # like a recorded one: within keep_last=2 it survives prune; a
                # following complete point displaces the oldest recorded point.
                self.succeeded(f.cli("prune", timeout=120))
                self.assertEqual(
                    {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))},
                    {first, publisher},
                )
                self.succeeded(f.cli("backup", timeout=180))
                # The run's own retention already counts every published point:
                # with keep_last=2 the oldest recorded point expires while the
                # published-but-unrecorded point survives beside the newest one.
                points = {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                self.assertEqual(len(points), 2)
                self.assertIn(publisher, points)
                self.assertNotIn(first, points)
                self.assertNotIn(first, f.ids())
                self.succeeded(f.cli("prune", timeout=120))
                retained = {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                self.assertEqual(retained, points)
                after = inventory(f.repository)
                self.succeeded(f.cli("prune", timeout=120))
                self.assertEqual(inventory(f.repository), after)
                done = f.target("published-recheck")
                self.succeeded(
                    f.cli("restore", "--snapshot", publisher, "--target", str(done), timeout=120)
                )
                self.assertEqual(
                    object_value(json.loads((done / "manifest.json").read_bytes())),
                    manifest,
                )

    @settings(max_examples=4, deadline=None, derandomize=True)
    @example(killed=True, keep=1, body=b"", repeats=1)
    @example(killed=False, keep=3, body=b"published\x00payload", repeats=3)
    @given(
        killed=st.booleans(),
        keep=st.sampled_from([1, 2, 3]),
        body=st.binary(min_size=0, max_size=256),
        repeats=st.sampled_from([1, 2, 3]),
    )
    def test_publication_interruption_history(
        self, killed: bool, keep: int, body: bytes, repeats: int
    ) -> None:
        """@cc [owner:ghuntley,label:verification;recovery] uploaded-publication-history
        A fully uploaded manifest MUST remain listable and restore exact captured
        bytes after runtime interruption before its journal receipt. Cleanup MUST
        preserve the failed terminal journal and prior last-success timestamp.
        Retention MUST count the published point and retain all its references
        until the configured number of newer complete points displaces it.
        """
        with fixture() as f:
            f.config["keep_last"] = keep
            payload = f.source / "payload.bin"
            payload.write_bytes(body)
            f.config["materialize"] = [str(payload)]
            self.succeeded(f.cli("backup", timeout=180))
            previous = object_value(json.loads((f.state / "status.json").read_bytes()))
            previous_run = string(f.manifest_journal()["run_id"])
            payload.write_bytes(body + b"\x00new")
            marker = f.root / "publication-history.mark"
            f.restic_shim(
                [
                    {
                        "action": "delegate_then_block",
                        "tokens": ["backup", "--tag", "host-manifest"],
                        "marker": str(marker),
                    }
                ]
            )
            result = f.interrupt("backup", [], marker, signal.SIGKILL if killed else signal.SIGTERM)
            self.assertFalse(f.shim_lives())
            if killed:
                self.assertEqual(result.returncode, -signal.SIGKILL)
                self.assertEqual(f.manifest_journal()["phase"], "publishing")
                status, journal = f.recover_killed()
            else:
                self.refused(result)
                f.config["restic"] = str(RESTIC)
                status = object_value(json.loads((f.state / "status.json").read_bytes()))
                journal = f.manifest_journal()
            self.assertEqual(journal["phase"], "failed")
            self.assertEqual(journal["failures"], ["interrupted"])
            self.assertIsNone(journal["manifest_id"])
            self.assertEqual(status["last_success_at"], previous["last_success_at"])
            run_id = string(journal["run_id"])
            self.assertNotEqual(run_id, previous_run)
            published = [
                row
                for row in rows(
                    json.loads(f.direct(["snapshots", "--tag", "host-manifest", "--json"]))
                )
                if "run:" + run_id in strings(row.get("tags", []))
            ]
            self.assertEqual(len(published), 1)
            point = string(published[0]["id"])
            manifest = object_value(
                json.loads(self.succeeded(f.cli("inspect", "--snapshot", point)))
            )
            self.assertEqual(manifest["run_id"], run_id)
            components = rows(manifest["components"])
            references = {string(row["snapshot_id"]) for row in components}
            self.assertEqual([row["kind"] for row in components], ["host-state"])
            terminal_bytes = (f.state / "run.json").read_bytes()
            for index in range(repeats):
                self.succeeded(f.cli("cleanup"))
                self.assertEqual((f.state / "run.json").read_bytes(), terminal_bytes)
                self.succeeded(f.cli("prune", timeout=120))
                self.assertIn(
                    point, {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                )
                self.assertTrue(references <= f.ids())
                target = f.target(f"publication-replay-{index}")
                self.succeeded(
                    f.cli("restore", "--snapshot", point, "--target", str(target), timeout=120)
                )
                captured = list(target.rglob("configuration/0"))
                self.assertEqual(len(captured), 1)
                self.assertEqual(captured[0].read_bytes(), body + b"\x00new")
                self.assertEqual(
                    object_value(json.loads((target / "manifest.json").read_bytes())), manifest
                )
            for index in range(keep):
                payload.write_bytes(body + f"replacement-{index}".encode())
                self.succeeded(f.cli("backup", timeout=180))
                listed = {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}
                self.assertEqual(point in listed, index < keep - 1)
                if index < keep - 1:
                    self.assertTrue(references <= f.ids())
            self.assertNotIn(point, f.ids())
            self.assertFalse(references & f.ids())

    def test_real_concurrent_prune_and_reads_during_blocked_restore(self) -> None:
        """A live blocked restore holds owner.lock; other real CLI processes fuse.

        Operator list/inspect/restore/init keep the 75 refusal; scheduled prune,
        check and reads skip with zero. Nobody publishes status or mutates the
        repository while the lock is held by an actual concurrent process.
        """
        now = datetime.now(UTC)
        with fixture() as f:
            first = f.capture("first.bin", b"co-first", now)
            second = f.capture("second.bin", b"co-second", now)
            point = f.point(
                f.manifest(
                    [
                        {"kind": "host-state", "snapshot_id": first},
                        {"kind": "postgres", "snapshot_id": second},
                    ]
                ),
                now,
            )
            # Ordinary successful work leaves stable private state to compare.
            self.succeeded(f.cli("list"))
            target = f.target("concurrent")
            marker = f.root / "concurrent-block.mark"
            repository_before = inventory(f.repository)
            source_before = inventory(f.source)
            status_bytes = (f.state / "status.json").read_bytes()
            f.restic_shim(
                [
                    {
                        "action": "block",
                        "tokens": ["restore", "--target", str(target / "1")],
                        "marker": str(marker),
                    }
                ]
            )
            process = f.launch("restore", ["--snapshot", point, "--target", str(target)])
            with process:
                self.assertTrue(wait_for_marker(process, marker))
                # Concurrent scheduled operations skip with zero while operator
                # reads refuse with 75; both complete while restore still runs.
                for skipped in ("prune", "check", "read-check", "cleanup"):
                    with self.subTest(skipped=skipped):
                        result = f.cli(skipped, timeout=60)
                        self.assertEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, b"")
                self.refused(f.cli("list", timeout=60), 75)
                self.refused(f.cli("inspect", "--snapshot", point, timeout=60), 75)
                self.refused(
                    f.cli(
                        "restore",
                        "--snapshot",
                        point,
                        "--target",
                        str(f.target("second-restore")),
                        timeout=60,
                    ),
                    75,
                )
                self.assertIsNone(process.poll())
                self.assertEqual(inventory(f.repository), repository_before)
                self.assertEqual(inventory(f.source), source_before)
                self.assertEqual((f.state / "status.json").read_bytes(), status_bytes)
                shim = int(marker.read_text())
                f.tracked_shims.append(shim)
                process.kill()
                process.communicate(timeout=30)
                with suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                with suppress(ProcessLookupError):
                    os.killpg(shim, signal.SIGKILL)
                self.assertEqual(process.returncode, -signal.SIGKILL)
            self.assertFalse(f.shim_lives())
            # The interrupted restore publishes nothing and leaves its partial
            # verified component for operator inspection.
            self.assertFalse((target / "manifest.json").exists())
            self.assertEqual(
                (target / "0" / str(f.source / "first.bin")[1:]).read_bytes(), b"co-first"
            )
            status = object_value(json.loads((f.state / "status.json").read_bytes()))
            self.assertEqual(status["state"], "healthy")
            self.assertEqual(status["last_success_at"], 321)
            self.assertEqual(inventory(f.repository), repository_before)
            # After the lock releases, scheduled retention resumes normally.
            f.config["restic"] = str(RESTIC)
            self.succeeded(f.cli("prune", timeout=120))
            self.succeeded(f.cli("check", timeout=120))
            self.assertEqual(
                {row["id"] for row in rows(json.loads(self.succeeded(f.cli("list"))))}, {point}
            )
            self.assertFalse(f.shim_lives())
            self.assertEqual(inventory(f.source), source_before)

    def test_generated_mid_restore_credential_swap_fails_closed(self) -> None:
        """A password swap mid-restore fails remaining components generically.

        The swap happens while component custody files remain structurally
        private: the runtime reads RESTIC_PASSWORD_FILE per component, so the
        next component fails closed as repository, partial verified output is
        retained, no manifest is written, and a fresh target with restored
        custody retries byte-exact.
        """
        randomizer = random.Random(SEED + 6)
        now = datetime.now(UTC)
        for history in range(4):
            with self.subTest(history=history), fixture() as f:
                kinds = ["host-state", "postgres", "guest"]
                bodies = {kind: bytes([history]) + kind.encode() * (history + 2) for kind in kinds}
                randomizer.shuffle(kinds)
                components: list[dict[str, JSON]] = []
                identities = []
                for kind in kinds:
                    identity = f.capture(kind + ".bin", bodies[kind], now)
                    identities.append(identity)
                    components.append({"kind": kind, "snapshot_id": identity})
                point = f.point(f.manifest(components, 50 + history), now)
                self.succeeded(f.cli("list"))
                target = f.target("swap")
                marker = f.root / "swap.mark"
                repository_before = inventory(f.repository)
                source_before = inventory(f.source)
                status_bytes = (f.state / "status.json").read_bytes()
                # The runtime re-reads the password file at component 1: swap in a
                # well-formed private but wrong password right at that boundary.
                f.restic_shim(
                    [
                        {
                            "action": "swap_then_delegate",
                            "tokens": ["restore", "--target", str(target / "1")],
                            "marker": str(marker),
                            "password_file": str(f.password),
                            "password": "swapped-credential-fixture\n",
                        }
                    ]
                )
                result = f.cli("restore", "--snapshot", point, "--target", str(target), timeout=120)
                self.refused(result)
                self.assertTrue(marker.exists())
                self.assertFalse((target / "manifest.json").exists())
                self.assertFalse((target / "2").exists())
                self.assertEqual(
                    (target / "0" / str(f.source / (kinds[0] + ".bin"))[1:]).read_bytes(),
                    bodies[kinds[0]],
                )
                self.assertEqual(inventory(f.repository), repository_before)
                self.assertEqual(inventory(f.source), source_before)
                self.assertEqual((f.state / "status.json").read_bytes(), status_bytes)
                # An identical retry with the same stale credential refuses
                # without touching the retained partial output.
                partial = inventory(target)
                self.refused(
                    f.cli("restore", "--snapshot", point, "--target", str(target), timeout=120)
                )
                self.assertEqual(inventory(target), partial)
                # Restore custody and retry into a fresh empty target: byte-exact.
                f.password.write_text("disposable-backup-operator-fixture\n")
                f.password.chmod(0o600)
                f.config["restic"] = str(RESTIC)
                fresh = f.target("swap-fresh")
                self.succeeded(
                    f.cli("restore", "--snapshot", point, "--target", str(fresh), timeout=120)
                )
                self.assertEqual(
                    object_value(json.loads((fresh / "manifest.json").read_bytes())),
                    object_value(json.loads(self.succeeded(f.cli("inspect", "--snapshot", point)))),
                )
                for index, kind in enumerate(kinds):
                    self.assertEqual(
                        (fresh / str(index) / str(f.source / (kind + ".bin"))[1:]).read_bytes(),
                        bodies[kind],
                    )
                self.assertEqual(inventory(f.repository), repository_before)
                self.assertEqual(inventory(f.source), source_before)

    def test_generated_lock_and_target_refusals_preserve_existing_data(self) -> None:
        randomizer = random.Random(SEED + 3)
        with fixture() as f:
            now = datetime.now(UTC)
            host = f.capture("host.bin", b"existing-data", now)
            point = f.point(f.manifest([{"kind": "host-state", "snapshot_id": host}]), now)
            target = f.target("lock")
            # Establish ordinary local state before comparing lock refusals.
            # Runner initializes its private host-snapshots directory before
            # lock acquisition; that housekeeping is not repository mutation.
            self.succeeded(f.cli("list"))
            operations = [
                "list",
                "inspect",
                "restore",
                "init",
                "prune",
                "check",
                "read-check",
                "backup",
                "cleanup",
            ]
            for history in range(4):
                with self.subTest(history=history), (f.state / "owner.lock").open("r+b") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    before = inventory(f.repository), inventory(f.source), inventory(f.state)
                    randomizer.shuffle(operations)
                    for operation in operations:
                        result = f.cli(operation, "--snapshot", point, "--target", str(target))
                        if operation in {"list", "inspect", "restore", "init"}:
                            self.refused(result, 75)
                        else:
                            self.succeeded(result)
                        self.assertEqual(
                            (inventory(f.repository), inventory(f.source), inventory(f.state)),
                            before,
                        )
                        self.assertFalse(target.exists())
            self.succeeded(f.cli("inspect", "--snapshot", point))
            self.succeeded(f.cli("restore", "--snapshot", point, "--target", str(target)))
            occupied = f.target("occupied")
            occupied.mkdir(mode=0o700)
            (occupied / "operator-data").write_bytes(b"do-not-overwrite")
            alias = f.target("symlink")
            alias.symlink_to(occupied, target_is_directory=True)
            exposed = f.target("public")
            exposed.mkdir(mode=0o755)
            exposed.chmod(0o755)
            targets = [
                str(occupied),
                str(alias),
                str(alias / "child"),
                str(exposed),
                "relative",
                str(f.root / "nested" / ".." / "escape"),
            ]
            randomizer.shuffle(targets)
            before = (
                inventory(f.repository),
                inventory(f.source),
                inventory(occupied),
                inventory(exposed),
            )
            for refused_target in targets:
                self.refused(f.cli("restore", "--snapshot", point, "--target", refused_target))
                self.assertEqual(
                    (
                        inventory(f.repository),
                        inventory(f.source),
                        inventory(occupied),
                        inventory(exposed),
                    ),
                    before,
                )
            self.assertTrue(alias.is_symlink())
            self.assertFalse((f.root / "relative").exists())
            self.assertFalse((f.root / "nested").exists())
            self.assertFalse((f.root / "escape").exists())
            for identity in ["short", "g" * 64, "f" * 64]:
                self.refused(f.cli("inspect", "--snapshot", identity))
            self.assertEqual(inventory(f.repository), before[0])


if __name__ == "__main__":
    unittest.main()
