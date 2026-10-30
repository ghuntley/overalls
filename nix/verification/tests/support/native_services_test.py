"""Exercise service-client framing/refusal oracles; no native runtime claims."""

from __future__ import annotations

import json
import socket
import struct
import tempfile
import time
import unittest
from collections.abc import Callable, Generator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import native_services as services

BINDING = services.Binding("dddddddd-dddd-4ddd-8ddd-000000000201", 7, "b" * 64)
BOOT = services.Boot(BINDING, "0f0e0d0c-0b0a-4908-8706-050403020100")


class TerminalFixture:
    """Valid synthetic peer responses with deterministic time, never a native VM."""

    def __init__(self) -> None:
        self.elapsed: float = 0.0
        self.created: bool = False
        self.retired: bool = False
        self.fail_retirement: bool = False
        self.fail_pty: bool = False
        self.pty_delay: tuple[float, ...] = (4.0, 4.0, 1.0, 1.0)
        self.primary_error = services.ProtocolError("synthetic PTY failure")
        self.channels: list[TerminalConnection] = []
        self.operations: dict[int, int] = {}
        self.token: bytes = b"s" * 16

    def now(self) -> float:
        return self.elapsed

    @contextmanager
    def connect(self, _uds: Path, port: int) -> Generator[services.Connection]:
        if port != 1075:
            raise AssertionError("unexpected synthetic service port")
        channel = TerminalConnection(self)
        self.channels.append(channel)
        try:
            yield channel
        finally:
            channel.closed_at = self.now()
            channel.stream.close()


class TerminalConnection(services.Connection):
    """Exercise the real deadline, framing consumers and PTY oracle using a clock."""

    def __init__(self, fixture: TerminalFixture) -> None:
        super().__init__(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM), fixture.now() + 15)
        self.fixture: TerminalFixture = fixture
        self.opened_at: float = fixture.now()
        self.closed_at: float | None = None
        self.authenticated: bool = False
        self.operation: int = 0
        self.payload: bytes = b""
        self.output: bytes = b""
        self.delay: float = 0.0
        self.pty_commands: int = 0

    def send(self, body: bytes) -> None:
        self.remaining()
        if len(body) >= 4 and body[0] == 0x4C and body[1] in (1, 4, 5, 10, 11, 12, 13):
            self.operation = body[1]
            self.payload = body[4:]
            if len(self.payload) != int.from_bytes(body[2:4], "big"):
                raise AssertionError("invalid synthetic terminal frame length")
            return
        if not self.authenticated or self.operation != 10:
            raise AssertionError("PTY input preceded authenticated attach")
        outputs = (
            b"native-pty-ready\n",
            b"native-pty-identity:200000:200000\n",
            b"rows = 41; columns = 101;\nnative-pty-size:41 101\n",
            b"native-pty-retained\n",
        )
        self.output = outputs[self.pty_commands]
        self.delay = self.fixture.pty_delay[self.pty_commands]
        self.pty_commands += 1

    def receive(self, size: int) -> bytes:
        self.remaining()
        if self.fixture.fail_pty and self.pty_commands:
            raise self.fixture.primary_error
        self.fixture.elapsed += self.delay
        self.delay = 0
        self.remaining()
        result, self.output = self.output[:size], self.output[size:]
        return result

    def terminal_frame(self) -> tuple[int, bytes]:
        self.remaining()
        operation, payload = self.operation, self.payload
        self.fixture.operations[operation] = self.fixture.operations.get(operation, 0) + 1
        if operation == 1:
            if len(payload) != 48 or payload != services.terminal_hello(BINDING, payload[:16]):
                raise AssertionError("invalid synthetic terminal authentication")
            self.authenticated = True
            return 0x80, b""
        if not self.authenticated:
            raise AssertionError("terminal operation preceded authentication")
        if operation == 12:
            if not self.fixture.created:
                self.fixture.elapsed += 8
                self.fixture.created = True
            self.remaining()
            return 0x80, struct.pack(">Q16s", 1, self.fixture.token)
        if operation == 13:
            return 0x80, struct.pack(">QB", 1, 1)
        if operation == 11:
            return 0x80, self.fixture.token
        if operation == 10:
            if payload[8:24] != self.fixture.token:
                return 0x81, b"\x03"
            self.output = b"native-pty-retained\n" if payload[24] == 0 else b""
            return 0x80, struct.pack(">QI", 0, len(self.output))
        if operation == 4:
            if self.fixture.fail_retirement:
                raise OSError("synthetic retirement failure")
            self.fixture.retired = True
        if operation not in (4, 5):
            raise AssertionError("unexpected synthetic terminal operation")
        return 0x80, b""


