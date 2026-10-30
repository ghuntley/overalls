"""Public fleet policy and explicit local SOPS operations."""

import argparse
import base64
import contextlib
import fcntl
import getpass
import json
import os
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
from collections.abc import Generator
from pathlib import Path
from typing import NoReturn, TypedDict

import yaml

LIMIT = 16 * 1024 * 1024
NAME = re.compile(r"[a-z_][a-z0-9_-]{0,31}\Z")


class Failure(Exception):
    """Safe, non-secret operational failure."""


class User(TypedDict):
    keys: list[str]
    recipients: list[str]


class Document(TypedDict):
    path: str
    recipients: list[str]


def run(args: list[str], data: bytes | None = None, env: dict[str, str] | None = None) -> bytes:
    try:
        result = subprocess.run(
            args,
            input=data,
            stdin=subprocess.DEVNULL if data is None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise Failure("Cryptographic tool unavailable or timed out.") from None
    if result.returncode or len(result.stdout) > LIMIT:
        raise Failure("Cryptographic operation failed; check the identity and document.")
    return result.stdout


def public_recipient(key: str) -> str:
    if not isinstance(key, str) or "\n" in key or "\r" in key:
        raise Failure("Invalid public Ed25519 key.")
    parts = key.split()
    try:
        blob = base64.b64decode(parts[1], validate=True)
        if (
            parts[0] != "ssh-ed25519"
            or len(blob) != 51
            or blob[:19] != (struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32))
        ):
            raise ValueError()
    except (ValueError, IndexError):
        raise Failure("Invalid public Ed25519 key.") from None
    recipient = run(["ssh-to-age"], (" ".join(parts[:2]) + "\n").encode()).decode().strip()
    if not re.fullmatch(r"age1[0-9a-z]{58}", recipient):
        raise Failure("Public key conversion failed.")
    return recipient


def policy(raw: object) -> tuple[dict[str, User], list[str], dict[str, Document]]:
    if not isinstance(raw, dict):
        raise TypeError("invalid manifest object")
    users = raw["users"]
    inventory = raw["inventory"]
    if not isinstance(users, dict) or not isinstance(inventory, dict):
        raise TypeError("invalid manifest inventory")
    recovery: set[str] = set()
    public: dict[str, User] = {}
    for name, user in users.items():
        if not NAME.fullmatch(name) or name == "root":
            raise Failure("Invalid user name.")
        if not isinstance(user, dict):
            raise TypeError("invalid manifest user")
        keys = user.get("sshKeys", [])
        if user.get("admin", False) and not user.get("login", False):
            raise Failure("Administrators must have login enabled.")
        if (user.get("login", False) or user.get("secretRecovery", False)) and not keys:
            raise Failure("Login and recovery require public keys.")
        if not isinstance(keys, list) or any(not isinstance(key, str) for key in keys):
            raise TypeError("invalid manifest public keys")
        recipients = sorted({public_recipient(key) for key in keys})
        public[name] = User(keys=keys, recipients=recipients)
        if user.get("secretRecovery", False):
            recovery.update(recipients)
    host_entries = inventory["hosts"]
    document_entries = inventory["documents"]
    if not isinstance(host_entries, dict) or not isinstance(document_entries, dict):
        raise TypeError("invalid manifest inventory")
    hosts: dict[str, set[str]] = {}
    for name, host in host_entries.items():
        if not isinstance(host, dict):
            raise TypeError("invalid manifest host")
        keys = host["sshKeys"]
        if not NAME.fullmatch(name) or not keys:
            raise Failure("Hosts require valid names and authenticated public keys.")
        if not isinstance(keys, list) or any(not isinstance(key, str) for key in keys):
            raise Failure("Hosts require valid names and authenticated public keys.")
        hosts[name] = {public_recipient(key) for key in keys}
    documents: dict[str, Document] = {}
    paths: set[str] = set()
    for name, document in document_entries.items():
        if not isinstance(document, dict):
            raise TypeError("invalid manifest document")
        path = document["path"]
        document_hosts = document["hosts"]
        recovery_only = document.get("recoveryOnly", False)
        if (
            not NAME.fullmatch(name)
            or not isinstance(path, str)
            or not re.fullmatch(r"secrets/[a-zA-Z0-9_./-]+\.enc\.(json|yaml|yml)", path)
            or any(part in ("", ".", "..") for part in path.split("/"))
            or path in paths
            or not recovery
            or not isinstance(recovery_only, bool)
            or not isinstance(document_hosts, list)
            or (bool(document_hosts) == recovery_only)
        ):
            raise Failure(
                "Invalid document inventory; require unique paths, recovery users and either hosts or explicit recovery-only custody."
            )
        paths.add(path)
        recipients = set(recovery)
        for host in document_hosts:
            if not isinstance(host, str) or host not in hosts:
                raise Failure("Document references an unknown host.")
            recipients.update(hosts[host])
        documents[name] = Document(path=path, recipients=sorted(recipients))
    return public, sorted(recovery), documents


