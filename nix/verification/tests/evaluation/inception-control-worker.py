"""Issuer input isolation and bounded child process groups."""

import copy
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import TypedDict, cast
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
read_private = runtime.read_private
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
roles_spec = importlib.util.spec_from_file_location("roles", source / "roles.py")
if roles_spec is None or roles_spec.loader is None:
    raise RuntimeError("roles helper unavailable")
roles = importlib.util.module_from_spec(roles_spec)
sys.modules["roles"] = roles
roles_spec.loader.exec_module(roles)
proofs_spec = importlib.util.spec_from_file_location("control_proofs", source / "control_proofs.py")
if proofs_spec is None or proofs_spec.loader is None:
    raise RuntimeError("control proofs helper unavailable")
proofs = importlib.util.module_from_spec(proofs_spec)
sys.modules["control_proofs"] = proofs
proofs_spec.loader.exec_module(proofs)
tls_spec = importlib.util.spec_from_file_location("control_tls", source / "control_tls.py")
if tls_spec is None or tls_spec.loader is None:
    raise RuntimeError("control TLS helper unavailable")
control_tls = importlib.util.module_from_spec(tls_spec)
sys.modules["control_tls"] = control_tls
tls_spec.loader.exec_module(control_tls)
worker_spec = importlib.util.spec_from_file_location("control_worker", source / "control_worker.py")
if worker_spec is None or worker_spec.loader is None:
    raise RuntimeError("control worker helper unavailable")
worker = importlib.util.module_from_spec(worker_spec)
sys.modules["control_worker"] = worker
worker_spec.loader.exec_module(worker)

CASES = json.loads(Path(sys.argv.pop(1)).read_text())


