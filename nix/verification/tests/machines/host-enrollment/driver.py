import base64
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile

work = pathlib.Path(tempfile.mkdtemp(prefix="host-enrollment-"))
command = [
    qemu,
    "-enable-kvm",
    "-cpu",
    "host",
    "-m",
    "6144",
    "-smp",
    "4",
    "-uuid",
    "11111111-1111-4111-8111-111111111111",
    "-netdev",
    "user,id=net,hostfwd=tcp:127.0.0.1:2222-:22",
    "-device",
    "virtio-net-pci,netdev=net",
]
for i in range(2):
    backing = str(pathlib.Path(images) / f"system{i}.qcow2")
    disk = str(work / f"disk{i}.qcow2")
    subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", backing, disk], check=True
    )
    command += [
        "-drive",
        f"file={disk},if=none,id=d{i},format=qcow2",
        "-device",
        f"virtio-blk-pci,drive=d{i},serial=member{i}",
    ]
host = create_machine(name="host", start_command=shlex.join(command))
driver.machines_qemu.append(host)
host.start()
host.wait_for_unit("sshd.service")
# A base system admits only Tailscale and the source its installation recorded
# (ADR-0234). Record the installer source as `remote.py install-base-source`
# would: QEMU user networking forwards the driver's SSH from 10.0.2.2.
host.succeed(
    "install -d -m 0700 /var/lib/overalls-host"
    " && (umask 077; printf '10.0.2.2\\n' > /var/lib/overalls-host/base-source)"
    " && systemctl start overalls-base-source.service"
    " && systemctl restart overalls-runtime-firewall.service"
)
host.succeed("install -d -m 700 /root/enrollment-test")
for source, destination in [
    (operator_key, "operator"),
    (recipe, "flake.nix"),
    (common, "common.nix"),
    (remote_script, "remote.py"),
    (test_program, "exercise.py"),
]:
    data = base64.b64encode(pathlib.Path(source).read_bytes()).decode()
    code, _ = host.execute(
        "umask 077; printf %s "
        + shlex.quote(data)
        + " | base64 -d > /root/enrollment-test/"
        + destination
    )
    assert code == 0
# Seed additional native-build inputs over authenticated SSH. A private local
# Nix database lets this client use the builder's read-only store safely.
transport_key = work / "transport-key"
shutil.copyfile(operator_key, transport_key)
transport_key.chmod(0o600)
known = work / "known-hosts"
known.write_text(
    "[127.0.0.1]:2222 " + host.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip() + "\n"
)
env = dict(
    os.environ,
    NIX_STATE_DIR=str(work / "nix-state"),
    NIX_LOG_DIR=str(work / "nix-log"),
    NIX_REMOTE="local",
    NIX_CONFIG="experimental-features = nix-command\nsubstituters =\n",
    PATH=ssh_path + ":" + os.environ["PATH"],
    NIX_SSHOPTS=shlex.join(
        [
            "-F",
            "/dev/null",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "UserKnownHostsFile=" + str(known),
            "-i",
            str(transport_key),
        ]
    ),
)
subprocess.run(
    [nix_store, "--load-db"],
    input=pathlib.Path(registration).read_text(),
    text=True,
    env=env,
    check=True,
)
subprocess.run(
    [nix, "copy", "--no-check-sigs", "--to", "ssh-ng://tester@127.0.0.1:2222", *extra_paths],
    env=env,
    check=True,
    timeout=180,
)
# Exercise transport, SOPS, exact published builds and activation inside the VM.
# Its authenticated SSH target is the same host over loopback; no calls are mocked.
host.succeed("python3 /root/enrollment-test/exercise.py", timeout=2400)
host.shutdown()
