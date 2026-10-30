#!/usr/bin/env python3
"""Run a controlled Porsche-to-authenticated-SSH benchmark after rollout.

No credential, remote command output, terminal data, or SQL result bodies enter
the evidence. The private output directory is new for every run.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shlex
import statistics
import subprocess
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal, TypedDict

Distribution = Literal["nixos", "ubuntu"]
Stage = Literal["prewarm", "sequential", "concurrent"]


class Entry(TypedDict):
    distribution: Distribution
    stage: Stage
    index: int
    name: str
    image: str
    create_request_id: str
    delete_request_id: str


class Receipt(TypedDict):
    status: str
    result: dict[str, object]


class NativeEvidence(TypedDict):
    method: Literal["reflink", "offload", "copy"]
    source: Literal["template", "verified", "standby"]
    template_record_id: str | None
    template_incarnation: str | None


class TemplateCost(TypedDict):
    distribution: Distribution
    image: str
    pool_id: str
    record_id: str
    incarnation: str
    construction_ms: float


@dataclass(frozen=True)
class Sample:
    ssh_seconds: float
    pool_id: str
    template_record_id: str | None
    template_incarnation: str | None
    template_construction_ms: float | None
    source: Literal["template", "verified", "standby"]


@dataclass(frozen=True)
class Configuration:
    output: Path
    mode: Literal["baseline", "enabled"]
    control_host: str
    database_host: str
    control_key: Path
    control_known_hosts: Path
    control_port: int
    database_key: Path
    database_known_hosts: Path
    database_port: int
    admin_panterloons: str
    admin_dungarees: str
    admin_key: Path
    admin_known_hosts: Path
    admin_port: int
    guest_key: Path
    guest_known_hosts: Path
    guest_ssh_config: Path
    guest_port: int
    guest_user: str
    nixos_image: str
    ubuntu_image: str
    profile: Literal["oss", "standard", "customer"]
    cpu: int
    revision: str
    baseline_summary: Path | None
    absolute: bool = False


def checked_host(value: str) -> str:
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}", value):
        raise ValueError("invalid SSH host")
    return value


def checked_target(value: str) -> str:
    if "@" in value:
        username, host = value.split("@", maxsplit=1)
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
            raise ValueError("invalid SSH account")
    else:
        host = value
    checked_host(host)
    return value


def checked_uuid(value: str) -> str:
    return str(uuid.UUID(value))


def checked_image(value: str) -> str:
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise ValueError("invalid content-addressed image ID")
    return value


def checked_guest_user(value: str) -> str:
    """@cc [owner:ghuntley,label:security;verification] benchmark-exact-guest-account
    The guest SSH account MUST accept Marshall's durable lowercase account
    grammar, including an internal dot, without admitting separators, trailing
    punctuation or an SSH target supplied in place of a username.
    """
    if not re.fullmatch(r"(?:[a-z_][a-z0-9_.-]{0,30}[a-z0-9_]|[a-z_])", value):
        raise ValueError("invalid guest account name")
    return value


def read_config() -> Configuration:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("baseline", "enabled"), required=True)
    parser.add_argument("--control-host", required=True)
    parser.add_argument("--database-host", required=True)
    parser.add_argument("--control-key", type=Path, required=True)
    parser.add_argument("--control-known-hosts", type=Path, required=True)
    parser.add_argument("--control-port", type=int, default=22)
    parser.add_argument("--database-key", type=Path, required=True)
    parser.add_argument("--database-known-hosts", type=Path, required=True)
    parser.add_argument("--database-port", type=int, default=22)
    parser.add_argument("--admin-panterloons", required=True)
    parser.add_argument("--admin-dungarees", required=True)
    parser.add_argument("--admin-key", type=Path, required=True)
    parser.add_argument("--admin-known-hosts", type=Path, required=True)
    parser.add_argument("--admin-port", type=int, default=2222)
    parser.add_argument("--guest-key", type=Path, required=True)
    parser.add_argument("--guest-known-hosts", type=Path, required=True)
    parser.add_argument("--guest-ssh-config", type=Path, required=True)
    parser.add_argument("--guest-port", type=int, default=22)
    parser.add_argument("--guest-user", required=True)
    parser.add_argument("--nixos-image", required=True)
    parser.add_argument("--ubuntu-image", required=True)
    parser.add_argument("--profile", choices=("oss", "standard", "customer"), default="oss")
    parser.add_argument("--cpu", type=int, default=1)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--baseline-summary", type=Path)
    parser.add_argument(
        "--absolute",
        action="store_true",
        help="enabled samples without a baseline (e.g. after guest images changed)",
    )
    args = parser.parse_args()
    if args.absolute and args.baseline_summary is not None:
        parser.error("--absolute and --baseline-summary are mutually exclusive")
    if args.cpu not in range(1, 33):
        parser.error("CPU must be between one and 32")
    if any(
        port not in range(1, 65536)
        for port in (args.control_port, args.database_port, args.admin_port, args.guest_port)
    ):
        parser.error("SSH ports must be between one and 65535")
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("revision must be a full Git commit ID")
    try:
        guest_user = checked_guest_user(args.guest_user)
    except ValueError:
        parser.error("invalid guest account name")
    for key in (
        args.control_key,
        args.control_known_hosts,
        args.database_key,
        args.database_known_hosts,
        args.admin_key,
        args.admin_known_hosts,
        args.guest_key,
        args.guest_known_hosts,
        args.guest_ssh_config,
    ):
        if not key.is_file():
            parser.error("SSH identity or known_hosts input is missing")
    return Configuration(
        output=args.output,
        mode=args.mode,
        control_host=checked_target(args.control_host),
        database_host=checked_target(args.database_host),
        control_key=args.control_key,
        control_known_hosts=args.control_known_hosts,
        control_port=args.control_port,
        database_key=args.database_key,
        database_known_hosts=args.database_known_hosts,
        database_port=args.database_port,
        admin_panterloons=checked_target(args.admin_panterloons),
        admin_dungarees=checked_target(args.admin_dungarees),
        admin_key=args.admin_key,
        admin_known_hosts=args.admin_known_hosts,
        admin_port=args.admin_port,
        guest_key=args.guest_key,
        guest_known_hosts=args.guest_known_hosts,
        guest_ssh_config=args.guest_ssh_config,
        guest_port=args.guest_port,
        guest_user=guest_user,
        nixos_image=checked_image(args.nixos_image),
        ubuntu_image=checked_image(args.ubuntu_image),
        profile=args.profile,
        cpu=args.cpu,
        revision=args.revision,
        baseline_summary=args.baseline_summary,
        absolute=args.absolute,
    )


def parsed_object(raw: str) -> dict[str, object]:
    value: object = json.loads(raw)
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("invalid JSON object")
    return {key: item for key, item in value.items() if isinstance(key, str)}


def receipt(raw: str) -> Receipt:
    value = parsed_object(raw)
    result = value.get("result")
    status = value.get("status")
    if value.get("version") != 1 or not isinstance(status, str):
        raise ValueError("invalid Porsche envelope")
    if not isinstance(result, dict) or not all(isinstance(key, str) for key in result):
        raise ValueError("invalid Porsche result")
    return {"status": status, "result": {str(k): v for k, v in result.items()}}


def ssh_argv(
    key: Path, known_hosts: Path, port: int, destination: str, config_path: Path = Path("/dev/null")
) -> list[str]:
    return [
        "ssh",
        "-F",
        str(config_path),
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "ConnectionAttempts=1",
        "-o",
        "UserKnownHostsFile=" + str(known_hosts),
        "-i",
        str(key),
        "-p",
        str(port),
        destination,
    ]


def guest_ssh_argv(config: Configuration, ssh_host: str) -> list[str]:
    """@cc [owner:ghuntley,label:verification;security] benchmark-audi-guest-transport
    Authenticated guest SSH MUST traverse the explicitly selected, installed Audi
    ProxyCommand profile while retaining strict verified host-CA trust, the same
    chosen key and a validated guest username/host. Marshall/admin reads MUST
    remain isolated from ambient SSH configuration.
    """
    return ssh_argv(
        config.guest_key,
        config.guest_known_hosts,
        config.guest_port,
        config.guest_user + "@" + checked_host(ssh_host),
        config_path=config.guest_ssh_config,
    )


def invoke(argv: list[str], seconds: int) -> str:
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=seconds, check=False)
    except subprocess.TimeoutExpired:
        # The CLI may have accepted a mutation: its planned request ID remains
        # available for reconciliation, never retry with a replacement ID.
        raise TimeoutError(
            "external command timed out; reconcile the persisted request ID"
        ) from None
    if result.returncode != 0:
        raise RuntimeError(f"command exited {result.returncode}")
    return result.stdout


def control(config: Configuration, command: str, seconds: int = 660) -> Receipt:
    raw = invoke(
        [
            *ssh_argv(
                config.control_key,
                config.control_known_hosts,
                config.control_port,
                config.control_host,
            ),
            command,
        ],
        seconds,
    )
    return receipt(raw)


def authenticated_guest_account(config: Configuration) -> None:
    """@cc [owner:ghuntley,label:verification;security] benchmark-current-account-proof
    Before planning any mutation, the current authenticated Porsche identity
    MUST advertise the exact durable guest account selected for the experiment.
    A CLI username or stale prior observation alone cannot bind guest SSH access.
    """
    observed = control(config, "whoami --json", 15)
    if (
        observed["status"] != "succeeded"
        or observed["result"].get("guest_username") != config.guest_user
    ):
        raise ValueError("benchmark guest account differs from authenticated Porsche identity")


def request_outcome(config: Configuration, request_id: str, wait_seconds: int = 120) -> Receipt:
    """@cc [owner:ghuntley,label:verification;recovery] benchmark-read-original-request
    An uncertain mutation MUST be reconciled only by read-only polls of its
    original persisted request ID, within the caller's bounded deadline. A
    delayed physical deletion MAY outlive the Porsche command's wait; it MUST
    NOT be retried under a replacement identity or counted before confirmation.
    """
    if wait_seconds not in range(1, 1801):
        raise ValueError("request observation deadline is out of bounds")
    identity = checked_uuid(request_id)
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        try:
            observed = control(config, f"request show {identity} --json", 15)
        except (RuntimeError, TimeoutError, ValueError):
            # A dropped create/delete reply is not permission to submit another
            # mutation. Only a read with this exact planned ID can resolve it.
            time.sleep(2)
            continue
        if observed["status"] == "succeeded":
            return observed
        if observed["status"] not in ("accepted", "running"):
            raise RuntimeError("original request failed or has an unknown status")
        time.sleep(2)
    raise TimeoutError("original request remains unconfirmed")


def database(config: Configuration, sql: str) -> object:
    # The SQL is fixed text plus UUIDs re-parsed by checked_uuid, never shell input.
    remote = "sudo -n -u postgres psql -X -qAt -d marshall -c " + shlex.quote(
        "BEGIN READ ONLY; SET LOCAL statement_timeout='2s'; " + sql + "; COMMIT;"
    )
    raw = invoke(
        [
            *ssh_argv(
                config.database_key,
                config.database_known_hosts,
                config.database_port,
                config.database_host,
            ),
            remote,
        ],
        15,
    ).strip()
    value: object = json.loads(raw)
    return value


class Journal:
    """@cc [owner:ghuntley,label:verification;recovery] benchmark-intents-before-effects
    All creation/deletion request identities MUST be fsynced in a new private
    manifest before the first external mutation. Uncertain outcomes MUST retain
    those identities and MUST NOT be retried with new request IDs.
    """

    def __init__(self, config: Configuration) -> None:
        self.directory = config.output.resolve()
        self.directory.mkdir(mode=0o700)
        if self.directory.stat().st_mode & 0o077:
            raise ValueError("run directory must be private")
        self.lock = threading.Lock()
        self.events = self.directory / "events.jsonl"
        prefix = "fp-" + datetime.now(UTC).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
        entries: list[Entry] = []
        for distribution, image in (("nixos", config.nixos_image), ("ubuntu", config.ubuntu_image)):
            for stage, count in (("prewarm", 1), ("sequential", 10), ("concurrent", 2)):
                for index in range(count):
                    entries.append(
                        Entry(
                            distribution=distribution,
                            stage=stage,
                            index=index,
                            name=f"{prefix}-{distribution[0]}-{stage[0]}{index:02}",
                            image=image,
                            create_request_id=str(uuid.uuid4()),
                            delete_request_id=str(uuid.uuid4()),
                        )
                    )
        self.entries = entries
        manifest = {
            "mode": config.mode,
            "revision": config.revision,
            "profile": config.profile,
            "cpu": config.cpu,
            "entries": entries,
        }
        with (self.directory / "manifest.json").open("x") as stream:
            json.dump(manifest, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        descriptor = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def record(self, entry: Entry, phase: str, **values: str | int | float | bool) -> None:
        event = {
            "name": entry["name"],
            "phase": phase,
            "monotonic_ns": time.monotonic_ns(),
            "utc": datetime.now(UTC).isoformat(),
            **values,
        }
        with self.lock, self.events.open("a") as stream:
            stream.write(json.dumps(event) + "\n")
            stream.flush()
            os.fsync(stream.fileno())


def cleanup_confirmed(config: Configuration, vm_id: str) -> bool:
    vm = checked_uuid(vm_id)
    result = database(
        config,
        "SELECT row_to_json(t) FROM (SELECT v.observed_state, "
        "NOT EXISTS(SELECT 1 FROM compute_reservations r WHERE r.vm_id=v.id "
        "AND (r.compute_held OR r.disk_held)) AS released "
        f"FROM compute_virtual_machines v WHERE v.id='{vm}') t",
    )
    if not isinstance(result, dict):
        return False
    return result.get("observed_state") == "deleted" and result.get("released") is True


def terminal_creation_vm(config: Configuration, entry: Entry) -> tuple[str, str] | None:
    """@cc [owner:ghuntley,label:verification;recovery] benchmark-terminal-create-custody
    An uncertain or malformed creation reply MAY yield a cleanup identity
    only from the exact persisted terminal failed/succeeded request and its
    valid VM ID. Missing, running and unreadable requests MUST remain
    unconfirmed, not authorize a replacement mutation or name-only deletion.
    """
    request_id = checked_uuid(entry["create_request_id"])
    observed = database(
        config,
        "SELECT row_to_json(t) FROM (SELECT status, vm_id FROM ssh_requests "
        f"WHERE request_id='{request_id}') t",
    )
    if not isinstance(observed, dict):
        return None
    identity = observed.get("vm_id")
    if not isinstance(identity, str):
        return None
    if observed.get("status") == "failed":
        return "failed", checked_uuid(identity)
    if observed.get("status") == "succeeded":
        return "succeeded", checked_uuid(identity)
    return None


def reconcile_terminal_creation(config: Configuration, journal: Journal, entry: Entry) -> None:
    """Cleanup only a terminal same-ID VM after fresh Porsche ownership proof."""
    try:
        bound = terminal_creation_vm(config, entry)
    except (RuntimeError, TimeoutError, ValueError):
        journal.record(entry, "cleanup_unconfirmed")
        raise
    if bound is None:
        journal.record(entry, "cleanup_unconfirmed")
        return
    status, vm_id = bound
    journal.record(entry, f"{status}_create_bound", vm_id=vm_id)
    delete_owned_vm(config, journal, entry, vm_id)


def delete_owned_vm(config: Configuration, journal: Journal, entry: Entry, vm_id: str) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] benchmark-planned-delete-only
    Cleanup MUST bind the exact run-owned VM ID, name and current Porsche owner
    before submitting the manifest-planned deletion ID. Lost replies MUST be
    read by that same ID; a receipt alone does not establish released capacity.
    """
    shown = control(config, f"show {vm_id} --json")
    current = shown["result"]
    if (
        shown["status"] != "succeeded"
        or current.get("id") != vm_id
        or current.get("name") != entry["name"]
        or current.get("owner") is not True
    ):
        journal.record(entry, "cleanup_unconfirmed", vm_id=vm_id)
        raise RuntimeError("VM ownership cannot be confirmed for cleanup")
    journal.record(entry, "delete_started", vm_id=vm_id)
    try:
        deleted = control(
            config,
            f"rm {vm_id} --request-id {entry['delete_request_id']} --timeout 600 --json",
        )
    except (RuntimeError, TimeoutError, ValueError):
        journal.record(entry, "delete_reply_uncertain", vm_id=vm_id)
        deleted = request_outcome(config, entry["delete_request_id"], 1200)
    if deleted["status"] in ("accepted", "running"):
        deleted = request_outcome(config, entry["delete_request_id"], 1200)
    if deleted["status"] != "succeeded":
        raise RuntimeError("deletion receipt is not confirmed")
    for _ in range(120):
        if cleanup_confirmed(config, vm_id):
            journal.record(entry, "delete_confirmed", vm_id=vm_id)
            return
        time.sleep(1)
    raise TimeoutError("physical cleanup confirmation is missing")


