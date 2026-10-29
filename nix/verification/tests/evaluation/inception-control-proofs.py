"""Fixed control proof ownership, job expiry and actual parent evidence reads."""

import copy
import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
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
proofs_spec = importlib.util.spec_from_file_location("control_proofs", source / "control_proofs.py")
if proofs_spec is None or proofs_spec.loader is None:
    raise RuntimeError("control proofs helper unavailable")
control = importlib.util.module_from_spec(proofs_spec)
sys.modules["control_proofs"] = control
proofs_spec.loader.exec_module(control)

CASES = json.loads(Path(sys.argv.pop(1)).read_text())
PROOF = "A" * 43


class ControlProofTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        roots = self.base / "system-roots.pem"
        roots.write_bytes(b"test roots")
        image = self.base / "image.json"
        image.write_text(json.dumps({"system_ca": str(roots)}))
        configured_image = patch.object(ingress, "PUBLIC_CONFIG", image)
        configured_image.start()
        self.addCleanup(configured_image.stop)
        self.root = self.base / "worker"
        self.namespace = self.base / "namespace"
        self.boot = {
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "boot_challenge": "a" * 64,
        }
        name = "dev-" + "2" * 32 + ".inception.apps.example"
        self.config = {
            "version": 1,
            "binding": self.boot,
            "request_id": self.boot["placement_id"],
            "generation": 1,
            "origins": {"namespace": name, "control": "control." + name, "apps": "apps." + name},
            "public": next(item["value"] for item in CASES if item["name"] == "public"),
        }
        ingress.install(ingress.request(encode(self.config), self.boot), self.namespace)
        self.owner = "_acme-challenge." + self.config["origins"]["control"] + "."

    def begin(self, current: int = 1000) -> dict[str, object]:
        return control.begin(self.boot, self.root, self.namespace, current)

    def update(
        self,
        job: dict[str, object],
        action: str = "present",
        owner: str | None = None,
        proof: object = PROOF,
        current: int = 1100,
    ) -> dict[str, object]:
        return control.update(
            action,
            self.owner if owner is None else owner,
            proof,
            job["run_id"],
            self.boot,
            self.root,
            self.namespace,
            current,
        )

    def test_exact_owner_and_proof_never_refresh_the_job_deadline(self) -> None:
        job = self.begin()
        changed = self.update(job)
        self.assertEqual(changed["expires_at_ms"], 901000)
        self.assertEqual(changed["proofs"], [PROOF])
        self.assertEqual(self.update(job, current=900999), changed)
        with self.assertRaises(SetupError):
            self.update(job, current=901000)
        for owner in [self.owner[:-1], self.owner + "other.", "_acme-challenge.other.example."]:
            with self.assertRaises(SetupError):
                self.update(job, owner=owner)
        for value in ["bad", "A" * 44, True, None]:
            with self.assertRaises(SetupError):
                self.update(job, proof=value)

    def test_old_hook_cannot_clean_or_present_into_a_new_job(self) -> None:
        first = self.begin()
        self.update(first)
        second = self.begin(current=1200)
        self.assertNotEqual(first["run_id"], second["run_id"])
        for action in ["present", "cleanup"]:
            with self.assertRaises(SetupError):
                self.update(first, action=action, current=1300)
        self.assertEqual(control.current_job(self.boot, self.root, self.namespace, 1300), second)
        self.update(second, current=1300)
        with self.assertRaises(SetupError):
            self.update(second, action="cleanup", proof="B" * 42 + "A", current=1400)
        self.assertEqual(self.update(second, action="cleanup", current=1400)["proofs"], [])

    def test_generation_boot_and_malformed_job_cannot_supply_proofs(self) -> None:
        job = self.begin()
        self.update(job)
        for changed in [
            dict(self.config, generation=2),
            dict(self.config, binding=dict(self.boot, boot_challenge="b" * 64)),
        ]:
            publish(
                self.namespace / "ingress.json",
                encode({k: v for k, v in changed.items() if k != "request_id"}),
            )
            with self.assertRaises(SetupError):
                control.current_job(self.boot, self.root, self.namespace, 1200)
        ingress.install(self.config, self.namespace)
        for field, value in [
            ("generation", True),
            ("expires_at_ms", 901001),
            ("started_at_ms", 2000),
            ("binding", dict(self.boot, execution_epoch=True)),
        ]:
            invalid = copy.deepcopy(job)
            invalid[field] = value
            publish(self.root / "job.json", encode(invalid))
            with self.assertRaises(SetupError):
                control.current_job(self.boot, self.root, self.namespace, 1200)

    def test_heartbeat_cannot_extend_job_or_claim_implicit_readiness(self) -> None:
        job = self.begin()
        self.update(job)
        value = control.record(self.boot, False, self.root, self.namespace, 600500)
        self.assertFalse(value["ready"])
        self.assertEqual(value["proofs"], [PROOF])
        self.assertEqual(value["expires_at_ms"], 605500)
        expired = control.record(self.boot, False, self.root, self.namespace, 901000)
        self.assertEqual(expired["proofs"], [])
        self.assertEqual(expired["expires_at_ms"], 906000)
        with self.assertRaises(SetupError):
            control.record(self.boot, 1, self.root, self.namespace, 1200)

    def test_dns_second_rounding_does_not_reject_fresh_parent_evidence(self) -> None:
        current = control.now()
        job = self.begin(current)
        self.update(job, current=current)
        saved = control.current_job(self.boot, self.root, self.namespace)
        saved["expires_at_ms"] = current + 500
        publish(self.root / "job.json", encode(saved))
        shared = self.base / "shared"
        shared.mkdir(mode=0o750)
        observations.publish_shared(
            shared,
            encode(
                {
                    "binding": self.boot,
                    "generation": 1,
                    "records": [
                        {"label": "control", "proofs": [PROOF], "expires_at_ms": current + 400}
                    ],
                }
            ),
        )
        # Real file validation and monotonic clocks, with less than one second
        # left after DNS wire-TTL rounding and transport. The bounded job makes
        # the old impossible margin fail quickly instead of hanging the suite.
        control.wait_observed(job["run_id"], PROOF, self.boot, self.root, self.namespace, shared)

    def test_parent_evidence_must_match_and_expired_jobs_bound_waiting(self) -> None:
        current = control.now()
        job = self.begin(current)
        self.update(job, current=current)
        shared = self.base / "shared"
        shared.mkdir(mode=0o750)
        observations.publish_shared(
            shared,
            encode(
                {
                    "binding": self.boot,
                    "generation": 1,
                    "records": [
                        {"label": "control", "proofs": [PROOF], "expires_at_ms": current + 3000}
                    ],
                }
            ),
        )
        control.wait_observed(job["run_id"], PROOF, self.boot, self.root, self.namespace, shared)
        observations.publish_shared(
            shared, encode({"binding": self.boot, "generation": 2, "records": []})
        )
        saved = control.current_job(self.boot, self.root, self.namespace)
        saved["expires_at_ms"] = control.now() + 150
        publish(self.root / "job.json", encode(saved))
        started = time.monotonic()
        with self.assertRaises(SetupError):
            control.wait_observed(
                job["run_id"], PROOF, self.boot, self.root, self.namespace, shared
            )
        self.assertLess(time.monotonic() - started, 1)


unittest.main()
