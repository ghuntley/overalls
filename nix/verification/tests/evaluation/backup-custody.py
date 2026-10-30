"""Backup password custody: key ceremony, exact wedge label and restore-decrypt composition.

Disposable synthetic fixtures only: real restic/SOPS/age/ssh processes against a
local file repository. No systemd, S3, ZFS, PostgreSQL or production authority.
"""

from __future__ import annotations

import contextlib
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Generator
from pathlib import Path
from typing import TypedDict

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
from schema import (  # ty: ignore[unresolved-import] # argv[1] Nix backups module
    JSON,
    Config,
    boolean,
    integer,
    object_value,
    string,
    strings,
)

MODULES = Path(sys.argv.pop(1)).resolve()
SECRETS_CLI = Path(sys.argv.pop(1)).resolve()
RESTIC = Path(sys.argv.pop(1)).resolve()

SAFE_FAILURE = b"Backup operation failed; inspect backup status and recovery guidance.\n"
DECRYPT_REFUSAL = b"Cryptographic operation failed; check the identity and document."
DOCUMENT = "secrets/fixture-backup.enc.json"


def rows(value: object) -> list[dict[str, JSON]]:
    if not isinstance(value, list):
        raise AssertionError("expected JSON array")
    return [object_value(item) for item in value]


class ManifestUser(TypedDict):
    sshKeys: list[str]
    secretRecovery: bool