def lifecycle_events(config: Configuration, host: str, identity: str) -> list[dict[str, object]]:
    """Read bounded catalogued native diagnostics over the selected admin transport."""
    identity = checked_uuid(identity)
    raw = invoke(
        [
            *ssh_argv(
                config.admin_key,
                config.admin_known_hosts,
                config.admin_port,
                admin_target(config, host),
            ),
            f"sudo -n journalctl -u lilly.service --no-pager -o cat --grep={identity} -n 1000",
        ],
        20,
    )
    if len(raw.encode()) > 4 * 1024 * 1024:
        raise ValueError("native lifecycle observation exceeded its bound")
    events: list[dict[str, object]] = []
    for line in raw.splitlines():
        try:
            event = parsed_object(line)
        except (ValueError, json.JSONDecodeError):
            continue
        metadata = event.get("metadata")
        if not isinstance(metadata, dict):
            continue
        if metadata.get("event") == "lilly.lifecycle_transition_committed":
            events.append({key: value for key, value in metadata.items() if isinstance(key, str)})
    return events


def audit_phases(config: Configuration, host: str, host_id: str, placement_id: str) -> object:
    """Diagnostic phases never become readiness, accounting or cleanup authority."""
    host_id, placement_id = checked_uuid(host_id), checked_uuid(placement_id)
    phases: list[dict[str, object]] = []
    for event in lifecycle_events(config, host, placement_id):
        occurred = event.get("occurred_at")
        state = event.get("next_state")
        if (
            event.get("host_id") == host_id
            and event.get("placement_id") == placement_id
            and event.get("resource_type") == "provisioning"
            and isinstance(state, str)
            and state
            in (
                "pending",
                "materializing",
                "launching",
                "awaiting_trust",
                "awaiting_ssh",
                "ready",
                "failed",
                "superseded",
            )
            and type(occurred) is int
            and isinstance(occurred, int)
            and 0 < occurred < 253_402_300_800_000_000
        ):
            phases.append({"resource": "provisioning", "state": state, "at_unix_us": occurred})
    return {"source": "host-local catalogued diagnostics", "complete": False, "phases": phases}


