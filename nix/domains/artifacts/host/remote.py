"""Read-only hardware checks and durable enrollment receipts on the SSH target."""

import fcntl
import hashlib
import ipaddress
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Literal, TypedDict


class BlockDevice(TypedDict):
    """One lsblk node; optional columns may be absent or null."""

    name: str
    path: str
    type: str
    size: int
    serial: str | None
    model: str | None
    tran: str | None
    mountpoints: list[object] | None
    holders: list[object] | None
    children: list["BlockDevice"] | None


class Disk(TypedDict):
    id: str
    device: str
    aliases: list[str]
    path: str
    serial: str
    model: str
    transport: str
    size: int
    kind: str
    active: bool


class Inventory(TypedDict):
    arch: str
    machine: str
    disks: list[Disk]


class Identity(TypedDict):
    hostId: str
    sshKeys: list[str]


class Declaration(TypedDict):
    platform: str
    firmware: str
    identity: Identity
    inventory: Inventory
    storage: dict[str, object]
    git: dict[str, str]


class Binding(TypedDict):
    platform: str
    firmware: str
    storage: dict[str, object]
    identity: dict[str, object]


class StorageFacts(TypedDict):
    machine: str
    hostKey: str
    poolGuid: str
    datasetGuid: str
    binding: Binding


class AddrInfo(TypedDict):
    local: str
    prefixlen: int
    scope: str


class Address(TypedDict):
    ifname: str
    address: str | None
    addr_info: list[AddrInfo]


class Uplink(TypedDict):
    """Live uplink facts for the recovery copy; the values stay off the repository."""

    addresses: list[str]
    gateway: str
    routes: list[str]


UPLINK_RECOVERY = Path("/mnt/var/lib/overalls-host/uplink.conf")
BASE_SOURCE = Path("/mnt/var/lib/overalls-host/base-source")


class Facts(TypedDict):
    inventory: Inventory
    firmware: str
    addresses: list[Address]
    routes: list[dict[str, object]]
    hostKey: str


def run(args: list[str]) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=60).strip()


def public_key(path: str) -> str:
    return " ".join(run(["ssh-keygen", "-y", "-f", path]).split()[:2])


def kvm() -> None:
    with open("/dev/kvm", "rb") as device:
        if fcntl.ioctl(device, 0xAE00, 0) != 12:
            raise ValueError("unsupported KVM API")
        vm = fcntl.ioctl(device, 0xAE01, 0)
        os.close(vm)


def guest_platform(host: Declaration) -> bool:
    """@cc [owner:ghuntley,label:deployment;security] hcloud-no-kvm-no-lilly
    Hetzner Cloud hosts MUST NOT require KVM and MUST bind their ZFS root
    dataset instead of a Lilly guest dataset. Every other platform keeps both.
    """
    return host["platform"] != "hcloud"


def active(node: BlockDevice) -> bool:
    return (
        bool(any(node.get("mountpoints") or []))
        or bool(node.get("holders"))
        or any(active(n) for n in node.get("children") or [])
    )


def host_storage(node: BlockDevice) -> bool:
    """@cc [owner:ghuntley,label:security;deployment] virtual-block-device-exclusion
    Floppy controllers and kernel NBD endpoints MUST NOT enter persistent host
    inventory. Every other whole disk MUST undergo stable identity validation.
    """
    return node["type"] == "disk" and not re.fullmatch(r"(?:fd|nbd)[0-9]+", node["name"])


def classify(model: str, serial: str, transport: str) -> Literal["ebs", "local-nvme", "physical"]:
    if model == "Amazon Elastic Block Store" and serial.replace("-", "").startswith("vol"):
        return "ebs"
    if (
        model == "Amazon EC2 NVMe Instance Storage"
        and transport == "nvme"
        and not serial.replace("-", "").startswith("vol")
    ):
        return "local-nvme"
    if model.startswith("Amazon"):
        raise ValueError("ambiguous Amazon controller identity")
    return "physical"


