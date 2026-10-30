"""Guest terminal stand-in for the Mila journey fixture (ADR-0264).

The fixture has no provisioner and no guest VM. For one seeded terminal
machine, this process stands in for Lilly's terminal stream and the guest's
terminald: it connects to Marshall's fleet listener exactly as Lilly does
(`/api/provisioners/v4/stream`, `authorization: Lilly <token>`), speaks the
closed terminal stream v2 protocol, and backs each guest session with a real
PTY running a login shell as the unprivileged `mila-guest` account. Sessions
keep a terminald-style output ring so reattaching replays from the client's
cursor.

It never logs terminal bytes, tokens or control payloads; only closed event
names and counters reach stdout.

usage: terminal_host.py IDENTITY_JSON CA_FILE
"""

import asyncio
import base64
import contextlib
import fcntl
import json
import os
import pwd
import signal
import ssl
import struct
import subprocess
import sys
import termios
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import TypedDict

from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import WebSocketException

HEADER = struct.Struct(">IBQH")
DATA = 1
CONTROL = 2
MAX_PAYLOAD = 65_535
CHUNK = 32_768
WINDOW_FRAMES = 16
WINDOW_BYTES = 262_144
RING_BYTES = 1_048_576
MAX_SESSIONS = 16
GUEST_ACCOUNT = "mila-guest"
SHELL = "/run/current-system/sw/bin/bash"


class Identity(TypedDict):
    """The synthetic host's current stream identity (written by fixture.exs)."""

    base_url: str
    token: str
    host_id: str
    session_id: str
    epoch: int
    vm_id: str


def string_keyed(value: object) -> dict[str, object] | None:
    """Narrows parsed JSON to a string-keyed object."""
    if not isinstance(value, dict):
        return None
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            return None
        result[key] = item
    return result


def read_identity(path: Path) -> Identity:
    value = string_keyed(json.loads(path.read_text(encoding="utf-8")))
    if value is None:
        raise ValueError("identity is not an object")
    base_url, token = value.get("base_url"), value.get("token")
    host_id, session_id = value.get("host_id"), value.get("session_id")
    epoch, vm_id = value.get("epoch"), value.get("vm_id")
    if not (
        isinstance(base_url, str)
        and base_url.startswith("https://")
        and isinstance(token, str)
        and isinstance(host_id, str)
        and isinstance(session_id, str)
        and isinstance(epoch, int)
        and epoch > 0
        and isinstance(vm_id, str)
    ):
        raise ValueError("identity fields are invalid")
    return Identity(
        base_url=base_url,
        token=token,
        host_id=host_id,
        session_id=session_id,
        epoch=epoch,
        vm_id=vm_id,
    )


def event(name: str, **counters: int | str) -> None:
    """Closed diagnostic events: a name, counters and exception class names only."""
    print(json.dumps({"event": name, **counters}), flush=True)


def control_frame(message: dict[str, object]) -> bytes:
    payload = json.dumps({**message, "version": 2}, separators=(",", ":")).encode()
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("control payload too large")
    return HEADER.pack(0, CONTROL, 0, len(payload)) + payload


def data_frame(channel: int, sequence: int, data: bytes) -> bytes:
    return HEADER.pack(channel, DATA, sequence, len(data)) + data


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass
class Ring:
    """Bounded output history addressed by absolute byte offsets."""

    base: int = 0
    data: bytearray = field(default_factory=bytearray)

    @property
    def tail(self) -> int:
        return self.base + len(self.data)

    def append(self, chunk: bytes) -> None:
        self.data.extend(chunk)
        excess = len(self.data) - RING_BYTES
        if excess > 0:
            del self.data[:excess]
            self.base += excess

    def replay_from(self, cursor: int) -> tuple[int, bytes]:
        """terminald semantics: start = clamp(cursor, base, tail)."""
        start = min(max(cursor, self.base), self.tail)
        return start, bytes(self.data[start - self.base :])