def placement_snapshot(config: Configuration, vm_id: str) -> dict[str, object]:
    vm = checked_uuid(vm_id)
    result = database(
        config,
        "SELECT row_to_json(t) FROM (SELECT h.name AS host, h.id AS host_id, p.pool_id, "
        "p.id AS placement_id, h.reported_at AS host_reported_at, "
        "h.capacity->>'cpu_headroom_millicores' AS cpu_headroom_millicores, "
        "s.free_bytes AS pool_free_bytes FROM compute_virtual_machines v "
        "JOIN compute_workload_placements p ON p.id=v.current_placement_id "
        "JOIN compute_hosts h ON h.id=p.host_id "
        "JOIN compute_storage_pools s ON s.id=p.pool_id "
        f"WHERE v.id='{vm}') t",
    )
    if not isinstance(result, dict) or not all(isinstance(key, str) for key in result):
        raise ValueError("placement identity is missing")
    fields: dict[str, object] = {str(k): v for k, v in result.items()}
    for name in ("host", "host_id", "pool_id", "placement_id"):
        if not isinstance(fields.get(name), str):
            raise ValueError("incomplete placement identity")
    for name in ("host_id", "pool_id", "placement_id"):
        identity = fields[name]
        if not isinstance(identity, str) or checked_uuid(identity) != identity:
            raise ValueError("invalid placement identity")
    headroom = fields.get("cpu_headroom_millicores")
    free = fields.get("pool_free_bytes")
    if (
        not isinstance(fields.get("host_reported_at"), str)
        or not isinstance(headroom, str)
        or not headroom.isdecimal()
        or isinstance(free, bool)
        or not isinstance(free, int)
        or free < 0
    ):
        raise ValueError("measured host load or pool capacity is unavailable")
    return fields


