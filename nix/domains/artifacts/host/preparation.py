"""Prepare recoverable, encrypted enrollment changes without activating hosts."""

import argparse
import copy
import fcntl
import ipaddress
import json
import os
import re
import tempfile
import uuid
from collections.abc import Mapping
from pathlib import Path
from typing import TypedDict

import cli
import remote

try:
    import secrets_cli as custody  # ty: ignore[unresolved-import] # copied in at packaging time
except ModuleNotFoundError:
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "secrets_cli", Path(__file__).parent.parent / "secrets/cli.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("secrets custody helper unavailable") from None
    custody = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(custody)

LIFETIME = 157680000


class StorageBackend(TypedDict):
    backend: str
    zpool_guid: str
    dataset_guid: str
    dataset: str


class PoolRequest(TypedDict):
    name: str
    storage: StorageBackend
    overhead_bytes: int


class RegistrationRequest(TypedDict, total=False):
    version: int
    name: str
    architecture: str
    machine_id: str
    overhead_cores: int
    overhead_memory_bytes: int
    credential_ttl_seconds: int
    pools: list[PoolRequest]
    transfer_endpoint: cli.TransferEndpoint


class CredentialEnvelope(TypedDict):
    version: int
    host_id: str
    credential_id: str
    credential: str
    expires_at: str


class MarshallPool(TypedDict):
    id: str
    name: str
    storage: dict[str, object]
    filesystem_id: str


class RegistrationBinding(TypedDict):
    host_id: str
    machine_id: str
    credential_id: str
    expires_at: str
    pools: list[MarshallPool]


class RegistrationMetadata(TypedDict, total=False):
    name: str
    machine_id: str
    architecture: str
    transfer_endpoint: cli.TransferEndpoint | None
    host_id: str
    credential_id: str
    expires_at: str
    pools: list[MarshallPool]


class MarshallResult(TypedDict):
    envelope: CredentialEnvelope
    metadata: RegistrationMetadata


class ManifestUser(TypedDict, total=False):
    sshKeys: list[str]


class ManifestDocument(TypedDict, total=False):
    path: str
    hosts: list[str]


class ManifestInventory(TypedDict):
    hosts: dict[str, ManifestUser]
    documents: dict[str, ManifestDocument]


class FleetManifest(TypedDict):
    users: dict[str, ManifestUser]
    inventory: ManifestInventory


class EnrollmentChange(TypedDict):
    path: str
    before: str | None
    after: str


class EnrollmentState(TypedDict, total=False):
    operation_id: str
    identity: dict[str, object]
    source: str
    originals: dict[str, str | None]
    changes: list[EnrollmentChange]
    binding: RegistrationBinding
    complete: bool


def guest_capacity_bytes(host: cli.Host) -> int:
    """@cc [owner:ghuntley,label:capacity] enrollment-storage-headroom-below-capacity
    Enrollment storage headroom (`overhead_bytes`) MUST be strictly below the
    reviewed physical guest capacity: the Hetzner guest dataset quota, or the
    summed raw size of the dedicated EC2 local NVMe guest disks. Marshall
    subtracts headroom from observed free bytes before admission, so headroom at
    or above capacity would leave an enrolled pool that can never admit a disk.
    The bound uses only reviewed declarations, never a logical commitment cap.
    """
    if host["platform"] in cli.SHARED_ROOT:
        quota = host["storage"]["quotaBytes"]
        if quota is None or type(quota) is not int or quota <= 0:
            raise cli.Failure("Shared-root hosts require a reviewed guest quota")
        return quota
    disks = {d["id"]: d["size"] for d in host["inventory"]["disks"]}
    if not host["storage"]["guests"] or any(d not in disks for d in host["storage"]["guests"]):
        raise cli.Failure("EC2 requires declared local guest disks")
    return sum(disks[d] for d in host["storage"]["guests"])


