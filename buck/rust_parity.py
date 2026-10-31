"""Parity of a Buck2-built Rust leaf with the Nix build it replaces.

Contract rust-leaf-parity: see buck/CONTRACTS.

Usage: rust_parity.py [--bytes] NIX READELF NIX_STORE STORE_PATH_FILE FLAKE_ATTR [RUNTIME_REF...]

With --bytes (a Cargo-driven leaf built by the same script as its Nix build,
such as Lyra's cross builds) the two trees must instead hold the same files
with the same bytes and executable bits. The one exception is Mach-O: zig's
link writes a per-run LC_UUID, so a Nix rebuild of the same derivation differs
there too; LC_UUID and the code-signature blob (which hashes it) are masked
before comparing, and manifest.json's sha256 for such a file is not compared.

STORE_PATH_FILE holds the imported Buck2 artifact's store path. Its bin/ must
name the same executables as the Nix build of FLAKE_ATTR, each with the same
ELF interpreter, RUNPATH and panic strategy (unwind or abort), no NEEDED
library and no `.debug_*` section the Nix build lacks, and
every store path in the RUNPATH or anywhere in the bytes (a vendored crate in
a panic location, for example) must be in the closure of the import's declared
runtime references; otherwise assembly would drop it from the closure. Instruction
bytes are not compared: the builds use different drivers (Cargo and Buck2).
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Linkage:
    """The dynamic-linking interface of one ELF executable."""

    interpreter: str
    needed: tuple[str, ...]
    runpath: tuple[str, ...]


def run(*argv: str) -> str:
    return subprocess.run(list(argv), check=True, capture_output=True, text=True).stdout


def linkage(readelf: str, path: Path) -> Linkage:
    interpreter = ""
    for line in run(readelf, "-l", "-W", str(path)).splitlines():
        if "Requesting program interpreter:" in line:
            interpreter = line.split(":", 1)[1].strip().rstrip("]")
    needed: list[str] = []
    runpath: list[str] = []
    for line in run(readelf, "-d", "-W", str(path)).splitlines():
        if "(NEEDED)" in line:
            library = line.split("[", 1)[1].rstrip("]")
            # Cargo's links also list the dynamic loader, which PT_INTERP
            # loads either way; it is not part of the interface compared.
            if not library.startswith("ld-linux"):
                needed.append(library)
        elif "(RUNPATH)" in line or "(RPATH)" in line:
            runpath.extend(line.split("[", 1)[1].rstrip("]").split(":"))
    return Linkage(interpreter, tuple(needed), tuple(runpath))


def debug_sections(readelf: str, path: Path) -> set[str]:
    """The `.debug_*` section names, which a stripped build does not carry."""
    names: set[str] = set()
    for line in run(readelf, "-S", "-W", str(path)).splitlines():
        for word in line.replace("]", "] ").split():
            if word.startswith(".debug_"):
                names.add(word)
    return names


# The panic_unwind runtime's message, linked only when panics unwind. Symbol
# tables may be stripped, so the strategy is read from the bytes.
UNWIND_MARKER = b"Rust cannot catch foreign exceptions"


def unwinds(path: Path) -> bool:
    """Whether the executable links the unwinding panic runtime (panic = unwind)."""
    return UNWIND_MARKER in path.read_bytes()


def embedded_store_paths(path: Path) -> set[str]:
    data = path.read_bytes()
    found: set[str] = set()
    start = data.find(b"/nix/store/")
    while start != -1:
        candidate = data[start : start + 44].decode("ascii", errors="replace")
        end = start + 44
        while end < len(data) and (chr(data[end]).isalnum() or chr(data[end]) in "+-._?="):
            end += 1
        if len(candidate) == 44:
            found.add(data[start:end].decode("ascii", errors="replace"))
        start = data.find(b"/nix/store/", start + 1)
    return found


def store_root(path: str) -> str:
    return "/".join(path.split("/")[:4])


MACHO_64 = 0xFEEDFACF
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D


def masked_macho(data: bytes) -> bytes | None:
    """The bytes with LC_UUID and the code signature zeroed, or None if not Mach-O 64."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MACHO_64:
        return None
    out = bytearray(data)
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, offset)
        if command == LC_UUID:
            out[offset + 8 : offset + 24] = bytes(16)
        elif command == LC_CODE_SIGNATURE:
            start, length = struct.unpack_from("<II", data, offset + 8)
            out[start : start + length] = bytes(length)
        offset += size
    return bytes(out)


def tree(root: Path) -> dict[str, Path]:
    return {str(p.relative_to(root)): p for p in sorted(root.rglob("*")) if p.is_file()}


def manifest_entries(path: Path, unreproducible: set[str]) -> object:
    """manifest.json with the sha256 of each unreproducible file removed."""
    document = json.loads(path.read_text())
    artifacts = document.get("artifacts", {}) if isinstance(document, dict) else {}
    for entry in artifacts.values():
        if isinstance(entry, dict) and str(entry.get("path", "")).lstrip("/") in unreproducible:
            entry.pop("sha256", None)
    return document