def admin_target(config: Configuration, host: str) -> str:
    target = {"panterloons": config.admin_panterloons, "dungarees": config.admin_dungarees}.get(
        host
    )
    if target is None:
        raise ValueError("unknown physical host for read-only observation")
    return target


def host_load(config: Configuration, host: str) -> tuple[float, float, float]:
    """@cc [owner:ghuntley,label:verification;security] benchmark-native-load-observation
    The recorded provisioner load MUST come from the enumerated physical host
    over strict authenticated SSH; a client-machine load or unparsed response
    MUST NOT be reported as provisioner load.
    """
    raw = invoke(
        [
            *ssh_argv(
                config.admin_key,
                config.admin_known_hosts,
                config.admin_port,
                admin_target(config, host),
            ),
            "cat /proc/loadavg",
        ],
        15,
    )
    values = raw.split()
    if len(values) != 5:
        raise ValueError("physical host load response is incomplete")
    try:
        one, five, fifteen = (float(value) for value in values[:3])
    except ValueError:
        raise ValueError("physical host load response is invalid") from None
    if not all(math.isfinite(value) and value >= 0 for value in (one, five, fifteen)):
        raise ValueError("physical host load response is invalid")
    return one, five, fifteen


def deployed_image_proof(config: Configuration) -> dict[str, str]:
    """@cc [owner:ghuntley,label:verification;security;capacity] benchmark-exact-fleet-inputs
    Before a manifest or effect, both enrolled Lilly hosts MUST have the same
    canonical installed NixOS/Ubuntu store paths AND registered NAR hashes,
    advertise both selected enabled catalog IDs with fresh reports, and run
    the producer mode/budget under measurement. Reject missing, stale, busy,
    foreign or ambiguous inputs; no private config body or native payload may
    enter diagnostics. This evidence never authorizes an execution or deletion.
    """
    selected = {checked_image(config.nixos_image), checked_image(config.ubuntu_image)}
    if len(selected) != 2:
        raise ValueError("benchmark distributions must have distinct image IDs")
    # checked_image restricts IDs to the closed sha256:hex alphabet before SQL.
    ids = ",".join("'" + image + "'" for image in sorted(selected))
    catalog: object = database(
        config,
        "SELECT coalesce(json_agg(json_build_object('id',id,'enabled',enabled,"
        "'name',name,'manifest',manifest)), '[]'::json) "
        f"FROM compute_images WHERE id IN ({ids})",
    )
    if not isinstance(catalog, list) or len(catalog) != len(selected):
        raise ValueError("selected benchmark catalog images are missing")
    verified: set[str] = set()
    catalog_manifests: dict[str, dict[str, object]] = {}
    for raw in catalog:
        if not isinstance(raw, dict):
            raise ValueError("selected benchmark image is invalid")
        identity = raw.get("id")
        manifest = raw.get("manifest")
        name = raw.get("name")
        if (
            not isinstance(identity, str)
            or identity not in selected
            or raw.get("enabled") is not True
            or name not in ("NixOS", "Ubuntu 26.04 LTS")
            or not isinstance(manifest, dict)
        ):
            raise ValueError("selected benchmark image is unavailable")
        if identity in catalog_manifests:
            raise ValueError("selected benchmark images are ambiguous")
        catalog_manifests[identity] = manifest
        verified.add(identity)
    if verified != selected:
        raise ValueError("selected benchmark images are ambiguous")

    reports: object = database(
        config,
        "SELECT coalesce(json_agg(json_build_object('name',name,'fresh',"
        "reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '30 seconds',"
        "'images',inventory->'images')), '[]'::json) "
        "FROM compute_hosts WHERE name IN ('panterloons','dungarees')",
    )
    if not isinstance(reports, list) or len(reports) != 2:
        raise ValueError("enrolled benchmark host reports are missing")
    seen_hosts: set[str] = set()
    for raw in reports:
        if not isinstance(raw, dict):
            raise ValueError("enrolled benchmark host report is invalid")
        name = raw.get("name")
        offered = raw.get("images")
        if (
            not isinstance(name, str)
            or name not in ("panterloons", "dungarees")
            or name in seen_hosts
            or raw.get("fresh") is not True
            or not isinstance(offered, list)
            or not all(isinstance(image, str) for image in offered)
            or not selected.issubset(set(offered))
            or len(offered) != len(set(offered))
        ):
            raise ValueError("enrolled benchmark image offer is stale or incomplete")
        seen_hosts.add(name)

    installed: list[dict[str, tuple[str, str]]] = []
    # Templates and boot readiness are unconditional in current releases
    # (ADR-0159); a templates-off baseline can only be measured on a historical
    # deployment whose configuration still carries a zero budget.
    expected_budget = 0 if config.mode == "baseline" else 34_359_738_368
    for name in ("panterloons", "dungarees"):
        target = admin_target(config, name)
        runtime = invoke(
            [
                *ssh_argv(config.admin_key, config.admin_known_hosts, config.admin_port, target),
                "sudo -n jq -ce '{budgets: [.pools[].template_budget_bytes], images: .images}' "
                "/run/lilly-release/config.json",
            ],
            15,
        )
        fields = parsed_object(runtime)
        budgets = fields.get("budgets")
        sources = fields.get("images")
        if (
            not isinstance(budgets, list)
            or not budgets
            or any(type(budget) is not int or budget != expected_budget for budget in budgets)
            or not isinstance(sources, list)
            or len(sources) > 128
        ):
            raise ValueError("deployed producer mode or image set differs from campaign")
        paths: dict[str, tuple[str, str]] = {}
        for source in sources:
            if not isinstance(source, str):
                raise ValueError("deployed image source is untyped")
            match = re.fullmatch(
                r"/nix/store/[a-z0-9]{32}-lilly-(nixos-x86_64|ubuntu-26\.04-x86_64)",
                source,
            )
            if match is None:
                continue
            distribution = "nixos" if match.group(1) == "nixos-x86_64" else "ubuntu"
            if distribution in paths:
                raise ValueError("deployed benchmark image source is ambiguous")
            image_id = config.nixos_image if distribution == "nixos" else config.ubuntu_image
            manifest = catalog_manifests[image_id]
            expected_name = "NixOS" if distribution == "nixos" else "Ubuntu 26.04 LTS"
            if (
                next(row.get("name") for row in catalog if row.get("id") == image_id)
                != expected_name
            ):
                raise ValueError("selected catalog distribution differs from installed image")
            projected = invoke(
                [
                    *ssh_argv(
                        config.admin_key, config.admin_known_hosts, config.admin_port, target
                    ),
                    "sudo -n jq -ce '{kernel,initrd,rootfs}' "
                    + shlex.quote(source + "/manifest.json"),
                ],
                15,
            )
            installed_manifest = parsed_object(projected)
            for artifact in ("kernel", "initrd", "rootfs"):
                local_part = installed_manifest.get(artifact)
                catalog_part = manifest.get(artifact)
                if (
                    not isinstance(local_part, dict)
                    or not isinstance(catalog_part, dict)
                    or any(
                        local_part.get(field) != catalog_part.get(field)
                        for field in ("sha256", "bytes")
                    )
                    or not isinstance(local_part.get("sha256"), str)
                    or not re.fullmatch(r"[0-9a-f]{64}", local_part["sha256"])
                    or type(local_part.get("bytes")) is not int
                    or local_part["bytes"] <= 0
                ):
                    raise ValueError("installed manifest differs from selected catalog image")
            nar = invoke(
                [
                    *ssh_argv(
                        config.admin_key, config.admin_known_hosts, config.admin_port, target
                    ),
                    "nix-store --query --hash " + shlex.quote(source),
                ],
                15,
            ).strip()
            if not re.fullmatch(r"sha256:[a-z0-9]{52}", nar):
                raise ValueError("deployed benchmark NAR identity is invalid")
            paths[distribution] = (source, nar)
        if set(paths) != {"nixos", "ubuntu"}:
            raise ValueError("enrolled host lacks a benchmark distribution")
        one, five, _ = host_load(config, name)
        if one >= 12 or five >= 12:
            raise RuntimeError("physical host is too busy for controlled measurement")
        installed.append(paths)
    if installed[0] != installed[1]:
        raise RuntimeError("enrolled hosts have different benchmark image NAR identities")
    return {distribution: installed[0][distribution][1] for distribution in ("nixos", "ubuntu")}


