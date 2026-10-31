"""Controlled GitHub API, Smart HTTP, LFS, binding and admission authorities.

Only the packaged Audi/Galileo transport and actual managed clients are under
test here. This authority is deliberately independent of Marshall and Lilly.
All credentials and repositories are synthetic and confined to this machine.
"""

import base64
import grp
import hashlib
import io
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import uuid
import zipfile
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path("/run/galileo-fixture")
HOST = "11111111-1111-4111-8111-111111111111"
VM1 = "22222222-2222-4222-8222-222222222222"
VM2 = "44444444-4444-4444-8444-444444444444"
PLACEMENT = "33333333-3333-4333-8333-333333333333"
TOKEN = HOST + "." + "A" * 43
MAX_BODY = 16 * 1024 * 1024
LOCK = threading.Lock()
ORIGINS = {
    "api": "https://api.github.com",
    "uploads": "https://uploads.github.com",
    "git": "https://github.com",
    "gist": "https://gist.github.com",
    "raw": "https://raw.githubusercontent.com",
    "gist_raw": "https://gist.githubusercontent.com",
    "capability": "https://api.github.com",
}


@dataclass(frozen=True)
class Authority:
    owner: int
    phase: str
    generation: int

    @property
    def token(self) -> str:
        return f"synthetic-owner-{self.owner}-generation-{self.generation}"

    @property
    def action(self) -> str:
        return f"RemoteAuth action-{self.owner}-generation-{self.generation}"


@dataclass(frozen=True)
class Lease:
    vm: str
    owner: int
    generation: int
    expires: float


LEASES: dict[str, Lease] = {}


def record(event: dict[str, object]) -> None:
    """Keep bounded structural observations; never record credentials or queries."""
    with LOCK, (ROOT / "observed.jsonl").open("a") as output:
        output.write(json.dumps(event) + "\n")


