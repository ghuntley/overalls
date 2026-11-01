import json
from typing import TypedDict

# @cc [owner:ghuntley,label:verification] zfs-crash-after-real-mutation
# Fault tests MUST interrupt the real utility after its filesystem mutation, then
# let Lilly reconcile the retained state. Editing a claim to mimic a crash is insufficient.
storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
storage.succeed("zfs create -o mountpoint=/pool -o quota=6G tank/lilly")
storage.succeed(
    "install -Dm0755 /etc/zfs-fault /run/zfs-fault/bin/zfs; install -Dm0755 /etc/copy-fault /run/zfs-fault/bin/lilly-image-copy"
)
storage.succeed("install -Dm0755 /etc/zfs-observation-fault /run/zfs-changing/bin/zfs")


def vm_id(number: int) -> str:
    return f"dddddddd-dddd-4ddd-8ddd-{number:012d}"


def child(number: int) -> str:
    return f"tank/lilly/vm-{vm_id(number)}"


def disk(number: int) -> str:
    return f"/pool/vms/{vm_id(number)}/rootfs.ext4"


class ClaimBinding(TypedDict):
    host_id: str
    pool_id: str


class GuestClaim(TypedDict):
    state: str
    dataset_guid: str
    nonce: str
    binding: ClaimBinding


class PoolStorage(TypedDict):
    used_bytes: int


class PoolSnapshot(TypedDict):
    allocations: dict[str, int]
    storage: PoolStorage


def claim(number: int, retired: bool = False) -> GuestClaim:
    state = "deleted" if retired else "active"
    return json.loads(storage.succeed(f"cat /pool/.lilly-zfs/{state}/{vm_id(number)}/claim.json"))


def snapshot() -> PoolSnapshot:
    storage.succeed("zpool sync tank")
    return json.loads(storage.succeed("zfs-lifecycle snapshot"))


def interrupted(action: str, operation: str, number: int) -> None:
    unit = f"zfs-interrupt-{operation}-{number}"
    # lilly-hostd passes utilities only PATH and LC_ALL, so the fault wrappers
    # read the paused operation from this file rather than the environment.
    storage.succeed(
        f"rm -f /run/zfs-operation-committed; printf %s {operation} > /run/zfs-pause-operation"
    )
    storage.succeed(
        f"systemd-run --unit={unit} --property=Type=exec --setenv=ZFS_FAULT=1 --setenv=ZFS_PAUSE_OPERATION={operation} zfs-lifecycle {action} {number}"
    )
    # The marker MUST appear only after the real utility mutation. Full-artifact
    # hashing and, for "cp", the complete sparse copy precede it; measured
    # hashing alone exceeded the previous sixty-second allowance under VM I/O.
    storage.wait_for_file("/run/zfs-operation-committed", timeout=600)
    storage.succeed(f"systemctl kill --kill-whom=main --signal=KILL {unit}.service")
    storage.wait_until_fails(f"systemctl is-active --quiet {unit}.service")
    storage.succeed("rm -f /run/zfs-pause-operation")


with subtest("real image copied sparsely, owned once and reused without overwriting"):
    expected_size = int(storage.succeed("zfs-lifecycle disk-size").strip())
    assert expected_size >= 2 * 1024**3
    assert not snapshot()["allocations"]
    storage.succeed("zfs-lifecycle warm-template 1")
    # Moving usage is resampled (ADR-0163 decision 4): the preparation succeeds,
    # and a later quiet preparation agrees with it, so a stale first read fails.
    storage.succeed("ZFS_OBSERVATION_FAULT=usage zfs-lifecycle moving-prepare 1")
    storage.succeed("test -f /run/zfs-observation-changed")
    moved = claim(1)
    storage.succeed("rm /pool/fixture-growth; zpool sync tank")
    storage.succeed("zfs-lifecycle prepare 1")
    first = claim(1)
    assert first == moved
    assert storage.succeed(f"ls -A /pool/vms/{vm_id(1)}").split() == [
        "boot-bundle.json",
        "initrd",
        "kernel",
        "rootfs.ext4",
    ]
    storage.succeed(
        f"test -f /pool/.lilly-zfs/active/{vm_id(1)}/disk.json",
        f"test -f /pool/.lilly-zfs/active/{vm_id(1)}/disk-ready.json",
    )
    assert first["state"] == "ready" and first["dataset_guid"]
    size, blocks, uid, links = map(
        int, storage.succeed(f"stat --printf='%s %b %u %h' {disk(1)}").split()
    )
    assert size == expected_size and blocks * 512 < size and uid > 1_000_000 and links == 1
    storage.succeed(
        f"printf preserved | dd of={disk(1)} bs=1 seek=2000000000 conv=notrunc,fsync status=none"
    )
    storage.succeed("zfs-lifecycle prepare 1")
    assert claim(1) == first
    assert (
        storage.succeed(f"dd if={disk(1)} bs=1 skip=2000000000 count=9 status=none") == "preserved"
    )
    report = snapshot()
    assert 0 < report["allocations"][vm_id(1)] <= report["storage"]["used_bytes"]
    assert report["allocations"][vm_id(1)] < size

