"""Native durability scenarios: interrupted growth, host power loss and relocation.

Each scenario boots the actual native image in Firecracker with the production
drive cache mode (Writeback, Sync engine) on a disk file in a host ZFS dataset,
reaches complete readiness under an isolated synthetic authority, and records a
bounded receipt. Receipts never grant native admission.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import ssl
import subprocess
import tempfile
import threading
import time
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import native_control as control
import native_crash_recovery as crash
import native_git_fixture as git_fixture
import native_service_runner as runner
import native_services as services

Scenario = Literal[
    "interrupted-growth",
    "power-loss-before",
    "power-loss-after",
    "relocation-source",
    "relocation-destination",
]
EXPANSION = 2 * 1024**3
SOURCE_PLACEMENT = "dddddddd-dddd-4ddd-8ddd-000000000201"
DESTINATION_PLACEMENT = "eeeeeeee-eeee-4eee-8eee-000000000202"
POWER_CUT = "power-cut"
# Kill points, counted in VMM disk writes at or beyond the pre-expansion end of
# the disk: the first growth mutation, then a point inside native expansion.
INTERRUPTIONS = (1, 8)
ROOT_TYPES = {
    "freebsd": "516e7cb6-6ecf-11d6-8ff8-00022d09712b",
    "illumos": "6a898cc3-1dd2-11b2-99a6-080020736631",
}
WORKSPACE = '"$HOME/native-durability-workspace"'
WORKSPACE_LINES = 32768
TRACED = ("lseek", "write", "writev", "pwrite64", "pwritev", "pwritev2")
TRACE_LINE = re.compile(
    rb"^(?:\[pid\s+)?(\d+)\]?\s+(" + b"|".join(t.encode() for t in TRACED) + rb")\(([^)<]*)"
)


class DurabilityError(RuntimeError):
    """A failed durability observation; its text is a fixed category only."""


def workspace_bytes() -> bytes:
    return b"".join(b"native-relocation-%08d\n" % index for index in range(WORKSPACE_LINES))


def workspace_script() -> str:
    return (
        f"umask 077; /bin/mkdir -p {WORKSPACE}; "
        f"for ((index=0; index<{WORKSPACE_LINES}; index++)); do "
        "printf 'native-relocation-%08d\\n' \"$index\"; done "
        f"> {WORKSPACE}/data.bin; printf native-workspace-written"
    )


def digest_command(platform: runner.Platform) -> str:
    if platform.name == "freebsd":
        return f"/sbin/sha256 -q {WORKSPACE}/data.bin"
    return f"/usr/bin/digest -a sha256 {WORKSPACE}/data.bin"


def binding(placement: str, epoch: int) -> services.Binding:
    return services.Binding(placement, epoch, secrets.token_hex(32))


@dataclass(frozen=True)
class Prior:
    """The previous boot's identity, retained only inside private work roots."""

    boot: services.Boot
    workspace_sha256: str

    def encode(self) -> str:
        return json.dumps(
            {
                "version": 1,
                **self.boot.fields(),
                "workspace_sha256": self.workspace_sha256,
            },
            sort_keys=True,
        )


def prior_value(body: bytes) -> Prior:
    if len(body) > 4096:
        raise DurabilityError("invalid native durability state")
    value = services.decode_object(body)
    if (
        set(value)
        != {
            "version",
            "placement_id",
            "execution_epoch",
            "boot_challenge",
            "boot_id",
            "workspace_sha256",
        }
        or value.get("version") != 1
    ):
        raise DurabilityError("invalid native durability state")
    placement = value["placement_id"]
    epoch = value["execution_epoch"]
    challenge = value["boot_challenge"]
    boot_id = value["boot_id"]
    workspace = value["workspace_sha256"]
    if (
        not isinstance(placement, str)
        or type(epoch) is not int
        or not isinstance(challenge, str)
        or not isinstance(boot_id, str)
        or not isinstance(workspace, str)
        or not services.valid_hex(workspace, 64)
    ):
        raise DurabilityError("invalid native durability state")
    return Prior(services.Boot(services.Binding(placement, epoch, challenge), boot_id), workspace)


