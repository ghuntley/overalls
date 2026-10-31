import json
import shlex
from typing import TypedDict


class ZFSStorageObservation(TypedDict):
    quota_bytes: int | None
    used_bytes: int
    logical_used_bytes: int
    compression_ratio: float


class ZFSChildObservation(TypedDict):
    physical_bytes: int


class ZFSObservation(TypedDict):
    storage: ZFSStorageObservation
    children: dict[str, ZFSChildObservation]
    total_bytes: int
    free_bytes: int


def zfs_fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        fields[key] = item
    return fields


def zfs_bytes(value: object) -> int:
    assert isinstance(value, int) and not isinstance(value, bool)
    assert 0 <= value <= 9_223_372_036_854_775_807
    return value


def zfs_observation(value: object) -> ZFSObservation:
    """@cc [owner:ghuntley,label:verification] native-zfs-observation-json-boundary
    Native probe output MUST validate nested objects, byte counts, optional quota
    and local compression diagnostics before physical assertions use them. A raw
    allocation key MUST be rejected before projecting the typed observation.
    """
    fields = zfs_fields(value)
    assert "allocations" not in fields
    storage_fields = zfs_fields(fields["storage"])
    quota = storage_fields["quota_bytes"]
    quota_bytes = None if quota is None else zfs_bytes(quota)
    assert quota_bytes is None or quota_bytes > 0
    ratio = storage_fields["compression_ratio"]
    assert isinstance(ratio, (int, float)) and not isinstance(ratio, bool)
    assert 0 < ratio <= 1_000_000
    children: dict[str, ZFSChildObservation] = {}
    for name, child_value in zfs_fields(fields["children"]).items():
        child_fields = zfs_fields(child_value)
        children[name] = {"physical_bytes": zfs_bytes(child_fields["physical_bytes"])}
    result: ZFSObservation = {
        "storage": {
            "quota_bytes": quota_bytes,
            "used_bytes": zfs_bytes(storage_fields["used_bytes"]),
            "logical_used_bytes": zfs_bytes(storage_fields["logical_used_bytes"]),
            "compression_ratio": float(ratio),
        },
        "children": children,
        "total_bytes": zfs_bytes(fields["total_bytes"]),
        "free_bytes": zfs_bytes(fields["free_bytes"]),
    }
    return result


# @cc [owner:ghuntley,label:verification] native-zfs-observation-scope
# This suite MUST exercise Lilly's native reader against real ZFS mutations. It
# MUST NOT count raw child usage as a durable ownership or guest lifecycle test.
storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
storage.succeed("zfs create -o mountpoint=/pool -o quota=2G tank/lilly")
storage.succeed("zfs-check remember")


def observe() -> ZFSObservation:
    # Sync pending accounting in the fixture. Production reads must withhold an
    # unstable tree; two equal reads do not freeze a pool or reserve any space.
    storage.succeed("zpool sync tank")
    return zfs_observation(json.loads(storage.succeed("zfs-check observe")))


with subtest("disposable test datasets require matching ownership and GUID before deletion"):
    storage.succeed("zfs-check fixture")


with subtest("native identity, mirror extents and quota accounting"):
    empty = observe()
    assert empty["storage"]["quota_bytes"] == 2 * 1024**3
    assert empty["total_bytes"] == empty["storage"]["quota_bytes"]
    assert not empty["children"]
    assert "allocations" not in empty
    storage.succeed("mkdir /alias /pool/subdir; mount --bind /pool /alias")
    storage.succeed("zfs-check reject-mount /alias", "zfs-check reject-mount /pool/subdir")
    storage.succeed("umount /alias; ln -s /pool /symlink")
    storage.succeed("zfs-check reject-mount /symlink")

with subtest("changing usage resamples to the latest tree while changed policy and identity fail"):
    storage.succeed("install -Dm0755 /etc/zfs-observation-fault /run/zfs-changing/bin/zfs")
    transient_child = "tank/lilly/vm-eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    storage.succeed(
        f"zfs create -o mountpoint=/pool/vms/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee {transient_child}"
    )
    for mode, action in [
        ("usage", "moving-observation"),
        ("quota", "reject-observation"),
        ("child-identity", "reject-observation"),
    ]:
        storage.succeed("rm -f /run/zfs-observation-changed; zpool sync tank")
        storage.succeed(f"ZFS_OBSERVATION_FAULT={mode} zfs-check {action}")
        storage.succeed("test -f /run/zfs-observation-changed")
        storage.succeed("rm -f /pool/fixture-growth; zfs set quota=2G tank/lilly")
        observe()
    storage.succeed(f"zfs destroy {transient_child}")

