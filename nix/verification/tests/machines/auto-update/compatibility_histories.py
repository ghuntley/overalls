"""Generated compatibility intent histories; no native deployment is performed."""

import base64
import contextlib
import io
import json
import stat
import tempfile
import unittest
from collections.abc import Mapping
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path

from hypothesis import given, settings
from hypothesis import strategies as st

# isort: split
# The executable Nix check copies the actual production runtime beside this file.
import updater_runtime as updater

AUTHORITY = ("DATABASE_URL", "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET")


@dataclass(frozen=True)
class Key:
    identity: int
    material: int

    def encoded(self) -> dict[str, str]:
        return {
            "id": f"fixture_{self.identity}",
            "key": base64.b64encode(self.material.to_bytes(32, "big")).decode(),
        }


@dataclass(frozen=True)
class Authority:
    keys: tuple[Key, ...]
    database: str = "postgresql://fixture:synthetic@isolated/fixture"
    cookie: str = "synthetic-cookie"
    token: str = "synthetic-token"

    def environment(self) -> dict[str, str]:
        return dict(
            zip(AUTHORITY, (self.database, self.cookie, self.token), strict=True),
            MARSHALL_CLOAK_KEYS=json.dumps([key.encoded() for key in self.keys]),
        )


class Action(Enum):
    ADD = "add"
    REORDER_INACTIVE = "reorder_inactive"
    REMOVE = "remove"
    PROMOTE = "promote"
    REPLACE_MATERIAL = "replace_material"
    CHANGE_DATABASE = "change_database"
    CHANGE_COOKIE = "change_cookie"
    CHANGE_TOKEN = "change_token"
    FILL_SIXTEEN = "fill_sixteen"
    OVERFLOW = "overflow"


def proposal(accepted: Authority, action: Action, fresh: int) -> tuple[Authority, bool]:
    """@cc [owner:ghuntley,label:verification] updater-operation-intent-oracle
    Expected acceptance MUST derive from the requested operation and retained
    accepted history, without consulting compatible or preflight results.
    """
    keys = accepted.keys
    new = Key(fresh, fresh)
    match action:
        case Action.ADD:
            return replace(accepted, keys=(*keys, new)), len(keys) < 16
        case Action.REORDER_INACTIVE:
            return replace(accepted, keys=(keys[0], *reversed(keys[1:]))), True
        case Action.REMOVE:
            return replace(accepted, keys=keys[:-1]), False
        case Action.PROMOTE:
            return replace(accepted, keys=(keys[-1], *keys[:-1])), False
        case Action.REPLACE_MATERIAL:
            changed = replace(keys[-1], material=fresh)
            return replace(accepted, keys=(*keys[:-1], changed)), False
        case Action.CHANGE_DATABASE:
            return replace(
                accepted, database="postgresql://changed:synthetic@isolated/fixture"
            ), False
        case Action.CHANGE_COOKIE:
            return replace(accepted, cookie="changed-cookie"), False
        case Action.CHANGE_TOKEN:
            return replace(accepted, token="changed-token"), False
        case Action.FILL_SIXTEEN:
            additions = tuple(Key(fresh + index, fresh + index) for index in range(16 - len(keys)))
            return replace(accepted, keys=keys + additions), True
        case Action.OVERFLOW:
            additions = tuple(Key(fresh + index, fresh + index) for index in range(17 - len(keys)))
            return replace(accepted, keys=keys + additions), False


@dataclass(frozen=True)
class FileState:
    mode: int
    inode: int
    contents: bytes


def inventory(root: Path) -> dict[str, FileState]:
    return {
        path.name: FileState(
            stat.S_IMODE(path.stat().st_mode), path.stat().st_ino, path.read_bytes()
        )
        for path in root.iterdir()
    }


