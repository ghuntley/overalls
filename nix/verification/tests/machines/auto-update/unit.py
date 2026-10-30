"""Focused compatibility tests; machine tests separately establish activation behavior."""

import base64
import contextlib
import importlib.util
import io
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("updater", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("updater helper unavailable")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class Compatibility(unittest.TestCase):
    def setUp(self) -> None:
        self.key = {"id": "old", "key": base64.b64encode(bytes(32)).decode()}
        self.other = {"id": "new", "key": base64.b64encode(bytes([1] * 32)).decode()}
        self.old = {
            "DATABASE_URL": "postgresql://test:fixture@db/fixture",
            "SECRET_KEY_BASE": "fixture-cookie",
            "TOKEN_SIGNING_SECRET": "fixture-token",
            "MARSHALL_CLOAK_KEYS": json.dumps([self.key]),
        }

    def test_independent_authority_cannot_change(self) -> None:
        self.assertTrue(updater.compatible(self.old, self.old))
        for field in updater.KEYS[:3]:
            self.assertFalse(updater.compatible(self.old, dict(self.old, **{field: "changed"})))

    def test_key_addition_preserves_active_key_and_all_decryption_keys(self) -> None:
        appended = dict(self.old, MARSHALL_CLOAK_KEYS=json.dumps([self.key, self.other]))
        self.assertTrue(updater.compatible(self.old, appended))
        for ring in [
            [self.other, self.key],
            [self.other],
            [self.key, self.key],
            [],
            [self.key, {"id": "broken", "key": "not-base64"}],
        ]:
            self.assertFalse(
                updater.compatible(appended, dict(self.old, MARSHALL_CLOAK_KEYS=json.dumps(ring)))
            )

    def test_missing_or_invalid_baseline_cannot_approve_itself(self) -> None:
        self.assertFalse(updater.compatible({}, self.old))
        self.assertFalse(updater.compatible(self.old, {}))
        self.assertFalse(updater.compatible(dict(self.old, MARSHALL_CLOAK_KEYS="null"), self.old))


class DependentStops(unittest.TestCase):
    def test_dependency_cascade_and_canceled_job_recheck(self) -> None:
        deployment = object.__new__(updater.Deployment)
        states = {"parent.service": "active", "child.service": "active", "peer.service": "active"}
        stopped: list[str] = []

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            unit = arguments[-1]
            if arguments[1] == "show":
                return states[unit]
            self.assertEqual(arguments[1], "stop")
            stopped.append(unit)
            states[unit] = "inactive"
            if unit == "parent.service":
                states["child.service"] = "inactive"
            if unit == "peer.service":
                raise updater.UpdateError("activate_failed")
            return ""

        with patch.object(deployment, "command", side_effect=command):
            deployment.stop_units(["parent.service", "child.service", "peer.service"])
        self.assertEqual(stopped, ["parent.service", "peer.service"])

    def test_canceled_job_cannot_leave_a_consumer_running(self) -> None:
        deployment = object.__new__(updater.Deployment)

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            if arguments[1] == "show":
                return "active"
            raise updater.UpdateError("activate_failed")

        with (
            patch.object(deployment, "command", side_effect=command),
            self.assertRaises(updater.UpdateError),
        ):
            deployment.stop_units(["running.service"])

    def test_canceled_job_retries_after_later_dependent_stops(self) -> None:
        deployment = object.__new__(updater.Deployment)
        states = {"secret.service": "active", "dependent.service": "active"}
        stopped: list[str] = []

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            unit = arguments[-1]
            if arguments[1] == "show":
                return states[unit]
            stopped.append(unit)
            if unit == "secret.service" and states["dependent.service"] == "active":
                raise updater.UpdateError("activate_failed")
            states[unit] = "inactive"
            return ""

        with (
            patch.object(deployment, "command", side_effect=command),
            patch.object(updater.time, "sleep", return_value=None),
        ):
            deployment.stop_units(["secret.service", "dependent.service"])
        self.assertEqual(stopped, ["secret.service", "dependent.service", "secret.service"])


class SecretStops(unittest.TestCase):
    def test_independent_secret_units_stop_in_one_transaction(self) -> None:
        deployment = object.__new__(updater.Deployment)
        states = {"a.service": "active", "b.service": "inactive", "c.service": "active"}
        stops: list[list[str]] = []

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            if arguments[1] == "show":
                return states[arguments[-1]]
            self.assertEqual(arguments[1], "stop")
            stops.append(arguments[2:])
            for unit in arguments[2:]:
                states[unit] = "inactive"
            return ""

        with patch.object(deployment, "command", side_effect=command):
            deployment.stop_units(["a.service", "b.service", "c.service"], together=True)
        self.assertEqual(stops, [["a.service", "c.service"]])

    def test_a_secret_unit_that_stays_active_still_fails(self) -> None:
        deployment = object.__new__(updater.Deployment)

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            return "active" if arguments[1] == "show" else ""

        with (
            patch.object(deployment, "command", side_effect=command),
            patch.object(updater.time, "sleep", return_value=None),
            self.assertRaises(updater.UpdateError),
        ):
            deployment.stop_units(["stuck.service"], together=True)

    def test_each_stop_phase_has_its_own_deadline(self) -> None:
        deployment = object.__new__(updater.Deployment)
        clock = iter(float(value) for value in range(0, 10_000, 40))

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            return "inactive"

        # Each clock read advances 40 s; a single 180 s deadline would expire
        # in the second phase, separate deadlines never do.
        with (
            patch.object(deployment, "command", side_effect=command),
            patch.object(updater.time, "monotonic", side_effect=lambda: next(clock)),
        ):
            deployment.stop_units(["one.service"])
            deployment.stop_units(["two.service"], together=True)


class IdenticalClosureSecrets(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.runtime = root / "runtime"
        self.live = root / "live"
        descriptor = root / "descriptor.json"
        descriptor.write_text(json.dumps({"destination": str(self.live)}))
        (self.runtime / "staging" / "marshall" / "files").mkdir(parents=True)
        self.live.mkdir()
        self.deployment = object.__new__(updater.Deployment)
        self.deployment.candidate = {"secrets": {"marshall": str(descriptor)}}
        self.staged = self.runtime / "staging" / "marshall" / "files"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def matches(self) -> bool:
        with patch.object(updater, "RUNTIME", self.runtime):
            return self.deployment.staged_matches_live()

    def test_identical_bundles_match(self) -> None:
        for directory in [self.staged, self.live]:
            (directory / "environment").write_bytes(b"A=1\n")
        self.assertTrue(self.matches())

    def test_changed_added_or_removed_files_do_not_match(self) -> None:
        (self.staged / "environment").write_bytes(b"A=2\n")
        (self.live / "environment").write_bytes(b"A=1\n")
        self.assertFalse(self.matches())
        (self.live / "environment").write_bytes(b"A=2\n")
        self.assertTrue(self.matches())
        (self.staged / "extra").write_bytes(b"x")
        self.assertFalse(self.matches())
        (self.staged / "extra").unlink()
        (self.live / "extra").write_bytes(b"x")
        self.assertFalse(self.matches())

    def test_missing_live_bundle_does_not_match(self) -> None:
        self.live.rmdir()
        self.assertFalse(self.matches())


class ChangedUnits(unittest.TestCase):
    """@cc [owner:ghuntley,label:verification;recovery] updater-restarts-only-changed-units-tested
    Activation MUST stop only units whose store identity, drop-ins or secret
    bundle changed, or that the candidate dropped; an unchanged running
    consumer, its socket and its secret preparation MUST receive no stop.
    """

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.store = self.root / "store"
        self.store.mkdir()

    def tearDown(self) -> None:
        self.directory.cleanup()

    def system(self, name: str, units: dict[str, str], drop_ins: dict[str, dict[str, str]]) -> Path:
        system = self.root / name
        base = system / "etc/systemd/system"
        base.mkdir(parents=True)
        for unit, identity in units.items():
            target = self.store / identity / unit
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(identity)
            (base / unit).symlink_to(target)
        for unit, entries in drop_ins.items():
            (base / (unit + ".d")).mkdir()
            for entry, identity in entries.items():
                target = self.store / identity / entry
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(identity)
                (base / (unit + ".d") / entry).symlink_to(target)
        return system

    def test_identity_follows_unit_files_and_drop_ins(self) -> None:
        active = self.system(
            "active",
            {"kept.service": "k1", "changed.service": "c1", "dropped.service": "d1"},
            {"kept.service": {"override.conf": "o1"}},
        )
        candidate = self.system(
            "candidate",
            {"kept.service": "k1", "changed.service": "c2", "added.service": "a1"},
            {"kept.service": {"override.conf": "o1"}},
        )
        deployment = object.__new__(updater.Deployment)
        with patch.object(updater, "ACTIVE", active):
            changed = deployment.changed_units(
                candidate,
                ["kept.service", "changed.service", "dropped.service", "added.service"],
            )
        self.assertEqual(changed, {"changed.service", "dropped.service", "added.service"})
        drop_in = self.system(
            "drop-in",
            {"kept.service": "k1"},
            {"kept.service": {"override.conf": "o2"}},
        )
        with patch.object(updater, "ACTIVE", active):
            self.assertEqual(deployment.changed_units(drop_in, ["kept.service"]), {"kept.service"})

    def test_restart_set_includes_stale_bundles_and_dropped_consumers(self) -> None:
        active = self.system("active", {"a.service": "1", "b.service": "1"}, {})
        candidate = self.system("candidate", {"a.service": "1", "b.service": "1"}, {})
        live = self.root / "live"
        live.mkdir()
        (live / "environment").write_bytes(b"A=1\n")
        descriptor = self.root / "descriptor.json"
        descriptor.write_text(json.dumps({"destination": str(live)}))
        staged = self.root / "runtime/staging/marshall/files"
        staged.mkdir(parents=True)
        (staged / "environment").write_bytes(b"A=1\n")
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "consumers": ["a.service"],
            "secrets": {"marshall": str(descriptor)},
            "bundleConsumers": {"marshall": ["a.service"]},
        }
        deployment.previous_consumers = ["a.service", "b.service"]
        with (
            patch.object(updater, "ACTIVE", active),
            patch.object(updater, "RUNTIME", self.root / "runtime"),
        ):
            self.assertEqual(
                deployment.units_to_restart(candidate, ["a.service", "b.service"]), {"b.service"}
            )
            (staged / "environment").write_bytes(b"A=2\n")
            self.assertEqual(
                deployment.units_to_restart(candidate, ["a.service", "b.service"]),
                {"a.service", "b.service", "overalls-secrets-marshall.service"},
            )
            # A changed preparation unit restarts its consumers even when the
            # bundle bytes are identical.
            (staged / "environment").write_bytes(b"A=1\n")
            changed_secret = self.system(
                "changed-secret",
                {"a.service": "1", "b.service": "1", "overalls-secrets-marshall.service": "s2"},
                {},
            )
            self.assertEqual(
                deployment.units_to_restart(
                    changed_secret, ["a.service", "b.service", "overalls-secrets-marshall.service"]
                ),
                {"a.service", "b.service", "overalls-secrets-marshall.service"},
            )

    def test_dependents_of_a_restarting_unit_restart_too(self) -> None:
        active = self.system("active", {"m.service": "1", "wg.service": "1", "x.service": "1"}, {})
        candidate = self.system(
            "candidate", {"m.service": "2", "wg.service": "1", "x.service": "1"}, {}
        )
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "consumers": ["m.service", "wg.service", "x.service"],
            "secrets": {},
            "consumerDependents": {"m.service": ["wg.service"], "wg.service": ["x.service"]},
        }
        deployment.previous_consumers = []
        with patch.object(updater, "ACTIVE", active):
            self.assertEqual(
                deployment.units_to_restart(candidate, ["m.service", "wg.service", "x.service"]),
                {"m.service", "wg.service", "x.service"},
            )

    def test_activation_leaves_unchanged_consumers_running(self) -> None:
        active = self.system(
            "active", {"kept.service": "k1", "changed.service": "c1", "kept.socket": "s1"}, {}
        )
        bundle = self.root / "bundle"
        bundle.mkdir()
        (bundle / "system").symlink_to(
            self.system(
                "candidate",
                {"kept.service": "k1", "changed.service": "c2", "kept.socket": "s1"},
                {},
            )
        )
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "consumers": ["kept.service", "changed.service"],
            "healthUnits": ["changed.service"],
            "secrets": {},
            "socketUnits": ["kept.socket"],
        }
        deployment.previous_consumers = []
        deployment.resources = None
        deployment.handoff = {}
        calls: list[list[str]] = []

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            calls.append(arguments)
            if arguments[1:3] == ["list-units", "--failed"]:
                return ""
            if arguments[:2] == ["systemctl", "show"]:
                unit = arguments[-1]
                stopped = any(call[:2] == ["systemctl", "stop"] and unit in call for call in calls)
                return "inactive" if stopped else "active"
            return ""

        with (
            patch.object(updater, "shared_memory_ready", return_value=True),
            patch.object(updater, "ACTIVE", active),
            patch.object(updater, "RUNTIME", self.root / "runtime"),
            patch.object(deployment, "command", side_effect=command),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            (self.root / "runtime").mkdir()
            deployment.activate(bundle)
        stops = [call for call in calls if call[:2] == ["systemctl", "stop"]]
        self.assertEqual(stops, [["systemctl", "stop", "changed.service"]])
        self.assertTrue(any(call[0] == "nixos-rebuild" for call in calls))
        self.assertIn('"update.units_retained"', output.getvalue())
        self.assertIn('"count": 1', output.getvalue())


class SwitchExitStatus(unittest.TestCase):
    def activate(self, active_is_candidate: bool, failed_units: str = "") -> list[list[str]]:
        root = Path(tempfile.mkdtemp())
        bundle = root / "bundle"
        (bundle / "system").mkdir(parents=True)
        other = root / "other-system"
        other.mkdir()
        active = root / "current-system"
        active.symlink_to(bundle / "system" if active_is_candidate else other)
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "consumers": [],
            "healthUnits": [],
            "secrets": {},
            "socketUnits": [],
        }
        deployment.previous_consumers = []
        deployment.resources = None
        deployment.handoff = {}
        calls: list[list[str]] = []

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            calls.append(arguments)
            if arguments[0] == "nixos-rebuild":
                raise updater.UpdateError("command_failed")
            if arguments[1:3] == ["list-units", "--failed"]:
                switched = any(call[0] == "nixos-rebuild" for call in calls[:-1])
                standing = "heartbeat.service loaded failed failed"
                return standing + ("\n" + failed_units if switched and failed_units else "")
            return "inactive"

        with (
            patch.object(updater, "shared_memory_ready", return_value=True),
            patch.object(updater, "ACTIVE", active),
            patch.object(updater, "RUNTIME", root),
            patch.object(deployment, "command", side_effect=command),
        ):
            deployment.activate(bundle)
        return calls

    def test_switch_error_with_the_candidate_active_continues(self) -> None:
        calls = self.activate(active_is_candidate=True)
        self.assertTrue(any(call[0] == "nixos-rebuild" for call in calls))

    def test_switch_error_with_a_failed_system_unit_fails(self) -> None:
        with self.assertRaises(updater.UpdateError):
            self.activate(
                active_is_candidate=True, failed_units="broken.service loaded failed failed"
            )

    def test_switch_error_without_the_candidate_active_fails(self) -> None:
        with self.assertRaises(updater.UpdateError):
            self.activate(active_is_candidate=False)


