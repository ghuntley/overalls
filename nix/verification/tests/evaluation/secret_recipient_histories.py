"""Generated operator histories using disposable keys and actual SOPS/age tools."""

import importlib.util
import json
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import traceback
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict
from unittest.mock import patch

import yaml
from hypothesis import Verbosity, example, given, settings
from hypothesis import strategies as st

DOCUMENTS = ("first", "second", "third")
SUFFIXES = ("json", "yaml", "yml")


class User(TypedDict):
    sshKeys: list[str]
    secretRecovery: bool
    login: bool


class Host(TypedDict):
    sshKeys: list[str]


class Document(TypedDict):
    path: str
    hosts: list[str]
    recoveryOnly: bool


class Inventory(TypedDict):
    hosts: dict[str, Host]
    documents: dict[str, Document]


class Manifest(TypedDict):
    users: dict[str, User]
    inventory: Inventory


@dataclass(frozen=True)
class Policy:
    """Logical recipient operations; recovery bits are 1 (alpha), 2 (beta) and 4 (operator)."""

    recovery: int
    overlap: bool
    host_generation: int
    selections: tuple[int, int, int]

    def recovery_keys(self) -> frozenset[int]:
        """@cc [owner:ghuntley,label:verification] turnover-recipient-model
        Recovery membership MUST derive from the generated bitmask alone: no
        identity may be pinned into every generation, so full recipient turnover
        is expressible. Zero membership is not generatable because the CLI
        refuses a document policy without any recovery user.
        """
        keys = set()
        if self.recovery & 4:
            keys.add(0)
        if self.recovery & 1:
            keys.add(1)
            if self.overlap:
                keys.add(2)
        if self.recovery & 2:
            keys.add(2)
        return frozenset(keys)

    def host_keys(self) -> tuple[int, ...]:
        return ((3,), (3, 4), (4,))[self.host_generation]

    def allowed(self, document: int) -> frozenset[int]:
        """@cc [owner:ghuntley,label:verification] independent-recipient-oracle
        Expected decryptors MUST derive from generated logical operations only,
        never the CLI policy, metadata, exported recipients or reconciliation output.
        """
        keys = set(self.recovery_keys())
        if self.selections[document] & 1:
            keys.update(self.host_keys())
        if self.selections[document] & 2:
            keys.add(5)
        return frozenset(keys)


selections = st.tuples(st.integers(0, 3), st.integers(0, 3), st.just(0))
policies = st.builds(Policy, st.integers(1, 7), st.booleans(), st.integers(0, 2), selections)


@st.composite
def successors(draw: st.DrawFn, previous: Policy, host_generation: int | None = None) -> Policy:
    """Draw a destination retaining at least one source recovery identity.

    The retained anchor mirrors the documented two-generation ceremony: a
    successor must join and be verified before the incumbent retires, so every
    generated transition has an identity that both decrypts the published
    source and remains a destination recovery member.
    """
    retained = draw(st.sampled_from(sorted(previous.recovery_keys())))
    generation = host_generation if host_generation is not None else draw(st.integers(0, 2))
    return draw(
        st.builds(Policy, st.integers(1, 7), st.booleans(), st.just(generation), selections).filter(
            lambda candidate: retained in candidate.recovery_keys()
        )
    )


@st.composite
def histories(draw: st.DrawFn) -> tuple[Policy, ...]:
    chain = [Policy(4, False, 0, draw(selections))]
    chain.append(draw(successors(chain[-1], host_generation=1)))
    for _ in range(draw(st.integers(0, 2))):
        chain.append(draw(successors(chain[-1])))
    chain.append(draw(successors(chain[-1], host_generation=2)))
    return tuple(chain)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def capture(
    args: list[str], env: dict[str, str], data: bytes | None = None
) -> subprocess.CompletedProcess[bytes]:
    # Exceptions are rendered as source locations only at the outer boundary.
    return subprocess.run(args, input=data, capture_output=True, env=env, timeout=60)


def checked(args: list[str], env: dict[str, str], data: bytes | None = None) -> bytes:
    result = capture(args, env, data)
    require(result.returncode == 0, "fixture cryptographic command failed")
    return result.stdout


@dataclass(frozen=True)
class FileState:
    mode: int
    inode: int
    data: bytes | None