@dataclass
class Channel:
    """One attachment: per-channel output sequence, credit window and input order."""

    number: int
    session: "Session"
    writable: bool
    sequence: int = 0
    pending: list[bytes] = field(default_factory=list)
    sent_frames: int = 0
    sent_bytes: int = 0
    acked_frames: int = 0
    acked_bytes: int = 0
    in_flight: list[int] = field(default_factory=list)
    last_input: int = 0
    input_bytes: int = 0


@dataclass
class Session:
    """One guest shell on a real PTY."""

    guest_session_id: int
    request_id: str
    user: str
    cols: int
    rows: int
    master: int
    process: subprocess.Popen[bytes]
    ring: Ring = field(default_factory=Ring)
    channels: dict[int, Channel] = field(default_factory=dict)
    alive: bool = True
    created_ms: int = field(default_factory=now_ms)
    last_ms: int = field(default_factory=now_ms)


def set_size(fd: int, cols: int, rows: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def controlling_terminal() -> None:
    """Child side: the PTY becomes the new session's controlling terminal."""
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class TerminalHost:
    """@cc [owner:ghuntley,label:verification;security] mila-terminal-host-stand-in
    The stand-in MUST authenticate to Marshall only with the synthetic host's
    current credential and hello identity, MUST serve only the seeded terminal
    machine, MUST run guest shells as the unprivileged mila-guest account on
    real PTYs, MUST honour the stream v2 credit window, input order and cursor
    replay, and MUST NOT log terminal bytes, tokens or payloads.
    """

    def __init__(self, identity: Identity) -> None:
        self.identity = identity
        self.sessions: dict[int, Session] = {}
        self.by_request: dict[str, int] = {}
        self.channels: dict[int, Channel] = {}
        self.next_session = 1
        self.outbox: asyncio.Queue[bytes] | None = None
        self.heartbeat = 0
        account = pwd.getpwnam(GUEST_ACCOUNT)
        self.uid, self.gid, self.home = account.pw_uid, account.pw_gid, account.pw_dir

    def send(self, frame: bytes) -> None:
        """Frames leave through one ordered writer per connection."""
        if self.outbox is not None:
            self.outbox.put_nowait(frame)

    def reply(self, message: dict[str, object]) -> None:
        self.send(control_frame(message))

    def ours(self, message: dict[str, object]) -> bool:
        return message.get("vm_id") == self.identity["vm_id"]

    # --- PTY sessions -------------------------------------------------------

    def spawn(self, request_id: str, user: str, term: str, cols: int, rows: int) -> Session:
        master, slave = os.openpty()
        set_size(master, cols, rows)
        environment = {
            "HOME": self.home,
            "USER": GUEST_ACCOUNT,
            "LOGNAME": GUEST_ACCOUNT,
            "SHELL": SHELL,
            "TERM": term,
            "PATH": "/run/current-system/sw/bin",
            "LANG": "C.UTF-8",
        }
        process = subprocess.Popen(
            [SHELL, "-l"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            cwd=self.home,
            env=environment,
            user=self.uid,
            group=self.gid,
            extra_groups=[],
            start_new_session=True,
            preexec_fn=controlling_terminal,
            close_fds=True,
        )
        os.close(slave)
        os.set_blocking(master, False)
        session = Session(
            guest_session_id=self.next_session,
            request_id=request_id,
            user=user,
            cols=cols,
            rows=rows,
            master=master,
            process=process,
        )
        self.next_session += 1
        self.sessions[session.guest_session_id] = session
        self.by_request[request_id] = session.guest_session_id
        asyncio.get_running_loop().add_reader(master, self.readable, session)
        event("mila_terminal.session_created", sessions=len(self.sessions))
        return session

    def readable(self, session: Session) -> None:
        try:
            chunk = os.read(session.master, CHUNK)
        except BlockingIOError:
            return
        except OSError:
            chunk = b""
        if not chunk:
            self.exited(session)
            return
        session.ring.append(chunk)
        session.last_ms = now_ms()
        for channel in session.channels.values():
            channel.pending.append(chunk)
            self.flush(channel)

    def exited(self, session: Session) -> None:
        if not session.alive:
            return
        session.alive = False
        asyncio.get_running_loop().remove_reader(session.master)
        os.close(session.master)
        session.process.poll()
        for channel in list(session.channels.values()):
            self.close_channel(channel, "session_exit")
        event("mila_terminal.session_exited", sessions=len(self.sessions))

    def terminate(self, session: Session) -> None:
        if session.alive:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(session.process.pid, signal.SIGKILL)
            self.exited(session)
        session.process.wait()
        self.sessions.pop(session.guest_session_id, None)

    # --- channels -----------------------------------------------------------

    def flush(self, channel: Channel) -> None:
        while channel.pending and self.channels.get(channel.number) is channel:
            chunk = channel.pending[0]
            if (
                channel.sent_frames - channel.acked_frames >= WINDOW_FRAMES
                or channel.sent_bytes - channel.acked_bytes + len(chunk) > WINDOW_BYTES
            ):
                return
            channel.pending.pop(0)
            channel.sequence += 1
            channel.sent_frames += 1
            channel.sent_bytes += len(chunk)
            channel.in_flight.append(len(chunk))
            self.send(data_frame(channel.number, channel.sequence, chunk))

    def close_channel(self, channel: Channel, reason: str) -> None:
        if self.channels.pop(channel.number, None) is None:
            return
        channel.session.channels.pop(channel.number, None)
        self.reply({"type": "closed", "channel": channel.number, "reason": reason})

    def detach(self, number: int) -> None:
        channel = self.channels.pop(number, None)
        if channel is not None:
            channel.session.channels.pop(number, None)

    def input(self, number: int, sequence: int, data: bytes) -> None:
        channel = self.channels.get(number)
        if channel is None:
            return
        if sequence != channel.last_input + 1 or not channel.writable:
            self.close_channel(channel, "fenced")
            return
        channel.last_input = sequence
        try:
            os.write(channel.session.master, data)
        except OSError:
            self.close_channel(channel, "session_exit")
            return
        channel.input_bytes += len(data)
        self.reply(
            {
                "type": "input_ack",
                "channel": number,
                "frames": sequence,
                "bytes": channel.input_bytes,
            }
        )

    def output_ack(self, number: int, frames: int, total: int) -> None:
        channel = self.channels.get(number)
        if channel is None:
            return
        if frames <= channel.acked_frames and total <= channel.acked_bytes:
            return
        if frames <= channel.acked_frames or frames > channel.sent_frames:
            self.close_channel(channel, "fenced")
            return
        consumed = channel.in_flight[: frames - channel.acked_frames]
        if channel.acked_bytes + sum(consumed) != total:
            self.close_channel(channel, "fenced")
            return
        del channel.in_flight[: frames - channel.acked_frames]
        channel.acked_frames, channel.acked_bytes = frames, total
        self.flush(channel)

    # --- control ------------------------------------------------------------

    def control(self, message: dict[str, object]) -> None:
        kind = message.get("type")
        if kind == "heartbeat":
            self.reply({"type": "heartbeat_reply", "sequence": message.get("sequence")})
        elif kind == "heartbeat_reply":
            return
        elif kind == "create":
            self.create(message)
        elif kind == "creation_query" and self.ours(message):
            request = str(message.get("request_id"))
            existing = self.sessions.get(self.by_request.get(request, 0))
            state = "unknown" if existing is None else ("running" if existing.alive else "exited")
            self.reply(
                {
                    "type": "creation_status",
                    "request_id": request,
                    "state": state,
                    "guest_session_id": None if existing is None else existing.guest_session_id,
                }
            )
        elif kind == "creation_cancel" and self.ours(message):
            request = str(message.get("request_id"))
            existing = self.sessions.get(self.by_request.pop(request, 0))
            if existing is not None:
                self.terminate(existing)
            self.reply({"type": "creation_cancelled", "request_id": request, "ok": True})
        elif kind == "attach":
            self.attach(message)
        elif kind == "channel_close":
            number = message.get("channel")
            if isinstance(number, int):
                self.detach(number)
        elif kind == "output_ack":
            number, frames, total = (
                message.get("channel"),
                message.get("frames"),
                message.get("bytes"),
            )
            if isinstance(number, int) and isinstance(frames, int) and isinstance(total, int):
                self.output_ack(number, frames, total)
        elif kind == "resize" and self.ours(message):
            session = self.sessions.get(int(str(message.get("guest_session_id"))))
            cols, rows = message.get("cols"), message.get("rows")
            if session and session.alive and isinstance(cols, int) and isinstance(rows, int):
                session.cols, session.rows = cols, rows
                set_size(session.master, cols, rows)
        elif kind == "kill" and self.ours(message):
            session = self.sessions.get(int(str(message.get("guest_session_id"))))
            if session is not None:
                for channel in list(session.channels.values()):
                    self.close_channel(channel, "killed")
                self.terminate(session)
                event("mila_terminal.session_killed", sessions=len(self.sessions))
            self.reply({**message, "type": "killed", "ok": True})
        elif kind == "listing" and self.ours(message):
            self.reply(
                {
                    "type": "listed",
                    "vm_id": self.identity["vm_id"],
                    "sessions": [
                        {
                            "guest_session_id": s.guest_session_id,
                            "user": s.user,
                            "cols": s.cols,
                            "rows": s.rows,
                            "viewers": len(s.channels),
                            "alive": s.alive,
                            "created_ms": s.created_ms,
                            "last_ms": s.last_ms,
                        }
                        for s in list(self.sessions.values())[:64]
                    ],
                }
            )
        elif kind == "users" and self.ours(message):
            users = sorted({s.user for s in self.sessions.values()} | {GUEST_ACCOUNT})
            self.reply({"type": "users_listed", "vm_id": self.identity["vm_id"], "users": users})
        elif kind == "boot_log":
            self.reply(
                {
                    "type": "boot_log_data",
                    "vm_id": message.get("vm_id"),
                    "next": message.get("cursor"),
                    "bytes": base64.b64encode(b"").decode(),
                }
            )
        elif kind == "android_display_open":
            self.reply(
                {
                    "type": "android_display_opened",
                    "channel": message.get("channel"),
                    "generation": message.get("generation"),
                    "ok": False,
                    "reason": "display_unavailable",
                }
            )
        # Every other VM-scoped request is left unanswered, as Lilly does when
        # it cannot reach a guest: Marshall's bounded request then expires.

    def create(self, message: dict[str, object]) -> None:
        request = str(message.get("request_id"))
        channel = message.get("channel")
        user, term = message.get("user"), message.get("term")
        cols, rows = message.get("cols"), message.get("rows")
        existing = self.sessions.get(self.by_request.get(request, 0))
        ok = self.ours(message) and isinstance(user, str) and isinstance(term, str)
        reason: str | None = None if ok else "dial_failed"
        session_id: int | None = None
        if ok and existing is not None:
            session_id = existing.guest_session_id
        elif ok and len(self.sessions) >= MAX_SESSIONS:
            ok, reason = False, "limit"
        elif ok and isinstance(cols, int) and isinstance(rows, int):
            assert isinstance(user, str) and isinstance(term, str)
            session_id = self.spawn(request, user, term, cols, rows).guest_session_id
        else:
            ok, reason = False, "rejected"
        self.reply(
            {
                "type": "created",
                "request_id": request,
                "ok": ok,
                "channel": channel,
                "guest_session_id": session_id if ok else None,
                "reason": None if ok else reason,
            }
        )

    def attach(self, message: dict[str, object]) -> None:
        number = message.get("channel")
        cursor = message.get("cursor")
        session = self.sessions.get(int(str(message.get("guest_session_id"))))
        if (
            not self.ours(message)
            or not isinstance(number, int)
            or not isinstance(cursor, int)
            or session is None
            or not session.alive
        ):
            self.reply(
                {
                    "type": "attached",
                    "replay_bytes": 0,
                    "channel": number,
                    "ok": False,
                    "guest_session_id": None,
                    "from": None,
                    "reason": "not_found" if self.ours(message) else "dial_failed",
                }
            )
            return
        writable = message.get("mode") == "rw"
        cols, rows = message.get("cols"), message.get("rows")
        if writable and isinstance(cols, int) and isinstance(rows, int) and cols > 0 and rows > 0:
            session.cols, session.rows = cols, rows
            set_size(session.master, cols, rows)
        start, replay = session.ring.replay_from(cursor)
        channel = Channel(number=number, session=session, writable=writable)
        channel.pending = [replay[i : i + CHUNK] for i in range(0, len(replay), CHUNK)]
        self.channels[number] = channel
        session.channels[number] = channel
        self.reply(
            {
                "type": "attached",
                "replay_bytes": len(replay),
                "channel": number,
                "ok": True,
                "guest_session_id": session.guest_session_id,
                "from": start,
                "reason": None,
            }
        )
        self.flush(channel)

    # --- transport ----------------------------------------------------------

    def frames(self, buffer: bytearray) -> None:
        while len(buffer) >= HEADER.size:
            number, kind, sequence, length = HEADER.unpack_from(buffer)
            if len(buffer) < HEADER.size + length:
                return
            payload = bytes(buffer[HEADER.size : HEADER.size + length])
            del buffer[: HEADER.size + length]
            if kind == CONTROL and number == 0:
                decoded = string_keyed(json.loads(payload))
                if decoded is not None and decoded.get("version") == 2:
                    self.control(decoded)
            elif kind == DATA and number > 0:
                self.input(number, sequence, payload)

    async def beat(self) -> None:
        while True:
            await asyncio.sleep(1)
            self.heartbeat += 1
            self.reply({"type": "heartbeat", "sequence": self.heartbeat})

    @staticmethod
    async def write(socket: ClientConnection, outbox: "asyncio.Queue[bytes]") -> None:
        while True:
            await socket.send(await outbox.get())

    async def run(self, ca_file: str) -> None:
        context = ssl.create_default_context(cafile=ca_file)
        uri = (
            self.identity["base_url"].replace("https://", "wss://", 1)
            + "/api/provisioners/v4/stream"
        )
        async with connect(
            uri,
            ssl=context,
            additional_headers={"authorization": "Lilly " + self.identity["token"]},
            max_size=HEADER.size + MAX_PAYLOAD,
            compression=None,
        ) as socket:
            outbox: asyncio.Queue[bytes] = asyncio.Queue()
            self.outbox = outbox
            writer = asyncio.create_task(self.write(socket, outbox))
            self.heartbeat = 0
            self.reply(
                {
                    "type": "hello",
                    "host_id": self.identity["host_id"],
                    "session_id": self.identity["session_id"],
                    "epoch": self.identity["epoch"],
                }
            )
            buffer = bytearray()
            beating: asyncio.Task[None] | None = None
            try:
                async for message in socket:
                    if not isinstance(message, bytes):
                        continue
                    if beating is None:
                        # The first reply is hello_response; heartbeats follow it.
                        beating = asyncio.create_task(self.beat())
                        event("mila_terminal.stream_authenticated")
                    buffer.extend(message)
                    self.frames(buffer)
            finally:
                if beating is not None:
                    beating.cancel()
                writer.cancel()
                self.outbox = None
                for channel in list(self.channels.values()):
                    self.detach(channel.number)


async def main() -> None:
    identity_path, ca_file = Path(sys.argv[1]), sys.argv[2]
    host: TerminalHost | None = None
    while True:
        try:
            identity = read_identity(identity_path)
            if host is None or host.identity != identity:
                # A new host session (fixture restart) starts a fresh guest boot.
                if host is not None:
                    for session in list(host.sessions.values()):
                        host.terminate(session)
                host = TerminalHost(identity)
            await host.run(ca_file)
            event("mila_terminal.stream_closed")
        except (OSError, ValueError, WebSocketException) as error:
            event("mila_terminal.stream_unavailable", kind=type(error).__name__)
        await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())
