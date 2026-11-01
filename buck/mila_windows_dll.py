"""Checks of the published Mila Windows FFI DLL for buck/mila.bzl.

Usage:
  python3 buck/mila_windows_dll.py reproducible STAMP DIR_A DIR_B
  python3 buck/mila_windows_dll.py abi STAMP DLL HEADER CSHARP...

`reproducible` compares the mila_ffi.dll of two independent builds (different
Buck2 output and Cargo target directories) byte for byte and records their
SHA-256. `abi` reads the PE file itself: the `mila_*` exports MUST be exactly
the functions the hand-written C header declares, every `EntryPoint` the
production .NET interop imports MUST be exported, the DLL MUST import only
Windows system libraries (no MinGW runtime DLL the Windows runner lacks), the
COFF, export and debug directory timestamps MUST be zero, and no build path
(store, checkout or buck-out) may appear in its bytes.

Contract mila-windows-ffi-published: see buck/CONTRACTS.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

DLL_NAME = "mila_ffi.dll"

# System libraries present on every supported Windows (10 1809 and later).
# api-ms-win-* API sets (the UCRT among them) are accepted by prefix.
SYSTEM_DLLS = frozenset(
    {
        "advapi32.dll",
        "bcrypt.dll",
        "bcryptprimitives.dll",
        "crypt32.dll",
        "dbghelp.dll",
        "kernel32.dll",
        "msvcrt.dll",
        "ntdll.dll",
        "ole32.dll",
        "oleaut32.dll",
        "secur32.dll",
        "shell32.dll",
        "ucrtbase.dll",
        "user32.dll",
        "userenv.dll",
        "ws2_32.dll",
    }
)

# Byte strings that only a leaked build path contains.
BUILD_PATH_MARKERS = (b"/nix/store/", b"buck-out/", b"/home/", b"/build/", b".buck-cells/")

_EXPORT_DIRECTORY = 0
_IMPORT_DIRECTORY = 1
_DEBUG_DIRECTORY = 6


class CheckError(Exception):
    """A violated property of the DLL."""


@dataclass(frozen=True)
class Section:
    virtual_address: int
    virtual_size: int
    raw_offset: int
    raw_size: int


@dataclass(frozen=True)
class PeImage:
    coff_timestamp: int
    exports: frozenset[str]
    export_timestamp: int
    imports: tuple[str, ...]
    debug_timestamps: tuple[int, ...]


def _u16(data: bytes, offset: int) -> int:
    value: int = struct.unpack_from("<H", data, offset)[0]
    return value


def _u32(data: bytes, offset: int) -> int:
    value: int = struct.unpack_from("<I", data, offset)[0]
    return value


def _c_string(data: bytes, offset: int) -> str:
    end = data.index(b"\0", offset)
    return data[offset:end].decode("ascii")


def _offset(sections: list[Section], rva: int) -> int:
    for section in sections:
        size = max(section.virtual_size, section.raw_size)
        if section.virtual_address <= rva < section.virtual_address + size:
            return section.raw_offset + (rva - section.virtual_address)
    raise CheckError(f"RVA {rva:#x} lies in no section")


def parse_pe(data: bytes) -> PeImage:
    """Read the header fields, exports, imports and debug entries of a PE32+ DLL."""
    if data[:2] != b"MZ":
        raise CheckError("not a PE file (no MZ header)")
    pe = _u32(data, 0x3C)
    if data[pe : pe + 4] != b"PE\0\0":
        raise CheckError("not a PE file (no PE signature)")
    coff = pe + 4
    section_count = _u16(data, coff + 2)
    coff_timestamp = _u32(data, coff + 4)
    optional_size = _u16(data, coff + 16)
    optional = coff + 20
    if _u16(data, optional) != 0x20B:
        raise CheckError("not a PE32+ image")
    directory_count = _u32(data, optional + 108)
    directories: list[tuple[int, int]] = [
        (_u32(data, optional + 112 + 8 * index), _u32(data, optional + 116 + 8 * index))
        for index in range(directory_count)
    ]
    table = optional + optional_size
    sections = [
        Section(
            virtual_size=_u32(data, table + 40 * index + 8),
            virtual_address=_u32(data, table + 40 * index + 12),
            raw_size=_u32(data, table + 40 * index + 16),
            raw_offset=_u32(data, table + 40 * index + 20),
        )
        for index in range(section_count)
    ]

    exports: set[str] = set()
    export_timestamp = 0
    export_rva, export_size = directories[_EXPORT_DIRECTORY]
    if export_size:
        base = _offset(sections, export_rva)
        export_timestamp = _u32(data, base + 4)
        names = _offset(sections, _u32(data, base + 32))
        for index in range(_u32(data, base + 24)):
            exports.add(_c_string(data, _offset(sections, _u32(data, names + 4 * index))))

    imports: list[str] = []
    import_rva, import_size = directories[_IMPORT_DIRECTORY]
    if import_size:
        descriptor = _offset(sections, import_rva)
        while _u32(data, descriptor + 12):
            imports.append(_c_string(data, _offset(sections, _u32(data, descriptor + 12))))
            descriptor += 20

    debug_timestamps: list[int] = []
    if len(directories) > _DEBUG_DIRECTORY:
        debug_rva, debug_size = directories[_DEBUG_DIRECTORY]
        if debug_size:
            entry = _offset(sections, debug_rva)
            for index in range(debug_size // 28):
                debug_timestamps.append(_u32(data, entry + 28 * index + 4))

    return PeImage(
        coff_timestamp=coff_timestamp,
        exports=frozenset(exports),
        export_timestamp=export_timestamp,
        imports=tuple(imports),
        debug_timestamps=tuple(debug_timestamps),
    )


def header_functions(header: str) -> frozenset[str]:
    """The `mila_*` functions a C header declares (comments and macros removed)."""
    text = re.sub(r"/\*.*?\*/", " ", header, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", " ", text)
    text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    return frozenset(re.findall(r"\b(mila_[A-Za-z0-9_]+)\s*\(", text))


def csharp_entry_points(source: str) -> frozenset[str]:
    """The native entry points named by `[LibraryImport]`/`[DllImport]` attributes."""
    return frozenset(re.findall(r'EntryPoint\s*=\s*"(mila_[A-Za-z0-9_]+)"', source))


def _system_dll(name: str) -> bool:
    lowered = name.lower()
    return lowered in SYSTEM_DLLS or lowered.startswith("api-ms-win-")


def check_abi(dll: bytes, header: str, csharp: list[str]) -> list[str]:
    """Every violated ABI and determinism property of `dll`, as messages."""
    image = parse_pe(dll)
    problems: list[str] = []
    exported = frozenset(name for name in image.exports if name.startswith("mila_"))
    declared = header_functions(header)
    for name in sorted(declared - exported):
        problems.append(f"declared in the header but not exported: {name}")
    for name in sorted(exported - declared):
        problems.append(f"exported but not declared in the header: {name}")
    imported = frozenset().union(*(csharp_entry_points(source) for source in csharp))
    if not imported:
        problems.append("the .NET interop sources name no mila_* entry point")
    for name in sorted(imported - image.exports):
        problems.append(f"imported by the .NET interop but not exported: {name}")
    for name in image.imports:
        if not _system_dll(name):
            problems.append(f"imports a non-system DLL: {name}")
    if image.coff_timestamp:
        problems.append(f"COFF header TimeDateStamp is {image.coff_timestamp}, not 0")
    if image.export_timestamp:
        problems.append(f"export directory TimeDateStamp is {image.export_timestamp}, not 0")
    for stamp in image.debug_timestamps:
        if stamp:
            problems.append(f"debug directory TimeDateStamp is {stamp}, not 0")
    for marker in BUILD_PATH_MARKERS:
        if marker in dll:
            problems.append(f"contains a build path ({marker.decode()})")
    return problems


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reproducible(stamp: Path, first: Path, second: Path) -> int:
    if first.resolve() == second.resolve():
        print("mila_windows_dll: the two builds share one output directory", file=sys.stderr)
        return 1
    a, b = first / DLL_NAME, second / DLL_NAME
    digest_a, digest_b = _digest(a), _digest(b)
    if a.read_bytes() != b.read_bytes():
        print(
            f"mila_windows_dll: {DLL_NAME} is not reproducible: {digest_a} != {digest_b}",
            file=sys.stderr,
        )
        return 1
    stamp.write_text(
        f"reproducible {DLL_NAME}\n{digest_a}  {first}\n{digest_b}  {second}\n", encoding="utf-8"
    )
    return 0


def abi(stamp: Path, dll: Path, header: Path, csharp: list[Path]) -> int:
    data = dll.read_bytes()
    problems = check_abi(
        data,
        header.read_text(encoding="utf-8"),
        [path.read_text(encoding="utf-8") for path in csharp],
    )
    if problems:
        for problem in problems:
            print(f"mila_windows_dll: {problem}", file=sys.stderr)
        return 1
    image = parse_pe(data)
    mila = sorted(name for name in image.exports if name.startswith("mila_"))
    stamp.write_text(
        f"abi ok {hashlib.sha256(data).hexdigest()}\n"
        f"exports {len(mila)} mila_* functions; imports {', '.join(image.imports)}\n",
        encoding="utf-8",
    )
    return 0


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 4 and argv[0] == "reproducible":
            return reproducible(Path(argv[1]), Path(argv[2]), Path(argv[3]))
        if len(argv) >= 5 and argv[0] == "abi":
            return abi(Path(argv[1]), Path(argv[2]), Path(argv[3]), [Path(p) for p in argv[4:]])
    except CheckError as error:
        print(f"mila_windows_dll: {error}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