def read_regular(path: Path, private: bool = False) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(path, flags)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_size > LIMIT
                or (private and (info.st_uid != os.getuid() or info.st_mode & 0o077))
            ):
                raise Failure("Unsafe input file type, ownership, size or permissions.")
            data = stream.read(LIMIT + 1)
            if len(data) > LIMIT:
                raise Failure("Input exceeds size limit.")
            return data
    except OSError:
        raise Failure("Input file is missing or unsafe.") from None


def private_path(value: str) -> Path:
    path = Path(value).absolute()
    if path.resolve().is_relative_to("/nix/store"):
        raise Failure("Private material must remain outside the Nix store.")
    return path


def document_path(root: Path, relative: str) -> Path:
    path = root
    for component in relative.split("/"):
        path = path / component
        if path.is_symlink():
            raise Failure("Document paths must not contain symlinks.")
    if not path.parent.is_dir():
        raise Failure("Create the declared document directory before proceeding.")
    return path


def metadata(data: bytes, kind: str) -> list[str]:
    try:
        parsed: object = json.loads(data) if kind == "json" else yaml.safe_load(data)
        if not isinstance(parsed, dict):
            raise ValueError()
        meta = parsed["sops"]
        if not isinstance(meta, dict):
            raise ValueError()
        mac = meta.get("mac")
        if (
            not isinstance(meta.get("version"), str)
            or not isinstance(mac, str)
            or not mac.startswith("ENC[AES256_GCM,")
        ):
            raise ValueError()
        if any(
            meta.get(provider)
            for provider in (
                "kms",
                "gcp_kms",
                "azure_kv",
                "hc_vault",
                "pgp",
                "key_groups",
                "huawei_kms",
            )
        ):
            raise ValueError()
        entries = meta["age"]
        if not isinstance(entries, list):
            raise ValueError()
        recipients: list[str] = []
        for entry in entries:
            if not isinstance(entry, dict):
                raise TypeError()
            recipient = entry["recipient"]
            enc = entry.get("enc")
            if not isinstance(recipient, str) or not isinstance(enc, str):
                raise TypeError()
            if not enc.startswith("-----BEGIN AGE ENCRYPTED FILE-----"):
                raise ValueError()
            recipients.append(recipient)
        if not recipients or len(recipients) != len(set(recipients)):
            raise ValueError()
        if any(not re.fullmatch(r"age1[0-9a-z]{58}", key) for key in recipients):
            raise ValueError()
        return sorted(recipients)
    except (ValueError, KeyError, TypeError, yaml.YAMLError):
        raise Failure("Document must be a valid age-only SOPS JSON or YAML mapping.") from None


def clean_environment(work: Path) -> dict[str, str]:
    return {
        "PATH": os.environ["PATH"],
        "HOME": str(work),
        "XDG_CONFIG_HOME": str(work),
        "XDG_DATA_HOME": str(work),
        "XDG_CACHE_HOME": str(work),
        "SOPS_AGE_KEY_FILE": str(work / "identity"),
        "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
    }


def interrupt(*_: object) -> NoReturn:
    raise KeyboardInterrupt()


