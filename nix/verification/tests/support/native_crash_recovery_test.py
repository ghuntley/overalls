"""Check crash evidence boundaries; host child processes establish no VM acceptance."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import native_crash_recovery as crash
import native_services as services


@contextmanager
def child() -> Generator[subprocess.Popen[bytes]]:
    with subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def boots() -> tuple[services.Boot, services.Boot]:
    placement = "11111111-1111-4111-8111-111111111111"
    return (
        services.Boot(
            services.Binding(placement, 7, "a" * 64),
            "22222222-2222-4222-8222-222222222222",
        ),
        services.Boot(
            services.Binding(placement, 8, "b" * 64),
            "33333333-3333-4333-8333-333333333333",
        ),
    )


def receipt(before: services.Boot, after: services.Boot) -> dict[str, object]:
    return {
        "version": 1,
        "os": "freebsd",
        "boot_ids": [before.boot_id, after.boot_id],
        "boot_endings": ["sigkill", "clean"],
        "kernel_sha256": "a" * 64,
        "trust_bundle_digest": "b" * 64,
        "image_sha256": "c" * 64,
        "firmware_sha256": "d" * 64,
        "vmm_sha256": "e" * 64,
        "checks": list(crash.SERVICE_CHECKS),
        "native_admission": False,
        "scope": crash.SERVICE_SCOPE,
    }


class CrashBoundaryTest(unittest.TestCase):
    def test_fsck_exit_status_is_closed_and_bounded(self) -> None:
        for body, expected in ((b"0", 0), (b"1", 1), (b"255", 255)):
            self.assertEqual(crash.ufs_integrity_status(body), expected)
        for body in (b"", b"00", b"-1", b"256", b"0\n", b"0secret", b"9" * 4096):
            with self.subTest(size=len(body)), self.assertRaises(services.ProtocolError):
                crash.ufs_integrity_status(body)

    def test_ssh_accepts_only_exact_login_event_and_bounded_success(self) -> None:
        self.assertEqual(
            crash.command_output(
                subprocess.CompletedProcess(["ssh"], 0, b"fixed", crash.SSH_LOGIN_EVENT)
            ),
            b"fixed",
        )
        for status, body, stderr in (
            (1, b"fixed", crash.SSH_LOGIN_EVENT),
            (0, b"fixed", b""),
            (0, b"fixed", crash.SSH_LOGIN_EVENT * 2),
            (0, b"fixed", crash.SSH_LOGIN_EVENT.replace(b"\n", b"\r\n")),
            (0, b"fixed", crash.SSH_LOGIN_EVENT.replace(b"login_recorded", b"login_denied")),
            (0, b"fixed", crash.SSH_LOGIN_EVENT + b"unexpected\n"),
            (0, b"x" * 4097, crash.SSH_LOGIN_EVENT),
        ):
            with (
                self.subTest(status=status, stderr=stderr),
                self.assertRaises(services.ProtocolError),
            ):
                crash.command_output(subprocess.CompletedProcess(["ssh"], status, body, stderr))

    def test_root_identity_refuses_foreign_duplicate_readonly_or_other_targets(self) -> None:
        freebsd = b"/dev/gpt/rootfs / ufs rw,noatime 1 1\ndevfs /dev devfs rw 0 0\n"
        illumos = f"{crash.DATASET} - / zfs - no\n".encode("ascii")
        crash.root_mount(freebsd, "freebsd")
        crash.root_mount(illumos, "illumos")
        for body, os_name in (
            (freebsd.replace(b"rootfs", b"foreign"), "freebsd"),
            (freebsd.replace(b"rw,noatime", b"ro"), "freebsd"),
            (freebsd.replace(b"ufs", b"zfs"), "freebsd"),
            (freebsd + freebsd, "freebsd"),
            (illumos.replace(crash.DATASET.encode(), b"foreign/ROOT/default"), "illumos"),
            (illumos + illumos, "illumos"),
            (b"", "freebsd"),
            (b"\xff\n", "illumos"),
            (b"x" * 4097, "freebsd"),
        ):
            with self.subTest(body=body), self.assertRaises(services.ProtocolError):
                crash.root_mount(body, os_name)

    def test_restart_requires_changed_boot_challenge_and_exact_next_epoch(self) -> None:
        before, after = boots()
        crash.new_authority(before, after)
        for binding, boot_id in (
            (after.binding, before.boot_id),
            (before.binding, after.boot_id),
            (
                services.Binding(before.binding.placement_id, 8, before.binding.boot_challenge),
                after.boot_id,
            ),
            (
                services.Binding(before.binding.placement_id, 9, after.binding.boot_challenge),
                after.boot_id,
            ),
            (
                services.Binding(after.boot_id, 8, after.binding.boot_challenge),
                after.boot_id,
            ),
        ):
            with self.subTest(binding=binding), self.assertRaises(services.ProtocolError):
                crash.new_authority(before, services.Boot(binding, boot_id))

    def test_actual_host_exit_must_be_sigkill_not_live_sigterm_or_shell_137(self) -> None:
        with child() as process:
            with self.assertRaises(services.ProtocolError):
                crash.observed_crash(process)
            process.terminate()
            process.wait(timeout=5)
            with self.assertRaises(services.ProtocolError):
                crash.observed_crash(process)
        with child() as process:
            process.kill()
            process.wait(timeout=5)
            crash.observed_crash(process)
        with subprocess.Popen(
            [sys.executable, "-c", "raise SystemExit(137)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ) as process:
            process.wait(timeout=5)
            with self.assertRaises(services.ProtocolError):
                crash.observed_crash(process)

    def test_zfs_requires_completed_zero_repair_scrub_and_healthy_single_disk(self) -> None:
        status = (
            f"  pool: {crash.POOL}\n state: ONLINE\n"
            "  scan: scrub repaired 0B in 0 days 00:00:02 with 0 errors on Sat Oct 17 15:00:00 2026\n"
            f"config:\n\n\tNAME        STATE     READ WRITE CKSUM\n"
            f"\t{crash.POOL}  ONLINE       0     0     0\n"
            "\t  c2t0d0   ONLINE       0     0     0\n\nerrors: No known data errors\n"
        ).encode("ascii")
        self.assertEqual(crash.scrub_status(status), "complete")
        running = status.replace(
            b"scrub repaired 0B in 0 days 00:00:02 with 0 errors on Sat Oct 17 15:00:00 2026",
            b"scrub in progress since Sat Oct 17 15:00:00 2026",
        )
        self.assertEqual(crash.scrub_status(running), "running")
        for body in (
            status.replace(b"repaired 0B", b"repaired 1B"),
            status.replace(b"with 0 errors", b"with 1 errors"),
            status.replace(b"ONLINE", b"DEGRADED", 1),
            status.replace(b"0     0     0", b"0     1     0"),
            status.replace(b"c2t0d0", b"mirror-0"),
            status.replace(b"errors: No known data errors", b"errors: 1 data errors"),
            status.replace(b"\nerrors:", b"\n  c3t0d0 ONLINE 0 0 0\nerrors:"),
            status + b" state: ONLINE\n",
            status.replace(b"scrub repaired", b"resilvered"),
            status[:-1],
            b"\xff\n",
        ):
            with self.subTest(body=body), self.assertRaises(services.ProtocolError):
                crash.scrub_status(body)

    def test_service_receipt_requires_complete_abrupt_sequence_and_exact_types(self) -> None:
        before, after = boots()
        with child() as process:
            first = crash.Observation(before, process, "freebsd")
            second = crash.Observation(after, process, "freebsd")
            valid = receipt(before, after)
            artifacts = crash.service_evidence(json.dumps(valid).encode(), first, second)
            self.assertEqual(artifacts.kernel, "a" * 64)
            for field, value in (
                ("version", True),
                ("version", 1.0),
                ("native_admission", 0),
                ("native_admission", True),
                ("boot_endings", ["clean", "clean"]),
                ("boot_endings", ["sigkill"]),
                ("boot_ids", [after.boot_id, before.boot_id]),
                ("boot_ids", [before.boot_id, before.boot_id]),
                ("checks", list(crash.SERVICE_CHECKS[:-1])),
                ("checks", [*crash.SERVICE_CHECKS[:-1], crash.SERVICE_CHECKS[0]]),
                ("kernel_sha256", "A" * 64),
                ("trust_bundle_digest", 1),
                ("scope", "clean reboot"),
                ("unknown", False),
            ):
                with (
                    self.subTest(field=field, value=value),
                    self.assertRaises(services.ProtocolError),
                ):
                    crash.service_evidence(
                        json.dumps(valid | {field: value}).encode(), first, second
                    )
            for body in (
                b"{}",
                b"x" * 16_385,
                json.dumps(valid).replace('"version": 1', '"version": 1, "version": 1').encode(),
            ):
                with self.subTest(body=body), self.assertRaises(services.ProtocolError):
                    crash.service_evidence(body, first, second)

    def test_service_attribution_check_requires_exact_capability(self) -> None:
        before, after = boots()
        attribution = "all-boots-current-mmds-git-config-and-commit-attribution"
        with child() as process:
            first = crash.Observation(before, process, "freebsd")
            second = crash.Observation(after, process, "freebsd")
            original = receipt(before, after)
            capable = original | {"checks": [*crash.SERVICE_CHECKS, attribution]}
            crash.service_evidence(json.dumps(capable).encode(), first, second, git_identity=True)
            for value, expected_identity in (
                (capable, False),
                (original, True),
                (capable | {"checks": [*crash.SERVICE_CHECKS, attribution, attribution]}, True),
                (
                    capable | {"checks": [*crash.SERVICE_CHECKS[:-1], attribution, attribution]},
                    True,
                ),
            ):
                with (
                    self.subTest(capable=expected_identity),
                    self.assertRaises(services.ProtocolError),
                ):
                    crash.service_evidence(
                        json.dumps(value).encode(), first, second, git_identity=expected_identity
                    )

    def test_incomplete_observations_publish_no_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            oracle = crash.Oracle(work)
            with self.assertRaises(services.ProtocolError):
                oracle.finish()
            self.assertEqual(list(work.iterdir()), [])
            with child() as process:
                process.kill()
                process.wait(timeout=5)
                oracle.before = crash.Observation(boots()[0], process, "freebsd")
                with self.assertRaises(services.ProtocolError):
                    oracle.finish()
                self.assertEqual(list(work.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
