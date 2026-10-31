import pathlib
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
from collections.abc import Sequence

# @cc [owner:ghuntley,label:verification] exported-images-boot-without-instrumentation
# Exact exported disks MUST boot through UEFI without a direct kernel, shared
# host store, injected credentials or a test-console service. Fresh copies MUST
# generate different SSH identities; reboot and each surviving mirror member
# MUST retain the first copy's identity. Writes MUST stay in disposable overlays.
# The base perimeter admits SSH only from the recorded installer source
# (ADR-0234); the fixture images record 10.0.2.2, QEMU user networking's view
# of this driver, exactly as installation would (exported-image-installer-source).
work = pathlib.Path(tempfile.mkdtemp(prefix="overalls-images-"))
bases = [pathlib.Path(images) / f"{name}.qcow2" for name in ["system0", "system1"]]


def overlays(name: str, parents: Sequence[pathlib.Path]) -> list[pathlib.Path]:
    result = []
    for number, parent in enumerate(parents):
        disk = work / f"{name}-{number}.qcow2"
        subprocess.run(
            [qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", str(parent), str(disk)],
            check=True,
        )
        result.append(disk)
    return result


def boot_key(name: str, disks: Sequence[pathlib.Path]) -> str:
    nvram = work / f"{name}-nvram.fd"
    shutil.copyfile(variables, nvram)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    command = [
        qemu,
        "-enable-kvm",
        "-cpu",
        "host",
        "-m",
        "2048",
        "-smp",
        "2",
        "-drive",
        f"if=pflash,format=raw,unit=0,readonly=on,file={firmware}",
        "-drive",
        f"if=pflash,format=raw,unit=1,file={nvram}",
        "-netdev",
        f"user,id=network,hostfwd=tcp:127.0.0.1:{port}-:22",
        "-device",
        "virtio-net-pci,netdev=network",
    ]
    for number, disk in enumerate(disks):
        command += [
            "-drive",
            f"file={disk},if=none,id=member{number},format=qcow2,cache=writeback,werror=report",
            "-device",
            f"virtio-blk-pci,drive=member{number},serial=member{number}",
        ]
    vm = create_machine(name=name, start_command=shlex.join(command))
    driver.machines_qemu.append(vm)
    vm.start()
    process = vm.process
    assert process is not None
    deadline = time.monotonic() + 240
    key = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f"{name}: QEMU exited before SSH"
        scan = subprocess.run(
            [ssh_keyscan, "-T", "3", "-t", "ed25519", "-p", str(port), "127.0.0.1"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        keys = [line.split() for line in scan.stdout.splitlines() if not line.startswith("#")]
        if (
            scan.returncode == 0
            and len(keys) == 1
            and len(keys[0]) == 3
            and keys[0][1] == "ssh-ed25519"
        ):
            key = " ".join(keys[0][1:])
            break
        time.sleep(1)
    if key is None:
        vm.screenshot(f"{name}-boot-failure")
        raise AssertionError(f"{name}: no SSH host identity within 240 seconds")
    vm.log("Exported image reached SSH with an Ed25519 host identity")
    vm.send_monitor_command("system_powerdown")
    process.wait(timeout=60)
    vm.wait_for_shutdown()
    return key


first = overlays("first", bases)
identity = boot_key("first-boot", first)
independent = overlays("independent", bases)
assert boot_key("independent-first-boot", independent) != identity
assert boot_key("reboot", first) == identity

# Fork only after clean shutdown and never rejoin independently written branches.
for number, member in enumerate(first):
    survivor = overlays(f"survivor-{number}", [member])
    assert boot_key(f"survivor-{number}", survivor) == identity