with subtest("unknown contents and mount aliases prevent destruction"):
    storage.succeed(f"touch /pool/vms/{vm_id(1)}/unknown")
    storage.succeed("zfs-lifecycle reject-delete 1")
    storage.succeed(f"test -f {disk(1)}; rm /pool/vms/{vm_id(1)}/unknown")
    storage.succeed(f"mkdir /alias; mount --bind /pool/vms/{vm_id(1)} /alias")
    storage.succeed("zfs-lifecycle reject-delete 1", "zfs-lifecycle reject-snapshot")
    storage.succeed("umount /alias")
    storage.succeed("zfs-lifecycle delete 1")
    assert claim(1, retired=True)["state"] == "deleted"
    storage.succeed(
        f"test -f /pool/.lilly-zfs/deleted/{vm_id(1)}/disk.json",
        f"test -f /pool/.lilly-zfs/deleted/{vm_id(1)}/disk-ready.json",
    )
    storage.succeed("zfs-lifecycle delete 1", "zfs-lifecycle reject-prepare 1")
    assert vm_id(1) not in snapshot()["allocations"]

with subtest("retired cleanup rejects foreign directories, contents, symlinks and mounts"):
    path = f"/pool/vms/{vm_id(1)}"
    retired_before = claim(1, retired=True)
    storage.succeed(f"mkdir {path}; chown 1234 {path}")
    storage.succeed("zfs-lifecycle reject-delete 1")
    storage.succeed(f"test -d {path}; chown root {path}; touch {path}/unexpected")
    storage.succeed("zfs-lifecycle reject-delete 1")
    storage.succeed(f"test -f {path}/unexpected; rm {path}/unexpected; rmdir {path}")
    storage.succeed(f"ln -s /pool/.lilly-zfs/deleted {path}")
    storage.succeed("zfs-lifecycle reject-delete 1")
    storage.succeed(f"test -L {path}; rm {path}; mkdir {path}; mount -t tmpfs tmpfs {path}")
    storage.succeed("zfs-lifecycle reject-delete 1")
    storage.succeed(f"mountpoint -q {path}; umount {path}")
    storage.succeed("zfs-lifecycle delete 1", "zfs-lifecycle delete 1")
    assert claim(1, retired=True) == retired_before

# SKIPPED, not passed: "parent sync failure prevents deletion acknowledgement
# and remains retryable". lilly-hostd performs `sync` natively (hostd
# files.rs native()), so a `sync` stub on PATH is never executed and cannot arm
# the fault; reject-delete returned :ok. The case has not been exercised since
# 840c79834. Open gap in ADR-0031: a test-build-only fault seam for hostd's
# native sync is the proposed follow-up.
print(
    "SKIPPED parent-sync-failure subtest: hostd syncs natively, so the PATH stub "
    "cannot arm the fault (ADR-0031 open gap)"
)

with subtest("interrupted create binds only its recorded nonce and new GUID"):
    interrupted("prepare", "create", 2)
    pending = claim(2)
    assert pending["state"] == "creating" and pending["dataset_guid"] is None
    guid = storage.succeed(f"zfs get -Hpo value guid {child(2)}").strip()
    assert vm_id(2) not in snapshot()["allocations"]
    storage.succeed("zfs-lifecycle prepare 2")
    assert claim(2)["dataset_guid"] == guid
    assert claim(2)["nonce"] == pending["nonce"]

with subtest("interrupted sparse copy is retried before atomic disk publication"):
    interrupted("prepare", "cp", 3)
    pending = claim(3)
    assert pending["state"] == "bound"
    storage.fail(f"test -e {disk(3)}")
    storage.succeed(f"test -f /pool/vms/{vm_id(3)}/.rootfs.pending")
    assert vm_id(3) not in snapshot()["allocations"]
    storage.succeed("zfs-lifecycle prepare 3")
    assert claim(3)["dataset_guid"] == pending["dataset_guid"]
    assert vm_id(3) in snapshot()["allocations"]

