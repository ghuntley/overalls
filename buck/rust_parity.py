"""Parity of a Buck2-built Rust leaf with the Nix build it replaces.

Contract rust-leaf-parity: see buck/CONTRACTS.

Usage: rust_parity.py NIX READELF NIX_STORE STORE_PATH_FILE FLAKE_ATTR [RUNTIME_REF...]

STORE_PATH_FILE holds the imported Buck2 artifact's store path. For every
executable under its bin/, the Nix build of FLAKE_ATTR must have one of the
same name with the same ELF interpreter, NEEDED libraries and RUNPATH, and
every store path in the RUNPATH or anywhere in the bytes (a vendored crate in
a panic location, for example) must be in the closure of the import's declared
runtime references; otherwise assembly would drop it from the closure. Instruction
bytes are not compared: the builds use different drivers (Cargo and Buck2).
"""

from __future__ import annotations

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


def main(argv: list[str]) -> int:
    if len(argv) < 6:
        print(__doc__, file=sys.stderr)
        return 2
    nix, readelf, nix_store, store_path_file, attr = argv[1:6]
    refs = [store_root(ref) for ref in argv[6:]]
    buck = Path(Path(store_path_file).read_text().strip())
    reference = Path(
        run(nix, "build", "--no-link", "--print-out-paths", f".#{attr}").strip().splitlines()[-1]
    )
    closure = set(run(nix_store, "-qR", *refs).split()) if refs else set()
    failures: list[str] = []
    executables = sorted(p for p in (buck / "bin").iterdir() if p.is_file())
    if not executables:
        failures.append(f"{buck}/bin has no executables")
    for executable in executables:
        other = reference / "bin" / executable.name
        if not other.exists():
            failures.append(f"{executable.name}: absent from the Nix build {reference}")
            continue
        mine, theirs = linkage(readelf, executable), linkage(readelf, other.resolve())
        if mine != theirs:
            failures.append(f"{executable.name}: Buck2 {mine} != Nix {theirs}")
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