def inventory(root: Path) -> dict[str, FileState]:
    found: dict[str, FileState] = {}
    for path in root.rglob("*"):
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), "unsafe fixture entry")
        found[str(path.relative_to(root))] = FileState(
            stat.S_IMODE(info.st_mode),
            info.st_ino,
            path.read_bytes() if stat.S_ISREG(info.st_mode) else None,
        )
    return found


class Fixture:
    """@cc [owner:ghuntley,label:security] disposable-secret-history-custody
    Private bytes MUST stay in a disposable mode-0700 runtime tree, subprocess
    pipes or memory. Diagnostics MUST omit values, keys, raw tool output and local
    variables. Each CLI return MUST leave the private inventory unchanged.
    """

    def __init__(self, root: Path, cli: Path) -> None:
        self.cli = cli
        self.root = root
        self.repo = root / "repo"
        self.private = root / "private"
        self.runtime = root / "runtime"
        for directory in (self.repo / "secrets", self.private, self.runtime):
            directory.mkdir(parents=True, mode=0o700)
        self.manifest = self.repo / "manifest.json"
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.runtime),
            "XDG_CONFIG_HOME": str(self.runtime),
            "XDG_DATA_HOME": str(self.runtime),
            "XDG_CACHE_HOME": str(self.runtime),
            "TMPDIR": str(self.runtime),
            "PYTHONDONTWRITEBYTECODE": "1",
            "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
        }
        self.public: list[str] = []
        self.recipients: list[str] = []
        for actor in range(7):
            key = self.key(actor)
            checked(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], self.env)
            public = key.with_suffix(".pub").read_text().strip()
            self.public.append(public)
            self.recipients.append(
                checked(["ssh-to-age"], self.env, public.encode()).decode().strip()
            )
            converted = checked(["ssh-to-age", "-private-key", "-i", str(key)], self.env)
            (self.private / f"age-{actor}").write_bytes(converted)
        self.payloads = [{"TOKEN": secrets.token_hex(24), "DOCUMENT": name} for name in DOCUMENTS]
        for index, payload in enumerate(self.payloads):
            data = json.dumps(payload) if index == 0 else yaml.safe_dump(payload)
            (self.private / f"input-{index}").write_text(data)
        self.private_before = inventory(self.private)

    def key(self, actor: int) -> Path:
        return self.private / f"ssh-{actor}"

    def path(self, index: int) -> Path:
        return self.repo / "secrets" / f"{DOCUMENTS[index]}.enc.{SUFFIXES[index]}"

    def kind(self, index: int) -> str:
        return "json" if index == 0 else "yaml"

    def policy(self, policy: Policy) -> None:
        # Only this serializer builds the public manifest. The independent oracle
        # consumes Policy operations directly and never reads this representation.
        raw = Manifest(
            users={
                "operator": User(
                    sshKeys=[self.public[0]],
                    secretRecovery=bool(policy.recovery & 4),
                    login=False,
                ),
                "alpha": User(
                    sshKeys=[self.public[key] for key in ((1, 2) if policy.overlap else (1,))],
                    secretRecovery=bool(policy.recovery & 1),
                    login=True,
                ),
                "beta": User(
                    sshKeys=[self.public[2]], secretRecovery=bool(policy.recovery & 2), login=True
                ),
                "outsider": User(sshKeys=[self.public[6]], secretRecovery=False, login=True),
            },
            inventory=Inventory(
                hosts={
                    "host-a": Host(sshKeys=[self.public[key] for key in policy.host_keys()]),
                    "host-b": Host(sshKeys=[self.public[5]]),
                },
                documents={
                    name: Document(
                        path=str(self.path(index).relative_to(self.repo)),
                        hosts=[
                            host
                            for bit, host in ((1, "host-a"), (2, "host-b"))
                            if policy.selections[index] & bit
                        ],
                        recoveryOnly=policy.selections[index] == 0,
                    )
                    for index, name in enumerate(DOCUMENTS)
                },
            ),
        )
        self.manifest.write_text(json.dumps(raw))

    def invoke(
        self, *args: str, fault: tuple[int, bool] | None = None
    ) -> subprocess.CompletedProcess[bytes]:
        command = [sys.executable, str(self.cli)]
        if fault is not None:
            command = [
                sys.executable,
                __file__,
                "fault",
                str(self.cli),
                str(fault[0]),
                str(int(fault[1])),
            ]
        result = capture(
            [*command, "--manifest", str(self.manifest), *args, "--root", str(self.repo)], self.env
        )
        require(inventory(self.private) == self.private_before, "private fixture inventory changed")
        require(list(self.runtime.iterdir()) == [], "CLI left private runtime artifacts")
        allowed = {"manifest.json", "secrets"} | {
            str(self.path(index).relative_to(self.repo)) for index in range(3)
        }
        found = inventory(self.repo)
        require(found.keys() <= allowed, "CLI left unexpected repository artifacts")
        require(
            all(state.mode == (0o700 if state.data is None else 0o600) for state in found.values()),
            "unsafe repository fixture permissions",
        )
        combined = result.stdout + result.stderr
        require(b"Traceback" not in combined, "CLI printed a traceback")
        for state in self.private_before.values():
            if state.data is not None:
                require(state.data not in combined, "CLI printed private file contents")
        for payload in self.payloads:
            require(payload["TOKEN"].encode() not in combined, "CLI printed private plaintext")
        require(str(self.private).encode() not in combined, "CLI printed private fixture path")
        return result

    def success(self, *args: str) -> None:
        require(self.invoke(*args).returncode == 0, "operator command failed")

    def rekey(
        self, actor: int = 0, fault: tuple[int, bool] | None = None
    ) -> subprocess.CompletedProcess[bytes]:
        return self.invoke("rekey", "--ssh-key", str(self.key(actor)), fault=fault)

    def snapshot(self) -> tuple[bytes, ...]:
        return tuple(self.path(index).read_bytes() for index in range(3))

    def decryptors(self, expected: tuple[frozenset[int], ...]) -> None:
        for index in range(3):
            ciphertext = self.path(index).read_bytes()
            for actor in range(7):
                require(
                    self.envelope_decrypt(actor, ciphertext, index) == (actor in expected[index]),
                    "actual decryptor differs from operation oracle",
                )
        require(inventory(self.private) == self.private_before, "decryption changed private inputs")
        require(list(self.runtime.iterdir()) == [], "decryption left runtime artifacts")

    def envelope_decrypt(self, actor: int, ciphertext: bytes, index: int) -> bool:
        """Actual SOPS decrypt attempt as one identity; True requires payload equality."""
        env = {**self.env, "SOPS_AGE_KEY_FILE": str(self.private / f"age-{actor}")}
        result = capture(
            [
                "sops",
                "--decrypt",
                "--input-type",
                self.kind(index),
                "--output-type",
                "json",
                "/dev/stdin",
            ],
            env,
            ciphertext,
        )
        if result.returncode != 0:
            return False
        parsed: object = json.loads(result.stdout)
        return bool(parsed == self.payloads[index])

    def data_key(self, actor: int, ciphertext: bytes, index: int) -> bytes:
        parsed: object = json.loads(ciphertext) if index == 0 else yaml.safe_load(ciphertext)
        require(isinstance(parsed, dict), "invalid SOPS envelope")
        if not isinstance(parsed, dict):
            raise AssertionError("invalid SOPS envelope")
        metadata: object = parsed.get("sops")
        if not isinstance(metadata, dict):
            raise AssertionError("missing SOPS envelope")
        entries: object = metadata.get("age")
        if not isinstance(entries, list):
            raise AssertionError("missing age envelopes")
        for entry in entries:
            if isinstance(entry, dict) and entry.get("recipient") == self.recipients[actor]:
                encrypted: object = entry.get("enc")
                if isinstance(encrypted, str):
                    return checked(
                        ["age", "--decrypt", "-i", str(self.private / f"age-{actor}")],
                        self.env,
                        encrypted.encode(),
                    )
        raise AssertionError("retained generation data-key envelope missing")

    def bootstrap(self, policy: Policy) -> None:
        self.policy(policy)
        for index, name in enumerate(DOCUMENTS):
            self.success("encrypt", name, "--input", str(self.private / f"input-{index}"))
        self.success("check")
        self.decryptors(tuple(policy.allowed(index) for index in range(3)))

    def replay(self, actor: int = 0) -> None:
        before = inventory(self.repo)
        self.success("check")
        require(self.rekey(actor).returncode == 0, "no-op rekey failed")
        require(inventory(self.repo) == before, "no-op changed ciphertext or file identity")