with subtest("missing initialized storage fences preparation and capacity"):
    storage.succeed(f"rm {disk(3)}")
    storage.succeed("zfs-lifecycle reject-prepare 3", "zfs-lifecycle reject-snapshot")
    storage.succeed("zfs-lifecycle delete 3")
    assert claim(3, retired=True)["state"] == "deleted"

with subtest("mismatched disk metadata and a replaced child GUID cannot be adopted"):
    storage.succeed("zfs-lifecycle prepare 4")
    original = claim(4)
    metadata = f"/pool/.lilly-zfs/active/{vm_id(4)}/disk.json"
    storage.succeed(f"cp {metadata} /run/original-disk.json; printf '{{}}' > {metadata}")
    storage.succeed(
        "zfs-lifecycle reject-snapshot",
        "zfs-lifecycle reject-prepare 4",
        "zfs-lifecycle reject-delete 4",
    )
    storage.succeed(f"cp /run/original-disk.json {metadata}")
    storage.succeed(f"zfs destroy {child(4)}")
    binding = original["binding"]
    storage.succeed(
        f"zfs create -o mountpoint=/pool/vms/{vm_id(4)} -o lilly:host={binding['host_id']} -o lilly:pool={binding['pool_id']} -o lilly:vm={vm_id(4)} -o lilly:nonce={original['nonce']} {child(4)}"
    )
    storage.succeed(f"touch /pool/vms/{vm_id(4)}/replacement-data")
    storage.succeed(
        "zfs-lifecycle reject-snapshot",
        "zfs-lifecycle reject-prepare 4",
        "zfs-lifecycle reject-delete 4",
    )
    storage.succeed(f"test -f /pool/vms/{vm_id(4)}/replacement-data; zfs destroy {child(4)}")
    storage.succeed("zfs-lifecycle delete 4")

with subtest("ownership mismatch and orphan descendants fence the pool"):
    nonce = claim(2)["nonce"]
    storage.succeed(f"zfs set lilly:nonce=00000000000000000000000000000000 {child(2)}")
    storage.succeed(
        "zfs-lifecycle reject-prepare 2",
        "zfs-lifecycle reject-delete 2",
        "zfs-lifecycle reject-snapshot",
    )
    storage.succeed(f"zfs set lilly:nonce={nonce} {child(2)}")
    orphan = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    storage.succeed(f"zfs create -o mountpoint=/pool/vms/{orphan} tank/lilly/vm-{orphan}")
    storage.succeed("zfs-lifecycle reject-snapshot")
    storage.succeed(f"zfs destroy tank/lilly/vm-{orphan}")

with subtest("interrupted destroy retains a deletion fence and reconciles absence"):
    interrupted("delete", "destroy", 2)
    assert claim(2)["state"] == "deleting"
    storage.fail(f"zfs list {child(2)}")
    storage.succeed(f"mkdir -p /pool/vms/{vm_id(2)}; touch /pool/vms/{vm_id(2)}/unexpected")
    storage.succeed("zfs-lifecycle reject-delete 2")
    assert claim(2)["state"] == "deleting"
    storage.succeed(f"test -f /pool/vms/{vm_id(2)}/unexpected; rm /pool/vms/{vm_id(2)}/unexpected")
    storage.succeed("zfs-lifecycle reject-prepare 2", "zfs-lifecycle delete 2")
    assert claim(2, retired=True)["state"] == "deleted"
    assert not snapshot()["allocations"]

