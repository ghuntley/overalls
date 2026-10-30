"""Check benchmark custody/refusal behavior without external SSH or VM effects."""

import json
import sys
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import provisioning_benchmark as bench

VM_ID = "11111111-1111-4111-8111-111111111111"
TEMPLATE_RECORD = "22222222-2222-4222-8222-222222222222"
TEMPLATE_INCARNATION = "33333333-3333-4333-8333-333333333333"
IMAGE = "sha256:" + "a" * 64
ARTIFACTS = {
    name: {"sha256": digit * 64, "bytes": 1234}
    for name, digit in (("kernel", "1"), ("initrd", "2"), ("rootfs", "3"))
}
VERIFIED = bench.NativeEvidence(
    method="reflink", source="verified", template_record_id=None, template_incarnation=None
)


class BenchmarkCustodyTest(unittest.TestCase):
    def test_guest_account_grammar_accepts_dotted_durable_identity(self) -> None:
        self.assertEqual(bench.checked_guest_user("alice.smith"), "alice.smith")
        for invalid in ("alice.", "alice@other", "alice/bob", "-alice", "alice\nother"):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "guest account"):
                bench.checked_guest_user(invalid)

    def config(self, output: Path) -> bench.Configuration:
        return bench.Configuration(
            output=output,
            mode="baseline",
            control_host="example.test",
            database_host="db.example.test",
            control_key=output.parent / "control",
            control_known_hosts=output.parent / "known_hosts",
            control_port=22,
            database_key=output.parent / "database",
            database_known_hosts=output.parent / "database_known_hosts",
            database_port=2222,
            admin_panterloons="ghuntley@ghuntley.dev",
            admin_dungarees="ghuntley@198.51.100.35",
            admin_key=output.parent / "admin",
            admin_known_hosts=output.parent / "admin_known_hosts",
            admin_port=2222,
            guest_key=output.parent / "guest",
            guest_known_hosts=output.parent / "guest_known_hosts",
            guest_ssh_config=output.parent / "guest_ssh_config",
            guest_port=22,
            guest_user="testuser",
            nixos_image=IMAGE,
            ubuntu_image=IMAGE,
            profile="oss",
            cpu=1,
            revision="a" * 40,
            baseline_summary=None,
        )

    def test_manifest_precedes_mutation_and_cleanup_is_confirmed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []
            guest_attempts: list[int] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                # The complete immutable plan, including the delete identity,
                # must be on disk before even the first external effect.
                saved = bench.parsed_object((journal.directory / "manifest.json").read_text())
                assert entry["delete_request_id"] in json.dumps(saved)
                if command.startswith("new "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "ssh_host": "guest.example.test"},
                    }
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                    }
                if command.startswith("rm "):
                    return {"status": "succeeded", "result": {"id": VM_ID}}
                raise AssertionError("unexpected control request")

            def guest(argv: list[str], _seconds: int) -> str:
                self.assertIn("StrictHostKeyChecking=yes", argv)
                self.assertIn("BatchMode=yes", argv)
                self.assertEqual(argv[argv.index("-F") + 1], str(config.guest_ssh_config))
                if argv[-1] == "cat /proc/sys/kernel/random/boot_id":
                    return VM_ID + "\n"
                self.assertEqual(argv[-1], "ls")
                guest_attempts.append(len(guest_attempts))
                if len(guest_attempts) == 1:
                    raise TimeoutError("transient guest boot")
                return "fixture output that must never enter the journal"

            def placement(_config: bench.Configuration, _vm_id: str) -> dict[str, object]:
                return {
                    "host": "host-1",
                    "host_id": VM_ID,
                    "pool_id": VM_ID,
                    "placement_id": VM_ID,
                    "host_reported_at": "2026-09-28T12:00:00Z",
                    "cpu_headroom_millicores": "2000",
                    "pool_free_bytes": 1_000_000_000,
                }

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(bench, "invoke", side_effect=guest),
                patch.object(bench, "placement_snapshot", side_effect=placement),
                patch.object(bench, "host_load", return_value=(0.5, 0.25, 0.125)),
                patch.object(bench, "audit_phases", return_value=[]),
                patch.object(bench, "materialization_evidence", return_value=VERIFIED),
                patch.object(bench, "cleanup_confirmed", return_value=True),
                patch.object(bench.time, "sleep", return_value=None),
            ):
                elapsed = bench.run_one(config, journal, entry)
            self.assertGreaterEqual(elapsed.ssh_seconds, 0)
            self.assertEqual([command.split()[0] for command in commands], ["new", "show", "rm"])
            self.assertEqual(len(guest_attempts), 2)
            self.assertIn(entry["delete_request_id"], commands[-1])
            record = (journal.directory / "events.jsonl").read_text()
            self.assertIn("delete_confirmed", record)
            self.assertIn('"boot_id": "' + VM_ID + '"', record)
            self.assertIn('"host_load_1m": 0.5', record)
            self.assertNotIn("fixture output", record)

    def test_foreign_identity_never_reaches_delete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "ssh_host": "guest.example.test"},
                    }
                return {
                    "status": "succeeded",
                    "result": {"id": VM_ID, "name": "foreign-vm", "owner": False},
                }

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(
                    bench,
                    "placement_snapshot",
                    return_value={
                        "host": "host-1",
                        "host_id": VM_ID,
                        "pool_id": VM_ID,
                        "placement_id": VM_ID,
                        "host_reported_at": "2026-09-28T12:00:00Z",
                        "cpu_headroom_millicores": "2000",
                        "pool_free_bytes": 1_000_000_000,
                    },
                ),
                patch.object(bench, "invoke", return_value=""),
                patch.object(bench, "guest_boot_id", return_value=VM_ID),
                patch.object(bench, "host_load", return_value=(0.5, 0.25, 0.125)),
                patch.object(bench, "audit_phases", return_value=[]),
                patch.object(bench, "materialization_evidence", return_value=VERIFIED),
                self.assertRaisesRegex(RuntimeError, "ownership"),
            ):
                bench.run_one(config, journal, entry)
            self.assertEqual([command.split()[0] for command in commands], ["new", "show"])
            self.assertIn(
                entry["delete_request_id"], (journal.directory / "manifest.json").read_text()
            )

    def test_incompatible_baseline_stops_before_first_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline.json"
            baseline.write_text(
                json.dumps(
                    {
                        "mode": "baseline",
                        "images": {"nixos": IMAGE, "ubuntu": IMAGE},
                        "profile": "oss",
                        "cpu": 2,
                        "median_seconds": {"nixos": 20.0, "ubuntu": 25.0},
                    }
                )
            )
            config = replace(self.config(root / "run"), mode="enabled", baseline_summary=baseline)
            with self.assertRaisesRegex(ValueError, "conditions differ"):
                bench.run(config)
            self.assertFalse(config.output.exists())

    def test_enabled_without_baseline_stops_before_any_control_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = replace(self.config(Path(temporary) / "run"), mode="enabled")
            with (
                patch.object(bench, "control") as control,
                self.assertRaisesRegex(ValueError, "requires a baseline summary"),
            ):
                bench.run(config)
            control.assert_not_called()
            self.assertFalse(config.output.exists())

    def test_enabled_refuses_changed_nar_even_with_same_catalog_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = root / "baseline.json"
            config = replace(self.config(root / "run"), mode="enabled", baseline_summary=summary)
            summary.write_text(
                json.dumps(
                    {
                        "mode": "baseline",
                        "images": {"nixos": IMAGE, "ubuntu": IMAGE},
                        "profile": config.profile,
                        "cpu": config.cpu,
                        "median_seconds": {"nixos": 20.0, "ubuntu": 25.0},
                        "installed_nars": {
                            "nixos": "sha256:" + "a" * 52,
                            "ubuntu": "sha256:" + "b" * 52,
                        },
                    }
                )
            )
            with self.assertRaisesRegex(ValueError, "installed image NAR identities differ"):
                bench.baseline_medians(
                    config,
                    {
                        "nixos": "sha256:" + "a" * 52,
                        "ubuntu": "sha256:" + "c" * 52,
                    },
                )
            self.assertFalse(config.output.exists())

    def test_wrong_authenticated_guest_identity_stops_before_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                return {"status": "succeeded", "result": {"guest_username": "another.user"}}

            with (
                patch.object(bench, "control", side_effect=control),
                self.assertRaisesRegex(ValueError, "differs from authenticated Porsche identity"),
            ):
                bench.run(config)
            self.assertEqual(commands, ["whoami --json"])
            self.assertFalse(config.output.exists())

    def test_same_store_path_with_different_host_nar_refuses_before_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = replace(
                self.config(Path(temporary) / "run"), ubuntu_image="sha256:" + "b" * 64
            )
            nixos_path = "/nix/store/" + "a" * 32 + "-lilly-nixos-x86_64"
            ubuntu_path = "/nix/store/" + "b" * 32 + "-lilly-ubuntu-26.04-x86_64"

            def database(_config: bench.Configuration, sql: str) -> object:
                if "FROM compute_images" in sql:
                    return [
                        {
                            "id": config.nixos_image,
                            "enabled": True,
                            "name": "NixOS",
                            "manifest": ARTIFACTS,
                        },
                        {
                            "id": config.ubuntu_image,
                            "enabled": True,
                            "name": "Ubuntu 26.04 LTS",
                            "manifest": ARTIFACTS,
                        },
                    ]
                if "FROM compute_hosts" in sql:
                    return [
                        {
                            "name": host,
                            "fresh": True,
                            "images": [config.nixos_image, config.ubuntu_image],
                        }
                        for host in ("panterloons", "dungarees")
                    ]
                raise AssertionError("unexpected read-only query")

            def invoke(argv: list[str], _seconds: int) -> str:
                remote = argv[-1]
                if remote.startswith("sudo -n jq "):
                    if remote.endswith("/manifest.json"):
                        return json.dumps(ARTIFACTS)
                    return json.dumps(
                        {
                            "budgets": [0],
                            "images": [nixos_path, ubuntu_path],
                        }
                    )
                if remote.startswith("nix-store --query --hash "):
                    return (
                        "sha256:"
                        + (
                            "3"
                            if argv[-2] == config.admin_dungarees and ubuntu_path in remote
                            else "2"
                        )
                        * 52
                    )
                raise AssertionError("unexpected host read")

            with (
                patch.object(bench, "authenticated_guest_account"),
                patch.object(bench, "database", side_effect=database),
                patch.object(bench, "invoke", side_effect=invoke),
                patch.object(bench, "host_load", return_value=(0.5, 0.25, 0.125)),
                self.assertRaisesRegex(RuntimeError, "different benchmark image NAR"),
            ):
                bench.run(config)
            self.assertFalse(config.output.exists())

    def test_enabled_campaign_refuses_producers_off_before_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = root / "baseline.json"
            config = replace(
                self.config(root / "run"),
                mode="enabled",
                baseline_summary=summary,
                ubuntu_image="sha256:" + "b" * 64,
            )
            summary.write_text(
                json.dumps(
                    {
                        "mode": "baseline",
                        "images": {"nixos": config.nixos_image, "ubuntu": config.ubuntu_image},
                        "profile": config.profile,
                        "cpu": config.cpu,
                        "median_seconds": {"nixos": 20.0, "ubuntu": 25.0},
                    }
                )
            )

            def database(_config: bench.Configuration, sql: str) -> object:
                if "FROM compute_images" in sql:
                    return [
                        {
                            "id": config.nixos_image,
                            "enabled": True,
                            "name": "NixOS",
                            "manifest": ARTIFACTS,
                        },
                        {
                            "id": config.ubuntu_image,
                            "enabled": True,
                            "name": "Ubuntu 26.04 LTS",
                            "manifest": ARTIFACTS,
                        },
                    ]
                if "FROM compute_hosts" in sql:
                    return [
                        {
                            "name": host,
                            "fresh": True,
                            "images": [config.nixos_image, config.ubuntu_image],
                        }
                        for host in ("panterloons", "dungarees")
                    ]
                raise AssertionError("unexpected read-only query")

            def invoke(_argv: list[str], _seconds: int) -> str:
                return json.dumps({"budgets": [0], "images": []})

            with (
                patch.object(bench, "authenticated_guest_account"),
                patch.object(bench, "database", side_effect=database),
                patch.object(bench, "invoke", side_effect=invoke),
                self.assertRaisesRegex(ValueError, "producer mode"),
            ):
                bench.run(config)
            self.assertFalse(config.output.exists())

    def test_installed_manifest_must_match_selected_catalog_before_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = replace(
                self.config(Path(temporary) / "run"), ubuntu_image="sha256:" + "b" * 64
            )

            def database(_config: bench.Configuration, sql: str) -> object:
                if "FROM compute_images" in sql:
                    return [
                        {
                            "id": config.nixos_image,
                            "enabled": True,
                            "name": "NixOS",
                            "manifest": ARTIFACTS,
                        },
                        {
                            "id": config.ubuntu_image,
                            "enabled": True,
                            "name": "Ubuntu 26.04 LTS",
                            "manifest": ARTIFACTS,
                        },
                    ]
                return [
                    {
                        "name": host,
                        "fresh": True,
                        "images": [config.nixos_image, config.ubuntu_image],
                    }
                    for host in ("panterloons", "dungarees")
                ]

            def invoke(argv: list[str], _seconds: int) -> str:
                if argv[-1].endswith("/manifest.json"):
                    return json.dumps({**ARTIFACTS, "rootfs": {"sha256": "4" * 64, "bytes": 1234}})
                return json.dumps(
                    {
                        "budgets": [0],
                        "images": [
                            "/nix/store/" + "a" * 32 + "-lilly-nixos-x86_64",
                            "/nix/store/" + "b" * 32 + "-lilly-ubuntu-26.04-x86_64",
                        ],
                    }
                )

            with (
                patch.object(bench, "authenticated_guest_account"),
                patch.object(bench, "database", side_effect=database),
                patch.object(bench, "invoke", side_effect=invoke),
                self.assertRaisesRegex(ValueError, "installed manifest differs"),
            ):
                bench.run(config)
            self.assertFalse(config.output.exists())

    def test_uncertain_creation_keeps_original_identity_without_retry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []

            def timed_out(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                raise TimeoutError("outcome unknown")

            with (
                patch.object(bench, "control", side_effect=timed_out),
                patch.object(bench, "request_outcome", side_effect=TimeoutError("outcome unknown")),
                patch.object(bench, "database", return_value=None),
                self.assertRaisesRegex(TimeoutError, "unknown"),
            ):
                bench.run_one(config, journal, entry)
            self.assertEqual(len(commands), 1)
            self.assertIn(entry["create_request_id"], commands[0])
            self.assertIn(
                entry["delete_request_id"], (journal.directory / "manifest.json").read_text()
            )

    def test_failed_create_uses_planned_deletion_after_exact_request_and_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []
            reads: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    raise RuntimeError("failed create")
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                    }
                if command.startswith("rm "):
                    return {"status": "succeeded", "result": {"id": VM_ID}}
                raise AssertionError("unexpected command")

            def database(_config: bench.Configuration, query: str) -> object:
                reads.append(query)
                self.assertIn(entry["create_request_id"], query)
                return {"status": "failed", "vm_id": VM_ID}

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(bench, "request_outcome", side_effect=RuntimeError("request failed")),
                patch.object(bench, "database", side_effect=database),
                patch.object(bench, "cleanup_confirmed", return_value=True),
                self.assertRaisesRegex(RuntimeError, "request failed"),
            ):
                bench.run_one(config, journal, entry)
            self.assertEqual(len(reads), 1)
            self.assertEqual([command.split()[0] for command in commands], ["new", "show", "rm"])
            self.assertIn(entry["delete_request_id"], commands[-1])
            events = (journal.directory / "events.jsonl").read_text()
            self.assertIn("failed_create_bound", events)
            self.assertIn("delete_confirmed", events)

    def test_failed_create_never_deletes_without_terminal_request_and_current_owner(self) -> None:
        for status, owner in (("running", True), ("failed", False), ("succeeded", False)):
            with self.subTest(status=status, owner=owner), tempfile.TemporaryDirectory() as tmp:
                config = self.config(Path(tmp) / "run")
                journal = bench.Journal(config)
                entry = journal.entries[0]
                commands: list[str] = []

                def control(
                    _config: bench.Configuration,
                    command: str,
                    _seconds: int = 660,
                    *,
                    commands: list[str] = commands,
                    entry: bench.Entry = entry,
                    owner: bool = owner,
                ) -> bench.Receipt:
                    commands.append(command)
                    if command.startswith("new "):
                        raise RuntimeError("failed create")
                    if command.startswith("show "):
                        return {
                            "status": "succeeded",
                            "result": {"id": VM_ID, "name": entry["name"], "owner": owner},
                        }
                    raise AssertionError("unexpected mutation")

                with (
                    patch.object(bench, "control", side_effect=control),
                    patch.object(bench, "request_outcome", side_effect=RuntimeError("failed")),
                    patch.object(
                        bench, "database", return_value={"status": status, "vm_id": VM_ID}
                    ),
                    self.assertRaises(RuntimeError),
                ):
                    bench.run_one(config, journal, entry)
                self.assertEqual(
                    [command.split()[0] for command in commands],
                    ["new"] if status == "running" else ["new", "show"],
                )
                self.assertIn(
                    "cleanup_unconfirmed", (journal.directory / "events.jsonl").read_text()
                )

    def test_successful_create_with_bad_identity_uses_only_its_terminal_request(self) -> None:
        for identity in (None, "invalid-uuid"):
            with self.subTest(identity=identity), tempfile.TemporaryDirectory() as temporary:
                config = self.config(Path(temporary) / "run")
                journal = bench.Journal(config)
                entry = journal.entries[0]
                commands: list[str] = []

                def control(
                    _config: bench.Configuration,
                    command: str,
                    _seconds: int = 660,
                    *,
                    identity: str | None = identity,
                    entry: bench.Entry = entry,
                    commands: list[str] = commands,
                ) -> bench.Receipt:
                    commands.append(command)
                    if command.startswith("new "):
                        return {"status": "succeeded", "result": {"id": identity}}
                    if command.startswith("show "):
                        return {
                            "status": "succeeded",
                            "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                        }
                    if command.startswith("rm "):
                        return {"status": "succeeded", "result": {"id": VM_ID}}
                    raise AssertionError("unexpected control request")

                with (
                    patch.object(bench, "control", side_effect=control),
                    patch.object(
                        bench, "database", return_value={"status": "succeeded", "vm_id": VM_ID}
                    ),
                    patch.object(bench, "cleanup_confirmed", return_value=True),
                    self.assertRaisesRegex(ValueError, "identity|UUID"),
                ):
                    bench.run_one(config, journal, entry)
                self.assertEqual(
                    [command.split()[0] for command in commands], ["new", "show", "rm"]
                )
                self.assertIn(entry["delete_request_id"], commands[-1])
                events = (journal.directory / "events.jsonl").read_text()
                self.assertIn("succeeded_create_bound", events)
                self.assertIn("delete_confirmed", events)
                self.assertNotIn("ssh_authenticated", events)

    def test_unreadable_success_reply_cleans_the_terminal_original_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    raise TimeoutError("lost reply")
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                    }
                if command.startswith("rm "):
                    return {"status": "succeeded", "result": {"id": VM_ID}}
                raise AssertionError("unexpected control request")

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(
                    bench, "request_outcome", side_effect=TimeoutError("read unavailable")
                ),
                patch.object(
                    bench, "database", return_value={"status": "succeeded", "vm_id": VM_ID}
                ),
                patch.object(bench, "cleanup_confirmed", return_value=True),
                self.assertRaisesRegex(TimeoutError, "read unavailable"),
            ):
                bench.run_one(config, journal, entry)
            self.assertEqual([command.split()[0] for command in commands], ["new", "show", "rm"])
            self.assertIn(entry["delete_request_id"], commands[-1])
            self.assertIn("delete_confirmed", (journal.directory / "events.jsonl").read_text())

    def test_lost_reply_resolves_same_id_then_cleans_up(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    raise TimeoutError("lost reply")
                if command.startswith("request show "):
                    self.assertIn(entry["create_request_id"], command)
                    return {"status": "succeeded", "result": {"id": VM_ID}}
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {
                            "id": VM_ID,
                            "name": entry["name"],
                            "owner": True,
                            "ssh_host": "guest.example.test",
                        },
                    }
                if command.startswith("rm "):
                    return {"status": "succeeded", "result": {"id": VM_ID}}
                raise AssertionError("unexpected control request")

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(
                    bench,
                    "placement_snapshot",
                    return_value={
                        "host": "host-1",
                        "host_id": VM_ID,
                        "pool_id": VM_ID,
                        "placement_id": VM_ID,
                    },
                ),
                patch.object(bench, "invoke", return_value=""),
                patch.object(bench, "guest_boot_id", return_value=VM_ID),
                patch.object(bench, "host_load", return_value=(0.5, 0.25, 0.125)),
                patch.object(bench, "audit_phases", return_value=[]),
                patch.object(bench, "materialization_evidence", return_value=VERIFIED),
                patch.object(bench, "cleanup_confirmed", return_value=True),
            ):
                bench.run_one(config, journal, entry)
            self.assertEqual(
                [command.split()[0] for command in commands],
                ["new", "request", "show", "show", "rm"],
            )
            self.assertIn("delete_confirmed", (journal.directory / "events.jsonl").read_text())

    def test_lost_delete_reply_uses_only_the_planned_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "ssh_host": "guest.example.test"},
                    }
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                    }
                if command.startswith("rm "):
                    raise TimeoutError("lost deletion reply")
                self.assertIn(entry["delete_request_id"], command)
                return {"status": "succeeded", "result": {"id": VM_ID}}

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(
                    bench,
                    "placement_snapshot",
                    return_value={
                        "host": "host-1",
                        "host_id": VM_ID,
                        "pool_id": VM_ID,
                        "placement_id": VM_ID,
                    },
                ),
                patch.object(bench, "invoke", return_value=""),
                patch.object(bench, "guest_boot_id", return_value=VM_ID),
                patch.object(bench, "host_load", return_value=(0.5, 0.25, 0.125)),
                patch.object(bench, "audit_phases", return_value=[]),
                patch.object(bench, "materialization_evidence", return_value=VERIFIED),
                patch.object(bench, "cleanup_confirmed", return_value=True),
                patch.object(
                    bench, "request_outcome", wraps=bench.request_outcome
                ) as original_read,
            ):
                bench.run_one(config, journal, entry)
            original_read.assert_called_once_with(config, entry["delete_request_id"], 1200)
            self.assertEqual(
                [command.split()[0] for command in commands],
                ["new", "show", "rm", "request"],
            )
            self.assertIn(
                "delete_reply_uncertain", (journal.directory / "events.jsonl").read_text()
            )

    def test_invalid_boot_identity_is_not_counted_but_owned_vm_is_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            journal = bench.Journal(config)
            entry = journal.entries[0]
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "ssh_host": "guest.example.test"},
                    }
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                    }
                assert command.startswith("rm ")
                return {"status": "succeeded", "result": {"id": VM_ID}}

            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(bench, "invoke", return_value=""),
                patch.object(bench, "guest_boot_id", side_effect=ValueError("invalid boot")),
                patch.object(bench, "cleanup_confirmed", return_value=True),
                self.assertRaisesRegex(ValueError, "invalid boot"),
            ):
                bench.run_one(config, journal, entry)
            self.assertEqual([command.split()[0] for command in commands], ["new", "show", "rm"])
            events = (journal.directory / "events.jsonl").read_text()
            self.assertIn("delete_confirmed", events)
            self.assertNotIn("guest_boot_observed", events)

    def test_host_load_requires_selected_physical_host_and_finite_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")

            def load(argv: list[str], _seconds: int) -> str:
                self.assertIn("ghuntley@198.51.100.35", argv)
                self.assertEqual(argv[argv.index("-F") + 1], "/dev/null")
                self.assertEqual(argv[-1], "cat /proc/loadavg")
                return "0.12 0.34 0.56 1/10 123\n"

            with patch.object(bench, "invoke", side_effect=load):
                self.assertEqual(bench.host_load(config, "dungarees"), (0.12, 0.34, 0.56))
            with (
                patch.object(bench, "invoke", return_value="nan 0.34 0.56 1/10 123"),
                self.assertRaisesRegex(ValueError, "invalid"),
            ):
                bench.host_load(config, "dungarees")
            with self.assertRaisesRegex(ValueError, "unknown physical host"):
                bench.host_load(config, "foreign-host")

    def test_guest_ssh_uses_only_its_explicit_installed_profile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            guest = bench.guest_ssh_argv(config, "v-guest.apps.ghuntley.dev")
            self.assertEqual(guest[guest.index("-F") + 1], str(config.guest_ssh_config))
            self.assertIn("StrictHostKeyChecking=yes", guest)
            self.assertEqual(guest[-1], "testuser@v-guest.apps.ghuntley.dev")
            control = bench.ssh_argv(config.control_key, config.control_known_hosts, 22, "server")
            self.assertEqual(control[control.index("-F") + 1], "/dev/null")

    def test_native_method_uses_only_matching_catalogue_event(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            lines = [
                "incidental host log that must not become evidence",
                json.dumps(
                    {
                        "metadata": {
                            "event": "vm.image_materialized",
                            "placement_id": "22222222-2222-4222-8222-222222222222",
                            "method": "copy",
                            "source": "verified",
                        }
                    }
                ),
                json.dumps(
                    {
                        "metadata": {
                            "event": "vm.image_materialized",
                            "placement_id": VM_ID,
                            "method": "reflink",
                            "source": "verified",
                        }
                    }
                ),
            ]

            def journal_read(argv: list[str], _seconds: int) -> str:
                self.assertIn("ghuntley@198.51.100.35", argv)
                self.assertIn("sudo -n journalctl", argv[-1])
                return "\n".join(lines)

            with patch.object(bench, "invoke", side_effect=journal_read):
                observed = bench.materialization_evidence(config, "dungarees", VM_ID, 1_000_000.0)
            self.assertEqual(observed, VERIFIED)

    def test_offload_method_is_closed_evidence_and_unknown_methods_refuse(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            event = {
                "metadata": {
                    "event": "vm.image_materialized",
                    "placement_id": VM_ID,
                    "method": "offload",
                    "source": "verified",
                }
            }
            with patch.object(bench, "invoke", return_value=json.dumps(event)):
                observed = bench.materialization_evidence(config, "dungarees", VM_ID, 1_000_000.0)
            self.assertEqual(observed["method"], "offload")
            event["metadata"]["method"] = "dedupe"
            with (
                patch.object(bench, "invoke", return_value=json.dumps(event)),
                self.assertRaisesRegex(ValueError, "closed method or source"),
            ):
                bench.materialization_evidence(config, "dungarees", VM_ID, 1_000_000.0)

    def test_template_event_binds_exact_native_record_and_refuses_ambiguity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            event = {
                "metadata": {
                    "event": "vm.image_materialized",
                    "placement_id": VM_ID,
                    "method": "reflink",
                    "source": "template",
                    "template_record_id": TEMPLATE_RECORD,
                    "template_incarnation": TEMPLATE_INCARNATION,
                }
            }
            with patch.object(bench, "invoke", return_value=json.dumps(event)):
                observed = bench.materialization_evidence(config, "dungarees", VM_ID, 1_000_000.0)
            self.assertEqual(observed["template_record_id"], TEMPLATE_RECORD)
            self.assertEqual(observed["template_incarnation"], TEMPLATE_INCARNATION)
            with (
                patch.object(bench, "invoke", return_value="\n".join([json.dumps(event)] * 2)),
                self.assertRaisesRegex(ValueError, "exactly one"),
            ):
                bench.materialization_evidence(config, "dungarees", VM_ID, 1_000_000.0)
            del event["metadata"]["template_record_id"]
            with (
                patch.object(bench, "invoke", return_value=json.dumps(event)),
                self.assertRaisesRegex(ValueError, "lacks its native record"),
            ):
                bench.materialization_evidence(config, "dungarees", VM_ID, 1_000_000.0)

    def test_template_cost_requires_exact_host_local_binding_and_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = self.config(Path(temporary) / "run")
            ready = 1_790_647_200_000_000
            events = [
                {
                    "metadata": {
                        "event": "lilly.lifecycle_transition_committed",
                        "host_id": VM_ID,
                        "pool_id": TEMPLATE_INCARNATION,
                        "resource_type": "image_template",
                        "resource_id": TEMPLATE_RECORD,
                        "next_state": state,
                        "occurred_at": moment,
                    }
                }
                for state, moment in (("staging", ready - 124_500), ("ready", ready))
            ]
            raw = "\n".join(json.dumps(event) for event in events)
            with (
                patch.object(bench, "invoke", return_value=raw) as invocation,
                patch.object(
                    bench, "database", side_effect=AssertionError("retired diagnostic DB")
                ),
            ):
                duration, ready_unix = bench.template_construction(
                    config, "dungarees", VM_ID, TEMPLATE_INCARNATION, TEMPLATE_RECORD
                )
            self.assertIn("--grep=" + TEMPLATE_RECORD, invocation.call_args.args[0][-1])
            self.assertEqual(duration, 124.5)
            self.assertEqual(ready_unix, 1_790_647_200.0)
            for invalid in (
                raw + "\n" + json.dumps(events[0]),
                "",
                raw.replace(VM_ID, TEMPLATE_RECORD),
            ):
                with (
                    patch.object(bench, "invoke", return_value=invalid),
                    self.assertRaises(ValueError),
                ):
                    bench.template_construction(
                        config, "dungarees", VM_ID, TEMPLATE_INCARNATION, TEMPLATE_RECORD
                    )

    def test_enabled_warm_sample_requires_preexisting_native_template(self) -> None:
        for ready_before_start in (True, False):
            with self.subTest(ready_before_start=ready_before_start):
                self._exercise_enabled_sample(ready_before_start)

    def _exercise_enabled_sample(self, ready_before_start: bool) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = replace(self.config(Path(temporary) / "run"), mode="enabled")
            journal = bench.Journal(config)
            entry = next(row for row in journal.entries if row["stage"] == "sequential")
            commands: list[str] = []

            def control(
                _config: bench.Configuration, command: str, _seconds: int = 660
            ) -> bench.Receipt:
                commands.append(command)
                if command.startswith("new "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "ssh_host": "guest.example.test"},
                    }
                if command.startswith("show "):
                    return {
                        "status": "succeeded",
                        "result": {"id": VM_ID, "name": entry["name"], "owner": True},
                    }
                assert command.startswith("rm ")
                return {"status": "succeeded", "result": {"id": VM_ID}}

            native = bench.NativeEvidence(
                method="reflink",
                source="template",
                template_record_id=TEMPLATE_RECORD,
                template_incarnation=TEMPLATE_INCARNATION,
            )
            with (
                patch.object(bench, "control", side_effect=control),
                patch.object(bench, "invoke", return_value=""),
                patch.object(bench, "guest_boot_id", return_value=VM_ID),
                patch.object(bench, "host_load", return_value=(0.5, 0.25, 0.125)),
                patch.object(
                    bench,
                    "placement_snapshot",
                    return_value={
                        "host": "panterloons",
                        "host_id": VM_ID,
                        "pool_id": VM_ID,
                        "placement_id": VM_ID,
                    },
                ),
                patch.object(bench, "materialization_evidence", return_value=native),
                patch.object(
                    bench,
                    "template_construction",
                    return_value=(
                        200.0,
                        time.time() - 120 if ready_before_start else time.time(),
                    ),
                ),
                patch.object(bench, "audit_phases", return_value=[]),
                patch.object(bench, "cleanup_confirmed", return_value=True),
            ):
                if ready_before_start:
                    sample = bench.run_one(config, journal, entry)
                    self.assertEqual(sample.template_record_id, TEMPLATE_RECORD)
                    self.assertEqual(sample.template_construction_ms, 200.0)
                else:
                    with self.assertRaisesRegex(ValueError, "built during a warm sample"):
                        bench.run_one(config, journal, entry)
            self.assertEqual([command.split()[0] for command in commands], ["new", "show", "rm"])
            self.assertIn("delete_confirmed", (journal.directory / "events.jsonl").read_text())


if __name__ == "__main__":
    unittest.main()