class Fixture:
    """@cc [owner:ghuntley,label:verification] backup-custody-fixture-boundary
    Every operation MUST run inside one disposable mode-0700 tree: repository,
    password files, public checkout, recovery output and private identities.
    Repository-access expectations MUST derive from the fixture's own password
    and identity custody, never from inspecting the implementation under test.
    """

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.repository = self.root / "repository"
        self.source = self.root / "source"
        self.state = self.root / "state"
        self.checkout = self.root / "checkout"
        self.private = self.root / "private"
        self.runtime = self.root / "runtime"
        for directory in (
            self.repository,
            self.source,
            self.state,
            self.checkout,
            self.private,
            self.runtime,
            self.checkout / "secrets",
        ):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.tool_env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.runtime),
            "XDG_CONFIG_HOME": str(self.runtime),
            "XDG_DATA_HOME": str(self.runtime),
            "XDG_CACHE_HOME": str(self.runtime),
            "TMPDIR": str(self.runtime),
            "PYTHONDONTWRITEBYTECODE": "1",
            "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
            "LC_ALL": "C",
            "TZ": "UTC",
        }
        self.keys: dict[str, Path] = {}
        self.public: dict[str, str] = {}
        for name in ("recovery-a", "recovery-b", "fixture-host"):
            key = self.private / name
            self.capture(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
            self.keys[name] = key
            self.public[name] = key.with_suffix(".pub").read_text().strip()
        self.passwords = {
            generation: "fixture-password-" + secrets.token_hex(16)
            for generation in ("first", "second")
        }
        self.access_id = "fixture-access-" + secrets.token_hex(8)
        self.access_secret = "fixture-secret-" + secrets.token_hex(8)
        self.password = self.private / "password"
        self.publish_password("first")
        self.users: dict[str, ManifestUser] = {
            "recovery-a": ManifestUser(sshKeys=[self.public["recovery-a"]], secretRecovery=True)
        }
        self.manifest = self.private / "manifest.json"
        self.write_manifest()
        self.config = Config(
            hostname="fixture",
            repository=str(self.repository),
            region="test",
            password_file=str(self.password),
            cache_directory=str(self.root / "cache"),
            state_directory=str(self.state),
            revision="custody-fixture",
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
        self.descriptor = self.private / "config.json"
        self.restic(["init"])
        self.seal("first")

    def sealed_values(self) -> list[bytes]:
        return [
            value.encode()
            for value in (
                *self.passwords.values(),
                self.access_id,
                self.access_secret,
            )
        ] + [self.public[name].encode().split()[1] for name in self.public]

    def capture(self, args: list[str]) -> subprocess.CompletedProcess[bytes]:
        result = subprocess.run(args, capture_output=True, env=self.tool_env, timeout=60)
        if result.returncode != 0:
            raise AssertionError(f"fixture command {args[0]} failed")
        return result

    def publish_password(self, generation: str) -> None:
        self.password.write_text(self.passwords[generation] + "\n")
        self.password.chmod(0o600)

    def write_manifest(self) -> None:
        self.manifest.write_text(
            json.dumps(
                {
                    "users": self.users,
                    "inventory": {
                        "hosts": {"fixture-host": {"sshKeys": [self.public["fixture-host"]]}},
                        "documents": {
                            "fixture-backup": {"path": DOCUMENT, "hosts": ["fixture-host"]}
                        },
                    },
                }
            )
        )

    def payload(self, generation: str) -> dict[str, str]:
        return {
            "RESTIC_PASSWORD": self.passwords[generation],
            "AWS_ACCESS_KEY_ID": self.access_id,
            "AWS_SECRET_ACCESS_KEY": self.access_secret,
        }

    def seal(self, generation: str, replace: bool = False) -> bytes:
        """Seal the backup document through the real secrets CLI; return ciphertext."""
        source = self.private / f"input-{generation}"
        source.write_text(json.dumps(self.payload(generation)))
        source.chmod(0o600)
        arguments = ["encrypt", "fixture-backup", "--input", str(source)]
        if replace:
            arguments.append("--replace")
        result = self.secrets_cli(*arguments)
        if result.returncode != 0:
            raise AssertionError("fixture encryption failed")
        if self.secrets_cli("check").returncode != 0:
            raise AssertionError("fixture policy check failed")
        return self.document_path(self.checkout).read_bytes()

    def document_path(self, root: Path) -> Path:
        return root / DOCUMENT

    def secrets_cli(
        self, *args: str, root: Path | None = None
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [
                sys.executable,
                str(SECRETS_CLI),
                "--manifest",
                str(self.manifest),
                *args,
                "--root",
                str(root or self.checkout),
            ],
            capture_output=True,
            env=self.tool_env,
            timeout=60,
        )

    def decrypt(
        self, root: Path, identity: str, output: Path
    ) -> subprocess.CompletedProcess[bytes]:
        result = self.secrets_cli(
            "decrypt",
            "fixture-backup",
            "--ssh-key",
            str(self.keys[identity]),
            "--output",
            str(output),
            root=root,
        )
        combined = result.stdout + result.stderr
        if b"Traceback" in combined:
            raise AssertionError("decrypt printed a traceback")
        for value in self.sealed_values():
            if value in combined:
                raise AssertionError("decrypt printed sealed or identity material")
        return result

    def runtime_cli(self, operation: str, *args: str) -> subprocess.CompletedProcess[bytes]:
        self.descriptor.write_text(json.dumps(self.config))
        environment = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.root),
            "PYTHONDONTWRITEBYTECODE": "1",
            "RESTIC_REPOSITORY": str(self.repository),
            "RESTIC_PASSWORD_FILE": str(self.password),
            "RESTIC_CACHE_DIR": str(self.root / "cache"),
            "LC_ALL": "C",
            "TZ": "UTC",
        }
        result = subprocess.run(
            [
                sys.executable,
                str(MODULES / "runtime.py"),
                str(self.descriptor),
                operation,
                *args,
            ],
            capture_output=True,
            env=environment,
            timeout=120,
        )
        combined = result.stdout + result.stderr
        if b"Traceback" in combined:
            raise AssertionError("backup runtime printed a traceback")
        for value in self.sealed_values():
            if value in combined:
                raise AssertionError("backup runtime printed sealed material")
        return result

    def restic(
        self,
        args: list[str],
        password_file: Path | None = None,
        ok: bool = True,
    ) -> subprocess.CompletedProcess[bytes]:
        environment = {
            "PATH": self.tool_env["PATH"],
            "HOME": str(self.root),
            "RESTIC_REPOSITORY": str(self.repository),
            "RESTIC_PASSWORD_FILE": str(password_file or self.password),
            "RESTIC_CACHE_DIR": str(self.root / "cache"),
            "LC_ALL": "C",
            "TZ": "UTC",
        }
        result = subprocess.run(
            [str(RESTIC), *args], capture_output=True, env=environment, timeout=60
        )
        if ok and result.returncode != 0:
            raise AssertionError(f"fixture restic {args[0]} failed")
        return result

    def status(self) -> dict[str, JSON]:
        return object_value(json.loads((self.state / "status.json").read_bytes()))

    def point_ids(self, password_file: Path | None = None) -> set[str]:
        result = self.restic(["snapshots", "--json", "--host", "fixture"], password_file)
        return {string(row["id"]) for row in rows(json.loads(result.stdout))}

    def key_ids(self) -> tuple[set[str], str]:
        entries = rows(json.loads(self.restic(["key", "list", "--json"]).stdout))
        current = [string(entry["id"]) for entry in entries if boolean(entry["current"])]
        others = {string(entry["id"]) for entry in entries if not boolean(entry["current"])}
        if len(current) != 1 or len(entries) != len(current) + len(others):
            raise AssertionError("fixture key inventory is not exactly one current key")
        return others, current[0]

    def turnover(self) -> None:
        """Documented two-generation turnover of recovery-a to recovery-b."""
        self.users["recovery-b"] = ManifestUser(
            sshKeys=[self.public["recovery-b"]], secretRecovery=True
        )
        self.write_manifest()
        joined = self.secrets_cli("rekey", "--ssh-key", str(self.keys["recovery-a"]))
        if joined.returncode != 0:
            raise AssertionError("fixture settle rekey failed")
        self.users = {"recovery-b": self.users["recovery-b"]}
        self.write_manifest()
        retired = self.secrets_cli("rekey", "--ssh-key", str(self.keys["recovery-b"]))
        if retired.returncode != 0:
            raise AssertionError("fixture retirement rekey failed")
        if self.secrets_cli("check").returncode != 0:
            raise AssertionError("fixture turnover left drift")


