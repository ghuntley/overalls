"""Independent, bounded control certificate issuance and proxy supervision."""

import contextlib
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Never, Protocol, TypedDict, cast

import control_proofs as proofs
import control_tls as tls
from runtime import SetupError, encode, private_directory, publish

STATE = Path("/var/lib/inception-control")
SERVICE = "inception-control-proxy.service"


class Image(TypedDict):
    guest_root: str
    lego: str
    hook: str
    openssl: str
    haproxy: str
    validator: str
    systemctl: str


class IssuerFiles(Protocol):
    def issuer_file(self, path: Path, issuer: int) -> bytes: ...


def issued_material(module: IssuerFiles, directory: Path, hostname: str) -> bytes:
    """@cc [owner:ghuntley,label:security] inception-control-issued-material
    A completed ACME attempt MUST offer only the private key and the certificate
    bundle written for the current hostname. The shared validator MUST decide
    whether that bundle is complete and trusted; a missing optional issuer file
    MUST NOT cause a valid issuer output to be discarded.
    """
    return module.issuer_file(directory / (hostname + ".key"), 0) + module.issuer_file(
        directory / (hostname + ".crt"), 0
    )


def wait_for_issued_material(
    module: IssuerFiles,
    directory: Path,
    hostname: str,
    deadline: int,
    clock: Callable[[], int] = proofs.now,
) -> bytes:
    """Read Lego's files after process completion, allowing its final writes.

    Lego fetches the certificate in a separate ACME request after Pebble marks
    the order issued.  Under a loaded nested host the child process can report
    completion while the filesystem writes are still being flushed.  Keep the
    original job deadline as the authority fence and poll only for this
    already-owned output; no new authority is granted during the grace period.
    A successful read MUST finish before the deadline; a read that crosses the
    fence MUST be discarded even when both files are already present.
    """
    while True:
        # The deadline is an authority boundary, not merely a retry hint. Check
        # both sides of the filesystem read so a file that becomes visible at
        # the boundary cannot be consumed after its job has expired.
        if clock() >= deadline:
            raise SetupError("control certificate material deadline expired")
        try:
            material = issued_material(module, directory, hostname)
        except (OSError, ValueError):
            if clock() >= deadline:
                raise
            time.sleep(0.25)
            continue
        if clock() >= deadline:
            raise SetupError("control certificate material deadline expired")
        return material


def stop_job(process: subprocess.Popen[bytes] | None) -> None:
    """@cc [owner:ghuntley,label:recovery] inception-control-issuer-process-group
    Finishing, timing out or abandoning an issuance attempt MUST kill its entire
    process group, including hooks, before another job can gain authority.
    Only the worker's own start_new_session child group may be signalled.
    """
    if process is not None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def invocation(
    image: Image, config: proofs.Configuration, job: proofs.Job
) -> tuple[list[str], dict[str, str]]:
    """@cc [owner:ghuntley,label:security] inception-control-issuer-inputs
    Issuance MUST use the assigned control hostname, operator issuer and explicit
    consent, independent persistent account state and a fixed image-owned hook.
    No ambient proxy, provider credential or parent credential may be inherited.
    The hook's bound parent observation MUST establish propagation; direct DNS
    propagation and CNAME lookups MUST NOT bypass that observation. The child
    resolver MUST NOT be passed to lego because it is authoritative only for the
    child application zone, while the control owner is projected by the parent.
    """
    public = config["public"]
    if public["accept_terms"] is not True:
        raise SetupError("control issuer consent unavailable")
    arguments = [
        image["lego"],
        "--path",
        str(STATE / "acme"),
        "--server",
        public["issuer"],
        "--accept-tos",
        "--email",
        public["mailbox"].rstrip(".").replace(".", "@", 1),
        "--domains",
        config["origins"]["control"],
        "--dns",
        "exec",
        # The exec hook waits for the parent observation.  Passing the inner
        # Audi resolver here makes lego resolve the parent-owned control name
        # against a child-only authority and can reject an otherwise valid
        # challenge before the ACME server checks the projected TXT record.
        # Lego 4.x uses hyphenated DNS propagation flags.  Passing the old
        # dotted spelling makes every issuance invocation fail before it can
        # contact the fixture issuer, leaving the control proxy without TLS
        # material and surfacing only as a public TLS EOF.
        "--dns.propagation-wait",
        "1s",
        # Lego treats `run` as the subcommand; global flags must precede it.
        "run",
    ]
    environment = {
        "HOME": str(STATE),
        "LANG": "C.UTF-8",
        "EXEC_PATH": image["hook"],
        "EXEC_POLLING_INTERVAL": "1",
        "LEGO_DISABLE_CNAME_SUPPORT": "true",
        "LEGO_CA_CERTIFICATES": "/run/inception/audi-issuer-ca.pem",
        "INCEPTION_CONTROL_JOB": job["run_id"],
    }
    return arguments, environment


def clear_job(root: Path = proofs.ROOT) -> None:
    """The worker lock must be held and all previous issuer children dead."""
    with proofs.job_lock(root):
        (root / "job.json").unlink(missing_ok=True)