vm_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
child = f"tank/lilly/vm-{vm_id}"
disk = f"/pool/vms/{vm_id}/rootfs.ext4"
storage.succeed(f"zfs create -o mountpoint=/pool/vms/{vm_id} {child}")

with subtest("sparse size, compressible and incompressible growth"):
    storage.succeed(
        f"truncate -s 128M /run/source; cp --reflink=never --sparse=always /run/source {disk}; truncate -s 3G {disk}"
    )
    logical, blocks = map(int, storage.succeed(f"stat --printf='%s %b' {disk}").split())
    assert logical == 3 * 1024**3 and blocks * 512 < logical // 100
    sparse = observe()
    # Nonzero repeated bytes exercise LZ4; ZFS may elide all-zero blocks as holes.
    storage.succeed(
        f"dd if=/dev/zero bs=1M count=32 status=none | tr '\\000' A | dd of={disk} bs=1M conv=notrunc,fsync status=none"
    )
    compressed = observe()
    assert compressed["storage"]["logical_used_bytes"] > compressed["storage"]["used_bytes"], (
        compressed
    )
    assert compressed["storage"]["compression_ratio"] > 1
    assert compressed["children"][child]["physical_bytes"] < 32 * 1024**2
    storage.succeed(
        f"dd if=/dev/urandom of={disk} bs=1M seek=64 count=32 conv=notrunc,fsync status=none"
    )
    random = observe()
    assert random["free_bytes"] < compressed["free_bytes"]
    assert (
        random["children"][child]["physical_bytes"]
        > compressed["children"][child]["physical_bytes"]
    )
    assert random["storage"]["quota_bytes"] == sparse["storage"]["quota_bytes"]
    assert int(storage.succeed(f"stat --printf=%s {disk}")) == logical

with subtest("quota pressure cannot manufacture available space"):
    storage.succeed("zfs set quota=64M tank/lilly")
    pressured = observe()
    assert pressured["total_bytes"] == 64 * 1024**2
    assert pressured["free_bytes"] < 32 * 1024**2
    storage.fail(
        f"dd if=/dev/urandom of={disk} bs=1M seek=128 count=96 conv=notrunc,fsync status=none"
    )
    storage.succeed("zpool sync tank")
    code, output = storage.execute("zfs-check observe")
    if code == 0:
        assert zfs_observation(json.loads(output))["free_bytes"] < 2 * 1024**2
    storage.succeed("zfs set quota=2G tank/lilly")
    observe()

with subtest("root LZ4, no reservations and safe managed properties"):
    storage.succeed("zfs set compression=off tank")
    storage.succeed("zfs-check reject-mount")
    storage.succeed("zfs set compression=lz4 tank")
    for prop, bad, good in [
        ("compression", "off", "lz4"),
        ("reservation", "1M", "none"),
        ("refreservation", "1M", "none"),
        ("refquota", "1G", "none"),
        ("dedup", "on", "off"),
        ("sync", "disabled", "standard"),
        ("readonly", "on", "off"),
    ]:
        storage.succeed(f"zfs set {prop}={bad} {child}")
        storage.succeed("zfs-check reject-observation")
        storage.succeed(f"zfs set {prop}={good} {child}")
    observe()

with subtest("snapshots, bookmarks, clones and unknown descendants withhold observations"):
    storage.succeed(f"zfs snapshot {child}@unexpected")
    storage.succeed("zfs-check reject-observation")
    storage.succeed(
        f"zfs bookmark {child}@unexpected {child}#unexpected; zfs destroy {child}@unexpected"
    )
    storage.succeed("zfs-check reject-observation")
    storage.succeed(f"zfs destroy {child}#unexpected")
    storage.succeed(f"zfs create {child}/unknown")
    storage.succeed("zfs-check reject-observation")
    storage.succeed(f"zfs destroy {child}/unknown")
    storage.succeed("zfs create tank/lilly/unknown")
    storage.succeed("zfs-check reject-observation")
    storage.succeed("zfs destroy tank/lilly/unknown")
    clone_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    clone = f"tank/lilly/vm-{clone_id}"
    storage.succeed("zfs create tank/source; zfs snapshot tank/source@base")
    storage.succeed(f"zfs clone -o mountpoint=/pool/vms/{clone_id} tank/source@base {clone}")
    storage.succeed("zfs-check reject-observation")
    storage.succeed(f"zfs destroy {clone}; zfs destroy -r tank/source")
    observe()

