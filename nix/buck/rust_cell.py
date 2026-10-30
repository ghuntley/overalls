"""Generate the Buck2 Rust cell's inputs from the root Cargo workspace.

Contract rust-cell-from-root-lock: see nix/buck/rust.nix.

Reads `cargo metadata` of the root workspace (run offline and locked against
the importCargoLock vendor tree) and writes:

- `Cargo.toml`: a reindeer pseudo-package whose dependencies are every
  third-party crate any member uses directly (normal, build and dev), at the
  exact version the root Cargo.lock resolved, with the union of the features
  the members request. A crate used at two versions gets a versioned alias.
- `workspace.bzl`: `CRATES`, one entry per member keyed by its repository
  path, which the `overalls_rust_crate` macro (buck/rust.bzl) turns into
  prelude rust_library, rust_binary and rust_test targets; and `LINT_FLAGS`,
  the root `[workspace.lints]` as rustc flags, in Cargo's order. A
  platform-conditional dependency carries the reindeer platforms (named in
  PLATFORMS_JSON with their `rustc --print=cfg` output) whose cfg it matches.

Usage: rust_cell.py METADATA_JSON ROOT_CARGO_TOML PLATFORMS_JSON OUT_DIR
       rust_cell.py platforms RUSTC OUT_JSON NAME=TRIPLE...
       rust_cell.py check-lock CELL_LOCK ROOT_LOCK
       rust_cell.py default-fixups CELL_METADATA_JSON FIXUPS_DIR VENDOR_DIR
"""

from __future__ import annotations

import json
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import TypedDict


class DepEntry(TypedDict):
    """One `dependencies[]` entry of a package in cargo metadata."""

    name: str
    req: str
    kind: str | None
    rename: str | None
    optional: bool
    uses_default_features: bool
    features: list[str]
    target: str | None


class TargetEntry(TypedDict):
    """One `targets[]` entry of a package in cargo metadata."""

    name: str
    kind: list[str]
    src_path: str
    edition: str
    test: bool


class PackageEntry(TypedDict):
    """One `packages[]` entry of cargo metadata."""

    id: str
    name: str
    version: str
    edition: str
    manifest_path: str
    dependencies: list[DepEntry]
    targets: list[TargetEntry]
    features: dict[str, list[str]]


class DepKindEntry(TypedDict):
    """How a resolved dependency is used: kind and platform condition."""

    kind: str | None
    target: str | None


class NodeDep(TypedDict):
    """A resolved dependency edge in `resolve.nodes[].deps`."""

    name: str
    pkg: str
    dep_kinds: list[DepKindEntry]


class NodeEntry(TypedDict):
    """A resolved package in `resolve.nodes`."""

    id: str
    deps: list[NodeDep]
    features: list[str]


@dataclass
class ThirdParty:
    """One third-party (package, version) used directly by some member."""

    package: str
    version: str
    alias: str = ""
    default_features: bool = False
    features: set[str] = field(default_factory=set)
    # Platform conditions; None means unconditional.
    targets: set[str | None] = field(default_factory=set)


def _as_list(value: object) -> list[object]:
    if not isinstance(value, list):
        raise TypeError(f"expected a list, got {type(value).__name__}")
    return value


def _load_metadata(path: Path) -> tuple[list[PackageEntry], set[str], list[NodeEntry]]:
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise TypeError("cargo metadata is not an object")
    packages: list[PackageEntry] = [p for p in _as_list(raw["packages"]) if isinstance(p, dict)]  # ty: ignore[invalid-assignment]  # cargo metadata format_version 1
    members = {m for m in _as_list(raw["workspace_members"]) if isinstance(m, str)}
    resolve = raw["resolve"]
    if not isinstance(resolve, dict):
        raise TypeError("cargo metadata has no resolve graph")
    nodes: list[NodeEntry] = [n for n in _as_list(resolve["nodes"]) if isinstance(n, dict)]  # ty: ignore[invalid-assignment]  # cargo metadata format_version 1
    return packages, members, nodes


def _lint_flags(root_manifest: Path) -> list[str]:
    """`[workspace.lints]` as rustc flags, ordered like Cargo: by priority, then name."""
    lints = tomllib.loads(root_manifest.read_text()).get("workspace", {}).get("lints", {})
    entries: list[tuple[int, str, str]] = []
    for tool, table in sorted(lints.items()):
        for lint, setting in table.items():
            level, priority = (
                (setting["level"], int(setting.get("priority", 0)))
                if isinstance(setting, dict)
                else (setting, 0)
            )
            name = lint.replace("-", "_") if tool == "rust" else f"{tool}::{lint.replace('-', '_')}"
            entries.append((priority, name, level))
    flag = {"allow": "-A", "warn": "-W", "deny": "-D", "forbid": "-F"}
    return [f"{flag[level]}{name}" for _, name, level in sorted(entries)]


