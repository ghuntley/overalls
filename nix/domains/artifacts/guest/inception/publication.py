"""Bounded child publication from local verified control APIs; never parent credentials."""

from __future__ import annotations

import base64
import binascii
import contextlib
import fcntl
import http.client
import ipaddress
import json
import os
import pwd
import socket
import ssl
import stat
import sys
import threading
import time
from pathlib import Path
from typing import TYPE_CHECKING, Literal, TypedDict, overload

import ingress
import observations
from runtime import SetupError, encode, private_directory, publish, read_private

if TYPE_CHECKING:
    from readiness import Identity

STATE = Path("/var/lib/inception")
ROOT = Path("/run/inception")
MAXIMUM = 262144


class ServiceIdentity(TypedDict):
    id: str
    name: str
    role: str
    host_id: str
    generation: int
    enabled: bool


class IdentityReply(TypedDict):
    version: int
    service: ServiceIdentity


class ChildPublication(TypedDict):
    binding: ingress.Binding
    generation: int
    expires_at_ms: int
    porsche_host_key: str | None
    audi_host_key: str | None
    records: list[dict[str, object]]


def previous_records(value: object) -> list[dict[str, object]]:
    """Validate records copied from the last complete local publication."""
    if not isinstance(value, list) or len(value) > 255:
        raise SetupError("prior publication records invalid")
    records: list[dict[str, object]] = []
    labels: set[str] = set()
    for item in value:
        if (
            not isinstance(item, dict)
            or set(item) != {"label", "ready", "proofs"}
            or not isinstance(item["label"], str)
            or item["label"] in labels
            or not (
                item["label"] == "control"
                or item["label"] == ""
                or ingress.LABEL.fullmatch(item["label"])
            )
            or type(item["ready"]) is not bool
            or not isinstance(item["proofs"], list)
            or len(item["proofs"]) > 2
            or not all(proof(entry) for entry in item["proofs"])
            or len(set(item["proofs"])) != len(item["proofs"])
            or (item["label"] == "" and (item["ready"] or not item["proofs"]))
        ):
            raise SetupError("prior publication record invalid")
        labels.add(item["label"])
        records.append({"label": item["label"], "ready": item["ready"], "proofs": item["proofs"]})
    return records


def now() -> int:
    return time.monotonic_ns() // 1000000


def proof(value: object) -> bool:
    if not isinstance(value, str) or len(value) != 43:
        return False
    try:
        raw = base64.b64decode(value + "=", altchars=b"-_", validate=True)
        return len(raw) == 32 and base64.urlsafe_b64encode(raw).decode().rstrip("=") == value
    except (ValueError, binascii.Error):
        return False