@contextmanager
def fixture(cli: Path) -> Generator[Fixture]:
    with tempfile.TemporaryDirectory(prefix="overalls-recipient-history-") as directory:
        root = Path(directory)
        require(stat.S_IMODE(root.stat().st_mode) == 0o700, "unsafe fixture root")
        require(not root.resolve().is_relative_to("/nix/store"), "fixture in store")
        yield Fixture(root, cli)
    require(not root.exists(), "fixture teardown incomplete")


@settings(
    max_examples=12, deadline=None, database=None, derandomize=True, verbosity=Verbosity.quiet
)
@given(history=histories())
def recipient_history(cli: Path, history: tuple[Policy, ...]) -> None:
    """@cc [owner:ghuntley,label:verification] recipient-history-access-and-custody
    Every generated transition MUST compare actual decryption to independently
    selected identities, preserve plaintext, rotate changed-document data keys,
    and retain exact files on check, refused rekey and idempotent replay. A
    successful rekey MUST be driven by an identity retained in both generations;
    full turnover without such an anchor is covered by the refusal-pair test.
    """
    with fixture(cli) as f:
        previous = history[0]
        f.bootstrap(previous)
        f.replay()
        for current in history[1:]:
            old = f.snapshot()
            f.policy(current)
            before = inventory(f.repo)
            changed = [current.allowed(index) != previous.allowed(index) for index in range(3)]
            result = f.invoke("check")
            require((result.returncode != 0) == any(changed), "check missed recipient drift")
            require(inventory(f.repo) == before, "check changed repository")
            for actor in [*sorted(set(range(3)) - current.recovery_keys()), 6]:
                result = f.rekey(actor)
                require(result.returncode != 0, "unretained operator reconciled documents")
                require(b"retained recovery identity" in result.stderr, "wrong authority refusal")
                require(inventory(f.repo) == before, "refused rekey changed repository")
            retainers = sorted(previous.recovery_keys() & current.recovery_keys())
            require(bool(retainers), "generated history has no anchored transition")
            retained = retainers[0]
            require(f.rekey(retained).returncode == 0, "retained identity rekey failed")
            now = f.snapshot()
            for index in range(3):
                require(
                    (old[index] != now[index]) == changed[index], "wrong document publication set"
                )
                require(
                    (
                        f.data_key(retained, old[index], index)
                        != f.data_key(retained, now[index], index)
                    )
                    == changed[index],
                    "changed recipient set did not replace data key",
                )
            f.decryptors(tuple(current.allowed(index) for index in range(3)))
            # Exercise public decrypt with a retained identity and an outsider.
            output = f.root / "recovered.json"
            for actor in (retained, 6):
                result = f.invoke(
                    "decrypt", "first", "--ssh-key", str(f.key(actor)), "--output", str(output)
                )
                require(
                    (result.returncode == 0) == (actor == retained),
                    "CLI decrypt authority differed",
                )
                if actor == retained:
                    parsed: object = json.loads(output.read_bytes())
                    require(parsed == f.payloads[0], "CLI decrypt changed plaintext")
                    require(stat.S_IMODE(output.stat().st_mode) == 0o600, "unsafe decrypted output")
                    output.unlink()
                else:
                    require(not output.exists(), "refused decrypt published output")
            f.replay(retained)
            previous = current