Cfg = frozenset[tuple[str, str | None]]


def parse_cfg_lines(lines: list[str]) -> Cfg:
    """`rustc --print=cfg` output as (name, value) pairs."""
    pairs: set[tuple[str, str | None]] = set()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if "=" in line:
            name, value = line.split("=", 1)
            pairs.add((name, value.strip('"')))
        else:
            pairs.add((line, None))
    return frozenset(pairs)


def _tokens(expression: str) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(expression):
        char = expression[i]
        if char.isspace():
            i += 1
        elif char in "(),=":
            out.append(char)
            i += 1
        elif char == '"':
            end = expression.index('"', i + 1)
            out.append(expression[i : end + 1])
            i = end + 1
        else:
            start = i
            while (
                i < len(expression) and not expression[i].isspace() and expression[i] not in '(),="'
            ):
                i += 1
            out.append(expression[start:i])
    return out


def cfg_matches(target: str, triple: str, cfg: Cfg) -> bool:
    """Whether a Cargo `target` key (a triple or `cfg(...)`) holds for a platform."""
    if not target.startswith("cfg("):
        return target == triple
    tokens = _tokens(target)
    position = 0

    def take(expected: str | None = None) -> str:
        nonlocal position
        token = tokens[position]
        if expected is not None and token != expected:
            raise ValueError(f"bad cfg {target!r}: expected {expected!r}, got {token!r}")
        position += 1
        return token

    def predicate() -> bool:
        name = take()
        if name in ("all", "any", "not"):
            take("(")
            values: list[bool] = []
            while tokens[position] != ")":
                values.append(predicate())
                if tokens[position] == ",":
                    take(",")
            take(")")
            if name == "not":
                if len(values) != 1:
                    raise ValueError(f"bad cfg {target!r}: not() takes one predicate")
                return not values[0]
            return all(values) if name == "all" else any(values)
        if position < len(tokens) and tokens[position] == "=":
            take("=")
            return (name, take().strip('"')) in cfg
        return (name, None) in cfg

    take("cfg")
    take("(")
    result = predicate()
    take(")")
    if position != len(tokens):
        raise ValueError(f"bad cfg {target!r}: trailing tokens")
    return result


class Platform(TypedDict):
    """A reindeer platform: its rustc target triple and cfg output."""

    target: str
    cfg: list[str]


def _load_platforms(path: Path) -> dict[str, tuple[str, Cfg]]:
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise TypeError("platforms JSON is not an object")
    platforms: dict[str, tuple[str, Cfg]] = {}
    for name, entry in raw.items():
        if not isinstance(name, str) or not isinstance(entry, dict):
            raise TypeError("platforms JSON entry is not name -> object")
        target, cfg = entry.get("target"), entry.get("cfg")
        if not isinstance(target, str) or not isinstance(cfg, list):
            raise TypeError(f"platform {name} needs target and cfg")
        platforms[name] = (target, parse_cfg_lines([str(line) for line in cfg]))
    return platforms


def _manifest_uses_workspace_lints(manifest: Path) -> bool:
    lints = tomllib.loads(manifest.read_text()).get("lints", {})
    return isinstance(lints, dict) and lints.get("workspace") is True


def _relative(path: str, root: Path) -> str:
    return str(Path(path).relative_to(root))


def _extern(name: str) -> str:
    return name.replace("-", "_")