def inventory(require_zfs: bool = False) -> Inventory:
    nodes: list[BlockDevice] = json.loads(
        run(
            [
                "lsblk",
                "--json",
                "--bytes",
                "--output",
                "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS",
            ]
        )
    )["blockdevices"]
    disks: list[Disk] = []
    try:
        imported = run(["zpool", "status", "-LP"])
    except (OSError, subprocess.CalledProcessError):
        if require_zfs:
            raise ValueError("cannot inspect imported pools") from None
        imported = ""
    for node in nodes:
        # Linux reports empty legacy floppy controllers and kernel NBD devices
        # as disks. Neither is installable host storage: NBD devices are
        # runtime-created virtual endpoints and may expose active workload
        # pools. Every other whole disk still requires stable identity.
        if not host_storage(node):
            continue
        path = node["path"]
        serial = (node.get("serial") or "").strip()
        model = (node.get("model") or "").strip()
        transport = node.get("tran") or "unknown"
        aliases = sorted(
            str(p) for p in Path("/dev/disk/by-id").glob("*") if str(p.resolve()) == path
        )
        if not serial or not aliases:
            raise ValueError("disk has no stable serial or by-id path")
        kind = classify(model, serial, transport)
        identity = hashlib.sha256((model + "\0" + serial).encode()).hexdigest()[:24]
        # Holders include dm/MD/ZFS consumers that may have no mountpoint.
        holders = list(Path("/sys/class/block", node["name"], "holders").iterdir())
        for child in Path("/sys/class/block", node["name"]).glob(node["name"] + "*"):
            holders += list((child / "holders").glob("*"))
        disks.append(
            {
                "id": "disk-" + identity,
                "device": aliases[0],
                "aliases": aliases,
                "path": path,
                "serial": serial,
                "model": model,
                "transport": transport,
                "size": node["size"],
                "kind": kind,
                "active": active(node)
                or bool(holders)
                or path in imported
                or any(a in imported for a in aliases),
            }
        )
    if len({d["id"] for d in disks}) != len(disks):
        raise ValueError("duplicate disk identity")
    return {
        "arch": platform.machine(),
        "machine": Path("/sys/class/dmi/id/product_uuid").read_text().strip().lower(),
        "disks": sorted(disks, key=lambda d: d["id"]),
    }


def firmware() -> str:
    return "uefi" if Path("/sys/firmware/efi").exists() else "bios"


def discover() -> Facts:
    return {
        "inventory": inventory(),
        "firmware": firmware(),
        "addresses": json.loads(run(["ip", "-json", "address"])),
        "routes": json.loads(run(["ip", "-json", "route", "show", "table", "all"])),
        "hostKey": public_key("/etc/ssh/ssh_host_ed25519_key"),
    }


def match(expected: Inventory, observed: Inventory, erase: bool = False) -> None:
    """@cc [owner:ghuntley,label:security] complete-stable-disk-comparison
    Reordered kernel device names MAY match; missing, added, resized or replaced
    disks MUST fail. Erasure MUST reject active devices and changed by-id aliases.
    """
    if (expected["arch"], expected["machine"]) != (observed["arch"], observed["machine"]):
        raise ValueError("target hardware changed")
    old = {d["id"]: d for d in expected["disks"]}
    new = {d["id"]: d for d in observed["disks"]}
    if (
        len(old) != len(expected["disks"])
        or len(new) != len(observed["disks"])
        or old.keys() != new.keys()
    ):
        raise ValueError("disk membership changed")
    for identity, d in old.items():
        current = new[identity]
        if any(d[k] != current[k] for k in ("serial", "model", "transport", "size", "kind")):
            raise ValueError("disk identity changed")
        if d["device"] not in current["aliases"]:
            raise ValueError("reviewed disk path changed")
        if erase and current["active"]:
            raise ValueError("active target disk")