class PreflightFixture(updater.Deployment):
    """@cc [owner:ghuntley,label:verification] updater-preflight-seam-boundary
    Histories MUST execute inherited preflight and selected with actual compatible.
    Only environment loading and serving-process discovery are fixture seams;
    commands MUST fail closed. Local inventory checks MUST NOT claim native
    staging, systemd discovery, migration, activation or deployment-state recovery.
    """

    def __init__(self, root: Path) -> None:
        # Deliberately bypass Deployment.__init__: it loads root-owned helpers/state.
        self.config = updater.Configuration(
            repository="unused",
            branch="unused",
            flakeAttr="unused",
            healthTimeout=1,
            buildTimeout=60,
            verbose=False,
            secretUnits=[],
            secretHelper="unused",
            resourcePolicyHelper="",
        )
        self.root = root
        self.current_path = root / "candidate-staged.json"
        self.live_path = root / "candidate-live.json"
        self.baseline_path = root / "installed.json"
        self.staged = {str(self.live_path): str(self.current_path)}
        self.previous: dict[str, object] = {
            "marshall": {"environmentFile": str(self.baseline_path)},
            "lilly": None,
            "consumers": ["marshall-fixture.service"],
        }
        self.candidate = {
            "marshall": {"environmentFile": str(self.live_path)},
            "lilly": None,
            "diagnosticPreflight": [],
            "socketUnits": [],
        }
        self.previous_consumers = []
        self.serving: list[dict[str, str]] = []
        self.reads: list[str] = []
        self.discoveries = 0

    def environment(self, path: str) -> dict[str, str]:
        self.reads.append(path)
        raw: object = json.loads(Path(path).read_bytes())
        if not isinstance(raw, dict):
            raise AssertionError("fixture environment must be an object")
        result: dict[str, str] = {}
        for key, value in raw.items():
            if not isinstance(key, str) or not isinstance(value, str):
                raise AssertionError("fixture environment must contain strings")
            result[key] = value
        return result

    def serving_environments(self, previous: Mapping[str, object]) -> list[dict[str, str]]:
        if previous != self.previous:
            raise AssertionError("wrong previous manifest supplied")
        self.discoveries += 1
        return [dict(environment) for environment in self.serving]

    def command(self, arguments: list[str], *, timeout: float = 7200, capture: bool = False) -> str:
        raise AssertionError("unexpected command at isolated preflight boundary")

    def check(
        self,
        test: unittest.TestCase,
        candidate: Authority,
        installed: Authority,
        serving: tuple[Authority, ...],
        allowed: bool,
    ) -> None:
        # Poison the unselected live file; selected() must use staged candidate bytes.
        for path, environment in (
            (self.current_path, candidate.environment()),
            (self.baseline_path, installed.environment()),
            (self.live_path, {}),
        ):
            path.write_text(json.dumps(environment))
            path.chmod(0o600)
        self.serving = [authority.environment() for authority in serving]
        before = inventory(self.root)
        before_serving = [dict(environment) for environment in self.serving]
        before_previous = json.dumps(self.previous, sort_keys=True)
        before_candidate = json.dumps(self.candidate, sort_keys=True)
        before_staged = dict(self.staged)
        self.reads.clear()
        self.discoveries = 0
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            if allowed:
                self.preflight(self.previous)
            else:
                with test.assertRaises(updater.UpdateError) as failure:
                    self.preflight(self.previous)
                test.assertEqual(str(failure.exception), "coordinated_secret_change")
        test.assertEqual(output.getvalue(), "")
        test.assertEqual(self.discoveries, 1)
        test.assertEqual(
            self.reads,
            [str(self.current_path)] + ([] if serving else [str(self.baseline_path)]),
        )
        test.assertEqual(self.previous_consumers, ["marshall-fixture.service"])
        test.assertEqual(inventory(self.root), before)
        test.assertEqual(self.serving, before_serving)
        test.assertEqual(json.dumps(self.previous, sort_keys=True), before_previous)
        test.assertEqual(json.dumps(self.candidate, sort_keys=True), before_candidate)
        test.assertEqual(self.staged, before_staged)


