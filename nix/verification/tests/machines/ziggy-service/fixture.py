"""Native provider and control fixtures; production keys and outbound access are absent."""

import base64
import hashlib
import json
import ssl
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BufferedIOBase
from pathlib import Path

ROOT = Path("/run/ziggy-fixture")
HOST = "11111111-1111-4111-8111-111111111111"
lock = threading.Lock()


def object_value(value: object) -> dict[str, object] | None:
    """@cc [owner:ghuntley,label:verification] ziggy-fixture-object-boundary
    Decoded peer data MUST be checked as a string-keyed object before typed
    fixture dispatch. Invalid objects MUST NOT enter the synthetic authority path.
    """
    if not isinstance(value, dict):
        return None
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            return None
        result[key] = item
    return result


def decode_object(raw: bytes) -> dict[str, object] | None:
    """Decode a peer object without trusting the decoder's unrestricted result."""
    try:
        decoded: object = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return object_value(decoded)


def server_frame(payload: bytes) -> bytes:
    """One unmasked final text frame from the server."""
    size = len(payload)
    if size < 126:
        header = struct.pack("!BB", 0x81, size)
    elif size < 65536:
        header = struct.pack("!BBH", 0x81, 126, size)
    else:
        header = struct.pack("!BBQ", 0x81, 127, size)
    return header + payload


def read_exact(stream: BufferedIOBase, size: int) -> bytes | None:
    data = stream.read(size)
    return data if data is not None and len(data) == size else None


def read_client_frame(stream: BufferedIOBase) -> tuple[int, bytes] | None:
    """One masked client frame; None when the connection ends."""
    head = read_exact(stream, 2)
    if head is None:
        return None
    opcode, length = head[0] & 0x0F, head[1] & 0x7F
    if length == 126:
        extended = read_exact(stream, 2)
        if extended is None:
            return None
        length = struct.unpack("!H", extended)[0]
    elif length == 127:
        extended = read_exact(stream, 8)
        if extended is None:
            return None
        length = struct.unpack("!Q", extended)[0]
    if length > 1_200_000:
        return None
    mask = read_exact(stream, 4)
    payload = read_exact(stream, length)
    if mask is None or payload is None:
        return None
    return opcode, bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


def control(route: str, value: dict[str, object]) -> tuple[int, object]:
    """One Ziggy control request: an HTTPS-style status and document."""
    if route == "agent_next":
        with lock:
            if (ROOT / "agent-ready").exists() and not (ROOT / "agent-claimed").exists():
                (ROOT / "agent-claimed").touch()
                return reply(
                    dict(
                        call=dict(
                            id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                            claim_id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                            binding=dict(
                                host_id=HOST,
                                vm_id=HOST,
                                placement_id=HOST,
                                execution_epoch=1,
                            ),
                            request=dict(
                                model="fixture-model",
                                stream=True,
                                store=False,
                                input=[dict(role="user", content="private agent prompt")],
                            ),
                        )
                    )
                )
        return reply(dict(call=None))
    if route == "agent_result":
        with lock, (ROOT / "agent-results.jsonl").open("a") as output:
            output.write(json.dumps(value) + "\n")
        return reply(dict(acknowledged=value["call_id"]))
    if route == "identity":
        return reply(dict(host_id=HOST))
    if route == "renew" and (ROOT / "revoke").exists():
        return reply({}, 403)
    if route in ("admit", "renew"):
        if route == "admit":
            with lock, (ROOT / "admissions.jsonl").open("a") as output:
                output.write(json.dumps(value) + "\n")
        return reply(
            dict(
                request_id=value["request_id"],
                owner_id=HOST,
                admitted_at=int(time.time()),
                ttl_ms=30000,
            )
        )
    if route == "authorize":
        return reply(dict(authorized=True))
    if route == "complete":
        if (ROOT / "hold-receipts").exists():
            return reply({}, 503)
        with lock, (ROOT / "completions.jsonl").open("a") as output:
            output.write(json.dumps(value) + "\n")
        return reply(dict(acknowledged=value["request_id"]))

    return 400, {}


