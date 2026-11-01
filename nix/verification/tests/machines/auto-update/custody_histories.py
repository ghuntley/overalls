"""Generated updater custody/recovery histories; no native deployment is performed.

Runs inside a user/mount namespace as uid 0 with the production
/run/overalls-auto-update, /var/lib/overalls-auto-update, /run/current-system and
/run/overalls-secrets paths confined to a disposable fixture root. Secret
resolution uses the real ssh-to-age/sops/secretspec toolchain through the
production runtime and prepare.py; systemd, Git, Nix and clocks are explicit
world-model seams. Establishes no machine acceptance.
"""

import base64
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import NoReturn
from unittest.mock import patch

from hypothesis import example, given, settings
from hypothesis import strategies as st

# isort: split
# The executable Nix check copies the actual production runtime beside this file.
import updater_runtime as updater

if len(sys.argv) < 3:
    raise RuntimeError("usage: custody_histories.py PREPARE_PY [CLI_PY]")
PREPARE_PATH = Path(sys.argv[1]).resolve(strict=True)
CLI_PATH = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) > 2 else None
del sys.argv[1 : min(len(sys.argv), 3)]

WORK = Path(os.environ.get("CUSTODY_WORK", "/work"))
STATE = Path("/var/lib/overalls-auto-update")
RUNTIME = Path("/run/overalls-auto-update")
ACTIVE = Path("/run/current-system")
if (
    str(updater.STATE) != str(STATE)
    or str(updater.RUNTIME) != str(RUNTIME)
    or str(updater.ACTIVE) != str(ACTIVE)
):
    raise RuntimeError("production state paths changed; review the fixture roots")