@settings(max_examples=8, deadline=None, database=None, derandomize=True, verbosity=Verbosity.quiet)
@example(selection=(1, 2, 0), interrupted=0, after=False, broken=2)
@example(selection=(3, 1, 0), interrupted=2, after=True, broken=1)
@given(
    selection=selections,
    interrupted=st.integers(0, 2),
    after=st.booleans(),
    broken=st.integers(1, 2),
)
def interrupted_history(
    cli: Path, selection: tuple[int, int, int], interrupted: int, after: bool, broken: int
) -> None:
    """@cc [owner:ghuntley,label:verification] partial-publication-retry-oracle
    Preparation refusal MUST preserve every original. A bounded failure before or
    after real per-file publication MUST retain its exact completed/uncertain
    report; explicit public CLI retry MUST converge without republishing completed
    documents. The fixture MUST NOT assume multi-document atomicity.
    """
    old_policy = Policy(4, False, 0, selection)
    new_policy = Policy(7, True, 2, selection)
    with fixture(cli) as f:
        f.bootstrap(old_policy)
        original = f.snapshot()
        f.policy(new_policy)
        # A later broken document forces failure after an earlier candidate was
        # prepared. Every original, including the deliberately bad file, stays.
        f.path(broken).write_bytes(b"invalid disposable ciphertext")
        before = inventory(f.repo)
        require(f.rekey().returncode != 0, "broken candidate accepted")
        require(inventory(f.repo) == before, "preflight failure published a candidate")
        f.path(broken).write_bytes(original[broken])
        result = f.rekey(fault=(interrupted, after))
        require(result.returncode != 0, "publication fault was not exercised")
        completed = ", ".join(DOCUMENTS[:interrupted]) or "none"
        expected = (
            f"Publication interrupted; completed documents: {completed}; possibly updated document: "
            f"{DOCUMENTS[interrupted]}. Rerun reconciliation.\n"
        ).encode()
        require(result.stderr == expected, "partial publication scope was misreported")
        require(result.stdout == b"", "interrupted CLI reported completion")
        published = interrupted + int(after)
        partial = f.snapshot()
        for index in range(3):
            require(
                (partial[index] != original[index]) == (index < published),
                "wrong partial publication set",
            )
        f.decryptors(
            tuple(
                (new_policy if index < published else old_policy).allowed(index)
                for index in range(3)
            )
        )
        result = f.invoke("check")
        require((result.returncode == 0) == (published == 3), "partial drift check was wrong")
        require(f.rekey().returncode == 0, "explicit retry failed")
        final = f.snapshot()
        require(final[:published] == partial[:published], "retry republished completed ciphertext")
        for index in range(3):
            require(
                f.data_key(0, original[index], index) != f.data_key(0, final[index], index),
                "retry retained old data key",
            )
        f.decryptors(tuple(new_policy.allowed(index) for index in range(3)))
        f.replay()


