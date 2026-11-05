"""Exercise the device runner's selection, bounded subprocesses and no-false-pass parser."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
# Buck2 executes this standalone test beside the runner, without installing a Python package.
from packaged_instrumentation import (
    JOURNEY_METHODS,
    MAX_DESCRIPTOR_BYTES,
    MAX_OUTPUT_BYTES,
    CommandResult,
    load_journey,
    parse_instrumentation,
    reverse_mappings,
    run_bounded,
    run_suite,
)


def statuses(
    code: int = 0, method: str = "linked", class_name: str = "MilaPackagedJniTest"
) -> bytes:
    return (
        f"INSTRUMENTATION_STATUS: class=dev.overalls.mila.nativeui.{class_name}\n"
        f"INSTRUMENTATION_STATUS: test={method}\n"
        f"INSTRUMENTATION_STATUS_CODE: {code}\n"
    ).encode()


def success() -> bytes:
    return statuses() + b"OK (1 test)\nINSTRUMENTATION_CODE: -1\n"


class Device:
    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self.emulator = b"1\n"
        self.booted = b"1\n"
        self.api = b"35\n"
        self.instrumentation = CommandResult("ok", success())

    def execute(self, argv: list[str], timeout: float) -> CommandResult:
        self.calls.append(argv)
        if not 0 < timeout <= 1200:
            raise AssertionError("unbounded device command")
        command = argv[3:]
        if command == ["get-state"]:
            return CommandResult("ok", b"device\n")
        if command == ["shell", "getprop", "ro.kernel.qemu"]:
            return CommandResult("ok", self.emulator)
        if command == ["shell", "getprop", "sys.boot_completed"]:
            return CommandResult("ok", self.booted)
        if command == ["shell", "getprop", "ro.build.version.sdk"]:
            return CommandResult("ok", self.api)
        if command[0] in {"install", "uninstall"}:
            return CommandResult("ok", b"Success\n")
        if command[:3] == ["shell", "am", "force-stop"]:
            return CommandResult("ok")
        if command[:3] == ["shell", "am", "instrument"]:
            return self.instrumentation
        raise AssertionError("unexpected device command")


def fixture_document() -> dict[str, object]:
    return {
        "version": 1,
        "deployment": {"host": "localhost", "ssh_port": 2222, "https_port": 8443},
        "tls": {
            "ca_pem": "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----",
            "server_name": "localhost",
        },
        "approver": {
            "url": "https://localhost:8444/approve",
            "fixture_url": "https://localhost:8444/fixture/",
            "bearer_token": "test-fixture-bearer",
        },
        "seed": {
            "machine_id": "00000000-0000-0000-0000-000000000001",
            "terminal_machine_id": "00000000-0000-0000-0000-000000000002",
            "share_principal": "person@example.test",
        },
    }


def write_descriptor(root: Path, document: dict[str, object] | None = None) -> Path:
    path = root / "descriptor.json"
    path.write_text(
        json.dumps(fixture_document() if document is None else document), encoding="utf-8"
    )
    path.chmod(0o600)
    return path


def journey_success(skipped: int | None = None, reverse_order: bool = False) -> bytes:
    methods = tuple(reversed(JOURNEY_METHODS)) if reverse_order else JOURNEY_METHODS
    return (
        b"".join(
            statuses(-4 if index == skipped else 0, method, "MilaJourneyTest")
            for index, method in enumerate(methods)
        )
        + b"OK (14 tests)\nINSTRUMENTATION_CODE: -1\n"
    )


class JourneyDevice(Device):
    def __init__(self) -> None:
        super().__init__()
        self.mappings = {"tcp:2222": "tcp:2222", "tcp:9999": "tcp:10000"}
        self.open_failure: str | None = None
        self.change_mapping = False
        self.instrumentation = CommandResult("ok", journey_success())

    def execute(self, argv: list[str], timeout: float) -> CommandResult:
        command = argv[3:]
        if command[0] != "reverse":
            result = super().execute(argv, timeout)
            if command[:3] == ["shell", "am", "instrument"] and self.change_mapping:
                self.mappings["tcp:8443"] = "tcp:9998"
            return result
        self.calls.append(argv)
        if command == ["reverse", "--list"]:
            output = "".join(
                f"emulator-5580 {local} {remote}\n" for local, remote in self.mappings.items()
            )
            return CommandResult("ok", output.encode() or b"\n")
        if command[1] == "--no-rebind":
            local, remote = command[2:]
            if local in self.mappings or local == self.open_failure:
                return CommandResult("failed")
            self.mappings[local] = remote
            return CommandResult("ok")
        if command[1] == "--remove":
            self.mappings.pop(command[2])
            return CommandResult("ok")
        raise AssertionError("unexpected reverse command")


class InstrumentationParserTest(unittest.TestCase):
    def test_pass_needs_completed_status_and_matching_successful_summary(self) -> None:
        self.assertTrue(parse_instrumentation(success()).complete)
        for output in (
            b"OK (1 test)\nINSTRUMENTATION_CODE: -1\n",
            statuses() + b"OK (1 test)\n",
            statuses() + b"OK (2 tests)\nINSTRUMENTATION_CODE: -1\n",
            success() + b"INSTRUMENTATION_RESULT: shortMsg=Process crashed\n",
            success() + b"FAILURES!!!\n",
            b"x" * (MAX_OUTPUT_BYTES + 1),
        ):
            self.assertFalse(parse_instrumentation(output).complete)

    def test_skipped_and_assumed_tests_preserve_junit_run_count(self) -> None:
        output = statuses() + statuses(-3, "ignored") + statuses(-4, "assumed")
        counts = parse_instrumentation(output + b"OK (2 tests)\nINSTRUMENTATION_CODE: -1\n")
        self.assertTrue(counts.complete)
        self.assertEqual(counts.skipped, 2)

    def test_failure_report_omits_stream_and_bounds_identifiers(self) -> None:
        counts = parse_instrumentation(statuses(-2) + b"private-token-terminal-bytes\n")
        self.assertFalse(counts.complete)
        self.assertEqual(counts.failed, 1)
        self.assertEqual(
            counts.failure_ids, ("dev.overalls.mila.nativeui.MilaPackagedJniTest#linked",)
        )
        self.assertNotIn("private-token", repr(counts))
        malicious = statuses(-2, "bad method / secret")
        self.assertEqual(parse_instrumentation(malicious).failure_ids, ())


class DeviceRunnerTest(unittest.TestCase):
    def test_refuses_missing_physical_or_oversized_serial_before_any_command(self) -> None:
        for serial in ("", "physical-phone", "emulator-65536", "emulator-5580\n"):
            device = Device()
            result = run_suite(serial, "run-1", Path("."), Path("adb"), device.execute)
            self.assertEqual(result.reason, "invalid_serial")
            self.assertEqual(device.calls, [])
        self.assertEqual(
            run_suite("emulator-5580", "", Path("."), Path("adb")).reason, "invalid_run_id"
        )
        self.assertEqual(
            run_suite("emulator-5580", "run-1", Path("."), None).reason, "adb_unavailable"
        )

    def test_refuses_non_emulator_or_unbooted_device_before_install(self) -> None:
        for physical in (True, False):
            device = Device()
            if physical:
                device.emulator = b"0\n"
            else:
                device.booted = b"0\n"
            result = run_suite("emulator-5580", "run-1", Path("."), Path("adb"), device.execute)
            self.assertEqual(
                result.reason, "device_not_emulator" if physical else "device_not_booted"
            )
            self.assertFalse(any(call[3] in {"install", "uninstall"} for call in device.calls))

    def test_report_binds_artifacts_serial_api_run_and_excludes_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "app-debug.apk").write_bytes(b"app-artifact")
            (root / "app-debug-androidTest.apk").write_bytes(b"test-artifact")
            device = Device()
            result = run_suite("emulator-5580", "run-1", root, Path("adb"), device.execute)
            self.assertEqual(result.reason, "complete")
            self.assertEqual(result.app_sha256, hashlib.sha256(b"app-artifact").hexdigest())
            self.assertEqual(result.test_sha256, hashlib.sha256(b"test-artifact").hexdigest())
            self.assertEqual(result.api_level, 35)
            self.assertEqual(result.run_id, "run-1")
            self.assertTrue(all(call[1:3] == ["-s", "emulator-5580"] for call in device.calls))
            instrumentation = device.calls[-1]
            self.assertIn("notClass", instrumentation)
            self.assertIn("dev.overalls.mila.nativeui.MilaJourneyTest", instrumentation)
            self.assertEqual(result.document()["journey"], "excluded")
            self.assertLess(len(json.dumps(result.document())), 8192)

    def test_timeout_stops_only_the_explicit_emulators_packages(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("app-debug.apk", "app-debug-androidTest.apk"):
                (root / name).write_bytes(b"apk")
            device = Device()
            device.instrumentation = CommandResult("timeout")
            result = run_suite("emulator-5580", "run-1", root, Path("adb"), device.execute)
            self.assertEqual(result.reason, "command_timeout")
            self.assertEqual(device.calls[-1][3:6], ["shell", "am", "force-stop"])


class BoundedCommandTest(unittest.TestCase):
    def test_subprocess_capture_refuses_overflow_timeout_and_nonzero_exit(self) -> None:
        cases = (
            ("print('ok')", 5.0, "ok"),
            (f"print('x' * {MAX_OUTPUT_BYTES + 1})", 5.0, "oversized"),
            ("import time; time.sleep(3)", 0.05, "timeout"),
            ("raise SystemExit(1)", 5.0, "failed"),
        )
        for code, timeout, expected in cases:
            self.assertEqual(
                run_bounded([sys.executable, "-I", "-c", code], timeout).outcome, expected
            )


class JourneyRunnerTest(unittest.TestCase):
    def test_reverse_mapping_parser_accepts_empty_adb_output_and_blank_framing(self) -> None:
        for output in (b"", b"\n", b"\r\n", b" \t\n\n"):
            self.assertEqual(reverse_mappings(output), {})
        self.assertEqual(
            reverse_mappings(b"\nemulator-5580 tcp:2222 tcp:2222\n \t\n"),
            {"tcp:2222": "tcp:2222"},
        )
        self.assertIsNone(reverse_mappings(b"\nmalformed\n"))

    def test_journey_opens_and_cleans_all_reverses_from_empty_adb_list(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            descriptor = write_descriptor(root)
            for name in ("app-debug.apk", "app-debug-androidTest.apk"):
                (root / name).write_bytes(b"apk")
            device = JourneyDevice()
            device.mappings.clear()
            result = run_suite(
                "emulator-5580", "journey-1", root, Path("adb"), device.execute, descriptor
            )
            self.assertEqual(result.reason, "complete")
            self.assertEqual(result.counts.passed, 14)
            self.assertEqual(device.mappings, {})
            instruments = [
                call for call in device.calls if call[3:6] == ["shell", "am", "instrument"]
            ]
            self.assertEqual(len(instruments), 1)

    def test_descriptor_requires_owner_only_regular_file_and_valid_complete_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = write_descriptor(root)
            journey = load_journey(path)
            self.assertIsNotNone(journey)
            if journey is None:
                self.fail("validated descriptor")
            self.assertEqual(journey.ports, (2222, 8443, 8444))
            self.assertNotIn("test-fixture-bearer", repr(journey))
            path.chmod(0o644)
            self.assertIsNone(load_journey(path))
            path.chmod(0o600)
            link = root / "link.json"
            link.symlink_to(path)
            self.assertIsNone(load_journey(link))
            self.assertIsNone(load_journey(root))
            for document in (
                {**fixture_document(), "version": True},
                {
                    **fixture_document(),
                    "deployment": {
                        "host": "remote.example.test",
                        "ssh_port": 2222,
                        "https_port": 8443,
                    },
                },
                {**fixture_document(), "seed": {}},
                {
                    **fixture_document(),
                    "approver": {"url": "https://remote.example.test:8444/approve"},
                },
            ):
                self.assertIsNone(load_journey(write_descriptor(root, document)))
            path.write_bytes(b"x" * (MAX_DESCRIPTOR_BYTES + 1))
            self.assertIsNone(load_journey(path))

    def test_invalid_descriptor_refuses_before_any_device_command(self) -> None:
        device = JourneyDevice()
        result = run_suite(
            "emulator-5580", "journey-1", Path("."), Path("adb"), device.execute, Path("missing")
        )
        self.assertEqual(result.reason, "invalid_descriptor")
        self.assertEqual(device.calls, [])

    def test_journey_runs_once_in_order_and_cleans_only_owned_reverses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            descriptor = write_descriptor(root)
            for name in ("app-debug.apk", "app-debug-androidTest.apk"):
                (root / name).write_bytes(b"apk")
            for kind in (
                "success",
                "skip",
                "timeout",
                "wrong-order",
                "changed-mapping",
                "open-failure",
                "conflict",
            ):
                device = JourneyDevice()
                if kind == "skip":
                    device.instrumentation = CommandResult("ok", journey_success(skipped=4))
                elif kind == "timeout":
                    device.instrumentation = CommandResult("timeout")
                elif kind == "wrong-order":
                    device.instrumentation = CommandResult(
                        "ok", journey_success(reverse_order=True)
                    )
                elif kind == "changed-mapping":
                    device.change_mapping = True
                elif kind == "open-failure":
                    device.open_failure = "tcp:8444"
                elif kind == "conflict":
                    device.mappings["tcp:8443"] = "tcp:9998"
                result = run_suite(
                    "emulator-5580", "journey-1", root, Path("adb"), device.execute, descriptor
                )
                expected = {
                    "success": "complete",
                    "skip": "journey_incomplete",
                    "timeout": "command_timeout",
                    "wrong-order": "journey_incomplete",
                    "changed-mapping": "reverse_cleanup_failed",
                    "open-failure": "reverse_failed",
                    "conflict": "reverse_conflict",
                }[kind]
                self.assertEqual(result.reason, expected, kind)
                self.assertEqual(device.mappings["tcp:2222"], "tcp:2222")
                self.assertEqual(device.mappings["tcp:9999"], "tcp:10000")
                if kind in {"changed-mapping", "conflict"}:
                    self.assertEqual(device.mappings["tcp:8443"], "tcp:9998")
                else:
                    self.assertNotIn("tcp:8443", device.mappings)
                self.assertNotIn("tcp:8444", device.mappings)
                calls = [
                    call for call in device.calls if call[3:6] == ["shell", "am", "instrument"]
                ]
                self.assertEqual(len(calls), 0 if kind in {"open-failure", "conflict"} else 1)
                self.assertEqual(result.document()["journey"], "requested")
                self.assertNotIn("test-fixture-bearer", json.dumps(result.document()))


if __name__ == "__main__":
    unittest.main()