class CompatibilityHistories(unittest.TestCase):
    @settings(max_examples=32, deadline=None, derandomize=True, database=None)
    @given(
        order=st.permutations(tuple(Action)),
        initial_size=st.integers(3, 6),
        offset=st.integers(1, 10000),
        inactive=st.booleans(),
    )
    def test_operation_histories(
        self, order: list[Action], initial_size: int, offset: int, inactive: bool
    ) -> None:
        accepted = Authority(
            tuple(Key(offset + index, offset + index) for index in range(initial_size))
        )
        with tempfile.TemporaryDirectory(prefix="updater-history-") as directory:
            fixture = PreflightFixture(Path(directory))
            for index, action in enumerate(order):
                fresh = offset + 100 + index * 100
                candidate, allowed = proposal(accepted, action, fresh)
                old_environment, new_environment = accepted.environment(), candidate.environment()
                before_old, before_new = dict(old_environment), dict(new_environment)
                self.assertEqual(updater.compatible(old_environment, new_environment), allowed)
                self.assertEqual(old_environment, before_old)
                self.assertEqual(new_environment, before_new)
                fixture.check(self, candidate, accepted, () if inactive else (accepted,), allowed)
                if allowed:
                    accepted = candidate
                else:
                    # Explicit corrected retry returns to the accepted authority;
                    # refused candidates never become a baseline in this intent model.
                    corrected, retry_allowed = proposal(
                        accepted, Action.REORDER_INACTIVE, fresh + 50
                    )
                    self.assertTrue(retry_allowed)
                    self.assertTrue(
                        updater.compatible(accepted.environment(), corrected.environment())
                    )
                    fixture.check(self, corrected, accepted, () if inactive else (accepted,), True)
                    accepted = corrected
                self.assertTrue(updater.compatible(accepted.environment(), accepted.environment()))

    @settings(max_examples=24, deadline=None, derandomize=True, database=None)
    @given(
        order=st.permutations((1, 2, 3)),
        offset=st.integers(1, 10000),
        field=st.sampled_from(AUTHORITY),
    )
    def test_all_serving_and_inactive_baselines(
        self, order: list[int], offset: int, field: str
    ) -> None:
        active = Key(offset, offset)
        extra = tuple(Key(offset + index, offset + index) for index in (1, 2, 3))
        baselines = tuple(Authority((active, extra[index - 1])) for index in order)
        first_only = baselines[0]
        complete = Authority((active, *extra))
        # The staged file alone cannot prove serving compatibility. A replaced
        # installed file is deliberately incompatible while all live baselines fit.
        changed = dict(
            DATABASE_URL="database", SECRET_KEY_BASE="cookie", TOKEN_SIGNING_SECRET="token"
        )
        incompatible = replace(complete, **{changed[field]: "different-shared-authority"})
        with tempfile.TemporaryDirectory(prefix="updater-baselines-") as directory:
            fixture = PreflightFixture(Path(directory))
            self.assertTrue(
                updater.compatible(baselines[0].environment(), first_only.environment())
            )
            for baseline in baselines[1:]:
                self.assertFalse(
                    updater.compatible(baseline.environment(), first_only.environment())
                )
            fixture.check(self, first_only, first_only, baselines, False)
            for baseline in baselines:
                self.assertTrue(updater.compatible(baseline.environment(), complete.environment()))
            fixture.check(self, complete, incompatible, baselines, True)
            # Every position can veto, including the last serving process.
            for position in range(3):
                divergent = tuple(
                    incompatible if index == position else baseline
                    for index, baseline in enumerate(baselines)
                )
                fixture.check(self, complete, complete, divergent, False)
            fixture.check(self, complete, incompatible, (), False)
            fixture.check(self, complete, complete, (), True)


if __name__ == "__main__":
    unittest.main()