def generate(metadata: Path, root_manifest: Path, platforms_file: Path, out: Path) -> None:
    packages, members, nodes = _load_metadata(metadata)
    platforms = _load_platforms(platforms_file)
    root = root_manifest.parent.resolve()
    by_id = {p["id"]: p for p in packages}
    node_by_id = {n["id"]: n for n in nodes}
    member_paths = {
        pid: _relative(str(Path(by_id[pid]["manifest_path"]).parent), root) for pid in members
    }

    third: dict[tuple[str, str], ThirdParty] = {}
    crates: dict[str, dict[str, object]] = {}
    for pid in sorted(members, key=lambda i: member_paths[i]):
        package = by_id[pid]
        node = node_by_id[pid]
        manifest_deps = {_extern(d["rename"] or d["name"]): d for d in package["dependencies"]}
        deps: dict[str, list[dict[str, object]]] = {"normal": [], "dev": [], "build": []}
        for edge in node["deps"]:
            dep = by_id[edge["pkg"]]
            declared = manifest_deps.get(edge["name"])
            for kind_entry in edge["dep_kinds"]:
                kind = kind_entry["kind"] or "normal"
                if edge["pkg"] in members:
                    label = f"root//{member_paths[edge['pkg']].split('/')[0]}:{dep['name']}-lib"
                else:
                    entry = third.setdefault(
                        (dep["name"], dep["version"]), ThirdParty(dep["name"], dep["version"])
                    )
                    entry.targets.add(kind_entry["target"])
                    if declared is not None:
                        entry.default_features |= declared["uses_default_features"]
                        entry.features.update(declared["features"])
                    label = f"rust//:{dep['name']}@{dep['version']}"
                condition = kind_entry["target"]
                # None: every platform; else the reindeer platforms it holds on.
                on = (
                    None
                    if condition is None
                    else sorted(
                        n
                        for n, (triple, cfg) in platforms.items()
                        if cfg_matches(condition, triple, cfg)
                    )
                )
                deps[kind].append(
                    {
                        "extern": edge["name"],
                        "crate": _extern(dep["name"]),
                        "label": label,
                        "platforms": on,
                    }
                )
        lib = next(
            (
                t
                for t in package["targets"]
                if any(k in t["kind"] for k in ("lib", "rlib", "cdylib", "staticlib", "proc-macro"))
            ),
            None,
        )
        crates[member_paths[pid]] = {
            "name": package["name"],
            "version": package["version"],
            "edition": package["edition"],
            "features": sorted(node["features"]),
            "workspace_lints": _manifest_uses_workspace_lints(Path(package["manifest_path"])),
            "lib": None
            if lib is None
            else {
                "crate": _extern(lib["name"]),
                "root": _relative(lib["src_path"], root / member_paths[pid]),
                "proc_macro": "proc-macro" in lib["kind"],
                "test": lib["test"],
            },
            "bins": [
                {
                    "name": t["name"],
                    "root": _relative(t["src_path"], root / member_paths[pid]),
                    "test": t["test"],
                }
                for t in package["targets"]
                if "bin" in t["kind"]
            ],
            "tests": [
                {"name": t["name"], "root": _relative(t["src_path"], root / member_paths[pid])}
                for t in package["targets"]
                if "test" in t["kind"]
            ],
            "build_script": next(
                (
                    _relative(t["src_path"], root / member_paths[pid])
                    for t in package["targets"]
                    if "custom-build" in t["kind"]
                ),
                None,
            ),
            "deps": deps,
        }

    # Aliases: the package name when one version is used, else name-major.minor.
    versions: dict[str, list[str]] = {}
    for package, version in third:
        versions.setdefault(package, []).append(version)
    for (package, version), entry in third.items():
        entry.alias = (
            package
            if len(versions[package]) == 1
            else f"{package}-{version.replace('.', '_').replace('+', '_')}"
        )

    manifest = [
        "# Generated by nix/buck/rust_cell.py; do not edit.",
        "[package]",
        'name = "overalls-third-party"',
        'version = "0.0.0"',
        'edition = "2021"',
        "publish = false",
        "",
        "[lib]",
        'path = "lib.rs"',
        "",
    ]
    sections: dict[str | None, list[str]] = {}
    for entry in sorted(third.values(), key=lambda e: e.alias):
        features = ", ".join(json.dumps(f) for f in sorted(entry.features))
        line = f'{json.dumps(entry.alias)} = {{ package = {json.dumps(entry.package)}, version = "={entry.version}", default-features = {str(entry.default_features).lower()}, features = [{features}] }}'
        # A dependency used unconditionally anywhere is unconditional here.
        conditions = (
            [None] if None in entry.targets else sorted(t for t in entry.targets if t is not None)
        )
        for condition in conditions:
            sections.setdefault(condition, []).append(line)
    for condition in sorted(sections, key=lambda c: (c is not None, c or "")):
        manifest.append(
            "[dependencies]"
            if condition is None
            else f"[target.{json.dumps(condition)}.dependencies]"
        )
        manifest.extend(sections[condition])
        manifest.append("")
    manifest += ["[patch.crates-io]", 'fs2 = { path = "patches/fs2" }', ""]
    out.mkdir(parents=True, exist_ok=True)
    (out / "Cargo.toml").write_text("\n".join(manifest))
    (out / "lib.rs").write_text("")

    aliases = {f"rust//:{e.package}@{e.version}": f"rust//:{e.alias}" for e in third.values()}
    for crate in crates.values():
        crate_deps = crate["deps"]
        assert isinstance(crate_deps, dict)
        for edges in crate_deps.values():
            for edge in edges:
                label = edge["label"]
                assert isinstance(label, str)
                edge["label"] = aliases.get(label, label)
    bzl = [
        "# Generated by nix/buck/rust_cell.py from the root Cargo workspace; do not edit.",
        f"LINT_FLAGS = {json.dumps(_lint_flags(root_manifest))}",
        f"CRATES = {json.dumps(crates, indent=4, sort_keys=True)}",
        "",
    ]
    (out / "workspace.bzl").write_text(
        "\n".join(bzl)
        .replace(": null", ": None")
        .replace(": true", ": True")
        .replace(": false", ": False")
    )


