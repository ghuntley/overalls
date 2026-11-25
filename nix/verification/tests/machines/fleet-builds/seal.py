"""Seal the fixture fleet-build keys for the VM's real host identity."""

import json
import socket
import subprocess
from pathlib import Path

fixtures = Path("/etc/fixtures")
host = socket.gethostname()
values: dict[str, str] = {
    "GRPC_KEY": (fixtures / f"grpc-{host}.key").read_text(),
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
    input=json.dumps({"overalls-fleet-builds": {"production": values}}).encode(),
)
root = Path("/run/fixture")
root.mkdir(mode=0o700, exist_ok=True)
(root / "keys.enc.json").write_bytes(ciphertext)
