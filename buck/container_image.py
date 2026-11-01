"""Build or publish a Dockerfile image for buck/container_image.bzl.

Usage:
  python3 buck/container_image.py build SPEC.json --nix NIX [--store NAME=FILE...] --out OUT_DIR
  python3 buck/container_image.py publish SPEC.json --nix NIX [--store NAME=FILE...]
      --registry REG --tag TAG [--tag TAG...]
  python3 buck/container_image.py scan [FILE]   (an image tarball, or stdin)

Each `--store NAME=FILE` names a nix_assemble output (FILE holds a store
path). Its closure is exported with `nix copy` to a Nix binary cache
directory, which also holds `store-path`, and passed to `docker buildx build`
as the named build context NAME; the Dockerfile imports it from a bind mount.

`build` runs `docker buildx build --load` with the builder the Buck2 daemon's
environment selects, then streams `docker save` through the scan and writes
metadata.json, image-id, size and token-scan into OUT_DIR. `publish` (a
`buck2 run` command, so it runs with the caller's environment) builds the same
image with `--push` to REG/<repository>:TAG for each TAG, reading and writing
a registry layer cache at REG/<repository>:buildcache, then pulls the first
tag back and scans it.

The context is the repository root, `.git` included. The Namespace token never
reaches docker: NAMESPACE_RBE_TOKEN is removed from its environment, and no
build argument or secret is passed. The scan fails when a token-shaped string
(the `nsrt_` prefix and at least 20 token characters) appears in any member of
the saved image (layers, config, manifests), printing
only the member name, never its contents.

Contract container-image-buck2-only, container-image-no-token: see
.oss-scanner/CONTRACTS.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
from collections.abc import Buffer
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Protocol

TOKEN_PREFIX = b"nsrt_"
# A token is the prefix and a long run of token characters (a real one has
# hundreds); documentation and these scripts name the bare prefix, followed by
# punctuation, so only a token-shaped string counts.
TOKEN_MIN_BODY = 20
TOKEN_PATTERN = re.compile(re.escape(TOKEN_PREFIX) + rb"[A-Za-z0-9._\-]{%d,}" % TOKEN_MIN_BODY)
_TOKEN_MIN = len(TOKEN_PREFIX) + TOKEN_MIN_BODY
_CHUNK = 1 << 20
_GZIP_MAGIC = b"\x1f\x8b"
_ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


class _Readable(Protocol):
    def read(self, size: int, /) -> bytes: ...


@dataclass(frozen=True)
class Spec:
    dockerfile: str
    repository: str
    revision: str


@dataclass(frozen=True)
class ScanResult:
    members: int
    bytes_scanned: int
    matches: list[str]


def parse(document: object) -> Spec:
    if not isinstance(document, dict):
        raise SystemExit("container_image: the spec must be an object")
    values: dict[str, str] = {}
    for key in ("dockerfile", "repository", "revision"):
        value = document.get(key)
        if not isinstance(value, str) or not value:
            raise SystemExit(f"container_image: {key} must be a non-empty string")
        values[key] = value
    return Spec(**values)


def _contains(stream: _Readable) -> tuple[bool, int]:
    """Whether a token-shaped string occurs in `stream`, including across
    chunk boundaries."""
    tail = b""
    total = 0
    while chunk := stream.read(_CHUNK):
        total += len(chunk)
        window = tail + chunk
        if TOKEN_PATTERN.search(window):
            return True, total
        # A match not found yet starts within the last _TOKEN_MIN - 1 bytes.
        tail = window[-(_TOKEN_MIN - 1) :]
    return False, total


class _Peek(io.RawIOBase):
    """A stream whose first bytes were already consumed, put back in front."""

    def __init__(self, head: bytes, rest: _Readable) -> None:
        super().__init__()
        self._head = head
        self._rest = rest

    def readable(self) -> bool:
        return True

    def readinto(self, buffer: Buffer, /) -> int:
        view = memoryview(buffer).cast("B")
        size = len(view)
        if self._head:
            data, self._head = self._head[:size], self._head[size:]
        else:
            data = self._rest.read(size)
        view[: len(data)] = data
        return len(data)


def _member_contains(stream: _Readable) -> tuple[bool, int]:
    head = stream.read(4)
    peek = io.BufferedReader(_Peek(head, stream), _CHUNK)
    if head.startswith(_GZIP_MAGIC):
        with gzip.GzipFile(fileobj=peek) as unzipped:
            return _contains(unzipped)
    if head.startswith(_ZSTD_MAGIC):
        zstd = shutil.which("zstd")
        if zstd is None:
            raise SystemExit("container_image: a zstd layer needs zstd on PATH to be scanned")
        process = subprocess.Popen([zstd, "-qdc"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        assert process.stdin is not None and process.stdout is not None
        stdin = process.stdin

        def feed() -> None:
            # A thread, so a full stdout pipe cannot block the writer.
            stdin.write(head)
            while chunk := stream.read(_CHUNK):
                stdin.write(chunk)
            stdin.close()

        feeder = threading.Thread(target=feed)
        feeder.start()
        result = _contains(process.stdout)
        process.stdout.read()
        feeder.join()
        if process.wait() != 0:
            raise SystemExit("container_image: zstd could not decompress a layer")
        return result
    return _contains(peek)


def scan(archive: IO[bytes]) -> ScanResult:
    """Scan every regular member of an image tarball (`docker save`) for a
    token-shaped string. Compressed (gzip, zstd) members are scanned decompressed;
    plain ones, including uncompressed layer tars, as they are."""
    members = 0
    scanned = 0
    matches: list[str] = []
    with tarfile.open(fileobj=archive, mode="r|") as image:
        for member in image:
            if not member.isfile():
                continue
            handle = image.extractfile(member)
            if handle is None:
                continue
            found, size = _member_contains(handle)
            members += 1
            scanned += size
            if found:
                matches.append(member.name)
    return ScanResult(members=members, bytes_scanned=scanned, matches=matches)


def _root() -> Path:
    # This file is the source artifact in the checkout: buck/container_image.py.
    return Path(__file__).resolve().parents[1]


def _docker_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k != "NAMESPACE_RBE_TOKEN"}
    env["DOCKER_BUILDKIT"] = "1"
    return env


def _docker() -> str:
    docker = shutil.which("docker")
    if docker is None:
        raise SystemExit(
            "container_image: this non_hermetic target needs docker with buildx on PATH "
            "(the Buck2 daemon's for a build: run `tools/buck2 kill` after installing it)"
        )
    return docker


def _check_history(root: Path) -> None:
    git = root / ".git"
    if not git.is_dir():
        raise SystemExit(
            "container_image: the context needs a full .git directory, not a worktree link"
        )
    alternates = git / "objects" / "info" / "alternates"
    if alternates.is_file() and alternates.read_text(encoding="utf-8").strip():
        raise SystemExit(
            "container_image: .git borrows objects through objects/info/alternates; "
            "the image must carry its own history (git repack -a -d, then remove the file)"
        )


def _stores(values: list[str]) -> dict[str, Path]:
    stores: dict[str, Path] = {}
    for value in values:
        name, sep, file = value.partition("=")
        if not sep or not name or not file or name in stores:
            raise SystemExit(f"container_image: --store wants a unique NAME=FILE, got {value!r}")
        stores[name] = Path(file)
    return stores


def _export(nix: str, stores: dict[str, Path], scratch: Path) -> list[str]:
    """Export each store closure to a binary cache directory under `scratch`;
    return the `--build-context` arguments naming them."""
    argv: list[str] = []
    for name, file in sorted(stores.items()):
        path = file.read_text(encoding="utf-8").strip()
        if not path.startswith("/nix/store/"):
            raise SystemExit(f"container_image: {file} does not hold a store path")
        cache = scratch / name
        cache.mkdir(parents=True)
        subprocess.run(
            [
                nix,
                "--extra-experimental-features",
                "nix-command",
                "copy",
                "--to",
                f"file://{cache}?compression=zstd",
                path,
            ],
            check=True,
        )
        (cache / "store-path").write_text(path + "\n", encoding="utf-8")
        argv += ["--build-context", f"{name}={cache}"]
    return argv


def _build_argv(docker: str, spec: Spec, root: Path, contexts: list[str]) -> list[str]:
    return [
        docker,
        "buildx",
        "build",
        "--progress=plain",
        "--provenance=false",
        "--file",
        str(root / spec.dockerfile),
        "--label",
        f"org.opencontainers.image.revision={spec.revision}",
        *contexts,
    ]


def _scan_image(docker: str, image: str, env: dict[str, str]) -> str:
    """Stream `docker save` of a local image through the scan; fail on a match."""
    save = subprocess.Popen([docker, "save", image], env=env, stdout=subprocess.PIPE)
    assert save.stdout is not None
    result = scan(save.stdout)
    save.stdout.read()
    if save.wait() != 0:
        raise SystemExit("container_image: docker save failed")
    for name in result.matches:
        print(
            f"container_image: a Namespace token prefix appears in image member {name}",
            file=sys.stderr,
        )
    if result.matches:
        raise SystemExit("container_image: the image contains a Namespace token prefix")
    return f"members={result.members} bytes={result.bytes_scanned} matches=0\n"


def build(spec: Spec, out: Path, contexts: list[str]) -> None:
    root = _root()
    _check_history(root)
    docker = _docker()
    env = _docker_env()
    out.mkdir(parents=True, exist_ok=True)
    tag = f"{spec.repository}:buck2"
    argv = [
        *_build_argv(docker, spec, root, contexts),
        "--tag",
        tag,
        "--load",
        "--metadata-file",
        str(out / "metadata.json"),
        "--iidfile",
        str(out / "image-id"),
        str(root),
    ]
    status = subprocess.run(argv, cwd=root, env=env, check=False).returncode
    if status != 0:
        raise SystemExit(f"container_image: docker buildx build exited with {status}")
    image_id = (out / "image-id").read_text(encoding="utf-8").strip()
    size = subprocess.run(
        [docker, "image", "inspect", "--format", "{{.Size}}", image_id],
        env=env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    (out / "size").write_text(size + "\n", encoding="utf-8")
    report = _scan_image(docker, image_id, env)
    (out / "token-scan").write_text(report, encoding="utf-8")
    print(
        f"container_image: {tag} {image_id} size={size} token-scan {report.strip()}",
        file=sys.stderr,
    )


def publish(spec: Spec, registry: str, tags: list[str], contexts: list[str]) -> None:
    root = _root()
    _check_history(root)
    docker = _docker()
    image = f"{registry.rstrip('/')}/{spec.repository}"
    cache = f"{image}:buildcache"
    argv = _build_argv(docker, spec, root, contexts)
    for tag in tags:
        argv += ["--tag", f"{image}:{tag}"]
    argv += [
        "--push",
        "--cache-from",
        f"type=registry,ref={cache}",
        "--cache-to",
        f"type=registry,ref={cache},mode=max,image-manifest=true",
        str(root),
    ]
    env = _docker_env()
    status = subprocess.run(argv, cwd=root, env=env, check=False).returncode
    if status != 0:
        raise SystemExit(f"container_image: docker buildx build --push exited with {status}")
    # Scan what was published: pull it back and stream its layers.
    pushed = f"{image}:{tags[0]}"
    subprocess.run([docker, "pull", "--quiet", pushed], env=env, check=True)
    report = _scan_image(docker, pushed, env)
    print(f"container_image: published {pushed} token-scan {report.strip()}", file=sys.stderr)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="container_image")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "publish"):
        sub = commands.add_parser(command)
        sub.add_argument("spec")
        sub.add_argument("--nix", required=True)
        sub.add_argument("--store", action="append", default=[])
        if command == "build":
            sub.add_argument("--out", required=True)
        else:
            sub.add_argument("--registry", required=True)
            sub.add_argument("--tag", action="append", required=True)
    scan_parser = commands.add_parser("scan")
    scan_parser.add_argument("file", nargs="?")
    args = parser.parse_args(argv)
    command: str = args.command
    if command == "scan":
        path: str | None = args.file
        with (
            open(path, "rb")
            if path
            else os.fdopen(sys.stdin.fileno(), "rb", closefd=False) as handle
        ):
            result = scan(handle)
        for name in result.matches:
            print(
                f"container_image: a Namespace token prefix appears in image member {name}",
                file=sys.stderr,
            )
        print(
            f"members={result.members} bytes={result.bytes_scanned} matches={len(result.matches)}"
        )
        return 1 if result.matches else 0
    spec_path: str = args.spec
    with open(spec_path, encoding="utf-8") as handle:
        document: object = json.load(handle)
    spec = parse(document)
    nix: str = args.nix
    store_args: list[str] = args.store
    stores = _stores(store_args)
    # Buck2's per-action scratch directory for a build; a temporary one for
    # `buck2 run`. The exported caches never land in buck-out.
    scratch_root = os.environ.get("BUCK_SCRATCH_PATH") if command == "build" else None
    with tempfile.TemporaryDirectory(prefix="container-image-", dir=scratch_root) as scratch:
        contexts = _export(nix, stores, Path(scratch).resolve())
        if command == "build":
            out: str = args.out
            build(spec, Path(out).resolve(), contexts)
        else:
            registry: str = args.registry
            tags: list[str] = args.tag
            publish(spec, registry, tags, contexts)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
