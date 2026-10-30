"""Plan-bound bare-metal installation and non-destructive enrollment."""

import argparse
import contextlib
import copy
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections.abc import Callable, Generator, Mapping
from pathlib import Path
from typing import NotRequired, TypedDict

import remote
from remote import Binding, Facts, Identity, Inventory, StorageFacts

REPOSITORY = "ssh://git@github.com/ghuntley/overalls"
REMOTE = Path(__file__).with_name("remote.py")
PLATFORMS = ("hetzner", "ec2", "hcloud")


class Failure(Exception):
    pass


class StorageSelection(TypedDict):
    system: list[str]
    guests: list[str]
    quotaBytes: int | None
    ashift: int


class CredentialDocument(TypedDict):
    name: str
    path: str


class TransferEndpoint(TypedDict, total=False):
    """Relocation SSH endpoint; a fleet host names its address by SOPS secret."""

    address: str
    addressSecret: str
    port: int
    host_key: str


class LillySettings(TypedDict, total=False):
    controlPlane: str
    egressInterface: str
    overheads: dict[str, int]
    credentialTtlSeconds: int
    transferEndpoint: TransferEndpoint
    binding: Mapping[str, object]


class UplinkDeclaration(TypedDict):
    network: str


class AddressDeclaration(TypedDict):
    names: NotRequired[dict[str, str]]
    uplink: NotRequired[UplinkDeclaration]


class Host(TypedDict):
    name: str
    reviewed: bool
    platform: str
    firmware: str
    identity: Identity
    inventory: Inventory
    storage: StorageSelection
    network: dict[str, object]
    budgets: dict[str, int]
    git: dict[str, str]
    credentials: list[CredentialDocument]
    lilly: LillySettings
    addresses: NotRequired[AddressDeclaration]


class Plan(TypedDict):
    version: int
    host: Host
    target: str
    sourceKey: str
    sshPort: int
    installerSshPort: int
    revision: str
    repository: str
    system: str
    install: str
    kexec: str
    erase: list[str]


class InstallReceipt(TypedDict):
    plan: str
    hostKey: str
    revision: str
    host: str
    storage: StorageFacts


def run(
    args: list[str | Path], data: bytes | None = None, env: dict[str, str] | None = None
) -> bytes:
    try:
        return subprocess.check_output(
            [str(a) for a in args], input=data, stderr=subprocess.DEVNULL, env=env, timeout=7200
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise Failure("Command failed: " + Path(str(args[0])).name) from None


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def safe_name(name: str) -> str:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,27}", name) or name.endswith("-base"):
        raise Failure("Invalid host name")
    return name


def ssh_port(args: argparse.Namespace) -> int:
    value = getattr(args, "ssh_port", 22)
    if type(value) is not int or not 1 <= value <= 65535:
        raise Failure("Administrative SSH port must be between 1 and 65535")
    return value


def installer_connection(args: argparse.Namespace) -> argparse.Namespace:
    result = copy.copy(args)
    result.ssh_port = getattr(args, "installer_ssh_port", 22)
    ssh_port(result)
    return result


# @cc [owner:ghuntley,label:security] host-administrative-port-selection
# All administrative SSH and Nix copy connections MUST use the explicit validated
# port with pinned host keys and no user SSH config. Management SSH is not an
# administrative fallback. Installer and Marshall control targets select their
# own ports; transport failures MUST NOT retry another port.
def connection(args: argparse.Namespace, target: str | None = None) -> list[str]:
    target = target or args.target
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+", target):
        raise Failure("Use an explicit user@host SSH target")
    return [
        "ssh",
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + str(Path(args.known_hosts).resolve(strict=True)),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ConnectTimeout=10",
        "-i",
        str(Path(args.identity).resolve(strict=True)),
        "-p",
        str(ssh_port(args)),
        target,
    ]


def ssh(
    args: argparse.Namespace, argv: list[str], data: bytes | None = None, target: str | None = None
) -> bytes:
    # SSH has a remote shell protocol; quote the argument array at that boundary.
    return run([*connection(args, target), shlex.join(argv)], data)


