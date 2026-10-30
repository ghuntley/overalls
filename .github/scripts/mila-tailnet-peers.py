"""Keep the tunnelled Mila fixture up while this run's journey nodes use it.

Polls `tailscale status --json` and returns once every named peer has been
seen online and has since gone offline or left the tailnet (ephemeral nodes
are removed when their job logs out). Peers never seen within the join
deadline are reported and not waited for; the overall deadline bounds the run.

usage: mila-tailnet-peers.py DEADLINE_SECONDS PEER [PEER ...]
"""

import json
import subprocess
import sys
import time

JOIN_SECONDS = 1800


def online_peers() -> dict[str, bool]:
    """Maps tailnet peer host names to their online state."""
    output = subprocess.run(
        ["tailscale", "status", "--json"], check=True, capture_output=True, text=True
    ).stdout
    status: object = json.loads(output)
    peers = status.get("Peer") if isinstance(status, dict) else None
    result: dict[str, bool] = {}
    if isinstance(peers, dict):
        for peer in peers.values():
            if isinstance(peer, dict):
                name = peer.get("HostName")
                online = peer.get("Online")
                if isinstance(name, str):
                    result[name] = online is True
    return result


def main() -> None:
    """@cc [owner:ghuntley,label:verification] mila-tailnet-peers-bounded
    The fixture job MUST stay up until every named journey peer has joined and
    left, and MUST return by the overall deadline or once no named peer joined
    within the join window, so a missing peer cannot hold the runner forever.
    """
    deadline_seconds = int(sys.argv[1])
    wanted = set(sys.argv[2:])
    started = time.monotonic()
    seen: set[str] = set()
    finished: set[str] = set()
    while time.monotonic() - started < deadline_seconds:
        peers = online_peers()
        for name in wanted - finished:
            if peers.get(name):
                seen.add(name)
            elif name in seen:
                finished.add(name)
                print(f"{name} finished with the fixture", flush=True)
        waiting = wanted - finished
        if not waiting:
            return
        if time.monotonic() - started > JOIN_SECONDS and not (waiting & seen):
            print(f"never joined: {' '.join(sorted(waiting))}", flush=True)
            return
        time.sleep(10)
    print("fixture deadline reached", flush=True)


if __name__ == "__main__":
    main()
