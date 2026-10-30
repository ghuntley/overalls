"""Bounded host clients for actual native daemons through Firecracker's UDS.

These checks produce service evidence only. They do not enable native admission,
prove a workspace checkout, or replace SSH/executor authority integration tests.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import secrets
import socket
import struct
import time
import uuid
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

MAX_FRAME = 1_048_576
TIMEOUT = 15.0
Os = Literal["freebsd", "illumos"]


class ProtocolError(RuntimeError):
    """A closed diagnostic that never contains request or response bytes."""


def valid_hex(value: str, size: int) -> bool:
    """Require lowercase, fixed-size hex before it enters a wire identity."""
    return len(value) == size and all(char in "0123456789abcdef" for char in value)


def valid_uuid(value: str) -> bool:
    """Require the canonical lowercase UUID spelling used by the daemons."""
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


@dataclass(frozen=True)
class Binding:
    """A synthetic machine fixture's MMDS identity; never serialize its challenge."""

    placement_id: str
    execution_epoch: int
    boot_challenge: str

    def __post_init__(self) -> None:
        if (
            not valid_uuid(self.placement_id)
            or type(self.execution_epoch) is not int
            or not 0 < self.execution_epoch <= 0xFFFF_FFFF_FFFF_FFFF
            or not valid_hex(self.boot_challenge, 64)
        ):
            raise ValueError("invalid native fixture identity")

    def fields(self) -> dict[str, object]:
        """Return request fields only, never diagnostic or receipt fields."""
        return {
            "placement_id": self.placement_id,
            "execution_epoch": self.execution_epoch,
            "boot_challenge": self.boot_challenge,
        }


@dataclass(frozen=True)
class Boot:
    """A validated readiness response binds subsequent checks to one boot."""

    binding: Binding
    boot_id: str

    def __post_init__(self) -> None:
        if not valid_uuid(self.boot_id):
            raise ValueError("invalid native fixture boot identity")

    def fields(self) -> dict[str, object]:
        """Return expected wire fields without retaining complete responses."""
        return {**self.binding.fields(), "boot_id": self.boot_id}


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """Refuse duplicate JSON members rather than accepting the final identity."""
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("duplicate native protocol field")
        result[key] = value
    return result