def probe[T](
    args: argparse.Namespace,
    action: str = "discover",
    payload: object | None = None,
    target: str | None = None,
    extra: tuple[str, ...] = (),
) -> T:
    code = REMOTE.read_text()
    # The program travels over authenticated stdin. JSON is a separate literal,
    # never interpolated into a remote shell command.
    if payload is not None:
        code = "import io\n" + code
        code = code.replace(
            "    try:\n        main()",
            "    try:\n        sys.stdin = io.StringIO("
            + repr(json.dumps(payload))
            + ")\n        main()",
        )
    prefix = [] if (target or args.target).startswith("root@") else ["sudo", "-n"]
    return json.loads(ssh(args, [*prefix, "python3", "-", action, *extra], code.encode(), target))


def validate(h: Host) -> Host:
    safe_name(h["name"])
    if not h["reviewed"] or h["platform"] not in PLATFORMS or h["firmware"] not in ("bios", "uefi"):
        raise Failure("Review platform, firmware and network before planning")
    if h["inventory"]["arch"] != "x86_64" or not h["inventory"]["machine"] or not h["network"]:
        raise Failure("Reviewed x86_64 hardware and networking required")
    if (
        not re.fullmatch(r"[0-9a-f]{8}", h["identity"]["hostId"])
        or h["identity"]["hostId"] == "00000000"
    ):
        raise Failure("Explicit nonzero ZFS host ID required")
    budgets = (
        {"arcMaxMiB"}
        if h["platform"] == "hcloud"
        else {"guestMemoryMiB", "guestCpuCores", "arcMaxMiB"}
    )
    if set(h["budgets"]) != budgets or any(
        type(h["budgets"][k]) is not int or h["budgets"][k] <= 0 for k in budgets
    ):
        raise Failure("Explicit positive production resource budgets required")
    disks = {d["id"]: d for d in h["inventory"]["disks"]}
    if len(disks) != len(h["inventory"]["disks"]):
        raise Failure("Duplicate disk identity")
    for d in disks.values():
        if (
            not re.fullmatch(r"/dev/disk/by-id/[A-Za-z0-9_.:+-]+", d["device"])
            or not d["serial"]
            or d["size"] <= 0
        ):
            raise Failure("Stable whole-disk identity required")
    system, guests = h["storage"]["system"], h["storage"]["guests"]
    if (
        len(set(system + guests)) != len(system + guests)
        or not set(system + guests) <= disks.keys()
    ):
        raise Failure("Ambiguous storage selection")
    if h["platform"] == "hetzner":
        if (
            len(system) != 2
            or guests
            or type(h["storage"]["quotaBytes"]) is not int
            or h["storage"]["quotaBytes"] <= 0
        ):
            raise Failure("Hetzner requires two system disks and a reviewed guest quota")
    elif h["platform"] == "hcloud":
        # @cc [owner:ghuntley,label:deployment;capacity] hcloud-single-zfs-root
        # A Hetzner Cloud host MUST select exactly one system disk, no guest
        # disks, no guest quota and no Lilly role.
        if (
            len(system) != 1
            or guests
            or h["storage"]["quotaBytes"] not in (None, 0)
            or "lilly" in h
        ):
            raise Failure("Hetzner Cloud requires one system disk and no guest storage or Lilly")
    elif (
        any(d["kind"] not in ("ebs", "local-nvme") for d in disks.values())
        or len(system) != 1
        or disks[system[0]]["kind"] != "ebs"
        or not guests
        or set(guests) != {d["id"] for d in disks.values() if d["kind"] == "local-nvme"}
    ):
        raise Failure("EC2 requires one EBS root and every local NVMe drive")
    if not 9 <= h["storage"]["ashift"] <= 16:
        raise Failure("Invalid ashift")
    if h["git"]["repository"] != REPOSITORY and not re.fullmatch(
        r"ssh://[A-Za-z0-9@./:_-]+", h["git"]["repository"]
    ):
        raise Failure("Updates require a repository over SSH")
    return h


