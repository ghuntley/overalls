"""Host-local candidate deployment. Root-owned configuration is the trust boundary."""

import base64
import fcntl
import importlib.util
import json
import os
import pwd
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from contextlib import suppress
from pathlib import Path
from typing import Protocol, TypedDict, cast

STATE = Path("/var/lib/overalls-auto-update")
RUNTIME = Path("/run/overalls-auto-update")
ACTIVE = Path("/run/current-system")
# One fixed checkout and Buck2 isolation directory, so buck-out and the cells
# stay warm across revisions (ADR-0271). HOME keeps buckd state private.
CHECKOUT = STATE / "checkout"
BUCK2_HOME = STATE / "buck2-home"
# Buck2 Nix rules root their outputs here, in the root-owned state directory,
# rather than in the checkout or the invoking user's home.
BUCK2_GCROOTS = STATE / "gcroots"
BUCK2_ISOLATION = "overalls-update"
BUCK2_PRESERVED = ["/buck-out", "/.buck-cells", "/.buck-cells.key", "/.buck-cells.gcroot"]
BUCK2_LOCAL_CONFIG = (
    "# Written by overalls-auto-update.\n[buck2]\n  file_watcher = fs_hash_crawler\n"
)
DEPLOYMENT_PATH = re.compile(r"/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]{1,180}")


def unit_identity(system: Path, unit: str) -> tuple[str | None, tuple[tuple[str, str], ...]]:
    """The store identity of a unit in a system closure: its file and drop-ins by real path."""
    base = system / "etc/systemd/system"
    path = base / unit
    unit_file = str(path.resolve()) if path.exists() else None
    directory = base / (unit + ".d")
    drop_ins: tuple[tuple[str, str], ...] = ()
    if directory.is_dir():
        drop_ins = tuple(
            sorted((entry.name, str(entry.resolve())) for entry in directory.iterdir())
        )
    return unit_file, drop_ins


KEYS = ["DATABASE_URL", "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET", "MARSHALL_CLOAK_KEYS"]


class Configuration(TypedDict):
    repository: str
    branch: str
    flakeAttr: str
    healthTimeout: int
    buildTimeout: int
    verbose: bool
    secretUnits: list[str]
    secretHelper: str
    resourcePolicyHelper: str


class SecretsHelper(Protocol):
    MAX_RESOLUTION_BYTES: int

    def capture(
        self, arguments: list[str], environment: dict[str, str], timeout: float = 60
    ) -> bytes: ...

    def safe_directory(self, path: Path) -> None: ...

    def private_file(self, path: Path) -> None: ...

    def resolve(self, configuration: dict[str, object]) -> dict[str, bytes]: ...

    def publish(
        self,
        destination: Path,
        contents: dict[str, bytes],
        group: str,
        *,
        durable: bool = False,
    ) -> None: ...

    def descriptor_id(self, configuration: dict[str, object]) -> str: ...


def lilly_owner_file(path: Path) -> None:
    """@cc [owner:ghuntley,label:security] lilly-owner-binding-custody
    Lilly's owner binding MUST be a private (0600), singly linked, bounded
    regular file in a 0700 directory, each owned by root or the `lilly`
    service user (ADR-0182), beneath root-owned parents that no one else can
    write; anything else (a symbolic link, another owner, a group- or
    world-accessible mode) MUST raise ValueError.
    """
    try:
        service = {0, pwd.getpwnam("lilly").pw_uid}
    except KeyError:
        service = {0}
    directory = path.parent.lstat()
    info = path.lstat()
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid not in service
        or stat.S_IMODE(directory.st_mode) & 0o077
        or not stat.S_ISREG(info.st_mode)
        or info.st_uid not in service
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
        or not 0 < info.st_size <= 65536
    ):
        raise ValueError("invalid lilly owner binding")
    for parent in path.parent.parents:
        state = parent.lstat()
        if (
            not stat.S_ISDIR(state.st_mode)
            or state.st_uid != 0
            or (state.st_mode & 0o022 and not state.st_mode & stat.S_ISVTX)
        ):
            raise ValueError("untrusted directory")


class ResourceTransition(Protocol):
    def prepare(self) -> None: ...

    def apply(self) -> None: ...


class ResourceModule(Protocol):
    def compatible(
        self, previous: Mapping[str, object], candidate: Mapping[str, object]
    ) -> bool: ...

    Transition: Callable[..., ResourceTransition]

    def failure_reason(self, error: Exception) -> str: ...


class UpdateError(Exception):
    """Only fixed, nonsecret reason codes may cross this boundary."""


