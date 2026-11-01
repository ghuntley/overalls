"""Root-owned preparation of one disposable cache dataset; no deletion or pool creation."""

import json
import os
import pwd
import selectors
import stat
import subprocess
import sys
import time
from collections.abc import Mapping
from typing import TypedDict

GIB = 1024**3
MOUNT = "/var/cache/brady"


class PoolStorage(TypedDict):
    dataset: str
    dataset_guid: str
    zpool_guid: str


class Pool(TypedDict):
    storage: PoolStorage


class Config(TypedDict):
    pool: Pool
    dataset: str
    host_id: str
    zfs: str
    zpool: str


class Observation(TypedDict):
    version: int
    host_id: str
    dataset: str
    device: str
    boot_id: str
    observed_ms: int
    pool_total_bytes: int
    pool_available_bytes: int
    parent_total_bytes: int
    parent_available_bytes: int
    cache_quota_bytes: int


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def config_value(raw: object) -> Config:
    if not isinstance(raw, dict):
        raise ValueError("invalid storage configuration")
    pool = raw.get("pool")
    if not isinstance(pool, dict):
        raise ValueError("invalid storage configuration")
    storage = pool.get("storage")
    if not isinstance(storage, dict):
        raise ValueError("invalid storage configuration")
    return Config(
        pool=Pool(
            storage=PoolStorage(
                dataset=string(storage["dataset"]),
                dataset_guid=string(storage["dataset_guid"]),
                zpool_guid=string(storage["zpool_guid"]),
            )
        ),
        dataset=string(raw["dataset"]),
        host_id=string(raw["host_id"]),
        zfs=string(raw["zfs"]),
        zpool=string(raw["zpool"]),
    )