@dataclass(frozen=True)
class Write:
    fd: int
    offset: int
    length: int | None


class TraceParser:
    """Project strace raw lines to disk-write offsets; other descriptors are ignored."""

    def __init__(self, descriptors: frozenset[int]) -> None:
        self.descriptors = descriptors
        self.positions: dict[int, int] = {}

    def line(self, raw: bytes) -> Write | None:
        match = TRACE_LINE.match(raw)
        if match is None:
            return None
        name = match.group(2).decode("ascii")
        try:
            arguments = [
                int(item.strip(), 0) for item in match.group(3).split(b",") if item.strip()
            ]
        except ValueError:
            return None
        if not arguments or arguments[0] not in self.descriptors:
            return None
        fd = arguments[0]
        if name == "lseek":
            if len(arguments) >= 3 and arguments[2] == 0:
                self.positions[fd] = arguments[1]
            return None
        if name == "write" and len(arguments) >= 3 and fd in self.positions:
            offset = self.positions[fd]
            self.positions[fd] = offset + arguments[2]
            return Write(fd, offset, arguments[2])
        if name == "writev" and fd in self.positions:
            return Write(fd, self.positions[fd], None)
        if name == "pwrite64" and len(arguments) >= 4:
            return Write(fd, arguments[3], arguments[2])
        if name in ("pwritev", "pwritev2") and len(arguments) >= 4:
            return Write(fd, arguments[3], None)
        return None


def beyond(write: Write, threshold: int) -> bool:
    end = write.offset + (write.length or 1)
    return end > threshold