def string_value(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def integer_value(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def list_value(value: object) -> list[object]:
    if not isinstance(value, list):
        raise ValueError("expected array")
    return value


OCTET = r"(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
RUNTIME_ADDRESS = re.compile(OCTET + r"(\." + OCTET + r"){3}")


def runtime_protected_network(path: Path) -> str | None:
    """Return the /32 network held in a runtime protected-address file."""
    try:
        text = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError):
        return None
    first = text.split(".", 1)[0]
    if (
        RUNTIME_ADDRESS.fullmatch(text) is None
        or text in ("0.0.0.0", "255.255.255.255")
        or first == "127"
        or int(first) >= 224
    ):
        return None
    return text + "/32"


def effective_lilly_binding(
    binding: Mapping[str, object],
    read: Callable[[Path], str | None] = runtime_protected_network,
) -> dict[str, object]:
    """@cc [owner:ghuntley,label:recovery;security] lilly-protected-binding-effective
    Lilly bindings MUST compare protected networks by the effective set Lilly
    claims: the evaluated CIDRs plus each readable runtime address as a /32.
    Moving a literal into a runtime file with an equal value MUST NOT be a
    binding change. An unreadable or malformed runtime file MUST leave the
    binding raw, so only an identical binding compares equal.
    """
    result = dict(binding)
    cidrs = result.pop("protectedCidrs", [])
    files = result.pop("protectedAddressFiles", [])
    if not isinstance(cidrs, list) or not isinstance(files, list):
        return dict(binding)
    effective: set[str] = set()
    for item in cidrs:
        if not isinstance(item, str):
            return dict(binding)
        effective.add(item)
    for item in files:
        network = read(Path(item)) if isinstance(item, str) else None
        if network is None:
            return dict(binding)
        effective.add(network)
    result["protectedEffective"] = sorted(effective)
    return result


def lilly_bindings_equivalent(old: object, new: object) -> bool:
    if old == new:
        return True
    if not isinstance(old, dict) or not isinstance(new, dict):
        return False
    return effective_lilly_binding(old) == effective_lilly_binding(new)


def with_effective_lilly_binding(value: Mapping[str, object]) -> dict[str, object]:
    """A copy whose Lilly binding is normalised for resource comparisons."""
    result = dict(value)
    lilly = result.get("lilly")
    if isinstance(lilly, dict) and isinstance(lilly.get("binding"), dict):
        result["lilly"] = {**lilly, "binding": effective_lilly_binding(lilly["binding"])}
    return result


def configuration_value(raw: object) -> Configuration:
    row = object_value(raw)
    return Configuration(
        repository=string_value(row["repository"]),
        branch=string_value(row["branch"]),
        flakeAttr=string_value(row["flakeAttr"]),
        healthTimeout=integer_value(row["healthTimeout"]),
        buildTimeout=integer_value(row.get("buildTimeout", 7200)),
        verbose=bool(row["verbose"]),
        secretUnits=[string_value(item) for item in list_value(row["secretUnits"])],
        secretHelper=string_value(row["secretHelper"]),
        resourcePolicyHelper=string_value(row["resourcePolicyHelper"]),
    )


def atomic_json(path: Path, value: Mapping[str, object]) -> None:
    temporary = path.with_name(path.name + ".new")
    with temporary.open("w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_bytes())


def shared_memory_ready() -> bool:
    """Require the normal writable tmpfs before a switch stops consumers."""
    try:
        if stat.S_IMODE(Path("/dev/shm").stat().st_mode) != 0o1777:
            return False
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            before, separator, after = line.partition(" - ")
            mount = before.split()
            filesystem = after.split()
            if (
                separator
                and mount[4] == "/dev/shm"
                and "rw" in mount[5].split(",")
                and filesystem[0] == "tmpfs"
                and "rw" in filesystem[2].split(",")
            ):
                return True
    except (OSError, IndexError):
        return False
    return False


def load_secrets[T](path: str) -> T:
    spec = importlib.util.spec_from_file_location("overalls_secrets", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # importlib boundary: root-owned store helpers are consumed via protocol.
    return cast(T, module)


def compatible(old: Mapping[str, str], new: Mapping[str, str]) -> bool:
    """Compare privately; key removal/promotion and shared authority changes need maintenance."""
    if any(not old.get(key) or old[key] != new.get(key) for key in KEYS[:3]):
        return False
    try:
        previous = json.loads(old["MARSHALL_CLOAK_KEYS"])
        candidate = json.loads(new["MARSHALL_CLOAK_KEYS"])
        return (
            isinstance(previous, list)
            and isinstance(candidate, list)
            and bool(previous)
            and 1 <= len(candidate) <= 16
            and previous[0] == candidate[0]
            and all(key in candidate for key in previous)
            and all(
                isinstance(key, dict)
                and set(key) == {"id", "key"}
                and isinstance(key["id"], str)
                and re.fullmatch(r"[a-zA-Z0-9_-]{1,32}", key["id"])
                and isinstance(key["key"], str)
                and len(base64.b64decode(key["key"], validate=True)) == 32
                for key in candidate
            )
            and len({key["id"] for key in candidate}) == len(candidate)
        )
    except (ValueError, KeyError, TypeError, IndexError):
        return False


class Deployment:
    def __init__(self, configuration: Configuration) -> None:
        self.config = configuration
        self.secrets: SecretsHelper = load_secrets(configuration["secretHelper"])
        self.state: dict[str, object] = (
            read_json(STATE / "status.json") if (STATE / "status.json").exists() else {}
        )
        self.phase = "fetch"
        self.candidate: dict[str, object] | None = None
        self.staged: dict[str, str] = {}
        self.handoff: dict[str, str] = {}
        self.previous_consumers: list[str] = []
        self.resources: ResourceTransition | None = None

    def save(self, **values: object) -> None:
        self.state.update(values)
        atomic_json(STATE / "status.json", self.state)

    def step(self, phase: str) -> None:
        self.phase = phase
        self.save(phase=phase, updatedAt=int(time.time()))
        print(json.dumps({"event": "update.phase", "phase": phase}), flush=True)

    # @cc [owner:ghuntley,label:recovery] updater-timeout-group-cleanup
    # A command timeout MUST signal the child's whole process group, including
    # detached build helpers and SSH sessions, so no orphan survives holding
    # store locks or builder connections after command() raises TimeoutExpired.
    def command(self, arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
        with (STATE / "attempt.log").open("ab") as log:
            os.fchmod(log.fileno(), 0o600)
            # A new session makes the child its group leader, so a timeout can
            # reach detached build helpers and SSH sessions, not only the
            # direct child that subprocess.run would kill.
            process = subprocess.Popen(
                arguments,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if capture else log,
                stderr=log,
                env=dict(os.environ, GIT_TERMINAL_PROMPT="0"),
                start_new_session=True,
            )
            try:
                stdout, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.signal_group(process, signal.SIGTERM)
                try:
                    stdout, _ = process.communicate(timeout=15)
                except subprocess.TimeoutExpired:
                    self.signal_group(process, signal.SIGKILL)
                    stdout, _ = process.communicate()
        if process.returncode:
            raise UpdateError(self.phase + "_failed")
        return stdout.decode().strip() if capture else ""

    def signal_group(self, process: subprocess.Popen[bytes], number: signal.Signals) -> None:
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            return

    def environment(self, path: str) -> dict[str, str]:
        # Let systemd parse its own EnvironmentFile grammar, including literal
        # newlines and quoting. The captured output never enters a journal.
        command = [
            "systemd-run",
            "--quiet",
            "--wait",
            "--pipe",
            "--collect",
            "--unit=overalls-env-" + uuid.uuid4().hex,
            "--property=DynamicUser=yes",
            "--property=RuntimeMaxSec=30",
            "--property=NoNewPrivileges=yes",
            "--property=PrivateNetwork=yes",
            "--property=EnvironmentFile=" + path,
            sys.executable,
            "-c",
            "import json,os; print(json.dumps({k:os.environ.get(k) for k in " + repr(KEYS) + "}))",
        ]
        environment: dict[str, str] = json.loads(
            self.secrets.capture(command, dict(os.environ), timeout=40)
        )
        return environment

    def fetch(self) -> str:
        repository = STATE / "repository.git"
        if not repository.exists():
            self.command(["git", "init", "--bare", str(repository)])
        self.command(["git", "check-ref-format", "refs/heads/" + self.config["branch"]])
        self.command(
            [
                "git",
                "--git-dir=" + str(repository),
                "fetch",
                "--no-tags",
                self.config["repository"],
                "+refs/heads/" + self.config["branch"] + ":refs/overalls/candidate",
            ],
            timeout=120,
        )
        return self.command(
            [
                "git",
                "--git-dir=" + str(repository),
                "rev-parse",
                "refs/overalls/candidate^{commit}",
            ],
            capture=True,
        )

    # @cc [owner:ghuntley,label:deployment;recovery] updater-buck2-deployment-build
    # The candidate MUST be built only by the candidate checkout's own
    # tools/buck2 from the fixed checkout path and isolation directory, as
    # //fleet/hosts/<host>:deployment with the fetched revision, and the
    # activated bundle MUST be exactly the store path that target reports.
    # A missing or unstartable build tool, an unexpected report or a failed
    # build fails closed in the build phase; there is no fallback build path.
    def build(self, revision: str) -> Path:
        repository = STATE / "repository.git"
        if not (CHECKOUT / ".git").exists():
            # --force reclaims a registration whose directory has gone.
            self.command(
                [
                    "git",
                    "--git-dir=" + str(repository),
                    "worktree",
                    "add",
                    "--force",
                    "--detach",
                    str(CHECKOUT),
                    revision,
                ]
            )
        else:
            self.command(
                ["git", "-C", str(CHECKOUT), "checkout", "--quiet", "--force", "--detach", revision]
            )
            # Drop every untracked file except Buck2's output and cells links,
            # so only committed sources reach the build.
            self.command(
                ["git", "-C", str(CHECKOUT), "clean", "-ffdxq"]
                + ["--exclude=" + path for path in BUCK2_PRESERVED]
            )
        if (
            self.command(["git", "-C", str(CHECKOUT), "rev-parse", "HEAD"], capture=True)
            != revision
        ):
            raise UpdateError("checkout_mismatch")
        # One build per daemon needs no inotify watcher, and notify would follow
        # buck-out's Nix result links through the whole system closure.
        local = CHECKOUT / ".buckconfig.local"
        local.write_text(BUCK2_LOCAL_CONFIG)
        local.chmod(0o600)
        wrapper = CHECKOUT / "tools" / "buck2"
        if not wrapper.is_file() or not os.access(wrapper, os.X_OK):
            raise UpdateError("build_tool_unavailable")
        BUCK2_HOME.mkdir(mode=0o700, exist_ok=True)
        BUCK2_GCROOTS.mkdir(mode=0o700, exist_ok=True)
        buck2 = buck2_command(wrapper)
        target = "//fleet/hosts/" + self.config["flakeAttr"] + ":deployment"
        timeout = self.config["buildTimeout"]
        # A daemon started by anyone else could carry another environment.
        self.stop_buck2()
        try:
            try:
                # Realises the candidate's pinned cells and starts nothing.
                self.command([*buck2, "--version"], timeout=timeout)
            except UpdateError as error:
                raise UpdateError("build_tool_unavailable") from error
            command = [
                *buck2,
                "build",
                "--console=simple",
                "-c",
                "overalls.revision=" + revision,
                target,
                "--show-full-output",
            ]
            if self.config["verbose"]:
                command += ["-v", "4"]
            output = self.command(command, timeout=timeout, capture=True)
        finally:
            self.stop_buck2()
        reported = [
            line.split(" ", 1)[1]
            for line in output.splitlines()
            if line.split(" ", 1)[0] in {target, "root" + target} and " " in line
        ]
        if len(reported) != 1:
            raise UpdateError("build_output_invalid")
        report = Path(reported[0])
        if not report.is_relative_to(CHECKOUT / "buck-out") or not report.is_file():
            raise UpdateError("build_output_invalid")
        bundle = report.read_text().strip()
        if not DEPLOYMENT_PATH.fullmatch(bundle):
            raise UpdateError("build_output_invalid")
        self.command(["nix-store", "--add-root", str(STATE / "candidate"), "--realise", bundle])
        if str((STATE / "candidate").resolve(strict=True)) != bundle:
            raise UpdateError("build_output_invalid")
        self.save(builder="buck2")
        return Path(bundle)

    # @cc [owner:ghuntley,label:recovery] updater-buck2-daemon-stopped
    # buckd leaves the command's process group, so timeout group cleanup
    # cannot reach it. The updater MUST stop the isolated daemon before and
    # after every build, including after a timeout or failure, and in the
    # post-stop cleanup, so no daemon outlives an update attempt.
    def stop_buck2(self) -> None:
        binary = CHECKOUT / ".buck-cells" / "bin" / "buck2"
        if not binary.exists():
            return
        with suppress(UpdateError):
            self.command(buck2_kill_command(binary), timeout=60)

    def stage(self) -> None:
        # Retire a previous attempt's handoff before reusing its private staging
        # namespace. A preflight failure must never expose the next attempt via
        # a stale handoff descriptor.
        RUNTIME.joinpath("handoff.json").unlink(missing_ok=True)
        stage = RUNTIME / "staging"
        if stage.exists():
            self.secrets.safe_directory(stage)
            shutil.rmtree(stage)
        stage.mkdir(mode=0o700)
        assert self.candidate is not None
        for name, descriptor in object_value(self.candidate["secrets"]).items():
            original = read_json(Path(string_value(descriptor)))
            directory = stage / name
            directory.mkdir(mode=0o700)
            runtime = directory / "runtime"
            runtime.mkdir(mode=0o700)
            source = Path(string_value(original["encryptedFile"]))
            self.secrets.safe_directory(source.parent)
            # SOPS selects JSON/YAML decoding from the filename. Preserve the
            # source suffix while isolating its bytes from concurrent delivery.
            snapshot = directory / ("encrypted" + source.suffix)
            # Copy through the resolver's validated source check; symlinked
            # encrypted store paths are allowed, plaintext identities are not.
            info = source.stat()
            if (
                not source.is_file()
                or info.st_uid != 0
                or info.st_mode & 0o022
                or info.st_size > 16 * 1024 * 1024
            ):
                raise UpdateError("invalid_encrypted_source")
            snapshot.write_bytes(source.read_bytes())
            snapshot.chmod(0o600)
            destination = directory / "files"
            configuration = dict(
                original,
                runtime=str(runtime),
                encryptedFile=str(snapshot),
                destination=str(destination),
            )
            contents = self.secrets.resolve(configuration)
            self.secrets.publish(destination, contents, "root")
            self.handoff[self.secrets.descriptor_id(original)] = str(destination)
            for filename in contents:
                self.staged[str(Path(string_value(original["destination"])) / filename)] = str(
                    destination / filename
                )

    def staged_matches_live(self) -> bool:
        """Whether every staged candidate bundle equals its live bundle, file for file."""
        assert self.candidate is not None
        return all(
            self.bundle_matches_live(name) for name in object_value(self.candidate["secrets"])
        )

    def bundle_matches_live(self, name: str) -> bool:
        """Whether one staged candidate bundle equals its live bundle, file for file."""
        assert self.candidate is not None
        descriptor = object_value(self.candidate["secrets"])[name]
        original = read_json(Path(string_value(descriptor)))
        live = Path(string_value(original["destination"]))
        staged = RUNTIME / "staging" / name / "files"
        if not live.is_dir() or not staged.is_dir():
            return False
        names = sorted(path.name for path in staged.iterdir())
        if names != sorted(path.name for path in live.iterdir()):
            return False
        return all((staged / file).read_bytes() == (live / file).read_bytes() for file in names)

    # @cc [owner:ghuntley,label:recovery;capacity] updater-restarts-only-changed-units
    # Activation MUST stop and restart only the units whose definition changes
    # between the active system and the candidate (the unit file or any of its
    # drop-ins resolves to a different store path, or the unit exists on one
    # side only), the consumers of a secret bundle whose staged contents differ
    # from the live bundle, consumers the candidate no longer lists, and the
    # consumers that require, bind to or are part of any of those (the
    # manifest's consumerDependents, to a fixed point), because a retained
    # socket-activated or restarting dependent would pull a stopped unit back
    # up through Requires= during the stop phase. Every other running consumer, its
    # sockets and its secret preparation MUST stay up across the switch, so a
    # Marshall-only release never drops Lilly's control channel or exits guest
    # actors.
    def changed_units(self, system: Path, units: Iterable[str]) -> set[str]:
        return {
            unit for unit in units if unit_identity(ACTIVE, unit) != unit_identity(system, unit)
        }

    def units_to_restart(self, system: Path, affected: Iterable[str]) -> set[str]:
        assert self.candidate is not None
        candidate = self.candidate
        consumers = {string_value(item) for item in list_value(candidate["consumers"])}
        changed = self.changed_units(system, affected)
        changed |= set(self.previous_consumers) - consumers
        bundles = object_value(candidate.get("bundleConsumers") or {})
        for name in object_value(candidate["secrets"]):
            unit = "overalls-secrets-" + name + ".service"
            if unit not in changed and self.bundle_matches_live(name):
                continue
            # A restarted preparation unit takes its PartOf consumers down
            # implicitly; restart them deliberately, in order, instead.
            changed.add(unit)
            changed |= {string_value(item) for item in list_value(bundles.get(name, []))}
        dependents = object_value(candidate.get("consumerDependents") or {})
        while True:
            expanded = set(changed)
            for unit in changed:
                expanded |= {string_value(item) for item in list_value(dependents.get(unit, []))}
            if expanded == changed:
                return changed
            changed = expanded

    def selected(self, path: str) -> str:
        return self.staged.get(path, path)

    def serving_environments(self, previous: Mapping[str, object]) -> list[dict[str, str]]:
        baselines: list[dict[str, str]] = []
        for unit in list_value(previous["healthUnits"]):
            if not string_value(unit).startswith("marshall-"):
                continue
            pid = self.command(
                ["systemctl", "show", "--property=MainPID", "--value", string_value(unit)],
                capture=True,
            )
            if not pid.isdecimal():
                raise UpdateError("missing_marshall_baseline")
            if int(pid) == 0:
                continue
            # Read the actual serving process, not an EnvironmentFile that an
            # external delivery may already have replaced. Keep only authority
            # fields, in memory, with no values in commands or diagnostics.
            with Path("/proc", pid, "environ").open("rb") as stream:
                encoded = stream.read(self.secrets.MAX_RESOLUTION_BYTES + 1)
            if len(encoded) > self.secrets.MAX_RESOLUTION_BYTES:
                raise UpdateError("missing_marshall_baseline")
            environment: dict[str, str] = {}
            for entry in encoded.split(b"\0"):
                key, separator, value = entry.partition(b"=")
                if separator and key in [name.encode() for name in KEYS]:
                    environment[key.decode()] = value.decode()
            baselines.append(environment)
        return baselines

    def preflight(self, previous: Mapping[str, object]) -> None:
        resource_module: ResourceModule | None = None
        helper = self.config.get("resourcePolicyHelper")
        if helper:
            resource_module = load_secrets(helper)
        assert self.candidate is not None
        candidate = self.candidate
        resource_compatible = (
            resource_module.compatible(
                with_effective_lilly_binding(previous), with_effective_lilly_binding(candidate)
            )
            if resource_module
            else False
        )
        if (
            previous.get("installationBinding") != candidate.get("installationBinding")
            and not resource_compatible
        ):
            raise UpdateError("installation_binding_change")
        for command_value in list_value(candidate["diagnosticPreflight"]):
            command = [string_value(item) for item in list_value(command_value)]
            command[4] = self.selected(command[4])
            self.command(command, timeout=15)
        self.previous_consumers = [
            string_value(item) for item in list_value(previous.get("consumers", []))
        ]
        marshall = candidate["marshall"]
        if marshall:
            current = self.environment(
                self.selected(string_value(object_value(marshall)["environmentFile"]))
            )
            old = previous.get("marshall")
            if old:
                baselines = self.serving_environments(previous)
                if not baselines:
                    baselines = [
                        self.environment(string_value(object_value(old)["environmentFile"]))
                    ]
                if not all(compatible(prior, current) for prior in baselines):
                    raise UpdateError("coordinated_secret_change")
            elif self.command(
                ["systemctl", "list-units", "--plain", "--no-legend", "marshall-*.service"],
                capture=True,
            ):
                raise UpdateError("missing_marshall_baseline")
        lilly = candidate["lilly"]
        old_lilly = previous.get("lilly")
        if old_lilly and (
            not lilly
            or (
                not lilly_bindings_equivalent(
                    object_value(old_lilly)["binding"], object_value(lilly)["binding"]
                )
                and not resource_compatible
            )
        ):
            raise UpdateError("lilly_binding_change")
        if lilly:
            owner_path = Path("/var/lib/lilly/owner.json")
            if old_lilly and not owner_path.exists():
                raise UpdateError("missing_lilly_baseline")
            if not old_lilly and self.command(
                ["systemctl", "list-units", "--plain", "--no-legend", "lilly.service"], capture=True
            ):
                raise UpdateError("missing_lilly_baseline")
            if owner_path.exists():
                lilly_owner_file(owner_path)
                owner = read_json(owner_path)
                if owner.get("version") != 1:
                    raise UpdateError("lilly_binding_change")
                for key, value in object_value(object_value(lilly)["owner"]).items():
                    if owner.get(key) != value:
                        raise UpdateError("lilly_binding_change")
            self.command(
                [
                    "env",
                    "OVERALLS_CREDENTIAL="
                    + self.selected(string_value(object_value(lilly)["credentialFile"])),
                    "OVERALLS_HOST=" + string_value(object_value(lilly)["hostId"]),
                    "RELEASE_DISTRIBUTION=none",
                    "RELEASE_COOKIE=deploymentcheck",
                    "ERL_CRASH_DUMP=/dev/null",
                    *(
                        [
                            "ERL_CRASH_DUMP_PUBLIC_KEY="
                            + string_value(object_value(lilly)["crashDumpPublicKey"])
                        ]
                        if object_value(lilly).get("crashDumpPublicKey")
                        else []
                    ),
                    string_value(object_value(lilly)["release"]) + "/bin/lilly",
                    "eval",
                    'with {:ok, _} <- Lilly.Control.CredentialFile.read(System.fetch_env!("OVERALLS_CREDENTIAL"), System.fetch_env!("OVERALLS_HOST")), '
                    "{:ok, machine} <- Lilly.Host.Identity.read(), "
                    'true <- (case File.read("/var/lib/lilly/owner.json") do '
                    '{:ok, bytes} -> JSON.decode!(bytes)["machine_id"] == machine; {:error, :enoent} -> true; _ -> false end) '
                    "do System.halt(0) else _ -> System.halt(1) end",
                ],
                timeout=60,
            )
        if resource_module and candidate.get("resourcePolicy") is not None:
            if not resource_compatible:
                raise UpdateError("resource_policy_change")
            self.resources = resource_module.Transition(
                previous, candidate, self.command, atomic_json, STATE
            )
            try:
                self.resources.prepare()
            except Exception as error:
                raise UpdateError(resource_module.failure_reason(error)) from error

    def migrate(self) -> None:
        assert self.candidate is not None
        marshall = object_value(self.candidate["marshall"]) if self.candidate["marshall"] else None
        if not marshall:
            return
        self.command(
            [
                "systemd-run",
                "--quiet",
                "--wait",
                "--collect",
                "--pipe",
                # A migrator may outlive a killed updater. A fixed host-local unit
                # prevents the retry from consuming another two connections until
                # that bounded operation has exited and systemd collects the unit.
                "--unit=overalls-auto-update-migrate",
                "--property=Type=oneshot",
                "--property=DynamicUser=yes",
                "--property=NoNewPrivileges=yes",
                "--property=UMask=0077",
                "--property=TimeoutStartSec=1800",
                "--property=RuntimeDirectory=overalls-migration",
                "--property=EnvironmentFile="
                + self.selected(string_value(marshall["environmentFile"])),
                "--property=LoadCredential=database-ca.crt:"
                + self.selected(string_value(marshall["databaseCAFile"])),
                string_value(marshall["migrate"]),
            ],
            timeout=1810,
        )

    # @cc [owner:ghuntley,label:recovery] updater-socket-quiescence
    # Socket activators MUST stop before their consumer services and restart
    # afterward. A failed activation MUST attempt to restore prior live roles.

    # @cc [owner:ghuntley,label:recovery] updater-shared-memory-preflight
    # Activation MUST refuse a missing, read-only or incorrectly permissioned
    # /dev/shm tmpfs before stopping consumers, so PostgreSQL can restart.
    def activate(self, bundle: Path) -> None:
        assert self.candidate is not None
        if not shared_memory_ready():
            raise UpdateError("shared_memory_unavailable")
        candidate = self.candidate
        # Snapshot the consumer set before stopping anything. The durable
        # descriptor allows recovery even if the updater dies during switching.
        consumers = [string_value(item) for item in list_value(candidate["consumers"])]
        affected = sorted(set(consumers + self.previous_consumers))
        system = (bundle / "system").resolve(strict=True)
        secret_units = [
            "overalls-secrets-" + name + ".service" for name in object_value(candidate["secrets"])
        ]
        socket_units = [string_value(item) for item in list_value(candidate["socketUnits"])]
        restarting = self.units_to_restart(system, affected + secret_units + socket_units)
        running = {
            unit
            for unit in affected
            if self.command(
                ["systemctl", "show", "--property=ActiveState", "--value", unit], capture=True
            )
            in {"active", "activating", "reloading"}
        }
        # Restore previously active consumers and enabled application roles.
        # Inactive renewal/publication oneshots remain timer-driven. Starting a
        # unit that stayed up is a no-op.
        health_units = [string_value(item) for item in list_value(candidate["healthUnits"])]
        units = sorted(set(health_units) | (set(consumers) & running))
        # A socket is quiesced only when it or its service restarts.
        running_sockets = [
            unit
            for unit in socket_units
            if (unit in restarting or unit[: -len(".socket")] + ".service" in restarting)
            and self.command(
                ["systemctl", "show", "--property=ActiveState", "--value", unit], capture=True
            )
            in {"active", "activating", "reloading"}
        ]
        # Stop serving roles before their dependencies. In particular, a live
        # Marshall may otherwise restart its SMTP relay during the stop loop.
        stopping = list(
            dict.fromkeys([unit for unit in health_units if unit in running and unit in restarting])
        )
        stopping.extend(sorted((running & restarting) - set(stopping)))
        retained = sorted((running - restarting) | (set(secret_units) - restarting))
        print(
            json.dumps({"event": "update.units_retained", "count": len(retained)}),
            flush=True,
        )
        # First enrollment can introduce a secret service absent from the base.
        # Stop existing preparation units; stopping an unknown unit fails.
        existing_secrets: list[str] = []
        complete = False
        try:
            self.stop_units(running_sockets)
            self.stop_units(stopping)
            existing_secrets = [
                unit
                for unit in secret_units
                if unit in restarting
                and self.command(
                    ["systemctl", "show", "--property=LoadState", "--value", unit], capture=True
                )
                != "not-found"
            ]
            # Secret preparation units are independent leaves once every
            # consumer has stopped: stop them in one transaction, so a slow
            # cleanup cannot serialise behind every other bundle.
            self.stop_units(existing_secrets, together=True, seconds=300)
            atomic_json(RUNTIME / "handoff.json", self.handoff)
            failed_before = self.failed_units()
            try:
                self.command(
                    ["nixos-rebuild", "switch", "--no-reexec", "--store-path", str(system)]
                )
            except UpdateError:
                # switch-to-configuration also exits non-zero for failures
                # outside the system manager (for example reloading a logged-in
                # user's manager). Continue only when the candidate is active
                # and the switch failed no further system unit; restoring roles
                # and the bounded health checks below still decide the outcome.
                if ACTIVE.resolve() != system or self.failed_units() - failed_before:
                    raise
                print(json.dumps({"event": "update.switch_incomplete"}), flush=True)
            if self.resources:
                self.resources.apply()
            # Unchanged units stopped above are not restarted by nixos-rebuild.
            # Prepare every candidate bundle before restoring dependent consumers.
            if secret_units:
                self.command(["systemctl", "start", *secret_units], timeout=180)
            if units:
                self.command(["systemctl", "start", *units], timeout=180)
            if running_sockets:
                self.command(["systemctl", "start", *running_sockets], timeout=60)
            complete = True
        finally:
            if not complete:
                # A canceled stop job must not leave previously live roles down.
                # Retry each independently so one failed role cannot mask others.
                for unit in existing_secrets + sorted(running) + running_sockets:
                    try:
                        state = self.command(
                            ["systemctl", "show", "--property=ActiveState", "--value", unit],
                            timeout=5,
                            capture=True,
                        )
                        if state != "active":
                            self.command(["systemctl", "start", unit], timeout=30)
                    except UpdateError:
                        print(json.dumps({"event": "update.restore_failed"}), flush=True)

    def failed_units(self) -> set[str]:
        """Names of system units currently in the failed state."""
        output = self.command(
            ["systemctl", "list-units", "--failed", "--plain", "--no-legend"],
            timeout=30,
            capture=True,
        )
        return {line.split()[0] for line in output.splitlines() if line.strip()}

    # @cc [owner:ghuntley,label:recovery] updater-dependent-stop-completion
    # Stop each consumer in its own transaction, rechecking state because
    # stopping a dependency may stop another consumer. A canceled stop job can
    # leave its unit active until a later dependent stops, so retry remaining
    # active units after the pass. Each stop phase (sockets, consumers, secret
    # preparation) has its own deadline; independent secret-preparation leaves
    # stop together in one transaction with a longer deadline, since every
    # consumer is already down and a restore costs more than the wait. No
    # bundle may publish while a consumer remains active.
    def stop_units(self, units: list[str], *, together: bool = False, seconds: int = 180) -> None:
        deadline = time.monotonic() + seconds
        active = {"active", "activating", "deactivating", "reloading"}
        for attempt in range(4):
            running: list[str] = []
            for unit in units:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise UpdateError("activate_failed")
                state = self.command(
                    ["systemctl", "show", "--property=ActiveState", "--value", unit],
                    timeout=min(5, remaining),
                    capture=True,
                )
                if state not in active:
                    continue
                if together:
                    running.append(unit)
                    continue
                # A later stop may settle a canceled dependency job.
                with suppress(UpdateError):
                    self.command(
                        ["systemctl", "stop", unit],
                        timeout=max(1, deadline - time.monotonic()),
                    )
            if running:
                with suppress(UpdateError):
                    self.command(
                        ["systemctl", "stop", *running],
                        timeout=max(1, deadline - time.monotonic()),
                    )
            pending: list[str] = []
            for unit in units:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise UpdateError("activate_failed")
                state = self.command(
                    ["systemctl", "show", "--property=ActiveState", "--value", unit],
                    timeout=min(5, remaining),
                    capture=True,
                )
                if state not in {"inactive", "failed"}:
                    pending.append(unit)
            if not pending:
                return
            if attempt < 3:
                time.sleep(min(0.25, max(0, deadline - time.monotonic())))
        raise UpdateError("activate_failed")

    def healthy(self, bundle: Path, deadline: float) -> bool:
        if ACTIVE.resolve() != (bundle / "system").resolve():
            return False
        assert self.candidate is not None
        candidate = self.candidate
        try:
            for unit in [string_value(item) for item in list_value(candidate["healthUnits"])] + [
                "overalls-secrets-" + name + ".service"
                for name in object_value(candidate["secrets"])
            ]:
                if time.monotonic() >= deadline:
                    return False
                self.command(
                    ["systemctl", "is-active", "--quiet", unit],
                    timeout=min(5, deadline - time.monotonic()),
                )
            marshall = candidate["marshall"]
            if marshall:
                for instance in list_value(object_value(marshall)["instances"]):
                    instance_row = object_value(instance)
                    if time.monotonic() >= deadline:
                        return False
                    self.command(
                        [
                            "curl",
                            "--fail",
                            "--silent",
                            "--show-error",
                            "--noproxy",
                            "*",
                            "--max-time",
                            "3",
                            "--cacert",
                            string_value(instance_row["caFile"]),
                            "--resolve",
                            string_value(instance_row["resolve"]),
                            string_value(instance_row["url"]),
                        ],
                        timeout=min(5, deadline - time.monotonic()),
                    )
            if candidate["lilly"]:
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(2)
                    client.connect("/run/lilly-release/status.sock")
                    data = bytearray()
                    while b"\n" not in data and len(data) <= 4096:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        data.extend(chunk)
                    if len(data) > 4096 or json.loads(data).get("ready") is not True:
                        return False
            if candidate.get("porsche") and not self.porsche_healthy(deadline):
                return False
            if candidate.get("enrico"):
                response = self.command(
                    [
                        "curl",
                        "--fail",
                        "--silent",
                        "--show-error",
                        "--noproxy",
                        "*",
                        "--max-time",
                        "3",
                        "--max-filesize",
                        "4096",
                        "--unix-socket",
                        string_value(object_value(candidate["enrico"])["statusSocket"]),
                        "http://enrico/health/ready",
                    ],
                    timeout=min(5, deadline - time.monotonic()),
                    capture=True,
                )
                health: object = json.loads(response)
                if health != {"version": 1, "ready": True, "role": "enrico"}:
                    return False
            ziggy = candidate.get("ziggy")
            if ziggy:
                if time.monotonic() >= deadline:
                    return False
                response = self.command(
                    [
                        "curl",
                        "--fail",
                        "--silent",
                        "--show-error",
                        "--noproxy",
                        "*",
                        "--max-time",
                        "3",
                        "--max-filesize",
                        "4096",
                        "--unix-socket",
                        string_value(object_value(ziggy)["socket"]),
                        "http://ziggy/health/ready",
                    ],
                    timeout=min(5, deadline - time.monotonic()),
                    capture=True,
                )
                health: object = json.loads(response)
                if (
                    not isinstance(health, dict)
                    or health
                    != dict(
                        version=1,
                        ready=True,
                        role="ziggy",
                        host_id=string_value(object_value(ziggy)["hostId"]),
                    )
                    or type(health["version"]) is not int
                    or health["ready"] is not True
                ):
                    return False
            for role in list_value(candidate.get("audi", [])):
                role_row = object_value(role)
                if not self.status_healthy(
                    string_value(role_row["statusSocket"]), deadline, string_value(role_row["role"])
                ):
                    return False
            return time.monotonic() < deadline
        except (UpdateError, OSError, ValueError, subprocess.TimeoutExpired):
            return False

    # @cc [owner:ghuntley,label:recovery] updater-porsche-live-readiness
    # Porsche health MUST require its private socket's exact affirmative versioned
    # response within the remaining deployment deadline and a 4096-byte bound.
    # Unit activity alone MUST NOT establish authenticated control-plane readiness.
    def porsche_healthy(self, deadline: float) -> bool:
        assert self.candidate is not None
        return self.status_healthy(
            string_value(object_value(self.candidate["porsche"])["statusSocket"]), deadline
        )

    # @cc [owner:ghuntley,label:recovery] updater-private-role-readiness
    # Every enabled Audi role MUST return the exact affirmative versioned private
    # status response within the deployment deadline and 4096-byte limit. Missing,
    # stale, malformed or negative health MUST prevent lastHealthy advancement.
    def status_healthy(self, path: str, deadline: float, role: str | None = None) -> bool:
        deadline = min(deadline, time.monotonic() + 8)
        with socket.socket(socket.AF_UNIX) as client:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            client.settimeout(remaining)
            client.connect(path)
            data = bytearray()
            while b"\n" not in data and len(data) <= 4096:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                client.settimeout(remaining)
                chunk = client.recv(4097 - len(data))
                if not chunk:
                    break
                data.extend(chunk)
            if len(data) > 4096 or not data.endswith(b"\n"):
                return False
            value: object = json.loads(data)
            return (
                isinstance(value, dict)
                and set(value) == ({"version", "ready", "role"} if role else {"version", "ready"})
                and type(value["version"]) is int
                and value["version"] == 1
                and (role is None or value["role"] == role)
                and value["ready"] is True
                and time.monotonic() < deadline
            )

    def verify(self, bundle: Path) -> None:
        deadline = time.monotonic() + self.config["healthTimeout"]
        previous_success = False
        while time.monotonic() < deadline:
            success = self.healthy(bundle, deadline)
            if success and previous_success:
                return
            previous_success = success
            time.sleep(5)
        raise UpdateError("health_timeout")

    def record_healthy(self, identity: dict[str, str], system: str, revision: str) -> None:
        self.save(
            activatedCandidate=identity,
            lastHealthy=identity,
            lastHealthySystem=system,
            activeSystem=system,
            phase="healthy",
            failures=0,
            retryAt=0,
            failure=None,
        )
        RUNTIME.joinpath("handoff.json").unlink(missing_ok=True)
        if (RUNTIME / "staging").exists():
            shutil.rmtree(RUNTIME / "staging")
        print(json.dumps({"event": "update.healthy", "revision": revision}), flush=True)

    def run(self) -> None:
        self.step("fetch")
        for unit in self.config["secretUnits"]:
            self.command(["systemctl", "is-active", "--quiet", unit], timeout=5)
        revision = self.fetch()
        identity = {
            "repository": self.config["repository"],
            "branch": self.config["branch"],
            "flakeAttr": self.config["flakeAttr"],
        }
        identity["revision"] = revision
        same = self.state.get("candidate") == identity
        if same and time.time() < integer_value(self.state.get("retryAt", 0)):
            return
        if not same:
            self.save(candidate=identity, failures=0, retryAt=0, failure=None)
        if (
            same
            and self.state.get("lastHealthy") == identity
            and self.state.get("lastHealthySystem") == str(ACTIVE.resolve())
        ):
            self.save(
                phase="healthy",
                activeSystem=str(ACTIVE.resolve()),
                failures=0,
                retryAt=0,
                failure=None,
            )
            return
        self.step("build")
        bundle = self.build(revision)
        self.candidate = read_json(bundle / "manifest.json")
        system = str((bundle / "system").resolve())
        if same and self.state.get("lastHealthy") == identity and str(ACTIVE.resolve()) == system:
            self.save(
                phase="healthy",
                activeSystem=system,
                lastHealthySystem=system,
                failures=0,
                retryAt=0,
                failure=None,
            )
            return
        active_manifest = ACTIVE / "overalls-deployment.json"
        staged = False
        if (
            str(ACTIVE.resolve()) == system
            and active_manifest.exists()
            and read_json(active_manifest) == self.candidate
        ):
            # @cc [owner:ghuntley,label:security;recovery] updater-identical-closure-secrets
            # A new Git revision may produce the exact already-active closure,
            # but its secret sources can still differ. Stage (validate) every
            # candidate bundle privately first: a bundle that fails to resolve
            # fails at stage; byte-identical bundles only verify live roles
            # without interruption or migrations; any difference takes the full
            # preflight, migrate and activate path.
            self.step("stage")
            self.stage()
            staged = True
            if self.staged_matches_live():
                # Nothing changes: retire the private staging copies at once.
                staging = RUNTIME / "staging"
                self.secrets.safe_directory(staging)
                shutil.rmtree(staging)
                self.staged.clear()
                self.handoff.clear()
                self.step("verify")
                self.verify(bundle)
                self.record_healthy(identity, system, revision)
                return
        if self.state.get("activatedCandidate") != identity or str(ACTIVE.resolve()) != system:
            previous_path = ACTIVE / "overalls-deployment.json"
            previous = read_json(previous_path) if previous_path.exists() else {}
            if not staged:
                self.step("stage")
                self.stage()
            self.step("preflight")
            self.preflight(previous)
            self.step("migrate")
            self.migrate()
            self.step("activate")
            self.activate(bundle)
            self.save(activatedCandidate=identity, activeSystem=system)
        self.step("verify")
        self.verify(bundle)
        self.record_healthy(identity, system, revision)

    def failed(self, reason: str) -> None:
        failures = min(integer_value(self.state.get("failures", 0)) + 1, 16)
        delay = min(900, 30 * 2 ** (failures - 1))
        self.save(
            phase=self.phase,
            failedPhase=self.phase,
            failure=reason,
            failures=failures,
            retryAt=int(time.time()) + delay,
            activeSystem=str(ACTIVE.resolve()),
        )
        # Before activation no consumer can depend on these candidate files.
        # A partial switch retains its handoff for exact-candidate recovery.
        if self.phase in {"stage", "preflight", "migrate"}:
            RUNTIME.joinpath("handoff.json").unlink(missing_ok=True)
            if (RUNTIME / "staging").exists():
                self.secrets.safe_directory(RUNTIME / "staging")
                shutil.rmtree(RUNTIME / "staging")
        print(
            json.dumps({"event": "update.failed", "phase": self.phase, "reason": reason}),
            flush=True,
        )


def buck2_command(binary: Path) -> list[str]:
    """A Buck2 invocation in the fixed checkout, isolation directory and state."""
    return [
        "env",
        "-C",
        str(CHECKOUT),
        "HOME=" + str(BUCK2_HOME),
        "OVERALLS_GCROOT_DIR=" + str(BUCK2_GCROOTS),
        str(binary),
        "--isolation-dir",
        BUCK2_ISOLATION,
    ]


def buck2_kill_command(binary: Path) -> list[str]:
    return [*buck2_command(binary), "kill"]


def stop_buck2_daemon() -> None:
    """Post-stop counterpart of Deployment.stop_buck2, without a deployment."""
    binary = CHECKOUT / ".buck-cells" / "bin" / "buck2"
    if not binary.exists():
        return
    with suppress(OSError, subprocess.SubprocessError):
        subprocess.run(
            buck2_kill_command(binary),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
            check=False,
        )


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "status":
        print(
            json.dumps(
                read_json(STATE / "status.json")
                if (STATE / "status.json").exists()
                else {"phase": "never-run"},
                indent=2,
            )
        )
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "--cleanup":
        # systemd invokes this after abnormal termination too. Keep validated
        # handoff files for partial-switch recovery, but never retain an age key.
        helper = load_secrets(string_value(read_json(Path(sys.argv[2]))["secretHelper"]))
        helper.safe_directory(RUNTIME)
        with (RUNTIME / "update.lock").open("a") as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            stop_buck2_daemon()
            staging = RUNTIME / "staging"
            if staging.exists():
                helper.safe_directory(staging)
                for directory in staging.iterdir():
                    helper.safe_directory(directory)
                    runtime = directory / "runtime"
                    if runtime.exists():
                        helper.safe_directory(runtime)
                        (runtime / "identity").unlink(missing_ok=True)
        return 0
    os.umask(0o077)
    configuration = configuration_value(read_json(Path(sys.argv[1])))
    for directory in [STATE, RUNTIME]:
        directory.mkdir(mode=0o700, exist_ok=True)
    deployment = Deployment(configuration)
    for directory in [STATE, RUNTIME]:
        deployment.secrets.safe_directory(directory)
        if directory.stat().st_mode & 0o777 != 0o700:
            raise UpdateError("unsafe_updater_directory")
    with (RUNTIME / "update.lock").open("a") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        try:
            deployment.run()
            return 0
        except UpdateError as error:
            deployment.failed(str(error))
        except Exception:
            deployment.failed("operation_failed")
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print('{"event":"update.failed","reason":"invalid_configuration"}')
        sys.exit(1)