class HarnessError(BaseException):
    """Fixture/oracle failure; MUST NOT be absorbed by the production handler."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise HarnessError(message)


def impossible(message: str) -> NoReturn:
    raise HarnessError(message)


def int_value(value: object) -> int:
    if type(value) is not int:
        raise HarnessError("expected an integer")
    return value


def object_map(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise HarnessError("expected an object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise HarnessError("object keys must be strings")
        result[key] = item
    return result


def object_str_map(value: object) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, item in object_map(value).items():
        if not isinstance(item, str):
            raise HarnessError("entries must be strings")
        result[key] = item
    return result


def string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        raise HarnessError("expected an array")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise HarnessError("array entries must be strings")
        result.append(item)
    return result


def tool(name: str) -> str:
    found = shutil.which(name)
    if found is None:
        raise HarnessError(name + " missing from PATH")
    if not Path(found).is_file():
        raise HarnessError(name + " is not a file")
    return found


TOOLS = {name: tool(name) for name in ["sops", "ssh-to-age", "age-keygen", "ssh-keygen"]}
TOOL_PATH = str(Path(TOOLS["sops"]).resolve().parent)
SECRETSPEC = tool("secretspec")


def capture(arguments: list[str], input_bytes: bytes | None = None) -> bytes:
    result = subprocess.run(arguments, input=input_bytes, capture_output=True, timeout=120)
    require(result.returncode == 0, f"fixture tool failed: {arguments[0]}")
    return result.stdout


def parse_environment(path: Path) -> dict[str, str]:
    return parse_environment_data(path.read_bytes())


def parse_environment_data(data: bytes) -> dict[str, str]:
    """Strict parser for exactly the quoting render() emits into EnvironmentFiles."""
    values: dict[str, str] = {}
    index = 0
    while index < len(data):
        end = data.index(b"=", index)
        name = data[index:end].decode()
        require(re.fullmatch(r"[A-Z_][A-Z0-9_]*", name) is not None, "fixture env name")
        require(data[end + 1 : end + 2] == b'"', "fixture env value must be quoted")
        out = bytearray()
        cursor = end + 2
        while data[cursor] != 0x22:
            if data[cursor] == 0x5C:
                cursor += 1
                require(data[cursor] in (0x22, 0x5C), "unknown env escape")
            out.append(data[cursor])
            cursor += 1
        cursor += 1
        require(data[cursor : cursor + 1] == b"\n", "env line must end after quote")
        values[name] = bytes(out).decode()
        index = cursor + 1
    return values


@dataclass(frozen=True)
class Identity:
    """A synthetic custody identity: SSH keypair plus its derived age recipient."""

    name: str
    ssh_private: Path
    age_recipient: str


def make_identity(root: Path, name: str) -> Identity:
    private = root / (name + ".ssh")
    capture([TOOLS["ssh-keygen"], "-q", "-t", "ed25519", "-N", "", "-f", str(private)])
    recipient = capture([TOOLS["ssh-to-age"], "-i", str(private) + ".pub"]).decode().strip()
    require(re.fullmatch(r"age1[0-9a-z]{58}", recipient) is not None, "fixture recipient")
    return Identity(name, private, recipient)


def encrypt_document(
    path: Path, project: str, values: Mapping[str, str], recipients: list[str]
) -> None:
    require(len(recipients) == len(set(recipients)), "duplicate recipient")
    payload = json.dumps({project: {"production": dict(values)}}).encode()
    ciphertext = capture(
        [
            TOOLS["sops"],
            "--encrypt",
            "--age",
            ",".join(recipients),
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        payload,
    )
    temporary = path.with_name(path.name + ".new")
    temporary.write_bytes(ciphertext)
    os.replace(temporary, path)
    path.chmod(0o640)


def oracle_plaintext(path: Path, identity: Identity | None) -> dict[str, object] | None:
    """Independent decryptor: plaintext object for a recipient, None otherwise."""
    if identity is None:
        return None
    age = capture([TOOLS["ssh-to-age"], "-private-key", "-i", str(identity.ssh_private)])
    identity_file = path.parent / (".oracle-" + identity.name + ".age")
    identity_file.write_bytes(age)
    identity_file.chmod(0o600)
    try:
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(path.parent),
            "SOPS_AGE_KEY_FILE": str(identity_file),
            "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
        }
        result = subprocess.run(
            [TOOLS["sops"], "--decrypt", "--output-type", "json", str(path)],
            capture_output=True,
            timeout=120,
            env=env,
        )
        if result.returncode != 0:
            return None
        parsed = json.loads(result.stdout)
        require(isinstance(parsed, dict), "oracle plaintext must be an object")
        return parsed
    finally:
        identity_file.unlink(missing_ok=True)


@dataclass(frozen=True)
class OutputSpec:
    format: str
    secrets: list[str]


def descriptor(
    root: Path,
    name: str,
    encrypted: str,
    outputs: Mapping[str, OutputSpec],
    host: Identity,
) -> str:
    """Same descriptor JSON shape as nix/domains/system/secrets/default.nix renders."""
    manifest = root / (name + "-secretspec.toml")
    lines = ["[project]", 'name = "overalls-' + name + '"', 'revision = "1.0"', ""]
    secret_names = sorted({secret for output in outputs.values() for secret in output.secrets})
    for secret in secret_names:
        lines.append("[profiles.production." + secret + "]")
        lines.append('description = "Required deployment secret"')
        lines.append("required = true")
        lines.append("")
    manifest.write_text("\n".join(lines))
    runtime_dir = Path("/run/overalls-secrets-" + name)
    runtime_dir.mkdir(mode=0o700, exist_ok=True)
    descriptor_path = root / (name + "-descriptor.json")
    descriptor_path.write_text(
        json.dumps(
            {
                "hostKey": str(host.ssh_private),
                "runtime": str(runtime_dir),
                "encryptedFile": encrypted,
                "group": "root",
                "outputs": {
                    key: {"format": value.format, "secrets": value.secrets}
                    for key, value in outputs.items()
                },
                "destination": "/run/overalls-secrets/" + name,
                "manifest": str(manifest),
                "toolPath": TOOL_PATH,
                "sshToAge": TOOLS["ssh-to-age"],
                "secretspec": SECRETSPEC,
            },
            sort_keys=True,
        )
    )
    return str(descriptor_path)


@dataclass(frozen=True)
class Bundle:
    """One candidate revision: exact system directory plus deployment manifest."""

    label: str
    folder: Path
    system: Path
    manifest: dict[str, object]


def make_bundle(
    root: Path,
    label: str,
    secrets_map: Mapping[str, str],
    marshall_env: Path | None,
) -> Bundle:
    folder = root / "revisions" / (label + "-bundle")
    folder.mkdir(parents=True)
    system = root / "revisions" / (label + "-system")
    system.mkdir()
    marshall: dict[str, object] | None = None
    if marshall_env is not None:
        marshall = {
            "environmentFile": str(marshall_env),
            "databaseCAFile": str(root / "unused-database-ca.crt"),
            "migrate": str(root / "unused-migrator"),
            "instances": [],
        }
    manifest: dict[str, object] = {
        "version": 1,
        "installationBinding": None,
        "secrets": dict(secrets_map),
        "consumers": ["marshall-main.service"] if marshall else [],
        "diagnosticPreflight": [],
        "socketUnits": [],
        "healthUnits": ["marshall-main.service"] if marshall else [],
        "marshall": marshall,
        "lilly": None,
    }
    (system / "overalls-deployment.json").write_text(json.dumps(manifest, sort_keys=True))
    # Each synthetic generation replaces its units, matching World.switch's
    # complete process replacement rather than claiming unchanged-unit reuse.
    unit_directory = system / "etc/systemd/system"
    unit_directory.mkdir(parents=True)
    unit_names = ["overalls-secrets-" + name + ".service" for name in secrets_map]
    if marshall:
        unit_names.append("marshall-main.service")
    for unit in unit_names:
        (unit_directory / unit).write_text("[Unit]\nDescription=Fixture " + label + "\n")
    os.symlink(system, folder / "system")
    (folder / "manifest.json").write_text(json.dumps(manifest, sort_keys=True))
    return Bundle(label, folder, system, manifest)


@dataclass
class ClockStep:
    wall: float = 1_700_000_000.0
    mono: float = 10_000.0

    def time(self) -> float:
        return self.wall

    def monotonic(self) -> float:
        return self.mono

    def sleep(self, seconds: float) -> None:
        self.advance(seconds)

    def advance(self, seconds: float) -> None:
        require(seconds >= 0, "negative clock advance")
        self.wall += seconds
        self.mono += seconds


@dataclass
class UnitEntry:
    active: bool = False
    failed: bool = False


@dataclass(frozen=True)
class Mutation:
    """A concurrent-delivery race: re-encrypt a document during an activation."""

    system: str
    document: str
    project: str
    recipients: list[str]
    values: dict[str, str]


@dataclass
class World:
    """Fixture side of systemd/Git/Nix effects; logs every observable effect."""

    root: Path
    clock: ClockStep = field(default_factory=ClockStep)
    revisions: dict[str, Bundle] = field(default_factory=dict)
    head: str | None = None
    units: dict[str, UnitEntry] = field(default_factory=dict)
    serving: dict[str, dict[str, str]] = field(default_factory=dict)
    roster: dict[str, list[str]] = field(default_factory=dict)
    log: list[tuple[str, ...]] = field(default_factory=list)
    prepared: list[tuple[str, int, str]] = field(default_factory=list)
    resolutions: list[tuple[str, dict[str, bytes] | None]] = field(default_factory=list)
    migrations: list[str] = field(default_factory=list)
    switches: list[tuple[str, str]] = field(default_factory=list)
    outcome: dict[str, str] = field(default_factory=dict)
    secret_material: list[bytes] = field(default_factory=list)
    pending_mutations: list[Mutation] = field(default_factory=list)
    handoff_at_switch: dict[str, str] = field(default_factory=dict)
    staged_snapshot: dict[str, dict[str, bytes]] = field(default_factory=dict)
    checked_out: str | None = None

    def publish(self, bundle: Bundle) -> str:
        revision = "fx-rev-" + hashlib.sha256(bundle.label.encode()).hexdigest()[:12]
        self.revisions[revision] = bundle
        self.head = revision
        self.roster[str(bundle.system)] = sorted(
            set(
                string_list(bundle.manifest["healthUnits"])
                + string_list(bundle.manifest["consumers"])
                + [
                    "overalls-secrets-" + name + ".service"
                    for name in object_map(bundle.manifest["secrets"])
                ]
            )
        )
        return revision

    def expected_outcome(self, revision: str) -> str:
        return self.outcome.get(revision, "healthy")

    def unit_state(self, unit: str) -> str:
        entry = self.units.get(unit)
        if entry is not None and entry.failed:
            require(not entry.active, "failed unit cannot be active")
            return "failed"
        return "active" if entry is not None and entry.active else "inactive"

    def switch(self, system: str, channel: str) -> None:
        require(Path(system).is_dir(), "switch target must be a system directory")
        require((Path(system) / "overalls-deployment.json").is_file(), "missing manifest")
        ACTIVE.unlink(missing_ok=True)
        os.symlink(system, ACTIVE)
        self.units = {name: UnitEntry(active=False) for name in self.roster[system]}
        self.serving = {}
        self.switches.append((channel, system))
        handoff = RUNTIME / "handoff.json"
        self.handoff_at_switch = {}
        self.staged_snapshot = {}
        if handoff.exists():
            captured: object = json.loads(handoff.read_bytes())
            for key, value in object_map(captured).items():
                if not isinstance(value, str):
                    raise HarnessError("handoff entries must be strings")
                self.handoff_at_switch[key] = value
                directory = Path(value)
                if directory.is_dir():
                    self.staged_snapshot[key] = {
                        entry.name: entry.read_bytes() for entry in directory.iterdir()
                    }
        matched = [m for m in self.pending_mutations if m.system == system]
        self.pending_mutations = [m for m in self.pending_mutations if m.system != system]
        for mutation in matched:
            encrypt_document(
                Path(mutation.document),
                mutation.project,
                mutation.values,
                mutation.recipients,
            )

    def start(self, unit: str, channel: str) -> None:
        entry = self.units.get(unit)
        if entry is None:
            entry = UnitEntry()
            self.units[unit] = entry
        if unit.startswith("overalls-secrets-") and unit.endswith(".service"):
            self.prepare_secret_unit(unit, channel)
        elif unit.startswith("marshall-") and unit.endswith(".service"):
            environment = parse_environment(Path("/run/overalls-secrets/marshall/environment"))
            self.serving[unit] = environment
        entry.active = True
        entry.failed = False

    def stop(self, unit: str) -> None:
        entry = self.units.get(unit)
        if entry is not None:
            entry.active = False
            entry.failed = False
        self.serving.pop(unit, None)

    def prepare_secret_unit(self, unit: str, channel: str) -> None:
        """Run the real prepare.py script for the active generation's descriptor."""
        manifest = object_map(json.loads((ACTIVE / "overalls-deployment.json").read_bytes()))
        name = unit.removeprefix("overalls-secrets-").removesuffix(".service")
        descriptor_path = object_map(manifest.get("secrets", {})).get(name)
        if descriptor_path is None or not isinstance(descriptor_path, str):
            self.prepared.append((unit, 1, "/dev/null"))
            raise updater.UpdateError("activate_failed")
        try:
            result = subprocess.run(
                [sys.executable, str(PREPARE_PATH), str(descriptor_path)],
                capture_output=True,
                timeout=300,
            )
        except subprocess.TimeoutExpired as error:
            raise HarnessError("prepare subprocess timed out") from error
        self.prepared.append((unit, result.returncode, str(descriptor_path)))
        if result.returncode != 0:
            self.stop(unit)
            self.units[unit].failed = True
            raise updater.UpdateError("activate_failed")

    def command(
        self, deployment: "FixtureDeployment", arguments: list[str], capture_flag: bool
    ) -> str:
        self.log.append(tuple(arguments))
        head = arguments[0]
        if head == "git":
            return self.git_command(arguments, capture_flag)
        if head == "env":
            return self.buck2_command(arguments)
        if head == "nix-store":
            return self.nix_store_command(arguments)
        if head == "nixos-rebuild":
            require(arguments[1:4] == ["switch", "--no-reexec", "--store-path"], "switch args")
            self.switch(arguments[4], "updater")
            return ""
        if head == "systemctl":
            return self.systemctl(arguments, capture_flag)
        if head == "systemd-run":
            require(deployment.phase == "migrate", "only the migrator may use systemd-run")
            require("--unit=overalls-auto-update-migrate" in arguments, "unknown unit name")
            self.migrations.append(str(self.head))
            return ""
        return impossible("unexpected command in custody fixture: " + head)

    def git_command(self, arguments: list[str], capture_flag: bool) -> str:
        if arguments[1:3] == ["init", "--bare"]:
            Path(arguments[3]).mkdir(parents=True, exist_ok=True)
            return ""
        if arguments[1] == "check-ref-format":
            return ""
        if arguments[1].startswith("--git-dir="):
            rest = arguments[2:]
            if rest[0] == "fetch":
                return ""
            if rest[0] == "worktree":
                if rest[1:4] != ["add", "--force", "--detach"]:
                    return impossible("worktree arguments")
                checkout = Path(rest[4])
                if checkout != updater.CHECKOUT or checkout.exists():
                    return impossible("the fixed checkout must be created once")
                (checkout / "tools").mkdir(mode=0o700, parents=True)
                (checkout / ".git").write_text("gitdir: fixture\n")
                wrapper = checkout / "tools" / "buck2"
                wrapper.write_text("#!/bin/false\n")
                wrapper.chmod(0o700)
                self.checked_out = rest[5]
                return ""
            if rest[0] == "rev-parse":
                if not capture_flag:
                    raise HarnessError("rev-parse must capture")
                if self.head is None:
                    raise HarnessError("nothing published")
                return self.head
        if arguments[1:3] == ["-C", str(updater.CHECKOUT)]:
            rest = arguments[3:]
            if rest[:4] == ["checkout", "--quiet", "--force", "--detach"]:
                self.checked_out = rest[4]
                return ""
            if rest[0] == "clean":
                return ""
            if rest == ["rev-parse", "HEAD"] and capture_flag and self.checked_out:
                return self.checked_out
        return impossible("unexpected git command: " + " ".join(arguments))

    def buck2_command(self, arguments: list[str]) -> str:
        """Models the candidate checkout's tools/buck2 deployment build."""
        wrapper = str(updater.CHECKOUT / "tools" / "buck2")
        require(arguments[1:3] == ["-C", str(updater.CHECKOUT)], "buck2 runs in the checkout")
        require(
            arguments[3:5]
            == [
                "HOME=" + str(updater.BUCK2_HOME),
                "OVERALLS_GCROOT_DIR=" + str(updater.BUCK2_GCROOTS),
            ],
            "private buckd state and GC roots",
        )
        require(arguments[5:8] == [wrapper, "--isolation-dir", updater.BUCK2_ISOLATION], "wrapper")
        rest = arguments[8:]
        if rest == ["--version"]:
            return ""
        require(rest[:2] == ["build", "--console=simple"], "only deployment builds are modeled")
        if self.checked_out is None:
            raise HarnessError("build before checkout")
        require(rest[2:4] == ["-c", "overalls.revision=" + self.checked_out], "revision")
        target = "//fleet/hosts/host:deployment"
        require(rest[4:6] == [target, "--show-full-output"], "deployment target")
        report = updater.CHECKOUT / "buck-out" / "store-path"
        report.parent.mkdir(exist_ok=True)
        report.write_text(str(self.revisions[self.checked_out].folder) + "\n")
        return "root" + target + " " + str(report)

    def nix_store_command(self, arguments: list[str]) -> str:
        require(arguments[1] == "--add-root" and arguments[3] == "--realise", "root the bundle")
        link = Path(arguments[2])
        link.unlink(missing_ok=True)
        os.symlink(arguments[4], link)
        return ""

    def systemctl(self, arguments: list[str], capture_flag: bool) -> str:
        """@cc [owner:ghuntley,label:verification] custody-failed-unit-query
        The unfiltered failed-unit query MUST return exactly modeled failed units,
        excluding inactive and active units. Unsupported query flags MUST fail
        closed rather than being interpreted as an empty failed-unit result.
        """
        verb = arguments[1]
        if verb == "show":
            require(arguments[2].startswith("--property="), "property required")
            require(arguments[3] == "--value", "--value required")
            require(capture_flag, "show must capture")
            unit = arguments[4]
            prop = arguments[2].removeprefix("--property=")
            if prop == "ActiveState":
                return self.unit_state(unit)
            if prop == "LoadState":
                return "loaded" if unit in self.units else "not-found"
            return impossible("unexpected property " + prop)
        if verb == "is-active":
            require(arguments[2] == "--quiet", "is-active must be quiet")
            require(not capture_flag, "is-active must not capture")
            if self.unit_state(arguments[-1]) != "active":
                raise updater.UpdateError("lookup_failed")
            return ""
        if verb == "stop":
            for unit in arguments[2:]:
                self.stop(unit)
            return ""
        if verb == "start":
            for unit in arguments[2:]:
                self.start(unit, "updater")
            return ""
        if verb == "list-units":
            require(capture_flag, "list-units must capture")
            if arguments[2:] == ["--failed", "--plain", "--no-legend"]:
                return "".join(
                    unit + " loaded failed failed synthetic\n"
                    for unit in self.units
                    if self.unit_state(unit) == "failed"
                )
            pattern = arguments[-1]
            if arguments[2:-1] == ["--plain", "--no-legend"] and pattern.endswith("-*.service"):
                prefix = pattern.removesuffix("*.service")
                return "".join(
                    unit + " loaded active running synthetic\n"
                    for unit, entry in self.units.items()
                    if entry.active and unit.startswith(prefix)
                )
            return impossible("unexpected unit pattern " + pattern)
        return impossible("unexpected systemctl verb " + verb)