def declaration_request(
    host: cli.Host, observed: remote.StorageFacts, machine_id: str
) -> RegistrationRequest:
    settings = host["lilly"]
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?/?", settings["controlPlane"]):
        raise cli.Failure("Lilly requires an HTTPS control-plane origin")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}", settings["egressInterface"]):
        raise cli.Failure("A reviewed Lilly egress interface is required")
    ttl = settings.get("credentialTtlSeconds", LIFETIME)
    overhead = settings["overheads"]
    limits = {
        "cores": 65536,
        "memoryBytes": 9223372036854775807,
        "storageBytes": guest_capacity_bytes(host) - 1,
    }
    if (
        type(ttl) is not int
        or not 1 <= ttl <= LIFETIME
        or any(
            type(overhead[k]) is not int or not 0 <= overhead[k] <= limit
            for k, limit in limits.items()
        )
    ):
        raise cli.Failure("Invalid credential lifetime or enrollment overheads")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", machine_id):
        raise cli.Failure("Lilly application identity unavailable")
    storage: StorageBackend = {
        "backend": "zfs",
        "zpool_guid": observed["poolGuid"],
        "dataset_guid": observed["datasetGuid"],
        "dataset": ("zroot" if host["platform"] in cli.SHARED_ROOT else "guests") + "/lilly",
    }
    request: RegistrationRequest = {
        "version": 3,
        "name": host["name"],
        "architecture": host["inventory"]["arch"],
        "machine_id": machine_id,
        "overhead_cores": overhead["cores"],
        "overhead_memory_bytes": overhead["memoryBytes"],
        "credential_ttl_seconds": ttl,
        "pools": [
            {
                "name": "guests",
                "storage": storage,
                "overhead_bytes": overhead["storageBytes"],
            }
        ],
    }
    if "transferEndpoint" in settings:
        request["transfer_endpoint"] = settings["transferEndpoint"]
    return request


FLEET_ADDRESSES = "secrets/fleet-addresses.enc.json"


def transfer_secret(request: RegistrationRequest) -> str | None:
    endpoint = request.get("transfer_endpoint")
    if endpoint is None or "addressSecret" not in endpoint:
        return None
    secret = endpoint["addressSecret"]
    if "address" in endpoint or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,62}_IPV4", secret):
        raise cli.Failure("A transfer endpoint names exactly one fleet address secret")
    return secret


def resolve_transfer_endpoint(
    request: RegistrationRequest, root: Path, env: dict[str, str]
) -> RegistrationRequest:
    """@cc [owner:ghuntley,label:security] enrollment-transfer-address-from-sops
    A fleet host's relocation endpoint address MUST come from the shared fleet
    address document, decrypted only with the operator's recovery identity, and
    MUST be a canonical explicit unicast IPv4 address before it reaches Marshall. Failures
    MUST NOT print the value.
    """
    secret = transfer_secret(request)
    if secret is None:
        return request
    sealed = custody.read_regular(custody.document_path(root, FLEET_ADDRESSES))
    document = json.loads(custody.decrypt(sealed, "json", env))
    value = document.get("overalls-fleet-addresses", {}).get("production", {}).get(secret)
    try:
        address = ipaddress.IPv4Address(value if isinstance(value, str) else "")
    except ValueError:
        raise cli.Failure("The transfer endpoint's fleet address is missing or invalid") from None
    if (
        str(address) != value
        or address.is_unspecified
        or address.is_loopback
        or address.is_multicast
        or address.is_link_local
    ):
        raise cli.Failure("The transfer endpoint's fleet address is missing or invalid")
    endpoint = request["transfer_endpoint"]
    resolved: cli.TransferEndpoint = {"address": value}
    if "port" in endpoint:
        resolved["port"] = endpoint["port"]
    if "host_key" in endpoint:
        resolved["host_key"] = endpoint["host_key"]
    return {**request, "transfer_endpoint": resolved}


def manifest(root: Path) -> FleetManifest:
    # Read public working-tree policy, including new untracked host declarations.
    # Only the pinned library comes from the flake; no private material is evaluated.
    def path(p: str) -> str:
        return "(/. + " + json.dumps(str(root / p)) + ")"

    expression = (
        "let f = builtins.getFlake " + json.dumps("git+file://" + str(root)) + "; "
        "lib = f.inputs.nixpkgs.lib; in { users = import "
        + path("nix/policy/identity/users.nix")
        + "; inventory = import "
        + path("nix/policy/secrets/secret-documents.nix")
        + " { inherit lib; }; }"
    )
    return json.loads(cli.run(["nix", "eval", "--impure", "--json", "--expr", expression]))