TURNOVERS = ((4, 1), (4, 2), (1, 2))
turnovers = st.sampled_from(TURNOVERS)


def actors(bits: int) -> int:
    return {4: 0, 1: 1, 2: 2}[bits]


@settings(max_examples=6, deadline=None, database=None, derandomize=True, verbosity=Verbosity.quiet)
@example(pair=(4, 1), selection=(0, 1, 0))
@example(pair=(4, 2), selection=(2, 0, 0))
@example(pair=(1, 2), selection=(3, 3, 0))
@given(pair=turnovers, selection=selections)
def ceremony_history(cli: Path, pair: tuple[int, int], selection: tuple[int, int, int]) -> None:
    """@cc [owner:ghuntley,label:verification] two-generation-ceremony-oracle
    The documented turnover of a recovery identity MUST proceed through a
    joined intermediate generation: rekey anchored by a retained identity,
    drift-free check, exact decryptor equality and data-key rotation at every
    step. After retirement, preserved historical ciphertext MUST stay openable
    by the retired incumbent and refuse the successor; the working-tree check
    stays silent about preserved bytes, as currently documented.
    """
    incumbent, successor = actors(pair[0]), actors(pair[1])
    generations = (
        Policy(pair[0], False, 0, selection),
        Policy(pair[0] | pair[1], False, 1, selection),
        Policy(pair[1], False, 2, selection),
    )
    with fixture(cli) as f:
        previous = generations[0]
        f.bootstrap(previous)
        historical = f.snapshot()
        for anchor, current in ((incumbent, generations[1]), (successor, generations[2])):
            require(
                anchor in previous.recovery_keys() & current.recovery_keys(),
                "ceremony transition lost its retained anchor",
            )
            old = f.snapshot()
            f.policy(current)
            require(f.invoke("check").returncode != 0, "joined generation hid recipient drift")
            require(f.rekey(anchor).returncode == 0, "ceremony rekey failed")
            require(f.invoke("check").returncode == 0, "ceremony reconciliation left drift")
            now = f.snapshot()
            for index in range(3):
                require(old[index] != now[index], "joined generation published no change")
                require(
                    f.data_key(anchor, old[index], index) != f.data_key(anchor, now[index], index),
                    "ceremony retained a historical data key",
                )
            f.decryptors(tuple(current.allowed(index) for index in range(3)))
            f.replay(anchor)
            previous = current
        final = generations[2]
        for index in range(3):
            require(incumbent not in final.allowed(index), "incumbent retained after turnover")
            require(successor in final.allowed(index), "successor absent after turnover")
        require(f.invoke("check").returncode == 0, "post-turnover check failed")
        # Preserved pre-turnover ciphertext (Git history or a retained backup
        # point capture) keeps its historical recipient set. Overlap=False, so
        # identity 2 belongs to exactly one of alpha/beta per generation.
        for index in range(3):
            require(
                f.envelope_decrypt(incumbent, historical[index], index),
                "incumbent cannot open its own historical generation",
            )
            require(
                not f.envelope_decrypt(successor, historical[index], index),
                "successor opened a sealed historical generation",
            )


