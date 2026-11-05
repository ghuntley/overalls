"""Run packaged Android tests on one explicitly selected device, without raw logs."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import selectors
import shutil
import stat
import subprocess
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Literal, TypedDict
from urllib.parse import urlsplit

MAX_OUTPUT_BYTES = 512 * 1024
MAX_APK_BYTES = 256 * 1024 * 1024
MAX_DESCRIPTOR_BYTES = 128 * 1024
PACKAGE = "dev.overalls.mila.nativeui"
RUNNER = f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"
SERIAL = re.compile(r"emulator-[1-9][0-9]{0,4}\Z")
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
TEST_ID = re.compile(r"[A-Za-z0-9_.$]+#[A-Za-z0-9_.$-]{1,160}\Z")
JOURNEY_METHODS = (
    "j01_signInRequiresBrowserApprovalThenReconnectsWithoutIt",
    "j02_machineListingIncludesSeedMachine",
    "j03_createThroughSessionBoundForm",
    "j04_lifecycleAdmissionThenResize",
    "j05_shareAddAndRemoveOnSeedMachine",
    "j06_threadPromptAnswerAndPlanApproval",
    "j07_terminalWithoutGuestIsRefusedClosed",
    "j08_webEndpointShowAndSetMoveRevision",
    "j09_sshKeysListIncludesThisDevice",
    "j10_notificationDeviceCrud",
    "j11_deleteCreatedMachine",
    "j12_guestTerminalEchoResizeReplayAndKill",
    "j13_signedOutShareCompletesAfterFixtureSignIn",
    "j14_linkLaunchesThroughSystemResolverToSeedMachine",
)
JOURNEY_IDS = tuple(f"{PACKAGE}.MilaJourneyTest#{method}" for method in JOURNEY_METHODS)

CommandOutcome = Literal["ok", "failed", "timeout", "oversized", "unavailable"]
Reason = Literal[
    "complete",
    "invalid_serial",
    "invalid_run_id",
    "adb_unavailable",
    "device_unavailable",
    "device_not_emulator",
    "device_not_booted",
    "invalid_api_level",
    "invalid_apk",
    "install_failed",
    "instrumentation_failed",
    "command_timeout",
    "command_output_limit",
    "invalid_descriptor",
    "reverse_conflict",
    "reverse_failed",
    "reverse_cleanup_failed",
    "journey_incomplete",
]


@dataclass(frozen=True)
class CommandResult:
    outcome: CommandOutcome
    output: bytes = b""


@dataclass(frozen=True)
class Counts:
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    failure_ids: tuple[str, ...] = ()
    complete: bool = False
    completed_ids: tuple[str, ...] = ()


class ReportDocument(TypedDict):
    version: int
    outcome: Literal["passed", "failed"]
    reason: Reason
    run_id: str
    serial: str
    api_level: int | None
    app_sha256: str | None
    test_sha256: str | None
    passed: int
    failed: int
    skipped: int
    failure_ids: list[str]
    journey: Literal["excluded", "requested"]


@dataclass(frozen=True)
class Report:
    reason: Reason
    run_id: str
    serial: str
    api_level: int | None = None
    app_sha256: str | None = None
    test_sha256: str | None = None
    counts: Counts = Counts()
    journey: Literal["excluded", "requested"] = "excluded"

    def document(self) -> ReportDocument:
        return {
            "version": 1,
            "outcome": "passed" if self.reason == "complete" else "failed",
            "reason": self.reason,
            "run_id": self.run_id,
            "serial": self.serial,
            "api_level": self.api_level,
            "app_sha256": self.app_sha256,
            "test_sha256": self.test_sha256,
            "passed": self.counts.passed,
            "failed": self.counts.failed,
            "skipped": self.counts.skipped,
            "failure_ids": list(self.counts.failure_ids),
            "journey": self.journey,
        }


def run_bounded(argv: list[str], timeout: float) -> CommandResult:
    """Capture a bounded amount of subprocess output and never print it."""
    try:
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError:
        return CommandResult("unavailable")
    with process:
        output = process.stdout
        if output is None:
            process.kill()
            return CommandResult("unavailable")
        deadline = time.monotonic() + timeout
        captured = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(output, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return CommandResult("timeout")
                    if not selector.select(min(remaining, 0.25)):
                        continue
                    chunk = os.read(
                        output.fileno(), min(65536, MAX_OUTPUT_BYTES + 1 - len(captured))
                    )
                    if not chunk:
                        status = process.wait(timeout=max(0.001, remaining))
                        return CommandResult("ok" if status == 0 else "failed", bytes(captured))
                    captured.extend(chunk)
                    if len(captured) > MAX_OUTPUT_BYTES:
                        return CommandResult("oversized")
        except (OSError, subprocess.TimeoutExpired):
            return CommandResult("timeout")
        finally:
            if process.poll() is None:
                process.kill()


def parse_instrumentation(output: bytes) -> Counts:
    """@cc [owner:ghuntley,label:verification;security] android-device-test-report
    A passing report MUST require completed AndroidJUnitRunner test statuses, its successful
    final code and a nonzero OK summary; crashes, malformed statuses and failures MUST fail.
    Raw instrumentation streams MUST NOT enter the report; failure IDs remain bounded.
    """
    if len(output) > MAX_OUTPUT_BYTES:
        return Counts()
    passed = failed = skipped = 0
    fields: dict[str, str] = {}
    failures: list[str] = []
    completed: list[str] = []
    summary = 0
    assumed = 0
    successful_exit = False
    malformed = False
    for line in output.decode("utf-8", errors="replace").replace("\r", "").splitlines():
        if line.startswith("INSTRUMENTATION_STATUS: "):
            key, separator, value = line.removeprefix("INSTRUMENTATION_STATUS: ").partition("=")
            if separator and key in {"class", "test"}:
                fields[key] = value
        elif line.startswith("INSTRUMENTATION_STATUS_CODE: "):
            code = line.removeprefix("INSTRUMENTATION_STATUS_CODE: ")
            if code == "1":
                continue
            identity = fields.get("class", "") + "#" + fields.get("test", "")
            if not TEST_ID.fullmatch(identity) or len(identity) > 256:
                malformed = True
            elif len(completed) < 256:
                completed.append(identity)
            else:
                malformed = True
            if code == "0":
                passed += 1
            elif code in {"-1", "-2"}:
                failed += 1
                if len(failures) < 16 and TEST_ID.fullmatch(identity) and len(identity) <= 256:
                    failures.append(identity)
            elif code in {"-3", "-4"}:
                skipped += 1
                if code == "-4":
                    assumed += 1
            else:
                malformed = True
            fields.clear()
        elif re.fullmatch(r"OK \([1-9][0-9]{0,3} tests?\)", line):
            summary = int(line.split("(")[1].split(" ")[0])
        elif line == "INSTRUMENTATION_CODE: -1":
            successful_exit = True
        if any(
            marker in line
            for marker in ("FAILURES!!!", "INSTRUMENTATION_FAILED", "shortMsg=", "Process crashed")
        ):
            malformed = True
    complete = (
        summary == passed + failed + assumed
        and successful_exit
        and passed > 0
        and failed == 0
        and not malformed
    )
    return Counts(passed, failed, skipped, tuple(failures), complete, tuple(completed))


@dataclass(frozen=True)
class Journey:
    ports: tuple[int, ...]
    encoded: str = field(repr=False)


def object_fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("invalid descriptor object")
    fields: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("invalid descriptor key")
        fields[key] = item
    return fields


def descriptor_text(fields: dict[str, object], name: str, maximum: int) -> str:
    value = fields.get(name)
    if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > maximum:
        raise ValueError("invalid descriptor text")
    return value


def descriptor_port(value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 1024 <= value <= 65535:
        raise ValueError("invalid descriptor port")
    return value


def descriptor_url(value: str) -> tuple[str, int]:
    parsed = urlsplit(value)
    if (
        not value.isprintable()
        or parsed.scheme != "https"
        or parsed.hostname not in {"localhost", "127.0.0.1"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or parsed.query
        or not parsed.path.startswith("/")
    ):
        raise ValueError("invalid descriptor URL")
    return parsed.hostname, descriptor_port(parsed.port)


def load_journey(path: Path) -> Journey | None:
    """@cc [owner:ghuntley,label:security;verification] android-journey-descriptor-custody
    Fixture descriptors MUST be bounded owner-only regular files opened without following
    symlinks. Version, loopback endpoints, TLS, approver and required seed data MUST validate
    before device mutations; descriptor contents MUST remain absent from reports and logs.
    """
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or metadata.st_mode & 0o077
                or not 0 < metadata.st_size <= MAX_DESCRIPTOR_BYTES
            ):
                return None
            encoded = source.read(MAX_DESCRIPTOR_BYTES + 1)
        if len(encoded) > MAX_DESCRIPTOR_BYTES:
            return None
        document: object = json.loads(encoded)
        root = object_fields(document)
        version = root.get("version")
        if not isinstance(version, int) or isinstance(version, bool) or version != 1:
            return None
        deployment = object_fields(root.get("deployment"))
        host = descriptor_text(deployment, "host", 253)
        if host not in {"localhost", "127.0.0.1"}:
            return None
        ports = {
            descriptor_port(deployment.get("ssh_port")),
            descriptor_port(deployment.get("https_port")),
        }
        tls = object_fields(root.get("tls"))
        ca = descriptor_text(tls, "ca_pem", 64 * 1024)
        if "-----BEGIN CERTIFICATE-----" not in ca or "-----END CERTIFICATE-----" not in ca:
            return None
        if tls.get("server_name", host) != host:
            return None
        approver = object_fields(root.get("approver"))
        origin = descriptor_url(descriptor_text(approver, "url", 2048))
        hook = descriptor_url(descriptor_text(approver, "fixture_url", 2048))
        if origin != hook:
            return None
        ports.add(origin[1])
        token = descriptor_text(approver, "bearer_token", 4096)
        if not token.isprintable():
            return None
        seed = object_fields(root.get("seed"))
        principal = descriptor_text(seed, "share_principal", 256)
        if len(principal) < 3 or any(
            character.isspace() or not character.isprintable() for character in principal
        ):
            return None
        for key in ("machine_id", "terminal_machine_id"):
            value = descriptor_text(seed, key, 36)
            identity = uuid.UUID(value)
            if identity.int == 0 or str(identity) != value:
                return None
        return Journey(tuple(sorted(ports)), base64.b64encode(encoded).decode("ascii"))
    except (OSError, ValueError, UnicodeError):
        return None


def reverse_mappings(output: bytes) -> dict[str, str] | None:
    if len(output) > MAX_OUTPUT_BYTES:
        return None
    mappings: dict[str, str] = {}
    lines = output.decode("utf-8", errors="replace").splitlines()
    if len(lines) > 256:
        return None
    for line in lines:
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 3 or fields[1] in mappings:
            return None
        mappings[fields[1]] = fields[2]
    return mappings


def journey_run(
    journey: Journey,
    report: Report,
    command: Callable[[list[str], float], CommandResult],
) -> Report:
    """@cc [owner:ghuntley,label:security;verification] android-journey-once-and-reverse-ownership
    A journey MUST invoke its ordered 14 tests once, require all 14 passes without skips,
    and never retry the mutating suite. Reverse mappings MUST use only required loopback ports,
    refuse conflicts without rebinding, and clean up only mappings created by this invocation.
    """
    listed = command(["reverse", "--list"], 30.0)
    existing = reverse_mappings(listed.output) if listed.outcome == "ok" else None
    if existing is None:
        return replace(report, reason="reverse_failed")
    endpoints = tuple(f"tcp:{port}" for port in journey.ports)
    if any(endpoint in existing and existing[endpoint] != endpoint for endpoint in endpoints):
        return replace(report, reason="reverse_conflict")
    created: list[str] = []

    def invoke() -> Report:
        for endpoint in endpoints:
            if endpoint in existing:
                continue
            opened = command(["reverse", "--no-rebind", endpoint, endpoint], 30.0)
            if opened.outcome != "ok":
                return replace(report, reason="reverse_failed")
            created.append(endpoint)
        result = command(
            [
                "shell",
                "am",
                "instrument",
                "-r",
                "-w",
                "-e",
                "class",
                f"{PACKAGE}.MilaJourneyTest",
                "-e",
                "milaJourneyDescriptor",
                journey.encoded,
                RUNNER,
            ],
            1200.0,
        )
        if result.outcome != "ok":
            command(["shell", "am", "force-stop", f"{PACKAGE}.test"], 30.0)
            command(["shell", "am", "force-stop", PACKAGE], 30.0)
            reason: Reason = "instrumentation_failed"
            if result.outcome == "timeout":
                reason = "command_timeout"
            elif result.outcome == "oversized":
                reason = "command_output_limit"
            return replace(report, reason=reason)
        counts = parse_instrumentation(result.output)
        complete = (
            counts.complete
            and counts.passed == 14
            and counts.failed == 0
            and counts.skipped == 0
            and counts.completed_ids == JOURNEY_IDS
        )
        return replace(
            report, reason="complete" if complete else "journey_incomplete", counts=counts
        )

    cleanup_ok = True
    try:
        outcome = invoke()
    finally:
        if created:
            listing = command(["reverse", "--list"], 30.0)
            current = reverse_mappings(listing.output) if listing.outcome == "ok" else None
            if current is None:
                cleanup_ok = False
            else:
                for endpoint in reversed(created):
                    if endpoint not in current:
                        continue
                    if current[endpoint] != endpoint:
                        cleanup_ok = False
                        continue
                    removed = command(["reverse", "--remove", endpoint], 30.0)
                    if removed.outcome != "ok":
                        cleanup_ok = False
    return outcome if cleanup_ok else replace(outcome, reason="reverse_cleanup_failed")


def adb_executable() -> Path | None:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    candidate = Path(sdk) / "platform-tools" / "adb" if sdk else None
    if candidate is not None and candidate.is_file() and os.access(candidate, os.X_OK):
        return candidate
    found = shutil.which("adb")
    return Path(found) if found else None


def apk_digest(path: Path) -> str | None:
    try:
        if not path.is_file() or not 0 < path.stat().st_size <= MAX_APK_BYTES:
            return None
        with path.open("rb") as apk:
            return hashlib.file_digest(apk, "sha256").hexdigest()
    except OSError:
        return None


def run_suite(
    serial: str,
    run_id: str,
    apk_dir: Path,
    adb: Path | None,
    execute: Callable[[list[str], float], CommandResult] = run_bounded,
    journey_descriptor: Path | None = None,
) -> Report:
    """@cc [owner:ghuntley,label:verification;security] android-device-test-selection
    Device tests MUST require an explicit disposable-emulator serial and fresh run identity, address every
    adb command with that serial, bind evidence to both APK digests and the device API, and
    exclude the fixture journey unless its descriptor path is explicitly supplied. Physical
    devices MUST be refused before any install or test.
    No device discovery, emulator launch or raw device logs run.
    """
    if not SERIAL.fullmatch(serial) or int(serial.removeprefix("emulator-")) > 65535:
        return Report("invalid_serial", "", "")
    if not RUN_ID.fullmatch(run_id):
        return Report("invalid_run_id", "", serial)
    report = Report(
        "adb_unavailable",
        run_id,
        serial,
        journey="requested" if journey_descriptor is not None else "excluded",
    )
    journey = load_journey(journey_descriptor) if journey_descriptor is not None else None
    if journey_descriptor is not None and journey is None:
        return replace(report, reason="invalid_descriptor")
    if adb is None:
        return report

    def command(arguments: list[str], timeout: float = 30.0) -> CommandResult:
        return execute([str(adb), "-s", serial, *arguments], timeout)

    def refusal(result: CommandResult, reason: Reason) -> Report:
        if result.outcome == "timeout":
            reason = "command_timeout"
        elif result.outcome == "oversized":
            reason = "command_output_limit"
        return replace(report, reason=reason)

    state = command(["get-state"])
    if state.outcome != "ok" or state.output.strip() != b"device":
        return refusal(state, "device_unavailable")
    emulator = command(["shell", "getprop", "ro.kernel.qemu"])
    if emulator.outcome != "ok" or emulator.output.strip() != b"1":
        return refusal(emulator, "device_not_emulator")
    booted = command(["shell", "getprop", "sys.boot_completed"])
    if booted.outcome != "ok" or booted.output.strip() != b"1":
        return refusal(booted, "device_not_booted")
    api = command(["shell", "getprop", "ro.build.version.sdk"])
    if api.outcome != "ok" or not re.fullmatch(rb"[0-9]{2,3}", api.output.strip()):
        return refusal(api, "invalid_api_level")
    api_level = int(api.output.strip())
    if not 26 <= api_level <= 100:
        return replace(report, reason="invalid_api_level")
    app = apk_dir / "app-debug.apk"
    test = apk_dir / "app-debug-androidTest.apk"
    report = replace(
        report, api_level=api_level, app_sha256=apk_digest(app), test_sha256=apk_digest(test)
    )
    if report.app_sha256 is None or report.test_sha256 is None:
        return replace(report, reason="invalid_apk")
    for package in (f"{PACKAGE}.test", PACKAGE):
        removed = command(["uninstall", package])
        if removed.outcome not in {"ok", "failed"}:
            return refusal(removed, "install_failed")
    for apk in (app, test):
        installed = command(["install", "-r", "-t", "-g", str(apk)], 120.0)
        if installed.outcome != "ok" or b"Success" not in installed.output.splitlines():
            return refusal(installed, "install_failed")
    if journey is not None:
        return journey_run(journey, report, command)
    result = command(
        [
            "shell",
            "am",
            "instrument",
            "-r",
            "-w",
            "-e",
            "notClass",
            f"{PACKAGE}.MilaJourneyTest",
            RUNNER,
        ],
        600.0,
    )
    if result.outcome != "ok":
        # A timed-out local adb client need not stop instrumentation on-device.
        command(["shell", "am", "force-stop", f"{PACKAGE}.test"])
        command(["shell", "am", "force-stop", PACKAGE])
        return refusal(result, "instrumentation_failed")
    counts = parse_instrumentation(result.output)
    return replace(
        report, reason="complete" if counts.complete else "instrumentation_failed", counts=counts
    )


@dataclass
class Arguments(argparse.Namespace):
    serial: str = ""
    run_id: str = ""
    apk_dir: Path = Path(".")
    report: Path = Path(".")
    journey_descriptor: Path | None = None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--apk-dir", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--journey-descriptor", type=Path)
    args = parser.parse_args(namespace=Arguments())
    report = run_suite(
        args.serial,
        args.run_id,
        args.apk_dir,
        adb_executable(),
        journey_descriptor=args.journey_descriptor,
    )
    encoded = json.dumps(report.document(), sort_keys=True) + "\n"
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if report.reason == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
