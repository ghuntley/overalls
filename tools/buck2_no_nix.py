"""Materialise the `tools/buck2 --no-nix` cells on a runner without Nix.

Usage: python tools/buck2_no_nix.py SYSTEM DEST

SYSTEM is a key of tools/buck2-no-nix.json `binaries` (x86_64-windows,
x86_64-linux). DEST (.buck-cells) receives bin/<buck2>, prelude/, an empty
rust/ cell, a non_hermetic-only toolchains.buckconfig and kit-id. The buck2
release asset and the prelude archive are downloaded from the URLs that file
names and MUST match the SHA-256 recorded in the pin registry
(nix/domains/artifacts/dependency-hashes.json); nix/buck/no-nix.nix checks
that the same pins are the buckCells buck2 and prelude. DEST is left alone
when its kit-id already names this release.

Contract buck2-no-nix-mode: see tools/CONTRACTS.
"""

from __future__ import annotations

import base64
import hashlib
import importlib
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

REGISTRY = Path("nix/domains/artifacts/dependency-hashes.json")
PINS = Path("tools/buck2-no-nix.json")


@dataclass(frozen=True)
class Binary:
    asset: str
    pin: str
    file: str


@dataclass(frozen=True)
class Pins:
    release: str
    prelude: str
    prelude_pin: str
    binaries: dict[str, Binary]


def _string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise SystemExit(f"buck2_no_nix: {PINS} {field} must be a non-empty string")
    return value


def load_pins(root: Path) -> Pins:
    document: object = json.loads((root / PINS).read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise SystemExit(f"buck2_no_nix: {PINS} must be an object")
    raw = document.get("binaries")
    if not isinstance(raw, dict):
        raise SystemExit(f"buck2_no_nix: {PINS} binaries must be an object")
    binaries: dict[str, Binary] = {}
    for system, entry in raw.items():
        if not isinstance(entry, dict):
            raise SystemExit(f"buck2_no_nix: {PINS} binaries.{system} must be an object")
        binaries[str(system)] = Binary(
            asset=_string(entry.get("asset"), f"binaries.{system}.asset"),
            pin=_string(entry.get("pin"), f"binaries.{system}.pin"),
            file=_string(entry.get("file"), f"binaries.{system}.file"),
        )
    return Pins(
        release=_string(document.get("release"), "release"),
        prelude=_string(document.get("prelude"), "prelude"),
        prelude_pin=_string(document.get("prelude_pin"), "prelude_pin"),
        binaries=binaries,
    )


def load_registry(root: Path) -> dict[str, str]:
    document: object = json.loads((root / REGISTRY).read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise SystemExit(f"buck2_no_nix: {REGISTRY} must be an object")
    return {str(k): v for k, v in document.items() if isinstance(v, str)}


def _sri(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return "sha256-" + base64.b64encode(digest.digest()).decode("ascii")


def fetch(url: str, expected: str, target: Path) -> None:
    print(f"buck2_no_nix: fetching {url}", file=sys.stderr, flush=True)
    with urllib.request.urlopen(url, timeout=300) as response, target.open("wb") as out:
        shutil.copyfileobj(response, out)
    actual = _sri(target)
    if actual != expected:
        raise SystemExit(f"buck2_no_nix: {url} is {actual}, but the pin registry says {expected}")


def _unzstd(source: Path, target: Path) -> None:
    zstd = shutil.which("zstd")
    if zstd is not None:
        subprocess.run([zstd, "-q", "-d", str(source), "-o", str(target)], check=True)
        return
    try:
        # Python 3.14's standard library, where no zstd executable exists.
        module = importlib.import_module("compression.zstd")
    except ImportError:
        raise SystemExit(
            "buck2_no_nix: zstd (or Python 3.14) is required to unpack buck2"
        ) from None
    decompress = getattr(module, "decompress", None)
    if not callable(decompress):
        raise SystemExit("buck2_no_nix: compression.zstd has no decompress")
    data = decompress(source.read_bytes())
    if not isinstance(data, bytes):
        raise SystemExit("buck2_no_nix: compression.zstd returned no bytes")
    target.write_bytes(data)


def _untar_prelude(archive: Path, target: Path) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        members: list[tarfile.TarInfo] = []
        for member in tar.getmembers():
            parts = member.name.split("/", 1)
            if len(parts) != 2 or not parts[1]:
                continue
            member.name = parts[1]
            members.append(member)
        tar.extractall(target, members=members, filter="data")


def materialise(root: Path, system: str, dest: Path) -> None:
    pins = load_pins(root)
    binary = pins.binaries.get(system)
    if binary is None:
        raise SystemExit(f"buck2_no_nix: no buck2 binary is pinned for {system}")
    kit_id = f"{system} {pins.release} {pins.prelude}"
    marker = dest / "kit-id"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == kit_id:
        return
    registry = load_registry(root)
    python = "python" if system.endswith("-windows") else "python3"
    with tempfile.TemporaryDirectory(prefix="buck2-no-nix-", dir=root) as scratch:
        work = Path(scratch)
        staged = work / "cells"
        (staged / "bin").mkdir(parents=True)
        (staged / "rust").mkdir()
        base = f"https://github.com/facebook/buck2/releases/download/{pins.release}"
        fetch(f"{base}/{binary.asset}", registry[binary.pin], work / binary.asset)
        _unzstd(work / binary.asset, staged / "bin" / binary.file)
        (staged / "bin" / binary.file).chmod(0o755)
        prelude = work / "prelude.tar.gz"
        fetch(
            f"https://github.com/facebook/buck2-prelude/archive/{pins.prelude}.tar.gz",
            registry[pins.prelude_pin],
            prelude,
        )
        _untar_prelude(prelude, staged / "prelude")
        # Must match the kits nix/buck/no-nix.nix builds.
        (staged / "toolchains.buckconfig").write_text(
            f"[overalls]\n  no_nix = true\n  non_hermetic = true\n[nix]\n  python = {python}\n",
            encoding="utf-8",
        )
        (staged / "kit-id").write_text(kit_id + "\n", encoding="utf-8")
        if dest.is_symlink() or dest.is_file():
            dest.unlink()
        elif dest.exists():
            shutil.rmtree(dest)
        staged.rename(dest)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    materialise(Path.cwd(), argv[0], Path(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