@settings(max_examples=4, deadline=None, database=None, derandomize=True, verbosity=Verbosity.quiet)
@example(pair=(4, 1), selection=(0, 0, 0))
@given(pair=turnovers, selection=selections)
def direct_turnover_refusal(
    cli: Path, pair: tuple[int, int], selection: tuple[int, int, int]
) -> None:
    """@cc [owner:ghuntley,label:verification] direct-turnover-refusal-pair
    A single-step full recipient replacement MUST refuse on both identities and
    preserve every original: the departed identity fails the retained-recovery
    retention check before touching documents; the new identity passes the
    retention check but cannot decrypt sealed documents. check MUST report the
    drift, and restoring the previous policy MUST reconcile cleanly.
    """
    incumbent, successor = actors(pair[0]), actors(pair[1])
    source = Policy(pair[0], False, 0, selection)
    target = Policy(pair[1], False, 1, selection)
    with fixture(cli) as f:
        f.bootstrap(source)
        f.replay(incumbent)
        original = f.snapshot()
        f.policy(target)
        before = inventory(f.repo)
        require(f.invoke("check").returncode != 0, "check missed full-turnover drift")
        require(inventory(f.repo) == before, "check changed repository")
        # Removed identity: refused by the retention check before any document work.
        result = f.rekey(incumbent)
        require(result.returncode != 0, "removed identity reconciled documents")
        require(b"retained recovery identity" in result.stderr, "wrong retention refusal label")
        require(inventory(f.repo) == before, "retention refusal changed repository")
        # New identity: retained, but cannot decrypt the sealed historical documents.
        result = f.rekey(successor)
        require(result.returncode != 0, "new identity reconciled documents")
        require(b"Cryptographic operation failed" in result.stderr, "wrong decrypt refusal label")
        require(b"retained recovery identity" not in result.stderr, "mislabeled decrypt refusal")
        require(inventory(f.repo) == before, "decrypt refusal changed repository")
        require(f.snapshot() == original, "refused turnover changed ciphertext")
        # Overlap=False, so identity 2 belongs to exactly one user per generation.
        for index in range(3):
            require(
                f.envelope_decrypt(incumbent, original[index], index),
                "incumbent lost access to unchanged originals",
            )
            require(
                not f.envelope_decrypt(successor, original[index], index),
                "successor gained access without a ceremony",
            )
        # Aborted turnover: restoring the source policy reconciles without changes.
        f.policy(source)
        require(f.invoke("check").returncode == 0, "restored policy reported drift")
        f.replay(incumbent)


def fault_process() -> None:
    """Invoke actual main with a test-only interruption around real publication."""
    source, selected, after = Path(sys.argv[2]), int(sys.argv[3]), bool(int(sys.argv[4]))
    spec = importlib.util.spec_from_file_location("fleet_secrets", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("CLI unavailable")
    cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cli)
    publish = cli.publish
    count = 0

    def interrupted(path: Path, data: bytes, original: bytes | None) -> None:
        nonlocal count
        current = count
        count += 1
        if current == selected and not after:
            raise OSError("disposable publication interruption")
        publish(path, data, original)
        if current == selected and after:
            raise OSError("disposable publication interruption")

    sys.argv = [str(source), *sys.argv[5:]]
    try:
        with patch.object(cli, "publish", interrupted):
            cli.main()
    except cli.Failure as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    os.umask(0o077)
    try:
        if sys.argv[1] == "fault":
            fault_process()
        else:
            source = Path(sys.argv[1]).resolve(strict=True)
            recipient_history(source)
            print("Recipient histories passed: 12 generated examples.")
            interrupted_history(source)
            print("Interruption histories passed: 8 generated examples and 2 explicit boundaries.")
            ceremony_history(source)
            print("Ceremony histories passed: 6 generated examples and 3 explicit pairs.")
            direct_turnover_refusal(source)
            print("Direct turnover refusals passed: 4 generated examples and 1 explicit pair.")
    except Exception as error:
        frames = traceback.extract_tb(error.__traceback__)[-5:]
        locations = ", ".join(f"{Path(frame.filename).name}:{frame.lineno}" for frame in frames)
        print(f"Secret histories failed ({type(error).__name__}) at {locations}", file=sys.stderr)
        sys.exit(1)
