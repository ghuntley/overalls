"""Plan safety tests; these do not establish physical installation acceptance."""

import copy
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar, NotRequired, TypedDict, cast
from unittest.mock import patch

import cli  # ty: ignore[unresolved-import] # PYTHONPATH nix/domains/artifacts/host
import enrollment  # ty: ignore[unresolved-import] # PYTHONPATH nix/domains/artifacts/host
import remote  # ty: ignore[unresolved-import] # PYTHONPATH nix/domains/artifacts/host

spec = importlib.util.spec_from_file_location("updater", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("updater helper unavailable")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)
resource_helper = sys.argv.pop(1)
fleet_spec = importlib.util.spec_from_file_location("fleet_addresses", sys.argv.pop(1))
if fleet_spec is None or fleet_spec.loader is None:
    raise RuntimeError("fleet address helper unavailable")
fleet_addresses = importlib.util.module_from_spec(fleet_spec)
fleet_spec.loader.exec_module(fleet_addresses)


class DiskRecord(TypedDict):
    id: str
    serial: str
    model: str
    kind: str
    size: int
    device: str
    aliases: list[str]
    path: str
    transport: str
    active: bool


class InventoryRecord(TypedDict):
    arch: str
    machine: str
    disks: list[DiskRecord]


class StorageRecord(TypedDict):
    system: list[str]
    guests: list[str]
    quotaBytes: int | None
    ashift: int


class BudgetsRecord(TypedDict):
    # Hetzner Cloud hosts declare only the ARC budget (no Lilly guests).
    guestMemoryMiB: NotRequired[int]
    guestCpuCores: NotRequired[int]
    arcMaxMiB: int


class HostRecord(TypedDict):
    name: str
    reviewed: bool
    platform: str
    firmware: str
    identity: dict[str, object]
    inventory: InventoryRecord
    storage: StorageRecord
    network: dict[str, object]
    budgets: BudgetsRecord
    git: dict[str, str]
    credentials: list[object]


class ResourcePolicyRecord(TypedDict):
    version: int
    cpuCores: int
    memoryMiB: int
    arcMaxBytes: int
    quotaBytes: int
    dataset: str
    zpoolGuid: str
    datasetGuid: str


class CandidateRecord(TypedDict):
    resourcePolicy: ResourcePolicyRecord
    lilly: dict[str, object]
    installationBinding: dict[str, object]


class BindingRecord(TypedDict):
    platform: str
    identity: dict[str, object]


class PlanRecord(TypedDict):
    version: int
    host: HostRecord
    target: str
    sourceKey: str
    sshPort: int
    installerSshPort: int
    repository: str
    revision: str
    system: str
    install: str
    kexec: str


def disk(name: str, kind: str) -> DiskRecord:
    return {
        "id": name,
        "serial": name,
        "model": kind,
        "kind": kind,
        "size": 100,
        "device": "/dev/disk/by-id/" + name,
        "aliases": ["/dev/disk/by-id/" + name],
        "path": "/dev/nvme0n1",
        "transport": "nvme",
        "active": False,
    }


def host() -> HostRecord:
    return {
        "name": "example",
        "reviewed": True,
        "platform": "ec2",
        "firmware": "uefi",
        "identity": {"hostId": "12345678", "sshKeys": []},
        "inventory": {
            "arch": "x86_64",
            "machine": "machine-1",
            "disks": [
                disk("root", "ebs"),
                disk("other-ebs", "ebs"),
                disk("local1", "local-nvme"),
                disk("local2", "local-nvme"),
            ],
        },
        "storage": {
            "system": ["root"],
            "guests": ["local1", "local2"],
            "quotaBytes": None,
            "ashift": 12,
        },
        "network": {"10-eth": {"networkConfig": {"DHCP": "yes"}}},
        "budgets": {
            "guestMemoryMiB": 1024,
            "guestCpuCores": 2,
            "arcMaxMiB": 512,
        },
        "git": {"repository": cli.REPOSITORY, "knownHosts": ""},
        "credentials": [],
    }


