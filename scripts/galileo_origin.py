#!/usr/bin/env python3
"""Disposable guest origin for live Galileo acceptance; never echoes credentials."""

import argparse
import base64
import hashlib
import json
import select
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import TypedDict
from urllib.parse import urlsplit


class Observation(TypedDict):
    accepts: int
    closed: bool
    timed_out: bool


class Origin(ThreadingHTTPServer):
    def __init__(self, directory: Path, source: str, port: int) -> None:
        self.directory = directory
        self.source = source
        self.lock = threading.Lock()
        self.observations: dict[str, Observation] = {}
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        super().__init__(("0.0.0.0", port), Handler)

    def observe(self, case: str, *, accepted: bool = False, closed: bool = False) -> None:
        with self.lock:
            observation = self.observations.setdefault(
                case, {"accepts": 0, "closed": False, "timed_out": False}
            )
            if accepted:
                observation["accepts"] += 1
            observation["closed"] = closed
            temporary = self.directory / (case + ".tmp")
            temporary.write_text(json.dumps(observation))
            temporary.replace(self.directory / (case + ".json"))


class Handler(BaseHTTPRequestHandler):
    """@cc [owner:ghuntley,label:security;verification] galileo-origin-redacted-evidence
    The disposable origin MUST emit only credential comparison flags, public
    provenance, body length/digest and closed request counters. Request headers,
    bodies and peer tokens MUST NOT enter response bodies, logs or evidence.
    """

    protocol_version = "HTTP/1.1"

    @property
    def origin(self) -> Origin:
        """The serving Origin, narrowed from BaseServer at runtime."""
        server = self.server
        if not isinstance(server, Origin):
            raise TypeError("Handler must be served by Origin")
        return server

    def log_message(self, format: str, *args: object) -> None:
        pass

    def body(self) -> bytes:
        maximum = 2 * 1024 * 1024
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            chunks: list[bytes] = []
            total = 0
            while True:
                line = self.rfile.readline(128)
                if not line.endswith(b"\r\n"):
                    raise ValueError("Invalid chunk framing")
                size = int(line.split(b";", 1)[0], 16)
                if size == 0:
                    if self.rfile.readline(128) != b"\r\n":
                        raise ValueError("Unexpected trailers")
                    return b"".join(chunks)
                total += size
                if size < 0 or total > maximum:
                    raise ValueError("Body exceeds fixture limit")
                chunk = self.rfile.read(size)
                if len(chunk) != size or self.rfile.read(2) != b"\r\n":
                    raise ValueError("Incomplete chunk")
                chunks.append(chunk)
        size = int(self.headers.get("content-length", "0"))
        if not 0 <= size <= maximum:
            raise ValueError("Body exceeds fixture limit")
        body = self.rfile.read(size)
        if len(body) != size:
            raise ValueError("Incomplete body")
        return body

    def do_GET(self) -> None:
        path = urlsplit(self.path)
        case = path.path.strip("/")
        if case not in {"probe", "upload", "peer", "stall", "basic", "static"}:
            self.send_error(404)
            return
        try:
            body = self.body()
        except ValueError:
            self.send_error(400)
            return
        self.origin.observe(case, accepted=True)
        if case == "stall":
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                readable, _, _ = select.select([self.connection], [], [], 0.5)
                if readable:
                    try:
                        closed = self.connection.recv(1) == b""
                    except ConnectionError:
                        closed = True
                    if closed:
                        self.origin.observe(case, closed=True)
                        self.close_connection = True
                        return
            with self.origin.lock:
                self.origin.observations[case]["timed_out"] = True
            self.origin.observe(case)
            self.close_connection = True
            return

        basic = base64.b64encode(b"galileo:synthetic").decode()
        result = {
            "bearer": self.headers.get_all("authorization") == ["Bearer galileo-synthetic"],
            "basic": self.headers.get_all("authorization") == ["Basic " + basic],
            "static": self.headers.get_all("x-galileo-fixture") == ["galileo-synthetic"],
            "peer": self.headers.get_all("x-overalls-source-vm") == [self.origin.source],
            "authorization_absent": self.headers.get_all("authorization") is None,
            "path": case,
            "query_preserved": path.query == "probe=galileo",
            "bytes": len(body),
            "sha256": hashlib.sha256(body).hexdigest(),
            "method": self.command,
        }
        encoded = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    do_POST = do_GET
    do_PUT = do_GET


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("source")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    with Origin(args.directory, args.source, args.port) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