def compare_bytes(buck: Path, reference: Path) -> list[str]:
    """Failures of a byte-for-byte comparison of two output trees."""
    failures: list[str] = []
    mine, theirs = tree(buck), tree(reference)
    for name in sorted(set(theirs) - set(mine)):
        failures.append(f"{name}: in the Nix build {reference} but not the Buck2 import")
    for name in sorted(set(mine) - set(theirs)):
        failures.append(f"{name}: absent from the Nix build {reference}")
    unreproducible: set[str] = set()
    for name in sorted(set(mine) & set(theirs)):
        a, b = mine[name], theirs[name]
        if (a.stat().st_mode & 0o111 != 0) != (b.stat().st_mode & 0o111 != 0):
            failures.append(f"{name}: executable bit differs")
        for embedded in sorted(embedded_store_paths(a)):
            failures.append(f"{name}: embeds {embedded}")
        if name == "manifest.json":
            continue
        left, right = a.read_bytes(), b.read_bytes()
        masked_left, masked_right = masked_macho(left), masked_macho(right)
        if masked_left is not None and masked_right is not None:
            unreproducible.add(name)
            left, right = masked_left, masked_right
        if left != right:
            failures.append(
                f"{name}: bytes differ from the Nix build ({len(left)} and {len(right)} bytes)"
            )
    # Everything but the masked files' hashes; those hashes are checked
    # against the files themselves by the builds' own manifest step.
    both = "manifest.json" in mine and "manifest.json" in theirs
    if both and manifest_entries(mine["manifest.json"], unreproducible) != manifest_entries(
        theirs["manifest.json"], unreproducible
    ):
        failures.append("manifest.json: entries differ beyond the masked Mach-O hashes")
    return failures


def main(argv: list[str]) -> int:
    by_bytes = len(argv) > 1 and argv[1] == "--bytes"
    if by_bytes:
        argv = argv[:1] + argv[2:]
    if len(argv) < 6:
        print(__doc__, file=sys.stderr)
        return 2
    nix, readelf, nix_store, store_path_file, attr = argv[1:6]
    refs = [store_root(ref) for ref in argv[6:]]
    buck = Path(Path(store_path_file).read_text().strip())
    reference = Path(
        run(nix, "build", "--no-link", "--print-out-paths", f".#{attr}").strip().splitlines()[-1]
    )
    if by_bytes:
        failures = compare_bytes(buck, reference)
        for failure in failures:
            print(failure, file=sys.stderr)
        if not failures:
            print(
                f"{len(tree(buck))} files match {reference} byte for byte (Mach-O UUID and signature masked)"
            )
        return 1 if failures else 0
    closure = set(run(nix_store, "-qR", *refs).split()) if refs else set()
    failures: list[str] = []
    executables = sorted(p for p in (buck / "bin").iterdir() if p.is_file())
    if not executables:
        failures.append(f"{buck}/bin has no executables")
    # A consumer may run any executable of the Nix build it reads.
    names = {executable.name for executable in executables}
    for missing in sorted(p.name for p in (reference / "bin").iterdir() if p.name not in names):
        failures.append(f"{missing}: in the Nix build {reference} but not the Buck2 import")
    for executable in executables:
        other = reference / "bin" / executable.name
        if not other.exists():
            failures.append(f"{executable.name}: absent from the Nix build {reference}")
            continue
        mine, theirs = linkage(readelf, executable), linkage(readelf, other.resolve())
        # Fewer NEEDED entries are fine: the link resolved every symbol, and
        # an unused DT_NEEDED (rustc 1.99's libm) loads nothing the binary uses.
        if (
            mine.interpreter != theirs.interpreter
            or mine.runpath != theirs.runpath
            or not set(mine.needed) <= set(theirs.needed)
        ):
            failures.append(f"{executable.name}: Buck2 {mine} != Nix {theirs}")
        # A helper that survives a panic under unwind aborts under abort.
        if unwinds(executable) != unwinds(other.resolve()):
            strategy = {True: "unwind", False: "abort"}
            failures.append(
                f"{executable.name}: Buck2 panics {strategy[unwinds(executable)]}, "
                f"Nix panics {strategy[unwinds(other.resolve())]}"
            )
        # Stripping is part of the interface: debug sections the Nix build
        # strips would multiply the size of every host and guest closure.
        extra = debug_sections(readelf, executable) - debug_sections(readelf, other.resolve())
        if extra:
            failures.append(f"{executable.name}: unstripped debug sections {sorted(extra)}")
        # Any other embedded store path (a vendored crate in a panic
        # location, say) would be dropped from the import's closure.
        for embedded in sorted(embedded_store_paths(executable) - closure):
            failures.append(
                f"{executable.name}: embeds {embedded}, outside its declared runtime references"
            )
        for entry in mine.runpath:
            if entry.startswith("/nix/store/") and store_root(entry) not in closure:
                failures.append(
                    f"{executable.name}: rpath {entry} is not a declared runtime reference"
                )
    for failure in failures:
        print(failure, file=sys.stderr)
    if not failures:
        print(f"{len(executables)} executables match {reference}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
