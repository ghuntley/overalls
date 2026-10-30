"""Find this run's tunnelled Mila fixture on the tailnet and fetch its descriptor.

A macOS or Windows journey job runs this after joining the tailnet
(ADR-0264). It resolves `mila-fixture-<run>-<attempt>` from
`tailscale status --json` (Peer[].HostName -> TailscaleIPs), downloads
`http://<fixture>:8445/descriptor.json` to DESCRIPTOR_PATH (owner-only) and
writes the fixture's tailnet address to ADDRESS_PATH. Every minute it prints
a diagnostic: this node's state and tags, the run's `mila-*` peers, the
resolution result, and the last curl exit code and stderr. It never prints
the descriptor, whose approver bearer is secret, and it names only `mila-*`
nodes because the repository's logs are public.

usage: mila-tailnet-join.py DESCRIPTOR_PATH ADDRESS_PATH
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field

TAG = "tag:mila-ci"
PORT = 8445
WAIT_SECONDS = 3600
DIAGNOSTIC_SECONDS = 60
POLICY_HINT = (
    "the tailnet policy must grant tag:mila-ci -> tag:mila-ci on "
    "tcp:8443, tcp:2222, tcp:8444 and tcp:8445 (ADR-0264, Tailnet configuration)"
)


@dataclass(frozen=True)
class Peer:
    """A `mila-*` tailnet node as `tailscale status --json` reports it."""

    name: str
    online: bool
    ipv4: str | None


@dataclass
class Status:
    """The parts of `tailscale status --json` the journey needs."""

    backend: str = "unknown"
    self_tags: list[str] = field(default_factory=list)
    self_ipv4: str | None = None
    peers: list[Peer] = field(default_factory=list)
    other_peers: int = 0
    error: str | None = None


def ipv4_of(addresses: object) -> str | None:
    if isinstance(addresses, list):
        for address in addresses:
            if isinstance(address, str) and "." in address:
                return address
    return None


def node_name(node: dict[object, object]) -> str:
    """HostName, falling back to the first MagicDNS label."""
    host = node.get("HostName")
    if isinstance(host, str) and host:
        return host
    dns = node.get("DNSName")
    return dns.split(".")[0] if isinstance(dns, str) else ""


def tailscale(arguments: list[str]) -> tuple[int, str, str]:
    """Runs the CLI, retrying under `sudo -n` where the daemon socket is root-only."""
    result: tuple[int, str, str] = (-1, "", "tailscale not run")
    for command in (["tailscale", *arguments], ["sudo", "-n", "tailscale", *arguments]):
        try:
            completed = subprocess.run(
                command, capture_output=True, text=True, timeout=30, check=False
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            if command[0] == "tailscale":
                result = (-1, "", f"{type(error).__name__}: {error}")
            continue
        if completed.returncode == 0 or command[0] == "tailscale":
            result = (completed.returncode, completed.stdout, completed.stderr.strip())
        if completed.returncode == 0:
            break
    return result


def read_status() -> Status:
    code, stdout, stderr = tailscale(["status", "--json"])
    if code != 0:
        return Status(error=f"tailscale status exit {code}: {stderr}")
    try:
        document: object = json.loads(stdout)
    except json.JSONDecodeError as error:
        return Status(error=f"tailscale status JSON invalid: {error}")
    status = Status()
    if not isinstance(document, dict):
        status.error = "tailscale status JSON is not an object"
        return status
    backend = document.get("BackendState")
    status.backend = backend if isinstance(backend, str) else "unknown"
    me = document.get("Self")
    if isinstance(me, dict):
        tags = me.get("Tags")
        status.self_tags = [t for t in tags if isinstance(t, str)] if isinstance(tags, list) else []
        status.self_ipv4 = ipv4_of(me.get("TailscaleIPs"))
    peers = document.get("Peer")
    if isinstance(peers, dict):
        for node in peers.values():
            if not isinstance(node, dict):
                continue
            name = node_name(node)
            if name.startswith("mila-"):
                online = node.get("Online") is True
                status.peers.append(Peer(name, online, ipv4_of(node.get("TailscaleIPs"))))
            else:
                status.other_peers += 1
    return status


def fetch(address: str, target: str) -> tuple[int, str]:
    """curl the descriptor; returns curl's exit code and stderr."""
    try:
        completed = subprocess.run(
            [
                "curl",
                "-sS",
                "--fail",
                "--max-time",
                "10",
                "-o",
                target,
                f"http://{address}:{PORT}/descriptor.json",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return -1, f"{type(error).__name__}: {error}"
    return completed.returncode, completed.stderr.strip()


def ping(address: str) -> str:
    """One disco ping: it succeeds without any packet-filter grant."""
    code, stdout, stderr = tailscale(["ping", "-c", "1", "--timeout", "5s", address])
    output = (stdout + "\n" + stderr).strip().splitlines()
    return f"exit {code}: {output[-1] if output else ''}"


def diagnose(
    fixture: str, status: Status, curl: tuple[int, str] | None, pinged: str | None
) -> None:
    print(f"--- tailnet diagnostic ({time.strftime('%H:%M:%S')})", flush=True)
    if status.error:
        print(f"  status: {status.error}", flush=True)
    print(
        f"  self: backend={status.backend} tags={','.join(status.self_tags) or 'none'} "
        f"ipv4={status.self_ipv4}",
        flush=True,
    )
    for peer in status.peers:
        print(f"  peer {peer.name}: online={peer.online} ipv4={peer.ipv4}", flush=True)
    print(f"  other peers: {status.other_peers}", flush=True)
    match = [peer for peer in status.peers if peer.name == fixture]
    print(f"  resolve {fixture}: {match[0].ipv4 if match else 'not in netmap'}", flush=True)
    if curl is not None:
        print(f"  curl descriptor: exit {curl[0]} {curl[1]}", flush=True)
    if pinged is not None:
        print(f"  tailscale ping: {pinged}", flush=True)
        if curl is not None and curl[0] == 28 and pinged.startswith("exit 0"):
            print(f"  hint: the path works but TCP {PORT} times out; {POLICY_HINT}", flush=True)


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] mila-tailnet-join-diagnosed
    The client MUST resolve the fixture from `tailscale status --json`, MUST print
    a diagnostic (node state, `mila-*` peers, resolution, curl exit code and
    stderr) at least every minute while waiting, MUST fail fast when this node
    lacks tag:mila-ci, and MUST NOT print the descriptor or non-`mila-*` nodes.
    """
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    descriptor, address_path = sys.argv[1], sys.argv[2]
    # A step timeout sends SIGTERM; unwind so the partial download is removed.
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(143))
    fixture = f"mila-fixture-{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}"
    started = time.monotonic()
    last_diagnostic = -DIAGNOSTIC_SECONDS
    directory = os.path.dirname(os.path.abspath(descriptor))
    handle, partial = tempfile.mkstemp(dir=directory, prefix=".descriptor.")
    os.close(handle)
    try:
        while time.monotonic() - started < WAIT_SECONDS:
            status = read_status()
            if not status.error and status.backend == "Running" and TAG not in status.self_tags:
                diagnose(fixture, status, None, None)
                raise SystemExit(
                    f"this node is not tagged {TAG}: create the auth key with that tag, "
                    f"or the grant cannot apply; {POLICY_HINT}"
                )
            match = [peer for peer in status.peers if peer.name == fixture and peer.ipv4]
            curl: tuple[int, str] | None = None
            pinged: str | None = None
            if match and match[0].online:
                address = match[0].ipv4
                assert address is not None
                curl = fetch(address, partial)
                if curl[0] == 0:
                    os.chmod(partial, 0o600)
                    os.replace(partial, descriptor)
                    with open(address_path, "w", encoding="utf-8") as out:
                        out.write(address)
                    print(f"fetched the descriptor from {fixture} ({address})", flush=True)
                    return
                if time.monotonic() - last_diagnostic >= DIAGNOSTIC_SECONDS:
                    pinged = ping(address)
            if time.monotonic() - last_diagnostic >= DIAGNOSTIC_SECONDS:
                diagnose(fixture, status, curl, pinged)
                last_diagnostic = time.monotonic()
            time.sleep(5)
        raise SystemExit(
            f"tunnelled fixture {fixture} did not serve a descriptor within 60 minutes"
        )
    finally:
        if os.path.exists(partial):
            os.unlink(partial)


if __name__ == "__main__":
    main()