class SharedMemoryPreflight(unittest.TestCase):
    def test_requires_writable_tmpfs_with_sticky_permissions(self) -> None:
        mode = os.stat_result((stat.S_IFDIR | 0o1777, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        mount = "1 0 0:1 / /dev/shm rw,nosuid - tmpfs tmpfs rw\n"
        with (
            patch.object(updater.Path, "stat", return_value=mode),
            patch.object(updater.Path, "read_text", return_value=mount),
        ):
            self.assertTrue(updater.shared_memory_ready())

        for invalid in (
            "1 0 0:1 / /dev/shm ro,nosuid - tmpfs tmpfs ro\n",
            "1 0 0:1 / /dev/shm rw,nosuid - tmpfs tmpfs ro\n",
            "1 0 0:1 / /dev/shm rw,nosuid - ext4 /dev/disk rw\n",
            "1 0 0:1 / /elsewhere rw,nosuid - tmpfs tmpfs rw\n",
        ):
            with (
                patch.object(updater.Path, "stat", return_value=mode),
                patch.object(updater.Path, "read_text", return_value=invalid),
            ):
                self.assertFalse(updater.shared_memory_ready())

        wrong_mode = os.stat_result((stat.S_IFDIR | 0o0755, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        with (
            patch.object(updater.Path, "stat", return_value=wrong_mode),
            patch.object(updater.Path, "read_text", return_value=mount),
        ):
            self.assertFalse(updater.shared_memory_ready())

    def test_activation_fails_before_any_consumer_stop(self) -> None:
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {}
        with (
            patch.object(updater, "shared_memory_ready", return_value=False),
            patch.object(deployment, "command") as command,
            self.assertRaisesRegex(updater.UpdateError, "shared_memory_unavailable"),
        ):
            deployment.activate(Path("/unused"))
        command.assert_not_called()


class PorscheReadiness(unittest.TestCase):
    def check_response(self, payload: bytes) -> bool:
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "status.sock")
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(path)
            listener.listen(1)

            def serve() -> None:
                connection, _ = listener.accept()
                with connection, contextlib.suppress(BrokenPipeError):
                    connection.sendall(payload)

            thread = threading.Thread(target=serve)
            thread.start()
            deployment = object.__new__(updater.Deployment)
            deployment.candidate = {
                "porsche": {"statusSocket": path},
                "healthUnits": [],
                "secrets": {},
                "marshall": None,
                "lilly": None,
            }
            try:
                with patch.object(updater, "ACTIVE", Path(directory) / "system"):
                    return deployment.healthy(Path(directory), time.monotonic() + 2)
            finally:
                thread.join(timeout=3)
                listener.close()
                self.assertFalse(thread.is_alive())

    def test_exact_affirmative_response_only(self) -> None:
        self.assertTrue(self.check_response(b'{"version":1,"ready":true}\n'))
        for value in [
            b'{"version":1,"ready":false}\n',
            b'{"version":true,"ready":true}\n',
            b'{"version":1,"ready":true,"extra":1}\n',
            b'{"version":1,"ready":true}',
            b"invalid\n",
            b" " * 4097,
        ]:
            self.assertFalse(self.check_response(value))

    def test_expired_deadline_never_connects(self) -> None:
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {"porsche": {"statusSocket": "/missing/status.sock"}}
        self.assertFalse(deployment.porsche_healthy(time.monotonic() - 1))


class AudiReadiness(PorscheReadiness):
    def test_every_enabled_role_must_pass(self) -> None:
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "audi": [
                {"role": "gateway", "statusSocket": "/gateway"},
                {"role": "dns", "statusSocket": "/dns"},
            ],
            "healthUnits": [],
            "secrets": {},
            "marshall": None,
            "lilly": None,
        }
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            with patch.object(updater, "ACTIVE", bundle / "system"):
                for results, expected in [
                    ([True, True], True),
                    ([True, False], False),
                    ([False], False),
                ]:
                    with patch.object(deployment, "status_healthy", side_effect=results) as check:
                        self.assertEqual(deployment.healthy(bundle, time.monotonic() + 2), expected)
                        self.assertEqual(check.call_count, len(results))

    def check_response(self, payload: bytes) -> bool:
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "status.sock")
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                listener.listen(1)

                def serve() -> None:
                    connection, _ = listener.accept()
                    with connection, contextlib.suppress(BrokenPipeError):
                        connection.sendall(payload)

                thread = threading.Thread(target=serve)
                thread.start()
                deployment = object.__new__(updater.Deployment)
                deployment.candidate = {
                    "audi": [{"role": "dns", "statusSocket": path}],
                    "healthUnits": [],
                    "secrets": {},
                    "marshall": None,
                    "lilly": None,
                }
                try:
                    with patch.object(updater, "ACTIVE", Path(directory) / "system"):
                        return deployment.healthy(Path(directory), time.monotonic() + 2)
                finally:
                    thread.join(timeout=3)
                    self.assertFalse(thread.is_alive())

    def test_exact_affirmative_response_only(self) -> None:
        self.assertTrue(self.check_response(b'{"version":1,"role":"dns","ready":true}\n'))
        for value in [
            {"version": 1, "role": "gateway", "ready": True},
            {"version": 1, "role": "dns", "ready": False},
            {"version": True, "role": "dns", "ready": True},
            {"version": 1, "ready": True},
            {"version": 1, "role": "dns", "ready": True, "extra": 1},
        ]:
            self.assertFalse(self.check_response((json.dumps(value) + "\n").encode()))
        for value in [b"invalid\n", b" " * 4097, b'{"version":1,"role":"dns","ready":true}']:
            self.assertFalse(self.check_response(value))


class ZiggyReadiness(unittest.TestCase):
    def test_host_bound_exact_health_and_capture(self) -> None:
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "ziggy": {"socket": "/run/ziggy/proxy.sock", "hostId": "host-one"},
            "healthUnits": [],
            "secrets": {},
            "marshall": None,
            "lilly": None,
        }
        good = dict(version=1, ready=True, role="ziggy", host_id="host-one")
        bad = [
            dict(good, host_id="host-two"),
            dict(good, ready=False),
            dict(good, ready=1),
            dict(good, version=True),
            dict(good, extra=1),
            [],
        ]
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(updater, "ACTIVE", Path(directory) / "system"),
        ):
            for payload in [good, *bad]:
                with patch.object(
                    deployment, "command", return_value=json.dumps(payload)
                ) as command:
                    self.assertEqual(
                        deployment.healthy(Path(directory), time.monotonic() + 2),
                        payload is good,
                    )
                    self.assertTrue(command.call_args.kwargs["capture"])
                    self.assertIn("--max-filesize", command.call_args.args[0])
            with patch.object(deployment, "command", return_value="invalid"):
                self.assertFalse(deployment.healthy(Path(directory), time.monotonic() + 2))
            with patch.object(deployment, "command") as command:
                self.assertFalse(deployment.healthy(Path(directory), time.monotonic() - 1))
                command.assert_not_called()


