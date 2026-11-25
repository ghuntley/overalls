"""Explicit enrollment of an already authenticated installed host; never formats."""

import fcntl
import importlib.util
import json
import os
import subprocess
import sys
from collections.abc import Callable, Mapping
from contextlib import suppress
from pathlib import Path
from typing import Protocol, TypedDict, cast


class DeploymentConfig(TypedDict):
    secretHelper: str
    resourcePolicyHelper: str
    repository: str


class HostDeclaration(TypedDict):
    platform: str
    budgets: dict[str, int]
    storage: dict[str, object]


class BindingIdentity(TypedDict):
    sshKeys: list[str]


class InstallationBinding(TypedDict):
    identity: BindingIdentity


class Manifest(TypedDict):
    installationBinding: InstallationBinding


class SecretsHelper(Protocol):
    def safe_directory(self, path: Path) -> None: ...


class ResourcePolicyHelper(Protocol):
    def policy(self, candidate: Mapping[str, object]) -> object: ...


class Deployment(Protocol):
    secrets: SecretsHelper
    candidate: Mapping[str, object]

    def command(
        self, arguments: list[str], *, timeout: float = 7200, capture: bool = False
    ) -> str: ...

    def save(self, **values: object) -> None: ...

    def step(self, phase: str) -> None: ...

    def stage(self) -> None: ...

    def preflight(self, previous: Mapping[str, object]) -> None: ...

    def selected(self, path: str) -> str: ...

    def migrate(self) -> None: ...

    def activate(self, bundle: Path) -> None: ...

    def verify(self, bundle: Path) -> None: ...

    def failed(self, reason: str) -> None: ...


class Updater(Protocol):
    STATE: Path
    RUNTIME: Path

    def load_secrets(self, path: str) -> SecretsHelper: ...

    Deployment: Callable[[Mapping[str, object]], Deployment]


class HostRemote(Protocol):
    def verify(self, host: object) -> Mapping[str, object]: ...

    def atomic(self, path: Path, value: object) -> None: ...