with subtest("interrupted destroy recovers only the owned unmounted child"):
    storage.succeed("zfs-lifecycle prepare 5")
    original = claim(5)
    interrupted("delete", "unmount", 5)
    assert claim(5)["state"] == "deleting"
    assert storage.succeed(f"zfs get -Hpo value mounted {child(5)}").strip() == "no"
    storage.succeed("zfs-lifecycle reject-snapshot", "zfs-lifecycle reject-prepare 5")
    # Never hide unknown host files with a recovery mount.
    storage.succeed(f"touch /pool/vms/{vm_id(5)}/unexpected")
    storage.succeed("zfs-lifecycle reject-delete 5")
    assert storage.succeed(f"zfs get -Hpo value mounted {child(5)}").strip() == "no"
    storage.succeed(f"rm /pool/vms/{vm_id(5)}/unexpected")
    # Ownership and policy checks must run before remounting.
    storage.succeed(f"zfs set lilly:nonce=00000000000000000000000000000000 {child(5)}")
    storage.succeed("zfs-lifecycle reject-delete 5")
    assert storage.succeed(f"zfs get -Hpo value mounted {child(5)}").strip() == "no"
    storage.succeed(f"zfs set lilly:nonce={original['nonce']} compression=off {child(5)}")
    storage.succeed("zfs-lifecycle reject-delete 5")
    assert storage.succeed(f"zfs get -Hpo value mounted {child(5)}").strip() == "no"
    storage.succeed(f"zfs set compression=lz4 {child(5)}")
    storage.succeed("zfs-lifecycle delete 5")
    retired = claim(5, retired=True)
    assert retired["state"] == "deleted" and retired["dataset_guid"] == original["dataset_guid"]
    storage.fail(f"zfs list {child(5)}")
    assert not snapshot()["allocations"]

with subtest("unmounted replacement with copied ownership tags is never recovered"):
    storage.succeed("zfs-lifecycle prepare 6")
    original = claim(6)
    interrupted("delete", "unmount", 6)
    storage.succeed(f"zfs destroy {child(6)}")
    binding = original["binding"]
    storage.succeed(
        f"zfs create -o mountpoint=/pool/vms/{vm_id(6)} -o lilly:host={binding['host_id']} -o lilly:pool={binding['pool_id']} -o lilly:vm={vm_id(6)} -o lilly:nonce={original['nonce']} {child(6)}"
    )
    storage.succeed(f"touch /pool/vms/{vm_id(6)}/replacement-data; zfs unmount {child(6)}")
    replacement_guid = storage.succeed(f"zfs get -Hpo value guid {child(6)}").strip()
    assert replacement_guid != original["dataset_guid"]
    storage.succeed("zfs-lifecycle reject-delete 6", "zfs-lifecycle reject-snapshot")
    assert storage.succeed(f"zfs get -Hpo value mounted {child(6)}").strip() == "no"
    assert storage.succeed(f"zfs get -Hpo value guid {child(6)}").strip() == replacement_guid
    storage.succeed(
        f"zfs mount {child(6)}; test -f /pool/vms/{vm_id(6)}/replacement-data; zfs destroy {child(6)}"
    )
    storage.succeed("zfs-lifecycle delete 6")
    assert claim(6, retired=True)["state"] == "deleted"