with subtest("explicit snapshot GUID bindings count shared retained blocks exactly once"):
    storage.succeed(f"zfs snapshot {child}@lilly-backup", f"zfs snapshot {child}@lilly-b")
    storage.succeed(
        f"dd if=/dev/urandom of={disk} bs=1M seek=64 count=32 conv=notrunc,fsync status=none"
    )
    storage.succeed("zpool sync tank")

    def native_property(dataset: str, property_name: str) -> str:
        return storage.succeed(f"zfs get -Hp -o value {property_name} {dataset}").strip()

    def bindings_file(bindings: dict[str, dict[str, str]]) -> None:
        encoded = shlex.quote(json.dumps(bindings))
        storage.succeed(f"printf %s {encoded} > /run/zfs-snapshot-bindings")

    source_guid = native_property(child, "guid")
    bindings = {
        child + suffix: {
            "dataset_guid": source_guid,
            "snapshot_guid": native_property(child + suffix, "guid"),
        }
        for suffix in ["@lilly-backup", "@lilly-b"]
    }
    retained = int(native_property(child, "usedbysnapshots"))
    exclusive = sum(int(native_property(snapshot, "used")) for snapshot in bindings)
    assert retained > exclusive
    bindings_file(bindings)
    storage.succeed("zfs-check reject-observation")
    accounted = zfs_observation(json.loads(storage.succeed("zfs-check observe-snapshots")))
    expected_bytes = int(native_property(child, "usedbydataset")) + retained
    assert accounted["children"][child]["physical_bytes"] == expected_bytes
    assert "allocations" not in accounted

    for field in ["dataset_guid", "snapshot_guid"]:
        wrong = {name: dict(value) for name, value in bindings.items()}
        wrong[child + "@lilly-backup"][field] = "1"
        bindings_file(wrong)
        storage.succeed("zfs-check reject-snapshot-bindings")

    bindings_file(bindings)
    storage.succeed(f"zfs destroy {child}@lilly-backup", "zpool sync tank")
    storage.succeed("zfs-check reject-snapshot-bindings")
    bindings_file({child + "@lilly-b": bindings[child + "@lilly-b"]})
    storage.succeed("zfs-check observe-snapshots")
    storage.succeed(f"zfs destroy {child}@lilly-b", "rm /run/zfs-snapshot-bindings")
    observe()

with subtest("degraded backing is withheld without altering data"):
    storage.succeed("zpool offline tank /dev/vdc1")
    storage.succeed("zfs-check reject-observation")
    assert int(storage.succeed(f"stat --printf=%s {disk}")) == logical
    storage.succeed("zpool online tank /dev/vdc1; zpool wait -t resilver tank")
    observe()

with subtest("large property tree uses the explicit bounded response frame"):
    # 400 real children exceed the standard 65536-byte response limit; parser properties also
    # exercise its full 4096-child bound. This is not a fleet throughput benchmark.
    storage.succeed(
        "for i in $(seq 1 400); do id=$(printf 'cccccccc-cccc-4ccc-8ccc-%012d' $i); zfs create -o mountpoint=/pool/vms/$id tank/lilly/vm-$id || exit; done",
        timeout=120,
    )
    assert int(storage.succeed("zfs-check tree-bytes")) > 65_536
    many = observe()
    assert len(many["children"]) == 401
    storage.succeed(
        "for i in $(seq 1 400); do id=$(printf 'cccccccc-cccc-4ccc-8ccc-%012d' $i); zfs destroy tank/lilly/vm-$id || exit; done",
        timeout=120,
    )