@contextlib.contextmanager
def identity(key_file: str, work: Path) -> Generator[tuple[dict[str, str], str]]:
    key = private_path(key_file)
    private = read_regular(key, private=True)
    # Copy the validated input so the converter never follows a swapped source.
    source = work / "operator.ssh"
    source.write_bytes(private)
    env = clean_environment(work)
    args = ["ssh-to-age", "-private-key", "-i", str(source)]
    try:
        try:
            converted = run(args, env=env)
        except Failure:
            if not sys.stdin.isatty():
                raise Failure(
                    "Identity conversion failed; encrypted keys require an interactive terminal."
                ) from None
            password = getpass.getpass("SSH key passphrase: ")
            converted = run([*args, "-stdinpass"], (password + "\n").encode(), env)
        target = work / "identity"
        target.write_bytes(converted)
        recipient = run(["age-keygen", "-y", str(target)], env=env).decode().strip()
        yield env, recipient
    finally:
        source.unlink(missing_ok=True)
        (work / "identity").unlink(missing_ok=True)


def decrypt(data: bytes, kind: str, env: dict[str, str]) -> bytes:
    metadata(data, kind)
    return run(
        ["sops", "--decrypt", "--input-type", kind, "--output-type", kind, "/dev/stdin"], data, env
    )