def registry_packages(lock: Path) -> set[tuple[str, str]]:
    """The (name, version) of every registry package in a Cargo.lock."""
    packages: object = tomllib.loads(lock.read_text()).get("package", [])
    return {
        (str(p["name"]), str(p["version"]))
        for p in _as_list(packages)
        if isinstance(p, dict) and "source" in p
    }


def check_lock(cell_lock: Path, root_lock: Path) -> int:
    """Fail when the cell resolved a version the root lock did not."""
    extra = registry_packages(cell_lock) - registry_packages(root_lock)
    if extra:
        print(
            f"rust cell resolved versions outside the root Cargo.lock: {sorted(extra)}",
            file=sys.stderr,
        )
        return 1
    return 0


def default_fixups(metadata: Path, fixups: Path, vendor: Path) -> int:
    """Write each third-party crate's default fixups.

    Every crate gets all of its files as sources, since precise source
    scanning misses macro-declared modules and `include_str!` data, and runs
    its build script (buildscript_run) with Cargo's link directives. A committed fixups/<crate>/fixups.toml
    wins. When only some versions of a crate have a build script, running it
    is scoped to those versions, since reindeer refuses a build-script fixup
    for a version without one. Crates with no vendored sources (resolved but
    used on no platform) get none, since reindeer refuses a glob matching
    nothing.
    """
    packages, members, _ = _load_metadata(metadata)
    versions: dict[str, dict[str, bool]] = {}
    for package in packages:
        if (
            package["id"] in members
            or not (vendor / f"{package['name']}-{package['version']}").is_dir()
        ):
            continue
        has_build = any("custom-build" in t["kind"] for t in package["targets"])
        versions.setdefault(package["name"], {})[package["version"]] = has_build
    for name, by_version in sorted(versions.items()):
        target = fixups / name / "fixups.toml"
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        text = 'extra_srcs = ["**/*"]\n'
        # Cargo passes a build script's link directives to rustc.
        run = "buildscript.run = { rustc_link_lib = true, rustc_link_search = true }\n"
        if all(by_version.values()):
            text += run
        else:
            text += "".join(
                f"['cfg(version = \"={version}\")']\n{run}"
                for version, has_build in sorted(by_version.items())
                if has_build
            )
        target.write_text(text)
    return 0


def write_platforms(rustc: str, out: Path, specs: list[str]) -> int:
    """Record each reindeer platform's triple and `rustc --print=cfg` output."""
    platforms: dict[str, Platform] = {}
    for spec in specs:
        name, triple = spec.split("=", 1)
        printed = subprocess.run(
            [rustc, "--print=cfg", f"--target={triple}"], check=True, capture_output=True, text=True
        )
        platforms[name] = {"target": triple, "cfg": printed.stdout.splitlines()}
    out.write_text(json.dumps(platforms, indent=2, sort_keys=True))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[1] == "platforms":
        return write_platforms(argv[2], Path(argv[3]), argv[4:])
    if len(argv) == 5 and argv[1] == "default-fixups":
        return default_fixups(Path(argv[2]), Path(argv[3]), Path(argv[4]))
    if len(argv) == 4 and argv[1] == "check-lock":
        return check_lock(Path(argv[2]), Path(argv[3]))
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    generate(Path(argv[1]), Path(argv[2]), Path(argv[3]), Path(argv[4]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