def reply(value: object, status: int = 200) -> tuple[int, object]:
    return status, value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def reply(self, value: object, status: int = 200) -> None:
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.path == "/api/control/v1":
            return self.control_socket()
        if self.path == "/v1/models":
            key = self.headers.get("Authorization") or self.headers.get("x-api-key")
            if key not in ("Bearer synthetic-openai-private", "synthetic-anthropic-private"):
                return self.reply({}, 403)
            return self.reply(dict(data=[dict(id="fixture-model")], has_more=False))
        self.reply({}, 404)

    def control_socket(self) -> None:
        """The Marshall control WebSocket (ADR-0142), synthetic Ziggy service."""
        if self.headers.get("overalls-control") != "1":
            return self.reply({}, 426)
        if (
            self.headers.get("overalls-service") != "ziggy"
            or self.headers.get("Authorization") != "Bearer " + HOST + "." + "A" * 43
        ):
            return self.reply({}, 401)
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        write_lock = threading.Lock()

        def send(value: dict[str, object]) -> None:
            with write_lock:
                self.wfile.write(server_frame(json.dumps(value).encode()))
                self.wfile.flush()

        def answer(message: dict[str, object]) -> None:
            op, body = message.get("op"), object_value(message.get("body"))
            if not isinstance(op, str) or not op.startswith("ziggy.") or body is None:
                status, value = 400, {}
            else:
                status, value = control(op.removeprefix("ziggy."), body)
            if status == 200:
                send({"k": "res", "id": message.get("id"), "ok": True, "body": value})
            else:
                error = {403: "unauthorized", 503: "unavailable"}.get(status, "invalid_request")
                send({"k": "res", "id": message.get("id"), "ok": False, "error": error})

        while True:
            frame = read_client_frame(self.rfile)
            if frame is None or frame[0] == 8:
                return
            if frame[0] != 1:
                continue
            message = decode_object(frame[1])
            if message is None:
                return
            kind = message.get("k")
            if kind == "hello":
                if message.get("bind") != {"host_id": HOST}:
                    return
                send({"k": "welcome", "conn": "fixture", "heartbeat_ms": 5000, "limits": {}})
            elif kind == "ping":
                send({"k": "pong", "n": message.get("n")})
            elif kind == "req":
                threading.Thread(target=answer, args=(message,), daemon=True).start()

    def do_POST(self) -> None:
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 < size <= 1048576:
            return self.reply({}, 400)
        raw = self.rfile.read(size)
        value = decode_object(raw)
        if value is None:
            return self.reply({}, 400)
        if self.path in (
            "/v1/responses",
            "/v1/messages",
            "/v1/messages?beta=true",
            "/v1/messages/count_tokens",
            "/v1/messages/count_tokens?beta=true",
            "/v1/chat/completions",
        ):
            native_path = self.path.removesuffix("?beta=true")
            expected = (
                "Bearer synthetic-openai-private"
                if native_path in ("/v1/responses", "/v1/chat/completions")
                else "synthetic-anthropic-private"
            )
            actual = (
                self.headers.get("Authorization")
                if native_path in ("/v1/responses", "/v1/chat/completions")
                else self.headers.get("x-api-key")
            )
            if actual != expected or self.headers.get("x-overalls-binding"):
                return self.reply({}, 403)
            with lock, (ROOT / "provider-calls").open("a") as output:
                output.write(self.path + "\n")
            # Synthetic request bytes belong only to this isolated private fixture.
            with lock, (ROOT / "provider-requests.jsonl").open("a") as output:
                output.write(
                    json.dumps(
                        dict(
                            path=self.path,
                            body=raw.decode(),
                            anthropic_version=self.headers.get("anthropic-version"),
                            anthropic_beta=self.headers.get("anthropic-beta"),
                            authorization=self.headers.get("authorization"),
                            unexpected=self.headers.get("x-unexpected"),
                        )
                    )
                    + "\n"
                )
            if native_path == "/v1/messages/count_tokens":
                return self.reply(dict(input_tokens=3))
            if self.path == "/v1/chat/completions":
                return self.reply(
                    dict(
                        choices=[
                            dict(message=dict(role="assistant", content="synthetic agent reply"))
                        ],
                        usage=dict(prompt_tokens=3, completion_tokens=7, total_tokens=10),
                    )
                )
            if self.path == "/v1/responses" and isinstance(value.get("input"), list):
                item = dict(
                    type="message",
                    role="assistant",
                    content=[dict(type="output_text", text="synthetic agent reply")],
                )
                events = [
                    dict(type="response.output_item.done", output_index=0, item=item),
                    dict(
                        type="response.completed",
                        response=dict(
                            status="completed",
                            output=[],
                            usage=dict(input_tokens=3, output_tokens=7),
                        ),
                    ),
                ]
                raw = b"".join(("data: " + json.dumps(event) + "\n\n").encode() for event in events)
                # A streamed Responses call answers with SSE, as the provider does;
                # Ziggy selects its stream reassembly from this content type.
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            if value.get("stream"):
                if self.path.endswith("responses"):
                    events = [
                        dict(type="response.output_text.delta", delta="synthetic-output"),
                        dict(
                            type="response.completed",
                            response=dict(usage=dict(input_tokens=3, output_tokens=7)),
                        ),
                    ]
                else:
                    events = [
                        dict(
                            type="message_start",
                            message=dict(usage=dict(input_tokens=3, output_tokens=0)),
                        ),
                        dict(type="message_delta", usage=dict(output_tokens=7)),
                    ]
                chunks = [("data: " + json.dumps(event) + "\n\n").encode() for event in events]
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for chunk in chunks:
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.1)
                if value.get("hold"):
                    try:
                        for _ in range(400):
                            self.wfile.write(b"d\r\n: heartbeat\n\n\r\n")
                            self.wfile.flush()
                            time.sleep(0.1)
                    except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                        return
                self.wfile.write(b"0\r\n\r\n")
                return
            return self.reply(
                dict(usage=dict(input_tokens=3, output_tokens=7), output="synthetic-output")
            )
        self.reply({}, 404)


server = ThreadingHTTPServer(("127.0.0.1", 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
