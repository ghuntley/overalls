"""Serve the tunnelled Mila fixture's descriptor until this run's journeys end.

The `journey-fixture-tailnet` job (ADR-0264) runs this after the fixture
has written its descriptor. It first checks, and fails fast otherwise, that
this node is tagged tag:mila-ci and that its packet filter admits the
fixture ports, then serves on BIND_ADDRESS:8445:

- GET /descriptor.json: the descriptor (tag:mila-ci peers only, by policy).
- POST /finished/<peer>/<outcome>: a journey job's explicit result, where
  <peer> is one of PEER and <outcome> is success, failure, cancelled or
  skipped.

A peer has ended when it reports a result, when it was seen and then left the
tailnet (ephemeral nodes are removed at logout), or when it never joined
within the join window. Only an explicit `success` report counts as finished.
The server stops once every peer has ended, or at the deadline. It never
prints the descriptor, and it names only `mila-*` nodes because the
repository's logs are public.

usage: mila-tailnet-peers.py --bind ADDRESS --directory DIR --deadline SECONDS PEER [PEER ...]
"""

import argparse
import json
import subprocess
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TAG = "tag:mila-ci"
PORT = 8445
FIXTURE_PORTS = (8443, 2222, 8444, 8445)
JOIN_SECONDS = 1800
POLL_SECONDS = 10
DIAGNOSTIC_SECONDS = 60
OUTCOMES = frozenset({"success", "failure", "cancelled", "skipped"})
POLICY_HINT = (
    "the tailnet policy must grant tag:mila-ci -> tag:mila-ci on "
    "tcp:8443, tcp:2222, tcp:8444 and tcp:8445 (ADR-0264, Tailnet configuration)"
)


@dataclass
class PeerState:
    """What the fixture knows about one journey job's tailnet node."""

    seen: bool = False
    missing_polls: int = 0
    reported: str | None = None
    ended: str | None = None


class Results:
    """Explicit results reported by the journey jobs, shared with the server thread."""

    def __init__(self, peers: list[str]) -> None:
        self._lock = threading.Lock()
        self._allowed = frozenset(peers)
        self._results: dict[str, str] = {}

    def report(self, peer: str, outcome: str) -> bool:
        if peer not in self._allowed or outcome not in OUTCOMES:
            return False
        with self._lock:
            self._results.setdefault(peer, outcome)
        return True

    def get(self, peer: str) -> str | None:
        with self._lock:
            return self._results.get(peer)


def handler(descriptor: Path, results: Results) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            """Request lines are not logged; results are printed by the watcher."""

        def do_GET(self) -> None:
            if self.path != "/descriptor.json":
                self.send_error(404)
                return
            body = descriptor.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self) -> None:
            parts = self.path.split("/")
            if len(parts) == 4 and parts[1] == "finished" and results.report(parts[2], parts[3]):
                self.send_response(204)
                self.end_headers()
                return
            self.send_error(404)

    return Handler