def storage(host: Declaration, root: str = "", binding: Binding | None = None) -> StorageFacts:
    current = inventory(require_zfs=True)
    match(host["inventory"], current)
    if firmware() != host["firmware"]:
        raise ValueError("firmware changed")
    guests = guest_platform(host)
    if guests:
        kvm()
    if host["platform"] == "ec2" and run(["findmnt", "-n", "-o", "FSTYPE", root or "/"]) != "ext4":
        raise ValueError("EC2 system storage is not ext4")
    pool = "guests" if host["platform"] == "ec2" else "zroot"
    dataset = pool + ("/lilly" if guests else "/root")
    mount = root + "/var/lib/lilly/pool" if guests else root or "/"
    if run(["zfs", "get", "-H", "-o", "value", "mounted", dataset]) != "yes":
        raise ValueError("bound dataset not mounted")
    if run(["findmnt", "-n", "-o", "SOURCE", mount]) != dataset:
        raise ValueError("bound mount identity differs")
    for key, value in (("compression", "lz4"), ("reservation", "0"), ("refreservation", "0")):
        if run(["zfs", "get", "-Hp", "-o", "value", key, dataset]) != value:
            raise ValueError("guest storage policy differs")
    expected_quota = (
        str(host["storage"]["quotaBytes"]) if host["platform"] in ("hetzner", "metal") else "0"
    )
    if run(["zfs", "get", "-Hp", "-o", "value", "quota", dataset]) != expected_quota:
        raise ValueError("guest quota differs")
    return {
        "machine": current["machine"],
        "hostKey": public_key(root + "/etc/ssh/ssh_host_ed25519_key"),
        "poolGuid": run(["zpool", "get", "-Hp", "-o", "value", "guid", pool]),
        "datasetGuid": run(["zfs", "get", "-Hp", "-o", "value", "guid", dataset]),
        "binding": binding
        if binding is not None
        else json.loads(Path("/etc/overalls-installation.json").read_text()),
    }