@contextlib.contextmanager
def published(repository: str, revision: str) -> Generator[Path]:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise Failure("Use a full published Git commit")
    if not repository.startswith("ssh://") or not re.fullmatch(
        r"ssh://[A-Za-z0-9@./:_-]+", repository
    ):
        raise Failure("Use a credential-free SSH repository URL")
    with tempfile.TemporaryDirectory(prefix="overalls-published-") as directory:
        root = Path(directory)
        # Existing local Git SSH trust/authentication is required; never accept new keys.
        env = dict(os.environ, GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes")
        run(
            [
                "git",
                "clone",
                "--no-checkout",
                "--single-branch",
                "--branch",
                "trunk",
                repository,
                root,
            ],
            env=env,
        )
        run(["git", "-C", root, "merge-base", "--is-ancestor", revision, "origin/trunk"])
        run(["git", "-C", root, "checkout", "--detach", revision])
        if not (root / "flake.lock").is_file():
            raise Failure("Published lockfile required")
        yield root


def build(root: Path, name: str, attr: str) -> str:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", name):
        raise Failure("Invalid configuration attribute")
    ref = f"git+file://{root}#nixosConfigurations.{name}.config.system.build.{attr}"
    paths: list[dict[str, dict[str, str]]] = json.loads(
        run(["nix", "build", "--no-link", "--json", "--no-write-lock-file", ref])
    )
    return paths[0]["outputs"]["out"]


def write_new(path: str, value: object) -> None:
    with open(path, "x", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def default_routes(routes: list[dict[str, object]]) -> list[dict[str, object]]:
    """Keep only each default route's interface, without addresses."""
    kept: list[dict[str, object]] = []
    for route in routes:
        entry: dict[str, object] = {"dev": route.get("dev"), "dst": "default"}
        if route.get("dst") == "default" and entry not in kept:
            kept.append(entry)
    return kept


def uplink_facts(h: Host, facts: Facts) -> remote.Uplink | None:
    """Live addressing for the uplink recovery copy, from authenticated facts.

    Fleet addresses live in SOPS, so a freshly installed base system has no
    document; the recovery copy is its only addressing until enrollment.
    """
    declared = h.get("addresses", {}).get("uplink")
    if declared is None:
        return None
    match = h["network"].get(declared["network"])
    mac = match.get("matchConfig", {}).get("MACAddress") if isinstance(match, dict) else None
    nic = next((n for n in facts["addresses"] if mac and n.get("address") == mac), None)
    if nic is None:
        raise Failure("Declared uplink interface was not observed")
    addresses = [
        f"{a['local']}/{a['prefixlen']}"
        for a in nic["addr_info"]
        if a["scope"] == "global" and ":" not in a["local"]
    ]
    routes = [
        r
        for r in facts["routes"]
        if r.get("dev") == nic["ifname"]
        and r.get("table", "main") == "main"
        and r.get("type", "unicast") == "unicast"
        and isinstance(r.get("gateway"), str)
        and ":" not in str(r["gateway"])
    ]
    gateways = {str(r["gateway"]) for r in routes if r.get("dst") == "default"}
    if not addresses or len(gateways) != 1:
        raise Failure("Uplink needs observed IPv4 addresses and one default gateway")
    (gateway,) = gateways
    hosts = sorted(
        {
            str(r["dst"])
            for r in routes
            if r.get("gateway") == gateway and "/" not in str(r.get("dst", "/"))
        }
        - {"default"}
    )
    return {"addresses": addresses, "gateway": gateway, "routes": hosts}


def discover(args: argparse.Namespace) -> None:
    facts: Facts = probe(args)
    disks = facts["inventory"]["disks"]
    local = [d["id"] for d in disks if d["kind"] == "local-nvme"]
    roots = [d["id"] for d in disks if d["kind"] == "ebs" and d["active"]]
    network: dict[str, object] = {}
    for nic in facts["addresses"]:
        if nic["ifname"] == "lo" or not nic.get("address"):
            continue
        entry: dict[str, object] = {"matchConfig": {"MACAddress": nic["address"]}}
        if args.platform == "ec2":
            entry["networkConfig"] = {"DHCP": "yes"}
        elif args.platform == "hcloud":
            # @cc [owner:ghuntley,label:security;deployment] hcloud-addresses-outside-repository
            # Hetzner Cloud candidates MUST NOT carry address literals: IPv4
            # comes from the provider's DHCP, and the fleet tunnel is IPv4-only,
            # so IPv6 is not configured. Listeners and grants take the address
            # from the shared SOPS document (fleet-addresses-from-sops).
            entry["networkConfig"] = {
                "DHCP": "ipv4",
                "IPv6AcceptRA": False,
                "LinkLocalAddressing": "no",
            }
        else:
            entry["networkConfig"] = {
                "Address": [
                    f"{a['local']}/{a['prefixlen']}"
                    for a in nic["addr_info"]
                    if a["scope"] == "global"
                ]
            }
        network["10-" + nic["ifname"]] = entry
    candidate: dict[str, object] = {
        "name": safe_name(args.name),
        "reviewed": False,
        "platform": args.platform,
        "firmware": facts["firmware"],
        "inventory": facts["inventory"],
        "network": network,
        "identity": {"hostId": "", "sshKeys": []},
        "storage": {
            "system": roots if args.platform == "ec2" else [],
            "guests": local if args.platform == "ec2" else [],
            "quotaBytes": None,
            "ashift": 12,
        },
        "budgets": {"arcMaxMiB": None}
        if args.platform == "hcloud"
        else {
            "guestMemoryMiB": None,
            "guestCpuCores": None,
            "arcMaxMiB": None,
        },
        "git": {"repository": REPOSITORY, "knownHosts": ""},
        "credentials": [],
        "discovery": {
            "sourceKey": facts["hostKey"],
            "routes": default_routes(facts["routes"])
            if args.platform == "hcloud"
            else facts["routes"],
        },
    }
    write_new(args.output, candidate)


def plan(args: argparse.Namespace) -> None:
    with published(args.repository, args.revision) as root:
        h = validate(
            json.loads((root / "fleet/hosts" / safe_name(args.host) / "host.json").read_text())
        )
        if h["identity"]["sshKeys"] or h["credentials"]:
            raise Failure(
                "Installation creates a new identity; publish a base declaration without host keys or credential references"
            )
        facts: Facts = probe(args)
        remote.match(h["inventory"], facts["inventory"])
        if h["firmware"] != facts["firmware"]:
            raise Failure("Reviewed firmware differs")
        system = build(root, args.host + "-base", "toplevel")
        install = build(root, args.host + "-base", "overallsHostInstall")
        tarball = (
            run(
                [
                    "nix",
                    "build",
                    "--no-link",
                    "--print-out-paths",
                    "--no-write-lock-file",
                    f"git+file://{root}#host-kexec",
                ]
            )
            .decode()
            .strip()
        )
        tarballs = list(Path(tarball).rglob("*.tar.*"))
        if len(tarballs) != 1:
            raise Failure("Expected exactly one pinned kexec tarball")
        value: Plan = {
            "version": 1,
            "host": h,
            "target": args.target,
            "sourceKey": facts["hostKey"],
            "sshPort": ssh_port(args),
            "installerSshPort": ssh_port(installer_connection(args)),
            "revision": args.revision,
            "repository": args.repository,
            "system": system,
            "install": install,
            "kexec": str(tarballs[0]),
            "erase": h["storage"]["system"] + h["storage"]["guests"],
        }
        write_new(args.output, value)
        print("Plan written; erasure authorization: --erase " + digest(value))
        print(
            "Disks to erase: "
            + ", ".join(d["device"] for d in h["inventory"]["disks"] if d["id"] in value["erase"])
        )


def anywhere(args: argparse.Namespace, plan: Plan, phases: str, target: str) -> None:
    run(
        [
            "nixos-anywhere",
            "--target-host",
            target,
            "-i",
            str(Path(args.identity).resolve()),
            "--ssh-option",
            "UserKnownHostsFile=" + str(Path(args.known_hosts).resolve()),
            "--ssh-option",
            "GlobalKnownHostsFile=/dev/null",
            "--ssh-option",
            "BatchMode=yes",
            "--ssh-option",
            "HostKeyAlgorithms=ssh-ed25519",
            "--ssh-port",
            str(ssh_port(args)),
            "--post-kexec-ssh-port",
            str(ssh_port(installer_connection(args))),
            "--store-paths",
            plan["install"],
            plan["system"],
            "--kexec",
            plan["kexec"],
            *kexec_flags(plan["host"]),
            "--phases",
            phases,
        ]
    )


def kexec_flags(host: Host) -> list[str]:
    """@cc [owner:ghuntley,label:deployment] hcloud-legacy-kexec-syscall
    Hetzner Cloud images refuse kexec_file_load for the unsigned installer
    kernel (EADDRNOTAVAIL), so hcloud installs MUST force the kexec_load
    syscall. Other platforms keep the installer's automatic selection.
    """
    return ["--kexec-extra-flags", "--kexec-syscall"] if host["platform"] == "hcloud" else []


# @cc [owner:ghuntley,label:security] installation-transport-binding
# Installation MUST reject source/installer port changes against the approved
# plan before contacting the target. Plans MUST carry both port fields.
# Kexec completion MUST switch to the installer port.
def install(args: argparse.Namespace) -> None:
    p: Plan = json.loads(Path(args.plan).read_text())
    installer_args = installer_connection(args)
    if (
        p["version"] != 1
        or args.erase != digest(p)
        or args.target != p["target"]
        or ssh_port(args) != p["sshPort"]
        or ssh_port(installer_args) != p["installerSshPort"]
    ):
        raise Failure("Installation requires this plan's explicit erasure digest, target and ports")
    validate(p["host"])
    if p["host"]["identity"]["sshKeys"] or p["host"]["credentials"]:
        raise Failure("Destructive installation requires an unenrolled base declaration")
    state = Path(args.plan + ".state.json")
    previous: dict[str, object] = json.loads(state.read_text()) if state.exists() else {}
    if previous.get("phase") == "complete":
        raise Failure("Installation completed; use enroll or create a new maintenance plan")
    phase: str = "validate"

    def save() -> None:
        remote.atomic(state, {"plan": digest(p), "phase": phase})

    save()
    try:
        with published(p["repository"], p["revision"]) as root:
            declared = validate(
                json.loads((root / "fleet/hosts" / p["host"]["name"] / "host.json").read_text())
            )
            if (
                declared != p["host"]
                or build(root, p["host"]["name"] + "-base", "toplevel") != p["system"]
                or build(root, p["host"]["name"] + "-base", "overallsHostInstall") != p["install"]
            ):
                raise Failure("Plan differs from published build")
            tarball = (
                run(
                    [
                        "nix",
                        "build",
                        "--no-link",
                        "--print-out-paths",
                        "--no-write-lock-file",
                        f"git+file://{root}#host-kexec",
                    ]
                )
                .decode()
                .strip()
            )
            if str(next(Path(tarball).rglob("*.tar.*"))) != p["kexec"]:
                raise Failure("Installer differs from published build")
        facts: Facts = probe(args)
        remote.match(p["host"]["inventory"], facts["inventory"])
        if facts["hostKey"] != p["sourceKey"] or facts["firmware"] != p["host"]["firmware"]:
            raise Failure("Authenticated target changed")
        phase = "kexec"
        save()
        anywhere(args, p, "kexec", args.target)
        installer_target = "root@" + args.target.split("@", 1)[1]
        phase = "installer-validation"
        save()
        probe(installer_args, "guard", p["host"], installer_target)
        phase = "format-install"
        save()
        anywhere(installer_args, p, "disko,install", installer_target)
        phase = "identity"
        save()
        # Named users must traverse /etc/ssh to read public authorized keys.
        # The generated private key itself remains mode 0600.
        ssh(
            installer_args,
            [
                "sh",
                "-eu",
                "-c",
                "umask 077; install -d -m 755 /mnt/etc/ssh; test ! -e /mnt/etc/ssh/ssh_host_ed25519_key; ssh-keygen -q -t ed25519 -N '' -f /mnt/etc/ssh/ssh_host_ed25519_key",
            ],
            target=installer_target,
        )
        key = (
            ssh(
                installer_args,
                ["cat", "/mnt/etc/ssh/ssh_host_ed25519_key.pub"],
                target=installer_target,
            )
            .decode()
            .strip()
        )
        installed: dict[str, object] = {
            "plan": digest(p),
            "hostKey": " ".join(key.split()[:2]),
            "revision": p["revision"],
            "host": p["host"]["name"],
        }
        installed["storage"] = probe(
            installer_args,
            "install-baseline",
            {
                "host": p["host"],
                "binding": json.loads(
                    Path(p["system"] + "/etc/overalls-installation.json").read_text()
                ),
            },
            installer_target,
        )
        uplink = uplink_facts(p["host"], facts)
        if uplink is not None:
            phase = "uplink-recovery"
            save()
            probe(installer_args, "install-uplink", uplink, installer_target)
        phase = "base-source"
        save()
        probe(installer_args, "install-base-source", target=installer_target)
        receipt_path = Path(args.plan + ".installed.json")
        remote.atomic(receipt_path, installed)
        phase = "reboot"
        save()
        anywhere(installer_args, p, "reboot", installer_target)
        print("Installed public identity recorded in " + str(receipt_path))
        print("Authenticate the next connection with this key: " + installed["hostKey"])
        phase = "complete"
        save()
    except Exception:
        raise Failure(
            f"Installation interrupted at {phase}; state: {state}. Any destructive retry requires renewed --erase authorization."
        ) from None


def encrypt(args: argparse.Namespace) -> None:
    # Reuse SecretSpec/SOPS inventory tooling, keeping plaintext in private temp storage.
    root = Path(args.root).resolve(strict=True)
    key = Path(args.deploy_key).resolve(strict=True)
    if key.is_relative_to(root) or key.is_relative_to("/nix/store") or key.stat().st_mode & 0o077:
        raise Failure("Deploy key must be a private file outside the checkout/store")
    h: Host = json.loads((root / "fleet/hosts" / args.host / "host.json").read_text())
    facts: Facts = probe(args)
    if facts["hostKey"] not in [" ".join(k.split()[:2]) for k in h["identity"]["sshKeys"]]:
        raise Failure("Installed public key must be recorded before encryption")
    with tempfile.TemporaryDirectory(prefix="overalls-enroll-") as directory:
        plaintext = Path(directory) / "git.json"
        # SecretSpec's SOPS provider consumes the named production profile.
        plaintext.write_text(
            json.dumps({"overalls-git": {"production": {"GIT_DEPLOY_KEY": key.read_text()}}})
        )
        plaintext.chmod(0o600)
        run(
            [
                "nix",
                "run",
                str(root) + "#secrets",
                "--",
                "encrypt",
                args.host + "-git",
                "--root",
                root,
                "--input",
                plaintext,
            ]
        )
    print(
        "Encrypted shared deploy key. Publish the host declaration and ciphertext, then enroll --revision COMMIT."
    )


def enroll(args: argparse.Namespace) -> None:
    if args.deploy_key:
        return encrypt(args)
    if not args.revision or not args.install_receipt:
        raise Failure("Activation requires a published --revision and --install-receipt")
    installed: InstallReceipt = json.loads(Path(args.install_receipt).read_text())
    facts: Facts = probe(args)
    if facts["hostKey"] != installed["hostKey"] or installed["host"] != args.host:
        raise Failure("Installed identity does not match authenticated target")
    with published(args.repository, args.revision) as root:
        h = validate(
            json.loads((root / "fleet/hosts" / safe_name(args.host) / "host.json").read_text())
        )
        if facts["hostKey"] not in [" ".join(k.split()[:2]) for k in h["identity"]["sshKeys"]]:
            raise Failure("Published declaration does not bind installed key")
        remote.match(h["inventory"], facts["inventory"])
        baseline: StorageFacts = probe(args, "verify", extra=("/etc/overalls-host.json",))
        if {k: v for k, v in baseline.items() if k != "binding"} != {
            k: v for k, v in installed["storage"].items() if k != "binding"
        }:
            raise Failure("Installed storage receipt differs")
        old_binding: Binding = json.loads(json.dumps(baseline["binding"]))
        old_binding["identity"].pop("sshKeys", None)
        proposed: Binding = json.loads(
            Path(build(root, args.host, "overallsHostBinding")).read_text()
        )
        proposed["identity"].pop("sshKeys", None)
        if old_binding != proposed:
            raise Failure("Enrollment cannot change installation bindings")
        build(root, args.host, "toplevel")
        activation = build(root, args.host, "overallsHostEnrollment")
        env = dict(os.environ, NIX_SSHOPTS=shlex.join(connection(args)[1:-1]))
        # Locally built closures are unsigned. Trust is the pinned admin SSH
        # connection and exact published build, not a public binary-cache key.
        run(
            ["nix", "copy", "--no-check-sigs", "--to", "ssh-ng://" + args.target, activation],
            env=env,
        )
        command = ["sudo", "-n", activation, args.revision]
        if args.rebind_empty_lilly:
            command.append("--rebind-empty-lilly")
        ssh(args, command)
        print("Enrollment verified; receipt persisted and polling enabled.")


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in (
        "discover",
        "plan",
        "install",
        "enroll",
        "verify",
        "prepare-enrollment",
        "rotate-credential",
    ):
        p = sub.add_parser(name)
        for flag in ("target", "known-hosts", "identity"):
            p.add_argument("--" + flag, required=True)
        p.add_argument("--ssh-port", type=int, default=22, help="Administrative target SSH port")
        if name in ("plan", "install"):
            p.add_argument("--installer-ssh-port", type=int, default=22)
        if name in ("plan", "enroll"):
            p.add_argument("--host", required=True, type=safe_name)
            p.add_argument("--repository", default=REPOSITORY)
            p.add_argument("--revision", required=name == "plan")
        if name in ("plan", "discover"):
            p.add_argument("--output", required=True)
        if name == "discover":
            p.add_argument("--platform", choices=PLATFORMS, required=True)
            p.add_argument("--name", required=True)
        if name == "install":
            p.add_argument("--plan", required=True)
            p.add_argument("--erase", required=True)
        if name in ("prepare-enrollment", "rotate-credential"):
            p.add_argument("--host", required=True, type=safe_name)
            p.add_argument("--root", default=".")
            p.add_argument("--marshall-target", required=True)
            p.add_argument("--marshall-ssh-port", type=int, default=22)
            p.add_argument("--recovery-key", required=True)
            p.add_argument("--install-receipt", required=True)
        if name == "enroll":
            p.add_argument("--deploy-key")
            p.add_argument("--root", default=".")
            p.add_argument("--install-receipt")
            p.add_argument(
                "--rebind-empty-lilly",
                action="store_true",
                help="Replace stale Lilly control-plane ownership only after proving the host empty",
            )
    args = parser.parse_args()
    try:
        if args.command in ("prepare-enrollment", "rotate-credential"):
            sys.modules.setdefault("cli", sys.modules[__name__])
            import preparation

            try:
                preparation.prepare(args)
            except preparation.custody.Failure as exc:
                raise Failure(str(exc)) from None
        elif args.command == "verify":
            print(
                json.dumps(
                    probe(args, "verify", extra=("/etc/overalls-host.json", "--receipt")), indent=2
                )
            )
        else:
            handler: Callable[[argparse.Namespace], None] = globals()[args.command]
            handler(args)
    except (Failure, ValueError, KeyError, OSError, TypeError) as exc:
        # Never print tool output or JSON values that could contain private inputs.
        print(
            str(exc)
            if isinstance(exc, Failure)
            else "Invalid host configuration or inaccessible input",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