def observed_request(args: argparse.Namespace, host: cli.Host) -> tuple[RegistrationRequest, str]:
    receipt: cli.InstallReceipt = json.loads(Path(args.install_receipt).read_bytes())
    facts: remote.Facts = cli.probe(args)
    if receipt["host"] != host["name"] or receipt["hostKey"] != facts["hostKey"]:
        raise cli.Failure("Installed identity differs from authenticated target")
    if host["identity"]["sshKeys"] and facts["hostKey"] not in [
        " ".join(k.split()[:2]) for k in host["identity"]["sshKeys"]
    ]:
        raise cli.Failure("Declared SSH identity differs from installed target")
    remote.match(host["inventory"], facts["inventory"])
    observed: remote.StorageFacts = cli.probe(args, "verify", extra=("/etc/overalls-host.json",))

    def normalize(value: remote.StorageFacts) -> remote.StorageFacts:
        value = copy.deepcopy(value)
        value["binding"]["identity"].pop("sshKeys", None)
        return value

    if normalize(observed) != normalize(receipt["storage"]):
        raise cli.Failure("Installed storage receipt differs")
    # Verify the working declaration against the installed platform bindings too.
    binding = observed["binding"]
    for key in ("platform", "firmware", "storage"):
        if host[key] != binding[key]:
            raise cli.Failure("Declaration changes installation bindings")
    if host["identity"]["hostId"] != binding["identity"]["hostId"]:
        raise cli.Failure("Declaration changes the ZFS host identity")
    prefix = [] if args.target.startswith("root@") else ["sudo", "-n"]
    machine_id = cli.ssh(args, [*prefix, "overalls-lilly-identity"]).decode().strip()
    return declaration_request(host, observed, machine_id), facts["hostKey"]


def checked_result(
    result: MarshallResult,
    request: RegistrationRequest,
    prior_binding: Mapping[str, object] | None,
) -> RegistrationBinding:
    envelope, metadata = result["envelope"], result["metadata"]
    if (
        set(envelope) != {"version", "host_id", "credential_id", "credential", "expires_at"}
        or envelope["version"] != 1
        or metadata["name"] != request["name"]
        or metadata["machine_id"] != request["machine_id"]
        or metadata["architecture"] != request["architecture"]
        or metadata["transfer_endpoint"] != request.get("transfer_endpoint")
        or any(envelope[k] != metadata[k] for k in ("host_id", "credential_id", "expires_at"))
        or not re.fullmatch(
            re.escape(envelope["credential_id"]) + r":[A-Za-z0-9_-]{43}", envelope["credential"]
        )
        or (prior_binding and metadata["host_id"] != prior_binding["host_id"])
    ):
        raise cli.Failure("Marshall returned conflicting registration metadata")
    for value in (metadata["host_id"], metadata["credential_id"]):
        if str(uuid.UUID(value)) != value:
            raise cli.Failure("Invalid registration identity")
    if len(metadata["pools"]) != 1:
        raise cli.Failure("Marshall returned conflicting pool bindings")
    pool = metadata["pools"][0]
    expected = request["pools"][0]
    if any(pool[k] != expected[k] for k in ("name", "storage")):
        raise cli.Failure("Marshall returned conflicting pool bindings")
    if (
        pool["filesystem_id"]
        != "zfs:" + expected["storage"]["zpool_guid"] + ":" + expected["storage"]["dataset_guid"]
    ):
        raise cli.Failure("Marshall returned conflicting filesystem identity")
    uuid.UUID(pool["id"])
    return RegistrationBinding(
        host_id=metadata["host_id"],
        machine_id=metadata["machine_id"],
        credential_id=metadata["credential_id"],
        expires_at=metadata["expires_at"],
        pools=[
            MarshallPool(
                id=pool["id"],
                name=pool["name"],
                storage=pool["storage"],
                filesystem_id=pool["filesystem_id"],
            )
        ],
    )