def command(config: Mapping[str, object], tool: str, args: list[str]) -> str:
    executable = config[tool]
    if not isinstance(executable, str):
        raise TypeError("invalid storage tool")
    with subprocess.Popen(
        [executable, *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    ) as process:
        assert process.stdout is not None
        deadline = time.monotonic() + 10
        output = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise TimeoutError("storage_command_timeout")
                    chunk = os.read(process.stdout.fileno(), 4096)
                    if not chunk:
                        if process.wait(timeout=max(0.01, deadline - time.monotonic())):
                            raise ValueError("storage_command_failed")
                        return output.decode("ascii").strip()
                    output.extend(chunk)
                    if len(output) > 65536:
                        raise ValueError("storage_output_limit")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


def properties(config: Config, dataset: str, names: list[str]) -> dict[str, str]:
    output = command(
        config, "zfs", ["get", "-Hp", "-o", "property,value", ",".join(names), dataset]
    )
    result: dict[str, str] = dict(line.split("\t", 1) for line in output.splitlines())
    if set(result) != set(names):
        raise ValueError("invalid_storage_properties")
    return result


def dataset_properties(config: Config, names: Mapping[str, list[str]]) -> dict[str, dict[str, str]]:
    """Read each dataset's properties in one ``zfs get`` and require exactly those pairs."""
    datasets = list(names)
    if len(set(datasets)) != len(datasets) or not datasets:
        raise ValueError("invalid_storage_datasets")
    union = sorted({name for wanted in names.values() for name in wanted})
    output = command(
        config,
        "zfs",
        ["get", "-Hp", "-o", "name,property,value", ",".join(union), *datasets],
    )
    rows: dict[str, dict[str, str]] = {dataset: {} for dataset in datasets}
    for line in output.splitlines():
        fields = line.split("\t", 2)
        if len(fields) != 3 or fields[0] not in rows or fields[1] in rows[fields[0]]:
            raise ValueError("invalid_storage_properties")
        rows[fields[0]][fields[1]] = fields[2]
    if any(set(rows[dataset]) != set(union) for dataset in datasets):
        raise ValueError("invalid_storage_properties")
    return {dataset: {key: rows[dataset][key] for key in names[dataset]} for dataset in datasets}


def prepare(config: Config) -> None:
    pool = config["pool"]
    parent = pool["storage"]["dataset"]
    zpool = parent.split("/")[0]
    dataset = config["dataset"]
    if not dataset.startswith(zpool + "/") or dataset == parent or dataset.startswith(parent + "/"):
        raise ValueError("cache_must_be_separate_from_guest_parent")
    if properties(config, parent, ["guid"])["guid"] != pool["storage"]["dataset_guid"]:
        raise ValueError("parent_identity_changed")
    if (
        command(config, "zpool", ["get", "-Hp", "-o", "value", "guid", zpool])
        != pool["storage"]["zpool_guid"]
    ):
        raise ValueError("pool_identity_changed")
    capacity = properties(config, zpool, ["used", "available"])
    total = int(capacity["used"]) + int(capacity["available"])
    quota = min(total // 10, 256 * GIB)
    if not 1024**2 <= quota <= 256 * GIB:
        raise ValueError("invalid_pool_capacity")
    names = command(
        config, "zfs", ["list", "-H", "-o", "name", "-t", "filesystem", "-d", "1", zpool]
    ).splitlines()
    expected = {
        "org.overalls:brady-host": config["host_id"],
        "mountpoint": MOUNT,
        "reservation": "0",
        "refreservation": "0",
        "com.sun:auto-snapshot": "false",
        "compression": "lz4",
        "atime": "off",
        "exec": "off",
        "setuid": "off",
        "devices": "off",
        "canmount": "on",
        "primarycache": "metadata",
        "readonly": "off",
        "dedup": "off",
        "sync": "standard",
    }
    if dataset in names:
        actual = properties(config, dataset, list(expected))
        if actual != expected:
            raise ValueError("cache_dataset_not_owned")
        if (
            command(config, "zfs", ["list", "-H", "-o", "name", "-t", "all", "-r", dataset])
            != dataset
        ):
            raise ValueError("unexpected_cache_descendants")
    else:
        if os.path.lexists(MOUNT):
            info = os.lstat(MOUNT)
            if not stat.S_ISDIR(info.st_mode) or os.listdir(MOUNT) or os.path.ismount(MOUNT):
                raise ValueError("cache_mount_not_empty")
        options = {**expected, "quota": str(quota), "refquota": str(quota)}
        args = ["create"]
        for key, value in options.items():
            args.extend(["-o", key + "=" + value])
        command(config, "zfs", [*args, dataset])
    # Changing a quota may fail under existing use; do not remove objects here.
    command(config, "zfs", ["set", f"quota={quota}", f"refquota={quota}", dataset])
    observed = properties(config, dataset, ["mounted", "mountpoint", "quota", "refquota"])
    if observed != {
        "mounted": "yes",
        "mountpoint": MOUNT,
        "quota": str(quota),
        "refquota": str(quota),
    }:
        raise ValueError("cache_mount_unconfirmed")
    if not os.path.ismount(MOUNT) or os.path.realpath(MOUNT) != MOUNT:
        raise ValueError("cache_mount_unconfirmed")
    user = pwd.getpwnam("brady")
    os.chown(MOUNT, user.pw_uid, user.pw_gid, follow_symlinks=False)
    os.chmod(MOUNT, 0o700, follow_symlinks=False)


def observe(config: Config) -> Observation:
    """Read-only native pressure proof; never infer freed bytes from cache intentions.

    The freshness timestamp is taken before the first ZFS read, so every reported
    value is at least as new as ``observed_ms`` (ADR-0069 three-second expiry).
    The parent, pool and cache properties come from one ``zfs get`` so a loaded
    host spends fewer process launches between that timestamp and publication.
    """
    with open("/proc/uptime", encoding="ascii") as stream:
        started = int(float(stream.read(128).split()[0]) * 1000)
    parent = config["pool"]["storage"]["dataset"]
    zpool = parent.split("/")[0]
    bound = config["pool"]["storage"]
    if (
        command(config, "zpool", ["get", "-Hp", "-o", "value", "guid", zpool])
        != bound["zpool_guid"]
    ):
        raise ValueError("pool_identity_changed")
    observed = dataset_properties(
        config,
        {
            parent: ["guid", "used", "available", "readonly", "reservation", "refreservation"],
            zpool: ["used", "available"],
            config["dataset"]: [
                "org.overalls:brady-host",
                "mountpoint",
                "mounted",
                "quota",
                "refquota",
                "reservation",
                "refreservation",
                "readonly",
                "usedbysnapshots",
            ],
        },
    )
    guest = observed[parent]
    if (
        guest["guid"] != bound["dataset_guid"]
        or guest["readonly"] != "off"
        or guest["reservation"] != "0"
        or guest["refreservation"] != "0"
    ):
        raise ValueError("parent_policy_changed")
    pool = observed[zpool]
    cache = observed[config["dataset"]]
    if (
        cache["org.overalls:brady-host"] != config["host_id"]
        or cache["mountpoint"] != MOUNT
        or cache["mounted"] != "yes"
        or cache["readonly"] != "off"
        or any(cache[key] != "0" for key in ("reservation", "refreservation", "usedbysnapshots"))
        or not os.path.ismount(MOUNT)
        or os.path.realpath(MOUNT) != MOUNT
    ):
        raise ValueError("cache_policy_changed")
    if (
        command(config, "zfs", ["list", "-H", "-o", "name", "-t", "all", "-r", config["dataset"]])
        != config["dataset"]
    ):
        raise ValueError("unexpected_cache_descendants")
    device = os.stat(MOUNT).st_dev
    with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as stream:
        boot = stream.read(64).strip()
    return Observation(
        version=1,
        host_id=config["host_id"],
        dataset=config["dataset"],
        device=f"{os.major(device)}:{os.minor(device)}",
        boot_id=boot,
        observed_ms=started,
        pool_total_bytes=int(pool["used"]) + int(pool["available"]),
        pool_available_bytes=int(pool["available"]),
        parent_total_bytes=int(guest["used"]) + int(guest["available"]),
        parent_available_bytes=int(guest["available"]),
        cache_quota_bytes=min(int(cache["quota"]), int(cache["refquota"])),
    )


def publish_pressure(config: Config) -> None:
    directory = "/run/brady-pressure"
    path = directory + "/pressure.json"
    while True:
        # Start samples on a one-second cadence measured from the previous start,
        # not one second after it finished: a slow sample must not also wait out a
        # full sleep before the next one begins, or the published proof lapses.
        cycle = time.monotonic()
        try:
            value = observe(config)
            descriptor = os.open(
                path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o640
            )
            with os.fdopen(descriptor, "w", encoding="ascii") as stream:
                json.dump(value, stream, separators=(",", ":"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(path + ".tmp", path)
        except Exception:
            # Keep failures closed and silent; the last proof expires after three seconds.
            pass
        time.sleep(max(0.0, cycle + 1 - time.monotonic()))


if __name__ == "__main__":
    try:
        with open(sys.argv[1], encoding="ascii") as stream:
            config = config_value(json.loads(stream.read(65537)))
        if len(sys.argv) == 3 and sys.argv[2] == "observe":
            publish_pressure(config)
        else:
            prepare(config)
    except Exception:
        print('{"event":"brady.storage_unavailable"}', flush=True)
        sys.exit(1)