with subtest(
    "source transfer snapshots recover real interrupted effects and retain authority history"
):
    storage.succeed("zfs-lifecycle prepare 7", "zfs-lifecycle prepare 8")
    neighbor_before = claim(8)
    storage.succeed("printf neighbor > /pool/neighbor-marker")
    # This fixture has no VMM; the source is physically stopped throughout, as
    # ADR-0155 requires for the single transfer snapshot.
    storage.succeed(
        f"printf transferred | dd of={disk(7)} bs=1 seek=2000000000 conv=notrunc,fsync status=none"
    )
    interrupted("transfer-final", "snapshot", 7)
    final = child(7) + "@lilly-b"
    first_guid = storage.succeed(f"zfs get -Hp -o value guid {final}").strip()
    storage.succeed("zfs-lifecycle reject-snapshot")
    storage.succeed("zfs-lifecycle transfer-final 7", "zfs-lifecycle transfer-final 7")
    assert storage.succeed(f"zfs get -Hp -o value guid {final}").strip() == first_guid
    assert vm_id(7) in snapshot()["allocations"]
    storage.succeed("zfs-lifecycle reject-delete 7")
    assert claim(7)["state"] == "ready"
    # A legacy pre-copy "lilly-a" snapshot is foreign to the single-slot policy.
    storage.succeed(f"zfs snapshot -o lilly:transfer_nonce=foreign {child(7)}@lilly-a")
    storage.succeed("zfs-lifecycle reject-snapshot")
    storage.succeed(f"zfs destroy {child(7)}@lilly-a")
    nonce = storage.succeed(f"zfs get -Hp -o value lilly:transfer_nonce {final}").strip()
    storage.succeed(f"zfs set lilly:transfer_nonce=foreign {final}")
    storage.succeed("zfs-lifecycle reject-snapshot", "zfs-lifecycle reject-transfer-cleanup 7")
    assert storage.succeed(f"zfs get -Hp -o value guid {final}").strip() == first_guid
    storage.succeed(f"zfs set lilly:transfer_nonce={nonce} {final}")
    interrupted("transfer-cleanup", "destroy", 7)
    storage.fail(f"zfs list {final}")
    storage.succeed("zfs-lifecycle transfer-cleanup 7", "zfs-lifecycle transfer-cleanup 7")
    storage.succeed("zfs-lifecycle reject-transfer-final 7")
    storage.fail(f"zfs list {final}")
    snapshot()

    newer = "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 ZFS_SOURCE_EPOCH=2"
    storage.succeed(f"{newer} zfs-lifecycle transfer-final 7")
    second_guid = storage.succeed(f"zfs get -Hp -o value guid {final}").strip()
    assert second_guid != first_guid
    storage.succeed("zfs-lifecycle transfer-cleanup 7")
    assert storage.succeed(f"zfs get -Hp -o value guid {final}").strip() == second_guid
    assert vm_id(7) in snapshot()["allocations"]
    second_nonce = storage.succeed(f"zfs get -Hp -o value lilly:transfer_nonce {final}").strip()
    storage.succeed(f"zfs destroy {final}")
    storage.succeed(f"{newer} zfs-lifecycle reject-transfer-final 7")
    storage.fail(f"zfs list {final}")
    storage.succeed(f"zfs snapshot -o lilly:transfer_nonce={second_nonce} {final}")
    replacement_guid = storage.succeed(f"zfs get -Hp -o value guid {final}").strip()
    assert replacement_guid != second_guid
    storage.succeed(f"{newer} zfs-lifecycle reject-transfer-final 7")
    storage.succeed(
        f"{newer} zfs-lifecycle reject-transfer-cleanup 7", "zfs-lifecycle reject-snapshot"
    )
    assert storage.succeed(f"zfs get -Hp -o value guid {final}").strip() == replacement_guid
    storage.succeed(f"zfs destroy {final}")
    storage.succeed(f"{newer} zfs-lifecycle transfer-cleanup 7")

    foreign = "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000003 ZFS_SOURCE_EPOCH=3"
    storage.succeed(f"zfs snapshot -o lilly:transfer_nonce=foreign {final}")
    foreign_guid = storage.succeed(f"zfs get -Hp -o value guid {final}").strip()
    storage.succeed(f"{foreign} zfs-lifecycle reject-transfer-final 7")
    storage.succeed(f"{foreign} zfs-lifecycle reject-transfer-cleanup 7")
    assert storage.succeed(f"zfs get -Hp -o value guid {final}").strip() == foreign_guid
    storage.succeed(f"zfs destroy {final}")
    storage.succeed(f"{foreign} zfs-lifecycle transfer-cleanup 7")
    assert (
        storage.succeed(f"dd if={disk(7)} bs=1 skip=2000000000 count=11 status=none")
        == "transferred"
    )
    storage.succeed("zfs-lifecycle delete 7")
    storage.fail(f"zfs list {child(7)}")
    storage.succeed(f"test -f /pool/.lilly-zfs/deleted/{vm_id(7)}/snapshot-current.json")
    assert claim(8) == neighbor_before
    assert vm_id(8) in snapshot()["allocations"]
    # @cc [owner:ghuntley,label:verification;recovery] delete-identity-fence-under-pool-writes
    # A real pool write between deletion's two observations changes only usage
    # counters and MUST NOT fail deletion (ADR-0143); a non-usage policy change in
    # the same window MUST still refuse it before the fence, and the delete MUST
    # then complete. Reuses the prepared neighbor to avoid another image hash.
    storage.succeed("rm -f /run/zfs-observation-changed /pool/fixture-growth; zpool sync tank")
    storage.succeed("ZFS_OBSERVATION_FAULT=quota zfs-lifecycle reject-delete 8")
    storage.succeed("test -f /run/zfs-observation-changed", "zfs set quota=6G tank/lilly")
    assert claim(8) == neighbor_before
    storage.succeed("rm -f /run/zfs-observation-changed; zpool sync tank")
    storage.succeed("ZFS_OBSERVATION_FAULT=usage zfs-lifecycle delete 8")
    storage.succeed("test -f /run/zfs-observation-changed", "test -s /pool/fixture-growth")
    storage.fail(f"zfs list {child(8)}")
    assert claim(8, retired=True)["state"] == "deleted"
    storage.succeed("rm /pool/neighbor-marker /pool/fixture-growth /run/zfs-observation-changed")
    assert not snapshot()["allocations"]