class Host:
    """One test host's private native VM: fixture copy, config and launch helpers."""

    def __init__(
        self,
        image: Path,
        vmm: Path,
        fixture: Path,
        tap: str,
        work: Path,
        os_name: services.Os,
        disk: Path,
    ) -> None:
        work.mkdir(mode=0o700, parents=True, exist_ok=False)
        local = work / "authority"
        local.mkdir(mode=0o700)
        for name in (
            "ca.pem",
            "tls.pem",
            "tls.key",
            "ssh-ca",
            "ssh-ca.pub",
            "user",
            "user.pub",
            "wrong-user",
            "wrong-user.pub",
        ):
            shutil.copyfile(fixture / name, local / name)
            (local / name).chmod(0o600)
        self.fixture = local
        self.work = work
        self.vmm = vmm
        self.disk = disk
        self.platform = runner.Platform(os_name)
        self.network = runner.DEFAULT_NETWORK
        manifest = services.decode_object((image / "manifest.json").read_bytes())
        kernel = services.decode_object(json.dumps(manifest.get("kernel")).encode("utf-8"))
        expected = kernel.get("sha256")
        if not isinstance(expected, str) or not services.valid_hex(expected, 64):
            raise DurabilityError("missing exact native kernel identity")
        self.expected = expected
        self.git_identity = manifest.get("git_identity_version") == 1
        self.uds = work / "v.sock"
        self.metadata = work / "metadata.json"
        self.config = work / "firecracker.json"
        # Lilly's production drive configuration (lilly/lib/lilly/vm/jail.ex):
        # Writeback advertises virtio flush and turns it into a host fsync.
        self.config.write_text(
            json.dumps(
                {
                    "boot-source": {"kernel_image_path": str((image / "firmware").resolve())},
                    "drives": [
                        {
                            "drive_id": "rootfs",
                            "path_on_host": str(disk),
                            "is_root_device": True,
                            "is_read_only": False,
                            "cache_type": "Writeback",
                            "io_engine": "Sync",
                        }
                    ],
                    "machine-config": {"vcpu_count": 2, "mem_size_mib": 2048},
                    "vsock": {"guest_cid": 3, "uds_path": str(self.uds)},
                    "network-interfaces": [
                        {"iface_id": "native0", "host_dev_name": tap, "guest_mac": self.network.mac}
                    ],
                    "mmds-config": {
                        "version": "V2",
                        "network_interfaces": ["native0"],
                        "ipv4_address": "169.254.169.254",
                    },
                }
            ),
            encoding="utf-8",
        )

    def arguments(self) -> list[str]:
        return runner.firecracker_arguments(self.vmm, self.metadata, self.config, None)

    def prepare(self, current: services.Binding) -> None:
        runner.metadata(self.metadata, current, self.network, git_identity=self.git_identity)
        for path in self.work.glob("v.sock*"):
            path.unlink()

    @contextmanager
    def launched(self, arguments: list[str]) -> Generator[subprocess.Popen[bytes]]:
        with (
            (self.work / "serial.log").open("ab") as serial,
            (self.work / "vmm-stderr.log").open("ab") as stderr,
        ):
            process = subprocess.Popen(
                arguments, stdin=subprocess.DEVNULL, stdout=serial, stderr=stderr
            )
            try:
                yield process
            finally:
                runner.cleanup_vm(process)

    @contextmanager
    def ready(self, current: services.Binding) -> Generator[runner.BootContext]:
        """Boot to complete readiness under isolated authority; the caller ends the boot."""
        self.prepare(current)
        with self.launched(self.arguments()) as process:
            boot = runner.wait_kernel(process, self.uds, current, self.expected, self.platform)
            subprocess.run(
                ["ping", "-c", "1", "-W", "5", self.network.address],
                check=True,
                timeout=10,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            services.readiness_withheld(self.uds)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(self.fixture / "tls.pem", self.fixture / "tls.key")
            authority = control.Authority(
                control.Config(
                    self.fixture / "ssh-ca",
                    runner.PRINCIPAL,
                    frozenset({self.network.address}),
                    control.key((self.fixture / "user.pub").read_text().strip()),
                )
            )
            server = control.Server(("169.254.254.1", 443), context, authority)
            dns = git_fixture.DNSServer(("1.1.1.1", 53), frozenset({self.network.address}))
            threads = [
                threading.Thread(target=server.serve_forever, daemon=True),
                threading.Thread(target=dns.serve_forever, daemon=True),
            ]
            for thread in threads:
                thread.start()
            try:
                services.trust(self.uds, boot, [(self.fixture / "ca.pem").read_text()])
                runner.wait_readiness(process, self.uds, boot)
                (self.work / "known_hosts").write_text(
                    f"@cert-authority {runner.PRINCIPAL} "
                    f"{(self.fixture / 'ssh-ca.pub').read_text().strip()}\n"
                )
                print(f"native durability ready epoch={current.execution_epoch}", flush=True)
                yield runner.BootContext(
                    self.uds,
                    boot,
                    self.fixture,
                    self.work,
                    self.network,
                    self.platform,
                    process,
                    authority,
                )
            finally:
                server.shutdown()
                dns.shutdown()
                for thread in threads:
                    thread.join(timeout=5)
                server.server_close()
                dns.server_close()

    def interrupted(self, current: services.Binding, threshold: int, count: int) -> int:
        """@cc [owner:ghuntley,label:verification;recovery] native-growth-interruption-point
        The VMM MUST run under a syscall tracer limited to write-family calls and
        receive SIGKILL once it has issued `count` writes to the root disk file
        at or past `threshold` (the pre-expansion size). A boot that reaches the
        deadline or exits first MUST fail. Returns the observed write count,
        which may exceed `count` because the tracer is asynchronous.
        """
        self.prepare(current)
        trace = self.work / f"trace-{current.execution_epoch}.log"
        tracer = [
            "strace",
            "-f",
            "--seccomp-bpf",
            "-qq",
            "-e",
            "trace=" + ",".join(TRACED),
            "-e",
            "raw=all",
            "-e",
            "signal=none",
            "-o",
            str(trace),
            "--",
            *self.arguments(),
        ]
        disk = self.disk.resolve()
        with self.launched(tracer) as process:
            deadline = time.monotonic() + 300
            vmm_pid = 0
            descriptors: frozenset[int] = frozenset()
            while not descriptors:
                if process.poll() is not None or time.monotonic() > deadline:
                    raise DurabilityError("traced native VMM did not open its disk")
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children")
                try:
                    pids = children.read_text().split()
                    if pids:
                        vmm_pid = int(pids[0])
                        found: set[int] = set()
                        for entry in Path(f"/proc/{vmm_pid}/fd").iterdir():
                            try:
                                if Path(os.readlink(entry)) == disk:
                                    found.add(int(entry.name))
                            except OSError:
                                continue
                        descriptors = frozenset(found)
                except OSError:
                    pass
                time.sleep(0.05)
            parser = TraceParser(descriptors)
            observed = 0
            offsets: list[int] = []
            while not trace.exists():
                time.sleep(0.01)
            with trace.open("rb") as source:
                pending = b""
                while observed < count:
                    if process.poll() is not None:
                        raise DurabilityError("native VMM exited before the growth interruption")
                    if time.monotonic() > deadline:
                        raise DurabilityError("native growth interruption deadline exceeded")
                    chunk = source.read(65536)
                    if not chunk:
                        time.sleep(0.002)
                        continue
                    pending += chunk
                    *lines, pending = pending.split(b"\n")
                    for line in lines:
                        write = parser.line(line)
                        if write is not None and beyond(write, threshold):
                            observed += 1
                            if len(offsets) < 32:
                                offsets.append(write.offset - threshold)
                            if observed >= count:
                                os.kill(vmm_pid, signal.SIGKILL)
                                break
                process.wait(timeout=30)
                for line in (pending + source.read()).split(b"\n"):
                    write = parser.line(line)
                    if write is not None and beyond(write, threshold):
                        observed += 1
            print(
                f"native growth interruption count={count} observed={observed} "
                f"relative_offsets={offsets}",
                flush=True,
            )
            if process.returncode not in (-signal.SIGKILL, 128 + signal.SIGKILL):
                raise DurabilityError("native growth interruption was not an observed SIGKILL")
            trace.unlink()
            return observed


def kill(context: runner.BootContext) -> None:
    runner.alive(context.process)
    context.process.kill()
    if context.process.wait(timeout=10) != -signal.SIGKILL:
        raise DurabilityError("native abrupt VMM death was not observed")


def dm_mark(device: str, name: str) -> None:
    subprocess.run(["dmsetup", "message", device, "0", "mark", name], check=True, timeout=30)


def marker(context: runner.BootContext, journal: str = "") -> None:
    """Create fixed home bytes, acknowledge them through the native flush agent, read back.

    With a dm-log-writes device, marks bracket the flush request so the replay
    records how many device flushes the guest's flush capability produced.
    """
    if (
        crash.command(
            context,
            f"test ! -e {crash.MARKER}; umask 077; "
            f"printf 'native-crash-durable-bytes-v1\\n' > {crash.MARKER}; "
            "printf native-crash-marker-created",
        )
        != b"native-crash-marker-created"
    ):
        raise DurabilityError("native durability marker was not created")
    if journal:
        dm_mark(journal, "guest-flush-requested")
    services.flush(context.uds, context.boot)
    if journal:
        dm_mark(journal, "guest-flush-acknowledged")
    retained(context)


def retained(context: runner.BootContext) -> None:
    if (
        crash.command(
            context, f"test -f {crash.MARKER}; test ! -L {crash.MARKER}; /bin/cat {crash.MARKER}"
        )
        != crash.RETAINED
    ):
        raise DurabilityError("native durability marker bytes differ")


def workspace_digest(context: runner.BootContext) -> str:
    body = crash.command(context, digest_command(context.platform))
    value = body.decode("ascii", errors="replace").strip()
    if not services.valid_hex(value, 64):
        raise DurabilityError("invalid native workspace digest")
    return value


def capacity(context: runner.BootContext) -> int:
    if context.platform.name == "freebsd":
        lines = crash.command(context, "/bin/df -kP /").splitlines()
        fields = lines[1].split() if len(lines) == 2 else []
        if len(fields) != 6 or fields[5] != b"/" or not fields[1].isdigit():
            raise DurabilityError("invalid native root capacity")
        return int(fields[1]) * 1024
    body = crash.command(
        context, f"/usr/sbin/zpool get -Hp -o value size {crash.POOL}", root=True
    ).strip()
    if not body.isdigit():
        raise DurabilityError("invalid native pool capacity")
    return int(body)


@dataclass(frozen=True)
class GrowthReceipt:
    disk_bytes: int
    root_end_after: int
    outcome: str


def growth_receipt(context: runner.BootContext) -> GrowthReceipt:
    value = services.decode_object(
        crash.command(context, "/bin/cat /var/run/overalls/root-growth.json", root=True)
    )
    disk_bytes = value.get("disk_bytes")
    end = value.get("root_end_after")
    outcome = value.get("outcome")
    if (
        value.get("os") != context.platform.name
        or value.get("native_admission") is not False
        or type(disk_bytes) is not int
        or type(end) is not int
        or outcome not in ("grown", "unchanged")
        or not isinstance(outcome, str)
    ):
        raise DurabilityError("invalid native growth receipt")
    return GrowthReceipt(disk_bytes, end, outcome)


def narrow(value: object) -> dict[str, object]:
    """Re-validate a nested JSON object through the closed decoder."""
    if not isinstance(value, dict):
        raise DurabilityError("invalid native GPT response")
    return services.decode_object(json.dumps(value).encode("utf-8"))


def root_end(disk: Path, os_name: services.Os) -> int:
    """Read the primary GPT root partition end through pinned sfdisk."""
    result = subprocess.run(
        ["sfdisk", "--json", str(disk)], capture_output=True, check=False, timeout=30
    )
    if result.returncode or len(result.stdout) > 16384:
        raise DurabilityError("native GPT unreadable after interruption")
    table = narrow(services.decode_object(result.stdout).get("partitiontable"))
    partitions = table.get("partitions")
    if not isinstance(partitions, list):
        raise DurabilityError("invalid native GPT response")
    ends: list[int] = []
    for raw in partitions:
        item = narrow(raw)
        kind = item.get("type")
        start = item.get("start")
        size = item.get("size")
        if (
            isinstance(kind, str)
            and kind.lower() == ROOT_TYPES[os_name]
            and type(start) is int
            and type(size) is int
        ):
            ends.append(start + size - 1)
    if not ends:
        raise DurabilityError("native GPT root partition is missing")
    return ends[-1]


def write_receipt(work: Path, name: str, receipt: dict[str, object]) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w", dir=work, prefix=".receipt-", delete=False
    ) as output:
        temporary = Path(output.name)
        try:
            json.dump(receipt, output, sort_keys=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
            temporary.replace(work / name)
        finally:
            temporary.unlink(missing_ok=True)


@dataclass(frozen=True)
class Baseline:
    capacity: int
    boot_id: str


@dataclass(frozen=True)
class Recovered:
    integrity: crash.Integrity
    receipt: GrowthReceipt
    capacity: int
    boot_id: str


def baseline(host: Host, current: services.Binding) -> Baseline:
    with host.ready(current) as context:
        marker(context)
        result = Baseline(capacity(context), context.boot.boot_id)
        runner.clean_shutdown(context)
        return result


def recover_growth(host: Host, current: services.Binding, killed: services.Binding) -> Recovered:
    with host.ready(current) as context:
        integrity = crash.integrity(context)
        result = Recovered(
            integrity, growth_receipt(context), capacity(context), context.boot.boot_id
        )
        retained(context)
        crash.stale_refusals(context, services.Boot(killed, context.boot.boot_id))
        services.flush(context.uds, context.boot)
        runner.clean_shutdown(context)
        return result


def interrupted_growth(host: Host) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-interrupted-growth-evidence
    After a flushed home marker and clean exit, each of two host expansions MUST
    be followed by a boot killed at a traced growth write past the old disk end.
    The primary GPT MUST then name either the old or the eventually grown root.
    The next boot MUST reach readiness only after the boot helper completes, pass
    native filesystem integrity (UFS forced fsck, ZFS zero-error scrub), report a
    current growth receipt for the expanded disk, show increased root capacity,
    retain the marker, refuse the killed boot's authority and exit cleanly.
    """
    epoch = 7
    first = baseline(host, binding(SOURCE_PLACEMENT, epoch))
    capacities = [first.capacity]
    boot_ids = [first.boot_id]
    stages: list[dict[str, object]] = []
    integrity: crash.Integrity | None = None
    for count in INTERRUPTIONS:
        before_bytes = host.disk.stat().st_size
        before_end = root_end(host.disk, host.platform.name)
        with host.disk.open("r+b") as target:
            target.truncate(before_bytes + EXPANSION)
            os.fsync(target.fileno())
        epoch += 1
        killed = binding(SOURCE_PLACEMENT, epoch)
        observed = host.interrupted(killed, before_bytes, count)
        interim_end = root_end(host.disk, host.platform.name)
        epoch += 1
        recovered = recover_growth(host, binding(SOURCE_PLACEMENT, epoch), killed)
        integrity = recovered.integrity
        receipt = recovered.receipt
        grown = recovered.capacity
        boot_ids.append(recovered.boot_id)
        after_end = root_end(host.disk, host.platform.name)
        if (
            receipt.disk_bytes != before_bytes + EXPANSION
            or receipt.root_end_after != after_end
            or after_end <= before_end
            or interim_end not in (before_end, after_end)
            or grown <= capacities[-1]
        ):
            raise DurabilityError("native interrupted growth did not recover consistently")
        capacities.append(grown)
        stages.append(
            {
                "kill_after_writes_past_old_end": count,
                "observed_writes_past_old_end": observed,
                "interim_root": "old" if interim_end == before_end else "grown",
                "recovery_receipt_outcome": receipt.outcome,
            }
        )
        print(f"native interrupted growth stage={count} recovered", flush=True)
    if len(set(boot_ids)) != len(boot_ids) or integrity is None:
        raise DurabilityError("native interrupted growth retained a boot identity")
    write_receipt(
        host.work,
        "interrupted-growth-receipt.json",
        {
            "version": 1,
            "os": host.platform.name,
            "boot_ids": boot_ids,
            "root_capacity_bytes": capacities,
            "stages": stages,
            "native_integrity": integrity,
            "checks": [
                "flushed-marker-before-expansion",
                "traced-sigkill-during-growth-writes-past-old-end",
                "primary-gpt-old-or-grown-after-interruption",
                "native-filesystem-integrity-after-recovery",
                "boot-helper-completed-growth-on-recovery-boot",
                "root-capacity-increased-each-stage",
                "marker-retained-and-killed-boot-authority-refused",
                "clean-exit-after-each-recovery",
            ],
            "native_admission": False,
            "scope": "VMM SIGKILL during boot-time root growth on a production-cache native disk file; host storage remains powered; no physical media fault or admission",
        },
    )


def power_loss_before(host: Host, cut_device: str, canary: Path) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-power-loss-cut
    The marker MUST be acknowledged by the native flush agent before a host
    canary is written without fsync and guest churn is left unsynchronized.
    The VMM MUST then be SIGKILLed and the dm-log-writes power-cut mark appended
    immediately, so the replayed prefix excludes every later flush.
    """
    current = binding(SOURCE_PLACEMENT, 7)
    state: Prior | None = None
    with host.ready(current) as context:
        marker(context, cut_device)
        canary.write_bytes(secrets.token_bytes(65536))
        if (
            crash.command(
                context,
                f"umask 077; for ((index=0; index<65536; index++)); do "
                f"printf 'native-unsynced-power-loss-churn\\n'; done > {crash.TRANSIENT}; "
                "printf native-churn-written",
            )
            != b"native-churn-written"
        ):
            raise DurabilityError("native power-loss churn failed")
        kill(context)
        dm_mark(cut_device, POWER_CUT)
        print("native power-loss cut marked after observed SIGKILL", flush=True)
        state = Prior(context.boot, "0" * 64)
    if state is None:
        raise DurabilityError("native power-loss cut was not observed")
    (host.work / "prior.json").write_text(state.encode() + "\n", encoding="utf-8")


def power_loss_after(host: Host, prior: Prior, replay: Path, canary: Path) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-power-loss-evidence
    On the replayed pool, the unsynchronized host canary MUST be absent (proving
    volatile state was discarded), the guest MUST boot under fresh authority,
    pass native integrity, retain exact flush-acknowledged marker bytes, refuse
    the pre-cut boot's authority and exit cleanly. Survival of unsynchronized
    guest churn is recorded, never required or claimed.
    """
    if canary.exists():
        raise DurabilityError("unsynchronized host canary survived the power cut")
    counts = services.decode_object(replay.read_bytes())
    current = binding(SOURCE_PLACEMENT, prior.boot.binding.execution_epoch + 1)
    integrity: crash.Integrity | None = None
    churn = b""
    boot_id = ""
    with host.ready(current) as context:
        crash.new_authority(prior.boot, context.boot)
        integrity = crash.integrity(context)
        retained(context)
        churn = crash.command(
            context,
            f"if test -f {crash.TRANSIENT}; then /usr/bin/wc -c < {crash.TRANSIENT}; "
            "else printf absent; fi",
        ).strip()
        crash.stale_refusals(context, prior.boot)
        services.flush(context.uds, context.boot)
        boot_id = context.boot.boot_id
        runner.clean_shutdown(context)
    if integrity is None or not boot_id:
        raise DurabilityError("native power-loss recovery was not observed")
    write_receipt(
        host.work,
        "power-loss-receipt.json",
        {
            "version": 1,
            "os": host.platform.name,
            "boot_ids": [prior.boot.boot_id, boot_id],
            "boot_endings": ["power-cut", "clean"],
            "native_integrity": integrity,
            "replay": counts,
            "unsynced_guest_churn": churn.decode("ascii", errors="replace")[:32],
            "checks": [
                "flush-agent-acknowledged-marker-before-cut",
                "vmm-sigkill-then-dm-log-writes-power-cut-mark",
                "replayed-flushed-prefix-only",
                "unsynchronized-host-canary-lost",
                "same-placement-new-epoch-challenge-and-boot-id",
                "native-filesystem-integrity-after-power-loss",
                "exact-flushed-marker-bytes-after-power-loss",
                "pre-cut-flush-workspace-and-terminal-authority-refused",
                "final-clean-shutdown-observed",
            ],
            "native_admission": False,
            "scope": "host power loss modeled by replaying the host ZFS pool's dm-log-writes journal to the cut; one nested host, synthetic authority; no physical media or admission",
        },
    )


def relocation_source(host: Host) -> None:
    current = binding(SOURCE_PLACEMENT, 7)
    expected = hashlib.sha256(workspace_bytes()).hexdigest()
    state: Prior | None = None
    with host.ready(current) as context:
        marker(context)
        if crash.command(context, workspace_script()) != b"native-workspace-written":
            raise DurabilityError("native relocation workspace write failed")
        services.flush(context.uds, context.boot)
        if workspace_digest(context) != expected:
            raise DurabilityError("native relocation workspace digest differs")
        state = Prior(context.boot, expected)
        runner.clean_shutdown(context)
    if state is None:
        raise DurabilityError("native relocation source was not observed")
    (host.work / "prior.json").write_text(state.encode() + "\n", encoding="utf-8")


def relocation_destination(host: Host, prior: Prior) -> None:
    """@cc [owner:ghuntley,label:verification;security;recovery] native-relocation-evidence
    A stopped native guest's received disk MUST boot on a second host under a
    new placement, epoch and challenge with a new boot ID, keep exact workspace
    and marker bytes, refuse the source placement's flush, workspace and terminal
    authority, and exit cleanly. This MUST NOT claim Lilly transfer orchestration.
    """
    if prior.boot.binding.placement_id != SOURCE_PLACEMENT:
        raise DurabilityError("native relocation source placement differs")
    current = binding(DESTINATION_PLACEMENT, 1)
    integrity: crash.Integrity | None = None
    boot_id = ""
    with host.ready(current) as context:
        if context.boot.boot_id == prior.boot.boot_id:
            raise DurabilityError("native relocation retained the source boot ID")
        integrity = crash.integrity(context)
        retained(context)
        if workspace_digest(context) != prior.workspace_sha256:
            raise DurabilityError("native relocation lost workspace bytes")
        crash.stale_refusals(context, prior.boot)
        services.flush(context.uds, context.boot)
        boot_id = context.boot.boot_id
        runner.clean_shutdown(context)
    if integrity is None or not boot_id:
        raise DurabilityError("native relocation destination was not observed")
    write_receipt(
        host.work,
        "relocation-receipt.json",
        {
            "version": 1,
            "os": host.platform.name,
            "boot_ids": [prior.boot.boot_id, boot_id],
            "placements": [SOURCE_PLACEMENT, DESTINATION_PLACEMENT],
            "workspace_sha256": prior.workspace_sha256,
            "native_integrity": integrity,
            "checks": [
                "source-clean-exit-after-flushed-workspace",
                "zfs-send-receive-to-second-host",
                "destination-new-placement-epoch-challenge-and-boot-id",
                "native-filesystem-integrity-on-destination",
                "exact-workspace-and-marker-bytes-on-destination",
                "source-placement-flush-workspace-and-terminal-authority-refused",
                "destination-clean-shutdown-observed",
            ],
            "native_admission": False,
            "scope": "stopped native guest disk moved by ZFS send/receive between two nested hosts; not Lilly transfer or Marshall relocation orchestration; no admission",
        },
    )


class Options(argparse.Namespace):
    scenario: Scenario
    image: Path
    vmm: Path
    fixture: Path
    tap: str
    work: Path
    os_name: services.Os
    disk: Path
    cut_device: str
    canary: Path | None
    prior: Path | None
    replay: Path | None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scenario",
        required=True,
        choices=(
            "interrupted-growth",
            "power-loss-before",
            "power-loss-after",
            "relocation-source",
            "relocation-destination",
        ),
    )
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--vmm", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--tap", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--os-name", choices=("freebsd", "illumos"), required=True)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--cut-device", default="")
    parser.add_argument("--canary", type=Path)
    parser.add_argument("--prior", type=Path)
    parser.add_argument("--replay", type=Path)
    arguments = parser.parse_args(namespace=Options())
    host = Host(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        arguments.os_name,
        arguments.disk,
    )
    try:
        if arguments.scenario == "interrupted-growth":
            interrupted_growth(host)
        elif arguments.scenario == "power-loss-before":
            if not arguments.cut_device or arguments.canary is None:
                raise DurabilityError("power-loss cut requires its device and canary")
            power_loss_before(host, arguments.cut_device, arguments.canary)
        elif arguments.scenario == "power-loss-after":
            if arguments.prior is None or arguments.replay is None or arguments.canary is None:
                raise DurabilityError("power-loss recovery requires its prior state")
            power_loss_after(
                host,
                prior_value(arguments.prior.read_bytes()),
                arguments.replay,
                arguments.canary,
            )
        elif arguments.scenario == "relocation-source":
            relocation_source(host)
        else:
            if arguments.prior is None:
                raise DurabilityError("relocation destination requires source state")
            relocation_destination(host, prior_value(arguments.prior.read_bytes()))
    finally:
        host.metadata.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