@contextmanager
def peer(handler: Callable[[services.Connection], None]) -> Generator[Path]:
    """One bounded local Firecracker handshake fixture, without a guest VM."""
    with tempfile.TemporaryDirectory(prefix="native-services-") as directory:
        path = Path(directory) / "v.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.settimeout(3)
            listener.bind(str(path))
            listener.listen(1)

            def serve() -> None:
                with listener.accept()[0] as stream:
                    channel = services.Connection(stream, time.monotonic() + 3)
                    request = channel.line(64)
                    if not request.startswith(b"CONNECT "):
                        raise RuntimeError("invalid local service fixture handshake")
                    channel.send(b"OK 1234\n")
                    handler(channel)

            with ThreadPoolExecutor(max_workers=1) as executor:
                completed = executor.submit(serve)
                try:
                    yield path
                finally:
                    completed.result(timeout=4)


class NativeServiceClientTests(unittest.TestCase):
    """Untrusted bytes cannot make an incomplete service history look successful."""

    def test_readiness_requires_exact_identity_and_scalar_types(self) -> None:
        good = {"version": 1, "state": "ready", **BOOT.fields()}
        mutations: list[dict[str, object]] = [
            {**good, "execution_epoch": 8},
            {**good, "version": True},
            {**good, "unexpected": 1},
            {**good, "boot_id": "invalid"},
        ]
        for mutation in mutations:
            with self.subTest(kind=list(mutation)):

                def answer(
                    channel: services.Connection, message: bytes = services.encode(mutation) + b"\n"
                ) -> None:
                    channel.send(message)

                with peer(answer) as path, self.assertRaises(services.ProtocolError):
                    services.readiness(path, BINDING)

        def correct(channel: services.Connection) -> None:
            channel.send(services.encode(good) + b"\n")

        with peer(correct) as path:
            self.assertEqual(services.readiness(path, BINDING), BOOT)

    def test_duplicate_and_nonobject_json_never_narrow(self) -> None:
        for body in (b'{"version":2,"version":1}', b"[]", b"true", b"null", b"\xff"):
            with self.subTest(body=body), self.assertRaises(services.ProtocolError):
                services.decode_object(body)

    def test_truncated_and_oversized_frames_fail_before_parsing(self) -> None:
        for data in (b"\x00\x00", struct.pack(">I", services.MAX_FRAME + 1), b"\x00" * 4):
            with self.subTest(size=len(data)):
                reader, writer = socket.socketpair()
                with reader, writer:
                    writer.sendall(data)
                    writer.shutdown(socket.SHUT_WR)
                    channel = services.Connection(reader, time.monotonic() + 1)
                    with self.assertRaises(services.ProtocolError):
                        channel.framed_object()

    def test_bounded_line_does_not_consume_next_frame(self) -> None:
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"first\nsecond\n")
            channel = services.Connection(reader, time.monotonic() + 1)
            self.assertEqual(channel.line(6), b"first\n")
            self.assertEqual(channel.line(7), b"second\n")
            writer.sendall(b"oversized\n")
            with self.assertRaises(services.ProtocolError):
                channel.line(4)

    def test_expired_deadline_fails_with_data_already_available(self) -> None:
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"ready\n")
            channel = services.Connection(reader, time.monotonic() - 1)
            with self.assertRaises(TimeoutError):
                channel.line(6)

    def test_refusal_requires_connected_peer_close_and_no_bytes(self) -> None:
        def close(channel: services.Connection) -> None:
            self.assertEqual(channel.exact(3), b"bad")

        with peer(close) as path:
            services.refused(path, 1026, b"bad")

        def unexpected(channel: services.Connection) -> None:
            channel.exact(3)
            channel.send(b"unexpected")

        with peer(unexpected) as path, self.assertRaises(services.ProtocolError):
            services.refused(path, 1026, b"bad")
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(OSError):
            services.refused(Path(directory) / "missing", 1026, b"bad")

    def test_withheld_readiness_requires_a_live_daemon_and_no_response(self) -> None:
        def close(_channel: services.Connection) -> None:
            return

        with peer(close) as path:
            services.readiness_withheld(path)

        def answer(channel: services.Connection) -> None:
            channel.send(services.encode({"version": 1, "state": "ready", **BOOT.fields()}) + b"\n")

        with peer(answer) as path, self.assertRaises(services.ProtocolError):
            services.readiness_withheld(path)

    def test_refusal_cannot_hide_bad_firecracker_handshake(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                listener.listen(1)
                listener.settimeout(2)

                def serve() -> None:
                    with listener.accept()[0] as stream:
                        stream.settimeout(2)
                        stream.recv(64)
                        stream.sendall(b"ERR\n")

                with ThreadPoolExecutor(max_workers=1) as executor:
                    task = executor.submit(serve)
                    with self.assertRaises(services.ProtocolError):
                        services.refused(path, 1026, b"bad")
                    task.result(timeout=3)

    def test_kernel_attestation_is_bound_to_boot_and_exact_digest(self) -> None:
        def answer(channel: services.Connection) -> None:
            channel.send(
                services.encode(
                    {
                        "version": 1,
                        "state": "attested",
                        "os": "freebsd",
                        **BOOT.fields(),
                        "kernel_sha256": "a" * 64,
                    }
                )
                + b"\n"
            )

        with peer(answer) as path:
            services.kernel(path, BOOT, "freebsd", "a" * 64)
        with peer(answer) as path:
            self.assertEqual(services.kernel_boot(path, BINDING, "freebsd", "a" * 64), BOOT)
        with peer(answer) as path, self.assertRaises(services.ProtocolError):
            services.kernel(path, BOOT, "freebsd", "c" * 64)

    def test_fixture_file_has_closed_keys_and_no_boolean_epoch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "binding.json"
            path.write_text(json.dumps(BINDING.fields()), encoding="utf-8")
            self.assertEqual(services.fixture_binding(path), BINDING)
            for mutation in (
                {**BINDING.fields(), "execution_epoch": True},
                {**BINDING.fields(), "unexpected": 1},
            ):
                path.write_text(json.dumps(mutation), encoding="utf-8")
                with self.assertRaises(ValueError):
                    services.fixture_binding(path)

    def test_terminal_proof_changes_for_every_binding_dimension(self) -> None:
        nonce = bytes(range(16))
        proof = services.terminal_hello(BINDING, nonce)
        self.assertEqual(len(proof), 48)
        self.assertEqual(proof[:16], nonce)
        alternatives = (
            services.Binding(BINDING.placement_id, 8, BINDING.boot_challenge),
            services.Binding(BINDING.placement_id, 7, "c" * 64),
            services.Binding("dddddddd-dddd-4ddd-8ddd-000000000202", 7, BINDING.boot_challenge),
        )
        for alternative in alternatives:
            self.assertNotEqual(services.terminal_hello(alternative, nonce), proof)
        self.assertNotEqual(services.terminal_hello(BINDING, b"x" * 16), proof)

    def test_terminal_control_phases_do_not_share_the_entire_pty_deadline(self) -> None:
        for platform in ("freebsd", "illumos"):
            fixture = TerminalFixture()
            with (
                self.subTest(platform=platform),
                patch.object(services.time, "monotonic", fixture.now),
                patch.object(services, "connect", fixture.connect),
            ):
                services.terminal_session(Path("/synthetic-unused.sock"), BINDING, platform)
            self.assertTrue(fixture.retired)
            self.assertGreater(fixture.elapsed, services.TIMEOUT)
            self.assertEqual(fixture.operations, {1: 6, 12: 2, 13: 1, 11: 1, 10: 3, 5: 1, 4: 1})
            self.assertEqual(len(fixture.channels), 6)
            first, _rejected, data, resize, _replayed, retirement = fixture.channels
            self.assertIsNot(first, resize)
            self.assertIsNot(first, retirement)
            assert first.closed_at is not None
            self.assertLessEqual(first.closed_at, data.opened_at)
            for channel in fixture.channels:
                self.assertTrue(channel.authenticated)
                assert channel.closed_at is not None
                self.assertLess(channel.closed_at - channel.opened_at, services.TIMEOUT)

    def test_terminal_data_keeps_its_absolute_deadline(self) -> None:
        fixture = TerminalFixture()
        fixture.pty_delay = (16.0, 0.0, 0.0, 0.0)
        with (
            patch.object(services.time, "monotonic", fixture.now),
            patch.object(services, "connect", fixture.connect),
            self.assertRaises(TimeoutError),
        ):
            services.terminal_session(Path("/synthetic-unused.sock"), BINDING, "illumos")
        self.assertTrue(fixture.retired)

    def test_terminal_retirement_failure_preserves_the_primary_failure(self) -> None:
        fixture = TerminalFixture()
        fixture.fail_pty = True
        fixture.fail_retirement = True
        with (
            patch.object(services.time, "monotonic", fixture.now),
            patch.object(services, "connect", fixture.connect),
            self.assertRaises(services.ProtocolError) as raised,
        ):
            services.terminal_session(Path("/synthetic-unused.sock"), BINDING, "illumos")
        self.assertIs(raised.exception, fixture.primary_error)
        self.assertEqual(
            raised.exception.__notes__, ["native terminal retirement also failed (OSError)"]
        )
        self.assertNotIn("synthetic retirement failure", "".join(raised.exception.__notes__))

    def test_terminal_retirement_failure_cannot_pass_an_otherwise_successful_probe(self) -> None:
        fixture = TerminalFixture()
        fixture.fail_retirement = True
        with (
            patch.object(services.time, "monotonic", fixture.now),
            patch.object(services, "connect", fixture.connect),
            self.assertRaises(OSError),
        ):
            services.terminal_session(Path("/synthetic-unused.sock"), BINDING, "illumos")


if __name__ == "__main__":
    unittest.main()