def tailscale_json(arguments: list[str]) -> object | None:
    for command in (["tailscale", *arguments], ["sudo", "-n", "tailscale", *arguments]):
        try:
            completed = subprocess.run(
                command, capture_output=True, text=True, timeout=30, check=False
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if completed.returncode == 0:
            try:
                return json.loads(completed.stdout)
            except json.JSONDecodeError:
                continue
    return None


def node_name(node: dict[object, object]) -> str:
    host = node.get("HostName")
    if isinstance(host, str) and host:
        return host
    dns = node.get("DNSName")
    return dns.split(".")[0] if isinstance(dns, str) else ""


def mila_peers() -> dict[str, bool] | None:
    """Online state of the `mila-*` peers, or None when status is unreadable."""
    status = tailscale_json(["status", "--json"])
    if not isinstance(status, dict):
        return None
    peers = status.get("Peer")
    result: dict[str, bool] = {}
    if isinstance(peers, dict):
        for node in peers.values():
            if isinstance(node, dict):
                name = node_name(node)
                if name.startswith("mila-"):
                    result[name] = node.get("Online") is True
    return result


def port_ranges(value: object) -> list[tuple[int, int]]:
    """Every {First, Last} port range anywhere in a netmap document."""
    found: list[tuple[int, int]] = []
    if isinstance(value, dict):
        first, last = value.get("First"), value.get("Last")
        if isinstance(first, int) and isinstance(last, int):
            found.append((first, last))
        for item in value.values():
            found.extend(port_ranges(item))
    elif isinstance(value, list):
        for item in value:
            found.extend(port_ranges(item))
    return found


def check_policy() -> None:
    """@cc [owner:ghuntley,label:verification;security] mila-tailnet-policy-fail-fast
    The fixture MUST stop with a clear message when its node lacks tag:mila-ci or
    its packet filter admits none of the fixture ports, instead of waiting for
    peers that cannot connect. An unreadable netmap MUST only warn.
    """
    status = tailscale_json(["status", "--json"])
    me = status.get("Self") if isinstance(status, dict) else None
    tags = me.get("Tags") if isinstance(me, dict) else None
    if not isinstance(tags, list) or TAG not in tags:
        raise SystemExit(
            f"this fixture node is not tagged {TAG}: create the auth key with that tag; "
            + POLICY_HINT
        )
    netmap = tailscale_json(["debug", "netmap"])
    if not isinstance(netmap, dict) or not any(
        key in netmap for key in ("PacketFilter", "PacketFilterRules")
    ):
        print("warning: netmap unreadable; tailnet policy not checked", flush=True)
        return
    ranges = port_ranges({key: netmap.get(key) for key in ("PacketFilter", "PacketFilterRules")})
    missing = [port for port in FIXTURE_PORTS if not any(a <= port <= b for a, b in ranges)]
    if missing:
        raise SystemExit(
            "this fixture's packet filter admits no peer on "
            + ", ".join(f"tcp:{port}" for port in missing)
            + "; "
            + POLICY_HINT
        )
    print("tailnet policy admits the fixture ports on this node", flush=True)


def serve(address: str, descriptor: Path, results: Results) -> ThreadingHTTPServer:
    try:
        server = ThreadingHTTPServer((address, PORT), handler(descriptor, results))
    except OSError as error:
        raise SystemExit(f"cannot serve the descriptor on {address}:{PORT}: {error}") from error
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with urllib.request.urlopen(
            f"http://{address}:{PORT}/descriptor.json", timeout=10
        ) as reply:
            reply.read()
    except OSError as error:
        raise SystemExit(
            f"descriptor server on {address}:{PORT} failed its self-check: {error}"
        ) from error
    print(f"serving the descriptor on {address}:{PORT}", flush=True)
    return server


def watch(peers: list[str], results: Results, deadline: int) -> None:
    """@cc [owner:ghuntley,label:verification] mila-tailnet-peers-bounded
    The fixture MUST stay up until every named journey peer has ended (reported a
    result, left the tailnet after joining, or never joined within the join
    window) and MUST return by the overall deadline. Only an explicit success
    report counts as finished.
    """
    started = time.monotonic()
    states = {peer: PeerState() for peer in peers}
    last_diagnostic = 0.0
    while time.monotonic() - started < deadline:
        online = mila_peers()
        for peer, state in states.items():
            if state.ended:
                continue
            reported = results.get(peer)
            if reported:
                state.reported = state.ended = reported
                verdict = "finished" if reported == "success" else "ended"
                print(f"{peer} {verdict}: reported {reported}", flush=True)
                continue
            if online is None:
                continue
            if online.get(peer):
                state.seen, state.missing_polls = True, 0
            elif state.seen:
                state.missing_polls += 1
                if state.missing_polls >= 2:
                    state.ended = "left without reporting"
                    print(f"{peer} ended: left the tailnet without reporting a result", flush=True)
            elif time.monotonic() - started > JOIN_SECONDS:
                state.ended = "never joined"
                print(f"{peer} ended: never joined the tailnet", flush=True)
        if all(state.ended for state in states.values()):
            break
        if time.monotonic() - last_diagnostic >= DIAGNOSTIC_SECONDS:
            last_diagnostic = time.monotonic()
            shown = (
                "unreadable"
                if online is None
                else (
                    ", ".join(
                        f"{name}={'online' if up else 'offline'}"
                        for name, up in sorted(online.items())
                    )
                    or "none"
                )
            )
            print(f"--- {time.strftime('%H:%M:%S')} mila peers: {shown}", flush=True)
        time.sleep(POLL_SECONDS)
    else:
        print("fixture deadline reached", flush=True)
    finished = [peer for peer, state in states.items() if state.ended == "success"]
    print(f"journeys finished successfully: {len(finished)} of {len(peers)}", flush=True)
    for peer, state in states.items():
        print(f"  {peer}: {state.ended or 'still running at the deadline'}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--deadline", required=True, type=int)
    parser.add_argument("peers", nargs="+")
    arguments = parser.parse_args()
    bind: str = arguments.bind
    directory: Path = arguments.directory
    deadline: int = arguments.deadline
    peers: list[str] = arguments.peers
    descriptor = directory / "descriptor.json"
    if not descriptor.is_file():
        raise SystemExit(f"{descriptor} is missing")
    check_policy()
    results = Results(peers)
    server = serve(bind, descriptor, results)
    try:
        watch(peers, results, deadline)
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