with subtest("reclamation is observed and replaced pool identity is rejected"):
    before_delete = observe()
    storage.succeed(f"zfs destroy {child}")
    after_delete = observe()
    assert not after_delete["children"]
    assert after_delete["free_bytes"] > before_delete["free_bytes"]
    storage.succeed("zfs destroy tank/lilly; zfs create -o mountpoint=/pool -o quota=2G tank/lilly")
    storage.succeed("zfs-check reject-observation")
    storage.succeed("zfs-check remember")
    observe()
    storage.succeed("zfs unmount tank/lilly")
    storage.succeed("zfs-check reject-mount")


with subtest("imported persistent device aliases retain complete native identity"):
    storage.succeed("zpool export tank")
    storage.succeed("zpool import -d /dev/disk/by-partuuid tank", "zfs mount -a")
    status = json.loads(storage.succeed("zpool status -jPp tank"))
    root_vdev = status["pools"]["tank"]["vdevs"]["tank"]
    mirror = next(iter(root_vdev["vdevs"].values()))
    assert all(
        leaf["path"].startswith("/dev/disk/by-partuuid/") for leaf in mirror["vdevs"].values()
    )
    # The same GUIDs and physical extents must survive the path spelling change.
    storage.succeed("zfs-check observe")

with subtest("physical CPU and memory pressure reduce measured headroom and recover"):
    storage.succeed("systemctl start lilly.slice")
    baseline = json.loads(storage.succeed("zfs-check headroom"))
    assert baseline["memory_headroom_bytes"] > 400 * 1024**2
    # Linux resource pressure in the actual guest slice; this is not a guest-OOM test.
    pressure = "import time; memory=bytearray(256*1024**2); open('/run/pressure-ready','w').close(); exec('while True: pass')"
    storage.succeed(
        "systemd-run --unit=usage-pressure --slice=lilly.slice python3 -c " + shlex.quote(pressure)
    )
    storage.wait_until_succeeds("test -f /run/pressure-ready")
    pressured = json.loads(storage.succeed("zfs-check headroom"))
    assert pressured["memory_headroom_bytes"] < baseline["memory_headroom_bytes"] - 128 * 1024**2
    assert pressured["cpu_headroom_millicores"] < 300, pressured
    storage.succeed("systemctl stop usage-pressure.service")
    recovered = json.loads(storage.succeed("zfs-check headroom"))
    assert recovered["memory_headroom_bytes"] > pressured["memory_headroom_bytes"] + 128 * 1024**2
    assert recovered["cpu_headroom_millicores"] > pressured["cpu_headroom_millicores"], recovered

with subtest("large tracked unit inventory omits descriptions and still rejects unknown resources"):
    # These sleeping fixture units prove native inventory behavior, not VM execution.
    ids = [f"dddddddd-dddd-4ddd-8ddd-{number:012d}" for number in range(56)]
    units = [f"lilly-vm-{identity}.service" for identity in ids]
    description = shlex.quote("fixture " + "x" * 1600)
    for unit in units:
        storage.succeed(
            f"systemd-run --unit={unit} --slice=lilly.slice --description={description} sleep infinity"
        )
    verbose = storage.succeed(
        "systemctl list-units --all --plain --no-legend --no-pager 'lilly-vm-*.service'"
    )
    assert len(verbose.encode()) > 65_536
    compact = storage.succeed("systemctl show --property=Id --value 'lilly-vm-*.service'")
    assert set(compact.split()) == set(units)
    storage.succeed("printf %s " + shlex.quote(json.dumps(ids)) + " > /run/tracked-unit-ids")
    storage.succeed("zfs-check tracked-units")
    storage.succeed("printf %s " + shlex.quote(json.dumps(ids[1:])) + " > /run/tracked-unit-ids")
    storage.succeed("zfs-check reject-units")
    storage.succeed("printf %s " + shlex.quote(json.dumps(ids)) + " > /run/tracked-unit-ids")
    storage.succeed("systemd-run --unit=fixture-untracked --slice=lilly.slice sleep infinity")
    storage.succeed("zfs-check reject-units")
    storage.succeed("systemctl stop fixture-untracked.service")
    storage.succeed("zfs-check tracked-units")
    storage.succeed("systemctl stop " + " ".join(units))


with subtest("reviewed resource tuning preserves native identity, guest process and receipts"):
    storage.succeed("python3 /etc/resource-native.py")