@contextlib.contextmanager
def fixture() -> Generator[Fixture]:
    with tempfile.TemporaryDirectory(prefix="overalls-backup-custody-") as temporary:
        root = Path(temporary)
        try:
            yield Fixture(root)
        finally:
            shutil.rmtree(root)
            if root.exists():
                raise AssertionError("custody fixture survived cleanup")


class Custody(unittest.TestCase):
    def refused_runtime(self, result: subprocess.CompletedProcess[bytes]) -> None:
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, SAFE_FAILURE)

    def test_ceremony_overlap_never_wedges_scheduled_operations(self) -> None:
        with fixture() as f:
            self.assertEqual(f.runtime_cli("backup").returncode, 0)
            observations: list[dict[str, JSON]] = []

            def observe() -> None:
                observations.append(f.status())

            second = f.private / "candidate-password"
            second.write_text(f.passwords["second"] + "\n")
            second.chmod(0o600)
            # Step 1: add the new password while the published value is still old.
            f.restic(["key", "add", "--new-password-file", str(second)])
            self.assertEqual(f.runtime_cli("check").returncode, 0)
            observe()
            # Step 2: rotate the document value and deploy (password file swap).
            f.seal("second", replace=True)
            f.publish_password("second")
            self.assertEqual(f.runtime_cli("check").returncode, 0)
            self.assertEqual(f.runtime_cli("backup").returncode, 0)
            observe()
            # Step 3: retire the old key while authenticating with the new password.
            old_ids, _current = f.key_ids()
            self.assertEqual(len(old_ids), 1)
            f.restic(["key", "remove", next(iter(old_ids))])
            deprecated = f.private / "deprecated-password"
            deprecated.write_text(f.passwords["first"] + "\n")
            deprecated.chmod(0o600)
            self.assertNotEqual(f.restic(["cat", "config"], deprecated, ok=False).returncode, 0)
            self.assertEqual(f.runtime_cli("check").returncode, 0)
            self.assertEqual(f.runtime_cli("backup").returncode, 0)
            observe()
            for status in observations:
                self.assertEqual(status["state"], "healthy")
                self.assertEqual(status["failure"], "none")
            self.assertTrue(f.point_ids())

    def test_rotation_without_ceremony_wedges_with_repository_failure_label(self) -> None:
        with fixture() as f:
            self.assertEqual(f.runtime_cli("backup").returncode, 0)
            points = f.point_ids()
            previous = f.private / "previous-password"
            previous.write_text(f.passwords["first"] + "\n")
            previous.chmod(0o600)
            succeeded_at = integer(f.status()["last_success_at"])
            historical = f.document_path(f.checkout).read_bytes()
            # Rotate the document value and deploy it WITHOUT the key ceremony.
            f.seal("second", replace=True)
            f.publish_password("second")
            result = f.runtime_cli("backup")
            self.refused_runtime(result)
            journal = object_value(json.loads((f.state / "run.json").read_bytes()))
            self.assertEqual(string(journal["phase"]), "failed")
            self.assertEqual(rows(journal["components"]), [])
            self.assertEqual(strings(journal["failures"]), ["repository"])
            self.assertEqual(journal["manifest_id"], None)
            self.assertTrue(boolean(journal["cleanup_confirmed"]))
            # Every repository-mediated operation wedges with the same label; the
            # repository inventory is untouched and the last success is preserved.
            for operation in ("check", "list"):
                self.refused_runtime(f.runtime_cli(operation))
                status = f.status()
                self.assertEqual(string(status["state"]), "failed")
                self.assertEqual(string(status["failure"]), "repository")
                self.assertEqual(integer(status["last_success_at"]), succeeded_at)
                self.assertEqual(f.point_ids(previous), points)
            # Recovery through the previous generation, exactly as documented:
            # decrypt the historical ciphertext, then adopt the published value.
            recovered_root = f.root / "previous-generation"
            recovered_root.mkdir(mode=0o700)
            (recovered_root / "secrets").mkdir(mode=0o700)
            f.document_path(recovered_root).write_bytes(historical)
            f.document_path(recovered_root).chmod(0o600)
            step = f.private / "old-recovered.json"
            decrypt = f.decrypt(recovered_root, "recovery-a", step)
            self.assertEqual(decrypt.returncode, 0)
            self.assertEqual(decrypt.stdout, b"Document operation completed.\n")
            recovered = object_value(json.loads(step.read_bytes()))
            self.assertEqual(recovered, f.payload("first"))
            previous_password = f.private / "historical-password"
            previous_password.write_text(string(recovered["RESTIC_PASSWORD"]) + "\n")
            previous_password.chmod(0o600)
            f.restic(
                ["key", "passwd", "--new-password-file", str(f.password)],
                password_file=previous_password,
            )
            self.assertEqual(f.runtime_cli("check").returncode, 0)
            self.assertEqual(f.runtime_cli("backup").returncode, 0)
            status = f.status()
            self.assertEqual(string(status["state"]), "healthy")
            self.assertEqual(string(status["failure"]), "none")
            self.assertNotEqual(
                f.restic(["cat", "config"], previous_password, ok=False).returncode, 0
            )
            self.assertTrue(points < f.point_ids())

    def test_restored_ciphertext_decryption_recovers_repository_access(self) -> None:
        with fixture() as f:
            # Capture the materialized ciphertext with the real managed backup.
            source = f.document_path(f.checkout)
            f.config["materialize"] = [str(source)]
            self.assertEqual(f.runtime_cli("backup").returncode, 0)
            listed = rows(json.loads(f.runtime_cli("list").stdout))
            self.assertEqual(len(listed), 1)
            point = string(listed[0]["id"])
            target = f.root / "restore"
            self.assertEqual(
                f.runtime_cli("restore", "--snapshot", point, "--target", str(target)).returncode,
                0,
            )
            tables = list((target / "0").rglob("paths.json"))
            self.assertEqual(len(tables), 1)
            mappings = rows(object_value(json.loads(tables[0].read_bytes()))["paths"])
            found = [entry for entry in mappings if string(entry["original"]) == str(source)]
            self.assertEqual(len(found), 1)
            self.assertEqual(string(found[0]["filesystem"]), "artifact")
            restored = (target / "0") / string(found[0]["source"]).lstrip("/")
            self.assertEqual(restored.read_bytes(), source.read_bytes())
            # Decrypt the restored bytes with the recovery identity and open the
            # repository with exactly the recovered password value.
            recovery_checkout = f.root / "recovery-checkout"
            recovery_checkout.mkdir(mode=0o700)
            (recovery_checkout / "secrets").mkdir(mode=0o700)
            f.document_path(recovery_checkout).write_bytes(restored.read_bytes())
            f.document_path(recovery_checkout).chmod(0o600)
            recovered_json = f.private / "recovered.json"
            result = f.decrypt(recovery_checkout, "recovery-a", recovered_json)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"Document operation completed.\n")
            recovered = object_value(json.loads(recovered_json.read_bytes()))
            self.assertEqual(recovered, f.payload("first"))
            recovered_password = f.private / "recovered-password"
            recovered_password.write_text(string(recovered["RESTIC_PASSWORD"]) + "\n")
            recovered_password.chmod(0o600)
            self.assertEqual(f.restic(["cat", "config"], recovered_password).returncode, 0)
            self.assertEqual(f.point_ids(recovered_password), f.point_ids())
            # Historical-generation failure leg: after a complete documented
            # turnover, the pre-turnover ciphertext refuses the new identity
            # and publishes no output, while the retired identity still opens it.
            historical = source.read_bytes()
            f.turnover()
            historical_checkout = f.root / "historical-checkout"
            historical_checkout.mkdir(mode=0o700)
            (historical_checkout / "secrets").mkdir(mode=0o700)
            f.document_path(historical_checkout).write_bytes(historical)
            f.document_path(historical_checkout).chmod(0o600)
            refused_output = f.private / "refused.json"
            refused = f.decrypt(historical_checkout, "recovery-b", refused_output)
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(refused.stdout, b"")
            self.assertIn(DECRYPT_REFUSAL, refused.stderr)
            self.assertFalse(refused_output.exists())
            incumbent = f.private / "incumbent.json"
            self.assertEqual(f.decrypt(historical_checkout, "recovery-a", incumbent).returncode, 0)
            self.assertEqual(object_value(json.loads(incumbent.read_bytes())), f.payload("first"))
            current = f.private / "current.json"
            result = f.decrypt(f.checkout, "recovery-b", current)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(object_value(json.loads(current.read_bytes())), f.payload("first"))


if __name__ == "__main__":
    unittest.main()