def host_key(path: Path, owner: int) -> str:
    """@cc [owner:ghuntley,label:security] inception-published-key-custody
    Published host keys MUST be bounded canonical Ed25519 public keys in regular
    single-link files owned by the corresponding local service, with no group or
    world writes. Symlinks and trailing commands/comments MUST fail closed.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != owner
            or info.st_nlink != 1
            or info.st_mode & 0o022
            or info.st_size > 128
        ):
            raise SetupError("service public key unavailable")
        value = stream.read(129).removesuffix(b"\n").decode("ascii")
    fields = value.split(" ")
    if len(fields) != 2 or fields[0] != "ssh-ed25519":
        raise SetupError("service public key invalid")
    raw = base64.b64decode(fields[1], validate=True)
    if (
        len(raw) != 51
        or raw[:19] != b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
        or base64.b64encode(raw).decode() != fields[1]
    ):
        raise SetupError("service public key invalid")
    return value


class LocalClient:
    """Verified localhost TLS on a fixed IPv4 socket; no DNS or proxy resolution."""

    # The inner Marshall browser endpoint is 4443, while the authenticated
    # machine APIs used by Inception (SSH, Audi and DNS) are served by its
    # separate FleetEndpoint on the default fleet port 5443.
    def __init__(self, ca: str, port: int = 5443) -> None:
        self.context = ssl.create_default_context(cafile=str(ca))
        self.port = port

    @overload
    def request(
        self, route: Literal["audi/v1/identity"], token: str, fields: dict[str, object]
    ) -> IdentityReply: ...

    @overload
    def request(
        self,
        route: Literal["audi/v1/dns-snapshot", "ssh/v1/ready"],
        token: str,
        fields: dict[str, object],
    ) -> object: ...

    def request(self, route: str, token: str, fields: dict[str, object]) -> object:
        """@cc [owner:ghuntley,label:security] inception-local-publication-client
        Calls MUST use only the fixed local control API routes over verified TLS
        to IPv4 loopback, with bounded response bytes and an absolute deadline.
        Redirects, alternate hosts, compressed responses and duplicate JSON keys
        MUST fail. Credentials and response bodies MUST NOT enter diagnostics.
        """
        if route not in ["audi/v1/dns-snapshot", "audi/v1/identity", "ssh/v1/ready"]:
            raise SetupError("publication route invalid")
        if (
            not isinstance(token, str)
            or not 1 <= len(token) <= 80
            or any(c in token for c in "\r\n\0")
        ):
            raise SetupError("publication credential invalid")
        deadline = now() + 2000
        connection = http.client.HTTPSConnection("localhost", self.port, context=self.context)
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        timer = None
        try:
            raw.settimeout(2)
            raw.connect(("127.0.0.1", self.port))
            raw.settimeout(max(0.001, (deadline - now()) / 1000))
            connection.sock = self.context.wrap_socket(raw, server_hostname="localhost")
            if now() >= deadline:
                raise SetupError("publication request expired")
            transport = connection.sock

            def expire() -> None:
                with contextlib.suppress(OSError):
                    transport.shutdown(socket.SHUT_RDWR)

            timer = threading.Timer((deadline - now()) / 1000, expire)
            timer.daemon = True
            timer.start()
            connection.request(
                "POST",
                "/api/" + route,
                encode(dict(fields, version=1)),
                {
                    "authorization": "Bearer " + token,
                    "content-type": "application/json",
                    "accept-encoding": "identity",
                },
            )
            response = connection.getresponse()
            if (
                response.status != 200
                or response.getheader("Content-Encoding", "identity") != "identity"
                or response.getheader("Content-Type", "").split(";", 1)[0] != "application/json"
            ):
                raise SetupError("publication request refused")
            body = response.read(MAXIMUM + 1)
            if len(body) > MAXIMUM or now() >= deadline:
                raise SetupError("publication response unavailable")
            return json.loads(body, object_pairs_hook=ingress.unique_object)
        finally:
            if timer:
                timer.cancel()
            connection.close()
            raw.close()


def records(
    snapshot: object, zone: str, started: int, current: int
) -> tuple[list[dict[str, object]], int]:
    """@cc [owner:ghuntley,label:security;recovery] inception-child-dns-projection
    The complete local snapshot MUST match the configured app zone. Only ordinary
    workload labels, canonical IPv4 routes and bounded SHA-256 proofs may enter
    this one-layer projection. Overflow or malformed input MUST reject the whole
    snapshot, never publish a prefix. Expiries MUST derive from request start;
    addresses MUST be discarded so the parent alone chooses public addresses.
    """
    if (
        not isinstance(snapshot, dict)
        or set(snapshot) != {"version", "zone", "revision", "ttl", "routes", "proofs"}
        or type(snapshot["version"]) is not int
        or snapshot["version"] != 1
        or snapshot["zone"] != zone
        or type(snapshot["revision"]) is not int
        or not 0 <= snapshot["revision"] <= 9223372036854775807
        or type(snapshot["ttl"]) is not int
        or not 1 <= snapshot["ttl"] <= 5000
    ):
        raise SetupError("child snapshot invalid")
    output = {}
    expiry = started + snapshot["ttl"]
    for kind in ["routes", "proofs"]:
        values = snapshot[kind]
        if not isinstance(values, list) or len(values) > 255:
            raise SetupError("child publication capacity exceeded")
        seen = set()
        for record in values:
            field = "addresses" if kind == "routes" else "proofs"
            if (
                not isinstance(record, dict)
                or set(record) != {"label", "ttl", field}
                or not isinstance(record["label"], str)
                or not (
                    (kind == "proofs" and record["label"] == "")
                    or (
                        34 <= len(record["label"]) <= 63
                        and ingress.LABEL.fullmatch(record["label"])
                    )
                )
                or record["label"] in seen
                or type(record["ttl"]) is not int
                or not 1 <= record["ttl"] <= snapshot["ttl"]
            ):
                raise SetupError("child record invalid")
            label = record["label"]
            seen.add(label)
            items = record[field]
            if (
                not isinstance(items, list)
                or not 1 <= len(items) <= (8 if kind == "routes" else 2)
                or not all(isinstance(item, str) for item in items)
                or len(set(items)) != len(items)
            ):
                raise SetupError("child record values invalid")
            if kind == "routes":
                for address in items:
                    if str(ipaddress.IPv4Address(address)) != address:
                        raise SetupError("child route invalid")
            elif not all(proof(item) for item in items):
                raise SetupError("child proof invalid")
            if started + record["ttl"] <= current:
                continue
            expiry = min(expiry, started + record["ttl"])
            entry = output.setdefault(label, {"label": label, "ready": False, "proofs": []})
            if kind == "routes":
                entry["ready"] = True
            else:
                entry["proofs"] = items
    if len(output) > 255 or expiry <= current:
        raise SetupError("child snapshot expired or oversized")
    return [output[label] for label in sorted(output)], expiry


def control_record(
    value: object, config: ingress.Configuration, current: int
) -> tuple[dict[str, object], int]:
    """@cc [owner:ghuntley,label:security;recovery] inception-control-proof-before-ready
    Control proofs MAY precede TLS readiness, but MUST come from a fresh private
    certificate-worker record with the exact current boot and generation. The
    worker may publish only control's readiness and at most two canonical proofs;
    no record may choose another hostname or extend its original deadline.
    """
    if (
        not isinstance(value, dict)
        or set(value) != {"binding", "generation", "expires_at_ms", "ready", "proofs"}
        or value["binding"] != config["binding"]
        or not isinstance(value["binding"], dict)
        or type(value["binding"].get("execution_epoch")) is not int
        or value["generation"] != config["generation"]
        or type(value["generation"]) is not int
        or type(value["expires_at_ms"]) is not int
        or not current < value["expires_at_ms"] <= current + 5000
        or type(value["ready"]) is not bool
        or not isinstance(value["proofs"], list)
        or len(value["proofs"]) > 2
        or not all(proof(item) for item in value["proofs"])
        or len(set(value["proofs"])) != len(value["proofs"])
    ):
        raise SetupError("control certificate state invalid")
    return {"label": "control", "ready": value["ready"], "proofs": value["proofs"]}, value[
        "expires_at_ms"
    ]


def collect(
    boot: Identity,
    config: ingress.Configuration,
    client: LocalClient,
    root: Path = ROOT,
    state: Path = STATE,
) -> ChildPublication:
    """@cc [owner:ghuntley,label:security;recovery] inception-control-proof-fast-path
    While a control proof or ready control heartbeat is present, publication
    MUST return the control record before optional gateway lookups. This also
    applies when an older certificate is already serving: renewal must not let
    the slow gateway lookups outlive the control heartbeat before the parent
    observes the new proof or ready route. A still-valid prior route and
    host-key snapshot MUST be retained so publishing a control record cannot
    withdraw the child's A record during certificate issuance.
    """
    # Validate the closed boot/namespace schema before consuming any authority.
    ingress.request(encode(dict(config, request_id=boot["placement_id"])), boot)
    request_config: ingress.Configuration = {
        "version": config["version"],
        "binding": config["binding"],
        "request_id": boot["placement_id"],
        "generation": config["generation"],
        "origins": config["origins"],
    }
    if "public" in config:
        request_config["public"] = config["public"]
    if "parent" in config:
        request_config["parent"] = config["parent"]
    started = now()
    result: ChildPublication = {
        "binding": config["binding"],
        "generation": config["generation"],
        "expires_at_ms": started + 5000,
        "porsche_host_key": None,
        "audi_host_key": None,
        "records": [],
    }

    try:
        control, expiry = control_record(
            json.loads(read_private(root / "control-publication.json", 4096)), config, now()
        )
        if control["proofs"] or control["ready"]:
            # DNS/SSH lookups can take the whole control heartbeat under load.
            # Keep the last complete local snapshot when it is still valid; the
            # parent will cap its lease by that snapshot's remaining lifetime.
            try:
                previous = ingress.publication(request_config, root, now=started)
                result["expires_at_ms"] = min(result["expires_at_ms"], started + previous["ttl_ms"])
                result["porsche_host_key"] = previous["porsche_host_key"]
                result["audi_host_key"] = previous["audi_host_key"]
                result["records"].extend(
                    record
                    for record in previous_records(previous["records"])
                    if record["label"] != "control"
                )
            except (OSError, ValueError, TypeError, KeyError, RecursionError, SetupError):
                pass
            result["records"].append(control)
            result["expires_at_ms"] = min(result["expires_at_ms"], expiry)
            if now() >= result["expires_at_ms"]:
                raise SetupError("child publication collection expired")
            return result
    except (OSError, ValueError, TypeError, KeyError, RecursionError, SetupError):
        pass

    try:
        token = read_private(state / "dns.token", 80).decode("ascii")
        snapshot = client.request(
            "audi/v1/dns-snapshot", token, {"zone": config["origins"]["apps"]}
        )
        result["records"], expiry = records(snapshot, config["origins"]["apps"], started, now())
        result["expires_at_ms"] = min(result["expires_at_ms"], expiry)
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        RecursionError,
        http.client.HTTPException,
        SetupError,
    ):
        pass
    try:
        token = read_private(state / "porsche.token", 80).decode("ascii")
        ready = client.request("ssh/v1/ready", token, {})
        if isinstance(ready, dict) and set(ready) == {"ready"} and ready["ready"] is True:
            result["porsche_host_key"] = host_key(
                Path("/var/lib/porsche/keys/ssh_host_ed25519_key.pub"),
                pwd.getpwnam("porsche").pw_uid,
            )
    except (OSError, ValueError, TypeError, KeyError, http.client.HTTPException, SetupError):
        pass
    try:
        token = read_private(state / "audi.token", 80).decode("ascii")
        local_host = json.loads(read_private(state / "lilly.json"))["host_id"]
        identity = client.request("audi/v1/identity", token, {})
        service = identity["service"]
        if (
            set(identity) != {"version", "service"}
            or type(identity["version"]) is not int
            or identity["version"] != 1
            or set(service) != {"id", "name", "role", "host_id", "generation", "enabled"}
            or service["enabled"] is not True
            or service["role"] != "gateway"
            or service["name"] != "inception-audi"
            or service["host_id"] != local_host
            or not isinstance(local_host, str)
            or not ingress.UUID.fullmatch(local_host)
            or not isinstance(service["id"], str)
            or not ingress.UUID.fullmatch(service["id"])
            or type(service["generation"]) is not int
            or not 1 <= service["generation"] <= 9223372036854775807
        ):
            raise SetupError("inner gateway identity unavailable")
        result["audi_host_key"] = host_key(
            Path("/var/lib/audi/keys/ssh_host_ed25519_key.pub"), pwd.getpwnam("audi").pw_uid
        )
    except (OSError, ValueError, TypeError, KeyError, http.client.HTTPException, SetupError):
        pass
    try:
        value = json.loads(read_private(root / "control-publication.json", 4096))
        record, expiry = control_record(value, config, now())
        result["records"].append(record)
        result["expires_at_ms"] = min(result["expires_at_ms"], expiry)
    except (OSError, ValueError, TypeError, KeyError, RecursionError, SetupError):
        pass
    if now() >= result["expires_at_ms"]:
        raise SetupError("child publication collection expired")
    return result


def install(config: ingress.Configuration, result: ChildPublication, root: Path = ROOT) -> None:
    """@cc [owner:ghuntley,label:security;concurrency] inception-producer-config-fence
    Publication MUST serialize with namespace installation and recheck its exact
    config before replacing output. A concurrent generation change or expired
    collection MUST NOT publish stale state. Output MUST remain root-private.
    """
    fd = os.open(root / "ingress.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (
            json.loads(read_private(root / "ingress.json")) != config
            or now() >= result["expires_at_ms"]
        ):
            raise SetupError("child publication configuration changed")
        data = encode(result)
        if len(data) > MAXIMUM:
            raise SetupError("child publication oversized")
        publish(root / "publication.json", data)


def main() -> None:
    sys.path.insert(0, sys.argv[1])
    from readiness import identity

    boot = identity(Path("/proc/cmdline").read_text())
    private_directory(ROOT)
    client = LocalClient("/run/inception-public/ca.crt")
    observations.Server(pwd.getpwnam("audi").pw_uid)
    while True:
        try:
            config = json.loads(read_private(ROOT / "ingress.json"))
            install(config, collect(boot, config, client))
        except (OSError, ValueError, TypeError, KeyError, RecursionError, SetupError):
            # The previous file expires independently; no error payload is logged.
            pass
        time.sleep(0.5)


if __name__ == "__main__":
    main()
