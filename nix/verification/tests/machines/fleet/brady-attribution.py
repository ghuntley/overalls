"""Isolated native client for the production root/Brady attribution socket."""

import ipaddress
import json
import os
import pwd
import socket
import struct
import sys

# @cc [owner:ghuntley,label:verification;security] brady-fixture-native-peer
# Query the production endpoint as its configured Brady UID, verify the peer is
# the configured unprivileged Lilly service UID (ADR-0182, as Brady.Attribution
# requires), and emit only the closed identity. Never replace the kernel lookup
# or actor proof with fixture metadata.
source, source_port, destination, destination_port = sys.argv[1:]
source = ipaddress.IPv4Address(source)
destination = ipaddress.IPv4Address(destination)
source_port, destination_port = int(source_port), int(destination_port)
assert 1 <= source_port <= 65535 and 1 <= destination_port <= 65535
lilly_uid = int(os.environ["LILLY_SERVICE_UID"])
assert lilly_uid > 0
user = pwd.getpwnam("brady")
os.setgroups([])
os.setgid(user.pw_gid)
os.setuid(user.pw_uid)
request = struct.pack(
    "!B4sH4sH", 1, source.packed, source_port, destination.packed, destination_port
)
with socket.socket(socket.AF_UNIX) as client:
    client.settimeout(2)
    client.connect("/run/lilly-brady/attribution.sock")
    assert (
        struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
        == lilly_uid
    )
    client.sendall(struct.pack("!H", len(request)) + request)

    def receive(size: int) -> bytes:
        result = b""
        while len(result) < size:
            chunk = client.recv(size - len(result))
            assert chunk
            result += chunk
        return result

    size = struct.unpack("!H", receive(2))[0]
    assert size in (2, 162)
    body = receive(size)
    if body == b"\x01\x00":
        print(json.dumps({"attribution": "unresolved"}))
    else:
        assert body[:2] == b"\x01\x01" and len(body) == 162
        print(
            json.dumps(
                dict(
                    attribution="resolved",
                    host_id=body[2:38].decode("ascii"),
                    vm_id=body[38:74].decode("ascii"),
                    placement_id=body[74:110].decode("ascii"),
                    execution_epoch=int.from_bytes(body[110:118], "big"),
                    generation=int.from_bytes(body[118:126], "big"),
                    owner_id=body[126:162].decode("ascii"),
                )
            )
        )