def atomic(path: Path, value: object) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    with open(temp, "w", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    os.fsync(fd)
    os.close(fd)


def uplink_drop_in(uplink: Uplink) -> str:
    """Render the networkd drop-in exactly as overalls-fleet-uplink does.

    The host-planning check compares this with fleet-addresses.py, so a base
    system booting without the SOPS document gets the same addressing.
    """
    interfaces = [ipaddress.IPv4Interface(address) for address in uplink["addresses"]]
    gateway = ipaddress.IPv4Address(uplink["gateway"])
    routes = [ipaddress.IPv4Address(route) for route in uplink["routes"]]
    if not interfaces or any(i.network != interfaces[0].network for i in interfaces):
        raise ValueError("uplink addresses must share one on-link network")
    if gateway not in interfaces[0].network:
        raise ValueError("uplink gateway must be on-link")
    lines = ["[Network]", *(f"Address={i.with_prefixlen}" for i in interfaces), ""]
    lines += ["[Route]", f"Destination={gateway}/32", "Scope=link", ""]
    lines += ["[Route]", f"Gateway={gateway}", "GatewayOnLink=yes", ""]
    for destination in [str(interfaces[0].network), *(f"{route}/32" for route in routes)]:
        lines += [
            "[Route]",
            f"Destination={destination}",
            f"Gateway={gateway}",
            "GatewayOnLink=yes",
            "",
        ]
    return "\n".join(lines)


def install_uplink(uplink: Uplink) -> dict[str, int]:
    text = uplink_drop_in(uplink)
    if UPLINK_RECOVERY.exists():
        raise ValueError("uplink recovery copy already exists")
    UPLINK_RECOVERY.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = UPLINK_RECOVERY.with_suffix(".tmp")
    with open(temp, "w", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, UPLINK_RECOVERY)
    # Only counts are reported; the addresses never reach operator output.
    return {"addresses": len(uplink["addresses"]), "routes": len(uplink["routes"])}


def install_base_source() -> dict[str, int]:
    """Record the authenticated installing operator's source for the base system.

    A base system has no fleet-address document, so its perimeter would admit
    nobody but Tailscale. This root-only file lets that one source reach the
    administrative SSH port until enrollment delivers the reviewed sources.
    """
    fields = os.environ.get("SSH_CONNECTION", "").split()
    if len(fields) != 4:
        raise ValueError("installer connection source unavailable")
    source = ipaddress.IPv4Address(fields[0])
    if source.is_unspecified or source.is_loopback or source.is_multicast or source.is_link_local:
        raise ValueError("installer connection source is not an explicit unicast IPv4 address")
    if BASE_SOURCE.exists():
        raise ValueError("base source already exists")
    BASE_SOURCE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = BASE_SOURCE.with_suffix(".tmp")
    with open(temp, "w", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        stream.write(f"{source}\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, BASE_SOURCE)
    # The address never reaches operator output.
    return {"sources": 1}


def verify(host: Declaration, receipt: bool = False) -> StorageFacts:
    observed = storage(host)
    baseline = Path("/var/lib/overalls-host/storage.json")
    if not baseline.exists():
        raise ValueError("missing installation storage baseline")
    prior = json.loads(baseline.read_text())

    def normalize(value: object) -> object:
        value = json.loads(json.dumps(value))
        if "binding" in value:
            value["binding"]["identity"].pop("sshKeys", None)
        return value

    if normalize(prior) != normalize(observed):
        raise ValueError("storage or identity requires explicit reconciliation")
    keys = host["identity"]["sshKeys"]
    if keys and observed["hostKey"] not in [" ".join(k.split()[:2]) for k in keys]:
        raise ValueError("published identity differs")
    if receipt:
        enrolled = json.loads(Path("/var/lib/overalls-host/enrollment.json").read_text())
        if enrolled["storage"] != observed:
            raise ValueError("enrollment receipt no longer matches")
        run(["systemctl", "is-active", "overalls-secrets-git.service"])
        run(["systemctl", "is-active", "overalls-auto-update.timer"])
        environment = dict(
            os.environ,
            GIT_SSH_COMMAND="ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/overalls-git-known-hosts -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i /run/overalls-secrets/git/deploy-key",
        )
        subprocess.run(
            ["git", "ls-remote", "--exit-code", host["git"]["repository"], "refs/heads/trunk"],
            env=environment,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=120,
        )
    settings = run(["sshd", "-T"]).lower().splitlines()
    if not all(
        s in settings
        for s in [
            "permitrootlogin no",
            "passwordauthentication no",
            "kbdinteractiveauthentication no",
        ]
    ):
        raise ValueError("installed SSH access policy differs")
    return observed


def main() -> None:
    action: str = sys.argv[1]
    result: object
    if action == "discover":
        result = discover()
    elif action == "guard":
        host = json.load(sys.stdin)
        match(host["inventory"], inventory(require_zfs=True), erase=True)
        if host["firmware"] != firmware():
            raise ValueError("firmware changed")
        if guest_platform(host):
            kvm()
        result = {"safe": True}
    elif action == "verify":
        host = json.loads(Path(sys.argv[2]).read_text())
        result = verify(host, receipt="--receipt" in sys.argv)
    elif action == "install-baseline":
        payload = json.load(sys.stdin)
        result = storage(payload["host"], root="/mnt", binding=payload["binding"])
        path = Path("/mnt/var/lib/overalls-host/storage.json")
        if path.exists():
            raise ValueError("installation baseline already exists")
        atomic(path, result)
    elif action == "install-uplink":
        result = install_uplink(json.load(sys.stdin))
    elif action == "install-base-source":
        result = install_base_source()
    else:
        raise ValueError("unknown operation")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        OSError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        KeyError,
    ):
        sys.exit("Host check failed: hardware, identity, storage or receipt mismatch")
