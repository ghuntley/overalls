"""Run one non-hermetic Mila platform build step list for buck/mila.bzl.

Usage: python3 buck/mila_platform.py SPEC.json OUT_DIR [STAMP]

The spec, written by the rule at analysis time, names commands that run in the
repository with the platform SDKs on the daemon's PATH (Xcode, Gradle, the .NET
SDK, cargo), and the repository paths their outputs land in. This script runs
them in order, then copies those outputs into the Buck2 output directory, or
writes the stamp of a check. Paths in the spec are relative to the project
root, the action's working directory; `path_env` values are made absolute
because the commands change directory, and `$NAME` of one expands in argv.

Contract mila-non-hermetic-targets: see buck/CONTRACTS.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Step:
    argv: list[str]
    cwd: str


@dataclass(frozen=True)
class Output:
    source: str
    name: str
    # A SHA256SUMS file (relative to the project root or absolute) that MUST
    # list the copied file's digest, for an output another job produced.
    sums: str | None


@dataclass(frozen=True)
class Spec:
    steps: list[Step]
    env: dict[str, str]
    path_env: dict[str, str]
    outputs: list[Output]
    require: list[str]


def _strings(value: object, field: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise SystemExit(f"mila_platform: {field} must be a list of strings")
    return [str(v) for v in value]


def _mapping(value: object, field: str) -> dict[str, str]:
    if not isinstance(value, dict) or not all(
        isinstance(k, str) and isinstance(v, str) for k, v in value.items()
    ):
        raise SystemExit(f"mila_platform: {field} must map strings to strings")
    return {str(k): str(v) for k, v in value.items()}


def parse(document: object) -> Spec:
    if not isinstance(document, dict):
        raise SystemExit("mila_platform: the spec must be an object")
    steps: list[Step] = []
    raw_steps = document.get("steps")
    if not isinstance(raw_steps, list):
        raise SystemExit("mila_platform: steps must be a list")
    for raw in raw_steps:
        if not isinstance(raw, dict):
            raise SystemExit("mila_platform: each step must be an object")
        argv = _strings(raw.get("argv"), "argv")
        cwd = raw.get("cwd", ".")
        if not argv or not isinstance(cwd, str):
            raise SystemExit("mila_platform: a step needs argv and a string cwd")
        steps.append(Step(argv=argv, cwd=cwd))
    outputs: list[Output] = []
    raw_outputs = document.get("outputs", [])
    if not isinstance(raw_outputs, list):
        raise SystemExit("mila_platform: outputs must be a list")
    for raw in raw_outputs:
        if not isinstance(raw, dict):
            raise SystemExit("mila_platform: each output must be an object")
        source, name, sums = raw.get("source"), raw.get("name"), raw.get("sums")
        if not isinstance(source, str) or not isinstance(name, str):
            raise SystemExit("mila_platform: an output needs a source and a name")
        if not (sums is None or isinstance(sums, str)):
            raise SystemExit("mila_platform: sums must be a path or null")
        outputs.append(Output(source=source, name=name, sums=sums))
    return Spec(
        steps=steps,
        env=_mapping(document.get("env", {}), "env"),
        path_env=_mapping(document.get("path_env", {}), "path_env"),
        outputs=outputs,
        require=_strings(document.get("require", []), "require"),
    )


def _copy(source: Path, target: Path) -> None:
    if source.is_dir():
        shutil.copytree(source, target, symlinks=True)
    elif source.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    else:
        raise SystemExit(f"mila_platform: the build did not produce {source}")


def _verify(sums: Path, name: str, digest: str) -> None:
    if not sums.is_file():
        raise SystemExit(f"mila_platform: {sums} is missing; import the whole artifact directory")
    listed: dict[str, str] = {}
    for line in sums.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 2:
            listed[parts[1].lstrip("*")] = parts[0]
    if listed.get(name) != digest:
        raise SystemExit(f"mila_platform: {name} does not match its digest in {sums}")


def _expand(argument: str, paths: dict[str, str]) -> str:
    for name in sorted(paths, key=len, reverse=True):
        argument = argument.replace("$" + name, paths[name])
    return argument


def run(spec: Spec, root: Path, out: Path, stamp: Path | None) -> None:
    missing = [name for name in spec.require if shutil.which(name) is None]
    if missing:
        raise SystemExit(
            "mila_platform: this non_hermetic target needs "
            + ", ".join(missing)
            + " on the Buck2 daemon's PATH; run `tools/buck2 kill` after installing it"
        )
    env = dict(os.environ)
    env.update(spec.env)
    paths: dict[str, str] = {}
    for name, path in spec.path_env.items():
        paths[name] = str((root / path).resolve())
        env[name] = paths[name]
    for step in spec.steps:
        # `$NAME` of a path_env variable expands in arguments; nothing else does.
        command = [_expand(arg, paths) for arg in step.argv]
        resolved = shutil.which(command[0], path=env.get("PATH"))
        if resolved is not None:
            command[0] = resolved
        print(f"mila_platform: {' '.join(step.argv)} (in {step.cwd})", file=sys.stderr, flush=True)
        status = subprocess.run(command, cwd=root / step.cwd, env=env, check=False).returncode
        if status != 0:
            raise SystemExit(f"mila_platform: {step.argv[0]} exited with {status}")
    out.mkdir(parents=True, exist_ok=True)
    sums: list[str] = []
    for output in spec.outputs:
        target = out / output.name
        _copy(root / output.source, target)
        if target.is_file():
            digest = hashlib.sha256(target.read_bytes()).hexdigest()
            if output.sums is not None:
                _verify(root / output.sums, Path(output.source).name, digest)
            sums.append(f"{digest}  {output.name}\n")
    if sums:
        (out / "SHA256SUMS").write_text("".join(sums), encoding="utf-8")
    if stamp is not None:
        stamp.write_text("ok\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as handle:
        document: object = json.load(handle)
    root = Path.cwd()
    stamp = root / argv[2] if len(argv) == 3 else None
    run(parse(document), root, root / argv[1], stamp)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
