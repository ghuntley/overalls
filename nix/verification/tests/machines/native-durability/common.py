"""Shared native durability host preparation; composed before one scenario fragment."""

import shlex
import time

from test_driver.machine import QemuMachine as Node

IMAGE = "/etc/overalls-native-image"
TOOLS = "/etc/native-durability-tools"


def prepare(machine: Node) -> None:
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -c /dev/kvm")
    machine.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
    machine.succeed("ip tuntap add native0 mode tap")
    machine.succeed("ip link set native0 up")
    machine.succeed("ip address add 10.10.0.1/32 dev native0")
    machine.succeed("ip route add 10.10.0.203/32 dev native0 src 10.10.0.1")
    machine.succeed("ip address add 169.254.254.1/32 dev lo")
    machine.succeed("ip address add 1.1.1.1/32 dev lo")


def pool(machine: Node, device: str, *, image: bool = True) -> None:
    """Create a production-shaped per-guest dataset holding a regular disk file."""
    machine.succeed(
        "zpool create -f -o cachefile=none -O compression=lz4 -O mountpoint=none "
        f"tank {shlex.quote(device)}"
    )
    if image:
        machine.succeed("zfs create -o mountpoint=/vms tank/vm")
        machine.succeed(f"cp --sparse=always {IMAGE}/disk.raw /vms/rootfs.raw")
        machine.succeed("chmod 0600 /vms/rootfs.raw && zpool sync tank")


GUEST_SMF_LOGS = (
    "site-overalls-native-growth:default.log",
    "site-overalls-native-bootstrap:default.log",
    "site-overalls-native-agents:default.log",
)


def guest_growth_log(machine: Node, disk: str) -> None:
    """Failure-only diagnostic: read the stopped guest's boot-chain SMF logs read-only.

    The candidate root dataset has a legacy mountpoint, so it is mounted with
    plain `mount -t zfs`; the `zfsutil` option is refused for legacy datasets.
    """
    tails = "".join(
        f"echo '--- {name}'; tail -n 80 '/mnt/guest/var/svc/log/{name}'; "
        for name in GUEST_SMF_LOGS
    )
    status, output = machine.execute(
        f"loop=$(losetup -fP --show -r {shlex.quote(disk)}) && "
        'zpool import -f -N -o readonly=on -d "${loop}p2" overalls_native_candidate && '
        "mkdir -p /mnt/guest && mount -t zfs -o ro "
        "overalls_native_candidate/ROOT/overalls-native-candidate /mnt/guest && "
        f"{{ {tails}}}; "
        "umount /mnt/guest; zpool export overalls_native_candidate; "
        'losetup -d "$loop"',
        timeout=120,
    )
    print(f"native durability guest growth log status={status}\n{output}", flush=True)


def run(
    machine: Node,
    phase: str,
    work: str,
    extra: str = "",
    timeout: int = 2000,
    disk: str = "/vms/rootfs.raw",
) -> None:
    started = time.monotonic()
    try:
        machine.succeed(
            f"python3 {TOOLS}/native_durability.py --scenario {phase}"
            f" --image {IMAGE} --vmm {vmm} --tap native0"
            " --fixture /etc/native-durability-fixture"
            f" --work {work} --os-name {os_name} --disk {disk}{extra}",
            timeout=timeout,
        )
    except Exception:
        if os_name == "illumos" and phase == "interrupted-growth":
            guest_growth_log(machine, disk)
        raise
    finally:
        print(
            f"native durability phase={phase} seconds={time.monotonic() - started:.0f}", flush=True
        )
        status, serial = machine.execute(f"tail -c 65536 {work}/serial.log 2>/dev/null")
        if status == 0:
            print(serial, flush=True)