def load(name: str, path: str) -> object:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("helper module unavailable: " + name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def enrollment_configuration(
    config: DeploymentConfig,
    previous: Mapping[str, object],
    candidate: Mapping[str, object],
    host: HostDeclaration,
    observed: Mapping[str, object],
) -> Mapping[str, object]:
    """@cc [owner:ghuntley,label:recovery] enrollment-resource-baseline
    Explicit enrollment MUST bind resource policy to the installed declaration's
    budgets and verified native GUIDs, without requiring or inventing an earlier
    enrollment receipt. It MUST NOT change an existing resource policy. Ordinary
    updater resource transitions remain independent of this enrollment-only path.
    """
    new = candidate.get("resourcePolicy")
    old = previous.get("resourcePolicy")
    if old is not None and old != new:
        raise ValueError("enrollment resource policy change")
    if new is not None:
        resources = cast(
            ResourcePolicyHelper,
            load("enrollment_resources", config["resourcePolicyHelper"]),
        )  # helper path is pinned by the deployed configuration
        new = resources.policy(candidate)
        expected = {
            "version": 1,
            "cpuCores": host["budgets"]["guestCpuCores"],
            "memoryMiB": host["budgets"]["guestMemoryMiB"],
            "arcMaxBytes": host["budgets"]["arcMaxMiB"] * 1048576,
            "quotaBytes": host["storage"]["quotaBytes"],
            "dataset": "zroot/lilly",
            "zpoolGuid": observed["poolGuid"],
            "datasetGuid": observed["datasetGuid"],
        }
        if host["platform"] not in ("hetzner", "metal") or new != expected:
            raise ValueError("enrollment resource baseline mismatch")
    # Activation applies already-declared limits. An updater transition would
    # instead require the receipt that only successful enrollment may create.
    result = dict(config)
    result.pop("resourcePolicyHelper", None)
    return result


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("invalid deployment descriptor")
    return cast(dict[str, object], value)


def string_value(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("invalid deployment descriptor")
    return value


def owner_pools(owner: Mapping[str, object]) -> list[dict[str, object]]:
    pools = owner.get("pools")
    if not isinstance(pools, list):
        raise ValueError("invalid Lilly owner descriptor")
    return [object_value(pool) for pool in pools]


def unique_owner_pools(owner: Mapping[str, object]) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for pool in owner_pools(owner):
        filesystem = string_value(pool.get("filesystem_id"))
        if filesystem in result:
            raise ValueError("duplicate Lilly pool filesystem identity")
        result[filesystem] = pool
    return result


def stable_owner(owner: Mapping[str, object]) -> dict[str, object]:
    result = dict(owner)
    result.pop("host_id", None)
    pools: list[dict[str, object]] = []
    for pool in unique_owner_pools(owner).values():
        value = dict(pool)
        value.pop("id", None)
        pools.append(value)
    result["pools"] = sorted(pools, key=lambda pool: string_value(pool.get("filesystem_id")))
    return result


def protected_networks(binding: Mapping[str, object]) -> list[str]:
    """The effective protected set Lilly claims (lilly-protected-binding-effective)."""
    protected = binding.get("protectedCidrs")
    files = binding.get("protectedAddressFiles", [])
    if (
        not isinstance(protected, list)
        or not all(isinstance(item, str) for item in protected)
        or not isinstance(files, list)
        or not all(isinstance(item, str) for item in files)
    ):
        raise ValueError("invalid Lilly network binding")
    effective = set(cast("list[str]", protected))
    for item in cast("list[str]", files):
        text = Path(item).read_text(encoding="ascii").strip()
        octets = text.split(".")
        if (
            len(octets) != 4
            or not all(
                part.isdigit() and str(int(part)) == part and int(part) <= 255 for part in octets
            )
            or text in ("0.0.0.0", "255.255.255.255")
            or octets[0] == "127"
            or int(octets[0]) >= 224
        ):
            raise ValueError("invalid Lilly runtime protected address")
        effective.add(text + "/32")
    return sorted(effective)


def stable_binding(lilly: Mapping[str, object]) -> dict[str, object]:
    result = dict(object_value(lilly.get("binding")))
    result.pop("hostId", None)
    if "protectedCidrs" in result:
        result["protectedCidrs"] = protected_networks(result)
        result.pop("protectedAddressFiles", None)
    pools = result.get("pools")
    if not isinstance(pools, list):
        return result
    stable_pools: list[dict[str, object]] = []
    for pool in pools:
        value = dict(object_value(pool))
        value.pop("id", None)
        stable_pools.append(value)
    result["pools"] = sorted(stable_pools, key=lambda pool: string_value(pool.get("filesystem_id")))
    return result


def pool_owner(owner: Mapping[str, object], pool: Mapping[str, object]) -> dict[str, object]:
    return {
        "host_id": string_value(owner.get("host_id")),
        "pool_id": string_value(pool.get("id")),
        "pool_path": string_value(pool.get("path")),
        "storage": object_value(pool.get("storage")),
    }


def empty_directory(path: Path) -> bool:
    return path.is_dir() and next(path.iterdir(), None) is None


def child_directory_exists(path: Path) -> bool:
    return path.is_dir() and any(child.is_dir() for child in path.iterdir())


def network_rebind_descriptor(
    old_lilly: Mapping[str, object], old_owner: Mapping[str, object]
) -> dict[str, object]:
    binding = object_value(old_lilly.get("binding"))
    return {
        "host_id": string_value(binding.get("hostId")),
        "egress": string_value(binding.get("egressInterface")),
        "protected": protected_networks(binding),
        "state_dir": string_value(old_owner.get("network_state_dir")),
    }


def destroy_empty_lilly_network(
    descriptor_path: Path,
    descriptor: Mapping[str, object],
    new_lilly: Mapping[str, object],
    deployment: Deployment,
    host_remote: HostRemote,
) -> None:
    network_directory = Path(string_value(descriptor.get("state_dir")))
    if not network_directory.is_dir() or next(network_directory.glob("guest-*.json"), None):
        raise ValueError("Lilly guest network state remains")
    host_remote.atomic(descriptor_path, descriptor)
    release = Path(string_value(new_lilly.get("release")))
    environment = ["env", "OVERALLS_NETWORK_REBIND=" + str(descriptor_path)]
    crash_key = new_lilly.get("crashDumpPublicKey")
    if crash_key is not None:
        environment.append("ERL_CRASH_DUMP_PUBLIC_KEY=" + string_value(crash_key))
    expression = (
        'path = System.fetch_env!("OVERALLS_NETWORK_REBIND"); '
        "{:ok, body} = File.read(path); {:ok, value} = JSON.decode(body); "
        '{:ok, config} = Lilly.Network.Config.new(value["host_id"], value["egress"], '
        'value["protected"], value["state_dir"]); :ok = Lilly.Network.destroy(config)'
    )
    deployment.command(
        [
            *environment,
            "PATH=" + str(release / "host-tools" / "bin"),
            "RELEASE_DISTRIBUTION=none",
            "RELEASE_COOKIE=enrollmentnetworkcleanup",
            "ERL_CRASH_DUMP=/dev/null",
            str(release / "bin" / "lilly"),
            "eval",
            expression,
        ],
        timeout=180,
    )


def finish_completed_lilly_rebind(
    candidate: Mapping[str, object],
    deployment: Deployment,
    host_remote: HostRemote,
) -> None:
    """@cc [owner:ghuntley,label:security;recovery] completed-rebind-store-repair
    A completed authority rebind MAY replace only its exact old empty command-store
    identity. The completed owner journal, inactive execution and empty durable
    command directories MUST be revalidated before that single atomic repair.
    """
    new_lilly = object_value(candidate.get("lilly"))
    new_owner = object_value(new_lilly.get("owner"))
    receipt_path = Path("/var/lib/overalls-host/lilly-rebind.json")
    receipt = object_value(json.loads(receipt_path.read_text()))
    old_record = object_value(receipt.get("old_owner"))
    new_record = object_value(receipt.get("new_owner"))
    recorded_old_owner = {
        key: value for key, value in old_record.items() if key not in {"version", "machine_id"}
    }
    recorded_new_owner = {
        key: value for key, value in new_record.items() if key not in {"version", "machine_id"}
    }
    if (
        receipt.get("version") != 1
        or receipt.get("phase") != "complete"
        or recorded_new_owner != new_owner
        or stable_owner(recorded_old_owner) != stable_owner(new_owner)
        or string_value(object_value(new_lilly.get("binding")).get("hostId"))
        != new_owner.get("host_id")
    ):
        raise ValueError("completed Lilly rebind is inconsistent")
    owner_path = Path("/var/lib/lilly/owner.json")
    if json.loads(owner_path.read_text()) != new_record:
        raise ValueError("completed Lilly rebind is inconsistent")
    state_dir = Path(string_value(new_owner.get("state_dir")))
    identity_path = state_dir / "identity.json"
    old_identity = {"version": 3, "host_id": string_value(old_record.get("host_id"))}
    new_identity = {"version": 3, "host_id": string_value(new_record.get("host_id"))}
    current = json.loads(identity_path.read_text())
    if current == new_identity:
        return
    if current != old_identity:
        raise ValueError("Lilly state store identity changed")
    active = deployment.command(
        ["systemctl", "show", "--property=ActiveState", "--value", "lilly.service"],
        capture=True,
    ) in {"active", "activating", "reloading"}
    if active:
        deployment.command(["systemctl", "stop", "lilly.service"], timeout=180)
    try:
        units = deployment.command(
            [
                "systemctl",
                "list-units",
                "--all",
                "--plain",
                "--no-legend",
                "--no-pager",
                "lilly-vm-*.service",
            ],
            capture=True,
        )
        if units.strip() or child_directory_exists(Path("/sys/fs/cgroup/lilly.slice")):
            raise ValueError("Lilly execution remains active")
        for directory in [
            state_dir / "actors",
            state_dir / "commands",
            Path(string_value(new_owner.get("vm_state_dir"))),
            Path(string_value(new_lilly.get("transferStateDirectory"))),
        ]:
            if not empty_directory(directory):
                raise ValueError("Lilly durable workload state remains")
        host_remote.atomic(identity_path, new_identity)
    except Exception:
        if active and json.loads(identity_path.read_text()) == old_identity:
            deployment.command(["systemctl", "start", "lilly.service"], timeout=180)
        raise


# @cc [owner:ghuntley,label:security;recovery] empty-lilly-authority-rebind
# Explicit enrollment MAY replace stale Marshall host and pool UUIDs only when the
# physical owner shape is unchanged and every execution, transfer, guest network
# claim, active claim, VM state and child ZFS dataset/snapshot is absent. It MUST
# remove only the old empty host network through Lilly's fenced cleanup. The
# replacement MUST journal old and new owner records and remain retryable across
# partial atomic writes. An already-equal installed binding MUST be an idempotent
# no-op so enrollment can resume after candidate activation.
def rebind_empty_lilly(
    previous: Mapping[str, object],
    candidate: Mapping[str, object],
    deployment: Deployment,
    host_remote: HostRemote,
    revision: str,
) -> None:
    old_lilly = object_value(previous.get("lilly"))
    new_lilly = object_value(candidate.get("lilly"))
    if old_lilly.get("binding") == new_lilly.get("binding"):
        finish_completed_lilly_rebind(candidate, deployment, host_remote)
        return
    if stable_binding(old_lilly) != stable_binding(new_lilly):
        raise ValueError("Lilly physical binding changed")
    old_owner = object_value(old_lilly.get("owner"))
    new_owner = object_value(new_lilly.get("owner"))
    if stable_owner(old_owner) != stable_owner(new_owner):
        raise ValueError("Lilly physical ownership changed")
    old_transfer = string_value(old_lilly.get("transferStateDirectory"))
    new_transfer = string_value(new_lilly.get("transferStateDirectory"))
    if old_transfer != new_transfer:
        raise ValueError("Lilly physical ownership changed")

    owner_path = Path("/var/lib/lilly/owner.json")
    current = json.loads(owner_path.read_text())
    if not isinstance(current, dict) or set(current) != set(old_owner) | {"version", "machine_id"}:
        raise ValueError("invalid Lilly owner record")
    machine_id = string_value(current.get("machine_id"))
    old_record = {"version": 1, "machine_id": machine_id, **old_owner}
    new_record = {"version": 1, "machine_id": machine_id, **new_owner}
    if current not in [old_record, new_record]:
        raise ValueError("Lilly owner record changed")

    active = deployment.command(
        ["systemctl", "show", "--property=ActiveState", "--value", "lilly.service"],
        capture=True,
    ) in {"active", "activating", "reloading"}
    if active:
        deployment.command(["systemctl", "stop", "lilly.service"], timeout=180)
    authority_records: list[tuple[Path, object, object]] = [(owner_path, old_record, new_record)]
    try:
        units = deployment.command(
            [
                "systemctl",
                "list-units",
                "--all",
                "--plain",
                "--no-legend",
                "--no-pager",
                "lilly-vm-*.service",
            ],
            capture=True,
        )
        cgroup = Path("/sys/fs/cgroup/lilly.slice")
        if units.strip() or child_directory_exists(cgroup):
            raise ValueError("Lilly execution remains active")
        for directory in [
            Path(string_value(old_owner.get("state_dir"))) / "actors",
            Path(string_value(old_owner.get("state_dir"))) / "commands",
            Path(string_value(old_owner.get("vm_state_dir"))),
            Path(new_transfer),
        ]:
            if not empty_directory(directory):
                raise ValueError("Lilly durable workload state remains")

        pool_changes: list[dict[str, object]] = []
        old_by_filesystem = unique_owner_pools(old_owner)
        for pool in unique_owner_pools(new_owner).values():
            filesystem = string_value(pool.get("filesystem_id"))
            old_pool = old_by_filesystem.get(filesystem)
            if old_pool is None:
                raise ValueError("Lilly pool identity changed")
            path = Path(string_value(pool.get("path")))
            for directory in [path / "vms", path / ".lilly-zfs" / "active"]:
                if not empty_directory(directory):
                    raise ValueError("Lilly active pool state remains")
            imports = path / ".lilly-zfs" / "imports"
            if imports.exists() and not empty_directory(imports):
                raise ValueError("Lilly transfer import state remains")
            dataset = string_value(object_value(pool.get("storage")).get("dataset"))
            observed = deployment.command(
                ["zfs", "list", "-H", "-r", "-t", "filesystem,snapshot", "-o", "name", dataset],
                capture=True,
            )
            if observed.splitlines() != [dataset]:
                raise ValueError("Lilly child storage remains")
            pool_path = path / ".lilly-zfs" / "owner.json"
            old_pool_owner = pool_owner(old_owner, old_pool)
            new_pool_owner = pool_owner(new_owner, pool)
            pool_current = json.loads(pool_path.read_text())
            if pool_current not in [old_pool_owner, new_pool_owner]:
                raise ValueError("Lilly pool owner changed")
            authority_records.append((pool_path, old_pool_owner, new_pool_owner))
            pool_changes.append(
                {
                    "path": str(pool_path),
                    "old": old_pool_owner,
                    "new": new_pool_owner,
                }
            )

        receipt_path = Path("/var/lib/overalls-host/lilly-rebind.json")
        network_path = Path("/var/lib/overalls-host/lilly-rebind-network.json")
        network = network_rebind_descriptor(old_lilly, old_owner)
        receipt: dict[str, object] = {
            "version": 1,
            "revision": revision,
            "old_owner": old_record,
            "new_owner": new_record,
            "pools": pool_changes,
            "network": network,
            "phase": "prepared",
        }
        prior_phase: object = None
        if receipt_path.exists():
            prior = json.loads(receipt_path.read_text())
            if not isinstance(prior, dict) or {
                key: value for key, value in prior.items() if key != "phase"
            } != {key: value for key, value in receipt.items() if key != "phase"}:
                raise ValueError("Lilly rebind receipt changed")
            prior_phase = prior.get("phase")
            if prior_phase not in {"prepared", "complete"}:
                raise ValueError("invalid Lilly rebind receipt phase")
        else:
            host_remote.atomic(receipt_path, receipt)
        if prior_phase == "complete" and any(
            json.loads(path.read_text()) != new for path, _old, new in authority_records
        ):
            raise ValueError("completed Lilly rebind is inconsistent")
        if prior_phase != "complete":
            destroy_empty_lilly_network(network_path, network, new_lilly, deployment, host_remote)
        identity_path = Path(string_value(old_owner.get("state_dir"))) / "identity.json"
        old_identity = {"version": 3, "host_id": string_value(old_owner.get("host_id"))}
        new_identity = {"version": 3, "host_id": string_value(new_owner.get("host_id"))}
        authority_records.append((identity_path, old_identity, new_identity))
        identity = json.loads(identity_path.read_text())
        if identity not in [old_identity, new_identity]:
            raise ValueError("Lilly state store identity changed")
        if identity == old_identity:
            host_remote.atomic(identity_path, new_identity)
        for change in pool_changes:
            path = Path(string_value(change["path"]))
            if json.loads(path.read_text()) == change["old"]:
                host_remote.atomic(path, change["new"])
        if json.loads(owner_path.read_text()) == old_record:
            host_remote.atomic(owner_path, new_record)
        host_remote.atomic(receipt_path, {**receipt, "phase": "complete"})
    except Exception:
        authority_unchanged = False
        with suppress(OSError, ValueError, TypeError, json.JSONDecodeError):
            authority_unchanged = all(
                json.loads(path.read_text()) == old for path, old, _new in authority_records
            )
        if active and authority_unchanged:
            deployment.command(["systemctl", "start", "lilly.service"], timeout=180)
        raise


def main() -> None:
    os.umask(0o077)
    updater = cast(Updater, load("updater", sys.argv[1]))  # argv[1] pins the deployed updater
    config: DeploymentConfig = json.loads(Path(sys.argv[2]).read_text())
    bundle = Path(sys.argv[3])
    host_remote = cast(
        HostRemote, load("host_remote", sys.argv[4])
    )  # argv[4] pins the host checks module
    revision: str = sys.argv[5]
    if not __import__("re").fullmatch("[0-9a-f]{40}", revision):
        raise ValueError("full revision required")
    options = set(sys.argv[6:])
    if not options <= {"--rebind-empty-lilly"}:
        raise ValueError("invalid enrollment option")
    candidate: Manifest = json.loads((bundle / "manifest.json").read_text())
    previous: dict[str, object] = json.loads(
        Path("/run/current-system/overalls-deployment.json").read_text()
    )
    before: dict[str, dict[str, object]] = json.loads(json.dumps(previous["installationBinding"]))
    after: dict[str, dict[str, object]] = json.loads(json.dumps(candidate["installationBinding"]))
    before["identity"].pop("sshKeys", None)
    after["identity"].pop("sshKeys", None)
    if before != after:
        raise ValueError("installation maintenance required")
    host_key = " ".join(
        subprocess.check_output(
            ["ssh-keygen", "-y", "-f", "/etc/ssh/ssh_host_ed25519_key"], text=True
        ).split()[:2]
    )
    if host_key not in [
        " ".join(k.split()[:2]) for k in candidate["installationBinding"]["identity"]["sshKeys"]
    ]:
        raise ValueError("candidate host identity mismatch")
    updater.STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
    updater.RUNTIME.mkdir(parents=True, mode=0o700, exist_ok=True)
    helper = updater.load_secrets(config["secretHelper"])
    for directory in [updater.STATE, updater.RUNTIME]:
        helper.safe_directory(directory)
        if directory.stat().st_mode & 0o777 != 0o700:
            raise ValueError("unsafe enrollment state directory")
    with (updater.RUNTIME / "update.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Re-read after acquiring the same lock used by automatic updates.
        previous = json.loads(Path("/run/current-system/overalls-deployment.json").read_text())
        locked_binding: dict[str, dict[str, object]] = json.loads(
            json.dumps(previous["installationBinding"])
        )
        locked_binding["identity"].pop("sshKeys", None)
        if locked_binding != after:
            raise ValueError("active installation changed while building")
        host: HostDeclaration = json.loads(Path("/etc/overalls-host.json").read_text())
        observed = host_remote.verify(host)
        effective = enrollment_configuration(config, previous, candidate, host, observed)
        deployment = updater.Deployment(effective)
        deployment.candidate = candidate
        # Explicit enrollment has authenticated the new public-key declaration.
        # Ordinary update preflight remains strict about every binding change.
        previous["installationBinding"] = candidate["installationBinding"]
        try:
            deployment.command(
                [
                    "systemctl",
                    "mask",
                    "--runtime",
                    "--now",
                    "overalls-auto-update.timer",
                    "overalls-auto-update.service",
                ]
            )
            progress_path = Path("/var/lib/overalls-host/enrollment-in-progress.json")
            host_remote.atomic(progress_path, {"version": 1, "revision": revision})
            Path("/var/lib/overalls-host/enrollment.json").unlink(missing_ok=True)
            deployment.step("enrollment-stage")
            deployment.stage()
            deployment.step("enrollment-preflight")
            if "--rebind-empty-lilly" in options:
                rebind_empty_lilly(previous, candidate, deployment, host_remote, revision)
                previous["lilly"] = candidate.get("lilly")
            deployment.preflight(previous)
            key = deployment.selected("/run/overalls-secrets/git/deploy-key")
            known = str((bundle / "system").resolve() / "etc/overalls-git-known-hosts")
            import shlex

            ssh = shlex.join(
                [
                    "ssh",
                    "-F",
                    "/dev/null",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "StrictHostKeyChecking=yes",
                    "-o",
                    "GlobalKnownHostsFile=/dev/null",
                    "-o",
                    "UserKnownHostsFile=" + known,
                    "-o",
                    "IdentitiesOnly=yes",
                    "-i",
                    key,
                ]
            )
            deployment.command(
                [
                    "env",
                    "GIT_SSH_COMMAND=" + ssh,
                    "git",
                    "ls-remote",
                    "--exit-code",
                    config["repository"],
                    "refs/heads/trunk",
                ],
                timeout=120,
            )
            deployment.step("enrollment-migrate")
            deployment.migrate()
            deployment.step("enrollment-activate")
            deployment.activate(bundle)
            deployment.step("enrollment-health")
            deployment.verify(bundle)
            deployment.command(["systemctl", "start", "overalls-secrets-git.service"])
            host = json.loads(Path("/etc/overalls-host.json").read_text())
            observed = host_remote.verify(host)
            host_remote.atomic(Path("/var/lib/overalls-host/storage.json"), observed)
            host_remote.atomic(
                Path("/var/lib/overalls-host/enrollment.json"),
                {"storage": observed, "revision": revision},
            )
            progress_path.unlink()
            deployment.command(
                [
                    "systemctl",
                    "unmask",
                    "--runtime",
                    "overalls-auto-update.timer",
                    "overalls-auto-update.service",
                ]
            )
            deployment.command(["systemctl", "start", "overalls-auto-update.timer"])
            deployment.save(enrolledRevision=revision, failures=0, retryAt=0, failure=None)
            deployment.step("enrolled")
        except Exception:
            deployment.failed("enrollment_failed")
            raise
        finally:
            staging = updater.RUNTIME / "staging"
            if staging.exists():
                deployment.secrets.safe_directory(staging)
                for directory in staging.iterdir():
                    deployment.secrets.safe_directory(directory)
                    runtime = directory / "runtime"
                    if runtime.exists():
                        deployment.secrets.safe_directory(runtime)
                        (runtime / "identity").unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(
            "Enrollment failed; polling remains gated. Inspect private updater phase state and retry enrollment."
        )
