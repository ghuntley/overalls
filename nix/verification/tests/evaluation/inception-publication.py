"""Bounded publication and real local verified-HTTPS transport fixtures."""

import base64
import contextlib
import copy
import http.client
import http.server
import importlib.util
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from collections.abc import Mapping
from pathlib import Path
from types import SimpleNamespace
from typing import TypedDict
from unittest.mock import patch

source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
SetupError = runtime.SetupError
encode = runtime.encode
publish = runtime.publish
settings_spec = importlib.util.spec_from_file_location(
    "public_settings", source / "public_settings.py"
)
if settings_spec is None or settings_spec.loader is None:
    raise RuntimeError("public settings helper unavailable")
public_settings = importlib.util.module_from_spec(settings_spec)
sys.modules["public_settings"] = public_settings
settings_spec.loader.exec_module(public_settings)
observations_spec = importlib.util.spec_from_file_location(
    "observations", source / "observations.py"
)
if observations_spec is None or observations_spec.loader is None:
    raise RuntimeError("observations helper unavailable")
observations = importlib.util.module_from_spec(observations_spec)
sys.modules["observations"] = observations
observations_spec.loader.exec_module(observations)
ingress_spec = importlib.util.spec_from_file_location("ingress", source / "ingress.py")
if ingress_spec is None or ingress_spec.loader is None:
    raise RuntimeError("ingress helper unavailable")
ingress = importlib.util.module_from_spec(ingress_spec)
sys.modules["ingress"] = ingress
ingress_spec.loader.exec_module(ingress)
publication_spec = importlib.util.spec_from_file_location("publication", source / "publication.py")
if publication_spec is None or publication_spec.loader is None:
    raise RuntimeError("publication helper unavailable")
publication = importlib.util.module_from_spec(publication_spec)
sys.modules["publication"] = publication
publication_spec.loader.exec_module(publication)

LABEL = "vm-" + "1" * 32
PROOF = base64.urlsafe_b64encode(bytes(32)).decode().rstrip("=")
KEY = (
    "ssh-ed25519 "
    + base64.b64encode(b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes(32)).decode()
)