class Boot(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


class Nameserver(TypedDict):
    address: str
    port: int


class PublicConfiguration(TypedDict):
    issuer: str
    accept_terms: bool
    nameservers: list[Nameserver]
    mailbox: str
    issuer_ca_pem: str
    trust_pem: str


class Configuration(TypedDict):
    version: int
    binding: Boot
    request_id: str
    generation: int
    origins: dict[str, str]
    public: PublicConfiguration


class WorkerTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
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
            "request_id": self.boot["placement_id"],
            "generation": 1,
            "origins": {
                "namespace": namespace,
                "control": "control." + namespace,
                "apps": "apps." + namespace,
            },
            "public": cast(
                PublicConfiguration,
                copy.deepcopy(next(item["value"] for item in CASES if item["name"] == "public")),
            ),
        }

    def test_process_category_redacts_transport_diagnostics_to_fixed_enums(self) -> None:
        self.assertEqual(worker.process_category(1, False, b"unexpected EOF"), "transport_http")
        self.assertEqual(
            worker.process_category(1, False, b"x509: unknown authority"), "transport_verify"
        )
        self.assertEqual(
            worker.process_category(1, False, b"asn1: malformed certificate"), "transport_parse"
        )
        self.assertEqual(
            worker.process_category(1, False, b"certificate unavailable"), "transport_verify"
        )
        self.assertEqual(worker.process_category(1, True, b"unexpected EOF"), "timeout")

    def test_issuer_environment_is_closed_and_fixed_hook_owns_propagation(self) -> None:
        with patch.dict(
            os.environ, {"HTTPS_PROXY": "http://untrusted", "AWS_SECRET_ACCESS_KEY": "sentinel"}
        ):
            args, env = worker.invocation(
                {"lego": "/immutable/lego", "hook": "/immutable/hook"},
                self.config,
                {"run_id": "b" * 64},
            )
        self.assertEqual(args[0], "/immutable/lego")
        self.assertEqual(args[-1], "run")
        self.assertEqual(args[args.index("--path") + 1], "/var/lib/inception-control/acme")
        self.assertEqual(args[args.index("--domains") + 1], self.config["origins"]["control"])
        self.assertEqual(
            [
                args[index + 1]
                for index, argument in enumerate(args)
                if argument == "--dns.resolvers"
            ],
            [f"{peer['address']}:{peer['port']}" for peer in self.config["public"]["nameservers"]],
        )
        self.assertEqual(args[args.index("--dns.propagation-wait") + 1], "1s")
        self.assertEqual(args[args.index("--cert.timeout") + 1], "720")
        self.assertEqual(args[args.index("--http-timeout") + 1], "720")
        self.assertLess(args.index("--dns.propagation-wait"), args.index("run"))
        self.assertEqual(env["EXEC_PATH"], "/immutable/hook")
        self.assertEqual(env["LEGO_DISABLE_CNAME_SUPPORT"], "true")
        self.assertEqual(env["GODEBUG"], "http2client=0")
        self.assertEqual(env["SSL_CERT_FILE"], "/run/inception/audi-issuer-ca.pem")
        self.assertEqual(
            set(env),
            {
                "HOME",
                "GODEBUG",
                "LANG",
                "EXEC_PATH",
                "EXEC_POLLING_INTERVAL",
                "LEGO_DISABLE_CNAME_SUPPORT",
                "LEGO_CA_CERTIFICATES",
                "SSL_CERT_FILE",
                "INCEPTION_CONTROL_JOB",
            },
        )
        self.config["public"]["accept_terms"] = False
        with self.assertRaises(SetupError):
            worker.invocation(
                {"lego": "/immutable/lego", "hook": "/immutable/hook"}, self.config, {}
            )

    def test_issued_material_uses_lego_bundle_without_optional_issuer_file(self) -> None:
        calls: list[tuple[str, int]] = []

        class Issuer:
            @staticmethod
            def issuer_file(path: Path, issuer: int) -> bytes:
                calls.append((path.name, issuer))
                return path.name.encode("ascii")

        hostname = self.config["origins"]["control"]
        self.assertEqual(
            worker.issued_material(Issuer(), self.root / "certificates", hostname),
            (hostname + ".key" + hostname + ".crt").encode("ascii"),
        )
        self.assertEqual(
            calls,
            [(hostname + ".key", 0), (hostname + ".crt", 0)],
        )

    def test_wait_for_issued_material_allows_final_filesystem_write(self) -> None:
        calls = 0
        sleeps: list[float] = []

        class Issuer:
            @staticmethod
            def issuer_file(path: Path, issuer: int) -> bytes:
                nonlocal calls
                calls += 1
                if calls == 1:
                    # Lego may expose a freshly-created file before its final
                    # mode/ownership metadata is visible to the custody
                    # reader.  The worker must keep polling within its
                    # bounded deadline instead of classifying that race as a
                    # permanently missing material set.
                    raise ValueError("issuer file still settling")
                return path.name.encode("ascii")

        clock = iter([100, 100, 100, 1000]).__next__
        with patch.object(worker.time, "sleep", sleeps.append):
            material = worker.wait_for_issued_material(
                Issuer(),
                self.root / "certificates",
                self.config["origins"]["control"],
                2000,
                clock,
            )
        hostname = self.config["origins"]["control"]
        self.assertEqual(material, (hostname + ".key" + hostname + ".crt").encode("ascii"))
        self.assertEqual(sleeps, [0.25])

    def test_wait_for_issued_material_discards_read_crossing_deadline(self) -> None:
        class Issuer:
            @staticmethod
            def issuer_file(path: Path, issuer: int) -> bytes:
                return path.name.encode("ascii")

        # The files are complete when the read starts, but the authority fence
        # expires before the read returns.  Material must not be consumed using
        # the stale pre-read timestamp.
        clock = iter([100, 2000]).__next__
        with self.assertRaises(SetupError):
            worker.wait_for_issued_material(
                Issuer(),
                self.root / "certificates",
                self.config["origins"]["control"],
                2000,
                clock,
            )

    def test_abandoned_issuer_and_hook_are_both_killed(self) -> None:
        marker = self.root / "child.pid"
        code = """import os, pathlib, signal, sys, time
child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
while True:
    time.sleep(1)
"""
        process = subprocess.Popen(
            [sys.executable, "-c", code, str(marker)], start_new_session=True
        )
        self.addCleanup(worker.stop_job, process)
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists())
        child = int(marker.read_text())
        worker.stop_job(process)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            status = Path(f"/proc/{child}/stat")
            if not status.exists() or status.read_text().split()[2] == "Z":
                break
            time.sleep(0.01)
        else:
            self.fail("issuer hook survived process-group termination")

    def test_restart_clears_proofs_and_changed_namespace_cannot_refresh_publication(self) -> None:
        namespace = self.root / "namespace"
        jobs = self.root / "jobs"
        ingress.install(ingress.request(encode(self.config), self.boot), namespace)
        accepted = proofs.configuration(self.boot, namespace)
        job = proofs.begin(self.boot, jobs, namespace)
        owner = "_acme-challenge." + self.config["origins"]["control"] + "."
        proofs.update("present", owner, "A" * 43, job["run_id"], self.boot, jobs, namespace)
        worker.heartbeat(self.boot, accepted, False, jobs, namespace)
        path = namespace / "control-publication.json"
        self.assertEqual(json.loads(read_private(path))["proofs"], ["A" * 43])
        worker.clear_job(jobs)
        worker.heartbeat(self.boot, accepted, False, jobs, namespace)
        prior = read_private(path)
        self.assertEqual(json.loads(prior)["proofs"], [])
        self.assertFalse(json.loads(prior)["ready"])
        changed = dict(self.config, generation=2)
        ingress.install(ingress.request(encode(changed), self.boot), namespace)
        with self.assertRaises(SetupError):
            worker.heartbeat(self.boot, accepted, True, jobs, namespace)
        # Namespace installation may remove the stale publication altogether;
        # neither path may publish a new ready heartbeat for the old generation.
        if path.exists():
            self.assertEqual(read_private(path), prior)


unittest.main()