def object_dict(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or len(value) > 1000:
        raise ValueError("invalid object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("invalid object key")
        result[key] = item
    return result


def decode_object(raw: bytes | str) -> dict[str, object]:
    value: object = json.loads(raw)
    return object_dict(value)


def authority(owner: int) -> Authority:
    path = ROOT / f"authority-{owner}.json"
    value = decode_object(path.read_bytes()) if path.exists() else {}
    phase, generation = value.get("phase", "active"), value.get("generation", 1)
    if not isinstance(phase, str) or phase not in {
        "active",
        "anonymous",
        "draining",
        "refuse",
        "outage",
    }:
        raise ValueError("invalid phase")
    if (
        not isinstance(phase, str)
        or not isinstance(generation, int)
        or generation not in range(1, 100)
    ):
        raise ValueError("invalid generation")
    return Authority(owner, phase, generation)


def physical_binding(address: str) -> dict[str, object]:
    second = ROOT / "client2-address"
    vm = VM2 if second.exists() and second.read_text().strip() == address else VM1
    return {"host_id": HOST, "vm_id": vm, "placement_id": PLACEMENT, "execution_epoch": 1}


def admitted_binding(value: object) -> tuple[dict[str, object], Authority] | None:
    if not isinstance(value, dict):
        return None
    binding = object_dict(value)
    vm = binding.get("vm_id")
    if (
        not isinstance(vm, str)
        or vm not in {VM1, VM2}
        or binding
        != {
            "host_id": HOST,
            "vm_id": vm,
            "placement_id": PLACEMENT,
            "execution_epoch": 1,
        }
    ):
        return None
    return binding, authority(2 if vm == VM2 else 1)


def receive_exact(peer: socket.socket, size: int) -> bytes:
    value = b""
    while len(value) < size:
        chunk = peer.recv(size - len(value))
        if not chunk:
            raise ConnectionError("truncated fixture frame")
        value += chunk
    return value


def watch(peer: socket.socket) -> None:
    try:
        size = struct.unpack("!I", receive_exact(peer, 4))[0]
        if size > 2048:
            return
        value = decode_object(receive_exact(peer, size))
        if (
            set(value) != {"version", "address", "purpose"}
            or value["version"] != 3
            or value["purpose"] != "services"
        ):
            return
        address = value["address"]
        if not isinstance(address, str):
            return
        raw = json.dumps(
            {"version": 3, "purpose": "services", "binding": physical_binding(address)}
        ).encode()
        peer.sendall(struct.pack("!I", len(raw)) + raw)
        while peer.recv(64):
            pass
    except (OSError, ValueError, ConnectionError):
        return
    finally:
        peer.close()


def connector() -> None:
    path = ROOT / "connector.sock"
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(path))
        os.chown(path, 0, grp.getgrnam("audi").gr_gid)
        path.chmod(0o660)
        server.listen(64)
        while True:
            peer, _ = server.accept()
            threading.Thread(target=watch, args=(peer,), daemon=True).start()


def frame(raw: bytes) -> bytes:
    length = len(raw)
    if length < 126:
        return struct.pack("!BB", 0x81, length) + raw
    if length < 65536:
        return struct.pack("!BBH", 0x81, 126, length) + raw
    return struct.pack("!BBQ", 0x81, 127, length) + raw


def control_result(operation: str, raw: object) -> tuple[bool, dict[str, object] | str]:
    if operation == "galileo.identity":
        return True, {"host_id": HOST}
    body = object_dict(raw)
    admitted = admitted_binding(body.get("binding"))
    if admitted is None:
        return False, "unauthorized"
    binding, current = admitted
    if current.phase == "outage":
        return False, "unavailable"
    if current.phase == "refuse":
        return False, "unauthorized"
    if operation == "galileo.github.authorize":
        route = object_dict(body.get("route"))
        kind = route.get("kind")
        if set(body) != {"binding", "route"} or not isinstance(kind, str) or kind not in ORIGINS:
            return False, "invalid_request"
        if current.phase == "draining":
            return False, "unavailable"
        headers: list[list[str]] = []
        lease: dict[str, object] = {"kind": "anonymous"}
        if current.phase == "active":
            identifier = str(uuid.uuid4())
            vm = binding["vm_id"]
            if not isinstance(vm, str):
                raise ValueError("invalid fixture VM")
            with LOCK:
                if len(LEASES) > 4096:
                    return False, "unavailable"
                LEASES[identifier] = Lease(
                    vm, current.owner, current.generation, time.monotonic() + 5
                )
            lease = {
                "kind": "connected",
                "id": identifier,
                "connection_id": VM2 if current.owner == 2 else VM1,
                "generation": current.generation,
            }
            if kind != "capability":
                authentication = "Bearer " + current.token
                if kind in {"git", "gist"}:
                    authentication = (
                        "Basic "
                        + base64.b64encode(("x-access-token:" + current.token).encode()).decode()
                    )
                headers = [["authorization", authentication]]
        return True, {
            "target": ORIGINS[kind],
            "strip_prefix": None,
            "headers": headers,
            "ttl": 5000,
            "lease": lease,
        }
    lease = object_dict(body.get("lease"))
    if operation == "galileo.github.close":
        identifier = lease.get("id")
        if isinstance(identifier, str):
            with LOCK:
                LEASES.pop(identifier, None)
        return True, {"closed": True}
    if operation != "galileo.github.renew":
        return False, "invalid_request"
    if lease == {"kind": "anonymous"}:
        return True, {"version": 1, "ttl": 5000}
    identifier = lease.get("id")
    if not isinstance(identifier, str):
        return False, "unauthorized"
    with LOCK:
        pin = LEASES.get(identifier)
        if (
            pin is None
            or pin.vm != binding["vm_id"]
            or pin.owner != current.owner
            or pin.generation != current.generation
            or lease.get("generation") != pin.generation
            or pin.expires <= time.monotonic()
            or current.phase != "active"
        ):
            record_refusal = True
        else:
            LEASES[identifier] = Lease(pin.vm, pin.owner, pin.generation, time.monotonic() + 5)
            record_refusal = False
    if record_refusal:
        record({"event": "renewal_refused", "owner": current.owner})
        return False, "unauthorized"
    return True, {"version": 1, "ttl": 5000}


class Server(ThreadingHTTPServer):
    def handle_error(
        self, request: socket.socket | tuple[bytes, socket.socket], client_address: tuple[str, int]
    ) -> None:
        record({"event": "fixture_request_failed"})


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # The current request's framed body, read at most once per request.
    body: bytes | None = None

    def log_message(self, format: str, *args: object) -> None:
        pass

    def reply(
        self, value: object, status: int = 200, headers: dict[str, str] | None = None
    ) -> None:
        self.bytes_reply(
            json.dumps(value).encode(),
            status,
            {"Content-Type": "application/json", **(headers or {})},
        )

    def bytes_reply(
        self, body: bytes, status: int = 200, headers: dict[str, str] | None = None
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
            self.wfile.flush()

    def read_body(self) -> bytes:
        if self.body is None:
            self.body = self.read_framed_body()
        return self.body

    def read_framed_body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > MAX_BODY:
                raise ValueError("invalid fixture body length")
            value = self.rfile.read(length)
            if len(value) != length:
                raise ConnectionError("truncated fixture body")
            return value
        chunks: list[bytes] = []
        total = 0
        while True:
            line = self.rfile.readline(4097)
            if not line.endswith(b"\r\n") or len(line) > 4096 or b";" in line:
                raise ValueError("invalid fixture chunk line")
            size = int(line[:-2], 16)
            if size == 0:
                if self.rfile.readline(4097) != b"\r\n":
                    raise ValueError("unsupported fixture trailers")
                return b"".join(chunks)
            total += size
            if total > MAX_BODY:
                raise ValueError("fixture body limit")
            value = self.rfile.read(size)
            if len(value) != size or self.rfile.read(2) != b"\r\n":
                raise ConnectionError("truncated fixture chunk")
            chunks.append(value)

    def do_GET(self) -> None:
        self.dispatch()

    def do_HEAD(self) -> None:
        self.dispatch()

    def do_POST(self) -> None:
        self.dispatch()

    def do_PUT(self) -> None:
        self.dispatch()

    def do_PATCH(self) -> None:
        self.dispatch()

    def do_DELETE(self) -> None:
        self.dispatch()

    def control_socket(self) -> None:
        if self.headers.get("overalls-control") != "1":
            return self.reply({}, 426)
        if (
            self.headers.get("overalls-service") != "galileo"
            or self.headers.get("Authorization") != "Bearer " + TOKEN
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
                self.wfile.write(frame(json.dumps(value).encode()))
                self.wfile.flush()

        while True:
            head = self.rfile.read(2)
            if len(head) != 2:
                return
            opcode, length = head[0] & 15, head[1] & 127
            if length in {126, 127}:
                count = 2 if length == 126 else 8
                length = int.from_bytes(self.rfile.read(count), "big")
            if length > MAX_BODY or not head[1] & 128:
                return
            mask, payload = self.rfile.read(4), self.rfile.read(length)
            if len(mask) != 4 or len(payload) != length or opcode == 8:
                return
            if opcode != 1:
                continue
            message = decode_object(
                bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
            )
            kind = message.get("k")
            if kind == "hello":
                send({"k": "welcome", "conn": "github-fixture", "heartbeat_ms": 5000, "limits": {}})
            elif kind == "ping":
                send({"k": "pong", "n": message.get("n")})
            elif kind == "req":
                threading.Thread(target=self.answer, args=(message, send), daemon=True).start()

    def answer(self, message: dict[str, object], send: Callable[[dict[str, object]], None]) -> None:
        operation = message.get("op")
        try:
            ok, result = control_result(
                operation if isinstance(operation, str) else "", message.get("body")
            )
        except (ValueError, OSError):
            ok, result = False, "invalid_request"
        response = {"k": "res", "id": message.get("id"), "ok": ok}
        response["body" if ok else "error"] = result
        with suppress(OSError, ConnectionError):
            send(response)

    def identify(self) -> tuple[int | None, str]:
        value = self.headers.get("Authorization", "")
        for owner in [1, 2]:
            current = authority(owner)
            if value == "Bearer " + current.token:
                return owner, "oauth"
            basic = (
                "Basic " + base64.b64encode(("x-access-token:" + current.token).encode()).decode()
            )
            if value == basic:
                return owner, "oauth"
            if value == current.action:
                return owner, "action"
        return None, "none" if value == "" else "invalid"

    def dispatch(self) -> None:
        host = self.headers.get("Host", "").split(":", 1)[0]
        path = urlsplit(self.path).path
        if host == "control.test" and path == "/api/control/v1":
            return self.control_socket()
        owner, credential = self.identify()
        record(
            {
                "event": "request",
                "host": host,
                "method": self.command,
                "path": path,
                "owner": owner,
                "credential": credential,
            }
        )
        # Drain the framed request body before any reply, as an HTTP/1.1 origin
        # must: closing with unread bytes resets the connection and can discard
        # the response before the client reads it.
        self.body = None
        self.read_body()
        if host in {
            "github-cloud.githubusercontent.com",
            "github-cloud.s3.amazonaws.com",
            "release-assets.githubusercontent.com",
        }:
            return self.storage(path, owner, credential)
        if path == "/public":
            return self.reply({"public": True, "authenticated": owner is not None})
        if owner is None:
            return self.reply({"message": "Requires authentication"}, 401)
        if host == "github.com":
            if "/info/lfs/" in path:
                return self.lfs(path, owner)
            return self.git(path)
        if host == "uploads.github.com":
            body = self.read_body()
            record(
                {
                    "event": "release_upload",
                    "bytes": len(body),
                    "sha256": hashlib.sha256(body).hexdigest(),
                }
            )
            return self.reply(
                {"id": 1, "name": parse_qs(urlsplit(self.path).query).get("name", ["asset"])[0]},
                201,
            )
        if host != "api.github.com":
            return self.reply({"message": "Unknown fixture host"}, 404)
        self.api(path, owner)

    def api(self, path: str, owner: int) -> None:
        if path == "/user":
            return self.reply(
                {"id": owner, "login": f"owner-{owner}"},
                headers={"X-OAuth-Scopes": "repo, workflow, read:org"},
            )
        if path == "/graphql":
            self.read_body()
            return self.reply({"data": {"viewer": {"login": f"owner-{owner}"}}})
        if path == "/user/orgs":
            return self.reply([{"login": "fixture-org", "id": 1}])
        if path == "/repos/owner/old":
            return self.reply(
                {},
                301 if self.command in {"GET", "HEAD"} else 307,
                {"Location": "https://api.github.com/repos/owner/private"},
            )
        if path == "/repos/owner/private":
            self.read_body()
            return self.reply(
                {
                    "id": 1,
                    "full_name": "owner/private",
                    "name": "private",
                    "private": True,
                    "owner": {"login": "owner"},
                    "default_branch": "main",
                    "permissions": {"push": True},
                }
            )
        if path == "/repos/owner/private/issues":
            page = parse_qs(urlsplit(self.path).query).get("page", ["1"])[0]
            headers = (
                {"Link": '<https://api.github.com/repos/owner/private/issues?page=2>; rel="next"'}
                if page == "1"
                else {}
            )
            return self.reply([{"number": int(page), "title": "synthetic"}], headers=headers)
        if path == "/repos/owner/private/pulls" and self.command == "POST":
            self.read_body()
            return self.reply(
                {"number": 1, "html_url": "https://github.com/owner/private/pull/1"}, 201
            )
        if path.endswith("/actions/runs/1/logs") or path.endswith("/actions/artifacts/1/zip"):
            return self.reply(
                {},
                302,
                {
                    "Location": "https://release-assets.githubusercontent.com/archive?sig=synthetic-signed-authority"
                },
            )
        if path.endswith("/actions/runs/1/artifacts") or path.endswith("/actions/artifacts"):
            return self.reply(
                {
                    "total_count": 1,
                    "artifacts": [
                        {
                            "id": 1,
                            "name": "fixture",
                            "expired": False,
                            "archive_download_url": "https://api.github.com/repos/owner/private/actions/artifacts/1/zip",
                        }
                    ],
                }
            )
        if path == "/repos/owner/private/releases/tags/v1":
            return self.reply(
                {
                    "id": 1,
                    "tag_name": "v1",
                    "upload_url": "https://uploads.github.com/repos/owner/private/releases/1/assets{?name,label}",
                    "assets": [],
                }
            )
        if path == "/fixture/capability":
            return self.reply(
                {
                    "url": "https://release-assets.githubusercontent.com/archive?sig=synthetic-signed-authority"
                }
            )
        if path == "/fixture/unreviewed-redirect":
            return self.reply(
                {}, 302, {"Location": "https://attacker.invalid/archive?sig=synthetic"}
            )
        if path == "/fixture/hold":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"6\r\nprefix\r\n")
            self.wfile.flush()
            record({"event": "hold_opened", "owner": owner})
            # Keep the response open long enough for Galileo's bounded lease
            # renewal path to run before the authority is withdrawn.
            time.sleep(3)
            self.connection.settimeout(10)
            try:
                closed = self.connection.recv(1) == b""
            except (OSError, ConnectionError):
                closed = True
            record({"event": "hold_closed", "owner": owner, "closed": closed})
            self.close_connection = True
            return
        self.reply({"message": "Unknown fixture API"}, 404)

    def git(self, path: str) -> None:
        body = self.read_body()
        environment = {
            **os.environ,
            "GIT_PROJECT_ROOT": str(ROOT / "repositories"),
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": path,
            "QUERY_STRING": urlsplit(self.path).query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_USER": "fixture-owner",
        }
        result = subprocess.run(
            ["git", "http-backend"], input=body, env=environment, capture_output=True, check=False
        )
        if result.returncode != 0:
            return self.reply({"message": "Git fixture failed"}, 500)
        raw_headers, separator, response = result.stdout.partition(b"\r\n\r\n")
        if not separator:
            raise ValueError("invalid Git CGI response")
        headers: dict[str, str] = {}
        status = 200
        for line in raw_headers.decode().split("\r\n"):
            name, value = line.split(":", 1)
            if name.lower() == "status":
                status = int(value.strip().split(" ", 1)[0])
            else:
                headers[name] = value.strip()
        self.bytes_reply(response, status, headers)

    def lfs(self, path: str, owner: int) -> None:
        payload = decode_object(self.read_body())
        if path.endswith("/objects/batch"):
            operation = payload.get("operation")
            objects = payload.get("objects")
            if (
                operation not in {"upload", "download"}
                or not isinstance(objects, list)
                or len(objects) > 100
            ):
                return self.reply({"message": "Invalid LFS batch"}, 400)
            result: list[dict[str, object]] = []
            for raw in objects:
                value = object_dict(raw)
                oid, size = value.get("oid"), value.get("size")
                if (
                    not valid_oid(oid)
                    or not isinstance(oid, str)
                    or not isinstance(size, int)
                    or size < 0
                    or size > MAX_BODY
                ):
                    return self.reply({"message": "Invalid LFS object"}, 400)
                exists = (ROOT / "lfs" / oid).exists()
                action = {
                    "href": f"https://github-cloud.githubusercontent.com/lfs/{oid}?sig=synthetic-lfs-authority",
                    "header": {"Authorization": authority(owner).action},
                    "expires_in": 60,
                }
                actions: dict[str, object] = {}
                if operation == "download":
                    actions["download"] = action
                elif not exists:
                    actions["upload"] = action
                    actions["verify"] = {
                        "href": "https://github.com/owner/private.git/info/lfs/verify",
                        "header": {"Authorization": authority(owner).action},
                        "expires_in": 60,
                    }
                result.append({"oid": oid, "size": size, "actions": actions})
            return self.reply(
                {"transfer": "basic", "objects": result},
                headers={"Content-Type": "application/vnd.git-lfs+json"},
            )
        if path.endswith("/verify"):
            oid = payload.get("oid")
            return self.reply(
                {},
                200
                if isinstance(oid, str) and valid_oid(oid) and (ROOT / "lfs" / oid).exists()
                else 404,
            )
        self.reply({"message": "Unknown LFS action"}, 404)

    def storage(self, path: str, owner: int | None, credential: str) -> None:
        if credential in {"oauth", "invalid"}:
            return self.reply({"message": "Credential recipient refused"}, 403)
        if path == "/archive" and self.command in {"GET", "HEAD"}:
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as archive:
                archive.writestr("fixture.txt", "synthetic Actions artifact\n")
            return self.bytes_reply(
                output.getvalue(),
                headers={
                    "Content-Type": "application/zip",
                    "Set-Cookie": "synthetic-provider-cookie",
                },
            )
        oid = path.removeprefix("/lfs/")
        if owner is None or credential != "action" or not valid_oid(oid):
            return self.reply({"message": "Transfer authority refused"}, 403)
        target = ROOT / "lfs" / oid
        if self.command == "PUT":
            body = self.read_body()
            if hashlib.sha256(body).hexdigest() != oid:
                return self.reply({"message": "Object hash refused"}, 422)
            target.write_bytes(body)
            record({"event": "lfs_upload", "owner": owner, "bytes": len(body), "oid": oid})
            return self.bytes_reply(b"")
        if self.command in {"GET", "HEAD"} and target.exists():
            return self.bytes_reply(
                target.read_bytes(), headers={"Content-Type": "application/octet-stream"}
            )
        self.reply({"message": "Unknown transfer"}, 404)


def valid_oid(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def seed() -> None:
    bare = ROOT / "repositories" / "owner" / "private.git"
    bare.parent.mkdir(parents=True, exist_ok=True)
    (ROOT / "lfs").mkdir(exist_ok=True)
    work = ROOT / "seed"
    for command in [
        ["git", "init", "--bare", "--initial-branch=main", str(bare)],
        ["git", "config", "--file", str(bare / "config"), "http.receivepack", "true"],
        ["git", "init", "--initial-branch=main", str(work)],
    ]:
        subprocess.run(command, check=True, capture_output=True)
    (work / "README.md").write_text("Synthetic private GitHub fixture\n")
    for command in [
        ["git", "-C", str(work), "add", "README.md"],
        [
            "git",
            "-C",
            str(work),
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "commit",
            "-m",
            "initial",
        ],
        ["git", "-C", str(work), "push", str(bare), "main"],
    ]:
        subprocess.run(command, check=True, capture_output=True)


def main() -> None:
    ROOT.mkdir(exist_ok=True)
    seed()
    threading.Thread(target=connector, daemon=True).start()
    server = Server(("127.0.0.1", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
