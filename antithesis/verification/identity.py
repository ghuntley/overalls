"""Freeze exact local source, staged runtime and image identity before a run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

from assertions import roster
from schema import (
    EvidenceError,
    Json,
    arr,
    atomic_json,
    field,
    integer,
    narrow_json,
    obj,
    read_json,
    string,
)

# This is a build-input inventory. Report-only roots are absent; Marshall priv,
# including priv/docs, is deliberately part of the compiled release inventory.
SOURCE_DIRS = (
    "marshall",
    "lilly",
    "protocol",
    "audi",
    "porsche",
    "ziggy",
    "galileo",
    "brady",
    "enrico",
    "elixir",
    "nix",
    "antithesis/sdk",
    "antithesis/lilly",
    "antithesis/workload",
    "antithesis/control_peer",
    "antithesis/operator",
    "antithesis/config",
    "antithesis/entrypoints",
    "antithesis/nix",
    "antithesis/emulation",
    "antithesis/fixtures",
    "antithesis/build",
    "antithesis/verification/selections",
)
SOURCE_FILES = (
    "flake.nix",
    "flake.lock",
    "antithesis/Dockerfile",
    "antithesis/AGENTS.md",
    "antithesis/CONTRACTS",
    "antithesis/verification/assertions.py",
    "antithesis/verification/campaign.py",
    "antithesis/verification/identity.py",
    "antithesis/verification/schema.py",
    "antithesis/verification/selection.py",
)
SKIP_PARTS = frozenset(
    {
        ".git",
        ".devenv",
        ".venv",
        "_build",
        "deps",
        "node_modules",
        "__pycache__",
        ".pytest_cache",
        ".ruff_cache",
        "target",
        "contexts",
        "selected-test",
        "outputs",
        "result",
    }
)
STAGES = frozenset(
    {
        "pg",
        "marshall",
        "lilly",
        "lilly-guest",
        "audi",
        "porsche",
        "ziggy",
        "galileo",
        "brady",
        "enrico",
        "workload",
        "guest-vmm",
        "router-vmm",
        "origin",
        "smtp",
        "producer-peer",
        "request-recorder",
        "trace-spool",
        "host-vmm",
        "private-host-vmm",
        "recorder-host-vmm",
    }
)
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
# The staged catalog is one Python module tree. The workload Dockerfile copies
# ``selected-test/catalog/`` to ``/opt/overalls-antithesis/catalog/`` and the
# Nix rootfs links ``/opt/antithesis/catalog`` to that tree's ``workload``
# module. The hosted Python instrumentor catalogs each entry of
# ``/opt/antithesis/catalog`` (or its resolved link target) as one root with
# its own catalog subdirectory, and the Python SDK registers exactly one
# subdirectory per process, so one resolved root is what declares every
# selected assertion in every workload process.
STAGED_CATALOG = "catalog/workload"
IMAGE_CATALOG_ROOT = "/opt/overalls-antithesis/catalog/workload"
IMAGE_CATALOG_LINK = "/opt/antithesis/catalog"
STORE = re.compile(r"^/nix/store/[a-z0-9]{32}-[^\s]+$")
RUNTIME_IMAGE_PATHS = frozenset(
    {
        "/etc/hosts",
        "/etc/hostname",
        "/etc/mtab",
        "/etc/resolv.conf",
        "/run/.containerenv",
        "/var/tmp",
    }
)
RUNTIME_IMAGE_PREFIXES = ("/dev", "/proc", "/sys")
# Nix's Lilly source allowlist excludes generated ExUnit fixtures at this exact
# path. Keep the exclusion scoped to the source inventory; copy checks retain
# every filesystem path, including directories named ``tmp``.
SOURCE_EXCLUDED_PATHS = frozenset({"lilly/tmp"})


@dataclass(frozen=True)
class CopyInput:
    source: str
    destination: str
    chmod: int | None
    archive: bool = False


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_record(path: Path, root: Path) -> dict[str, Json]:
    mode = path.lstat().st_mode
    relative = str(path.relative_to(root))
    if stat.S_ISLNK(mode):
        return {
            "path": relative,
            "kind": "symlink",
            "mode": stat.S_IMODE(mode),
            "target": os.readlink(path),
        }
    if stat.S_ISREG(mode):
        return {
            "path": relative,
            "kind": "file",
            "mode": stat.S_IMODE(mode),
            "sha256": sha256(path.read_bytes()),
            "bytes": path.stat().st_size,
        }
    if stat.S_ISDIR(mode):
        return {"path": relative, "kind": "directory", "mode": stat.S_IMODE(mode)}
    raise EvidenceError(f"unsupported build input {path}")


def walk_inputs(
    root: Path,
    bases: tuple[str, ...],
    excluded: frozenset[str] = SKIP_PARTS,
    *,
    exclude_results: bool = True,
    excluded_paths: frozenset[str] = frozenset(),
) -> list[dict[str, Json]]:
    def excluded_path(path: Path) -> bool:
        relative = str(path.relative_to(root))
        return any(relative == item or relative.startswith(item + "/") for item in excluded_paths)

    paths: list[Path] = []
    for base in bases:
        start = root / base
        if not start.exists() and not start.is_symlink():
            raise EvidenceError(f"missing build input {start}")
        if excluded_path(start):
            continue
        paths.append(start)
        if start.is_dir() and not start.is_symlink():
            for current, dirs, files in os.walk(start, followlinks=False):
                dirs[:] = sorted(
                    name
                    for name in dirs
                    if name not in excluded
                    and not excluded_path(Path(current) / name)
                    and (not exclude_results or re.fullmatch(r"result(?:-\d+)?", name) is None)
                )
                for name in dirs + sorted(files):
                    if (
                        name not in excluded
                        and (not exclude_results or re.fullmatch(r"result(?:-\d+)?", name) is None)
                        and not excluded_path(Path(current) / name)
                    ):
                        paths.append(Path(current) / name)
    return [file_record(path, root) for path in sorted(set(paths))]


def command_bytes(args: list[str], cwd: Path | None = None) -> bytes:
    try:
        result = subprocess.run(args, check=True, capture_output=True, timeout=120, cwd=cwd)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise EvidenceError(f"required query failed: {args[0]} {args[1]}: {exc}") from exc
    return result.stdout


def command(args: list[str], cwd: Path | None = None) -> str:
    try:
        return command_bytes(args, cwd).decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise EvidenceError(f"required query returned non-UTF-8 output: {args[0]}") from exc


# A cold Buck2 evaluation first builds the artifacts the assembly imports.
BUCK2_TIMEOUT = 3600


def buck2_output(root: Path, target: str) -> str:
    """The text of the single output file `tools/buck2 build` reports for target."""
    args = [str(root / "tools/buck2"), "build", "--show-full-output", target]
    try:
        result = subprocess.run(
            args, check=True, capture_output=True, timeout=BUCK2_TIMEOUT, cwd=root
        )
        listing = result.stdout.decode("utf-8").strip().splitlines()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise EvidenceError(f"required Buck2 build failed: {target}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise EvidenceError(f"Buck2 returned non-UTF-8 output: {target}") from exc
    fields = listing[-1].split(" ", 1) if listing else []
    if len(fields) != 2 or fields[0].removeprefix("root") != target:
        raise EvidenceError(f"Buck2 reported no output for {target}")
    try:
        return Path(fields[1]).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise EvidenceError(f"unreadable Buck2 output for {target}: {exc}") from exc


def verify_current_context(
    root: Path, stage: str, staged: Path
) -> tuple[str, str, list[dict[str, Json]]]:
    """@cc [owner:ghuntley,label:verification] current-nix-context-lineage
    A staged context MUST equal the built output currently evaluated from this
    repository for its stage, including all paths, modes, links and file bytes.
    An unbuilt current output or changed staged context MUST prevent a freeze.
    """
    # The derivation only, as `nix eval` gave it: an unbuilt output still fails
    # below. The Buck2 target is what prepare-contexts.sh builds (ADR-0269).
    derivation = buck2_output(root, f"//:package-antithesis-{stage}-context[drv]")
    if STORE.fullmatch(derivation) is None:
        raise EvidenceError(f"invalid current Nix context derivation for {stage}")
    output = command(["nix-store", "--query", "--outputs", derivation])
    if STORE.fullmatch(output) is None:
        raise EvidenceError(f"invalid current Nix context output for {stage}")
    expected = Path(output)
    if not expected.is_dir():
        raise EvidenceError(f"current Nix context is not built for {stage}: {output}")
    deriver = command(["nix-store", "--query", "--deriver", output])
    if STORE.fullmatch(deriver) is None:
        raise EvidenceError(f"current Nix context has no valid derivation for {stage}")
    return output, deriver, compare_context_trees(staged, expected, stage, output)


def _archive_members(archive: tarfile.TarFile) -> dict[str, tarfile.TarInfo]:
    members: dict[str, tarfile.TarInfo] = {}
    for member in archive:
        if member.uid != 0 or member.gid != 0:
            raise EvidenceError(f"non-root ownership in rootfs archive: {member.name}")
        path = Path(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise EvidenceError(f"unsafe rootfs archive path: {member.name}")
        name = path.as_posix()
        if name in members:
            raise EvidenceError(f"duplicate rootfs archive path: {name}")
        if not (member.isfile() or member.isdir() or member.issym()):
            raise EvidenceError(f"unsupported rootfs archive member: {name}")
        members[name] = member
    if "." not in members or not members["."].isdir():
        raise EvidenceError("rootfs archive lacks its root directory")
    for name in members:
        for parent in Path(name).parents:
            ancestor = members.get(parent.as_posix())
            if ancestor is not None and not ancestor.isdir():
                raise EvidenceError(f"rootfs archive path traverses a non-directory: {name}")
    return members


def archive_records(archive_path: Path, prefix: str = "rootfs") -> list[dict[str, Json]]:
    """@cc [owner:ghuntley,label:verification] rootfs-archive-exact-lineage
    Rootfs archives MUST expose exactly one relative path per regular file,
    directory or symlink, retaining modes, targets and regular-file bytes.
    Every member MUST have UID and GID zero, matching Docker COPY's root
    ownership and the archive writer's explicit ownership normalization.
    Absolute paths, traversal, duplicate paths, hardlinks, special files and
    children below non-directory members MUST prevent an identity freeze.
    """
    records: list[dict[str, Json]] = []
    try:
        with tarfile.open(archive_path, mode="r:") as archive:
            for name, member in sorted(_archive_members(archive).items()):
                record: dict[str, Json] = {
                    "path": prefix if name == "." else prefix + "/" + name,
                    "mode": stat.S_IMODE(member.mode),
                }
                if member.isdir():
                    record["kind"] = "directory"
                elif member.issym():
                    record.update({"kind": "symlink", "target": member.linkname})
                else:
                    content = archive.extractfile(member)
                    if content is None:
                        raise EvidenceError(f"unreadable rootfs archive member: {name}")
                    digest = hashlib.sha256()
                    with content:
                        while chunk := content.read(1024 * 1024):
                            digest.update(chunk)
                    record.update(
                        {"kind": "file", "bytes": member.size, "sha256": digest.hexdigest()}
                    )
                records.append(record)
    except (OSError, tarfile.TarError) as exc:
        raise EvidenceError(f"unreadable rootfs archive: {archive_path}: {exc}") from exc
    return sorted(records, key=lambda record: Path(string(field(record, "path"), "archive path")))


def archive_bytes(archive_path: Path, name: str) -> bytes:
    try:
        with tarfile.open(archive_path, mode="r:") as archive:
            member = _archive_members(archive).get(name)
            if member is None or not member.isfile():
                raise EvidenceError(f"rootfs archive lacks regular file: {name}")
            content = archive.extractfile(member)
            if content is None:
                raise EvidenceError(f"unreadable rootfs archive member: {name}")
            with content:
                return content.read()
    except (OSError, tarfile.TarError) as exc:
        raise EvidenceError(f"unreadable rootfs archive: {archive_path}: {exc}") from exc


def compare_context_trees(
    staged: Path, expected: Path, stage: str, expected_output: str
) -> list[dict[str, Json]]:
    bases = ("identity.json", "closure-store-paths.txt", "rootfs")
    expected_files = walk_inputs(expected, bases, frozenset())
    staged_files = sorted(
        walk_inputs(staged, bases[:2], frozenset()) + archive_records(staged / "rootfs.tar"),
        key=lambda record: Path(string(field(record, "path"), "context path")),
    )
    stamp_name = "rootfs/opt/overalls/context-output.txt"
    stamp = (expected_output + "\n").encode()
    if (
        not (staged / "context-output.txt").is_file()
        or (staged / "context-output.txt").read_bytes() != stamp
        or archive_bytes(staged / "rootfs.tar", "opt/overalls/context-output.txt") != stamp
    ):
        raise EvidenceError(f"staged Nix context has no current output stamp: {stage}")
    if [item for item in staged_files if item["path"] != stamp_name] != expected_files:
        raise EvidenceError(f"staged Nix context differs from current built output: {stage}")
    return staged_files


def context_record(root: Path, stage: str) -> dict[str, Json]:
    if stage not in STAGES:
        raise EvidenceError(f"unknown image stage {stage}")
    context = root / "antithesis/build/contexts" / stage
    expected_output, expected_deriver, context_files = verify_current_context(root, stage, context)
    identity = obj(read_json(context / "identity.json"), f"{stage} Nix identity")
    if string(field(identity, "name"), "context name") != stage:
        raise EvidenceError(f"context stage mismatch: {stage}")
    roots = [string(item, "Nix runtime root") for item in arr(field(identity, "roots"), "roots")]
    if not roots or any(not STORE.fullmatch(item) for item in roots):
        raise EvidenceError(f"invalid Nix runtime roots: {stage}")
    closure_file = context / "closure-store-paths.txt"
    closure = sorted(set(closure_file.read_text(encoding="utf-8").splitlines()))
    if not closure or any(not STORE.fullmatch(item) for item in closure):
        raise EvidenceError(f"invalid Nix closure list: {stage}")
    for item in roots:
        if item not in closure:
            raise EvidenceError(f"root absent from staged closure: {item}")
    # A copied context is not enough: independently query the exact local Nix
    # store paths and their derivations. Missing store metadata fails closed.
    roots_data: list[dict[str, Json]] = []
    for item in roots:
        deriver = command(["nix-store", "--query", "--deriver", item])
        if not STORE.fullmatch(deriver):
            raise EvidenceError(f"Nix deriver unavailable for {item}")
        requisites = sorted(
            set(command(["nix-store", "--query", "--requisites", item]).splitlines())
        )
        if not requisites or any(not STORE.fullmatch(entry) for entry in requisites):
            raise EvidenceError(f"Nix closure query invalid for {item}")
        if not set(requisites).issubset(closure):
            raise EvidenceError(f"staged closure omits requisites for {item}")
        roots_data.append(
            obj(
                narrow_json({"store_path": item, "deriver": deriver, "requisites": requisites}),
                "queried root",
            )
        )
    release_drv = identity.get("releaseDerivation")
    if release_drv is not None:
        if not isinstance(release_drv, str) or not STORE.fullmatch(release_drv):
            raise EvidenceError(f"invalid release derivation: {stage}")
        release_path = string(field(identity, "release"), "release")
        if command(["nix-store", "--query", "--deriver", release_path]) != release_drv:
            raise EvidenceError(f"release derivation mismatch: {stage}")
    return obj(
        narrow_json(
            {
                "stage": stage,
                "current_nix_context": expected_output,
                "current_nix_context_derivation": expected_deriver,
                "nix_identity": identity,
                "queried_roots": roots_data,
                "staged_closure": closure,
                "context_files": context_files,
            }
        ),
        "context record",
    )


def images(root: Path, stages: list[str], engine: str) -> dict[str, Json]:
    if engine not in {"podman", "docker"}:
        raise EvidenceError("engine must be podman or docker")
    result: dict[str, Json] = {}
    for stage in stages:
        tag = f"overalls-antithesis/{stage}:local"
        raw = command([engine, "image", "inspect", "--format", "{{.Id}}", tag])
        digest = raw.removeprefix("sha256:")
        immutable = f"sha256:{digest}"
        if not DIGEST.fullmatch(immutable):
            raise EvidenceError(f"missing immutable local image ID for {tag}")
        result[stage] = {"tag": tag, "image_id": immutable}
    return result


def verify_image_contexts(
    root: Path, engine: str, contexts: list[dict[str, Json]], image_data: dict[str, Json]
) -> None:
    """@cc [owner:ghuntley,label:verification] built-image-context-lineage
    Every inspected stage image MUST carry the exact identity, closure list and
    staged Nix output path from its current, checked context. Missing or stale
    embedded provenance MUST prevent an identity freeze. This verifies build
    provenance under Docker ADD/COPY semantics, not every in-image Nix byte.
    """
    if engine not in {"podman", "docker"}:
        raise EvidenceError("engine must be podman or docker")
    for record in contexts:
        stage = string(field(record, "stage"), "context stage")
        output = string(field(record, "current_nix_context"), "current Nix context")
        image = obj(field(image_data, stage), f"{stage} image")
        image_id = string(field(image, "image_id"), f"{stage} image ID")
        if DIGEST.fullmatch(image_id) is None:
            raise EvidenceError(f"invalid image ID for {stage}")
        staged = root / "antithesis/build/contexts" / stage
        for source_name, image_path in (
            ("identity.json", "/opt/overalls/image-identity.json"),
            ("closure-store-paths.txt", "/opt/overalls/closure-store-paths.txt"),
            ("context-output.txt", "/opt/overalls/context-output.txt"),
        ):
            expected = (staged / source_name).read_bytes()
            if source_name.endswith("context-output.txt") and expected != (output + "\n").encode():
                raise EvidenceError(f"{stage} staged Nix output stamp changed")
            actual = command_bytes(
                [
                    engine,
                    "run",
                    "--rm",
                    "--network",
                    "none",
                    "--read-only",
                    "--pull",
                    "never",
                    "--entrypoint",
                    "/usr/bin/cat",
                    image_id,
                    image_path,
                ]
            )
            if actual != expected:
                raise EvidenceError(f"{stage} image has stale Nix context evidence: {source_name}")


def docker_copies(root: Path) -> dict[str, list[CopyInput]]:
    """Parse local COPY and the exact rootfs archive ADD; refuse new syntax."""
    stages: dict[str, list[CopyInput]] = {}
    current: str | None = None
    for raw in (root / "antithesis/Dockerfile").read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("FROM "):
            match = re.fullmatch(r"FROM scratch AS ([a-z][a-z0-9-]*)", line)
            if match is None or match.group(1) in stages:
                raise EvidenceError("unsupported or duplicate Dockerfile stage")
            current = match.group(1)
            stages[current] = []
        elif line.startswith(("COPY ", "ADD ")):
            if current is None:
                raise EvidenceError("unsupported Dockerfile source instruction")
            if line.startswith("ADD "):
                source = f"antithesis/build/contexts/{current}/rootfs.tar"
                if line != f"ADD {source} /" or stages[current]:
                    raise EvidenceError(f"unsupported Dockerfile ADD in {current}")
                stages[current].append(CopyInput(source, "/", None, archive=True))
                continue
            match = re.fullmatch(r"COPY (?:--chmod=(0[0-7]{3,4}) )?(\S+) (\S+)", line)
            if match is None:
                raise EvidenceError(f"unsupported Dockerfile COPY in {current}")
            source, destination = match.group(2), match.group(3)
            parts = Path(source).parts
            if (
                not source.startswith("antithesis/")
                or ".." in parts
                or any(char in source for char in "*?[]$")
                or not destination.startswith("/")
                or ".." in Path(destination).parts
            ):
                raise EvidenceError(f"unsafe Dockerfile COPY in {current}")
            chmod = int(match.group(1), 8) if match.group(1) is not None else None
            stages[current].append(CopyInput(source, destination, chmod))
    return stages


def _under_copy_destination(path: str, copied: CopyInput) -> bool:
    destination = copied.destination.rstrip("/") or "/"
    if copied.source.endswith("/") or copied.archive:
        return path == destination or path.startswith(destination + "/")
    return path == destination


def _is_runtime_image_path(path: str) -> bool:
    return path in RUNTIME_IMAGE_PATHS or any(
        path == prefix or path.startswith(prefix + "/") for prefix in RUNTIME_IMAGE_PREFIXES
    )


def _image_hashes(base: list[str], image_id: str, paths: list[str]) -> dict[str, str]:
    """@cc [owner:ghuntley,label:verification] in-image-hash-path-identity
    In-image hashes MUST bind each digest to its exact requested path, including
    paths with backslashes or newlines. Malformed, duplicate or missing records
    MUST prevent an identity freeze.
    """
    hashes: dict[str, str] = {}
    batch: list[str] = []
    size = 0
    for path in sorted(paths):
        if batch and size + len(path) + 1 > 256_000:
            output = command_bytes(
                [*base, "--entrypoint", "/usr/bin/sha256sum", image_id, "--zero", *batch]
            )
            _append_image_hashes(hashes, output)
            batch = []
            size = 0
        batch.append(path)
        size += len(path) + 1
    if batch:
        output = command_bytes(
            [*base, "--entrypoint", "/usr/bin/sha256sum", image_id, "--zero", *batch]
        )
        _append_image_hashes(hashes, output)
    if set(hashes) != set(paths):
        raise EvidenceError("invalid in-image Docker COPY hash output")
    return hashes


def _append_image_hashes(hashes: dict[str, str], output: bytes) -> None:
    if not output.endswith(b"\0"):
        raise EvidenceError("invalid in-image Docker COPY hash output")
    for record in output[:-1].split(b"\0"):
        pieces = record.split(b"  ", 1)
        if len(pieces) != 2 or re.fullmatch(rb"[0-9a-f]{64}", pieces[0]) is None:
            raise EvidenceError("invalid in-image Docker COPY hash output")
        try:
            path = pieces[1].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise EvidenceError("invalid in-image Docker COPY hash output") from exc
        if path in hashes:
            raise EvidenceError("invalid in-image Docker COPY hash output")
        hashes[path] = pieces[0].decode("ascii")


def verify_image_copy(
    root: Path,
    engine: str,
    image_id: str,
    copied: CopyInput,
    *,
    ignored_destinations: tuple[CopyInput, ...] = (),
    prune_runtime_filesystems: bool = False,
) -> None:
    source = root / copied.source
    directory = copied.source.endswith("/") or copied.archive
    wrong_shape = not source.is_file() if copied.archive else directory != source.is_dir()
    if wrong_shape or (not source.exists() and not source.is_symlink()):
        raise EvidenceError(f"Dockerfile COPY source missing or shape changed: {copied.source}")
    if directory and not copied.destination.endswith("/"):
        raise EvidenceError(f"unsupported Dockerfile directory destination: {copied.destination}")
    if not directory and copied.destination.endswith("/"):
        raise EvidenceError(f"unsupported Dockerfile file destination: {copied.destination}")
    records = (
        archive_records(source, copied.source)
        if copied.archive
        else walk_inputs(
            root,
            (copied.source,),
            frozenset() if prune_runtime_filesystems else SKIP_PARTS,
            exclude_results=not prune_runtime_filesystems,
        )
    )
    expected_tree: dict[str, tuple[str, str, str]] = {}
    expected_hashes: dict[str, str] = {}
    for record in records:
        relative = Path(string(field(record, "path"), "COPY source")).relative_to(
            Path(copied.source)
        )
        if directory and relative == Path("."):
            continue
        image_path = (
            copied.destination.rstrip("/") + "/" + relative.as_posix()
            if directory
            else copied.destination
        )
        kind = string(field(record, "kind"), "COPY kind")
        source_mode = integer(field(record, "mode"), "COPY mode")
        mode = copied.chmod if copied.chmod is not None and kind != "symlink" else source_mode
        target = string(field(record, "target"), "COPY link") if kind == "symlink" else ""
        if any(_under_copy_destination(image_path, ignored) for ignored in ignored_destinations):
            continue
        expected_tree[image_path] = (kind, format(mode, "o"), target)
        if kind == "file":
            expected_hashes[image_path] = string(field(record, "sha256"), "COPY hash")
    base = [engine, "run", "--rm", "--network", "none", "--read-only", "--pull", "never"]
    args = [*base, "--entrypoint", "/usr/bin/find", image_id, copied.destination]
    args.extend(("-mindepth", "1") if directory else ("-maxdepth", "0"))
    if prune_runtime_filesystems:
        if copied.destination != "/" or not directory:
            raise EvidenceError("runtime filesystem pruning is only valid for rootfs COPY")
        args.extend(
            (
                "(",
                "-path",
                "/proc",
                "-o",
                "-path",
                "/sys",
                "-o",
                "-path",
                "/dev",
                "-o",
                "-path",
                "/etc/hosts",
                "-o",
                "-path",
                "/etc/hostname",
                "-o",
                "-path",
                "/etc/mtab",
                "-o",
                "-path",
                "/etc/resolv.conf",
                "-o",
                "-path",
                "/run/.containerenv",
                "-o",
                "-path",
                "/var/tmp",
                ")",
                "-prune",
                "-o",
            )
        )
    listing = command([*args, "-printf", "%y\\t%m\\t%p\\t%l\\t.\\n"])
    actual_tree: dict[str, tuple[str, str, str]] = {}
    kinds = {"f": "file", "d": "directory", "l": "symlink"}
    generated_ancestors: set[str] = set()
    if prune_runtime_filesystems:
        for ignored in ignored_destinations:
            parent = Path(ignored.destination.rstrip("/")).parent
            while parent != Path("/"):
                generated_ancestors.add(str(parent))
                parent = parent.parent
    for line in listing.splitlines():
        parts = line.split("\t", 4)
        if len(parts) != 5 or parts[4] != "." or parts[0] not in kinds or parts[2] in actual_tree:
            raise EvidenceError("invalid in-image Docker COPY listing")
        if (
            prune_runtime_filesystems
            and _is_runtime_image_path(parts[2])
            and parts[2] not in expected_tree
        ) or any(_under_copy_destination(parts[2], ignored) for ignored in ignored_destinations):
            continue
        if parts[2] in generated_ancestors and parts[2] not in expected_tree:
            if (kinds[parts[0]], parts[1], parts[3]) != ("directory", "755", ""):
                raise EvidenceError(f"image COPY paths differ from source: {copied.source}")
            continue
        actual_tree[parts[2]] = (kinds[parts[0]], parts[1], parts[3])
    if actual_tree != expected_tree:
        raise EvidenceError(f"image COPY paths differ from source: {copied.source}")
    if expected_hashes:
        actual_hashes = _image_hashes(base, image_id, list(expected_hashes))
        if actual_hashes != expected_hashes:
            raise EvidenceError(f"image COPY bytes differ from source: {copied.source}")


def verify_image_copies(
    root: Path, engine: str, stages: list[str], image_data: dict[str, Json]
) -> None:
    """@cc [owner:ghuntley,label:verification] direct-docker-copy-lineage
    Every selected stage MUST unpack the current checked Nix rootfs archive. The final
    image's rootfs-owned paths MUST match that source exactly after accounting
    for later COPY destinations, their absent default-mode ancestor directories,
    and runtime pseudo-filesystems. An absent source ancestor MUST be a 0755
    directory with no link target. Every other Dockerfile COPY source MUST match
    the inspected image's path listing, modes, link targets and file bytes.
    Unsupported ADD or COPY syntax MUST fail closed.
    """
    if engine not in {"podman", "docker"}:
        raise EvidenceError("engine must be podman or docker")
    copies = docker_copies(root)
    for stage in stages:
        stage_copies = copies.get(stage)
        if not stage_copies or stage_copies[0] != CopyInput(
            f"antithesis/build/contexts/{stage}/rootfs.tar", "/", None, archive=True
        ):
            raise EvidenceError(f"selected Dockerfile stage lacks checked Nix rootfs: {stage}")
        image = obj(field(image_data, stage), f"{stage} image")
        image_id = string(field(image, "image_id"), f"{stage} image ID")
        if DIGEST.fullmatch(image_id) is None:
            raise EvidenceError(f"invalid image ID for {stage}")
        verify_image_copy(
            root,
            engine,
            image_id,
            stage_copies[0],
            ignored_destinations=tuple(stage_copies[1:]),
            prune_runtime_filesystems=True,
        )
        for copied in stage_copies[1:]:
            verify_image_copy(root, engine, image_id, copied)


def validate_compose_secrets(config: dict[str, Json]) -> None:
    services = obj(field(config, "services"), "Compose services")
    for name, value in services.items():
        service = obj(value, f"service {name}")
        environment = service.get("environment", {})
        variables = obj(environment, f"{name}.environment")
        for variable, raw in variables.items():
            sensitive = any(
                term in variable.upper()
                for term in ("PASSWORD", "TOKEN", "SECRET", "CREDENTIAL", "PRIVATE_KEY")
            )
            path_value = (
                variable.upper().endswith(("_FILE", "_OUT"))
                and isinstance(raw, str)
                and raw.startswith("/")
            )
            if sensitive and not path_value:
                raise EvidenceError(
                    f"sensitive Compose environment value must use a runtime file: {name}.{variable}"
                )


def selected_stages(config: dict[str, Json]) -> list[str]:
    # The same rendered graph drives profile validation and stage inventory.
    services = obj(field(config, "services"), "Compose services")
    stages: set[str] = set()
    for name, value in services.items():
        service = obj(value, f"service {name}")
        build = obj(field(service, "build"), f"{name}.build")
        stage = string(field(build, "target"), f"{name}.build.target")
        if stage not in STAGES:
            raise EvidenceError(f"unknown Compose stage {stage}")
        if string(field(service, "image"), f"{name}.image") != f"overalls-antithesis/{stage}:local":
            raise EvidenceError(f"Compose service {name} uses an uninspected image tag")
        stages.add(stage)
    return sorted(stages)


def verify_staged_selection(root: Path, expected: dict[str, Json]) -> None:
    staged = root / "antithesis/build/selected-test"
    actual = obj(read_json(staged / "command-manifest.json"), "staged command manifest")
    if actual != expected:
        raise EvidenceError("staged command manifest differs from selected source")
    if {path.name for path in staged.iterdir()} != {"v1", "catalog", "command-manifest.json"}:
        raise EvidenceError("staged selection contains extra or missing entries")
    expected_files: set[str] = set()
    for value in arr(field(expected, "files"), "selected files"):
        record = obj(value, "selected file")
        relative = string(field(record, "path"), "selected source").removeprefix("antithesis/test/")
        expected_files.add(relative)
        staged_file = staged / relative
        if (
            staged_file.is_symlink()
            or not staged_file.is_file()
            or sha256(staged_file.read_bytes()) != field(record, "sha256")
            or stat.S_IMODE(staged_file.stat().st_mode) != field(record, "mode")
        ):
            raise EvidenceError(f"staged selected command differs from source: {relative}")
    actual_files = {
        str(path.relative_to(staged))
        for path in (staged / "v1").rglob("*")
        if path.is_file() and "__pycache__" not in path.parts
    }
    if actual_files != expected_files:
        raise EvidenceError("staged command tree contains extra or missing files")


def verify_staged_catalog(root: Path, expected: dict[str, Json]) -> None:
    """@cc [owner:ghuntley,label:verification] staged-catalog-equals-runtime-closure
    The staged catalog MUST hold exactly the manifest's runtime dependencies as
    regular files with their source bytes and modes under one ``workload``
    module directory. Extra, missing, stale or linked members MUST prevent an
    identity freeze; the Dockerfile COPY lineage check then binds the image.
    """
    staged = root / "antithesis/build/selected-test" / Path(STAGED_CATALOG).parent
    if not staged.is_dir() or {path.name for path in staged.iterdir()} != {
        Path(STAGED_CATALOG).name
    }:
        raise EvidenceError("staged catalog must contain exactly one workload module tree")
    catalog = root / "antithesis/build/selected-test" / STAGED_CATALOG
    if field(expected, "image_catalog_root") != IMAGE_CATALOG_ROOT:
        raise EvidenceError("selected manifest names an unexpected image catalog root")
    if field(expected, "image_catalog_link") != IMAGE_CATALOG_LINK:
        raise EvidenceError("selected manifest names an unexpected image catalog link")
    expected_files: set[str] = set()
    for value in arr(field(expected, "runtime_dependencies"), "runtime dependencies"):
        record = obj(value, "runtime dependency")
        source = string(field(record, "path"), "runtime source")
        relative = source.removeprefix("antithesis/workload/")
        if relative == source:
            raise EvidenceError("runtime dependency escapes workload")
        expected_files.add(relative)
        staged_file = catalog / relative
        if (
            staged_file.is_symlink()
            or not staged_file.is_file()
            or sha256(staged_file.read_bytes()) != field(record, "sha256")
            or stat.S_IMODE(staged_file.stat().st_mode) != field(record, "mode")
        ):
            raise EvidenceError(f"staged catalog member differs from source: {relative}")
    actual_files = {
        str(path.relative_to(catalog))
        for path in catalog.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual_files != expected_files:
        raise EvidenceError("staged catalog contains extra or missing modules")


def verify_catalog_link(root: Path) -> None:
    """@cc [owner:ghuntley,label:verification] single-root-catalog-link
    The staged workload rootfs MUST expose ``/opt/antithesis/catalog`` as one
    symlink whose target is the copied selection-scoped ``workload`` module
    tree, so the hosted instrumentor resolves a single cataloged root and every
    workload process registers that root's catalog. A missing path, a real
    directory or a link with another target MUST prevent an identity freeze.
    """
    records = archive_records(root / "antithesis/build/contexts/workload/rootfs.tar")
    link = next(
        (record for record in records if field(record, "path") == "rootfs" + IMAGE_CATALOG_LINK),
        None,
    )
    if link is None or field(link, "kind") != "symlink":
        raise EvidenceError("staged workload rootfs lacks the single-root catalog link")
    if field(link, "target") != IMAGE_CATALOG_ROOT:
        raise EvidenceError("staged workload catalog link targets an unexpected tree")


def verify_image_selection(
    root: Path, engine: str, image_id: str, expected: dict[str, Json]
) -> None:
    """@cc [owner:ghuntley,label:verification] copied-workload-image-identity
    The selected workload image MUST contain exactly the copied workload source
    paths, types, modes, symlink targets and regular-file bytes. Extra or stale
    modules MUST prevent an identity freeze.
    """
    if engine not in {"podman", "docker"} or DIGEST.fullmatch(image_id) is None:
        raise EvidenceError("invalid selected workload engine or image ID")
    base = [engine, "run", "--rm", "--network", "none", "--read-only", "--pull", "never"]
    image_manifest = obj(
        json.loads(
            command(
                [
                    *base,
                    "--entrypoint",
                    "/usr/bin/cat",
                    image_id,
                    "/opt/overalls-antithesis/command-manifest.json",
                ]
            )
        ),
        "in-image command manifest",
    )
    if image_manifest != expected:
        raise EvidenceError("workload image command manifest differs from frozen selection")
    test_root = "/opt/antithesis/test/v1"
    listed = set(
        command(
            [
                *base,
                "--entrypoint",
                "/usr/bin/find",
                image_id,
                test_root,
                "-mindepth",
                "1",
                "-print",
            ]
        ).splitlines()
    )
    source_records = [
        obj(item, "selected file") for item in arr(field(expected, "files"), "selected files")
    ]
    expected_hashes = {
        f"/opt/antithesis/test/{string(field(item, 'path'), 'selected source').removeprefix('antithesis/test/')}": string(
            field(item, "sha256"), "source hash"
        )
        for item in source_records
    }
    expected_paths = set(expected_hashes)
    for path in expected_hashes:
        parent = str(Path(path).parent)
        while parent != test_root:
            expected_paths.add(parent)
            parent = str(Path(parent).parent)
    if listed != expected_paths:
        raise EvidenceError("workload image contains extra or missing test paths")
    actual_hashes = _image_hashes(base, image_id, list(expected_hashes))
    if actual_hashes != expected_hashes:
        raise EvidenceError("workload image command bytes differ from selected source")
    modes = command(
        [*base, "--entrypoint", "/usr/bin/stat", image_id, "-c", "%a", *sorted(expected_hashes)]
    ).splitlines()
    if len(modes) != len(expected_hashes) or any(mode != "755" for mode in modes):
        raise EvidenceError("workload image test commands are not executable mode 0755")
    runtime_hashes: dict[str, str] = {}
    for item in arr(field(expected, "runtime_dependencies"), "runtime dependencies"):
        record = obj(item, "runtime dependency")
        source = string(field(record, "path"), "runtime source")
        if not source.startswith("antithesis/workload/"):
            raise EvidenceError("runtime dependency escapes workload")
        runtime_hashes[
            "/opt/overalls-antithesis/workload/" + source.removeprefix("antithesis/workload/")
        ] = string(field(record, "sha256"), "runtime hash")
    actual_runtime_hashes = _image_hashes(base, image_id, list(runtime_hashes))
    if actual_runtime_hashes != runtime_hashes:
        raise EvidenceError("workload image runtime modules differ from selected source")

    workload_root = "/opt/overalls-antithesis/workload"
    workload_records = walk_inputs(root, ("antithesis/workload",))
    expected_tree: dict[str, tuple[str, str, str]] = {}
    expected_workload_hashes: dict[str, str] = {}
    for item in workload_records:
        source = string(field(item, "path"), "workload source")
        path = workload_root + source.removeprefix("antithesis/workload")
        kind = string(field(item, "kind"), "workload kind")
        mode = format(integer(field(item, "mode"), "workload mode"), "o")
        target = string(field(item, "target"), "workload target") if kind == "symlink" else ""
        expected_tree[path] = (kind, mode, target)
        if kind == "file":
            expected_workload_hashes[path] = string(field(item, "sha256"), "workload hash")
    # Docker COPY creates the destination directory, so the source root's mode
    # is not a build input. Every child path and its metadata remains checked.
    expected_tree.pop(workload_root)
    listed_tree: dict[str, tuple[str, str, str]] = {}
    listing = command(
        [
            *base,
            "--entrypoint",
            "/usr/bin/find",
            image_id,
            workload_root,
            "-mindepth",
            "1",
            "-printf",
            "%y\\t%m\\t%p\\t%l\\t.\\n",
        ]
    )
    kinds = {"f": "file", "d": "directory", "l": "symlink"}
    for line in listing.splitlines():
        parts = line.split("\t", 4)
        if len(parts) != 5 or parts[4] != "." or parts[0] not in kinds or parts[2] in listed_tree:
            raise EvidenceError("invalid in-image workload tree listing")
        listed_tree[parts[2]] = (kinds[parts[0]], parts[1], parts[3])
    if listed_tree != expected_tree:
        raise EvidenceError("workload image has extra, missing or changed source paths")
    actual_workload_hashes = _image_hashes(base, image_id, list(expected_workload_hashes))
    if actual_workload_hashes != expected_workload_hashes:
        raise EvidenceError("workload image source bytes differ from local source")


def freeze(
    root: Path, compose: Path, engine: str, selection_name: str = "control-core"
) -> dict[str, Json]:
    """@cc [owner:ghuntley,label:verification] immutable-build-input-identity
    Freeze MUST include executable source modes, symlink targets, selected
    Compose, staged closure bytes, queried Nix roots/derivers/requisites, SDK
    roster and immutable local image IDs. Any missing query MUST fail closed.
    Report-only scratchbook and review files MUST not displace runtime inputs.
    """
    root = root.resolve()
    if not compose.is_file():
        raise EvidenceError(f"missing selected Compose file {compose}")
    from selection import (
        hosted_compose,
        manifest,
        read_selection,
        rendered_compose,
        verify_materialization,
    )

    selection_path = root / "antithesis/verification/selections" / f"{selection_name}.json"
    selected = read_selection(selection_path)
    if selected.name != selection_name or selected.compose_files[0] != str(
        compose.relative_to(root)
    ):
        raise EvidenceError("selected Compose file has no explicit command profile")
    rendered_data = rendered_compose(root, selected)
    selected_manifest = manifest(root, selected)
    verify_staged_selection(root, selected_manifest)
    stages = selected_stages(rendered_data)
    selected_command_sources = tuple(
        string(field(obj(item, "selected file"), "path"), "selected path")
        for item in arr(field(selected_manifest, "files"), "selected files")
    )
    source = walk_inputs(
        root,
        SOURCE_FILES + SOURCE_DIRS + selected_command_sources,
        excluded_paths=SOURCE_EXCLUDED_PATHS,
    )
    selected_paths = {
        string(field(obj(item, "selected file"), "path"), "selected path")
        for item in arr(field(selected_manifest, "files"), "selected files")
    }
    selected_paths.update(
        string(field(obj(item, "runtime dependency"), "path"), "runtime path")
        for item in arr(field(selected_manifest, "runtime_dependencies"), "runtime dependencies")
    )
    for stage in stages:
        if stage in {"marshall", "lilly", "audi", "porsche", "ziggy", "galileo", "brady", "enrico"}:
            selected_paths.update(
                str(path.relative_to(root)) for path in (root / stage / "lib").rglob("*.ex")
            )
    selected_paths.update(
        str(path.relative_to(root)) for path in (root / "antithesis/lilly/lib").rglob("*.ex")
    )
    for directory in ("antithesis/operator", "antithesis/control_peer"):
        selected_paths.update(
            str(path.relative_to(root))
            for path in (root / directory).rglob("*")
            if path.suffix in {".ex", ".exs"}
            and "test" not in path.relative_to(root / directory).parts
        )
    assertion_roster = roster(
        root, root / "antithesis/scratchbook/property-catalog.md", selected_paths
    )
    context = [context_record(root, stage) for stage in stages]
    verify_staged_catalog(root, selected_manifest)
    verify_catalog_link(root)
    image_data = images(root, stages, engine)
    verify_image_contexts(root, engine, context, image_data)
    verify_image_copies(root, engine, stages, image_data)
    hosted_config = verify_materialization(root, selected, engine, rendered_data, image_data)
    workload_image = obj(field(image_data, "workload"), "workload image")
    verify_image_selection(
        root,
        engine,
        string(field(workload_image, "image_id"), "workload image ID"),
        selected_manifest,
    )
    harness_scope: dict[str, Json] = {
        "selection": selection_name,
        "compose_files": list(selected.compose_files),
        "hosted_compose": hosted_compose(rendered_data),
        "hosted_config_sha256": field(hosted_config, "config_sha256"),
        "harness_source": [
            item
            for item in source
            if string(field(item, "path"), "source path").startswith("antithesis/")
        ],
        "command_manifest": selected_manifest,
        "assertion_roster": assertion_roster,
        "oracle_images": {
            name: value
            for name, value in image_data.items()
            if name in {"pg", "workload", "origin", "smtp"}
        },
    }
    harness_scope_sha256 = sha256(
        json.dumps(
            harness_scope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode()
    )
    payload = obj(
        narrow_json(
            {
                "format": 1,
                "engine": engine,
                "selection": selection_name,
                "compose_files": list(selected.compose_files),
                "selected_compose": str(compose.relative_to(root)),
                "rendered_compose": rendered_data,
                "hosted_config": hosted_config,
                "harness_scope_sha256": harness_scope_sha256,
                "source_files": source,
                "nix_contexts": context,
                "images": image_data,
                "assertion_roster": assertion_roster,
                "command_manifest": selected_manifest,
                "test_templates": field(selected_manifest, "files"),
                "scope": "local build identity; no hosted execution claimed",
            }
        ),
        "build identity",
    )
    payload["identity_sha256"] = sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    )
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--compose", type=Path)
    parser.add_argument(
        "--selection",
        choices=(
            "control-core",
            "repository-origin",
            "access-smtp",
            "recorder-host",
            "admission-stub",
            "backup-restic",
            "satellite-standin",
            "guest-lifecycle",
        ),
        default="control-core",
    )
    parser.add_argument("--engine", choices=("podman", "docker"), default="podman")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    data = freeze(
        root,
        (args.compose or root / "antithesis/config/docker-compose.yaml").resolve(),
        args.engine,
        args.selection,
    )
    atomic_json(args.output, data)
    print(string(field(data, "identity_sha256"), "identity_sha256"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