def decode_object(body: bytes) -> dict[str, object]:
    """Narrow external JSON through an object boundary, with closed diagnostics."""
    try:
        value: object = json.loads(body, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError, RecursionError):
        raise ProtocolError("invalid native protocol object") from None
    if not isinstance(value, dict):
        raise ProtocolError("invalid native protocol object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ProtocolError("invalid native protocol object")
        result[key] = item
    return result


def expect(actual: dict[str, object], expected: dict[str, object]) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-service-closed-receipts
    A service check MUST require exactly the expected keys, scalar types and
    values from the actual daemon. A foreign/stale boot, boolean version/epoch,
    unknown field or duplicate JSON member MUST NOT establish successful evidence.
    """
    if actual.keys() != expected.keys() or any(
        type(actual[key]) is not type(value) or actual[key] != value
        for key, value in expected.items()
    ):
        raise ProtocolError("native service receipt mismatch")


def encode(value: dict[str, object]) -> bytes:
    """Encode bounded requests without adding optional protocol fields."""
    return json.dumps(value, separators=(",", ":"), allow_nan=False).encode("utf-8")


@dataclass
class Connection:
    """All operations share an absolute deadline, including drip-fed frames."""

    stream: socket.socket
    deadline: float

    def remaining(self) -> float:
        value = self.deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError("native service deadline exceeded")
        return value

    def send(self, body: bytes) -> None:
        """Write within the connection's overall deadline."""
        self.stream.settimeout(self.remaining())
        self.stream.sendall(body)

    def receive(self, size: int) -> bytes:
        """Read only the requested bounded bytes within the same deadline."""
        self.stream.settimeout(self.remaining())
        return self.stream.recv(size)

    def exact(self, size: int) -> bytes:
        """Refuse a truncated frame, including a peer closing mid-header."""
        if not 0 <= size <= MAX_FRAME:
            raise ValueError("invalid native service read bound")
        body = bytearray()
        while len(body) < size:
            part = self.receive(size - len(body))
            if not part:
                raise ProtocolError("truncated native service response")
            body.extend(part)
        return bytes(body)

    def line(self, limit: int) -> bytes:
        """Read one bounded newline without consuming the following message."""
        if not 0 < limit <= MAX_FRAME:
            raise ValueError("invalid native service line bound")
        body = bytearray()
        while len(body) < limit:
            part = self.exact(1)
            body.extend(part)
            if part == b"\n":
                return bytes(body)
        raise ProtocolError("oversized native service line")

    def framed_object(self) -> dict[str, object]:
        """Read the native trust protocol's nonempty big-endian JSON frame."""
        size = int.from_bytes(self.exact(4), "big")
        if not 0 < size <= MAX_FRAME:
            raise ProtocolError("invalid native service frame bound")
        return decode_object(self.exact(size))

    def terminal_frame(self) -> tuple[int, bytes]:
        """Read a terminal control frame; never print or retain terminal bytes."""
        magic, operation, size = struct.unpack(">BBH", self.exact(4))
        if magic != 0x4C or size > 8192:
            raise ProtocolError("invalid native terminal frame")
        return operation, self.exact(size)


@contextmanager
def connect(uds: Path, port: int) -> Generator[Connection]:
    """Use the existing jail-local Firecracker channel, without guest TCP ports."""
    if type(port) is not int or not 0 < port <= 0xFFFF_FFFF:
        raise ValueError("invalid native service port")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        channel = Connection(stream, time.monotonic() + TIMEOUT)
        stream.settimeout(channel.remaining())
        stream.connect(str(uds))
        channel.send(f"CONNECT {port}\n".encode("ascii"))
        handshake = channel.line(64)
        if (
            not handshake.startswith(b"OK ")
            or not handshake[3:-1].isdigit()
            or not 0 < int(handshake[3:-1]) <= 0xFFFF_FFFF
        ):
            raise ProtocolError("invalid native Firecracker handshake")
        yield channel


def readiness(uds: Path, binding: Binding) -> Boot:
    """Require the actual six-field readiness response for this MMDS binding."""
    with connect(uds, 1024) as channel:
        response = decode_object(channel.line(512))
        boot_id = response.get("boot_id")
        if not isinstance(boot_id, str) or not valid_uuid(boot_id):
            raise ProtocolError("invalid native readiness boot identity")
        boot = Boot(binding, boot_id)
        expect(response, {"version": 1, "state": "ready", **boot.fields()})
        if channel.receive(1):
            raise ProtocolError("excess native readiness bytes")
        return boot


def readiness_withheld(uds: Path) -> None:
    """Require a live readiness daemon to close without an affirmative response."""
    refused(uds, 1024, b"")


def kernel_boot(uds: Path, binding: Binding, os_name: Os, expected_sha256: str) -> Boot:
    """Validate kernel attestation even while readiness is correctly withheld."""
    if os_name not in ("freebsd", "illumos") or not valid_hex(expected_sha256, 64):
        raise ValueError("invalid native kernel expectation")
    with connect(uds, 1098) as channel:
        response = decode_object(channel.line(512))
        boot_id = response.get("boot_id")
        if not isinstance(boot_id, str) or not valid_uuid(boot_id):
            raise ProtocolError("invalid native kernel boot identity")
        boot = Boot(binding, boot_id)
        expect(
            response,
            {
                "version": 1,
                "state": "attested",
                "os": os_name,
                **boot.fields(),
                "kernel_sha256": expected_sha256,
            },
        )
        if channel.receive(1):
            raise ProtocolError("excess native kernel response bytes")
        return boot


def kernel(uds: Path, boot: Boot, os_name: Os, expected_sha256: str) -> None:
    """Require kernel attestation to name the boot readiness already observed."""
    if kernel_boot(uds, boot.binding, os_name, expected_sha256) != boot:
        raise ProtocolError("native kernel boot changed")


def refused(uds: Path, port: int, request: bytes) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-service-refusal-observed
    Refusal evidence MUST require an established Firecracker connection followed
    by EOF/reset without a response. Connect failures and timeouts MUST fail the
    check; they MUST NOT count as a daemon refusing malformed or stale input.
    """
    with connect(uds, port) as channel:
        try:
            if request:
                channel.send(request)
        except (BrokenPipeError, ConnectionResetError):
            # A reset while writing does not prove that the peer sent nothing;
            # drain any queued response before accepting the refusal.
            pass
        try:
            response = channel.receive(1)
        except ConnectionResetError:
            return
        if response:
            raise ProtocolError("native service answered a refused request")


def flush(uds: Path, boot: Boot) -> None:
    """Require successful sync and malformed/stale/foreign refusal, then recovery."""
    request = {
        "version": 1,
        "operation": "sync",
        "nonce": secrets.token_hex(32),
        **boot.binding.fields(),
    }
    mutations: list[dict[str, object]] = [
        {**request, "version": 2},
        {**request, "execution_epoch": boot.binding.execution_epoch + 1},
        {**request, "placement_id": str(uuid.uuid4())},
        {
            **request,
            "boot_challenge": "0" * 64 if boot.binding.boot_challenge != "0" * 64 else "1" * 64,
        },
        {**request, "unexpected": True},
    ]
    for mutation in mutations:
        refused(uds, 1026, encode(mutation) + b"\n")
    refused(uds, 1026, b"x" * 1025 + b"\n")
    with connect(uds, 1026) as channel:
        channel.send(encode(request) + b"\n")
        expect(
            decode_object(channel.line(1024)),
            {"version": 1, "state": "flushed", "nonce": request["nonce"], **boot.fields()},
        )
        if channel.receive(1):
            raise ProtocolError("excess native flush response bytes")


def trust(uds: Path, boot: Boot, roots: list[str]) -> str:
    """Deliver isolated public fixture roots; require the exact installed digest."""
    if not 1 <= len(roots) <= 32 or any(
        len(root.encode("utf-8")) > 16_384
        or not root.startswith("-----BEGIN CERTIFICATE-----\n")
        or not root.rstrip().endswith("-----END CERTIFICATE-----")
        or root.count("-----BEGIN CERTIFICATE-----") != 1
        or root.count("-----END CERTIFICATE-----") != 1
        or "PRIVATE KEY" in root
        for root in roots
    ):
        raise ValueError("invalid native public fixture roots")
    fingerprints = sorted(hashlib.sha256(root.encode("utf-8")).digest() for root in roots)
    if len(set(fingerprints)) != len(roots):
        raise ValueError("duplicate native public fixture roots")
    bundle_digest = hashlib.sha256(b"".join(fingerprints)).hexdigest()
    request = {
        "version": 1,
        **boot.binding.fields(),
        "nonce": secrets.token_hex(32),
        "bundle_digest": bundle_digest,
        "roots": roots,
    }
    for size in (0, MAX_FRAME + 1):
        refused(uds, 1030, struct.pack(">I", size))
    stale = encode({**request, "execution_epoch": boot.binding.execution_epoch + 1})
    refused(uds, 1030, struct.pack(">I", len(stale)) + stale)
    body = encode(request)
    if len(body) > MAX_FRAME:
        raise ValueError("oversized native public fixture roots")
    with connect(uds, 1030) as channel:
        channel.send(struct.pack(">I", len(body)) + body)
        expect(
            channel.framed_object(),
            {
                "version": 1,
                "state": "installed",
                **boot.fields(),
                "nonce": request["nonce"],
                "bundle_digest": bundle_digest,
            },
        )
        if channel.receive(1):
            raise ProtocolError("excess native trust response bytes")
    return bundle_digest


def workspace(uds: Path, binding: Binding, source: dict[str, object]) -> None:
    """Check source receipt/idempotence only; checkout needs a local TLS Git fixture."""
    request = {
        "version": 1,
        **binding.fields(),
        "nonce": secrets.token_hex(32),
        "source": source,
    }
    body = encode(request) + b"\n"
    if len(body) > 4097:
        raise ValueError("oversized native workspace fixture")
    refused(uds, 1031, encode({**request, "execution_epoch": binding.execution_epoch + 1}) + b"\n")
    refused(uds, 1031, b"x" * 4097 + b"\n")
    for _ in range(2):
        with connect(uds, 1031) as channel:
            channel.send(body)
            expect(
                decode_object(channel.line(512)),
                {"version": 1, "state": "accepted", **binding.fields(), "nonce": request["nonce"]},
            )
            if channel.receive(1):
                raise ProtocolError("excess native workspace response bytes")


def workspace_refusals(uds: Path, binding: Binding) -> None:
    """Never deliver a source: stale/foreign/malformed requests must have no reply."""
    source: dict[str, object] = {
        "version": 2,
        "provider": "github",
        "namespace": ["overalls-native-fixture"],
        "repository": "unpublished-fixture",
        "revision": {"kind": "default"},
    }
    request = {
        "version": 1,
        **binding.fields(),
        "nonce": secrets.token_hex(32),
        "source": source,
    }
    for mutation in (
        {**request, "execution_epoch": binding.execution_epoch + 1},
        {**request, "placement_id": str(uuid.uuid4())},
        {**request, "unexpected": True},
    ):
        refused(uds, 1031, encode(mutation) + b"\n")
    refused(uds, 1031, b"x" * 4097 + b"\n")


def terminal_hello(binding: Binding, nonce: bytes) -> bytes:
    """Match the shared terminal protocol without logging its boot-derived proof."""
    if len(nonce) != 16:
        raise ValueError("invalid native terminal nonce")
    key = hashlib.sha256(binding.boot_challenge.encode("ascii") + b"overalls-terminald-v1").digest()
    message = (
        b"terminald-hello-v1"
        + nonce
        + binding.placement_id.encode("ascii")
        + str(binding.execution_epoch).encode("ascii")
    )
    return nonce + hmac.digest(key, message, "sha256")


def terminal(uds: Path, binding: Binding) -> None:
    """Check boot-bound HELLO/PING and stale/malformed proof refusal; no PTY claim."""
    stale = Binding(binding.placement_id, binding.execution_epoch + 1, binding.boot_challenge)
    for payload in (b"invalid", terminal_hello(stale, secrets.token_bytes(16))):
        with connect(uds, 1075) as channel:
            channel.send(struct.pack(">BBH", 0x4C, 1, len(payload)) + payload)
            if channel.terminal_frame() != (0x81, b"\x01"):
                raise ProtocolError("native terminal accepted an invalid proof")
            if channel.receive(1):
                raise ProtocolError("excess native terminal refusal bytes")
    with connect(uds, 1075) as channel:
        channel.send(b"\x4c\x01\x00\x30" + terminal_hello(binding, secrets.token_bytes(16)))
        if channel.terminal_frame() != (0x80, b""):
            raise ProtocolError("native terminal refused current-boot proof")
        channel.send(b"\x4c\x06\x00\x00")
        if channel.terminal_frame() != (0x80, b""):
            raise ProtocolError("native terminal ping failed")


def terminal_send(channel: Connection, operation: int, payload: bytes = b"") -> None:
    """Send a bounded terminal frame without recording authority or user bytes."""
    if not 0 <= operation <= 255 or len(payload) > 8192:
        raise ValueError("invalid native terminal request")
    channel.send(struct.pack(">BBH", 0x4C, operation, len(payload)) + payload)


def terminal_authenticate(channel: Connection, binding: Binding) -> None:
    terminal_send(channel, 1, terminal_hello(binding, secrets.token_bytes(16)))
    if channel.terminal_frame() != (0x80, b""):
        raise ProtocolError("native terminal refused current-boot proof")


def terminal_request(channel: Connection, operation: int, payload: bytes = b"") -> bytes:
    terminal_send(channel, operation, payload)
    answer, body = channel.terminal_frame()
    if answer != 0x80:
        raise ProtocolError("native terminal refused a valid control request")
    return body


def terminal_replay(channel: Connection, payload: bytes) -> tuple[int, bytes]:
    """Validate attach metadata before reading its bounded retained PTY bytes."""
    response = terminal_request(channel, 10, payload)
    if len(response) != 12:
        raise ProtocolError("invalid native terminal attach metadata")
    cursor, size = struct.unpack(">QI", response)
    if size > 262_144:
        raise ProtocolError("native terminal replay exceeded its fixture bound")
    return cursor, channel.exact(size)


def terminal_until(channel: Connection, expected: bytes, initial: bytes = b"") -> bytes:
    """Inspect only bounded synthetic bytes; never include them in diagnostics."""
    output = bytearray(initial)
    while expected not in bytes(output).replace(b"\r\n", b"\n"):
        if len(output) >= 65_536:
            raise ProtocolError("native terminal proof exceeded its output bound")
        chunk = channel.receive(min(8192, 65_536 - len(output)))
        if not chunk:
            raise ProtocolError("native terminal closed before its execution proof")
        output.extend(chunk)
    return bytes(output)


def terminal_control_request(uds: Path, binding: Binding, operation: int, payload: bytes) -> bytes:
    """@cc [owner:ghuntley,label:verification;security] native-terminal-phase-deadline
    Each standalone control operation MUST authenticate a fresh connection and
    retain its absolute deadline; unrelated PTY work MUST NOT consume that budget.
    """
    with connect(uds, 1075) as channel:
        terminal_authenticate(channel, binding)
        return terminal_request(channel, operation, payload)


def terminal_session(uds: Path, binding: Binding, os_name: Os) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-terminal-real-pty
    PTY evidence MUST create a real managed-account session, authenticate every
    connection, refuse an incorrect attach token, and verify executed identity,
    input, resize and retained replay. Synthetic proof bytes MUST NOT enter
    diagnostic or receipt fields, and the session MUST be explicitly retired.
    Resize proof MUST query the selected native stty dialect; the command input
    MUST NOT contain the expected geometry output.
    Retirement failure MUST fail successful probes and preserve an earlier probe
    error with a secondary note containing no response or exception payload.
    """
    if os_name not in ("freebsd", "illumos"):
        raise ValueError("invalid native terminal platform")
    user, term = b"u200000", b"xterm-256color"
    request_id = secrets.token_bytes(16)
    create = bytes([len(user)]) + user + bytes([len(term)]) + term + struct.pack(">HH", 80, 24)
    session_id: int | None = None
    failure: BaseException | None = None
    try:
        with connect(uds, 1075) as control:
            terminal_authenticate(control, binding)
            created = terminal_request(control, 12, request_id + create)
            if len(created) != 24:
                raise ProtocolError("invalid native terminal creation receipt")
            candidate_id, token = struct.unpack(">Q16s", created)
            if not 0 < candidate_id < 1 << 63:
                raise ProtocolError("invalid native terminal session identity")
            session_id = candidate_id
            if terminal_request(control, 12, request_id + create) != created:
                raise ProtocolError("native terminal duplicate creation changed identity")
            if terminal_request(control, 13, request_id) != struct.pack(">QB", session_id, 1):
                raise ProtocolError("native terminal omitted live creation evidence")
            recovered = terminal_request(control, 11, struct.pack(">Q", session_id))
            if not hmac.compare_digest(recovered, token):
                raise ProtocolError("native terminal recovery changed session authority")
        wrong = bytes([token[0] ^ 1]) + token[1:]
        with connect(uds, 1075) as rejected:
            terminal_authenticate(rejected, binding)
            terminal_send(rejected, 10, struct.pack(">Q16sBQHH", session_id, wrong, 1, 0, 80, 24))
            if rejected.terminal_frame() != (0x81, b"\x03") or rejected.receive(1):
                raise ProtocolError("native terminal accepted incorrect session authority")
        with connect(uds, 1075) as data:
            terminal_authenticate(data, binding)
            cursor, replay = terminal_replay(
                data, struct.pack(">Q16sBQHH", session_id, token, 1, 0, 80, 24)
            )
            if cursor != 0:
                raise ProtocolError("native terminal unexpectedly truncated fresh replay")
            data.send(b"stty -echo; printf '%s%s\\n' native- pty-ready\r")
            terminal_until(data, b"native-pty-ready\n", replay)
            identity = b"native-pty-identity:200000:200000\n"
            data.send(b'printf \'%s%s:%s:%s\\n\' native- pty-identity "$(id -u)" "$(id -g)"\r')
            terminal_until(data, identity)
            if terminal_control_request(uds, binding, 5, struct.pack(">QHH", session_id, 101, 41)):
                raise ProtocolError("invalid native terminal resize receipt")
            if os_name == "illumos":
                data.send(b"LC_ALL=C /usr/bin/stty -a\r")
                terminal_until(data, b"rows = 41; columns = 101;")
            else:
                data.send(b"printf '%s%s:' native- pty-size; stty size\r")
                terminal_until(data, b"native-pty-size:41 101\n")
            data.send(b"printf '%s%s\\n' native- pty-retained\r")
            retained = terminal_until(data, b"native-pty-retained\n")
        with connect(uds, 1075) as replayed:
            terminal_authenticate(replayed, binding)
            cursor, replay = terminal_replay(
                replayed, struct.pack(">Q16sBQHH", session_id, token, 0, 0, 0, 0)
            )
            if cursor != 0 or retained not in replay:
                raise ProtocolError("native terminal did not retain its acknowledged output")
    except BaseException as error:
        failure = error
        raise
    finally:
        if session_id is not None:
            try:
                if terminal_control_request(uds, binding, 4, struct.pack(">Q", session_id)):
                    raise ProtocolError("invalid native terminal retirement receipt")
            except Exception as cleanup_error:
                if failure is None:
                    raise
                failure.add_note(
                    "native terminal retirement also failed (" + type(cleanup_error).__name__ + ")"
                )


def fixture_binding(path: Path) -> Binding:
    """Read a closed fixture file instead of exposing a boot challenge in argv."""
    with path.open("rb") as source:
        body = source.read(4097)
    if len(body) > 4096:
        raise ValueError("oversized native fixture identity")
    value = decode_object(body)
    if set(value) != {"placement_id", "execution_epoch", "boot_challenge"}:
        raise ValueError("invalid native fixture identity")
    placement, epoch, challenge = (
        value["placement_id"],
        value["execution_epoch"],
        value["boot_challenge"],
    )
    if not isinstance(placement, str) or type(epoch) is not int or not isinstance(challenge, str):
        raise ValueError("invalid native fixture identity")
    return Binding(placement, epoch, challenge)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uds", type=Path, required=True)
    parser.add_argument("--binding", type=Path, required=True)
    parser.add_argument("--os", choices=("freebsd", "illumos"), required=True)
    parser.add_argument("--kernel-sha256", required=True)
    parser.add_argument("--public-root", type=Path, action="append", default=[])
    parser.add_argument("--receipt", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        binding = fixture_binding(arguments.binding)
        boot = readiness(arguments.uds, binding)
        os_name: Os = "freebsd" if arguments.os == "freebsd" else "illumos"
        kernel(arguments.uds, boot, os_name, arguments.kernel_sha256)
        checks = ["readiness-current-boot", "kernel-current-boot"]
        if arguments.public_root:
            roots: list[str] = []
            for path in arguments.public_root:
                with path.open("r", encoding="utf-8") as source:
                    roots.append(source.read(16_385))
            trust(arguments.uds, boot, roots)
            checks.append("trust-installed-and-stale-refused")
        flush(arguments.uds, boot)
        checks.append("flush-current-boot-and-refusals")
        terminal(arguments.uds, binding)
        checks.append("terminal-hello-ping-and-refusals")
        receipt = {
            "version": 1,
            "os": os_name,
            "boot_id": boot.boot_id,
            "kernel_sha256": arguments.kernel_sha256,
            "checks": checks,
            "native_admission": False,
            "scope": "actual service replies only; no checkout, SSH, execution, PTY or isolation claim",
        }
        with arguments.receipt.open("x", encoding="utf-8") as output:
            output.write(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    except (OSError, ValueError, ProtocolError):
        parser.exit(1, "native service verification failed\n")


if __name__ == "__main__":
    main()