class Boot(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


class Configuration(TypedDict):
    version: int
    binding: Boot
    generation: int
    origins: dict[str, str]


class Snapshot(TypedDict):
    version: int
    zone: str
    revision: int
    ttl: int
    routes: list[dict[str, object]]
    proofs: list[dict[str, object]]


class HandlerState(TypedDict):
    status: int
    body: bytes
    requests: list[tuple[str, str | None, object]]
    block: bool


class PublicationTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        roots = self.root / "system-roots.pem"
        roots.write_bytes(b"test roots")
        image = self.root / "image.json"
        image.write_text(json.dumps({"system_ca": str(roots)}))
        configured_image = patch.object(ingress, "PUBLIC_CONFIG", image)
        configured_image.start()
        self.addCleanup(configured_image.stop)
        self.boot: Boot = {
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "boot_challenge": "a" * 64,
        }
        namespace = "dev-" + "2" * 32 + ".inception.apps.example"
        self.config: Configuration = {
            "version": 1,
            "binding": self.boot,
            "generation": 1,
            "origins": {
                "namespace": namespace,
                "control": "control." + namespace,
                "apps": "apps." + namespace,
            },
        }
        self.snapshot: Snapshot = {
            "version": 1,
            "zone": self.config["origins"]["apps"],
            "revision": 1,
            "ttl": 5000,
            "routes": [{"label": LABEL, "addresses": ["192.0.2.37"], "ttl": 4000}],
            "proofs": [{"label": LABEL, "proofs": [PROOF], "ttl": 2000}],
        }

    def test_records_combine_without_child_addresses_and_keep_original_expiry(self) -> None:
        records, expiry = publication.records(self.snapshot, self.snapshot["zone"], 1000, 1100)
        self.assertEqual(expiry, 3000)
        self.assertEqual(records, [{"label": LABEL, "ready": True, "proofs": [PROOF]}])
        records, expiry = publication.records(self.snapshot, self.snapshot["zone"], 1000, 3000)
        self.assertEqual(records, [{"label": LABEL, "ready": True, "proofs": []}])
        self.assertEqual(expiry, 5000)
        with self.assertRaises(SetupError):
            publication.records(self.snapshot, self.snapshot["zone"], 1000, 6000)

    def test_apps_apex_can_publish_wildcard_proof_but_never_a_route(self) -> None:
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["proofs"] = [{"label": "", "proofs": [PROOF], "ttl": 2000}]
        records, expiry = publication.records(snapshot, snapshot["zone"], 1000, 1100)
        self.assertEqual(expiry, 3000)
        self.assertEqual(records[0], {"label": "", "ready": False, "proofs": [PROOF]})
        snapshot["routes"] = [{"label": "", "addresses": ["192.0.2.37"], "ttl": 4000}]
        with self.assertRaises(SetupError):
            publication.records(snapshot, snapshot["zone"], 1000, 1100)

    def test_closed_snapshot_rejects_recursion_overflow_and_non_ipv4(self) -> None:
        for field, value in [
            ("zone", "other.example"),
            ("version", True),
            ("ttl", 5001),
            ("ttl", False),
            ("token", "forbidden"),
            ("revision", -1),
            ("routes", self.snapshot["routes"] * 256),
        ]:
            with self.subTest(field=field), self.assertRaises(SetupError):
                publication.records(
                    dict(self.snapshot, **{field: value}), self.snapshot["zone"], 0, 1
                )
        for kind, field, value in [
            ("routes", "addresses", ["::1"]),
            ("routes", "addresses", ["127.1"]),
            ("routes", "addresses", ["192.0.2.1", "192.0.2.1"]),
            ("routes", "label", "control." + LABEL + ".inception"),
            ("routes", "label", "control"),
            ("routes", "ttl", 0),
            ("proofs", "proofs", [PROOF, PROOF]),
            ("proofs", "proofs", ["x" * 43]),
            ("proofs", "proofs", ["parent-token"]),
            ("proofs", "host", "other.example"),
        ]:
            bad = copy.deepcopy(self.snapshot)
            entries = bad["routes"] if kind == "routes" else bad["proofs"]
            entries[0][field] = value
            with (
                self.subTest(field=field, value=value),
                self.assertRaises((ValueError, SetupError)),
            ):
                publication.records(bad, self.snapshot["zone"], 0, 1)
        bad = copy.deepcopy(self.snapshot)
        bad["proofs"] *= 2
        with self.assertRaises(SetupError):
            publication.records(bad, self.snapshot["zone"], 0, 1)
        # Individually bounded collections must not overflow the union.
        bad["routes"] = [
            {"label": "vm-" + f"{i:032x}", "ttl": 5000, "addresses": ["192.0.2.37"]}
            for i in range(255)
        ]
        bad["proofs"] = [{"label": "vm-" + f"{255:032x}", "ttl": 5000, "proofs": [PROOF]}]
        with self.assertRaises(SetupError):
            publication.records(bad, self.snapshot["zone"], 0, 1)

    def test_control_proofs_bootstrap_before_readiness_and_stale_state_fails(self) -> None:
        value = {
            "binding": self.boot,
            "generation": 1,
            "expires_at_ms": 2000,
            "ready": False,
            "proofs": [PROOF],
        }
        record, expiry = publication.control_record(value, self.config, 1000)
        self.assertEqual(record, {"label": "control", "ready": False, "proofs": [PROOF]})
        self.assertEqual(expiry, 2000)
        for field, changed in [
            ("generation", 2),
            ("generation", True),
            ("expires_at_ms", 1000),
            ("expires_at_ms", 6001),
            ("ready", 1),
            ("label", "other"),
            ("proofs", [PROOF, PROOF]),
            ("binding", dict(self.boot, execution_epoch=2)),
        ]:
            with self.subTest(field=field), self.assertRaises(SetupError):
                publication.control_record(dict(value, **{field: changed}), self.config, 1000)

    def test_host_keys_require_service_custody_and_canonical_ed25519(self) -> None:
        path = self.root / "host.pub"
        publish(path, (KEY + "\n").encode())
        self.assertEqual(publication.host_key(path, os.getuid()), KEY)
        with self.assertRaises(SetupError):
            publication.host_key(path, os.getuid() + 1)
        path.chmod(0o666)
        with self.assertRaises(SetupError):
            publication.host_key(path, os.getuid())
        for value in [KEY + " comment", KEY + "\n\n", "ssh-rsa AAAA", KEY[:-4], "x" * 129]:
            publish(path, value.encode())
            with self.assertRaises((ValueError, SetupError)):
                publication.host_key(path, os.getuid())
        path.unlink()
        path.symlink_to("missing")
        with self.assertRaises(OSError):
            publication.host_key(path, os.getuid())

    def test_generation_race_and_expired_collection_cannot_replace_publication(self) -> None:
        value = dict(self.config, request_id=self.boot["placement_id"])
        ingress.install(value, self.root)
        with patch.object(publication, "now", return_value=1000):
            result = {"expires_at_ms": 2000}
            publication.install(self.config, result, self.root)
            self.assertEqual(json.loads((self.root / "publication.json").read_bytes()), result)
            ingress.install(dict(value, generation=2), self.root)
            with self.assertRaises(SetupError):
                publication.install(self.config, {"expires_at_ms": 3000}, self.root)
            self.assertEqual(json.loads((self.root / "publication.json").read_bytes()), result)
        with patch.object(publication, "now", return_value=2000), self.assertRaises(SetupError):
            publication.install(dict(self.config, generation=2), result, self.root)

    def test_collection_uses_only_local_dns_and_fails_closed_on_source_errors(self) -> None:
        publish(self.root / "dns.token", b"synthetic-local-dns-token")
        calls = []
        fixture = self.snapshot

        class Client:
            def request(
                self, route: str, token: str, fields: dict[str, object]
            ) -> Mapping[str, object]:
                calls.append((route, token, fields))
                return fixture

        with patch.object(publication, "now", return_value=1000):
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertEqual(result["expires_at_ms"], 3000)
            self.assertEqual(
                result["records"], [{"label": LABEL, "ready": True, "proofs": [PROOF]}]
            )
            self.assertIsNone(result["porsche_host_key"])
            self.assertEqual(
                calls,
                [
                    (
                        "audi/v1/dns-snapshot",
                        "synthetic-local-dns-token",
                        {"zone": self.snapshot["zone"]},
                    )
                ],
            )
            fixture = {"invalid": True}
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertEqual(result["records"], [])
            calls.clear()
            publish(
                self.root / "control-publication.json",
                encode(
                    {
                        "binding": self.boot,
                        "generation": 1,
                        "expires_at_ms": 1100,
                        "ready": False,
                        "proofs": [PROOF],
                    }
                ),
            )
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertEqual(result["expires_at_ms"], 1100)
            self.assertEqual(
                result["records"], [{"label": "control", "ready": False, "proofs": [PROOF]}]
            )
            self.assertEqual(calls, [])
            calls.clear()
            publish(
                self.root / "publication.json",
                encode(
                    {
                        "binding": self.boot,
                        "generation": 1,
                        "expires_at_ms": 5000,
                        "porsche_host_key": KEY,
                        "audi_host_key": KEY,
                        "records": [{"label": LABEL, "ready": True, "proofs": []}],
                    }
                ),
            )
            publish(
                self.root / "control-publication.json",
                encode(
                    {
                        "binding": self.boot,
                        "generation": 1,
                        "expires_at_ms": 1100,
                        "ready": True,
                        "proofs": [],
                    }
                ),
            )
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertEqual(result["expires_at_ms"], 1100)
            self.assertEqual(
                result["records"],
                [
                    {"label": LABEL, "ready": True, "proofs": []},
                    {"label": "control", "ready": True, "proofs": []},
                ],
            )
            self.assertEqual(calls, [])
            with self.assertRaises(SetupError):
                publication.collect(
                    dict(self.boot, execution_epoch=2), self.config, Client(), self.root, self.root
                )

    def test_each_key_requires_its_own_current_inner_authority(self) -> None:
        for name in ["dns", "porsche", "audi"]:
            publish(self.root / (name + ".token"), ("synthetic-" + name).encode())
        host = self.boot["placement_id"]
        publish(self.root / "lilly.json", encode({"host_id": host}))
        publish(self.root / "host.pub", (KEY + "\n").encode())
        authority = {"porsche": True, "audi": True, "host": host}
        fixture = self.snapshot

        class Client:
            def request(
                self, route: str, token: str, fields: dict[str, object]
            ) -> Mapping[str, object]:
                if route == "audi/v1/dns-snapshot":
                    return fixture
                if route == "ssh/v1/ready":
                    if not authority["porsche"]:
                        raise SetupError("revoked")
                    return {"ready": True}
                return {
                    "version": 1,
                    "service": {
                        "id": host,
                        "name": "inception-audi",
                        "role": "gateway",
                        "host_id": authority["host"],
                        "generation": 1,
                        "enabled": authority["audi"],
                    },
                }

        read_key = publication.host_key
        with (
            patch.object(publication, "now", return_value=1000),
            patch.object(
                publication.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid())
            ),
            patch.object(
                publication,
                "host_key",
                side_effect=lambda path, uid: read_key(self.root / "host.pub", uid),
            ),
        ):
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertEqual((result["porsche_host_key"], result["audi_host_key"]), (KEY, KEY))
            authority["porsche"] = False
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertIsNone(result["porsche_host_key"])
            self.assertEqual(result["audi_host_key"], KEY)
            authority["host"] = "22222222-2222-4222-8222-222222222222"
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertIsNone(result["audi_host_key"])
            authority.update(host=host, audi=False)
            result = publication.collect(self.boot, self.config, Client(), self.root, self.root)
            self.assertIsNone(result["audi_host_key"])
            self.assertTrue(result["records"])

    def test_actual_https_ca_hostname_bounds_and_no_redirect_or_proxy(self) -> None:
        ca = self.root / "ca.pem"
        key = self.root / "key.pem"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost",
                "-keyout",
                str(key),
                "-out",
                str(ca),
            ],
            check=True,
            capture_output=True,
        )
        release = threading.Event()
        state: HandlerState = {
            "status": 200,
            "body": encode({"ready": True}),
            "requests": [],
            "block": False,
        }

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                body = self.rfile.read(int(self.headers["Content-Length"]))
                state["requests"].append(
                    (self.path, self.headers["Authorization"], json.loads(body))
                )
                if state["block"]:
                    release.wait(5)
                self.send_response(state["status"])
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(state["body"])))
                self.send_header("Location", "https://other.invalid/secret")
                self.end_headers()
                with contextlib.suppress(OSError):
                    self.wfile.write(state["body"])

            def log_message(self, format: str, *args: object) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(ca, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join()))
        client = publication.LocalClient(ca, server.server_address[1])
        # No hostname resolution and no HTTP(S)_PROXY are used for this socket.
        with (
            patch.object(socket, "getaddrinfo", side_effect=AssertionError("DNS forbidden")),
            patch.dict(os.environ, HTTPS_PROXY="http://127.0.0.1:1"),
        ):
            self.assertEqual(client.request("ssh/v1/ready", "synthetic-token", {}), {"ready": True})
        self.assertEqual(
            state["requests"], [("/api/ssh/v1/ready", "Bearer synthetic-token", {"version": 1})]
        )
        for status, body in [
            (302, b"{}"),
            (200, b'{"ready":true,"ready":false}'),
            (200, b"x" * (publication.MAXIMUM + 1)),
        ]:
            state.update(status=status, body=body)
            with self.assertRaises(SetupError):
                client.request("ssh/v1/ready", "synthetic-token", {})
        with self.assertRaises(SetupError):
            client.request("http://other.invalid", "synthetic-token", {})
        client.context = ssl.create_default_context()
        with self.assertRaises(ssl.SSLCertVerificationError):
            client.request("ssh/v1/ready", "synthetic-token", {})
        self.assertEqual(len(state["requests"]), 4)
        client.context = ssl.create_default_context(cafile=str(ca))
        state.update(status=200, body=encode({"ready": True}), block=True)
        started = time.monotonic()
        try:
            with self.assertRaises((OSError, http.client.HTTPException, SetupError)):
                client.request("ssh/v1/ready", "synthetic-token", {})
            self.assertLess(time.monotonic() - started, 3)
        finally:
            release.set()
        # A trusted certificate for the wrong name must still fail verification.
        wrong = self.root / "wrong.pem"
        wrong_key = self.root / "wrong.key"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=wrong.invalid",
                "-addext",
                "subjectAltName=DNS:wrong.invalid",
                "-keyout",
                str(wrong_key),
                "-out",
                str(wrong),
            ],
            check=True,
            capture_output=True,
        )
        context.load_cert_chain(wrong, wrong_key)
        client.context = ssl.create_default_context(cafile=str(wrong))
        with self.assertRaises(ssl.SSLCertVerificationError):
            client.request("ssh/v1/ready", "synthetic-token", {})


if __name__ == "__main__":
    unittest.main()