class MigrationUnits(unittest.TestCase):
    """A candidate's database migration must be safe to re-run under recovery."""

    def test_migrate_reuses_one_collected_fixed_unit_across_reruns(self) -> None:
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {
            "marshall": {
                "environmentFile": "/run/candidate-secrets/environment",
                "databaseCAFile": "/run/candidate-secrets/database-ca.crt",
                "migrate": "/nix/store/synthetic-migrate",
            }
        }
        deployment.staged = {}
        calls: list[list[str]] = []

        def command(arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
            calls.append(arguments)
            return ""

        with patch.object(deployment, "command", side_effect=command):
            deployment.migrate()
            deployment.migrate()

        # One fixed collected oneshot per invocation: a crashed updater can
        # restart the same candidate's migration and systemd serializes the
        # attempt against any migrator the crashed updater already launched.
        self.assertEqual(len(calls), 2)
        for arguments in calls:
            self.assertEqual(arguments[0], "systemd-run")
            self.assertIn("--unit=overalls-auto-update-migrate", arguments)
            self.assertIn("--wait", arguments)
            self.assertIn("--collect", arguments)
            self.assertEqual(arguments[-1], "/nix/store/synthetic-migrate")

    def test_migrate_without_a_marshall_role_is_a_noop(self) -> None:
        deployment = object.__new__(updater.Deployment)
        deployment.candidate = {"marshall": None}
        with patch.object(deployment, "command") as command:
            deployment.migrate()
            deployment.migrate()
        command.assert_not_called()


class RemoteCacheConfiguration(unittest.TestCase):
    """The updater's Buck2 configuration never uploads and reads only a reachable cache."""

    def cache(self, identity: Path) -> dict[str, object]:
        return {
            "address": "100.98.214.120",
            "port": 50071,
            "instanceName": "main",
            "caCertificate": "/nix/store/fixture-ca.crt",
            "clientIdentity": str(identity),
        }

    def test_read_only_section_only_with_identity_and_listener(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            identity = Path(directory) / "client.pem"
            cache = updater.remote_cache_value(self.cache(identity))
            local, state = updater.buck2_local_config(None)
            self.assertEqual((local, state), (updater.BUCK2_LOCAL_CONFIG, "not_configured"))
            local, state = updater.buck2_local_config(cache, lambda *_: True)
            self.assertEqual((local, state), (updater.BUCK2_LOCAL_CONFIG, "identity_missing"))
            identity.write_text("")
            self.assertEqual(
                updater.buck2_local_config(cache, lambda *_: True)[1], "identity_missing"
            )
            identity.write_text("certificate and key")
            local, state = updater.buck2_local_config(cache, lambda *_: False)
            self.assertEqual((local, state), (updater.BUCK2_LOCAL_CONFIG, "unreachable"))
            probes: list[tuple[str, int]] = []
            local, state = updater.buck2_local_config(
                cache, lambda address, port: probes.append((address, port)) is None
            )
            self.assertEqual(state, "enabled")
            self.assertEqual(probes, [("100.98.214.120", 50071)])
            self.assertTrue(local.startswith(updater.BUCK2_LOCAL_CONFIG))
            self.assertIn("address = grpc://100.98.214.120:50071\n", local)
            self.assertIn(f"tls_client_cert = {identity}\n", local)
            for configured in [updater.BUCK2_LOCAL_CONFIG, local]:
                self.assertIn("default_allow_cache_upload = false", configured)
                self.assertIn("remote_execution = false", configured)

    def test_malformed_cache_configuration_is_refused(self) -> None:
        good = self.cache(Path("/run/overalls-secrets/buck-re/client.pem"))
        for change in [
            {"address": "100.98.214.120\n[buck2]"},
            {"address": "300.1.1.1"},
            {"port": 0},
            {"instanceName": "main\n  default_allow_cache_upload = true"},
            {"clientIdentity": "relative.pem"},
            {"caCertificate": "/ca.crt\n[buck2]"},
        ]:
            with self.assertRaises(ValueError):
                updater.remote_cache_value(dict(good, **change))
        self.assertIsNone(updater.remote_cache_value(None))

    def test_unreachable_listener_probe_is_bounded(self) -> None:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        started = time.monotonic()
        self.assertFalse(updater.cache_reachable("127.0.0.1", port))
        self.assertLess(time.monotonic() - started, updater.REMOTE_CACHE_PROBE_TIMEOUT + 1)


class RemoteCacheFallback(unittest.TestCase):
    def test_enabled_cache_failure_retries_without_cache(self) -> None:
        calls: list[str] = []

        def run() -> str:
            calls.append("run")
            if len(calls) == 1:
                raise updater.UpdateError("command_failed")
            return "built"

        def disable() -> None:
            calls.append("disable")

        with contextlib.redirect_stdout(io.StringIO()) as log:
            self.assertEqual(updater.build_with_cache_fallback(run, "enabled", disable), "built")
        self.assertEqual(calls, ["run", "disable", "run"])
        self.assertIn('"state": "fallback"', log.getvalue())

    def test_failure_without_cache_is_not_retried(self) -> None:
        for state in ["not_configured", "identity_missing", "unreachable"]:
            calls: list[str] = []

            def run(calls: list[str] = calls) -> str:
                calls.append("run")
                raise updater.UpdateError("command_failed")

            def disable(calls: list[str] = calls) -> None:
                calls.append("disable")

            with self.assertRaises(updater.UpdateError):
                updater.build_with_cache_fallback(run, state, disable)
            self.assertEqual(calls, ["run"], state)

    def test_second_failure_propagates(self) -> None:
        def run() -> str:
            raise updater.UpdateError("command_failed")

        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(updater.UpdateError):
            updater.build_with_cache_fallback(run, "enabled", lambda: None)


if __name__ == "__main__":
    unittest.main()
