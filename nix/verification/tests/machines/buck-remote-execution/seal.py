"""Seal the fixture buck-re identities for the VM's real host identity."""

import json
import socket
import subprocess
import sys
from pathlib import Path

fixtures = Path("/etc/fixtures")
host = socket.gethostname()
bundle = sys.argv[1]
documents: dict[str, dict[str, str]] = {
    "buck-re": {"SERVER_KEY": (fixtures / "server.key").read_text()},
    "buck-re-worker": {"WORKER_IDENTITY": (fixtures / f"worker-{host}.pem").read_text()},
}
recipient = subprocess.check_output(
    ["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"], text=True
).strip()
ciphertext = subprocess.check_output(
    [
        "sops",
        "--encrypt",
        "--age",
        recipient,
        "--input-type",
        "json",
        "--output-type",
        "json",
        "/dev/stdin",
    ],
    input=json.dumps({f"overalls-{bundle}": {"production": documents[bundle]}}).encode(),
)
root = Path("/run/fixture")
root.mkdir(mode=0o700, exist_ok=True)
(root / f"{bundle}.enc.json").write_bytes(ciphertext)