def publish(path: Path, data: bytes, original: bytes | None) -> None:
    """@cc [owner:ghuntley,label:security] atomic-secret-publication
    New documents MUST be created exclusively. Replacements MUST refuse a changed
    original and publish the fully prepared ciphertext with atomic replacement.
    """
    if original is None:
        if path.exists() or path.is_symlink():
            raise Failure("Output already exists.")
    elif read_regular(path) != original:
        raise Failure("Document changed concurrently; rerun reconciliation.")
    fd, temporary = tempfile.mkstemp(prefix=".overalls-sealed-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if original is None:
            os.link(temporary, path)  # Exclusive publication: never overwrite another writer.
        else:
            os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def reconcile(
    root: Path,
    documents: dict[str, Document],
    recovery: list[str],
    key_file: str,
    work: Path,
) -> None:
    candidates: list[tuple[str, Path, bytes, bytes]] = []
    with identity(key_file, work) as (env, recipient):
        if recipient not in recovery:
            raise Failure("Reconciliation requires a retained recovery identity.")
        for name, document in documents.items():
            path = document_path(root, document["path"])
            original = read_regular(path)
            kind = "json" if path.suffix == ".json" else "yaml"
            current = metadata(original, kind)
            if current == document["recipients"]:
                continue
            # Work only on ciphertext copies. Updating recipients then rotating
            # prevents removed keys from retaining the new document data key.
            before = decrypt(original, kind, env)
            staged = work / (name + "." + kind)
            staged.write_bytes(original)
            config = work / "sops.yaml"
            config.write_text(
                yaml.safe_dump(
                    {
                        "creation_rules": [
                            {
                                "path_regex": ".*",
                                "age": ",".join(document["recipients"]),
                            }
                        ]
                    }
                )
            )
            run(["sops", "--config", str(config), "updatekeys", "--yes", str(staged)], env=env)
            run(["sops", "rotate", "--in-place", str(staged)], env=env)
            sealed = read_regular(staged)
            if (
                metadata(sealed, kind) != document["recipients"]
                or decrypt(sealed, kind, env) != before
            ):
                raise Failure("Staged document validation failed.")
            candidates.append((name, path, original, sealed))
        # Preflight every original again before the first publication.
        for _, path, original, _ in candidates:
            if read_regular(path) != original:
                raise Failure("Document changed concurrently; nothing published.")
        published: list[str] = []
        pending: str | None = None
        try:
            for name, path, original, sealed in candidates:
                pending = name
                document_path(root, str(path.relative_to(root)))
                publish(path, sealed, original)
                published.append(name)
                pending = None
        except (OSError, Failure, KeyboardInterrupt):
            raise Failure(
                "Publication interrupted; completed documents: "
                + (", ".join(published) or "none")
                + "; possibly updated document: "
                + (pending or "none")
                + ". Rerun reconciliation."
            ) from None
    print(f"Reconciled {len(candidates)} document(s).")


def main() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser(prog="overalls-secrets", description=__doc__)
    parser.add_argument("--manifest", required=True, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    export = sub.add_parser("export", help="Write public recipient files.")
    export.add_argument("--output", required=True)
    for operation in ("check", "encrypt", "decrypt", "rekey"):
        command = sub.add_parser(operation)
        command.add_argument(
            "--root", default=".", help="Repository working directory (default: current directory)."
        )
        if operation in ("encrypt", "decrypt"):
            command.add_argument("name")
        if operation == "encrypt":
            command.add_argument("--input", required=True)
            command.add_argument(
                "--replace",
                action="store_true",
                help="atomically replace the existing encrypted document",
            )
        if operation == "decrypt":
            command.add_argument("--output", required=True)
        if operation in ("decrypt", "rekey"):
            command.add_argument("--ssh-key", required=True)
    args = parser.parse_args()
    raw: object = json.loads(Path(args.manifest).read_bytes())
    users, recovery, documents = policy(raw)
    if args.command == "export":
        output = Path(args.output)
        output.mkdir()
        (output / "manifest.json").write_text(json.dumps(raw, sort_keys=True) + "\n")
        (output / "recipients.json").write_text(
            json.dumps(
                {
                    "users": users,
                    "recovery": recovery,
                    "documents": documents,
                },
                sort_keys=True,
            )
            + "\n"
        )
        for name, user in users.items():
            (output / (name + ".pub")).write_text("\n".join(user["keys"]) + "\n")
            (output / (name + ".age")).write_text("\n".join(user["recipients"]) + "\n")
        return
    root = Path(args.root).resolve(strict=True)
    if args.command == "check":
        drift: list[str] = []
        for name, document in documents.items():
            path = document_path(root, document["path"])
            kind = "json" if path.suffix == ".json" else "yaml"
            if metadata(read_regular(path), kind) != document["recipients"]:
                drift.append(name)
        if drift:
            raise Failure("Recipient drift: " + ", ".join(drift))
        print(f"Checked {len(documents)} document(s).")
        return
    if args.command in ("decrypt", "rekey") and private_path(args.ssh_key).resolve().is_relative_to(
        root
    ):
        raise Failure("Private SSH identities must be outside the repository.")
    # Lock the directory itself: no generated lockfile enters the repository.
    with contextlib.ExitStack() as stack:
        lock = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        stack.callback(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="overalls-secrets-") as directory:
            work = Path(directory)
            if work.resolve().is_relative_to("/nix/store") or work.resolve().is_relative_to(root):
                raise Failure(
                    "Private runtime storage must be outside the repository and Nix store."
                )
            if args.command == "rekey":
                reconcile(root, documents, recovery, args.ssh_key, work)
                return
            if args.name not in documents:
                raise Failure("Unknown document name.")
            document = documents[args.name]
            path = document_path(root, document["path"])
            kind = "json" if path.suffix == ".json" else "yaml"
            if args.command == "encrypt":
                source = private_path(args.input)
                if source.resolve().is_relative_to(root):
                    raise Failure("Plaintext input must be outside the repository.")
                plaintext = read_regular(source, private=True)
                original = read_regular(path) if args.replace else None
                sealed = run(
                    [
                        "sops",
                        "--encrypt",
                        "--age",
                        ",".join(document["recipients"]),
                        "--input-type",
                        kind,
                        "--output-type",
                        kind,
                        "/dev/stdin",
                    ],
                    plaintext,
                    clean_environment(work),
                )
                if metadata(sealed, kind) != document["recipients"]:
                    raise Failure("Encryption recipient validation failed.")
                publish(path, sealed, original)
            else:
                with identity(args.ssh_key, work) as (env, _):
                    plaintext = decrypt(read_regular(path), kind, env)
                output = private_path(args.output)
                if output.resolve().is_relative_to(root):
                    raise Failure("Decrypted output must be outside the repository.")
                publish(output, plaintext, None)
    print("Document operation completed.")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt)
    try:
        main()
    except Failure as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError, KeyboardInterrupt):
        print("Secret operation failed; no private diagnostics emitted.", file=sys.stderr)
        sys.exit(1)