def heartbeat(
    boot: proofs.Boot,
    expected: proofs.Configuration,
    ready: bool,
    root: Path = proofs.ROOT,
    namespace: Path = proofs.NAMESPACE,
) -> None:
    """Publish only while the accepted namespace still matches this worker."""
    fd = os.open(namespace / "ingress.lock", os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(fd, "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if proofs.configuration(boot, namespace) != expected:
            raise SetupError("control namespace changed")
        publish(
            namespace / "control-publication.json",
            encode(proofs.record(boot, ready, root, namespace)),
        )


def supervise(boot: proofs.Boot, image: Image) -> None:
    """@cc [owner:ghuntley,label:security;recovery] inception-control-worker-authority
    A single worker MUST own issuance, validate before publishing certificates,
    and publish readiness only after a fresh verified local probe. Each issuance
    process group MUST expire at its original job deadline or namespace change.
    A process exit status alone MUST NOT classify issuance as failed: ACME may
    report cleanup-hook failure after issuing the certificate, so key and
    certificate files MUST still pass the complete validator before replacement.
    Failed or invalid issuance MUST preserve previously validated serving
    material. Worker exit MUST stop its proxy; independently expiring
    publication remains required.
    Restart MUST discard prior job authority before any new publication, even if
    cached certificates are valid and no new issuance is necessary.
    """
    private_directory(STATE)
    private_directory(proofs.ROOT)
    fd = os.open(STATE / "worker.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        clear_job()
        config = proofs.configuration(boot)
        hostname = config["origins"]["control"]
        proxy = proofs.ROOT / "haproxy.cfg"
        publish(proxy, tls.proxy_config(boot, config).encode())
        validation = tls.validation_settings(
            hostname,
            image["openssl"],
            image["haproxy"],
            "/run/inception/audi-trust.pem",
            tls.CERTIFICATES,
            proxy,
        )
        module = tls.validator(image["validator"])
        process, job, material, retry, proxy_retry = None, None, None, 0, 0

        def service(action: str) -> None:
            subprocess.run(
                [image["systemctl"], action, SERVICE],
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )

        def accept(candidate: bytes) -> bytes:
            try:
                candidate = tls.validate(candidate, validation, module, proofs.ROOT)
            except (OSError, ValueError, subprocess.SubprocessError, SetupError):
                publish(proofs.ROOT / "rejection-stage", b"validate\n")
                raise
            try:
                tls.install(candidate)
            except (OSError, ValueError, subprocess.SubprocessError, SetupError):
                publish(proofs.ROOT / "rejection-stage", b"install\n")
                raise
            try:
                service("reload-or-restart")
            except (OSError, ValueError, subprocess.SubprocessError, SetupError):
                publish(proofs.ROOT / "rejection-stage", b"service\n")
                raise
            return candidate

        def clear_issuer_output() -> None:
            """Discard an earlier attempt before granting a new job authority."""
            directory = STATE / "acme" / "certificates"
            for suffix in (".key", ".crt", ".issuer.crt"):
                (directory / (hostname + suffix)).unlink(missing_ok=True)

        try:
            with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError, SetupError):
                material = accept(module.issuer_file(tls.CERTIFICATES / "full.pem", 0))
            while True:
                if proofs.configuration(boot) != config:
                    raise SetupError("control namespace changed")
                ready = material is not None and tls.probe(
                    boot["address"], hostname, validation["caFile"], material
                )
                heartbeat(boot, config, ready)
                current = proofs.now()
                if material is not None and not ready and current >= proxy_retry:
                    # Recover a failed start/reload without waiting for the next
                    # certificate renewal. Revalidate cached bytes on every try.
                    proxy_retry = current + 15000
                    with contextlib.suppress(
                        OSError, ValueError, subprocess.SubprocessError, SetupError
                    ):
                        material = accept(module.issuer_file(tls.CERTIFICATES / "full.pem", 0))
                if process is not None and job is not None:
                    status = process.poll()
                    if status is not None or current >= job["expires_at_ms"]:
                        stop_job(process)
                        process = None
                        # `current` was sampled before stopping the child.  A
                        # process that exits at the deadline can spend several
                        # seconds in stop_job while its final files are flushed.
                        # Re-sample after the process group is dead so a
                        # candidate is never consumed after the original job
                        # authority has expired.
                        completed_at = proofs.now()
                        # Old hooks are dead before removing job authority.
                        clear_job()
                        retry = completed_at + 60000
                        # Lego may report a cleanup-hook failure after Pebble has
                        # issued a valid certificate.  The candidate is still
                        # safe to install because accept() performs complete
                        # key, chain, hostname, lifetime and trust validation;
                        # stale output is fenced by clear_issuer_output().
                        if completed_at < job["expires_at_ms"]:
                            try:
                                directory = STATE / "acme" / "certificates"
                                try:
                                    candidate = wait_for_issued_material(
                                        cast(IssuerFiles, module),
                                        directory,
                                        hostname,
                                        # Keep the synchronous filesystem grace below
                                        # the five-second publication TTL so this
                                        # worker never appears stopped while
                                        # waiting for Lego's final close.
                                        min(job["expires_at_ms"], completed_at + 4000),
                                    )
                                except (
                                    OSError,
                                    ValueError,
                                    subprocess.SubprocessError,
                                    SetupError,
                                ):
                                    publish(
                                        proofs.ROOT / "rejection-stage",
                                        b"process\n" if status not in (None, 0) else b"material\n",
                                    )
                                    raise
                                material = accept(candidate)
                            except (OSError, ValueError, subprocess.SubprocessError, SetupError):
                                print(
                                    '{"event":"inception.control_certificate_rejected"}',
                                    flush=True,
                                )
                elif current >= retry and (material is None or tls.renewal_due(material)):
                    job = proofs.begin(boot)
                    arguments, environment = invocation(image, config, job)
                    clear_issuer_output()
                    process = subprocess.Popen(
                        arguments,
                        env=environment,
                        start_new_session=True,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                time.sleep(0.25)
        finally:
            stop_job(process)
            clear_job()
            service("stop")


def main() -> None:
    os.umask(0o077)
    image: Image = json.loads(Path(sys.argv[1]).read_bytes())
    sys.path.insert(0, image["guest_root"])
    from readiness import identity

    boot = identity(Path("/proc/cmdline").read_text())

    def terminate(_number: int, _frame: object) -> Never:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    supervise(boot, image)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit("Inception control certificate worker unavailable")
