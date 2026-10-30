"""Seal the fixture buck-re identities for the VM's real host identity."""

import json
import socket
import subprocess
from pathlib import Path

fixtures = Path("/etc/fixtures")
host = socket.gethostname()
values: dict[str, str] = (
    {"SERVER_KEY": (fixtures / "server.key").read_text()}
    if host == "cache"
    else {"CLIENT_IDENTITY": (fixtures / "reader-host.pem").read_text()}
)
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
    input=json.dumps({"overalls-buck-re": {"production": values}}).encode(),
)
root = Path("/run/fixture")
root.mkdir(mode=0o700, exist_ok=True)
(root / "buck-re.enc.json").write_bytes(ciphertext)