class HostPlanning(unittest.TestCase):
    def test_explicit_empty_lilly_rebind_replaces_only_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original_path = Path

            def local_path(value: str | Path) -> Path:
                path = original_path(value)
                if path.is_relative_to(root):
                    return path
                return root / str(path).lstrip("/") if path.is_absolute() else path

            storage = {
                "backend": "zfs",
                "dataset": "zroot/lilly",
                "zpool_guid": "1",
                "dataset_guid": "2",
            }

            def owner(host_id: str, pool_id: str) -> dict[str, object]:
                return {
                    "host_id": host_id,
                    "state_dir": "/state",
                    "vm_state_dir": "/vms",
                    "network_state_dir": "/network",
                    "pools": [
                        {
                            "id": pool_id,
                            "path": "/pool",
                            "filesystem_id": "zfs:1:2",
                            "storage": storage,
                        }
                    ],
                }

            old_owner = owner("old-host", "old-pool")
            new_owner = owner("new-host", "new-pool")
            old_binding = {
                "hostId": "old-host",
                "egressInterface": "eth0",
                "protectedCidrs": [],
            }
            new_binding = {**old_binding, "hostId": "new-host"}
            previous = {
                "lilly": {
                    "binding": old_binding,
                    "owner": old_owner,
                    "transferStateDirectory": "/transfers",
                }
            }
            candidate = {
                "lilly": {
                    "binding": new_binding,
                    "owner": new_owner,
                    "transferStateDirectory": "/transfers",
                    "release": "/release",
                }
            }
            for path in [
                "/state/actors",
                "/state/commands",
                "/vms",
                "/network",
                "/transfers",
                "/pool/vms",
                "/pool/.lilly-zfs/active",
                "/pool/.lilly-zfs/deleted/retained-tombstone",
                "/sys/fs/cgroup/lilly.slice",
                "/var/lib/lilly",
                "/var/lib/overalls-host",
            ]:
                local_path(path).mkdir(parents=True, exist_ok=True)
            local_path("/sys/fs/cgroup/lilly.slice/cgroup.procs").write_text("")
            for name in ["network.json", "root.nft", "router.nft"]:
                (local_path("/network") / name).write_text("retained host network fixture")
            local_path("/state/identity.json").write_text(
                json.dumps({"version": 3, "host_id": "old-host"})
            )
            old_record = {"version": 1, "machine_id": "machine", **old_owner}
            old_pool = enrollment.pool_owner(old_owner, enrollment.owner_pools(old_owner)[0])
            local_path("/var/lib/lilly/owner.json").write_text(json.dumps(old_record))
            pool_owner_path = local_path("/pool/.lilly-zfs/owner.json")
            pool_owner_path.write_text(json.dumps(old_pool))
            calls: list[list[str]] = []
            zfs_children = False

            class Deployment:
                def command(
                    self, args: list[str], *, capture: bool = False, timeout: float = 7200
                ) -> str:
                    del capture, timeout
                    calls.append(args)
                    if args[:3] == ["systemctl", "show", "--property=ActiveState"]:
                        return "active"
                    if args[0] == "zfs":
                        return args[-1] + ("\n" + args[-1] + "/retained" if zfs_children else "")
                    return ""

            with patch.object(enrollment, "Path", side_effect=local_path):
                for _attempt in range(2):
                    enrollment.rebind_empty_lilly(
                        previous,
                        candidate,
                        cast(enrollment.Deployment, Deployment()),
                        cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                        "a" * 40,
                    )
            self.assertIn(["systemctl", "stop", "lilly.service"], calls)
            self.assertNotIn(["systemctl", "start", "lilly.service"], calls)
            network_calls = [call for call in calls if "OVERALLS_NETWORK_REBIND=" in " ".join(call)]
            self.assertEqual(len(network_calls), 1)
            self.assertIn("PATH=" + str(local_path("/release/host-tools/bin")), network_calls[0])
            self.assertEqual(
                json.loads(
                    local_path("/var/lib/overalls-host/lilly-rebind-network.json").read_text()
                ),
                {
                    "host_id": "old-host",
                    "egress": "eth0",
                    "protected": [],
                    "state_dir": "/network",
                },
            )
            self.assertEqual(
                json.loads(local_path("/var/lib/lilly/owner.json").read_text())["host_id"],
                "new-host",
            )
            self.assertEqual(json.loads(pool_owner_path.read_text())["pool_id"], "new-pool")
            self.assertEqual(
                json.loads(local_path("/state/identity.json").read_text())["host_id"], "new-host"
            )
            receipt = json.loads(local_path("/var/lib/overalls-host/lilly-rebind.json").read_text())
            self.assertEqual(receipt["phase"], "complete")
            self.assertTrue(local_path("/pool/.lilly-zfs/deleted/retained-tombstone").is_dir())
            zfs_children = True
            with (
                patch.object(enrollment, "Path", side_effect=local_path),
                self.assertRaisesRegex(ValueError, "child storage remains"),
            ):
                enrollment.rebind_empty_lilly(
                    previous,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                    "a" * 40,
                )
            zfs_children = False
            local_path("/var/lib/lilly/owner.json").write_text(json.dumps(old_record))
            pool_owner_path.write_text(json.dumps(old_pool))
            receipt["phase"] = "prepared"
            local_path("/var/lib/overalls-host/lilly-rebind.json").write_text(json.dumps(receipt))
            failed = False

            def fail_after_pool_write(path: Path, value: object) -> None:
                nonlocal failed
                remote.atomic(path, value)
                if path == pool_owner_path and not failed:
                    failed = True
                    raise RuntimeError("injected post-write failure")

            calls.clear()
            with (
                patch.object(enrollment, "Path", side_effect=local_path),
                self.assertRaisesRegex(RuntimeError, "post-write failure"),
            ):
                enrollment.rebind_empty_lilly(
                    previous,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(
                        enrollment.HostRemote,
                        SimpleNamespace(atomic=fail_after_pool_write),
                    ),
                    "a" * 40,
                )
            self.assertNotIn(["systemctl", "start", "lilly.service"], calls)
            with patch.object(enrollment, "Path", side_effect=local_path):
                enrollment.rebind_empty_lilly(
                    previous,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                    "a" * 40,
                )
            self.assertEqual(
                json.loads(local_path("/var/lib/lilly/owner.json").read_text())["host_id"],
                "new-host",
            )
            calls.clear()
            with patch.object(enrollment, "Path", side_effect=local_path):
                enrollment.rebind_empty_lilly(
                    candidate,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                    "a" * 40,
                )
            self.assertEqual(calls, [])

    def test_explicit_lilly_rebind_rejects_ambiguous_or_changed_physical_pools(self) -> None:
        pool: dict[str, object] = {
            "id": "old-pool",
            "path": "/pool",
            "filesystem_id": "zfs:1:2",
            "storage": {"dataset": "zroot/lilly"},
        }
        old: dict[str, object] = {
            "host_id": "old-host",
            "state_dir": "/state",
            "vm_state_dir": "/vms",
            "network_state_dir": "/network",
            "pools": [pool],
        }
        previous = {
            "lilly": {
                "binding": {"hostId": "old-host"},
                "owner": old,
                "transferStateDirectory": "/transfers",
            }
        }
        for pools in [[pool, {**pool, "id": "duplicate"}], [{**pool, "path": "/other"}]]:
            with self.subTest(pools=pools):
                new = {**old, "host_id": "new-host", "pools": pools}
                candidate = {
                    "lilly": {
                        "binding": {"hostId": "new-host"},
                        "owner": new,
                        "transferStateDirectory": "/transfers",
                    }
                }
                with self.assertRaisesRegex(
                    ValueError, "duplicate Lilly pool|physical ownership changed"
                ):
                    enrollment.rebind_empty_lilly(
                        previous,
                        candidate,
                        cast(enrollment.Deployment, SimpleNamespace()),
                        cast(enrollment.HostRemote, SimpleNamespace()),
                        "a" * 40,
                    )
        changed_binding = {
            "lilly": {
                "binding": {"hostId": "new-host", "egressInterface": "other"},
                "owner": {**old, "host_id": "new-host"},
                "transferStateDirectory": "/transfers",
            }
        }
        with self.assertRaisesRegex(ValueError, "physical binding changed"):
            enrollment.rebind_empty_lilly(
                previous,
                changed_binding,
                cast(enrollment.Deployment, SimpleNamespace()),
                cast(enrollment.HostRemote, SimpleNamespace()),
                "a" * 40,
            )

    def test_explicit_lilly_rebind_refuses_durable_workload_state(self) -> None:
        old = {
            "host_id": "old-host",
            "state_dir": "/state",
            "vm_state_dir": "/vms",
            "network_state_dir": "/network",
            "pools": [],
        }
        new = {**old, "host_id": "new-host"}
        old_binding = {
            "hostId": "old-host",
            "egressInterface": "eth0",
            "protectedCidrs": [],
        }
        previous = {
            "lilly": {
                "binding": old_binding,
                "owner": old,
                "transferStateDirectory": "/transfers",
            }
        }
        candidate = {
            "lilly": {
                "binding": {**old_binding, "hostId": "new-host"},
                "owner": new,
                "transferStateDirectory": "/transfers",
                "release": "/release",
            }
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original_path = Path

            def local_path(value: str | Path) -> Path:
                path = original_path(value)
                if path.is_relative_to(root):
                    return path
                return root / str(path).lstrip("/") if path.is_absolute() else path

            for path in [
                "/state/actors",
                "/state/commands",
                "/vms",
                "/network",
                "/transfers",
                "/var/lib/lilly",
            ]:
                local_path(path).mkdir(parents=True, exist_ok=True)
            local_path("/state/actors/retained").write_text("fixture")
            local_path("/var/lib/lilly/owner.json").write_text(
                json.dumps({"version": 1, "machine_id": "machine", **old})
            )
            calls: list[list[str]] = []
            units_active = False

            class Deployment:
                def command(
                    self, args: list[str], *, capture: bool = False, timeout: float = 7200
                ) -> str:
                    del capture, timeout
                    calls.append(args)
                    if args[:3] == ["systemctl", "show", "--property=ActiveState"]:
                        return "active"
                    if args[:2] == ["systemctl", "list-units"] and units_active:
                        return "lilly-vm-retained.service loaded active running"
                    return ""

            with (
                patch.object(enrollment, "Path", side_effect=local_path),
                self.assertRaisesRegex(ValueError, "durable workload state"),
            ):
                enrollment.rebind_empty_lilly(
                    previous,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                    "a" * 40,
                )
            self.assertIn(["systemctl", "start", "lilly.service"], calls)
            local_path("/state/actors/retained").unlink()
            units_active = False
            local_path("/network/guest-retained.json").write_text("fixture")
            calls.clear()
            with (
                patch.object(enrollment, "Path", side_effect=local_path),
                self.assertRaisesRegex(ValueError, "guest network state remains"),
            ):
                enrollment.rebind_empty_lilly(
                    previous,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                    "a" * 40,
                )
            self.assertIn(["systemctl", "start", "lilly.service"], calls)
            local_path("/network/guest-retained.json").unlink()
            units_active = True
            calls.clear()
            with (
                patch.object(enrollment, "Path", side_effect=local_path),
                self.assertRaisesRegex(ValueError, "execution remains active"),
            ):
                enrollment.rebind_empty_lilly(
                    previous,
                    candidate,
                    cast(enrollment.Deployment, Deployment()),
                    cast(enrollment.HostRemote, SimpleNamespace(atomic=remote.atomic)),
                    "a" * 40,
                )
            self.assertIn(["systemctl", "start", "lilly.service"], calls)

    def test_explicit_enrollment_resource_baseline_without_prior_receipt(self) -> None:
        installed = host()
        installed["platform"] = "hetzner"
        installed["storage"]["quotaBytes"] = 100000
        policy = ResourcePolicyRecord(
            version=1,
            cpuCores=2,
            memoryMiB=1024,
            arcMaxBytes=512 * 1048576,
            quotaBytes=100000,
            dataset="zroot/lilly",
            zpoolGuid="1",
            datasetGuid="2",
        )
        candidate: CandidateRecord = {
            "resourcePolicy": policy,
            "lilly": {
                "binding": {"guestCpuCores": 2, "guestMemoryMiB": 1024},
                "owner": {
                    "pools": [
                        {
                            "storage": {
                                "dataset": "zroot/lilly",
                                "zpool_guid": "1",
                                "dataset_guid": "2",
                            }
                        }
                    ]
                },
            },
            "installationBinding": {
                "storage": {"quotaBytes": 100000},
                "effective": {
                    "pools": {"zroot": {"datasets": {"lilly": {"options": {"quota": "100000"}}}}}
                },
            },
        }
        config = {"resourcePolicyHelper": resource_helper, "other": "preserved"}
        observed = {"poolGuid": "1", "datasetGuid": "2"}
        self.assertEqual(
            enrollment.enrollment_configuration(config, {}, candidate, installed, observed),
            {"other": "preserved"},
        )
        self.assertIn("resourcePolicyHelper", config)
        self.assertEqual(
            enrollment.enrollment_configuration(config, candidate, candidate, installed, observed),
            {"other": "preserved"},
        )
        for field in ("guestCpuCores", "guestMemoryMiB", "arcMaxMiB"):
            changed = copy.deepcopy(installed)
            changed["budgets"][field] += 1
            with self.assertRaises(ValueError):
                enrollment.enrollment_configuration(config, {}, candidate, changed, observed)
        for field in ("poolGuid", "datasetGuid"):
            with self.assertRaises(ValueError):
                enrollment.enrollment_configuration(
                    config, {}, candidate, installed, dict(observed, **{field: "9"})
                )
        previous = copy.deepcopy(candidate)
        previous["resourcePolicy"]["memoryMiB"] += 1
        with self.assertRaises(ValueError):
            enrollment.enrollment_configuration(config, previous, candidate, installed, observed)
        with self.assertRaises(ValueError):
            enrollment.enrollment_configuration(config, previous, {}, installed, observed)

    def test_administrative_and_installer_ports_keep_pinned_transport(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.touch()
            args = SimpleNamespace(
                target="root@example",
                identity=str(path),
                known_hosts=str(path),
                ssh_port=2222,
                installer_ssh_port=22,
            )
            connection = cli.connection(args)
            self.assertEqual(connection[connection.index("-p") + 1], "2222")
            self.assertIn("StrictHostKeyChecking=yes", connection)
            self.assertEqual(cli.ssh_port(cli.installer_connection(args)), 22)
            with patch.object(cli, "run") as run:
                cli.anywhere(
                    args,
                    {"install": "install", "system": "system", "kexec": "kexec", "host": host()},
                    "kexec",
                    args.target,
                )
            command = run.call_args.args[0]
            self.assertEqual(command[command.index("--ssh-port") + 1], "2222")
            self.assertEqual(command[command.index("--post-kexec-ssh-port") + 1], "22")
            self.assertNotIn("--kexec-extra-flags", command)
            for invalid in [0, -1, 65536, True, "2222"]:
                args.ssh_port = invalid
                with self.assertRaises(cli.Failure):
                    cli.connection(args)

    def test_installation_rejects_changed_ports_before_contacting_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            p = {"version": 1, "target": "root@example", "sshPort": 2222, "installerSshPort": 22}
            path = Path(directory) / "plan"
            path.write_text(json.dumps(p))
            for source, installer in [(22, 22), (2222, 2223)]:
                args = SimpleNamespace(
                    plan=str(path),
                    target=p["target"],
                    erase=cli.digest(p),
                    ssh_port=source,
                    installer_ssh_port=installer,
                )
                with patch.object(cli, "probe") as probe, self.assertRaises(cli.Failure):
                    cli.install(args)
                probe.assert_not_called()

    def test_controller_and_serial_classification(self) -> None:
        self.assertEqual(remote.classify("Amazon Elastic Block Store", "vol0123", "nvme"), "ebs")
        self.assertEqual(
            remote.classify("Amazon Elastic Block Store", "vol-0123", "unknown"), "ebs"
        )
        self.assertEqual(
            remote.classify("Amazon EC2 NVMe Instance Storage", "AWS123", "nvme"), "local-nvme"
        )
        for model, serial, transport in [
            ("Amazon Elastic Block Store", "AWS123", "nvme"),
            ("Amazon EC2 NVMe Instance Storage", "vol0123", "nvme"),
            ("Amazon EC2 NVMe Instance Storage", "AWS123", "sata"),
            ("Amazon Unknown", "123", "nvme"),
        ]:
            with self.assertRaises(ValueError):
                remote.classify(model, serial, transport)

    def test_virtual_disks_are_not_storage_but_unidentified_disk_is_rejected(self) -> None:
        floppy: dict[str, object] = {
            "name": "fd0",
            "path": "/dev/fd0",
            "type": "disk",
            "size": 4096,
        }
        empty_nbd = dict(floppy, name="nbd0", path="/dev/nbd0", size=0)
        active_nbd = dict(
            floppy,
            name="nbd15",
            path="/dev/nbd15",
            size=1099511627776,
            children=[{"name": "nbd15p1", "type": "part"}],
        )
        with (
            patch.object(
                remote,
                "run",
                side_effect=[
                    json.dumps({"blockdevices": [floppy, empty_nbd, active_nbd]}),
                    "no pools available",
                ],
            ),
            patch.object(
                remote, "Path", return_value=SimpleNamespace(read_text=lambda: "fixture-machine")
            ),
        ):
            self.assertEqual(remote.inventory()["disks"], [])
        unidentified = dict(floppy, name="sda", path="/dev/sda")
        with (
            patch.object(
                remote,
                "run",
                side_effect=[json.dumps({"blockdevices": [unidentified]}), "no pools available"],
            ),
            patch.object(remote, "Path", return_value=SimpleNamespace(glob=lambda _: [])),
            self.assertRaisesRegex(ValueError, "stable serial"),
        ):
            remote.inventory()

    def test_complete_local_nvme_and_ebs_exclusion(self) -> None:
        h = host()
        cli.validate(h)
        for guests in [["local1"], ["local1", "local2", "other-ebs"], ["local1", "local1"], []]:
            h["storage"]["guests"] = guests
            with self.assertRaises(cli.Failure):
                cli.validate(h)

    def test_budgets_and_shared_quota_required(self) -> None:
        for field in host()["budgets"]:
            h = host()
            # Deliberately invalid None probes the module's budget requirement.
            cast("dict[str, int | None]", h["budgets"])[field] = None
            with self.assertRaises(cli.Failure):
                cli.validate(h)
        # The retired logical commitment cap is refused rather than ignored.
        h = host()
        cast("dict[str, int]", h["budgets"])["logicalBytes"] = 100000
        with self.assertRaises(cli.Failure):
            cli.validate(h)
        h = host()
        h["platform"] = "hetzner"
        h["storage"].update(system=["local1", "local2"], guests=[])
        with self.assertRaises(cli.Failure):
            cli.validate(h)
        h["storage"]["quotaBytes"] = 1234
        cli.validate(h)

    def test_hcloud_single_zfs_root_without_guest_storage(self) -> None:
        def cloud() -> HostRecord:
            h = host()
            h["platform"] = "hcloud"
            h["inventory"]["disks"] = [disk("root", "physical")]
            h["storage"].update(system=["root"], guests=[], quotaBytes=None)
            h["budgets"] = {"arcMaxMiB": 512}
            return h

        cli.validate(cloud())
        h = cloud()
        h["storage"]["quotaBytes"] = 0
        cli.validate(h)
        h = cloud()
        h["inventory"]["disks"].append(disk("second", "physical"))
        h["storage"]["system"] = ["root", "second"]
        with self.assertRaisesRegex(cli.Failure, "one system disk"):
            cli.validate(h)
        h = cloud()
        h["inventory"]["disks"].append(disk("local1", "physical"))
        h["storage"]["guests"] = ["local1"]
        with self.assertRaisesRegex(cli.Failure, "one system disk"):
            cli.validate(h)
        h = cloud()
        h["storage"]["quotaBytes"] = 1234
        with self.assertRaisesRegex(cli.Failure, "one system disk"):
            cli.validate(h)
        h = cloud()
        # A Lilly role is refused on a platform without reviewed KVM.
        cast("dict[str, object]", h)["lilly"] = {"controlPlane": "https://example.test"}
        with self.assertRaisesRegex(cli.Failure, "Lilly"):
            cli.validate(h)
        h = cloud()
        h["budgets"] = {"arcMaxMiB": 512, "guestCpuCores": 1, "guestMemoryMiB": 1024}
        with self.assertRaisesRegex(cli.Failure, "budgets"):
            cli.validate(h)

    def test_hcloud_discovery_keeps_addresses_out_of_the_candidate(self) -> None:
        facts = {
            "inventory": host()["inventory"],
            "firmware": "uefi",
            "hostKey": "ssh-ed25519 AAAAfixture",
            "addresses": [
                {"ifname": "lo", "address": "00:00:00:00:00:00", "addr_info": []},
                {
                    "ifname": "eth0",
                    "address": "92:00:00:00:00:01",
                    "addr_info": [
                        {"local": "192.0.2.7", "prefixlen": 32, "scope": "global"},
                        {"local": "2001:db8:7::1", "prefixlen": 64, "scope": "global"},
                    ],
                },
            ],
            "routes": [
                {"dev": "eth0", "dst": "default", "gateway": "172.31.1.1", "prefsrc": "192.0.2.7"},
                {"dev": "eth0", "dst": "192.0.2.7", "prefsrc": "192.0.2.7", "type": "local"},
                {"dev": "eth0", "dst": "2001:db8:7::/64"},
                {"dev": "eth0", "dst": "default", "gateway": "fe80::1"},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate.json"
            args = SimpleNamespace(platform="hcloud", name="cloudy", output=str(output))
            with patch.object(cli, "probe", return_value=facts):
                cli.discover(args)
            text = output.read_text()
        candidate = json.loads(text)
        for literal in ("192.0.2.7", "2001:db8"):
            self.assertNotIn(literal, text)
        uplink = candidate["network"]["10-eth0"]
        self.assertEqual(uplink["networkConfig"]["DHCP"], "ipv4")
        self.assertNotIn("Address", uplink["networkConfig"])
        # The fleet tunnel is IPv4-only, so no IPv6 is proposed either.
        self.assertEqual(uplink["networkConfig"]["LinkLocalAddressing"], "no")
        self.assertNotIn("routes", uplink)
        self.assertEqual(candidate["discovery"]["routes"], [{"dev": "eth0", "dst": "default"}])

    def test_hcloud_installer_forces_the_legacy_kexec_syscall(self) -> None:
        h = host()
        for platform, flags in (
            ("hcloud", ["--kexec-extra-flags", "--kexec-syscall"]),
            ("ec2", []),
        ):
            h["platform"] = platform
            self.assertEqual(cli.kexec_flags(cast("cli.Host", h)), flags)

    def test_hcloud_guard_skips_kvm_but_lilly_platforms_require_it(self) -> None:
        h = host()
        for platform, calls in (("hcloud", 0), ("ec2", 1)):
            h["platform"] = platform
            with (
                patch.object(remote, "inventory", return_value=copy.deepcopy(h["inventory"])),
                patch.object(remote, "firmware", return_value="uefi"),
                patch.object(remote, "kvm") as probed,
                patch.object(sys, "argv", ["remote", "guard"]),
                patch.object(sys, "stdin", __import__("io").StringIO(json.dumps(h))),
                patch("builtins.print"),
            ):
                remote.main()
            self.assertEqual(probed.call_count, calls)

    def test_reordered_devices_match(self) -> None:
        expected = host()["inventory"]
        actual = copy.deepcopy(expected)
        actual["disks"].reverse()
        for i, d in enumerate(actual["disks"]):
            d["path"] = f"/dev/nvme{i + 8}n1"
        remote.match(expected, actual, erase=True)

    def test_added_missing_replaced_and_resized_disks_fail(self) -> None:
        expected = host()["inventory"]
        for mutate in [
            lambda a: a["disks"].pop(),
            lambda a: a["disks"].append(disk("new", "local-nvme")),
            lambda a: a["disks"][0].update(serial="replacement"),
            lambda a: a["disks"][0].update(size=101),
            lambda a: a.update(machine="replacement"),
            lambda a: a["disks"][0].update(aliases=[]),
        ]:
            actual = copy.deepcopy(expected)
            mutate(actual)
            with self.assertRaises(ValueError):
                remote.match(expected, actual, erase=True)

    def test_active_disks_rejected_only_at_erasure(self) -> None:
        expected = host()["inventory"]
        actual = copy.deepcopy(expected)
        actual["disks"][0]["active"] = True
        remote.match(expected, actual)
        with self.assertRaises(ValueError):
            remote.match(expected, actual, erase=True)

    def test_tampered_plan_requires_new_authorization(self) -> None:
        p = {"version": 1, "host": host(), "target": "root@example"}
        old = cli.digest(p)
        p["host"]["network"] = {"changed": True}
        self.assertNotEqual(cli.digest(p), old)

    def test_all_installation_binding_changes_rejected_before_commands(self) -> None:
        original = {
            "platform": "ec2",
            "firmware": "uefi",
            "identity": {"hostId": "12345678"},
            "storage": {"system": ["root"]},
        }
        for key in original:
            changed = copy.deepcopy(original)
            changed[key] = "changed"
            runner = object.__new__(updater.Deployment)
            runner.config = {}
            runner.candidate = {"installationBinding": changed}
            with self.assertRaisesRegex(updater.UpdateError, "installation_binding_change"):
                runner.preflight({"installationBinding": original})
        runner.candidate = {}
        with self.assertRaises(updater.UpdateError):
            runner.preflight({"installationBinding": original})

    def test_ordinary_update_still_rejects_lilly_authority_rebind(self) -> None:
        installation = {"platform": "hetzner"}
        runner = object.__new__(updater.Deployment)
        runner.config = {}
        runner.candidate = {
            "installationBinding": installation,
            "diagnosticPreflight": [],
            "marshall": None,
            "lilly": {"binding": {"hostId": "new-host"}},
        }
        with self.assertRaisesRegex(updater.UpdateError, "lilly_binding_change"):
            runner.preflight(
                {
                    "installationBinding": installation,
                    "consumers": [],
                    "marshall": None,
                    "lilly": {"binding": {"hostId": "old-host"}},
                }
            )

    def test_lilly_binding_compares_the_effective_protected_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            primary = Path(directory) / "primary"
            primary.write_text("192.0.2.10\n")
            other = Path(directory) / "other"
            other.write_text("198.51.100.7")
            malformed = Path(directory) / "malformed"
            malformed.write_text("192.0.2.010")
            literal = {
                "hostId": "host",
                "protectedCidrs": ["10.90.0.0/24", "192.0.2.10/32"],
                "guestCpuCores": 2,
            }
            legacy = {k: v for k, v in literal.items() if k != "protectedAddressFiles"}
            moved = {
                "hostId": "host",
                "protectedCidrs": ["10.90.0.0/24"],
                "protectedAddressFiles": [str(primary)],
                "guestCpuCores": 2,
            }
            # A literal moved into an equal runtime file, and a binding that
            # predates the key, keep the effective policy.
            self.assertTrue(updater.lilly_bindings_equivalent(legacy, moved))
            self.assertTrue(
                updater.lilly_bindings_equivalent(legacy, {**literal, "protectedAddressFiles": []})
            )
            for changed in (
                {**moved, "protectedAddressFiles": [str(other)]},
                {**moved, "protectedAddressFiles": [str(malformed)]},
                {**moved, "protectedAddressFiles": [str(Path(directory) / "missing")]},
                {**moved, "guestCpuCores": 4},
                {**moved, "hostId": "other"},
            ):
                self.assertFalse(updater.lilly_bindings_equivalent(legacy, changed))
            # Identical runtime-only bindings stay equal even before the
            # files exist, so ordinary updates never depend on decryption.
            unread = {**moved, "protectedAddressFiles": [str(Path(directory) / "missing")]}
            self.assertTrue(updater.lilly_bindings_equivalent(unread, copy.deepcopy(unread)))
            self.assertEqual(
                enrollment.protected_networks(moved), ["10.90.0.0/24", "192.0.2.10/32"]
            )
            self.assertEqual(
                enrollment.stable_binding({"binding": legacy}),
                enrollment.stable_binding({"binding": moved}),
            )
            with self.assertRaisesRegex(ValueError, "runtime protected address"):
                enrollment.protected_networks({**moved, "protectedAddressFiles": [str(malformed)]})

            runner = object.__new__(updater.Deployment)
            runner.config = {}
            installation = {"platform": "hetzner"}
            runner.candidate = {
                "installationBinding": installation,
                "diagnosticPreflight": [],
                "marshall": None,
                "lilly": {"binding": moved},
            }
            previous = {
                "installationBinding": installation,
                "consumers": [],
                "marshall": None,
                "lilly": {"binding": legacy},
            }
            # The binding passes, so preflight proceeds to the owner baseline.
            with (
                patch.object(Path, "exists", return_value=False),
                self.assertRaisesRegex(updater.UpdateError, "missing_lilly_baseline"),
            ):
                runner.preflight(previous)
            runner.candidate["lilly"] = {
                "binding": {**moved, "protectedAddressFiles": [str(other)]}
            }
            with self.assertRaisesRegex(updater.UpdateError, "lilly_binding_change"):
                runner.preflight(previous)

    def test_resource_preflight_uses_closed_failure_reason(self) -> None:
        installation = {"platform": "hetzner"}

        class FailedTransition:
            def prepare(self) -> None:
                raise ValueError("private resource detail")

            def apply(self) -> None:
                raise AssertionError("preflight must not apply resources")

        helper = SimpleNamespace(
            compatible=lambda previous, candidate: True,
            Transition=lambda *args: FailedTransition(),
            failure_reason=lambda error: "resource_receipt_mismatch",
        )
        runner = object.__new__(updater.Deployment)
        runner.config = {"resourcePolicyHelper": "resource-helper"}
        runner.candidate = {
            "installationBinding": installation,
            "diagnosticPreflight": [],
            "healthUnits": [],
            "marshall": None,
            "lilly": None,
            "resourcePolicy": {"version": 1},
        }
        with (
            patch.object(updater, "load_secrets", return_value=helper),
            self.assertRaisesRegex(updater.UpdateError, "resource_receipt_mismatch"),
        ):
            runner.preflight(
                {
                    "installationBinding": installation,
                    "consumers": [],
                    "healthUnits": [],
                    "marshall": None,
                    "lilly": None,
                }
            )

    def test_missing_baseline_cannot_be_enrolled(self) -> None:
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(remote, "storage", return_value={}),
            patch.object(
                remote, "Path", side_effect=lambda path: Path(directory) / Path(path).name
            ),
            self.assertRaises(ValueError),
        ):
            remote.verify(host())

    def test_lost_pool_guid_cannot_reuse_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "storage.json"
            base.write_text(json.dumps({"poolGuid": "old"}))
            with (
                patch.object(remote, "storage", return_value={"poolGuid": "new"}),
                patch.object(
                    remote, "Path", side_effect=lambda path: Path(directory) / Path(path).name
                ),
                self.assertRaises(ValueError),
            ):
                remote.verify(host(), receipt=True)

    def test_install_failure_boundaries_never_skip_guard(self) -> None:
        for failure in ["build", "identity", "guard", "format"]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                declaration = root / "fleet/hosts/example/host.json"
                declaration.parent.mkdir(parents=True)
                declaration.write_text(json.dumps(host()))
                tar = root / "image.tar.gz"
                tar.touch()
                p: PlanRecord = {
                    "version": 1,
                    "host": host(),
                    "target": "root@example",
                    "sourceKey": "source-key",
                    "sshPort": 2222,
                    "installerSshPort": 2223,
                    "repository": cli.REPOSITORY,
                    "revision": "a" * 40,
                    "system": "/nix/store/system",
                    "install": "/nix/store/install",
                    "kexec": str(tar),
                }
                plan = root / "plan.json"
                plan.write_text(json.dumps(p))
                args = SimpleNamespace(
                    plan=str(plan),
                    erase=cli.digest(p),
                    target=p["target"],
                    ssh_port=2222,
                    installer_ssh_port=2223,
                )
                phases: list[str] = []

                def build(
                    _root: Path,
                    _host: HostRecord,
                    attr: str,
                    failure: str = failure,
                    p: PlanRecord = p,
                ) -> str:
                    if failure == "build":
                        raise cli.Failure("build failed")
                    return p["system"] if attr == "base" else p["install"]

                def probe(
                    _args: SimpleNamespace,
                    action: str = "discover",
                    *rest: object,
                    failure: str = failure,
                    p: PlanRecord = p,
                ) -> dict[str, object]:
                    self.assertEqual(cli.ssh_port(_args), 2222 if action == "discover" else 2223)
                    if action == "discover":
                        return {
                            "inventory": host()["inventory"],
                            "firmware": "uefi",
                            "hostKey": "wrong" if failure == "identity" else p["sourceKey"],
                        }
                    if action == "guard" and failure == "guard":
                        raise ValueError("changed inventory")
                    return {}

                def anywhere(
                    _args: SimpleNamespace,
                    _plan: object,
                    phase: str,
                    _target: str,
                    phases: list[str] = phases,
                ) -> None:
                    self.assertEqual(cli.ssh_port(_args), 2222 if phase == "kexec" else 2223)
                    phases.append(phase)
                    if phase == "disko,install":
                        raise cli.Failure("format failed")

                with (
                    patch.object(cli, "published", return_value=nullcontext(root)),
                    patch.object(cli, "build", side_effect=build),
                    patch.object(cli, "buck2_build", return_value=str(root)),
                    patch.object(cli, "run", return_value=str(root).encode()),
                    patch.object(cli, "probe", side_effect=probe),
                    patch.object(cli, "anywhere", side_effect=anywhere),
                    self.assertRaises(cli.Failure),
                ):
                    cli.install(args)
                self.assertEqual(
                    phases,
                    []
                    if failure in ("build", "identity")
                    else ["kexec"]
                    if failure == "guard"
                    else ["kexec", "disko,install"],
                )
                state = json.loads(Path(str(plan) + ".state.json").read_text())
                self.assertNotEqual(state["phase"], "complete")
                self.assertEqual(state["plan"], cli.digest(p))

    def test_published_builds_name_fleet_host_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(cli.Failure, "fleet_host"):
                cli.build(root, "example", "base")
            package = root / "fleet/hosts/example"
            package.mkdir(parents=True)
            (package / "BUCK").write_text("fleet_host()\n")
            built: list[str] = []

            def buck2_build(_root: Path, target: str) -> str:
                built.append(target)
                return "/nix/store/" + "a" * 32 + "-system"

            with patch.object(cli, "buck2_build", side_effect=buck2_build):
                for target in ("base", "install", "system", "binding", "enrollment"):
                    cli.build(root, "example", target)
            self.assertEqual(
                built,
                [
                    f"//fleet/hosts/example:{t}"
                    for t in ("base", "install", "system", "binding", "enrollment")
                ],
            )
            with self.assertRaises(cli.Failure):
                cli.build(root, "example-base", "base")

    def test_buck2_build_reads_the_reported_store_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            out = root / "out"
            store = "/nix/store/" + "b" * 32 + "-overalls-host-install"
            out.write_text(store + "\n")
            target = "//fleet/hosts/example:install"
            calls: list[list[str | Path]] = []

            def run(args: list[str | Path], *_rest: object, **_kwargs: object) -> bytes:
                calls.append(args)
                if args[0] == "git":
                    return b"c" * 40 + b"\n"
                return f"root{target} {out}\n".encode()

            with patch.object(cli, "run", side_effect=run):
                self.assertEqual(cli.buck2_build(root, target), store)
            self.assertIn("overalls.revision=" + "c" * 40, [str(a) for a in calls[1]])
            out.write_text("not a store path\n")
            with patch.object(cli, "run", side_effect=run), self.assertRaises(cli.Failure):
                cli.buck2_build(root, target)

            def other(args: list[str | Path], *_rest: object, **_kwargs: object) -> bytes:
                return b"c" * 40 if args[0] == "git" else b"root//other:x /tmp/x\n"

            with patch.object(cli, "run", side_effect=other), self.assertRaises(cli.Failure):
                cli.buck2_build(root, target)

    def test_failed_buck2_reports_a_bounded_redacted_tail(self) -> None:
        secret = "nsc_" + "s" * 40
        noise = "\n".join(f"line {n}" for n in range(500))
        script = (
            f"import sys; sys.stderr.write({noise!r} + '\\nAction failed {secret}\\n'); sys.exit(1)"
        )
        with (
            patch.dict(os.environ, {"NAMESPACE_RBE_TOKEN": secret}),
            self.assertRaises(cli.Failure) as raised,
        ):
            cli.run([sys.executable, "-c", script], diagnostics=True)
        message = str(raised.exception)
        self.assertIn("Action failed [redacted]", message)
        self.assertNotIn(secret, message)
        self.assertNotIn("line 0\n", message)
        self.assertLessEqual(len(message.splitlines()), cli.DIAGNOSTIC_LINES + 1)
        with self.assertRaises(cli.Failure) as quiet:
            cli.run([sys.executable, "-c", script])
        self.assertEqual(str(quiet.exception), "Command failed: " + Path(sys.executable).name)

    def test_encryption_uses_shared_key_in_existing_git_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            declaration = root / "fleet/hosts/example/host.json"
            declaration.parent.mkdir(parents=True)
            h = host()
            h["identity"]["sshKeys"] = ["ssh-ed25519 fixture"]
            declaration.write_text(json.dumps(h))
            key = Path(directory) / "shared"
            key.write_text("shared-private-fixture")
            key.chmod(0o600)
            args = SimpleNamespace(root=str(root), deploy_key=str(key), host="example")
            payloads: list[object] = []

            def command(arguments: list[str], payloads: list[object] = payloads) -> bytes:
                payloads.append(json.loads(Path(arguments[-1]).read_text()))
                self.assertIn("example-git", arguments)
                return b""

            with (
                patch.object(cli, "probe", return_value={"hostKey": "ssh-ed25519 fixture"}),
                patch.object(cli, "run", side_effect=command),
            ):
                cli.encrypt(args)
            self.assertEqual(
                payloads,
                [{"overalls-git": {"production": {"GIT_DEPLOY_KEY": "shared-private-fixture"}}}],
            )

    def test_enrollment_failures_keep_polling_gated_and_identity_intact(self) -> None:
        for failure in ["stage", "preflight", "git", "migrate", "activate", "health", None]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binding: BindingRecord = {"platform": "ec2", "identity": {"sshKeys": []}}
                candidate = copy.deepcopy(binding)
                candidate["identity"]["sshKeys"] = ["ssh-ed25519 fixture"]
                files: dict[str, object] = {
                    "config.json": {"secretHelper": "helper", "repository": cli.REPOSITORY},
                    "bundle/manifest.json": {"installationBinding": candidate},
                    "run/current-system/overalls-deployment.json": {"installationBinding": binding},
                    "etc/overalls-host.json": host(),
                    "var/lib/overalls-host/enrollment.json": {"old": True},
                }
                for name, value in files.items():
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(json.dumps(value))
                (root / "bundle/system").mkdir()
                events: list[object] = []

                def operation(
                    name: str, failure: str | None = failure, events: list[object] = events
                ) -> None:
                    events.append(name)
                    if name == failure:
                        raise RuntimeError("injected boundary failure")

                class Deployment:
                    def __init__(self, config: object) -> None:
                        self.secrets = SimpleNamespace(safe_directory=lambda p: None)

                    def command(
                        self, args: list[str], events: list[object] = events, **kwargs: object
                    ) -> None:
                        events.append(args)
                        if args[0] == "env":
                            operation("git")

                    def save(self, events: list[object] = events, **values: object) -> None:
                        events.append(values)

                    def step(self, name: str, events: list[object] = events) -> None:
                        events.append(name)

                    def stage(self, events: list[object] = events) -> None:
                        operation("stage")

                    def preflight(self, previous: object, events: list[object] = events) -> None:
                        operation("preflight")

                    def selected(self, name: str) -> str:
                        return "/private/staged-key"

                    def migrate(self, events: list[object] = events) -> None:
                        operation("migrate")

                    def activate(self, bundle: object, events: list[object] = events) -> None:
                        operation("activate")

                    def verify(self, bundle: object, events: list[object] = events) -> None:
                        operation("health")

                    def failed(self, name: str, events: list[object] = events) -> None:
                        events.append(name)

                fake = SimpleNamespace(
                    STATE=root / "state",
                    RUNTIME=root / "runtime",
                    Deployment=Deployment,
                    load_secrets=lambda _: SimpleNamespace(safe_directory=lambda p: None),
                )
                checks = SimpleNamespace(
                    verify=lambda h: {"hostKey": "ssh-ed25519 fixture"}, atomic=remote.atomic
                )

                def local_path(value: str | Path, root: Path = root) -> Path:
                    path = Path(value)
                    return (
                        root / str(path).lstrip("/")
                        if str(path).startswith(("/run/", "/etc/", "/var/"))
                        else path
                    )

                args = [
                    "enrollment",
                    "updater",
                    str(root / "config.json"),
                    str(root / "bundle"),
                    "remote",
                    "a" * 40,
                ]
                with (
                    patch.object(enrollment, "load", side_effect=[fake, checks]),
                    patch.object(enrollment, "Path", side_effect=local_path),
                    patch.object(sys, "argv", args),
                    patch.object(
                        enrollment.subprocess,
                        "check_output",
                        return_value="ssh-ed25519 fixture generated@host\n",
                    ),
                ):
                    if failure:
                        with self.assertRaises(RuntimeError):
                            enrollment.main()
                    else:
                        enrollment.main()
                receipt = root / "var/lib/overalls-host/enrollment.json"
                progress = root / "var/lib/overalls-host/enrollment-in-progress.json"
                start = ["systemctl", "start", "overalls-auto-update.timer"]
                self.assertEqual(receipt.exists(), failure is None)
                self.assertEqual(progress.exists(), failure is not None)
                self.assertEqual(start in events, failure is None)
                self.assertIn(
                    [
                        "systemctl",
                        "mask",
                        "--runtime",
                        "--now",
                        "overalls-auto-update.timer",
                        "overalls-auto-update.service",
                    ],
                    events,
                )
                self.assertEqual(
                    json.loads((root / "run/current-system/overalls-deployment.json").read_text())[
                        "installationBinding"
                    ],
                    binding,
                )
                if failure:
                    self.assertNotIn(
                        [
                            "systemctl",
                            "unmask",
                            "--runtime",
                            "overalls-auto-update.timer",
                            "overalls-auto-update.service",
                        ],
                        events,
                    )
                self.assertFalse(any("format" in str(event) for event in events))

    def test_guard_cannot_format_after_changed_inventory(self) -> None:
        h = host()
        changed = copy.deepcopy(h["inventory"])
        changed["disks"].pop()
        with (
            patch.object(remote, "inventory", return_value=changed),
            patch.object(remote, "firmware", return_value="uefi"),
            patch.object(sys, "argv", ["remote", "guard"]),
            patch.object(sys, "stdin", __import__("io").StringIO(json.dumps(h))),
            self.assertRaises(ValueError),
        ):
            remote.main()


class UplinkRecovery(unittest.TestCase):
    """Install writes the copy the base system boots with; documentation addresses only."""

    MAC = "02:00:00:00:00:01"
    UPLINK: ClassVar["remote.Uplink"] = {
        "addresses": ["192.0.2.10/26", "192.0.2.20/26"],
        "gateway": "192.0.2.1",
        "routes": ["198.51.100.7"],
    }

    def host(self, uplink: bool = True) -> dict[str, object]:
        host: dict[str, object] = {
            "network": {"10-eth0": {"matchConfig": {"MACAddress": self.MAC}}}
        }
        if uplink:
            host["addresses"] = {"uplink": {"network": "10-eth0"}}
        return host

    def facts(self, routes: list[dict[str, object]] | None = None) -> dict[str, object]:
        return {
            "addresses": [
                {
                    "ifname": "lo",
                    "address": "00:00:00:00:00:00",
                    "addr_info": [{"local": "127.0.0.1", "prefixlen": 8, "scope": "host"}],
                },
                {
                    "ifname": "eth0",
                    "address": self.MAC,
                    "addr_info": [
                        {"local": "192.0.2.10", "prefixlen": 26, "scope": "global"},
                        {"local": "192.0.2.20", "prefixlen": 26, "scope": "global"},
                        {"local": "2001:db8::2", "prefixlen": 64, "scope": "global"},
                        {"local": "fe80::1", "prefixlen": 64, "scope": "link"},
                    ],
                },
            ],
            "routes": routes
            if routes is not None
            else [
                {"dst": "default", "gateway": "192.0.2.1", "dev": "eth0"},
                {"dst": "192.0.2.0/26", "gateway": "192.0.2.1", "dev": "eth0"},
                {"dst": "198.51.100.7", "gateway": "192.0.2.1", "dev": "eth0"},
                {"dst": "192.0.2.1", "dev": "eth0", "scope": "link"},
                {"dst": "192.0.2.10", "dev": "eth0", "table": "local", "type": "local"},
                {"dst": "default", "gateway": "fe80::1", "dev": "eth0"},
            ],
        }

    def test_facts_select_the_declared_interface_ipv4_and_host_routes(self) -> None:
        self.assertEqual(cli.uplink_facts(self.host(), self.facts()), self.UPLINK)
        self.assertIsNone(cli.uplink_facts(self.host(uplink=False), self.facts()))

    def test_facts_refuse_missing_interface_or_ambiguous_gateway(self) -> None:
        moved = self.host()
        moved["network"] = {"10-eth0": {"matchConfig": {"MACAddress": "02:00:00:00:00:09"}}}
        with self.assertRaises(cli.Failure):
            cli.uplink_facts(moved, self.facts())
        ambiguous: list[list[dict[str, object]]] = [
            [],
            [
                {"dst": "default", "gateway": "192.0.2.1", "dev": "eth0"},
                {"dst": "default", "gateway": "192.0.2.2", "dev": "eth0"},
            ],
        ]
        for routes in ambiguous:
            with self.assertRaises(cli.Failure):
                cli.uplink_facts(self.host(), self.facts(routes))

    def test_install_copy_matches_the_runtime_uplink_drop_in(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = {
                "one": "192.0.2.10",
                "two": "192.0.2.20",
                "prefix": "26",
                "gateway": "192.0.2.1",
                "peer": "198.51.100.7",
            }
            for name, value in values.items():
                (Path(directory) / name).write_text(value + "\n")
            runtime = fleet_addresses.render(
                {"directory": directory, "names": {}, "uplink": None},
                {
                    "network": "10-eth0",
                    "addresses": ["one", "two"],
                    "prefix": "prefix",
                    "gateway": "gateway",
                    "hostRoutes": ["peer"],
                    "recoveryFile": "/unused",
                },
            )
        self.assertEqual(remote.uplink_drop_in(self.UPLINK), runtime)

    def test_install_copy_is_private_written_once_and_validated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "overalls-host" / "uplink.conf"
            with patch.object(remote, "UPLINK_RECOVERY", target):
                self.assertEqual(remote.install_uplink(self.UPLINK), {"addresses": 2, "routes": 1})
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
                with self.assertRaises(ValueError):
                    remote.install_uplink(self.UPLINK)
        for bad in (
            {**self.UPLINK, "gateway": "198.51.100.1"},
            {**self.UPLINK, "addresses": ["192.0.2.10/26", "198.51.100.10/26"]},
            {**self.UPLINK, "addresses": []},
            {**self.UPLINK, "routes": ["not-an-address"]},
        ):
            with self.assertRaises(ValueError):
                remote.uplink_drop_in(cast("remote.Uplink", bad))


class BaseInstallerSource(unittest.TestCase):
    """Install records only the authenticated operator source; documentation addresses only."""

    def install(self, directory: str, connection: str | None) -> Path:
        target = Path(directory) / "overalls-host" / "base-source"
        environment = {} if connection is None else {"SSH_CONNECTION": connection}
        with (
            patch.object(remote, "BASE_SOURCE", target),
            patch.dict(remote.os.environ, environment, clear=True),
        ):
            self.assertEqual(remote.install_base_source(), {"sources": 1})
        return target

    def test_source_is_private_written_once_and_holds_only_the_address(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = self.install(directory, "198.51.100.7 51234 192.0.2.10 22")
            self.assertEqual(target.read_text(), "198.51.100.7\n")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(ValueError):
                self.install(directory, "198.51.100.7 51234 192.0.2.10 22")

    def test_source_refuses_missing_ipv6_or_non_unicast_connections(self) -> None:
        for connection in (
            None,
            "",
            "2001:db8::7 51234 2001:db8::2 22",
            "127.0.0.1 51234 127.0.0.1 22",
            "0.0.0.0 51234 192.0.2.10 22",
            "169.254.0.7 51234 192.0.2.10 22",
            "not-an-address 51234 192.0.2.10 22",
        ):
            with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
                self.install(directory, connection)


if __name__ == "__main__":
    unittest.main()