def guest_boot_id(config: Configuration, ssh_host: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] benchmark-observed-guest-boot
    A counted sample MUST record the canonical boot UUID read through the same
    strict host-CA and key-bound guest SSH path as the successful `ls` probe.
    """
    raw = invoke(
        [*guest_ssh_argv(config, ssh_host), "cat /proc/sys/kernel/random/boot_id"],
        15,
    ).strip()
    boot_id = checked_uuid(raw)
    if raw != boot_id:
        raise ValueError("guest boot identity is not canonical")
    return boot_id


def materialization_evidence(
    config: Configuration, host: str, placement_id: str, started_unix: float
) -> NativeEvidence:
    """@cc [owner:ghuntley,label:verification;security] benchmark-native-source-proof
    A counted cache mode MUST come from exactly one matching catalogued native
    placement event with a closed copy method/source and both validated template
    UUIDs, or no UUIDs for the verified path. Missing, ambiguous or mismatched
    events MUST fail without persisting raw journal lines.
    """
    placement = checked_uuid(placement_id)
    target = admin_target(config, host)
    # Read-only host-local journal; retain only the catalogued method for this
    # placement. No raw journal line or incidental OTP payload is persisted.
    remote = (
        "sudo -n journalctl -u lilly.service --no-pager -o cat "
        f"--since=@{max(0, int(started_unix) - 2)} -n 1000"
    )
    raw = invoke(
        [
            *ssh_argv(
                config.admin_key,
                config.admin_known_hosts,
                config.admin_port,
                target,
            ),
            remote,
        ],
        20,
    )
    observed: list[NativeEvidence] = []
    for line in raw.splitlines():
        try:
            event = parsed_object(line)
        except (ValueError, json.JSONDecodeError):
            continue
        metadata = event.get("metadata")
        if not isinstance(metadata, dict):
            continue
        if (
            metadata.get("event") != "vm.image_materialized"
            or metadata.get("placement_id") != placement
        ):
            continue
        method = metadata.get("method")
        source = metadata.get("source")
        if method not in ("reflink", "offload", "copy") or source not in (
            "template",
            "verified",
            "standby",
        ):
            raise ValueError("native materialization event lacks a closed method or source")
        record = metadata.get("template_record_id")
        incarnation = metadata.get("template_incarnation")
        if source == "template":
            if not isinstance(record, str) or not isinstance(incarnation, str):
                raise ValueError("template source lacks its native record identity")
            record = checked_uuid(record)
            incarnation = checked_uuid(incarnation)
        elif record is not None or incarnation is not None:
            # Verified and ADR-0146 standby sources never name a template record.
            raise ValueError("non-template source unexpectedly claims a template")
        observed.append(
            NativeEvidence(
                method=method,
                source=source,
                template_record_id=record,
                template_incarnation=incarnation,
            )
        )
    if len(observed) != 1:
        raise ValueError("exactly one native materialization event is required")
    return observed[0]


def template_construction(
    config: Configuration, host: str, host_id: str, pool_id: str, record_id: str
) -> tuple[float, float]:
    """@cc [owner:ghuntley,label:verification;storage] benchmark-template-cost-binding
    Construction cost MUST bind one staging and one ready diagnostic to the same
    validated host, pool and native template record UUID. Missing, duplicate or
    reversed observations cannot establish a warm hit; diagnostics grant no authority.
    """
    host_id, pool_id, record_id = (checked_uuid(value) for value in (host_id, pool_id, record_id))
    moments: dict[str, list[int]] = {"staging": [], "ready": []}
    for event in lifecycle_events(config, host, record_id):
        if event.get("resource_id") != record_id or event.get("resource_type") != "image_template":
            continue
        if event.get("host_id") != host_id or event.get("pool_id") != pool_id:
            raise ValueError("native template diagnostic identity mismatch")
        state = event.get("next_state")
        if state not in moments or not isinstance(state, str):
            continue
        occurred = event.get("occurred_at")
        if (
            type(occurred) is not int
            or not isinstance(occurred, int)
            or not 0 < occurred < 253_402_300_800_000_000
        ):
            raise ValueError("native template diagnostic timestamp invalid")
        moments[state].append(occurred)
    if len(moments["staging"]) != 1 or len(moments["ready"]) != 1:
        raise ValueError("exactly one native template staging and ready diagnostic is required")
    started, ready = moments["staging"][0], moments["ready"][0]
    if ready < started:
        raise ValueError("native template diagnostic time is reversed")
    return (ready - started) / 1000, ready / 1_000_000


def run_one(config: Configuration, journal: Journal, entry: Entry) -> Sample:
    """@cc [owner:ghuntley,label:verification;recovery] benchmark-authenticated-cleanup
    A counted sample MUST obtain a successful Porsche creation receipt, use
    its authenticated SSH host for a successful `ls` and canonical guest boot
    ID, observe physical host load and its exact native cache source and
    construction history, and confirm deletion and released reservations
    through read-only observations. Never count a timeout or a template built
    during a nominally warm sample.
    """
    journal.record(entry, "create_started", load_1m=os.getloadavg()[0])
    started = time.monotonic()
    started_unix = time.time()
    name = entry["name"]
    command = (
        f"new --name {name} --profile {config.profile} --image {entry['image']} "
        f"--cpu {config.cpu} --request-id {entry['create_request_id']} --timeout 600 --json"
    )
    try:
        try:
            created = control(config, command)
        except (RuntimeError, TimeoutError, ValueError):
            journal.record(entry, "create_reply_uncertain")
            created = request_outcome(config, entry["create_request_id"])
        if created["status"] in ("accepted", "running"):
            created = request_outcome(config, entry["create_request_id"])
        if created["status"] != "succeeded":
            raise RuntimeError("creation was not confirmed")
    except (RuntimeError, TimeoutError, ValueError):
        # A terminal create can already have reserved capacity and a VM row.
        # Reconcile only its original request, never a name-only lookup or a
        # retry under a replacement identity.
        reconcile_terminal_creation(config, journal, entry)
        raise
    try:
        vm_id = created["result"].get("id")
        if not isinstance(vm_id, str):
            raise ValueError("creation receipt lacks VM identity")
        vm_id = checked_uuid(vm_id)
    except ValueError:
        journal.record(entry, "create_identity_unconfirmed")
        reconcile_terminal_creation(config, journal, entry)
        raise
    try:
        ssh_host = created["result"].get("ssh_host")
        if not isinstance(ssh_host, str):
            shown = control(config, f"show {vm_id} --json")
            if shown["status"] != "succeeded" or shown["result"].get("name") != name:
                raise ValueError("creation receipt cannot be bound to its VM name")
            ssh_host = shown["result"].get("ssh_host")
        if not isinstance(ssh_host, str):
            raise ValueError("confirmed VM has no SSH host")
        checked_host(ssh_host)
        journal.record(entry, "create_succeeded", vm_id=vm_id, seconds=time.monotonic() - started)
        deadline = time.monotonic() + 120
        while True:
            try:
                invoke(
                    [*guest_ssh_argv(config, ssh_host), "ls"],
                    15,
                )
                break
            except (RuntimeError, TimeoutError):
                if time.monotonic() >= deadline:
                    raise TimeoutError("authenticated SSH did not become ready") from None
                time.sleep(1)
        ssh_seconds = time.monotonic() - started
        journal.record(entry, "ssh_authenticated", vm_id=vm_id, seconds=ssh_seconds)
        boot_id = guest_boot_id(config, ssh_host)
        journal.record(entry, "guest_boot_observed", vm_id=vm_id, boot_id=boot_id)
        location = placement_snapshot(config, vm_id)
        physical_load = host_load(config, str(location["host"]))
        journal.record(
            entry,
            "placement_observed",
            vm_id=vm_id,
            host=str(location["host"]),
            host_id=str(location["host_id"]),
            pool_id=str(location["pool_id"]),
            placement_id=str(location["placement_id"]),
            cpu_headroom_millicores=str(location.get("cpu_headroom_millicores")),
            pool_free_bytes=str(location.get("pool_free_bytes")),
            host_reported_at=str(location.get("host_reported_at")),
            host_load_1m=physical_load[0],
            host_load_5m=physical_load[1],
            host_load_15m=physical_load[2],
        )
        native = materialization_evidence(
            config, str(location["host"]), str(location["placement_id"]), started_unix
        )
        journal.record(
            entry,
            "native_method_observed",
            vm_id=vm_id,
            method=native["method"],
            cache_mode=native["source"],
            template_record_id=native["template_record_id"] or "none",
            template_incarnation=native["template_incarnation"] or "none",
        )
        if (config.mode == "baseline" and native["source"] != "verified") or (
            # Enabled creates come from a pre-cloned standby (ADR-0146) or,
            # when none is ready, the sealed template.
            config.mode == "enabled" and native["source"] not in ("template", "standby")
        ):
            raise ValueError("native cache source differs from the measured release mode")
        construction_ms: float | None = None
        if native["source"] == "template":
            record = native["template_record_id"]
            if record is None:
                raise ValueError("native template record is absent")
            construction_ms, ready_unix = template_construction(
                config,
                str(location["host"]),
                str(location["host_id"]),
                str(location["pool_id"]),
                record,
            )
            journal.record(
                entry,
                "template_construction_observed",
                vm_id=vm_id,
                record_id=record,
                pool_id=str(location["pool_id"]),
                construction_ms=construction_ms,
                ready_unix=ready_unix,
            )
            if entry["stage"] != "prewarm" and ready_unix >= started_unix - 2:
                raise ValueError("template was built during a warm sample")
        phases = audit_phases(
            config, str(location["host"]), str(location["host_id"]), str(location["placement_id"])
        )
        with journal.lock, (journal.directory / f"phases-{name}.json").open("x") as stream:
            json.dump(phases, stream)
            stream.flush()
            os.fsync(stream.fileno())
        return Sample(
            ssh_seconds=ssh_seconds,
            pool_id=str(location["pool_id"]),
            template_record_id=native["template_record_id"],
            template_incarnation=native["template_incarnation"],
            template_construction_ms=construction_ms,
            source=native["source"],
        )
    finally:
        delete_owned_vm(config, journal, entry, vm_id)


def baseline_medians(
    config: Configuration, installed_nars: dict[str, str] | None = None
) -> dict[str, float] | None:
    """@cc [owner:ghuntley,label:verification] enabled-samples-require-baseline
    Enabled mode MUST supply an existing baseline summary with matching image
    IDs, profile, CPU, installed NAR identities and positive medians before any
    journal or VM mutation. The early shape check precedes host reads; exact
    NAR equality is checked after the read-only host proof, still before effects.
    Complete per-sample custody and physical cleanup remain an independent
    campaign acceptance check, not inferred from these aggregate medians.
    """
    if config.baseline_summary is None:
        # Absolute enabled samples report medians only, never an improvement.
        if config.mode == "enabled" and not config.absolute:
            raise ValueError("enabled campaign requires a baseline summary")
        return None
    baseline = parsed_object(config.baseline_summary.read_text())
    expected = {"nixos": config.nixos_image, "ubuntu": config.ubuntu_image}
    if (
        baseline.get("mode") != "baseline"
        or baseline.get("images") != expected
        or baseline.get("profile") != config.profile
        or baseline.get("cpu") != config.cpu
        or config.mode != "enabled"
    ):
        raise ValueError("baseline and enabled experiment conditions differ")
    if installed_nars is not None and baseline.get("installed_nars") != installed_nars:
        raise ValueError("baseline and enabled installed image NAR identities differ")
    raw_medians = baseline.get("median_seconds")
    if not isinstance(raw_medians, dict):
        raise ValueError("baseline medians are missing")
    medians: dict[str, float] = {}
    for distribution in ("nixos", "ubuntu"):
        old = raw_medians.get(distribution)
        if isinstance(old, bool) or not isinstance(old, (float, int)) or old <= 0:
            raise ValueError("baseline median is invalid")
        medians[distribution] = float(old)
    return medians


def run(config: Configuration) -> None:
    previous = baseline_medians(config)
    authenticated_guest_account(config)
    installed_nars = deployed_image_proof(config)
    if config.mode == "enabled":
        baseline_medians(config, installed_nars)
    journal = Journal(config)
    medians: dict[str, float] = {}
    prewarm_probe: dict[str, float] = {}
    samples: list[tuple[Entry, Sample]] = []
    for distribution in ("nixos", "ubuntu"):
        entries = [
            entry
            for entry in journal.entries
            if entry["distribution"] == distribution and entry["stage"] == "prewarm"
        ]
        probe = run_one(config, journal, entries[0])
        samples.append((entries[0], probe))
        prewarm_probe[distribution] = probe.ssh_seconds
        sequential = [
            entry
            for entry in journal.entries
            if entry["distribution"] == distribution and entry["stage"] == "sequential"
        ]
        times: list[float] = []
        for entry in sequential:
            sample = run_one(config, journal, entry)
            samples.append((entry, sample))
            times.append(sample.ssh_seconds)
        if len(times) != 10:
            raise RuntimeError("incomplete sequential sample")
        medians[distribution] = statistics.median(times)
    concurrent = [entry for entry in journal.entries if entry["stage"] == "concurrent"]
    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(run_one, config, journal, entry): entry for entry in concurrent}
        four_way: list[float] = []
        for future in as_completed(futures):
            sample = future.result()
            samples.append((futures[future], sample))
            four_way.append(sample.ssh_seconds)
    if len(four_way) != 4:
        raise RuntimeError("incomplete concurrent sample")
    constructions: dict[tuple[str, str, str], TemplateCost] = {}
    for entry, sample in samples:
        record = sample.template_record_id
        incarnation = sample.template_incarnation
        duration = sample.template_construction_ms
        if record is None:
            if incarnation is not None or duration is not None:
                raise ValueError("unbound template construction evidence")
            continue
        if incarnation is None or duration is None:
            raise ValueError("template construction evidence is incomplete")
        cost = TemplateCost(
            distribution=entry["distribution"],
            image=entry["image"],
            pool_id=sample.pool_id,
            record_id=record,
            incarnation=incarnation,
            construction_ms=duration,
        )
        key = (entry["distribution"], sample.pool_id, record)
        if key in constructions and constructions[key] != cost:
            raise ValueError("native template evidence changed during the campaign")
        constructions[key] = cost
    # Standby creates (ADR-0146) never build a template on the create path;
    # template-sourced samples still require construction evidence.
    sources = Counter(sample.source for _, sample in samples)
    if config.mode == "enabled" and sources["template"] and not constructions:
        raise ValueError("enabled campaign lacks native template construction evidence")
    result = {
        "revision": config.revision,
        "mode": config.mode,
        "images": {"nixos": config.nixos_image, "ubuntu": config.ubuntu_image},
        "installed_nars": installed_nars,
        "profile": config.profile,
        "cpu": config.cpu,
        "prewarm_probe_ssh_seconds": prewarm_probe,
        "template_construction_by_image_pool": list(constructions.values()),
        "median_seconds": medians,
        "concurrent_seconds": four_way,
        "baseline": "none" if config.absolute else "matched",
        "sources": dict(sources),
    }
    if previous is not None:
        comparison: dict[str, float] = {}
        for distribution in ("nixos", "ubuntu"):
            old = previous[distribution]
            comparison[distribution] = (old - medians[distribution]) / old
        result["improvement_fraction"] = comparison
        result["target_assessment"] = (
            "pending native per-pool template/cache evidence and matched host/load review"
        )
    with (journal.directory / "summary.json").open("x") as stream:
        json.dump(result, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps(result))


if __name__ == "__main__":
    os.umask(0o077)
    run(read_config())
