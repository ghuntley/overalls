"""Runtime-only ACME fixture material and private verification helpers."""

import json
import os
import secrets
import socket
import ssl
import subprocess
import sys
import time
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import cast
from urllib.error import URLError
from urllib.request import urlopen

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from websockets.sync.client import connect
from websockets.typing import Origin

ROOT = Path("/run/overalls-test-acme")
PUBLIC = Path("/run/overalls-test-acme-public")
SOURCE = Path("/var/lib/acme/control.example.test/full.pem")
PUBLISHED = Path("/var/lib/overalls-certificates/marshall/full.pem")


def run(arguments: Sequence[str], input: bytes | None = None) -> bytes:
    result = subprocess.run(
        arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=30,
        input=input,
    )
    if result.returncode:
        raise ValueError("fixture command failed")
    return result.stdout


# @cc [owner:ghuntley,label:verification] acme-fixture-private-material
# DNS credentials and CA/private keys MUST be generated inside the VM, kept in
# private files and compared there; only public trust certificates may be shared.
def main() -> None:
    os.umask(0o077)
    action = sys.argv[1]
    if action == "setup-http":
        ROOT.mkdir(mode=0o700, exist_ok=True)
        PUBLIC.mkdir(mode=0o755, exist_ok=True)
        PUBLIC.chmod(0o755)
    elif action == "setup":
        ROOT.mkdir(mode=0o700)
        PUBLIC.mkdir(mode=0o755)
        PUBLIC.chmod(0o755)
        keys = {"access": "AKIA" + secrets.token_hex(8).upper(), "secret": secrets.token_hex(32)}
        (ROOT / "keys.json").write_text(json.dumps(keys))
        profile = f"[default]\naws_access_key_id = {keys['access']}\naws_secret_access_key = {keys['secret']}\n"
        host = run(["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"]).decode().strip()
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(ROOT / "recovery")])
        recovery = run(["ssh-to-age", "-i", str(ROOT / "recovery.pub")]).decode().strip()
        encrypted = run(
            [
                "sops",
                "--encrypt",
                "--age",
                host + "," + recovery,
                "--input-type",
                "json",
                "--output-type",
                "json",
                "/dev/stdin",
            ],
            input=json.dumps(
                {"overalls-route53": {"production": {"AWS_CREDENTIALS": profile}}}
            ).encode(),
        )
        (ROOT / "route53.enc.json").write_bytes(encrypted)
    elif action in ("trust", "trust-http"):
        issuer_ca = (
            PUBLIC / "issuer-ca.crt"
            if action == "trust-http"
            else Path("/run/overalls-test/ca.crt")
        )
        issuer = "control.example.test" if action == "trust-http" else "localhost"
        context = ssl.create_default_context(cafile=str(issuer_ca))
        deadline = time.monotonic() + 20
        while True:
            try:
                with urlopen(
                    f"https://{issuer}:15000/roots/0", context=context, timeout=2
                ) as response:
                    root = response.read()
                break
            except URLError as error:
                if isinstance(error.reason, ssl.SSLCertVerificationError):
                    print(
                        json.dumps(
                            {
                                "event": "fixture.ca_rejected",
                                "verify_code": error.reason.verify_code,
                            }
                        )
                    )
                    raise
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.1)
        x509.load_pem_x509_certificate(root)
        (PUBLIC / "trust.crt").write_bytes(
            Path("/run/overalls-test/ca.crt").read_bytes() + issuer_ca.read_bytes() + root
        )
        (PUBLIC / "trust.crt").chmod(0o644)
    elif action == "snapshot":
        (ROOT / "previous-published.pem").write_bytes(PUBLISHED.read_bytes())
        (ROOT / "previous-source.pem").write_bytes(SOURCE.read_bytes())
    elif action == "restore":
        SOURCE.write_bytes((ROOT / "previous-source.pem").read_bytes())
    elif action == "corrupt-cache":
        PUBLISHED.write_bytes(SOURCE.read_bytes())
    elif action == "restore-cache":
        PUBLISHED.write_bytes((ROOT / "previous-published.pem").read_bytes())
    elif action in ("reject-reload", "allow-reload"):
        override = Path("/run/systemd/system/haproxy.service.d/fixture.conf")
        if action == "reject-reload":
            override.parent.mkdir(parents=True, exist_ok=True)
            override.write_text(
                "[Service]\nExecReload=\nExecReload=/run/current-system/sw/bin/false\n"
            )
        else:
            override.unlink()
    elif action == "connection":
        context = ssl.create_default_context(cafile=str(PUBLIC / "trust.crt"))
        with connect(
            "wss://control.example.test/live/websocket?vsn=2.0.0",
            sock=socket.create_connection(("127.0.0.1", 443), timeout=5),
            ssl=context,
            origin=cast(Origin, "https://control.example.test"),  # Origin is a str NewType
            proxy=None,
            open_timeout=10,
        ) as connection:
            connection.send(json.dumps([None, "1", "phoenix", "heartbeat", {}]))
            assert json.loads(connection.recv(timeout=5)) == [
                None,
                "1",
                "phoenix",
                "phx_reply",
                {"response": {}, "status": "ok"},
            ]
            (ROOT / "connected").touch()
            deadline = time.monotonic() + 120
            while not (ROOT / "finish-connection").exists():
                if time.monotonic() > deadline:
                    raise ValueError("renewal did not finish")
                time.sleep(0.05)
            connection.send(json.dumps([None, "2", "phoenix", "heartbeat", {}]))
            assert json.loads(connection.recv(timeout=5)) == [
                None,
                "2",
                "phoenix",
                "phx_reply",
                {"response": {}, "status": "ok"},
            ]
            (ROOT / "connection-survived").touch()
    elif action in ("unchanged", "renewed", "reload-pending"):
        previous = x509.load_pem_x509_certificates((ROOT / "previous-published.pem").read_bytes())[
            0
        ]
        current = x509.load_pem_x509_certificates(PUBLISHED.read_bytes())[0]
        assert (previous.fingerprint(hashes.SHA256()) == current.fingerprint(hashes.SHA256())) == (
            action == "unchanged"
        )
        context = ssl.create_default_context(cafile=str(PUBLIC / "trust.crt"))
        with (
            socket.create_connection(("127.0.0.1", 443), timeout=5) as connection,
            context.wrap_socket(connection, server_hostname="control.example.test") as tls,
        ):
            expected = previous if action == "reload-pending" else current
            assert tls.getpeercert(binary_form=True) == expected.public_bytes(
                serialization.Encoding.DER
            )
    elif action == "invalid":
        kind = sys.argv[2]
        original = (ROOT / "previous-source.pem").read_bytes()
        # The fixture-generated PEM material is RSA.
        key = cast(rsa.RSAPrivateKey, serialization.load_pem_private_key(original, password=None))
        ca_key = cast(
            rsa.RSAPrivateKey,
            serialization.load_pem_private_key(
                Path("/run/overalls-test/ca.key").read_bytes(), password=None
            ),
        )
        ca = x509.load_pem_x509_certificate(Path("/run/overalls-test/ca.crt").read_bytes())
        signing = (
            rsa.generate_private_key(public_exponent=65537, key_size=2048)
            if kind == "untrusted"
            else ca_key
        )
        name = "wrong.example.test" if kind == "wrong-name" else "control.example.test"
        now = datetime.now(UTC)
        certificate = (
            x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)]))
            .issuer_name(ca.subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=2))
            .not_valid_after(now + timedelta(days=-1 if kind == "expired" else 2))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(name)]), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .sign(signing, hashes.SHA256())
        )
        if kind == "mismatched-key":
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        SOURCE.write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
            + certificate.public_bytes(serialization.Encoding.PEM)
        )
    elif action == "public-key":
        leaf = x509.load_pem_x509_certificates(PUBLISHED.read_bytes())[0]
        digest = hashes.Hash(hashes.SHA256())
        digest.update(
            leaf.public_key().public_bytes(
                serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
            )
        )
        print(digest.finalize().hex())
    elif action == "journal":
        keys: dict[str, str] = (
            json.loads((ROOT / "keys.json").read_text()) if (ROOT / "keys.json").exists() else {}
        )
        journal = run(["journalctl", "--no-pager", "--output=cat"])
        assert not any(value.encode() in journal for value in keys.values())
        assert b"BEGIN PRIVATE KEY" not in journal and b"BEGIN OPENSSH PRIVATE KEY" not in journal
    else:
        raise ValueError("unknown fixture action")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only the exception class, never its message: messages can carry
        # certificate, key or credential material. The class alone separates a
        # WebSocket opening-handshake TimeoutError from a TLS SSLError or an
        # assertion on the heartbeat reply.
        print(
            json.dumps({"event": "fixture.failed", "error": type(error).__name__}),
            file=sys.stderr,
        )
        sys.exit(1)
