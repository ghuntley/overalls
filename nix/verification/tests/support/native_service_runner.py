"""Verify real native services against an isolated HTTPS/SSH authority."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import ssl
import stat
import subprocess
import threading
import time
from collections.abc import Callable
from contextlib import ExitStack
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from typing import Literal

import native_control as control
import native_git_fixture as git_fixture
import native_github_fixture as github_fixture
import native_growth_oracle as growth_oracle
import native_omnios_growth_oracle as omnios_growth_oracle
import native_services as services

PRINCIPAL = "native.fixture.test"
USERNAME = "u200000"
SSH_LOGIN_EVENT = (
    b'{"service":"overalls-ssh-authorize","event":"ssh.login_recorded","severity":"info"}\n'
)
MAX_SERIAL_VERIFICATION = 4 * 1024 * 1024
ILLUMOS_SYNC_MARKER = b"syncing file systems... done"
FailureCategory = Literal[
    "subprocess-timeout", "subprocess", "protocol", "io", "invalid", "runtime"
]
Phase = Literal[
    "shutdown-send",
    "shutdown-vmm-wait",
    "authority-server-stop",
    "authority-dns-stop",
    "authority-thread-join",
    "authority-dns-thread-join",
    "authority-thread-check",
    "authority-server-close",
    "authority-dns-close",
    "vmm-cleanup",
    "growth-finalize",
    "receipt-image-digest",
    "receipt-firmware-digest",
    "receipt-vmm-digest",
    "service-receipt-write",
    "github-receipt-write",
]


class PhaseFailure(RuntimeError):
    def __init__(self, phase: Phase, category: FailureCategory) -> None:
        super().__init__("native service phase failed")
        self.phase = phase
        self.category = category


FLUSH_DRIVE: tuple[dict[str, str], dict[str, str]] = (
    {},
    {"cache_type": "Writeback", "io_engine": "Sync"},
)


def failure_category(error: Exception) -> FailureCategory:
    if isinstance(error, PhaseFailure):
        return error.category
    if isinstance(error, subprocess.TimeoutExpired):
        return "subprocess-timeout"
    if isinstance(error, subprocess.SubprocessError):
        return "subprocess"
    if isinstance(error, services.ProtocolError):
        return "protocol"
    if isinstance(error, OSError):
        return "io"
    if isinstance(error, ValueError):
        return "invalid"
    return "runtime"


def run_phase[T](phase: Phase, operation: Callable[[], T]) -> T:
    """@cc [owner:ghuntley,label:verification;security] native-closed-phase-diagnostics
    Phase diagnostics MUST contain only fixed phase/state/category values, never
    operation arguments, results or exception text. A failed operation MUST remain
    failed under its own phase after successful cleanup. Existing operation and
    outer deadlines MUST remain unchanged; progress MUST NOT imply acceptance.
    """
    print(f"native service phase={phase} state=started", flush=True)
    try:
        result = operation()
    except PhaseFailure:
        raise
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        raise PhaseFailure(phase, failure_category(error)) from None
    print(f"native service phase={phase} state=complete", flush=True)
    return result


@dataclass(frozen=True)
class Network:
    """Validated synthetic identity supplied by the isolated host harness."""

    address: str
    gateway: str
    mac: str

    def __post_init__(self) -> None:
        for value in (self.address, self.gateway):
            address = ipaddress.IPv4Address(value)
            if str(address) != value or address.is_multicast or address.is_unspecified:
                raise ValueError("invalid native fixture network identity")
        if self.address == self.gateway or re.fullmatch(r"02(?::[0-9a-f]{2}){5}", self.mac) is None:
            raise ValueError("invalid native fixture network identity")


DEFAULT_NETWORK = Network("10.10.0.203", "10.10.0.1", "02:fc:0a:00:00:cb")


@dataclass(frozen=True)
class Platform:
    """Closed native command dialect; no caller-supplied command paths."""

    name: services.Os

    def __post_init__(self) -> None:
        if self.name not in ("freebsd", "illumos"):
            raise ValueError("invalid native fixture platform")

    @property
    def bash(self) -> str:
        return "/usr/local/bin/bash" if self.name == "freebsd" else "/bin/bash"

    @property
    def sudo(self) -> str:
        return "/usr/local/bin/sudo" if self.name == "freebsd" else "/usr/bin/sudo"

    @property
    def git(self) -> str:
        return "/usr/local/bin/git" if self.name == "freebsd" else "/usr/bin/git"

    @property
    def ps(self) -> str:
        return "/bin/ps" if self.name == "freebsd" else "/usr/bin/ps"

    @property
    def home(self) -> str:
        return "/home/u200000" if self.name == "freebsd" else "/export/home/u200000"

    @property
    def shutdown(self) -> str:
        return "/sbin/shutdown -p now" if self.name == "freebsd" else "/usr/sbin/poweroff"


@dataclass(frozen=True)
class BootContext:
    """Private in-process capability for a separately maintained machine oracle."""

    uds: Path
    boot: services.Boot
    fixture: Path
    work: Path
    network: Network
    platform: Platform
    process: subprocess.Popen[bytes]
    authority: control.Authority
    api: Path | None = None


def firecracker_arguments(vmm: Path, metadata: Path, config: Path, api: Path | None) -> list[str]:
    """@cc [owner:ghuntley,label:verification] native-vmm-log-destination
    VMM diagnostics MUST use the owned work directory's explicit log path,
    because Firecracker's default logger shares stdout with guest serial bytes.
    The API MUST remain disabled unless a private Unix test socket is supplied.
    """
    control = ["--no-api"] if api is None else ["--api-sock", str(api)]
    return [
        str(vmm),
        "--enable-pci",
        "--log-path",
        str(config.parent / "vmm.log"),
        *control,
        "--metadata",
        str(metadata),
        "--config-file",
        str(config),
    ]


def prepare_api_socket(api: Path | None, previous: subprocess.Popen[bytes] | None) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-test-api-socket-lifetime
    An enabled test API MUST use one Unix socket inside the private work root.
    Cleanup MUST refuse while the preceding VM lives and MUST unlink only the
    test user's actual socket. Links, files and foreign-owned paths MUST refuse.
    The default no-API path MUST perform no API filesystem access.
    """
    if api is None:
        return
    if previous is not None and previous.poll() is None:
        raise RuntimeError("cannot replace the API socket of a live native VM")
    try:
        metadata = api.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise ValueError("native test API cleanup requires the owned Unix socket")
    api.unlink()


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def alive(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        raise RuntimeError("native service VM exited unexpectedly")


def wait_kernel(
    process: subprocess.Popen[bytes],
    uds: Path,
    binding: services.Binding,
    expected: str,
    platform: Platform,
) -> services.Boot:
    # OmniOS boots through firmware and can spend several minutes rebuilding
    # its boot archive before the native vsock agent appears.  Keep the
    # FreeBSD bound unchanged, but give the firmware-backed illumos image a
    # bounded five-minute attestation window.
    deadline = time.monotonic() + (300 if platform.name == "illumos" else 240)
    while True:
        alive(process)
        try:
            return services.kernel_boot(uds, binding, platform.name, expected)
        except (OSError, services.ProtocolError):
            if time.monotonic() >= deadline:
                raise RuntimeError("native service boot deadline exceeded") from None
            time.sleep(0.5)


def wait_readiness(process: subprocess.Popen[bytes], uds: Path, boot: services.Boot) -> None:
    deadline = time.monotonic() + 90
    while True:
        alive(process)
        try:
            if services.readiness(uds, boot.binding) != boot:
                raise RuntimeError("native readiness changed boot identity")
            return
        except (OSError, services.ProtocolError):
            if time.monotonic() >= deadline:
                raise RuntimeError("native complete readiness deadline exceeded") from None
            time.sleep(0.5)


def wait_clean_shutdown(process: subprocess.Popen[bytes], platform: Platform, serial: Path) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-clean-shutdown-exit
    A native VM MUST exit with status zero after the requested shutdown. An
    illumos run MUST also contain the bounded filesystem-sync marker that
    causes the pinned VMM to exit; any nonzero status or missing marker MUST
    fail closed.
    """
    status = process.wait(timeout=60)
    if status != 0:
        raise RuntimeError(f"native guest did not exit cleanly (status={status})")
    if platform.name != "illumos":
        return
    metadata = serial.stat()
    if metadata.st_size > MAX_SERIAL_VERIFICATION:
        raise RuntimeError("native shutdown serial log exceeded its bound")
    evidence = serial.read_bytes()
    if ILLUMOS_SYNC_MARKER not in evidence:
        raise RuntimeError("native OmniOS shutdown evidence was incomplete")


def clean_shutdown(context: BootContext) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-shutdown-phase-oracles
    Shutdown MUST retain the bounded SSH request before the zero-exit/sync oracle.
    Only SSH status zero or 255 with empty stdout MAY reach the unchanged 60-second
    VMM wait. Distinct fixed phases MUST NOT turn a timeout into successful exit.
    """

    def send() -> None:
        result = ssh(
            context.fixture,
            context.work / "known_hosts",
            f"{context.platform.sudo} -n {context.platform.shutdown} >/dev/null 2>&1",
            network=context.network,
            shutdown_diagnostics=True,
        )
        if result.returncode not in (0, 255) or result.stdout:
            raise RuntimeError("native SSH shutdown request failed")

    run_phase("shutdown-send", send)
    run_phase(
        "shutdown-vmm-wait",
        partial(
            wait_clean_shutdown, context.process, context.platform, context.work / "serial.log"
        ),
    )


def cleanup_vm(process: subprocess.Popen[bytes]) -> None:
    """Retain the bounded terminate/wait/kill cleanup independently from shutdown evidence."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def ssh(
    fixture: Path,
    known_hosts: Path,
    command: str | None,
    *,
    user: str = USERNAME,
    key: str = "user",
    options: tuple[str, ...] = (),
    network: Network = DEFAULT_NETWORK,
    timeout: float = 20,
    shutdown_diagnostics: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    """Run fixed synthetic probes without emitting commands or output."""
    if not 0 < timeout <= 20:
        raise ValueError("invalid native SSH probe deadline")
    arguments = [
        "ssh",
        "-F",
        "/dev/null",
        "-T",
        "-i",
        str(fixture / key),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=3",
        "-o",
        "ConnectionAttempts=1",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        f"HostKeyAlias={PRINCIPAL}",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-o",
        "LogLevel=DEBUG1" if shutdown_diagnostics else "LogLevel=ERROR",
        *options,
        f"{user}@{network.address}",
    ]
    if command is not None:
        arguments.append(command)
    try:
        result = subprocess.run(
            arguments, stdin=subprocess.DEVNULL, capture_output=True, check=False, timeout=timeout
        )
    except subprocess.TimeoutExpired as error:
        if shutdown_diagnostics:
            shutdown_ssh_stage(error.stderr)
        raise
    if shutdown_diagnostics:
        shutdown_ssh_stage(result.stderr)
        # Debug lines remain ephemeral input to the closed projection. Preserve
        # the original output bound for actual SSH errors and remote output.
        result.stderr = b"\n".join(
            line for line in result.stderr.splitlines() if not line.startswith(b"debug1: ")
        )
    if len(result.stdout) > 4096 or len(result.stderr) > 4096:
        raise RuntimeError("native SSH probe exceeded its output bound")
    return result


def shutdown_ssh_stage(stderr: bytes | str | None) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-shutdown-ssh-closed-stage
    SSH diagnostic bytes MUST remain ephemeral and project only a fixed stage.
    They MUST NOT enter output, artifacts or exceptions exposed to the driver.
    This projection MUST NOT grant shutdown acceptance or alter any deadline.
    """
    body = stderr if isinstance(stderr, bytes) else b""
    stage = "unobserved"
    for marker, label in (
        (b"debug1: Connection established.", "connected"),
        (b"debug1: Server host certificate:", "host-certificate"),
        (b"Authenticated to ", "authenticated"),
        (b"debug1: Sending command:", "command-sent"),
        (b"debug1: Exit status ", "exit-status"),
    ):
        if marker in body:
            stage = label
    print(f"native service shutdown ssh_stage={stage}", flush=True)


def success(result: subprocess.CompletedProcess[bytes], expected: bytes) -> None:
    if result.returncode != 0 or result.stdout != expected:
        failure = "other"
        for marker, category in (
            (b"Connection timed out", "connect-timeout"),
            (b"Connection refused", "connect-refused"),
            (b"Permission denied", "authorization-refused"),
            (b"Host key verification failed", "host-certificate-refused"),
            (b"Connection closed", "connection-closed"),
            (b"Connection reset", "connection-reset"),
        ):
            if marker in result.stderr:
                failure = category
                break
        print(
            f"native SSH closed result mismatch: status={result.returncode} "
            f"stdout_bytes={len(result.stdout)} stderr_bytes={len(result.stderr)} failure={failure}",
            flush=True,
        )
        raise RuntimeError("native SSH did not produce its closed expected result")


def refused(result: subprocess.CompletedProcess[bytes]) -> None:
    if result.returncode == 0 or result.stdout:
        raise RuntimeError("native SSH answered a refused operation")


def ssh_checks(
    fixture: Path, work: Path, authority: control.Authority, network: Network, platform: Platform
) -> str:
    """@cc [owner:ghuntley,label:verification;security] native-ssh-real-session-evidence
    SSH checks MUST exercise real sshd, certified host keys, managed accounts,
    Bash and sudo. Session refusal MUST permit key authorization while denying
    the private login receipt and attempting startup files/client environment
    overrides. A refused session MUST execute no user bytes.
    """
    probe = partial(ssh, network=network)
    known_hosts = work / "known_hosts"
    known_hosts.write_text(
        f"@cert-authority {PRINCIPAL} {(fixture / 'ssh-ca.pub').read_text().strip()}\n"
    )
    success(
        probe(
            fixture,
            known_hosts,
            "set -eu; /usr/bin/id -u; /usr/bin/id -g; printf '%s\\n' \"$SHELL\"; "
            f"{platform.sudo} -n /usr/bin/id -u",
        ),
        f"200000\n200000\n{platform.bash}\n0\n".encode("ascii"),
    )
    print("native SSH managed identity and sudo verified", flush=True)
    refused(probe(fixture, known_hosts, "printf refused", key="wrong-user"))
    refused(probe(fixture, known_hosts, "printf refused", user="root"))
    refused(probe(fixture, known_hosts, "printf refused", user="u200001"))
    refused(
        probe(
            fixture,
            known_hosts,
            "printf refused",
            options=(
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "PreferredAuthentications=password,keyboard-interactive",
            ),
        )
    )
    wrong_hosts = work / "wrong_known_hosts"
    wrong_hosts.write_text(
        f"@cert-authority {PRINCIPAL} {(fixture / 'wrong-user.pub').read_text().strip()}\n"
    )
    refused(probe(fixture, wrong_hosts, "printf refused"))
    print("native SSH foreign authority refusals verified", flush=True)
    success(
        probe(
            fixture,
            known_hosts,
            'set -eu; mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; '
            "printf 'printf native-prelogin-startup\\n' > \"$HOME/.bashrc\"; "
            "printf 'printf native-prelogin-rc\\n' > \"$HOME/.ssh/rc\"; "
            "printf native-startup-prepared",
        ),
        b"native-startup-prepared",
    )
    print("native SSH synthetic startup fixtures prepared", flush=True)
    previous = authority.count("login_refused")
    authority.set_login_allowed(False)
    try:
        for command in (None, "printf native-user-command-before-receipt"):
            refused(
                probe(
                    fixture,
                    known_hosts,
                    command,
                    options=(
                        "-o",
                        f"SetEnv=SHLVL=0 BASH_ENV={platform.home}/.bashrc ENV={platform.home}/.bashrc",
                    ),
                )
            )
        if authority.count("login_refused") < previous + 2:
            raise RuntimeError("native session did not reach the denied private login authority")
        print("native SSH login receipt refusals verified", flush=True)
    finally:
        authority.set_login_allowed(True)
    restored = probe(
        fixture,
        known_hosts,
        'set -eu; rm -f "$HOME/.bashrc" "$HOME/.ssh/rc"; printf native-restored',
    )
    # A base login profile can source .bashrc after the successful receipt.
    if restored.returncode != 0 or restored.stdout not in (
        b"native-restored",
        b"native-prelogin-startupnative-restored",
    ):
        raise RuntimeError("native SSH did not recover after restoring login authority")
    print("native SSH login authority restoration verified", flush=True)
    scan = subprocess.run(
        ["ssh-keyscan", "-c", "-t", "ed25519", "-T", "5", network.address],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=10,
    )
    if len(scan.stdout) > 16_384 or b"ssh-ed25519-cert-v01@openssh.com" not in scan.stdout:
        raise RuntimeError("native SSH did not expose its certified host key")
    certificate = work / "observed-host-cert.pub"
    certificate.write_bytes(scan.stdout)
    fingerprint = subprocess.run(
        ["ssh-keygen", "-l", "-f", str(certificate)],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=5,
    )
    # OpenSSH fingerprints a certificate's underlying plain public key. Hashing
    # certificate bytes would mistake renewal of the same key for key rotation.
    matched = re.fullmatch(
        rb"256 (SHA256:[A-Za-z0-9+/]{43}) [^\n]* \(ED25519-CERT\)\n", fingerprint.stdout
    )
    if matched is None or len(fingerprint.stdout) > 512:
        raise RuntimeError("native SSH certificate key fingerprint is invalid")
    return matched[1].decode("ascii")


def wait_executor(process: subprocess.Popen[bytes], authority: control.Authority) -> None:
    deadline = time.monotonic() + 90
    while not authority.snapshot().execution_completed:
        alive(process)
        if time.monotonic() >= deadline:
            print(
                "native executor fixed deadline: "
                + " ".join(
                    f"{event}={authority.count(event)}"
                    for event in ("register", "claim", "started", "completed")
                ),
                flush=True,
            )
            raise RuntimeError("native fixed execution deadline exceeded")
        time.sleep(0.25)
    if any(authority.count(event) < 1 for event in ("register", "claim", "started", "completed")):
        raise RuntimeError("native executor omitted a fenced execution phase")


@dataclass(frozen=True, repr=False)
class GroupObservation:
    """Ephemeral numeric identities; never serialized to receipts or diagnostics."""

    parent: int
    descendant: int
    members: tuple[tuple[int, str], ...]
    present: bool

    @property
    def live(self) -> bool:
        return (
            self.present
            and len(self.members) == 2
            and all(state[0] not in ("Z", "X") for _, state in self.members)
        )

    @property
    def absent(self) -> bool:
        return not self.present and not self.members


def process_group(payload: bytes, expected: tuple[int, int] | None = None) -> GroupObservation:
    """Narrow bounded marker/ps output without accepting PID reuse or escaped groups."""
    if len(payload) > 256:
        raise ValueError("native process observation exceeds its bound")
    lines = payload.splitlines()
    if not 2 <= len(lines) <= 4 or not payload.endswith(b"\n"):
        raise ValueError("invalid native process observation")
    marker = re.fullmatch(rb"([1-9][0-9]{0,9}) ([1-9][0-9]{0,9})", lines[0])
    if marker is None:
        raise ValueError("invalid native process identity marker")
    parent, descendant = (int(marker[index]) for index in (1, 2))
    if (
        not 1 < parent <= 2_147_483_647
        or not 1 < descendant <= 2_147_483_647
        or parent == descendant
        or (expected is not None and (parent, descendant) != expected)
        or lines[-1] not in (b"group-present", b"group-absent")
    ):
        raise ValueError("native process identity differs")
    members: dict[int, str] = {}
    for line in lines[1:-1]:
        member = re.fullmatch(
            rb"[ \t]*([1-9][0-9]{0,9})[ \t]+([1-9][0-9]{0,9})[ \t]+([DILORSTWXZ][A-Za-z+<>]{0,7})[ \t]*",
            line,
        )
        if member is None:
            raise ValueError("invalid native process member")
        pid, group = int(member[1]), int(member[2])
        if pid not in (parent, descendant) or pid in members or group != parent:
            raise ValueError("native process escaped or changed its group")
        members[pid] = member[3].decode("ascii")
    return GroupObservation(
        parent, descendant, tuple(members.items()), lines[-1] == b"group-present"
    )


def withdrawal_deadline(snapshot: control.Snapshot, now: float) -> float:
    """Reject results or observations at the independent command deadline boundary."""
    if (
        snapshot.started_at is None
        or snapshot.terminal_attempts
        or not 0 <= now - snapshot.started_at < control.WITHDRAWAL_SECONDS
    ):
        raise RuntimeError("native lease withdrawal deadline or result boundary failed")
    return snapshot.started_at + control.WITHDRAWAL_SECONDS


def observe_group(
    context: BootContext, deadline: float, expected: tuple[int, int] | None
) -> GroupObservation | None:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("native lease process observation was late")
    root = control.LEASE_PROBE_ROOT
    state = "state" if context.platform.name == "freebsd" else "s"
    command = (
        f"set -eu; test -f {root}/pids; test ! -L {root}/pids; "
        f'test "$(wc -c < {root}/pids)" -le 24; '
        f"read -r parent descendant extra < {root}/pids; "
        '[[ "$parent" =~ ^[1-9][0-9]{0,9}$ && "$descendant" =~ ^[1-9][0-9]{0,9}$ '
        '&& -z "$extra" ]]; printf \'%s %s\\n\' "$parent" "$descendant"; '
        f'{context.platform.ps} -p "$parent,$descendant" -o pid= -o pgid= -o {state}= '
        '|| test "$?" -eq 1; '
        "if kill -0 -- \"-$parent\" 2>/dev/null; then printf 'group-present\\n'; "
        "else printf 'group-absent\\n'; fi"
    )
    try:
        result = ssh(
            context.fixture,
            context.work / "known_hosts",
            f"{context.platform.sudo} -n {context.platform.bash} -c " + shlex.quote(command),
            network=context.network,
            # SSHD/PAM login receipt processing on Illumos can exceed two seconds;
            # retain a bounded observation while leaving the fifteen-second fence
            # budget to the caller.
            timeout=min(5.0, remaining),
        )
    except subprocess.TimeoutExpired:
        # A slow login is no observation of the group; callers retry inside
        # the same fence deadline, and a late probe still fails below.
        if time.monotonic() >= deadline:
            raise RuntimeError("native lease process observation was late") from None
        return None
    if time.monotonic() >= deadline:
        raise RuntimeError("native lease process observation was late")
    if result.returncode == 1 and not result.stdout and not result.stderr:
        return None
    # The native forced SSH session emits its fixed catalogued login event on
    # stderr before replacing itself with Bash. Accept that exact event while
    # refusing arbitrary command or diagnostic bytes.
    if result.returncode != 0 or result.stderr not in (b"", SSH_LOGIN_EVENT):
        raise RuntimeError("native lease process observation failed")
    return process_group(result.stdout, expected)


def executor_withdrawal(context: BootContext) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-current-lease-history
    The runner MUST arm the long command only after certified SSH and ordinary
    fixed completion, observe its live parent-led group and live descendant,
    then withdraw its exact heartbeat. It MUST observe the whole group absent
    before accepted-start plus fifteen seconds, after an actual matching HTTP
    403 and with no cancelled result attempts, then complete a strictly newer
    fence. Observations MUST never kill the group or log PIDs, arguments or output.
    """
    print("native executor phase=ordinary-completion", flush=True)
    wait_executor(context.process, context.authority)
    root = control.LEASE_PROBE_ROOT
    prepare = f"set -eu; test ! -e {root}; umask 077; mkdir {root}; printf native-lease-prepared"
    success(
        ssh(
            context.fixture,
            context.work / "known_hosts",
            f"{context.platform.sudo} -n {context.platform.bash} -c " + shlex.quote(prepare),
            network=context.network,
        ),
        b"native-lease-prepared",
    )
    print("native executor phase=withdrawal-start", flush=True)
    context.authority.arm_withdrawal()
    awaiting = time.monotonic() + 30
    while context.authority.snapshot().started_at is None:
        alive(context.process)
        if time.monotonic() >= awaiting:
            raise RuntimeError("native withdrawal command did not start")
        time.sleep(0.1)
    print("native executor phase=live-group-observation", flush=True)
    identity: tuple[int, int] | None = None
    while identity is None:
        alive(context.process)
        deadline = withdrawal_deadline(context.authority.snapshot(), time.monotonic())
        observed = observe_group(context, deadline, None)
        if observed is not None:
            if not observed.live:
                raise RuntimeError("native withdrawal group was not initially live")
            identity = (observed.parent, observed.descendant)
        else:
            time.sleep(0.1)
    print("native executor phase=withdrawn-group-observation", flush=True)
    context.authority.request_withdrawal()
    while True:
        alive(context.process)
        snapshot = context.authority.snapshot()
        deadline = withdrawal_deadline(snapshot, time.monotonic())
        if snapshot.phase != control.WithdrawalPhase.REJECTED:
            time.sleep(0.1)
            continue
        observed = observe_group(context, deadline, identity)
        snapshot = context.authority.snapshot()
        withdrawal_deadline(snapshot, time.monotonic())
        if (
            snapshot.phase == control.WithdrawalPhase.REJECTED
            and observed is not None
            and observed.absent
        ):
            context.authority.confirm_group_dead()
            break
        time.sleep(0.1)
    print("native executor phase=fresh-fence-completion", flush=True)
    awaiting = time.monotonic() + 90
    while True:
        alive(context.process)
        snapshot = context.authority.snapshot()
        if snapshot.terminal_attempts:
            raise RuntimeError("native cancelled executor attempted a result")
        if snapshot.phase == control.WithdrawalPhase.COMPLETE:
            break
        if time.monotonic() >= awaiting:
            raise RuntimeError("native fresh-fence execution did not complete")
        time.sleep(0.1)
    cleanup = f"set -eu; rm {root}/pids; rmdir {root}; printf native-lease-cleaned"
    success(
        ssh(
            context.fixture,
            context.work / "known_hosts",
            f"{context.platform.sudo} -n {context.platform.bash} -c " + shlex.quote(cleanup),
            network=context.network,
        ),
        b"native-lease-cleaned",
    )


def git_ownership_refused(result: subprocess.CompletedProcess[bytes]) -> None:
    if (
        result.returncode == 0
        or result.stdout
        or b"detected dubious ownership in repository" not in result.stderr
    ):
        print(
            f"native ownership refusal mismatch: status={result.returncode} "
            f"stdout_bytes={len(result.stdout)} stderr_bytes={len(result.stderr)} "
            f"dubious_ownership={b'detected dubious ownership in repository' in result.stderr}",
            flush=True,
        )
        raise RuntimeError("native unrelated repository ownership was not refused")


def checkout(
    context: BootContext, repository: git_fixture.Repository, *, retained_upgrade: bool = False
) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-workspace-actual-checkout
    Checkout evidence MUST deliver the source through the boot-bound receiver,
    wait for the actual native Git operation, and verify its commit, shallow
    metadata and fixture file digests through the managed SSH account. A source
    acceptance or a done marker alone MUST NOT establish checkout evidence.
    Managed-user Git MUST succeed for that exact checkout. For current images,
    this call MUST additionally run checkout_ownership. Retained images defer
    that strict oracle until their real updater completes; the caller MUST run
    checkout_ownership before issuing any retained acceptance receipt.
    """
    print("native workspace phase=source-delivery", flush=True)
    services.workspace(context.uds, context.boot.binding, repository.source())
    probe = partial(ssh, context.fixture, context.work / "known_hosts", network=context.network)
    deadline = time.monotonic() + 90
    print("native workspace phase=checkout-completion", flush=True)
    while True:
        alive(context.process)
        status = probe('test "$(cat /run/overalls-workspace/status)" = done')
        if status.returncode == 0 and not status.stdout:
            break
        if time.monotonic() >= deadline:
            print("native workspace outcome=completion-deadline", flush=True)
            raise RuntimeError("native workspace checkout deadline exceeded")
        time.sleep(0.5)
    root = "/workspace/unpublished-fixture"
    print("native workspace phase=commit-and-shallow-verification", flush=True)
    success(
        probe(
            f"set -eu; test -f {root}/.git/shallow; test -w {root}; "
            f"{context.platform.git} -C {root} rev-parse HEAD"
        ),
        repository.commit.encode("ascii") + b"\n",
    )
    for name, expected in repository.manifest.items():
        # Names originate only from the closed local fixture, never a request.
        if name not in git_fixture.FILES:
            raise RuntimeError("invalid native checkout fixture manifest")
        print("native workspace phase=manifest-verification", flush=True)
        result = probe(f"set -eu; test -w {root}/{name}; cat {root}/{name}")
        if result.returncode != 0 or hashlib.sha256(result.stdout).hexdigest() != expected:
            raise RuntimeError("native workspace checkout bytes differ from the fixture")
    if not retained_upgrade:
        checkout_ownership(context)


def checkout_ownership(context: BootContext) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-upgraded-checkout-ownership
    Managed-user Git MUST reject an unrelated root-owned repository with its
    actual dubious-ownership refusal after current setup or a real retained
    upgrade. A transport error, success, or unrelated Git error MUST NOT pass.
    """
    probe = partial(ssh, context.fixture, context.work / "known_hosts", network=context.network)
    unrelated = "/workspace/native-unrelated-root-repository"
    print("native workspace phase=unrelated-repository-preparation", flush=True)
    prepare = (
        f"set -eu; test ! -e {unrelated}; umask 022; mkdir {unrelated}; "
        f"{context.platform.git} -C {unrelated} init --quiet; printf native-unrelated-repository"
    )
    success(
        probe(f"{context.platform.sudo} -n {context.platform.bash} -c " + shlex.quote(prepare)),
        b"native-unrelated-repository",
    )
    try:
        print("native workspace phase=unrelated-ownership-refusal", flush=True)
        safe_directories = probe(f"{context.platform.git} config --get-all safe.directory")
        print(
            "native workspace ownership policy: "
            f"all_repositories={b'*' in safe_directories.stdout.splitlines()} "
            f"workspace_wildcard={b'/workspace/*' in safe_directories.stdout.splitlines()}",
            flush=True,
        )
        git_ownership_refused(probe(f"{context.platform.git} -C {unrelated} status --porcelain"))
    finally:
        cleanup = f"rm -rf {unrelated}"
        result = probe(
            f"{context.platform.sudo} -n {context.platform.bash} -c " + shlex.quote(cleanup)
        )
        if result.returncode != 0 or result.stdout:
            raise RuntimeError("native unrelated repository cleanup failed")


def git_attribution(context: BootContext) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-current-boot-git-attribution
    A capable candidate MUST expose this boot's MMDS public name/email through
    effective personal-user Git configuration and an actual commit without
    author overrides on every boot. Epoch-distinct values MUST replace the
    previous boot's attribution; this synthetic attribution grants no authority.
    """
    epoch = context.boot.binding.execution_epoch
    name = f"Native Fixture {epoch}"
    email = f"native-{epoch}@fixture.test"
    git = context.platform.git
    command = (
        "set -eu; test $(id -u) = 200000; "
        f'test "$({git} config user.name)" = {shlex.quote(name)}; '
        f'test "$({git} config user.email)" = {shlex.quote(email)}; '
        f'root="$HOME/native-attribution-{epoch}"; mkdir "$root"; '
        f'{git} -C "$root" init -q; '
        f'{git} -C "$root" commit -q --allow-empty -m attribution; '
        f'test "$({git} -C "$root" log -1 --format=%an)" = {shlex.quote(name)}; '
        f'test "$({git} -C "$root" log -1 --format=%ae)" = {shlex.quote(email)}; '
        "printf native-current-boot-git-attribution-verified"
    )
    success(
        ssh(context.fixture, context.work / "known_hosts", command, network=context.network),
        b"native-current-boot-git-attribution-verified",
    )


def metadata(
    path: Path, binding: services.Binding, network: Network, *, git_identity: bool = False
) -> None:
    path.write_text(
        json.dumps(
            {
                "lilly": {
                    "version": 1,
                    "placement": binding.placement_id,
                    "execution_epoch": binding.execution_epoch,
                    "boot_challenge": binding.boot_challenge,
                    "ipv4": network.address,
                    "prefix_length": 32,
                    "gateway": network.gateway,
                    "mac": network.mac,
                    **(
                        {
                            "git_identity": {
                                "version": 1,
                                "name": f"Native Fixture {binding.execution_epoch}",
                                "email": f"native-{binding.execution_epoch}@fixture.test",
                            }
                        }
                        if git_identity
                        else {}
                    ),
                }
            }
        ),
        encoding="utf-8",
    )
    path.chmod(0o600)


def github_tools(context: BootContext, generation: int) -> dict[str, object]:
    """Run shipped retained bootstrap, managed gh, Git and LFS as the personal UID."""
    authority = context.authority
    plugin = authority.github
    if plugin is None:
        raise ValueError("missing native GitHub fixture")
    prepare = (
        "set -eu; test $(id -u) = 200000; "
        + (
            'test "$(cat "$HOME/github-preserved")" = github-preserved; '
            f'test "$({context.platform.git} config --global fixture.preserved)" = retained; '
            if generation
            else 'printf github-preserved > "$HOME/github-preserved"; '
            f"{context.platform.git} config --global fixture.preserved retained; "
        )
        + "printf github-prepared"
    )
    success(
        ssh(context.fixture, context.work / "known_hosts", prepare, network=context.network),
        b"github-prepared",
    )
    with authority._lock:
        plugin.arm()
    deadline = time.monotonic() + 180
    while True:
        alive(context.process)
        with authority._lock:
            complete = plugin.completed and plugin.bootstrap_completed
        if complete:
            break
        if time.monotonic() >= deadline:
            with authority._lock:
                print(
                    "native retained GitHub deadline: "
                    f"bootstrap_started={plugin.bootstrap_started} "
                    f"bootstrap_completed={plugin.bootstrap_completed} "
                    f"bootstrap_failed={plugin.bootstrap_failed} "
                    f"bootstrap_exit_code={plugin.bootstrap_exit_code} "
                    f"bootstrap_artifact_fetches={authority.count('github_bootstrap_artifact')} "
                    f"tool_artifact_fetches={authority.count('github_tool_artifact')} "
                    f"gh_fetches={authority.count('github_tool_artifact_gh')} "
                    f"lfs_fetches={authority.count('github_tool_artifact_git-lfs')} "
                    f"config_fetches={authority.count('github_tool_artifact_github.gitconfig')} "
                    f"streams_completed={authority.count('github_artifact_stream_completed')} "
                    f"streams_failed={authority.count('github_artifact_stream_failed')} "
                    f"stream_failure_categories={[(category.value, authority.count(f'github_artifact_stream_failed_{category.value}')) for category in control.ArtifactStreamFailure]} "
                    f"registrations={authority.count('register')} "
                    f"heartbeat_requests={authority.count('heartbeat_request')} "
                    f"heartbeats_accepted={authority.count('heartbeat')} "
                    f"heartbeat_responses_sent={authority.count('heartbeat_response_sent')} "
                    f"heartbeat_responses_failed={authority.count('heartbeat_response_failed')} "
                    f"heartbeat_response_failure_categories={[(category.value, authority.count(f'heartbeat_response_failed_{category.value}')) for category in control.ArtifactStreamFailure]} "
                    f"transport_stages={[(event.value, authority.count(event.value)) for event in control.TransportEvent]} "
                    f"transport_during_artifact={[(event.value, authority.count(event.value + '_during_artifact')) for event in (control.TransportEvent.ACCEPTED, control.TransportEvent.HANDSHAKE_STARTED, control.TransportEvent.HANDSHAKE_SUCCEEDED, control.TransportEvent.HEARTBEAT_HEADERS, control.TransportEvent.HEARTBEAT_RESPONSE)]} "
                    f"transport_gauges={[(gauge, authority.count(gauge)) for gauge in ('transport_handlers_active', 'transport_handlers_highwater', 'transport_artifacts_active', 'transport_artifacts_highwater')]} "
                    f"maintenance_started={plugin.started} "
                    f"maintenance_start_count={authority.count('github_tools_started')} "
                    f"maintenance_completed={plugin.completed} "
                    f"maintenance_failure={plugin.maintenance_failure}",
                    flush=True,
                )
            for name, argument in (("gh", "--version"), ("git-lfs", "version")):
                executable = (
                    f"/var/lib/overalls/github-tools/generations/{plugin.generation}/{name}"
                )
                probe = ssh(
                    context.fixture,
                    context.work / "known_hosts",
                    f"test -x {executable} && {executable} {argument} >/dev/null 2>&1",
                    network=context.network,
                )
                print(
                    f"native staged GitHub health: tool={name} status={probe.returncode}",
                    flush=True,
                )
            raise RuntimeError("native retained GitHub bootstrap did not complete")
        time.sleep(0.1)
    branch = f"native-github-{generation}"
    command = (
        "set -eu; phase=preserved-config; "
        'trap \'printf "native-github-phase=%s\\n" "$phase" >&2\' EXIT; '
        "test $(id -u) = 200000; "
        'test "$(cat "$HOME/github-preserved")" = github-preserved; '
        f'test "$({context.platform.git} config --global fixture.preserved)" = retained; '
        "phase=cli-version; "
        "gh --version | head -1 | grep -q 'gh version 2.102.0'; "
        "phase=cli-api; "
        'test "$(gh api user --jq .login)" = native-fixture; '
        "phase=secret-refusal; "
        "if gh auth token >/dev/null 2>&1; then exit 1; fi; "
        'test ! -e "$HOME/.config/gh/hosts.yml"; test ! -e "$HOME/.git-credentials"; '
        "phase=initial-clone; "
        f'work="$HOME/github-{generation}"; mkdir "$work"; cd "$work"; '
        f"{context.platform.git} clone -q https://github.com{git_fixture.PREFIX} original; "
        f"cd original; {context.platform.git} checkout -q -b {branch}; "
        "phase=lfs-commit; "
        f"{context.platform.git} lfs install --local >/dev/null; "
        f"{context.platform.git} lfs track '*.dat' >/dev/null; "
        "printf 'native-github-lfs-proof\\n' > proof.dat; "
        f"{context.platform.git} add .gitattributes proof.dat; "
        f"{context.platform.git} -c user.name=Native -c user.email=native@fixture.test commit -q -m proof; "
        "phase=push; "
        f"{context.platform.git} push -q origin {branch} >/dev/null; cd ..; "
        "phase=lfs-clone; "
        f"{context.platform.git} clone -q --branch {branch} https://github.com{git_fixture.PREFIX} verified; "
        f"{context.platform.git} -C verified lfs install --local >/dev/null; "
        f"{context.platform.git} -C verified lfs pull >/dev/null; "
        'test "$(cat verified/proof.dat)" = native-github-lfs-proof; '
        'test ! -e "$HOME/.config/gh/hosts.yml"; test ! -e "$HOME/.git-credentials"; '
        "printf native-github-tools-verified"
    )
    result = ssh(context.fixture, context.work / "known_hosts", command, network=context.network)
    if result.returncode != 0:
        for phase in (
            "preserved-config",
            "cli-version",
            "cli-api",
            "secret-refusal",
            "initial-clone",
            "lfs-commit",
            "push",
            "lfs-clone",
        ):
            if result.stderr.endswith(f"native-github-phase={phase}\n".encode()):
                print(f"native retained GitHub failed phase={phase}", flush=True)
                break
    success(result, b"native-github-tools-verified")
    with authority._lock:
        return {"generation": plugin.generation, "outcome": plugin.outcome}


def run(
    image: Path,
    vmm: Path,
    fixture: Path,
    tap: str,
    work: Path,
    *,
    network: Network = DEFAULT_NETWORK,
    os_name: services.Os = "freebsd",
    verify_boot: Callable[[BootContext], None] | None = None,
    growth: bool = False,
    crash_first_boot: bool = False,
    enable_api: bool = False,
    github_tools_release: Path | None = None,
    github_executor_release: Path | None = None,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-service-machine-scope
    Checks MUST exercise source-built daemons after MMDS/static-network setup
    in Firecracker on a fresh disposable disk. That disk MUST survive verified
    clean shutdowns, or one observed first-boot SIGKILL when explicitly enabled
    for the separate crash oracle. New MMDS authority MUST change boot IDs and refuse
    previous epochs. Synthetic receipts MUST NOT grant catalog admission or
    establish native isolation or crash recovery.
    The default MUST disable the Firecracker API. Only an explicitly enabled
    test oracle MAY receive the private Unix API socket; no TCP control or
    production control endpoint may be introduced.
    Retained GitHub checks MUST complete their workflow on both clean boots
    before the unchanged final-boot cancellation oracle. The first shutdown
    MUST use independent certified SSH and observed clean VMM exit, never the
    cancellation command. A failed final oracle MUST prevent success receipts;
    retained receipts MUST NOT claim cancellation coverage on every boot.
    """
    platform = Platform(os_name)
    if (github_tools_release is None) != (github_executor_release is None):
        raise ValueError("both native GitHub releases are required")
    if growth and crash_first_boot:
        raise ValueError("native growth cannot share the crash-recovery scenario")
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Nix normalizes store modes to read-only public files. Restore private
    # permissions on this disposable fixture copy for OpenSSH's key checks.
    local_fixture = work / "authority"
    local_fixture.mkdir(mode=0o700)
    for name in (
        "ca.pem",
        "tls.pem",
        "tls.key",
        "ssh-ca",
        "ssh-ca.pub",
        "user",
        "user.pub",
        "wrong-user",
        "wrong-user.pub",
    ):
        target = local_fixture / name
        shutil.copyfile(fixture / name, target)
        target.chmod(0o600)
    fixture = local_fixture
    git = shutil.which("git")
    if git is None:
        raise RuntimeError("pinned native Git fixture tool is unavailable")
    repository = git_fixture.Repository.create(
        work / "git", Path(git).resolve(), allow_writes=github_tools_release is not None
    )
    github_observations: list[dict[str, object]] = []
    manifest = services.decode_object((image / "manifest.json").read_bytes())
    kernel = services.decode_object(json.dumps(manifest.get("kernel")).encode("utf-8"))
    expected = kernel.get("sha256")
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise ValueError("missing exact native kernel identity")
    disk = work / "disk.raw"
    shutil.copyfile(image / "disk.raw", disk)
    growth_check: growth_oracle.Oracle | omnios_growth_oracle.Oracle | None = None
    if growth:
        growth_check = (
            growth_oracle.Oracle(disk, work)
            if os_name == "freebsd"
            else omnios_growth_oracle.Oracle(disk, work, expected_kernel_sha256=expected)
        )
    uds = work / "v.sock"
    api = work / "api.sock" if enable_api else None
    metadata_path = work / "metadata.json"
    firmware = image / "firmware"
    config = {
        "boot-source": {"kernel_image_path": str(firmware.resolve())},
        # FreeBSD flush acknowledgement needs virtio flush, which only Lilly's
        # production Writeback/Sync drives advertise (lilly/lib/lilly/vm/jail.ex).
        # OmniOS flushes through ZFS sync; its Writeback path is covered by the
        # durability checks, and here host fsync per ZFS flush outruns deadlines.
        "drives": [
            {
                "drive_id": "rootfs",
                "path_on_host": str(disk),
                "is_root_device": True,
                "is_read_only": False,
                **FLUSH_DRIVE[os_name == "freebsd"],
            }
        ],
        "machine-config": {"vcpu_count": 2, "mem_size_mib": 2048},
        "vsock": {"guest_cid": 3, "uds_path": str(uds)},
        "network-interfaces": [
            {"iface_id": "native0", "host_dev_name": tap, "guest_mac": network.mac}
        ],
        "mmds-config": {
            "version": "V2",
            "network_interfaces": ["native0"],
            "ipv4_address": "169.254.169.254",
        },
    }
    if growth_check is not None:
        config["drives"].append(
            {
                "drive_id": "foreign",
                "path_on_host": str(growth_check.foreign),
                "is_root_device": False,
                "is_read_only": False,
                **FLUSH_DRIVE[os_name == "freebsd"],
            }
        )
    config_path = work / "firecracker.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    boots: list[services.Boot] = []
    boot_endings: list[str] = []
    host_keys: list[str] = []
    trust_digest = ""
    stage = "boot"
    process: subprocess.Popen[bytes] | None = None
    try:
        boot_count = 3 if growth else 2
        for generation in range(boot_count):
            growth_observation: growth_oracle.Guest | None = None
            if growth_check is not None:
                growth_check.before_boot(generation)
            binding = services.Binding(
                "dddddddd-dddd-4ddd-8ddd-000000000201", 7 + generation, secrets.token_hex(32)
            )
            metadata(
                metadata_path,
                binding,
                network,
                git_identity=manifest.get("git_identity_version") == 1,
            )
            for path in work.glob("v.sock*"):
                path.unlink()
            prepare_api_socket(api, process)
            with (
                (work / "serial.log").open("ab") as serial,
                (work / "vmm-stderr.log").open("ab") as vmm_stderr,
            ):
                process = subprocess.Popen(
                    firecracker_arguments(vmm, metadata_path, config_path, api),
                    stdin=subprocess.DEVNULL,
                    stdout=serial,
                    stderr=vmm_stderr,
                )
                try:
                    stage = "boot"
                    boot = wait_kernel(process, uds, binding, expected, platform)
                    print("native service current-boot kernel verified", flush=True)
                    if boots and boot.boot_id == boots[0].boot_id:
                        raise RuntimeError("native restart retained its boot ID")
                    boots.append(boot)
                    stage = "network"
                    subprocess.run(
                        ["ping", "-c", "1", "-W", "5", network.address],
                        check=True,
                        timeout=10,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    stage = "readiness-withheld"
                    services.readiness_withheld(uds)
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.minimum_version = ssl.TLSVersion.TLSv1_2
                    context.load_cert_chain(fixture / "tls.pem", fixture / "tls.key")
                    authority = control.Authority(
                        control.Config(
                            fixture / "ssh-ca",
                            PRINCIPAL,
                            frozenset({network.address}),
                            control.key((fixture / "user.pub").read_text().strip()),
                            execution_probe=True,
                            receipt=work / f"control-{generation}.json",
                        )
                    )
                    if github_tools_release is not None and github_executor_release is not None:
                        authority.github = github_fixture.GitHub(
                            github_tools_release, github_executor_release, os_name + "-amd64"
                        )
                    with ExitStack() as authority_scope:
                        server = control.Server(
                            ("169.254.254.1", 443), context, authority, repository=repository
                        )
                        authority_scope.callback(
                            run_phase, "authority-server-close", server.server_close
                        )
                        dns = git_fixture.DNSServer(("1.1.1.1", 53), frozenset({network.address}))
                        authority_scope.callback(run_phase, "authority-dns-close", dns.server_close)
                        thread = threading.Thread(target=server.serve_forever, daemon=True)
                        dns_thread = threading.Thread(target=dns.serve_forever, daemon=True)
                        thread.start()
                        dns_thread.start()
                        try:
                            stage = "trust"
                            trust_digest = services.trust(
                                uds, boot, [(fixture / "ca.pem").read_text()]
                            )
                            stage = "complete-readiness"
                            wait_readiness(process, uds, boot)
                            print("native service complete readiness verified", flush=True)
                            stage = "flush"
                            services.flush(uds, boot)
                            if generation:
                                services.refused(
                                    uds,
                                    1026,
                                    services.encode(
                                        {
                                            "version": 1,
                                            "operation": "sync",
                                            "nonce": secrets.token_hex(32),
                                            **boots[0].binding.fields(),
                                        }
                                    )
                                    + b"\n",
                                )
                            stage = "workspace-refusals"
                            services.workspace_refusals(uds, binding)
                            if generation and manifest.get("git_identity_version") == 1:
                                services.refused(
                                    uds,
                                    1031,
                                    services.encode(
                                        {
                                            "version": 1,
                                            **boots[0].binding.fields(),
                                            "nonce": secrets.token_hex(32),
                                            "source": repository.source(),
                                        }
                                    )
                                    + b"\n",
                                )
                            stage = "terminal-control"
                            services.terminal(uds, binding)
                            stage = "ssh"
                            host_keys.append(
                                ssh_checks(fixture, work, authority, network, platform)
                            )
                            print("native service SSH authority verified", flush=True)
                            if platform.name == "illumos":
                                stage = "installed-omnios-image-verification"
                                verification = (
                                    "set -eu; build_id=$(/usr/bin/cat /etc/overalls/kernel-build-id); "
                                    "/usr/bin/python3.12 -B -E -s "
                                    "/opt/overalls/libexec/image-candidate/native_image.py "
                                    'verify "$build_id" >/dev/null 2>&1; '
                                    "printf native-installed-image-verified"
                                )
                                success(
                                    ssh(
                                        fixture,
                                        work / "known_hosts",
                                        f"{platform.sudo} -n {platform.bash} -c "
                                        + shlex.quote(verification),
                                        network=network,
                                    ),
                                    b"native-installed-image-verified",
                                )
                                print("native service installed OmniOS image verified", flush=True)
                            boot_context = BootContext(
                                uds, boot, fixture, work, network, platform, process, authority, api
                            )
                            stage = "workspace-checkout"
                            checkout(
                                boot_context,
                                repository,
                                retained_upgrade=authority.github is not None,
                            )
                            print("native service workspace checkout verified", flush=True)
                            if manifest.get("git_identity_version") == 1:
                                stage = "git-attribution"
                                git_attribution(boot_context)
                                print(
                                    f"native current-boot Git attribution verified boot={generation}",
                                    flush=True,
                                )
                            stage = "terminal-session"
                            services.terminal_session(uds, binding, platform.name)
                            print("native service managed PTY verified", flush=True)
                            if authority.github is not None:
                                stage = "retained-github-tools"
                                github_observations.append(github_tools(boot_context, generation))
                                checkout_ownership(boot_context)
                                print(
                                    f"native retained GitHub tools verified boot={generation}",
                                    flush=True,
                                )
                            if authority.github is None or generation == boot_count - 1:
                                stage = "executor"
                                executor_withdrawal(boot_context)
                                print("native service fenced execution verified", flush=True)
                            stage = "retained-home"
                            retained_command = (
                                'test "$(cat "$HOME/native-retained")" = native-home-retained'
                                if generation
                                else 'printf native-home-retained > "$HOME/native-retained"'
                            )
                            success(
                                ssh(
                                    fixture,
                                    work / "known_hosts",
                                    "set -eu; "
                                    + retained_command
                                    + "; printf native-home-retained",
                                    network=network,
                                ),
                                b"native-home-retained",
                            )
                            stage = "kernel-recheck"
                            services.kernel(uds, boot, platform.name, expected)
                            if growth_check is not None:
                                stage = "native-root-growth"
                                growth_observation = growth_check.guest(
                                    partial(
                                        ssh,
                                        fixture,
                                        work / "known_hosts",
                                        network=network,
                                    ),
                                    platform.sudo,
                                )
                            if verify_boot is not None:
                                stage = "external-machine-oracle"
                                verify_boot(boot_context)
                            if crash_first_boot and generation == 0:
                                stage = "abrupt-guest-death"
                                alive(process)
                                process.kill()
                                if process.wait(timeout=10) != -signal.SIGKILL:
                                    raise RuntimeError("native guest abrupt death was not observed")
                                boot_endings.append("sigkill")
                            else:
                                stage = "clean-shutdown"
                                clean_shutdown(boot_context)
                                boot_endings.append("clean")
                                print(
                                    f"native service clean shutdown verified boot={generation}",
                                    flush=True,
                                )
                            if growth_check is not None:
                                stage = "offline-growth-verification"
                                if growth_observation is None:
                                    raise RuntimeError("native growth observation is missing")
                                growth_check.after_shutdown(growth_observation)
                        finally:
                            run_phase("authority-server-stop", server.shutdown)
                            run_phase("authority-dns-stop", dns.shutdown)
                            run_phase("authority-thread-join", partial(thread.join, timeout=5))
                            run_phase(
                                "authority-dns-thread-join", partial(dns_thread.join, timeout=5)
                            )
                            if thread.is_alive() or dns_thread.is_alive():
                                raise PhaseFailure("authority-thread-check", "runtime")
                finally:
                    run_phase("vmm-cleanup", partial(cleanup_vm, process))
        if len(set(host_keys)) != len(boots):
            raise RuntimeError("native restart retained its SSH host key")
        if growth_check is not None:
            run_phase(
                "growth-finalize", partial(growth_check.finish, [boot.boot_id for boot in boots])
            )
        receipt = {
            "version": 1,
            "os": platform.name,
            "boot_ids": [boot.boot_id for boot in boots],
            "boot_endings": boot_endings,
            "kernel_sha256": expected,
            "trust_bundle_digest": trust_digest,
            "image_sha256": run_phase("receipt-image-digest", partial(digest, image / "disk.raw")),
            "firmware_sha256": run_phase("receipt-firmware-digest", partial(digest, firmware)),
            "vmm_sha256": run_phase("receipt-vmm-digest", partial(digest, vmm)),
            "checks": [
                "mmdsv2-current-boot-kernel",
                "assigned-address-reachable",
                "readiness-withheld-without-ssh-authority",
                "trust-installed-and-stale-refused",
                "flush-current-boot-and-refusals",
                "workspace-stale-foreign-malformed-refused",
                "workspace-native-https-shallow-checkout-and-exact-bytes",
                "workspace-exact-git-ownership-and-unrelated-root-refusal",
                "terminal-hello-ping-and-refusals",
                "terminal-managed-pty-input-resize-replay-and-token-refusal",
                "kernel-current-boot-rechecked",
                "complete-readiness-after-isolated-authority",
                "ssh-certified-host-and-foreign-ca-refusal",
                "ssh-managed-uid-gid-bash-and-passwordless-sudo",
                "ssh-foreign-key-root-foreign-user-and-password-refusals",
                "ssh-login-receipt-before-startup-and-client-environment",
                "executor-private-https-fixed-command-completed",
                "executor-current-heartbeat-withdrawal-before-command-deadline",
                "executor-whole-group-death-no-result-and-fresh-fence-completion",
                "first-boot-sigkill-and-final-clean-shutdown"
                if crash_first_boot
                else "ssh-triggered-clean-guest-shutdown",
                "new-mmds-epoch-challenge-and-boot-id",
                "previous-boot-protocol-refused",
                "home-bytes-retained-across-abrupt-restart"
                if crash_first_boot
                else "home-bytes-retained-across-clean-reboot",
                "ssh-host-key-rotated-across-abrupt-restart"
                if crash_first_boot
                else "ssh-host-key-rotated-across-clean-reboot",
                (
                    "all-boots-core-services-and-final-boot-executor-withdrawal"
                    if github_tools_release is not None
                    else "all-boots-complete-service-oracles"
                ),
            ],
            "native_admission": False,
            "scope": (
                "native services with synthetic HTTPS/SSH/Git/DNS authority and an observed first-boot SIGKILL; separate crash oracle required for recovery acceptance; no native isolation or admission"
                if crash_first_boot
                else "native services with synthetic HTTPS/SSH/Git/DNS authority and clean reboot; no native isolation or crash recovery acceptance"
            ),
        }
        if manifest.get("git_identity_version") == 1:
            checks = receipt["checks"]
            if not isinstance(checks, list):
                raise RuntimeError("invalid native service receipt checks")
            checks.append("all-boots-current-mmds-git-config-and-commit-attribution")
        run_phase(
            "service-receipt-write",
            partial(
                (work / "service-receipt.json").write_text,
                json.dumps(receipt, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            ),
        )
        if github_observations:
            run_phase(
                "github-receipt-write",
                partial(
                    (work / "github-tools-receipt.json").write_text,
                    json.dumps(
                        {
                            "version": 1,
                            "platform": os_name + "-amd64",
                            "native_admission": False,
                            "boots": github_observations,
                            "checks": [
                                "retained-executor-fixed-bootstrap-and-fenced-artifact",
                                "verified-atomic-managed-generation",
                                "personal-uid-managed-gh-version-and-broker-api",
                                "personal-uid-git-clone-branch-commit-push",
                                "personal-uid-lfs-upload-and-download-exact-bytes",
                                "token-command-refused-and-no-cli-credential-store",
                                "home-and-existing-git-config-retained",
                                "clean-reboot-already-current-generation",
                            ],
                            "scope": "actual retained native guest programs with isolated synthetic authority; Marshall SQL authorization and production native admission require separate evidence",
                        },
                        sort_keys=True,
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                ),
            )
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        category = failure_category(error)
        if isinstance(error, PhaseFailure):
            stage = error.phase
        print(
            f"native service verification failed at stage {stage} category={category}", flush=True
        )
        raise RuntimeError("native service verification failed") from None
    finally:
        metadata_path.unlink(missing_ok=True)


class Options(argparse.Namespace):
    """CLI schema populated through argparse's explicit path conversions."""

    image: Path
    vmm: Path
    fixture: Path
    tap: str
    work: Path
    address: str
    gateway: str
    mac: str
    os_name: services.Os
    growth: bool
    github_tools_release: Path | None
    github_executor_release: Path | None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--vmm", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--tap", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--address", default=DEFAULT_NETWORK.address)
    parser.add_argument("--gateway", default=DEFAULT_NETWORK.gateway)
    parser.add_argument("--mac", default=DEFAULT_NETWORK.mac)
    parser.add_argument("--os-name", choices=("freebsd", "illumos"), default="freebsd")
    parser.add_argument("--growth", action="store_true")
    parser.add_argument("--github-tools-release", type=Path)
    parser.add_argument("--github-executor-release", type=Path)
    arguments = parser.parse_args(namespace=Options())
    run(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        network=Network(arguments.address, arguments.gateway, arguments.mac),
        os_name=arguments.os_name,
        growth=arguments.growth,
        github_tools_release=arguments.github_tools_release,
        github_executor_release=arguments.github_executor_release,
    )


if __name__ == "__main__":
    main()