class FixtureDeployment(updater.Deployment):
    """@cc [owner:ghuntley,label:verification] updater-custody-seam-boundary
    Histories MUST execute the production run/stage/preflight/activate/verify
    state machine, the real prepare.py resolution and the real SOPS toolchain.
    Only systemd/Git/Nix subprocesses, environment parsing, serving-process
    discovery and clocks are world-model seams; unexpected commands MUST fail
    closed. These local claims MUST NOT establish systemd, activation, database
    migration or native fleet acceptance.
    """

    def __init__(self, configuration: updater.Configuration, world: World) -> None:
        super().__init__(configuration)
        self.world = world
        helper = self.secrets
        real_resolve = helper.resolve

        def recorded(configuration: dict[str, object]) -> dict[str, bytes]:
            try:
                result = real_resolve(configuration)
            except Exception:
                world.resolutions.append((str(configuration["encryptedFile"]), None))
                raise
            world.resolutions.append((str(configuration["encryptedFile"]), result))
            return result

        helper.resolve = recorded  # ty: ignore[invalid-assignment] fixture records calls

    def command(self, arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
        del timeout
        return self.world.command(self, arguments, capture)

    def environment(self, path: str) -> dict[str, str]:
        return parse_environment(Path(path))

    def serving_environments(self, previous: Mapping[str, object]) -> list[dict[str, str]]:
        installed_path = ACTIVE / "overalls-deployment.json"
        installed = json.loads(installed_path.read_bytes()) if installed_path.exists() else {}
        require(previous == installed, "preflight must inspect the active manifest")
        return [dict(environment) for environment in self.world.serving.values()]


def make_config() -> updater.Configuration:
    return updater.Configuration(
        repository="https://unused.invalid/repository.git",
        branch="main",
        flakeAttr="host",
        healthTimeout=120,
        buildTimeout=7200,
        verbose=False,
        secretUnits=[],
        secretHelper=str(PREPARE_PATH),
        resourcePolicyHelper="",
    )


def read_state() -> dict[str, object]:
    status = STATE / "status.json"
    if not status.exists():
        return {}
    if stat.S_IMODE(status.stat().st_mode) != 0o600:
        raise HarnessError("status must stay private")
    return object_map(json.loads(status.read_bytes()))


STATE_KEYS = {
    "candidate",
    "phase",
    "updatedAt",
    "failures",
    "retryAt",
    "failure",
    "failedPhase",
    "activatedCandidate",
    "lastHealthy",
    "lastHealthySystem",
    "activeSystem",
    "builder",
}


class Model:
    """@cc [owner:ghuntley,label:verification] updater-durable-state-oplog
    Expected durable state MUST derive from the recorded operation log and the
    documented reason-code/backoff rules (failures capped at 16, delay
    min(900, 30*2**(failures-1))), never from reading updater internals. The
    harness MUST compare the complete status file against this model after
    every operation and MUST refuse unexplained keys.
    """

    def __init__(self) -> None:
        self.state: dict[str, object] = {}

    def identity(self, revision: str) -> dict[str, str]:
        return {
            "repository": "https://unused.invalid/repository.git",
            "branch": "main",
            "flakeAttr": "host",
            "revision": revision,
        }

    def expect_tick(self, world: World) -> tuple[int, list[dict[str, object]]]:
        """One timer firing at world.clock.wall: expected rc and event stream."""
        revision = world.head
        if revision is None:
            raise HarnessError("tick without candidate")
        identity = self.identity(revision)
        bundle = world.revisions[revision]
        state = self.state
        events: list[dict[str, object]] = [{"event": "update.phase", "phase": "fetch"}]
        state["phase"] = "fetch"
        same = state.get("candidate") == identity
        retry_at = int_value(state.get("retryAt", 0))
        if same and world.clock.wall < retry_at:
            return 0, events
        if not same:
            state.update(candidate=identity, failures=0, retryAt=0, failure=None)
        active_system = str(ACTIVE.resolve())
        healthy_here = state.get("lastHealthy") == identity and (
            state.get("lastHealthySystem") == active_system
        )
        if same and healthy_here:
            state.update(
                phase="healthy", activeSystem=active_system, failures=0, retryAt=0, failure=None
            )
            return 0, events
        events.append({"event": "update.phase", "phase": "build"})
        state["phase"] = "build"
        state["builder"] = "buck2"
        system = str((bundle.folder / "system").resolve())
        if same and state.get("lastHealthy") == identity and active_system == system:
            state.update(
                phase="healthy",
                activeSystem=system,
                lastHealthySystem=system,
                failures=0,
                retryAt=0,
                failure=None,
            )
            return 0, events
        manifest_path = ACTIVE / "overalls-deployment.json"
        active_matches = (
            active_system == system
            and manifest_path.exists()
            and json.loads(manifest_path.read_bytes()) == bundle.manifest
        )
        if active_matches:
            events.append({"event": "update.phase", "phase": "stage"})
            events.append({"event": "update.phase", "phase": "verify"})
            events.append({"event": "update.healthy", "revision": revision})
            state.update(
                activatedCandidate=identity,
                lastHealthy=identity,
                lastHealthySystem=system,
                activeSystem=system,
                phase="healthy",
                failures=0,
                retryAt=0,
                failure=None,
            )
            return 0, events
        require(
            state.get("activatedCandidate") != identity or active_system != system,
            "exact activated candidate must verify only",
        )
        outcome = world.expected_outcome(revision)
        if outcome == "healthy":
            events.extend(
                {"event": "update.phase", "phase": name}
                for name in ["stage", "preflight", "migrate", "activate"]
            )
            # Every synthetic generation replaces its unit definitions.
            events.append({"event": "update.units_retained", "count": 0})
            events.append({"event": "update.phase", "phase": "verify"})
            events.append({"event": "update.healthy", "revision": revision})
            state.update(
                activatedCandidate=identity,
                lastHealthy=identity,
                lastHealthySystem=system,
                activeSystem=system,
                phase="healthy",
                failures=0,
                retryAt=0,
                failure=None,
            )
            return 0, events
        phases = ["stage", "preflight", "migrate", "activate"]
        phase, reason = outcome.split("/", 1)
        require(phase in phases, "unknown failure phase " + phase)
        events.extend(
            {"event": "update.phase", "phase": name} for name in phases[: phases.index(phase) + 1]
        )
        events.append({"event": "update.failed", "phase": phase, "reason": reason})
        failures = min(int_value(state.get("failures", 0)) + 1, 16)
        delay = min(900, 30 * 2 ** (failures - 1))
        state.update(
            phase=phase,
            failedPhase=phase,
            failure=reason,
            failures=failures,
            retryAt=int(world.clock.wall) + delay,
            activeSystem=str(ACTIVE.resolve()),
        )
        return 1, events

    def check(self) -> None:
        state = read_state()
        extra = sorted(set(state) - STATE_KEYS)
        require(not extra, "unexpected updater state keys: " + repr(extra))
        if not state and not self.state:
            return
        require(isinstance(state.get("updatedAt"), int), "updatedAt must be recorded")
        for key, expected in self.state.items():
            require(
                state.get(key) == expected,
                f"durable state mismatch for {key}: {state.get(key)!r} != {expected!r}",
            )


def scan_leaks(world: World, outputs: str) -> None:
    status = STATE / "status.json"
    status_text = status.read_text() if status.exists() else ""
    for material in world.secret_material:
        require(material.decode() not in outputs, "secret material in updater output")
        require(material.decode() not in status_text, "secret material in durable state")
    require("AGE-SECRET-KEY-" not in outputs, "age identity in updater output")
    require("BEGIN OPENSSH PRIVATE KEY" not in outputs, "host key in updater output")


def check_runtime_invariants(terminal: str) -> None:
    handoff = RUNTIME / "handoff.json"
    staging = RUNTIME / "staging"
    if terminal in ("stage", "preflight", "migrate", "healthy"):
        require(not handoff.exists(), "stale handoff must not survive: " + terminal)
        require(not staging.exists(), "stale staging must not survive: " + terminal)


def tick(world: World, model: Model) -> tuple[int, list[dict[str, object]]]:
    """Fire one production main() against the world and compare with the model."""
    expected_rc, expected_events = model.expect_tick(world)
    config_path = world.root / "updater-config.json"
    config_path.write_text(json.dumps(make_config(), sort_keys=True))
    config_path.chmod(0o600)
    output = io.StringIO()
    factory = lambda configuration: FixtureDeployment(configuration, world)  # noqa: E731
    with (
        patch.object(updater, "Deployment", factory),
        patch.object(updater, "time", world.clock),
        # Fixture bundles are temporary folders rather than store paths.
        patch.object(updater, "DEPLOYMENT_PATH", re.compile(r"/.+-bundle")),
        patch.object(sys, "argv", ["overalls-auto-update", str(config_path)]),
        contextlib.redirect_stdout(output),
    ):
        rc = updater.main()
    events: list[dict[str, object]] = []
    for line in output.getvalue().splitlines():
        events.append(object_map(json.loads(line)))
    require(rc == expected_rc, f"exit {rc} != model {expected_rc}")
    require(events == expected_events, f"events {events} != model {expected_events}")
    model.check()
    scan_leaks(world, output.getvalue())
    terminal = "healthy" if expected_events[-1]["event"] == "update.healthy" else ""
    if expected_events[-1]["event"] == "update.failed":
        terminal = str(expected_events[-1]["phase"])
    if terminal:
        check_runtime_invariants(terminal)
    return rc, events


SECRET_NAMES = ["DATABASE_URL", "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET", "MARSHALL_CLOAK_KEYS"]
MANAGED_PATHS = [
    STATE,
    RUNTIME,
    Path("/run/overalls-secrets"),
    Path("/run/overalls-secrets-marshall"),
    Path("/run/overalls-secrets-git"),
]


def reset_machine_paths() -> None:
    """Between scenarios: purge confined machine paths (mountpoints keep their dirs)."""
    ACTIVE.unlink(missing_ok=True)
    for base in MANAGED_PATHS:
        if base.exists() or base.is_symlink():
            if base.is_symlink():
                base.unlink()
                continue
            for child in base.iterdir():
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        else:
            base.mkdir(mode=0o700 if base != Path("/run/overalls-secrets") else 0o755)
            base.chmod(0o700 if base != Path("/run/overalls-secrets") else 0o755)


def marshall_values(tag: str) -> dict[str, str]:
    keys = [
        {
            "id": f"fx-ring-{tag}-{index}",
            "key": base64.b64encode(hashlib.sha256(f"{tag}-{index}".encode()).digest()).decode(),
        }
        for index in range(2)
    ]
    return {
        "DATABASE_URL": f"postgresql://fixture:synthetic@db/fx-database-{tag}",
        "SECRET_KEY_BASE": f"fx-secret-base-{tag}",
        "TOKEN_SIGNING_SECRET": f"fx-token-{tag}",
        "MARSHALL_CLOAK_KEYS": json.dumps(keys),
    }


def marshall_stack(
    world: World,
    label: str,
    values: Mapping[str, str],
    recipients: list[str],
    host: Identity,
) -> tuple[Bundle, Path]:
    sealed = world.root / "sealed" / label
    sealed.mkdir(parents=True, exist_ok=True)
    document = sealed / "marshall.enc.json"
    encrypt_document(document, "overalls-marshall", values, recipients)
    descriptors = world.root / "descriptors" / label
    descriptors.mkdir(parents=True, exist_ok=True)
    desc = descriptor(
        descriptors,
        "marshall",
        str(document),
        {"environment": OutputSpec("environment", list(SECRET_NAMES))},
        host,
    )
    bundle = make_bundle(
        world.root, label, {"marshall": desc}, Path("/run/overalls-secrets/marshall/environment")
    )
    return bundle, document


def git_stack(
    world: World,
    label: str,
    values: Mapping[str, str],
    recipients: list[str],
    host: Identity,
) -> tuple[Bundle, Path]:
    sealed = world.root / "sealed" / label
    sealed.mkdir(parents=True, exist_ok=True)
    document = sealed / "git.enc.json"
    encrypt_document(document, "overalls-git", values, recipients)
    descriptors = world.root / "descriptors" / label
    descriptors.mkdir(parents=True, exist_ok=True)
    desc = descriptor(
        descriptors,
        "git",
        str(document),
        {"deploy-key": OutputSpec("raw", ["GIT_DEPLOY_KEY"])},
        host,
    )
    bundle = make_bundle(world.root, label, {"git": desc}, None)
    return bundle, document


def install_baseline(world: World, model: Model, bundle: Bundle) -> str:
    revision = world.publish(bundle)
    rc, events = tick(world, model)
    require(rc == 0, "baseline installation failed")
    require(events[-1] == {"event": "update.healthy", "revision": revision}, "baseline events")
    return revision


def advance_to_retry(world: World, model: Model) -> None:
    retry_at = int_value(model.state.get("retryAt", 0))
    if retry_at > world.clock.wall:
        world.clock.advance(retry_at - world.clock.wall)


def upstream_command_count(world: World, verb: str) -> int:
    return sum(1 for entry in world.log if entry and entry[0] == "systemctl" and entry[1] == verb)


def operator_manual_switch(
    world: World, bundle: Bundle, host: Identity, values: Mapping[str, str]
) -> None:
    """Documented runbook: stop consumers, prepare exact staged bytes, switch, start."""
    del host
    manifest = bundle.manifest
    for unit in list(world.serving):
        world.stop(unit)
        world.log.append(("OPERATOR", "stop", unit))
    world.switch(str(bundle.system), "operator")
    for name in object_map(manifest["secrets"]):
        world.log.append(("OPERATOR", "prepare", name))
        world.start("overalls-secrets-" + name + ".service", "operator")
    published = parse_environment(Path("/run/overalls-secrets/marshall/environment"))
    require(published == dict(values), "operator publication drifted from staged resolution")
    marshall_resolutions = [
        content
        for _, content in world.resolutions
        if content is not None and "environment" in content
    ]
    require(bool(marshall_resolutions), "updater staging must have resolved before refusal")
    require(
        published == parse_environment_bytes(marshall_resolutions[-1]["environment"]),
        "operator publication drifted from updater-staged bytes",
    )
    for unit in _roster_units(bundle):
        world.start(unit, "operator")
    world.log.append(("OPERATOR", "healthy-check", bundle.label))


def parse_environment_bytes(data: bytes) -> dict[str, str]:
    return parse_environment_data(data)


def _roster_units(bundle: Bundle) -> list[str]:
    return string_list(bundle.manifest["healthUnits"]) + string_list(bundle.manifest["consumers"])


def run_rotation_scenario(refusals: int, early_tick: bool, rotated: str) -> None:
    """(d) leg 1: legitimate value rotation refuses forever, operator recovers."""
    require(refusals >= 1, "need at least one refusal")
    with tempfile.TemporaryDirectory(prefix="custody-rotation-", dir=WORK) as root_str:
        root = Path(root_str)
        reset_machine_paths()
        world = World(root)
        model = Model()
        keys = root / "keys"
        keys.mkdir()
        host = make_identity(keys, "host")
        recovery = make_identity(keys, "recovery")
        values0 = marshall_values("base")
        world.secret_material += [value.encode() for value in values0.values()]
        bundle0, _ = marshall_stack(
            world, "r0", values0, [host.age_recipient, recovery.age_recipient], host
        )
        revision0 = install_baseline(world, model, bundle0)
        require(
            parse_environment(Path("/run/overalls-secrets/marshall/environment")) == values0,
            "baseline publication",
        )
        require(world.serving == {"marshall-main.service": values0}, "baseline serving")
        values1 = dict(values0)
        values1[rotated] = f"fx-rotated-{rotated.lower()}"
        world.secret_material.append(values1[rotated].encode())
        bundle1, _ = marshall_stack(
            world, "r1", values1, [host.age_recipient, recovery.age_recipient], host
        )
        revision1 = world.publish(bundle1)
        world.outcome[revision1] = "preflight/coordinated_secret_change"
        migrations_before = len(world.migrations)
        stops_before = upstream_command_count(world, "stop")
        switches_before = len(world.switches)
        resolutions_before = len(world.resolutions)
        for index in range(refusals):
            advance_to_retry(world, model)
            rc, _tick_events = tick(world, model)
            require(rc == 1, "rotation must refuse")
            require(
                parse_environment(Path("/run/overalls-secrets/marshall/environment")) == values0,
                "refused staging must never publish",
            )
            require(
                world.serving == {"marshall-main.service": values0},
                "refusal must not restart serving authority",
            )
            if index == 0 and early_tick:
                log_before = len(world.log)
                rc, events = tick(world, model)
                require(
                    rc == 0 and events == [{"event": "update.phase", "phase": "fetch"}],
                    "early backoff tick must only fetch",
                )
                require(len(world.resolutions) == resolutions_before + 1, "early resolve")
                require(
                    all(entry[0] == "git" for entry in world.log[log_before:]),
                    "early backoff tick must not build",
                )
        require(
            len(world.migrations) == migrations_before,
            "coordinated_secret_change must refuse before migration",
        )
        require(
            upstream_command_count(world, "stop") == stops_before,
            "refusal must not stop consumers",
        )
        require(len(world.switches) == switches_before, "refusal must not switch")
        require(len(world.resolutions) == resolutions_before + refusals, "stage per attempt")
        state = read_state()
        require(state["candidate"] == model.identity(revision1), "candidate pinned")
        require(state["lastHealthy"] == model.identity(revision0), "baseline")
        operator_manual_switch(world, bundle1, host, values1)
        require(world.serving == {"marshall-main.service": values1}, "operator switch serving")
        rc, events = tick(world, model)
        require(
            rc == 0 and events == [{"event": "update.phase", "phase": "fetch"}],
            "manual switch inside the backoff window must not be noticed yet",
        )
        require(str(ACTIVE.resolve()) == str(bundle1.system), "operator system")
        advance_to_retry(world, model)
        migrations_clean = len(world.migrations)
        switches_clean = len(world.switches)
        resolutions_clean = len(world.resolutions)
        stops_clean = upstream_command_count(world, "stop")
        preparations_clean = len(world.prepared)
        rc, events = tick(world, model)
        require(rc == 0, "verify-only recovery must succeed")
        require(
            events
            == [
                {"event": "update.phase", "phase": "fetch"},
                {"event": "update.phase", "phase": "build"},
                {"event": "update.phase", "phase": "stage"},
                {"event": "update.phase", "phase": "verify"},
                {"event": "update.healthy", "revision": revision1},
            ],
            "recovery must be verify-only",
        )
        require(len(world.migrations) == migrations_clean, "no migration rerun")
        require(len(world.switches) == switches_clean, "recovery must not switch")
        require(upstream_command_count(world, "stop") == stops_clean, "recovery stops no units")
        require(len(world.prepared) == preparations_clean, "recovery publishes no live bundles")
        require(not (RUNTIME / "staging").exists(), "recovery retires private staging")
        require(
            len(world.resolutions) == resolutions_clean + 1,
            "recovery must validate candidate secrets once before verifying live roles",
        )
        require(world.serving == {"marshall-main.service": values1}, "serving unchanged")
        state = read_state()
        require(state["phase"] == "healthy" and state["failures"] == 0, "converged healthy")
        require(state["failedPhase"] == "preflight", "refusal evidence retained")
        require(state["failure"] is None and state["retryAt"] == 0, "backoff cleared")
        require(state["lastHealthy"] == model.identity(revision1), "candidate now healthy")


def descriptor_id_of(path: str) -> str:
    parsed: object = json.loads(Path(path).read_bytes())
    require(isinstance(parsed, dict), "descriptor must be an object")
    return hashlib.sha256(
        json.dumps(parsed, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def run_rekey_scenario(extra_recipient: str, stale_handoff: bool, second_bundle: bool) -> None:
    """(d) leg 2: recipient-only rekey stages and hands off byte-exactly."""
    with tempfile.TemporaryDirectory(prefix="custody-rekey-", dir=WORK) as root_str:
        root = Path(root_str)
        reset_machine_paths()
        world = World(root)
        model = Model()
        keys = root / "keys"
        keys.mkdir()
        host = make_identity(keys, "host")
        recovery = make_identity(keys, "recovery")
        third = make_identity(keys, "second")
        values0 = marshall_values("rekey")
        world.secret_material += [value.encode() for value in values0.values()]
        bundle0, _ = marshall_stack(
            world, "r0", values0, [host.age_recipient, recovery.age_recipient], host
        )
        git_values = {"GIT_DEPLOY_KEY": "fx-git-deploy-rekey"}
        git_recipients = [host.age_recipient, recovery.age_recipient]
        git_bundle0, _git_doc0 = git_stack(world, "g0", git_values, git_recipients, host)
        if second_bundle:
            secrets_map0 = object_str_map(bundle0.manifest["secrets"])
            secrets_map0.update(object_str_map(git_bundle0.manifest["secrets"]))
            bundle0 = make_bundle(
                world.root,
                "r0t",
                secrets_map0,
                Path("/run/overalls-secrets/marshall/environment"),
            )
        revision0 = install_baseline(world, model, bundle0)
        require(
            parse_environment(Path("/run/overalls-secrets/marshall/environment")) == values0,
            "baseline publication",
        )
        if second_bundle:
            require(
                Path("/run/overalls-secrets/git/deploy-key").read_bytes()
                == git_values["GIT_DEPLOY_KEY"].encode(),
                "baseline git publication",
            )
        if stale_handoff:
            # A leaked descriptor from an abandoned earlier attempt must be retired.
            (RUNTIME / "handoff.json").write_bytes(b'{"deadbeefdeadbeef": "/nonexistent"}')
            (RUNTIME / "handoff.json").chmod(0o600)
            junk = RUNTIME / "staging" / "junk" / "files"
            junk.mkdir(parents=True)
            (junk / "environment").write_bytes(b"junk")
        recipients1 = sorted(
            [host.age_recipient, recovery.age_recipient, third.age_recipient],
            reverse=extra_recipient == "first-position",
        )
        bundle1, document1 = marshall_stack(world, "r1", values0, recipients1, host)
        secrets_map1 = object_str_map(bundle1.manifest["secrets"])
        if second_bundle:
            _gb1, _git_doc1 = git_stack(world, "g1", git_values, recipients1, host)
            secrets_map1.update(object_str_map(_gb1.manifest["secrets"]))
        bundle1 = make_bundle(
            world.root,
            "r1t",
            secrets_map1,
            Path("/run/overalls-secrets/marshall/environment"),
        )
        # Concurrent delivery race: the repository document flips while the
        # updater sits between activation and secret preparation. The published
        # bundle MUST come from the staged handoff, never from re-resolution.
        mutation_values = dict(values0)
        mutation_values["TOKEN_SIGNING_SECRET"] = "fx-token-concurrent"
        world.secret_material.append(mutation_values["TOKEN_SIGNING_SECRET"].encode())
        world.pending_mutations.append(
            Mutation(
                str(bundle1.system),
                str(document1),
                "overalls-marshall",
                recipients1,
                mutation_values,
            )
        )
        revision1 = world.publish(bundle1)
        migrations_before = len(world.migrations)
        resolutions_before = len(world.resolutions)
        rc, events = tick(world, model)
        require(rc == 0, "recipient-only rekey must be admitted")
        require(
            events
            == [
                {"event": "update.phase", "phase": "fetch"},
                {"event": "update.phase", "phase": "build"},
                {"event": "update.phase", "phase": "stage"},
                {"event": "update.phase", "phase": "preflight"},
                {"event": "update.phase", "phase": "migrate"},
                {"event": "update.phase", "phase": "activate"},
                {"event": "update.units_retained", "count": 0},
                {"event": "update.phase", "phase": "verify"},
                {"event": "update.healthy", "revision": revision1},
            ],
            "rekey must run the full pipeline",
        )
        require(
            len(world.migrations) == migrations_before + 1,
            "descriptor change runs the candidate migrator exactly once",
        )
        descriptor_count = 2 if second_bundle else 1
        require(
            len(world.resolutions) == resolutions_before + descriptor_count,
            "stage resolves each candidate descriptor exactly once",
        )
        published = parse_environment(Path("/run/overalls-secrets/marshall/environment"))
        require(published == values0, "publication must equal staged handoff bytes")
        require(
            published.get("TOKEN_SIGNING_SECRET") != "fx-token-concurrent",
            "activation must not re-resolve the concurrently delivered document",
        )
        oracle_values = oracle_plaintext(document1, host)
        if oracle_values is None:
            raise HarnessError("post-mutation document still decrypts")
        require(
            oracle_production(oracle_values)["TOKEN_SIGNING_SECRET"] == "fx-token-concurrent",
            "mutation oracle",
        )
        require(world.serving == {"marshall-main.service": values0}, "serving staged values")
        require(
            set(world.handoff_at_switch)
            == {descriptor_id_of(str(p)) for p in object_map(bundle1.manifest["secrets"]).values()},
            "handoff bound to exact candidate descriptors",
        )
        bound_outputs: set[str] = set()
        for key, path in object_str_map(bundle1.manifest["secrets"]).items():
            snapshot = world.staged_snapshot[descriptor_id_of(path)]
            parsed = object_map(json.loads(Path(path).read_bytes()))
            expect_names = set(object_map(parsed["outputs"]))
            require(set(snapshot) == expect_names, f"staged outputs for {key}")
            bound_outputs |= expect_names
            snapshot_source = str(RUNTIME / "staging" / key / "encrypted")
            recorded = [
                content
                for source, content in world.resolutions
                if source.startswith(snapshot_source + ".") and content is not None
            ]
            require(bool(recorded), "staged resolution recorded for " + key)
            for filename, staged_bytes in recorded[-1].items():
                require(
                    snapshot[filename] == staged_bytes,
                    f"staged bytes bound for {key}/{filename}",
                )
                require(
                    set(snapshot) == set(recorded[-1]),
                    f"staged file set bound for {key}",
                )
        require(state_phase_healthy(revision0, revision1, model), "final state")
        if stale_handoff:
            require("deadbeefdeadbeef" not in world.handoff_at_switch, "stale handoff retired")
            require(not any("junk" in key for key in world.handoff_at_switch), "junk retired")
        if second_bundle:
            require(
                Path("/run/overalls-secrets/git/deploy-key").read_bytes()
                == git_values["GIT_DEPLOY_KEY"].encode(),
                "second bundle publication",
            )


def oracle_production(oracle_values: dict[str, object]) -> dict[str, str]:
    production = object_map(object_map(oracle_values.get("overalls-marshall")).get("production"))
    return {str(key): str(value) for key, value in production.items()}


def state_phase_healthy(revision0: str, revision1: str, model: Model) -> bool:
    state = read_state()
    return bool(
        state.get("phase") == "healthy"
        and state.get("failures") == 0
        and state.get("failure") is None
        and state.get("candidate") == model.identity(revision1)
        and state.get("activatedCandidate") == model.identity(revision1)
        and state.get("lastHealthy") == model.identity(revision1)
        and state.get("lastHealthy") != model.identity(revision0)
    )


def run_wedge_scenario(wedge_ticks: int, fix: str) -> None:
    """(d) leg 3: host removed from a document its config still selects wedges stage."""
    with tempfile.TemporaryDirectory(prefix="custody-wedge-", dir=WORK) as root_str:
        root = Path(root_str)
        reset_machine_paths()
        world = World(root)
        model = Model()
        keys = root / "keys"
        keys.mkdir()
        host = make_identity(keys, "host")
        recovery = make_identity(keys, "recovery")
        values0 = {"GIT_DEPLOY_KEY": "fx-git-deploy-0"}
        world.secret_material.append(values0["GIT_DEPLOY_KEY"].encode())
        bundle0, _ = git_stack(
            world, "r0", values0, [host.age_recipient, recovery.age_recipient], host
        )
        revision0 = install_baseline(world, model, bundle0)
        require(
            Path("/run/overalls-secrets/git/deploy-key").read_bytes()
            == values0["GIT_DEPLOY_KEY"].encode(),
            "baseline raw publication is exact",
        )
        baseline_active = str(ACTIVE.resolve())
        # Custody change alone: rekey the document without the host recipient.
        sealed1 = root / "sealed" / "w1"
        sealed1.mkdir(parents=True)
        document1 = sealed1 / "git.enc.json"
        encrypt_document(document1, "overalls-git", values0, [recovery.age_recipient])
        require(oracle_plaintext(document1, host) is None, "host must lose decryption")
        require(oracle_plaintext(document1, recovery) is not None, "recovery decrypts")
        descriptors1 = root / "descriptors" / "w1"
        descriptors1.mkdir(parents=True)
        desc1 = descriptor(
            descriptors1,
            "git",
            str(document1),
            {"deploy-key": OutputSpec("raw", ["GIT_DEPLOY_KEY"])},
            host,
        )
        bundle1 = make_bundle(world.root, "w1", {"git": desc1}, None)
        revision1 = world.publish(bundle1)
        world.outcome[revision1] = "stage/operation_failed"
        stops_before = upstream_command_count(world, "stop")
        migrations_before = len(world.migrations)
        switches_before = len(world.switches)
        resolutions_before = len(world.resolutions)
        delays: list[int] = []
        for _ in range(wedge_ticks):
            advance_to_retry(world, model)
            before = int(world.clock.wall)
            rc, events = tick(world, model)
            require(rc == 1, "custody wedge must fail")
            require(
                events[-1]
                == {"event": "update.failed", "phase": "stage", "reason": "operation_failed"},
                "exact wedge refusal",
            )
            delays.append(int_value(read_state()["retryAt"]) - before)
            require(
                Path("/run/overalls-secrets/git/deploy-key").read_bytes()
                == values0["GIT_DEPLOY_KEY"].encode(),
                "wedged staging must never publish",
            )
            require(str(ACTIVE.resolve()) == baseline_active, "wedge must not switch")
        require(
            delays == [min(900, 30 * 2 ** min(i, 15)) for i in range(wedge_ticks)],
            "deterministic backoff sequence min(900, 30*2**(f-1))",
        )
        state = read_state()
        require(state["failures"] == min(wedge_ticks, 16), "failure cap sixteen")
        require(len(world.resolutions) == resolutions_before + wedge_ticks, "attempted stage")
        require(
            all(content is None for _, content in world.resolutions[resolutions_before:]),
            "every wedged resolution fails closed",
        )
        require(upstream_command_count(world, "stop") == stops_before, "wedge stops nothing")
        require(len(world.migrations) == migrations_before, "wedge never migrates")
        require(len(world.switches) == switches_before, "wedge never switches")
        if fix == "config-removal":
            bundle2 = make_bundle(world.root, "w2", {}, None)
        else:
            descriptors2 = root / "descriptors" / "w2"
            descriptors2.mkdir()
            sealed2 = root / "sealed" / "w2"
            sealed2.mkdir()
            document2 = sealed2 / "git.enc.json"
            encrypt_document(
                document2, "overalls-git", values0, [host.age_recipient, recovery.age_recipient]
            )
            desc2 = descriptor(
                descriptors2,
                "git",
                str(document2),
                {"deploy-key": OutputSpec("raw", ["GIT_DEPLOY_KEY"])},
                host,
            )
            bundle2 = make_bundle(world.root, "w2", {"git": desc2}, None)
        revision2 = world.publish(bundle2)
        rc, events = tick(world, model)
        require(rc == 0, "post-fix recovery must succeed")
        require(events[-1] == {"event": "update.healthy", "revision": revision2}, "recovery")
        state = read_state()
        require(state["phase"] == "healthy" and state["failures"] == 0, "converged")
        require(state["failure"] is None and state["retryAt"] == 0, "backoff cleared")
        require(state["failedPhase"] == "stage", "wedge evidence retained")
        require(state["lastHealthy"] == model.identity(revision2), "fixed revision healthy")
        require(str(ACTIVE.resolve()) == str(bundle2.system), "fixed candidate active")
        if fix == "custody-restored":
            require(
                Path("/run/overalls-secrets/git/deploy-key").read_bytes()
                == values0["GIT_DEPLOY_KEY"].encode(),
                "restored custody republishes staged values",
            )
        else:
            require(
                Path("/run/overalls-secrets/git/deploy-key").read_bytes()
                == values0["GIT_DEPLOY_KEY"].encode(),
                "config removal keeps the last published bundle untouched",
            )
        require(state["lastHealthy"] != model.identity(revision0), "advanced")


class RotationRecoveryHistories(unittest.TestCase):
    """Coordinated value rotation: refuse forever, recover via verify-only path."""

    @settings(max_examples=6, deadline=None, derandomize=True, database=None)
    @example(16, False, "SECRET_KEY_BASE")
    @example(17, True, "TOKEN_SIGNING_SECRET")
    @example(1, True, "DATABASE_URL")
    @given(
        refusals=st.integers(1, 22),
        early_tick=st.booleans(),
        rotated=st.sampled_from(["SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET", "DATABASE_URL"]),
    )
    def test_refusal_backoff_then_manual_verify_only_recovery(
        self, refusals: int, early_tick: bool, rotated: str
    ) -> None:
        run_rotation_scenario(refusals, early_tick, rotated)


class RecipientRekeyHistories(unittest.TestCase):
    """Recipient-only rekeys resolve and hand off staged bytes end-to-end."""

    @settings(max_examples=6, deadline=None, derandomize=True, database=None)
    @example("first-position", True, True)
    @example("sorted", False, False)
    @given(
        extra_recipient=st.sampled_from(["first-position", "sorted"]),
        stale_handoff=st.booleans(),
        second_bundle=st.booleans(),
    )
    def test_recipient_only_rekey_descriptor_handoff(
        self, extra_recipient: str, stale_handoff: bool, second_bundle: bool
    ) -> None:
        run_rekey_scenario(extra_recipient, stale_handoff, second_bundle)


class CustodyWedgeHistories(unittest.TestCase):
    """Host removed from a still-selected document wedges stage until the fix."""

    @settings(max_examples=6, deadline=None, derandomize=True, database=None)
    @example(1, "config-removal")
    @example(16, "custody-restored")
    @example(17, "custody-restored")
    @given(
        wedge_ticks=st.integers(1, 20),
        fix=st.sampled_from(["config-removal", "custody-restored"]),
    )
    def test_custody_wedge_label_backoff_and_recovery(self, wedge_ticks: int, fix: str) -> None:
        run_wedge_scenario(wedge_ticks, fix)


class FixedCustodyBoundaries(unittest.TestCase):
    def test_failed_unit_query_preserves_failure_and_refuses_unknown_flags(self) -> None:
        world = World(root=WORK)
        world.units = {
            "healthy.service": UnitEntry(active=True),
            "stopped.service": UnitEntry(),
            "broken.service": UnitEntry(failed=True),
        }
        arguments = ["systemctl", "list-units", "--failed", "--plain", "--no-legend"]
        self.assertEqual(
            world.systemctl(arguments, True),
            "broken.service loaded failed failed synthetic\n",
        )
        with self.assertRaises(HarnessError):
            world.systemctl([*arguments, "--unsupported"], True)
        world.stop("broken.service")
        self.assertEqual(world.systemctl(arguments, True), "")

    def test_refusal_backoff_caps_at_sixteen_failures(self) -> None:
        run_rotation_scenario(18, False, "SECRET_KEY_BASE")
        state = read_state()
        require(state["phase"] == "healthy", "capped refusal history converges")

    def test_cli_refuses_hostless_document_without_recovery_only(self) -> None:
        require(CLI_PATH is not None, "secrets CLI fixture path required")
        with tempfile.TemporaryDirectory(prefix="custody-cli-", dir=WORK) as root_str:
            root = Path(root_str)
            reset_machine_paths()
            keys = root / "keys"
            keys.mkdir()
            make_identity(keys, "op")
            make_identity(keys, "host-a")
            op_pub = (keys / "op.ssh.pub").read_text().strip()
            host_pub = (keys / "host-a.ssh.pub").read_text().strip()
            repositories = root / "repository"
            repositories.mkdir()

            def invoke(documents: Mapping[str, object], command: str) -> tuple[int, str]:
                manifest = root / "manifest.json"
                manifest.write_text(
                    json.dumps(
                        {
                            "users": {"op": {"sshKeys": [op_pub], "secretRecovery": True}},
                            "inventory": {
                                "hosts": {"host-a": {"sshKeys": [host_pub]}},
                                "documents": documents,
                            },
                        },
                        sort_keys=True,
                    )
                )
                arguments = [sys.executable, str(CLI_PATH), "--manifest", str(manifest)]
                if command == "check":
                    arguments += ["check", "--root", str(repositories)]
                else:
                    output = root / (
                        "export-" + hashlib.sha256(str(documents).encode()).hexdigest()[:8]
                    )
                    arguments += ["export", "--output", str(output)]
                result = subprocess.run(arguments, capture_output=True, timeout=60)
                return result.returncode, result.stderr.decode().strip()

            refusal = "Invalid document inventory; require unique paths, recovery users and either hosts or explicit recovery-only custody."
            base = {"path": "secrets/doc-a.enc.json"}
            rc, message = invoke({"doc-a": dict(base, hosts=[])}, "check")
            require(rc == 1 and message == refusal, "empty hosts must refuse")
            rc, message = invoke(
                {"doc-a": dict(base, hosts=["host-a"], recoveryOnly=True)}, "check"
            )
            require(rc == 1 and message == refusal, "hosted recovery-only must refuse")
            rc, _ = invoke(
                {
                    "doc-a": dict(base, hosts=[], recoveryOnly=True),
                    "doc-b": dict(base, path="secrets/doc-b.enc.json", hosts=["host-a"]),
                },
                "export",
            )
            require(rc == 0, "recovery-only and hosted custody export")


if __name__ == "__main__":
    unittest.main()
