"""Bounded DNS-01 hook for the inner control certificate's fixed hostname."""

import fcntl
import json
import os
import re
import secrets
import stat
import sys
import time
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from typing import TypedDict

import ingress
import observations
from ingress import Binding, Configuration
from runtime import SetupError, encode, private_directory, publish, read_private

ROOT = Path("/run/inception-control")
NAMESPACE = Path("/run/inception")
RUN_ID = re.compile(r"[0-9a-f]{64}")
# Native nested hosts can take several minutes between ACME authorization and
# certificate retrieval while the parent refreshes its short-lived offers. Keep
# one bounded issuance authority window, but allow that complete ACME exchange
# to finish before the worker fences the generated files.
JOB_TTL_MS = 900_000
PUBLICATION_TTL_MS = 5_000


class Boot(Binding):
    address: str
    gateway: str


class Job(TypedDict):
    version: int
    run_id: str
    binding: Binding
    generation: int
    hostname: str
    started_at_ms: int
    expires_at_ms: int
    proofs: list[str]


class Publication(TypedDict):
    binding: Binding
    generation: int
    proofs: list[str]
    ready: bool
    expires_at_ms: int


def now() -> int:
    return time.monotonic_ns() // 1000000


@contextmanager
def job_lock(root: Path) -> Generator[None]:
    private_directory(root)
    fd = os.open(root / "job.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as lock:
        info = os.fstat(lock.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & 0o077
        ):
            raise SetupError("control certificate lock invalid")
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def configuration(boot: Boot, namespace: Path = NAMESPACE) -> Configuration:
    config: Configuration = json.loads(read_private(namespace / "ingress.json"))
    ingress.request(encode(dict(config, request_id=boot["placement_id"])), boot)
    if config.get("public") is None:
        raise SetupError("control certificate settings unavailable")
    return config


def begin(
    boot: Boot,
    root: Path = ROOT,
    namespace: Path = NAMESPACE,
    current: int | None = None,
) -> Job:
    """@cc [owner:ghuntley,label:security;recovery] inception-control-proof-job
    A new certificate job MUST bind the current boot, generation and fixed
    control hostname. It MUST clear previous proofs and have one non-renewable
    fifteen-minute deadline. Only the single supervised certificate worker may
    begin jobs; a hook MUST NOT extend or replace job authority.
    """
    current = now() if current is None else current
    config = configuration(boot, namespace)
    private_directory(root)
    job: Job = {
        "version": 1,
        "run_id": secrets.token_hex(32),
        "binding": config["binding"],
        "generation": config["generation"],
        "hostname": config["origins"]["control"],
        "started_at_ms": current,
        "expires_at_ms": current + JOB_TTL_MS,
        "proofs": [],
    }
    with job_lock(root):
        publish(root / "job.json", encode(job))
    return job


def current_job(
    boot: Boot,
    root: Path = ROOT,
    namespace: Path = NAMESPACE,
    current: int | None = None,
) -> Job:
    current = now() if current is None else current
    config = configuration(boot, namespace)
    job: Job = json.loads(read_private(root / "job.json", 4096))
    if (
        not isinstance(job, dict)
        or set(job)
        != {
            "version",
            "run_id",
            "binding",
            "generation",
            "hostname",
            "started_at_ms",
            "expires_at_ms",
            "proofs",
        }
        or type(job["version"]) is not int
        or job["version"] != 1
        or not isinstance(job["run_id"], str)
        or not RUN_ID.fullmatch(job["run_id"])
        or job["binding"] != config["binding"]
        or not isinstance(job["binding"], dict)
        or type(job["binding"].get("execution_epoch")) is not int
        or type(job["generation"]) is not int
        or job["generation"] != config["generation"]
        or job["hostname"] != config["origins"]["control"]
        or type(job["started_at_ms"]) is not int
        or type(job["expires_at_ms"]) is not int
        or not job["started_at_ms"]
        <= current
        < job["expires_at_ms"]
        <= job["started_at_ms"] + JOB_TTL_MS
        or not isinstance(job["proofs"], list)
        or len(job["proofs"]) > 1
        or not all(observations.proof(p) for p in job["proofs"])
    ):
        raise SetupError("control certificate job unavailable")
    return job


def update(
    action: str,
    owner: str,
    proof: str,
    run_id: str,
    boot: Boot,
    root: Path = ROOT,
    namespace: Path = NAMESPACE,
    current: int | None = None,
) -> Job:
    """@cc [owner:ghuntley,label:security] inception-control-proof-selector
    Hooks MUST select only present/cleanup for the exact assigned control DNS-01
    owner, canonical proof and current job nonce. No other hostname, record,
    address or credential is accepted. A delayed cleanup MUST NOT remove a
    newer job or another proof. Updates MUST preserve the original deadline.
    """
    if action not in ["present", "cleanup"] or not observations.proof(proof):
        raise SetupError("control certificate hook invalid")
    with job_lock(root):
        job = current_job(boot, root, namespace, current)
        if run_id != job["run_id"] or owner != "_acme-challenge." + job["hostname"] + ".":
            raise SetupError("control certificate hook binding invalid")
        if action == "present":
            if job["proofs"] not in [[], [proof]]:
                raise SetupError("control certificate proof conflict")
            job["proofs"] = [proof]
        elif job["proofs"] == [proof]:
            job["proofs"] = []
        else:
            raise SetupError("control certificate cleanup mismatch")
        publish(root / "job.json", encode(job))
        return job


def record(
    boot: Boot,
    ready: bool,
    root: Path = ROOT,
    namespace: Path = NAMESPACE,
    current: int | None = None,
) -> Publication:
    """@cc [owner:ghuntley,label:recovery] inception-control-proof-heartbeat
    Control publication MUST expire within five seconds if its producer stops.
    Proofs MUST additionally remain bound to the live current job and its original
    deadline. Readiness MUST be supplied only by a freshly verified local TLS
    listener; this helper MUST NOT infer readiness from proof or file existence.
    """
    current = now() if current is None else current
    if type(ready) is not bool:
        raise SetupError("control certificate readiness invalid")
    config = configuration(boot, namespace)
    proofs, expiry = [], current + PUBLICATION_TTL_MS
    try:
        job = current_job(boot, root, namespace, current)
        if job["binding"] == config["binding"] and job["generation"] == config["generation"]:
            proofs, expiry = job["proofs"], min(expiry, job["expires_at_ms"])
    except (FileNotFoundError, SetupError):
        pass
    return {
        "binding": config["binding"],
        "generation": config["generation"],
        "proofs": proofs,
        "ready": ready,
        "expires_at_ms": expiry,
    }


def wait_observed(
    run_id: str,
    proof: str,
    boot: Boot,
    root: Path = ROOT,
    namespace: Path = NAMESPACE,
    shared: Path = observations.SHARED,
) -> None:
    """@cc [owner:ghuntley,label:security] inception-control-parent-observation
    A hook MUST complete only for the current job's exact proof and boot-bound
    parent evidence that remains strictly unexpired. Waiting MUST stop at
    the original job deadline or a changed job. It MUST NOT query DNS directly
    or treat missing evidence as successful propagation.
    """
    while True:
        job = current_job(boot, root, namespace)
        if job["run_id"] != run_id or job["proofs"] != [proof]:
            raise SetupError("control certificate proof replaced")
        request: observations.Query = {
            "version": 1,
            "binding": job["binding"],
            "generation": job["generation"],
            "label": "control",
            "proofs": [proof],
        }
        try:
            # DNS TTLs are whole seconds. A five-second publication leaves
            # bounded room for sampling and transport while the broker still
            # checks exact authority and the original job deadline.
            if observations.remaining(request, shared) > 0:
                return
        except (OSError, ValueError, KeyError, TypeError, SetupError):
            pass
        time.sleep(0.1)


def main() -> None:
    # The executable and import root are immutable image inputs, not hook values.
    sys.path.insert(0, sys.argv[1])
    from readiness import identity

    boot = identity(Path("/proc/cmdline").read_text())
    if len(sys.argv) != 5:
        raise SetupError("control certificate hook arguments invalid")
    action, owner, proof = sys.argv[2:]
    run_id = os.environ["INCEPTION_CONTROL_JOB"]
    update(action, owner, proof, run_id, boot)
    if action == "present":
        wait_observed(run_id, proof, boot)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, SetupError):
        sys.exit("Inception control proof unavailable")