def seal(value: object, recipients: list[str], env: dict[str, str]) -> str:
    plaintext = json.dumps(value).encode()
    sealed = custody.run(
        [
            "sops",
            "--encrypt",
            "--age",
            ",".join(recipients),
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        plaintext,
        env,
    )
    if (
        custody.metadata(sealed, "json") != recipients
        or json.loads(custody.decrypt(sealed, "json", env)) != value
    ):
        raise cli.Failure("Encrypted credential validation failed")
    return sealed.decode()


def publish_changes(root: Path, changes: list[EnrollmentChange]) -> None:
    """@cc [owner:ghuntley,label:recovery] enrollment-publication-retry
    All originals MUST be checked before publication. Each changed file MUST be
    atomically published, and retry MUST accept only its original or staged bytes.
    A partial publication MUST retain the operation ID and sealed artifacts.
    """
    preflight_changes(root, changes)
    for change in changes:
        path = custody.document_path(root, change["path"])
        current = custody.read_regular(path).decode() if path.exists() else None
        if current != change["after"]:
            custody.publish(
                path, change["after"].encode(), None if current is None else current.encode()
            )


def preflight_changes(root: Path, changes: list[EnrollmentChange]) -> None:
    for change in changes:
        path = custody.document_path(root, change["path"])
        current = custody.read_regular(path).decode() if path.exists() else None
        if current not in (change["before"], change["after"]):
            raise cli.Failure("Enrollment files changed concurrently; reconcile before retrying")


def prepare(args: argparse.Namespace) -> None:
    """@cc [owner:ghuntley,label:security] enrollment-authority-before-publication
    Preparation MUST authenticate the installed host and Marshall before issuing
    authority, persist its retry ID first, and validate recovery access before
    rotation. Plaintext MUST remain outside Git/store and MUST NOT enter journals.
    Preparation MUST NOT activate, enable, publish Git commits or format storage.
    """
    os.umask(0o077)
    root = Path(args.root).resolve(strict=True)
    # Serialize with secret reconciliation and other enrollment preparations.
    lock = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _prepare(args, root)
    finally:
        os.close(lock)


def _prepare(args: argparse.Namespace, root: Path) -> None:
    if len(args.host) > 26:
        raise cli.Failure("Enrollment host names must fit the 32-character secret document limit")
    host_path = "fleet/hosts/" + cli.safe_name(args.host) + "/host.json"
    source = custody.read_regular(custody.document_path(root, host_path)).decode()
    host: cli.Host = cli.validate(json.loads(source))
    if args.command == "rotate-credential" and not host["lilly"].get("binding"):
        raise cli.Failure("Rotation requires an existing registration binding")
    request, host_key = observed_request(args, host)
    if transfer_secret(request) is not None:
        if Path(args.recovery_key).resolve().is_relative_to(root):
            raise cli.Failure("Recovery identity must be outside Git")
        with (
            tempfile.TemporaryDirectory(prefix="overalls-enrollment-") as directory,
            custody.identity(args.recovery_key, Path(directory).resolve()) as (env, _),
        ):
            request = resolve_transfer_endpoint(request, root, env)
    state_root = (
        Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")).resolve()
        / "overalls/enrollment"
    )
    if state_root.is_relative_to(root) or state_root.is_relative_to("/nix/store"):
        raise cli.Failure("Enrollment recovery state must be outside Git and the Nix store")
    state_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    if (
        state_root.is_symlink()
        or state_root.stat().st_uid != os.getuid()
        or state_root.stat().st_mode & 0o077
    ):
        raise cli.Failure("Enrollment state directory must be private and owned by the operator")
    state_path = state_root / (cli.digest({"root": str(root), "host": args.host}) + ".json")
    prior: EnrollmentState | None = (
        json.loads(custody.read_regular(state_path, private=True)) if state_path.exists() else None
    )
    identity: dict[str, object] = {
        "request": request,
        "action": args.command,
        "marshall": args.marshall_target,
        "hostKey": host_key,
    }
    if prior and prior["identity"] != identity and not prior.get("complete"):
        raise cli.Failure(
            "An unfinished enrollment has different inputs; restore those inputs and retry"
        )
    state: EnrollmentState
    if (
        prior
        and prior["identity"] == identity
        and (not prior.get("complete") or args.command == "prepare-enrollment")
    ):
        state = prior
    else:
        state = {"operation_id": str(uuid.uuid4()), "identity": identity, "source": source}
        remote.atomic(state_path, state)
    print(
        "Enrollment operation " + state["operation_id"] + "; recovery journal: " + str(state_path)
    )
    if state.get("changes"):
        preflight_changes(root, state["changes"])
    elif source != state["source"]:
        raise cli.Failure("Declaration changed during an unfinished enrollment")
    raw: FleetManifest = manifest(root)
    host_keys = host["identity"]["sshKeys"] or [host_key]
    selected_keys = {" ".join(key.split()[:2]) for key in host_keys}
    if any(
        selected_keys.intersection(" ".join(key.split()[:2]) for key in entry["sshKeys"])
        for name, entry in raw["inventory"]["hosts"].items()
        if name != args.host
    ):
        raise cli.Failure("Installed SSH identity already belongs to another declared host")
    raw["inventory"]["hosts"][args.host] = {"sshKeys": host_keys}
    documents: dict[str, cli.CredentialDocument] = {
        kind: {
            "name": args.host + "-" + kind,
            "path": "secrets/" + args.host + "-" + kind + ".enc.json",
        }
        for kind in ("git", "lilly")
    }
    proposed = copy.deepcopy(host)
    proposed["identity"]["sshKeys"] = host_keys
    for document in documents.values():
        existing = raw["inventory"]["documents"].get(document["name"])
        if existing and (existing["path"] != document["path"] or existing["hosts"] != [args.host]):
            raise cli.Failure("Conflicting host credential inventory")
        raw["inventory"]["documents"][document["name"]] = {
            "path": document["path"],
            "hosts": [args.host],
        }
        references = [d for d in proposed["credentials"] if d["name"] == document["name"]]
        if references and references != [document]:
            raise cli.Failure("Conflicting host credential reference")
        if not references:
            proposed["credentials"].append(document)
    _, recovery, policy = custody.policy(raw)
    if not state.get("originals") and not state.get("changes"):
        state["originals"] = {}
        for document in documents.values():
            path = custody.document_path(root, document["path"])
            state["originals"][document["path"]] = (
                custody.read_regular(path).decode() if path.exists() else None
            )
        remote.atomic(state_path, state)
    for relative, original in state.get("originals", {}).items():
        if state.get("changes"):
            break
        path = custody.document_path(root, relative)
        current = custody.read_regular(path).decode() if path.exists() else None
        if current != original:
            raise cli.Failure("Credential documents changed during an unfinished enrollment")
    if Path(args.recovery_key).resolve().is_relative_to(root):
        raise cli.Failure("Recovery identity must be outside Git")
    with tempfile.TemporaryDirectory(prefix="overalls-enrollment-") as directory:
        work = Path(directory).resolve()
        if work.is_relative_to(root) or work.is_relative_to("/nix/store"):
            raise cli.Failure("Private runtime storage must be outside Git and the Nix store")
        with custody.identity(args.recovery_key, work) as (env, recipient):
            if recipient not in recovery:
                raise cli.Failure("Enrollment requires a current recovery identity")
            bootstrap = custody.document_path(root, policy["git-bootstrap"]["path"])
            deploy = json.loads(custody.decrypt(custody.read_regular(bootstrap), "json", env))
            deploy_key = deploy["overalls-git"]["production"]["GIT_DEPLOY_KEY"]
            prefix = [] if args.marshall_target.startswith("root@") else ["sudo", "-n"]
            control_args = copy.copy(args)
            control_args.ssh_port = getattr(args, "marshall_ssh_port", 22)
            result = json.loads(
                cli.ssh(
                    control_args,
                    [*prefix, "overalls-marshall-enrollment"],
                    json.dumps(
                        {
                            "operation_id": state["operation_id"],
                            "action": args.command,
                            "request": request,
                        }
                    ).encode(),
                    target=args.marshall_target,
                )
            )
            if result["metadata"].get("operation_id") != state["operation_id"]:
                raise cli.Failure("Marshall returned a different enrollment operation")
            binding = checked_result(result, request, host["lilly"].get("binding"))
            proposed["lilly"]["binding"] = binding
            proposed["lilly"].setdefault("credentialTtlSeconds", LIFETIME)
            if not state.get("changes"):
                changes: list[EnrollmentChange] = []
                for kind, payload in (
                    ("git", {"overalls-git": {"production": {"GIT_DEPLOY_KEY": deploy_key}}}),
                    (
                        "lilly",
                        {
                            "overalls-lilly": {
                                "production": {"LILLY_CREDENTIAL": json.dumps(result["envelope"])}
                            }
                        },
                    ),
                ):
                    document = documents[kind]
                    path = custody.document_path(root, document["path"])
                    before = state["originals"][document["path"]]
                    after = seal(payload, policy[document["name"]]["recipients"], env)
                    changes.append({"path": document["path"], "before": before, "after": after})
                changes.append(
                    {
                        "path": host_path,
                        "before": state["source"],
                        "after": json.dumps(proposed, indent=2, sort_keys=True) + "\n",
                    }
                )
                state["changes"] = changes
                state["binding"] = binding
                remote.atomic(state_path, state)
            elif state["binding"] != binding:
                raise cli.Failure(
                    "Registration changed since preparation; explicit reconciliation required"
                )
            publish_changes(root, state["changes"])
            state["complete"] = True
            remote.atomic(state_path, state)
    print("Prepared " + ", ".join(c["path"] for c in state["changes"]))
    print("Host " + binding["host_id"] + "; credential expires " + binding["expires_at"])
    print(
        "Review and publish these Git changes, then enroll --revision COMMIT --install-receipt FILE. Enable scheduling after readiness."
    )
