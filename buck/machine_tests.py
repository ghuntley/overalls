"""NixOS machine tests as Buck2 targets (ADR-0270).

Each machine test is a nixos_machine_test stanza in its suite's BUCK file,
whose `test` attribute is the Nix expression that instantiates it in the test
scope (nix/verification/tests/scope.nix). That expression is the source; this
tool derives every other attribute from it and the suite's files.

Subcommands:
  generate           rewrite nix/verification/tests/machines/**/BUCK, keeping each
                     stanza's name and `test` and deriving the rest
  check              fail when the derived attributes are stale
  refresh-scenarios  re-derive fleet/scenarios.json from each fleet variant's
                     composed script (its `[meta]`, evaluation only)
  run                the test command of one nixos_machine_test target
  debug NAME [ATTR]  build an attribute of one machine test (its interactive
                     driver, a typed browser artifact) from the checkout with
                     plain Nix: debugging only, without the Buck2 artifacts

Contract nixos-machine-test-labels and machine-test-targets-generated: see buck/CONTRACTS.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
import textwrap
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = Path("nix/verification/tests")
# The test scope; its featureFleets are the fleet variants a check inspects.
SCOPE = TESTS / "scope.nix"
MACHINES = TESTS / "machines"
FLEET = MACHINES / "fleet"
SCENARIOS_JSON = FLEET / "scenarios.json"
SUITES_BZL = MACHINES / "suites.bzl"
EVALUATION = "evaluation"
HEADER = (
    "# Maintained by buck/machine_tests.py: edit only a stanza's `name` and `test` (or add\n"
    "# one with just those), then run `python3 buck/machine_tests.py generate`.\n"
)

# Checks that run NixOS machine tests without importing ./machines (they need
# KVM through vmTools), and ./machines imports that only build a package.
# Both agree with the features `run` reads from the target's `[meta]`.
KVM_EVALUATION_CHECKS = frozenset({"firecracker-patch-tests", "foreign-linux-pam-helper"})

# The Inception machine tests are known broken (AGENTS.md). The zfs-guest
# Inception subtest is not a reason to skip zfs-guest: it stays required.
KNOWN_INCEPTION_FAILURES = frozenset({"inception", "inception-checkout", "inception-ssh-host-ca"})

# Contract machine-test-module-inputs: see buck/CONTRACTS. NIX_INPUTS holds
# //nix:base, which omits the NixOS modules. A test declares one //nix:module-*
# group per module it reaches (generated into MODULES_BZL, each holding the
# files that module imports), or //nix:system_modules when it reaches the
# whole catalog (modules.default, `service`, featureFleet or host fixtures).
# Restrict-eval over the declared copy turns a missed file into an error (M11).
SYSTEM = Path("nix/domains/system")
SYSTEM_CATALOG = SYSTEM / "catalog.nix"
MODULES_BZL = MACHINES / "modules.bzl"
SYSTEM_MODULES = "//nix:system_modules"
# The group of the catalog file itself, which modules.select reads.
CATALOG_GROUP = "//nix:module-catalog"
# Module attributes of nix/assemble/modules.nix that catalog entries pass,
# by the files they import. A plain path does not close over the packages.
MODULE_ATTRS: Mapping[str, tuple[str, ...]] = {
    "modules.platform.sysctl": ("sysctl.nix",),
    "modules.security.access": ("access.nix",),
    "modules.network.fleet-firewall": ("fleet-firewall.nix",),
    "modules.fleetBuilds": ("fleet-builds.nix",),
    "modules.security.secrets": ("secrets",),
    "modules.services.enrico": ("enrico.nix",),
}
PLAIN_MODULES = frozenset(
    {
        "modules.platform.sysctl",
        "modules.security.access",
        "modules.network.fleet-firewall",
        "modules.fleetBuilds",
    }
)
# `modules.select [ "a" "b" ]` or `serviceOf [ ... ]` (the service inputs with
# only the named catalog modules) in a catalog entry.
MODULE_SELECT = re.compile(r"\b(?:modules\.select|serviceOf)\s*\[([^\]]*)\]")
# A whole-catalog reference in a catalog entry's parameters (not a suite
# path such as ./machines/ziggy-service).
WHOLE_CATALOG = re.compile(r"(?<![-/\w])(service|fixtures|modules\.default)(?![-\w])")
# A path into the module tree, or a test helper outside the suites, named by
# a suite's Nix file (relative or from the repository root).
SYSTEM_PATH = re.compile(r"domains/system(/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)?")
HELPER_PATH = re.compile(r"(?:\.\./)+(support|evaluation|fixtures)/([A-Za-z0-9_./-]+\.nix)")
# Any relative path in a module file.
LOCAL_PATH = re.compile(r"(?<![A-Za-z0-9_])(\.\.?/[A-Za-z0-9_./-]*[A-Za-z0-9_-])")
# Owned groups a suite reads beyond NIX_INPUTS and PACKAGE_INPUTS.
# The offline Buck2 repository that support/update-fixture.nix copies (ADR-0271).
UPDATE_FIXTURE_INPUTS = (
    "//:buck_project",
    "//buck:srcs",
    "//buck:buck_file",
    "//tools:srcs",
    "toolchains//:srcs",
    "toolchains//:buck_file",
)
SUITE_INPUTS: Mapping[str, tuple[str, ...]] = {
    # The real Buck2 execution platform rule (ADR-0272).
    "auto-update": UPDATE_FIXTURE_INPUTS,
    "credential-rotation": UPDATE_FIXTURE_INPUTS,
    "fleet": UPDATE_FIXTURE_INPUTS,
    "host-enrollment": UPDATE_FIXTURE_INPUTS,
}
PACKAGE_INPUT = re.compile(r"\b(service|serviceOf|storage|packages)\b")
MODULE_REF = re.compile(r"\bmodules\.[A-Za-z0-9_.-]+")
NESTED_KVM = re.compile(r"^\s*requiredFeatures\.nested-kvm\s*=\s*true\s*;", re.M)
MACHINE_IMPORT = re.compile(r"import \./machines/([a-z0-9-]+)(/[a-z0-9.-]+\.nix)?")
RELATIVE_REF = re.compile(r"((?:\.\./)+)([A-Za-z0-9_.-]+)")


@dataclass(frozen=True)
class Entry:
    """One NixOS machine test: a nixos_machine_test stanza."""

    name: str
    suite: str
    # Its Nix expression in the test scope, in canonical layout.
    test: str
    packages: bool
    nested_kvm: bool
    known_failure: bool
    # The module roots its parameters reach (under SYSTEM), or None for all.
    modules: frozenset[str] | None


@dataclass
class Suite:
    """One directory under nix/verification/tests/machines."""

    name: str
    siblings: set[str] = field(default_factory=set)
    entries: list[Entry] = field(default_factory=list)


# --- Nix catalog scanning ---------------------------------------------------


def _skip_string(text: str, i: int) -> int:
    """Return the index just past the Nix string literal starting at i."""
    if text.startswith("''", i):
        j = i + 2
        while j < len(text):
            if text.startswith("'''", j) or text.startswith("''$", j) or text.startswith("''\\", j):
                j += 3
            elif text.startswith("''", j):
                return j + 2
            else:
                j += 1
        raise ValueError("unterminated indented string")
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 2
        elif text[j] == '"':
            return j + 1
        else:
            j += 1
    raise ValueError("unterminated string")


def split_statements(body: str) -> list[str]:
    """Split an attribute-set body into its top-level `;`-terminated statements."""
    statements: list[str] = []
    depth = 0
    start = 0
    i = 0
    while i < len(body):
        c = body[i]
        if c == "#":
            end = body.find("\n", i)
            i = len(body) if end < 0 else end
            continue
        if c == '"' or body.startswith("''", i):
            i = _skip_string(body, i)
            continue
        if c in "({[":
            depth += 1
        elif c in ")}]":
            depth -= 1
        elif c == ";" and depth == 0:
            statements.append(body[start:i].strip())
            start = i + 1
        i += 1
    tail = body[start:].strip()
    if tail:
        statements.append(tail)
    return [s for s in statements if s and not s.startswith("#")]


def _strip_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.strip().startswith("#"))


def _block(text: str, opener: str) -> str:
    """Return the body of the brace block whose `{` ends `opener`."""
    start = text.index(opener) + len(opener)
    depth = 1
    i = start
    while depth:
        c = text[i]
        if c == '"' or text.startswith("''", i):
            i = _skip_string(text, i)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    return text[start : i - 1]


def uses_packages(expr: str) -> bool:
    if PACKAGE_INPUT.search(expr):
        return True
    return any(ref not in PLAIN_MODULES for ref in MODULE_REF.findall(expr))


def catalog_roots(root: Path) -> dict[str, str]:
    """Each system catalog module's name and the path it imports (under SYSTEM)."""
    text = (root / SYSTEM_CATALOG).read_text()
    found = re.findall(
        r'\{ name = "([a-z0-9-]+)"; module = (?:import )?\./([A-Za-z0-9_./-]+)', text
    )
    roots = {name: path.removesuffix("/") for name, path in found}
    if len(roots) != len(found) or not roots:
        raise ValueError(f"{SYSTEM_CATALOG}: unreadable or duplicate module names")
    return roots


def module_roots(expr: str, fleet: bool, catalog: Mapping[str, str]) -> frozenset[str] | None:
    """The module roots a catalog entry's parameters reach, or None for all.

    `service` and featureFleet pass modules.default, and host fixtures are
    built from the whole catalog. `serviceOf` and modules.select name their
    catalog modules; a module attribute imports the files MODULE_ATTRS lists.
    """
    if fleet or WHOLE_CATALOG.search(expr):
        return None
    roots: set[str] = set()
    for names in MODULE_SELECT.findall(expr):
        for name in re.findall(r'"([^"]+)"', names):
            if name not in catalog:
                raise ValueError(f"unknown system catalog module {name!r}")
            roots.add(catalog[name])
        roots.add(SYSTEM_CATALOG.name)
    for ref in MODULE_REF.findall(MODULE_SELECT.sub("", expr)):
        if ref not in MODULE_ATTRS:
            return None
        roots.update(MODULE_ATTRS[ref])
    return frozenset(roots)


def canonical_test(expr: str) -> str:
    """A `test` expression's canonical layout: the first line unindented and the
    rest dedented, so generate is idempotent over any indentation."""
    lines = expr.strip().splitlines()
    if not lines:
        raise ValueError("empty test expression")
    rest = textwrap.dedent("\n".join(lines[1:]))
    return "\n".join([lines[0].strip(), *([rest] if rest else [])]).rstrip()


def feature_fleets(root: Path) -> dict[str, str]:
    """scope.nix's featureFleets: the variants a Nix check inspects by name."""
    text = (root / SCOPE).read_text()
    return {
        name: expr
        for name, _, expr in (
            s.partition(" = ")
            for s in split_statements(_strip_comments(_block(text, "featureFleets = {")))
        )
    }


def stanzas(path: Path) -> list[tuple[str, str]]:
    """The (name, test) of each nixos_machine_test stanza in a BUCK file."""
    found: list[tuple[str, str]] = []
    for statement in ast.parse(path.read_text(), str(path)).body:
        node = statement.value if isinstance(statement, ast.Expr) else None
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "nixos_machine_test"
        ):
            continue
        values = {k.arg: k.value for k in node.keywords}
        name, test = values.get("name"), values.get("test")
        if not (isinstance(name, ast.Constant) and isinstance(name.value, str)):
            raise ValueError(f"{path}: a nixos_machine_test has no literal name")
        if not (isinstance(test, ast.Constant) and isinstance(test.value, str)):
            raise ValueError(f"{path}: {name.value} has no literal `test` expression")
        found.append((name.value, canonical_test(test.value)))
    return found


def entry(
    root: Path, name: str, expr: str, catalog: Mapping[str, str], fleets: Mapping[str, str]
) -> Entry:
    """Derive one machine test's attributes from its `test` expression."""
    resolved = (
        fleets[expr.removeprefix("featureFleets.")] if expr.startswith("featureFleets.") else expr
    )
    if resolved.startswith("featureFleet "):
        suite, module = "fleet", "default.nix"
    elif name in KVM_EVALUATION_CHECKS:
        # The evaluation file and the helpers it imports name their modules.
        files = [
            root / TESTS / f for f in re.findall(r"\./(evaluation/[A-Za-z0-9_.-]+\.nix)", resolved)
        ]
        named = named_roots(root, files) if files else None
        reached = module_roots(resolved, False, catalog)
        modules = None if named is None or reached is None else named | reached
        return Entry(name, EVALUATION, expr, uses_packages(resolved), False, False, modules)
    elif match := MACHINE_IMPORT.search(resolved):
        suite, module = match.group(1), (match.group(2) or "/default.nix").lstrip("/")
    else:
        raise ValueError(
            f"{name}: `test` neither imports ./machines/<suite> nor is a fleet variant"
        )
    source = (root / MACHINES / suite / module).read_text()
    fleet = resolved.startswith("featureFleet ")
    return Entry(
        name=name,
        suite=suite,
        test=expr,
        # featureFleet always passes the service inputs.
        packages=fleet or uses_packages(resolved),
        nested_kvm=bool(NESTED_KVM.search(source)),
        known_failure=name in KNOWN_INCEPTION_FAILURES,
        modules=module_roots(resolved, fleet, catalog),
    )


def parse_tests(root: Path) -> list[Entry]:
    """Every machine test, from the nixos_machine_test stanzas under MACHINES."""
    catalog = catalog_roots(root)
    fleets = feature_fleets(root)
    entries: list[Entry] = []
    for path in [root / MACHINES / "BUCK", *sorted((root / MACHINES).glob("*/BUCK"))]:
        if not path.exists():
            continue
        for name, expr in stanzas(path):
            found = entry(root, name, expr, catalog, fleets)
            where = path.parent.name if path.parent != root / MACHINES else EVALUATION
            if found.suite != where:
                raise ValueError(
                    f"{name}: declared in {path} but its test is in suite {found.suite}"
                )
            entries.append(found)
    names = [e.name for e in entries]
    if len(names) != len(set(names)):
        raise ValueError("duplicate machine test names")
    return entries


def sibling_refs(root: Path, suite: str, suites: Iterable[str]) -> set[str]:
    """Other machine suites whose files this suite's Nix files reference."""
    known = set(suites)
    machines = (root / MACHINES).resolve()
    refs: set[str] = set()
    for path in sorted((root / MACHINES / suite).rglob("*.nix")):
        for ups, name in RELATIVE_REF.findall(path.read_text()):
            target = Path(os.path.normpath(path.parent.resolve() / ups / name))
            try:
                parts = target.relative_to(machines).parts
            except ValueError:
                continue
            if parts and parts[0] != suite and parts[0] in known:
                refs.add(parts[0])
    return refs


def suite_roots(root: Path, suite: str) -> frozenset[str] | None:
    """The module paths a suite's own Nix files, or the test helpers they
    import, name directly; None when one is the whole catalog or unresolved."""
    return named_roots(root, sorted((root / MACHINES / suite).rglob("*.nix")))


def named_roots(root: Path, files: Iterable[Path]) -> frozenset[str] | None:
    """The module paths these Nix files, or the test helpers they import,
    name directly; None when one is the whole catalog or unresolved."""
    roots: set[str] = set()
    seen: set[Path] = set()
    todo = list(files)
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        text = path.read_text()
        for match in SYSTEM_PATH.finditer(text):
            rel = (match.group(1) or "").strip("/")
            if not rel or rel == SYSTEM_CATALOG.name or not (root / SYSTEM / rel).exists():
                return None
            roots.add(rel)
        for kind, rel in HELPER_PATH.findall(text):
            helper = root / TESTS / kind / rel
            if helper.is_file():
                todo.append(helper)
    return frozenset(roots)


def module_files(root: Path, start: str) -> list[str]:
    """The files under SYSTEM that a module path reads, transitively.

    A directory reference reads the whole directory. Interpolated paths are
    not followed; restrict-eval fails on any file this misses.
    """
    base = (root / SYSTEM).resolve()
    if start == SYSTEM_CATALOG.name:
        # modules.select imports only the named modules' paths.
        return [start]
    seen: set[Path] = set()
    found: set[Path] = set()
    todo = [base / start]
    while todo:
        path = todo.pop()
        if path in seen or not path.exists():
            continue
        seen.add(path)
        if path.is_dir():
            todo.extend(p for p in path.rglob("*") if p.is_file())
            continue
        found.add(path)
        if path.suffix != ".nix":
            continue
        for ref in LOCAL_PATH.findall(path.read_text()):
            target = Path(os.path.normpath(path.parent / ref))
            if target.is_relative_to(base) and target != base / SYSTEM_CATALOG.name:
                todo.append(target)
    return sorted(p.relative_to(base).as_posix() for p in found)


def group_name(path: str) -> str:
    """The //nix:module-* group name of a module path under SYSTEM."""
    return re.sub(r"(/default)?\.nix$", "", path).replace("/", "-")


def module_groups(roots: frozenset[str] | None) -> list[str]:
    if roots is None:
        return [SYSTEM_MODULES]
    return sorted(f"//nix:module-{group_name(r)}" for r in roots)


def closure(start: set[str], graph: Mapping[str, set[str]]) -> set[str]:
    seen: set[str] = set()
    todo = list(start)
    while todo:
        node = todo.pop()
        if node not in seen:
            seen.add(node)
            todo.extend(graph.get(node, set()))
    return seen


# --- Rendering --------------------------------------------------------------


def _string_list(values: Sequence[str], indent: str) -> str:
    if not values:
        return "[]"
    inner = "".join(f'{indent}    "{v}",\n' for v in values)
    return f"[\n{inner}{indent}]"


def _test(expr: str) -> str:
    """A `test` expression as a Starlark string: single-quoted on one line,
    otherwise a triple-quoted block (Nix code has no single quotes here)."""
    if "'" in expr or "\\" in expr:
        raise ValueError(f"test expression contains a quote or backslash: {expr[:60]}")
    if "\n" not in expr:
        return f"'{expr}'"
    body = "\n".join(f"        {line}" if line else "" for line in expr.splitlines())
    return f"'''\n{body}\n    '''"


def render_target(entry: Entry, inputs: str, scenarios: Sequence[str]) -> str:
    labels = ["known_inception_failure"] if entry.known_failure else []
    lines = [
        "nixos_machine_test(",
        f'    name = "{entry.name}",',
        f'    check = "{entry.name}",',
        f'    suite = "{entry.suite}",',
        f"    nested_kvm = {entry.nested_kvm},",
        f"    packages = {entry.packages},",
        f"    labels = {_string_list(labels, '    ')},",
        f"    test = {_test(entry.test)},",
        f"    inputs = {inputs},",
    ]
    if scenarios:
        lines.append(f"    scenarios = {_string_list(scenarios, '    ')},")
    lines.append(")\n")
    return "\n".join(lines)


def _inputs(
    entry: Entry, own: Sequence[str], siblings: Iterable[str], reached: frozenset[str] | None
) -> str:
    groups = "NIX_INPUTS" + (" + PACKAGE_INPUTS" if entry.packages else "")
    roots = None if reached is None or entry.modules is None else reached | entry.modules
    modules = module_groups(roots)
    extra = (
        list(own)
        + modules
        + [f"//{MACHINES}/{s}:srcs" for s in sorted(siblings)]
        + list(SUITE_INPUTS.get(entry.suite, ()))
    )
    return f"{groups} + {_string_list(extra, '    ')}" if extra else groups


def render(
    root: Path, scenarios: Mapping[str, list[str]], entries: Sequence[Entry] | None = None
) -> dict[Path, str]:
    entries = parse_tests(root) if entries is None else entries
    suite_names = sorted(p.name for p in (root / MACHINES).iterdir() if p.is_dir())
    graph = {s: sibling_refs(root, s, suite_names) for s in suite_names}
    files: dict[Path, str] = {}
    by_suite: dict[str, list[Entry]] = {s: [] for s in suite_names}
    evaluation: list[Entry] = []
    for entry in entries:
        (evaluation if entry.suite == EVALUATION else by_suite[entry.suite]).append(entry)
    load = (
        'load("@root//buck:inputs.bzl", "NIX_INPUTS", "PACKAGE_INPUTS")\n'
        'load("@root//buck:nixos.bzl", "nixos_machine_test")\n'
    )
    for suite in suite_names:
        body = [HEADER, 'load("@root//buck:nix.bzl", "nix_owned")\n']
        if by_suite[suite]:
            body.append(load)
        body.append("\nnix_owned()\n")
        siblings = closure(graph[suite], graph) - {suite}
        # Module paths the suite or a suite it references names itself.
        reached: frozenset[str] | None = frozenset()
        for s in sorted(siblings | {suite}):
            named = suite_roots(root, s)
            reached = None if named is None or reached is None else reached | named
        if suite == "fleet" and by_suite[suite]:
            body.append(
                "\n# Each variant declares the shared files and only its own scenarios.\n"
                '_COMMON = glob(["**"], exclude = ["BUCK", "scenarios/**"])\n'
            )
        for entry in by_suite[suite]:
            body.append("\n")
            if suite == "fleet":
                variant = scenarios.get(entry.name, [])
                body.append(
                    f'filegroup(\n    name = "{entry.name}.files",\n'
                    f"    srcs = _COMMON + {_string_list(variant, '    ')},\n)\n\n"
                )
                own = [f":{entry.name}.files"]
                body.append(render_target(entry, _inputs(entry, own, siblings, reached), variant))
            else:
                body.append(render_target(entry, _inputs(entry, [":srcs"], siblings, reached), []))
        files[MACHINES / suite / "BUCK"] = "".join(body)
    aggregate = [HEADER, 'load("@root//buck:nix.bzl", "nix_owned", "owned_set")\n']
    if evaluation:
        aggregate.append(load)
    suites = _string_list([f"//{MACHINES}/{s}:srcs" for s in suite_names], "    ")
    aggregate.append(
        "\nnix_owned()\n"
        "\n# Every suite's files, for the flake-wide bootstrap targets.\n"
        f'owned_set(\n    name = "suites",\n    deps = {suites},\n'
        '    visibility = ["PUBLIC"],\n)\n'
    )
    for entry in evaluation:
        aggregate.append(
            "\n# A KVM evaluation check (a machine test by its features) outside ./machines.\n"
        )
        aggregate.append(render_target(entry, _inputs(entry, [], [], frozenset()), []))
    files[MACHINES / "BUCK"] = "".join(aggregate)
    names = sorted(e.name for e in entries)
    packages = [f"//{MACHINES}"] + [f"//{MACHINES}/{s}" for s in suite_names]
    files[SUITES_BZL] = (
        HEADER
        + f"MACHINE_TESTS = {_string_list(names, '')}\n"
        + f"MACHINE_PACKAGES = {_string_list(packages, '')}\n"
    )
    files[MODULES_BZL] = render_modules(root, entries, suite_names)
    return files


def render_modules(root: Path, entries: Sequence[Entry], suite_names: Sequence[str]) -> str:
    """The //nix:module-* groups: every catalog module and module attribute,
    and every other module path a suite names, each with the files it reads."""
    roots = {SYSTEM_CATALOG.name, *catalog_roots(root).values()}
    roots.update(r for attr in MODULE_ATTRS.values() for r in attr)
    for entry in entries:
        roots.update(entry.modules or ())
    for suite in suite_names:
        roots.update(suite_roots(root, suite) or ())
    # A directory and its default.nix share one group, holding both closures.
    groups: dict[str, set[str]] = {}
    for path in sorted(roots):
        groups.setdefault(group_name(path), set()).update(module_files(root, path))
    body = "".join(
        f'    "{name}": {_string_list(sorted(files), "    ")},\n'
        for name, files in sorted(groups.items())
    )
    return (
        HEADER
        + "# Files under nix/domains/system that each module path reads; nix/BUCK\n"
        + "# defines one //nix:module-<name> group per entry (ADR-0270).\n"
        + f"SYSTEM_MODULE_GROUPS = {{\n{body}}}\n"
    )


def load_scenarios(root: Path) -> dict[str, list[str]]:
    path = root / SCENARIOS_JSON
    if not path.exists():
        return {}
    data: object = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{SCENARIOS_JSON}: expected an object")
    result: dict[str, list[str]] = {}
    for key, value in data.items():
        if not isinstance(key, str) or not isinstance(value, list):
            raise ValueError(f"{SCENARIOS_JSON}: {key!r} must map to a list")
        result[key] = [str(v) for v in value]
    return result


# --- Scenario detection -----------------------------------------------------


def _signature(lines: Iterable[str]) -> set[str]:
    return {s for s in (line.strip() for line in lines) if len(s) >= 25}


def included_scenarios(script: str, root: Path) -> list[str]:
    """Scenario files whose distinctive lines appear in a composed test script."""
    fleet = root / FLEET
    files = {
        p.relative_to(fleet).as_posix(): p.read_text()
        for p in sorted((fleet / "scenarios").glob("*.py"))
    }
    shared = set()
    for p in fleet.glob("*"):
        if p.is_file():
            shared |= _signature(p.read_text().splitlines())
    lines = _signature(script.splitlines())
    used: list[str] = []
    for name, text in files.items():
        others = set().union(*(_signature(t.splitlines()) for n, t in files.items() if n != name))
        distinct = _signature(text.splitlines()) - others - shared
        if not distinct:
            if text.strip() and text.strip() in script:
                used.append(name)
            continue
        hits = len(distinct & lines)
        if hits >= min(3, len(distinct)):
            used.append(name)
    return used


def fleet_targets(entries: Iterable[Entry]) -> dict[str, str]:
    """Each fleet variant's `[meta]` target, which holds its composed script."""
    return {
        e.name: f"root//{MACHINES}/fleet:{e.name}.assembly[meta]"
        for e in entries
        if e.suite == "fleet"
    }


def read_meta(path: Path) -> dict[str, object]:
    value: object = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{path}: machine test meta is not an object")
    return {str(k): v for k, v in value.items()}


def refresh_scenarios(root: Path, buck2: str) -> None:
    """Build every fleet variant's `[meta]` (evaluation only, over the same
    declared tree and Buck2 artifacts as its run) and record the scenario
    files its composed script includes."""
    targets = fleet_targets(parse_tests(root))
    proc = subprocess.run(
        [buck2, "build", "--show-full-output", *targets.values()],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"building the fleet [meta] targets failed:\n{proc.stderr[-4000:]}")
    outputs = dict(line.split(" ", 1) for line in proc.stdout.splitlines() if " " in line)
    mapping: dict[str, list[str]] = {}
    for name, target in targets.items():
        label = next((k for k in outputs if k.endswith(target.removeprefix("root//"))), None)
        if label is None:
            raise RuntimeError(f"{target}: no output reported")
        script = read_meta(Path(outputs[label].strip())).get("testScript")
        if not isinstance(script, str):
            raise TypeError(f"{target}: meta has no testScript")
        mapping[name] = included_scenarios(script, root)
    (root / SCENARIOS_JSON).write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")


DEBUG_TEST = TESTS / ".buck-test.nix"


def debug(root: Path, nix: str, name: str, attr: str) -> int:
    """Build `machineTest.<attr>` of one machine test over the checkout.

    The expression is written where nix_assemble writes it, so its relative
    paths resolve the same way, and removed afterwards. Without Buck2
    artifacts a test that reads a Mix release fails to evaluate; use its
    `[driver]` target.
    """
    tests = {e.name: e for e in parse_tests(root)}
    if name not in tests:
        print(f"{name}: no such machine test", file=sys.stderr)
        return 1
    path = root / DEBUG_TEST
    path.write_text(f"tests: with tests;\n{tests[name].test}\n")
    expression = (
        "((builtins.getFlake (toString ./.)).lib.assemble "
        f"{{ machineTest = {path}; }}).machineTest.{attr}"
    )
    try:
        return subprocess.run(
            [nix, "build", "--impure", "-L", "--expr", expression], cwd=root, check=False
        ).returncode
    finally:
        path.unlink(missing_ok=True)


# --- Subcommands ------------------------------------------------------------


def check(root: Path) -> list[str]:
    problems: list[str] = []
    scenarios = load_scenarios(root)
    expected = render(root, scenarios)
    for path, text in sorted(expected.items()):
        current = (root / path).read_text() if (root / path).exists() else None
        if current != text:
            problems.append(f"{path} is stale; run python3 buck/machine_tests.py generate")
    fleet = {e.name for e in parse_tests(root) if e.suite == "fleet"}
    if set(scenarios) != fleet:
        problems.append(
            f"{SCENARIOS_JSON} variants differ from the fleet suite's variants "
            f"(missing {sorted(fleet - set(scenarios))}, extra {sorted(set(scenarios) - fleet)}); "
            "run python3 buck/machine_tests.py refresh-scenarios"
        )
    used = {s for v in scenarios.values() for s in v}
    for p in sorted((root / FLEET / "scenarios").glob("*.py")):
        name = p.relative_to(root / FLEET).as_posix()
        if name not in used:
            problems.append(f"{FLEET / name} is used by no fleet variant in {SCENARIOS_JSON}")
    return problems


# Checks that run NixOS machine tests without being one themselves.
MACHINE_AGGREGATES = frozenset({"host-conversion"})


@dataclass(frozen=True)
class Features:
    """What a check's system features say about how it runs."""

    machine: bool
    nested_kvm: bool


def features(name: str, meta: Mapping[str, object]) -> Features:
    """A machine test's features from its `[meta]` (lib.assemble's
    machineTestMeta), read without forcing its derivation.

    Contract machine-test-required-features: see buck/CONTRACTS. The NixOS
    tester exposes requirements through `config.requiredFeatures` rather than
    its lazy wrapper, so neither a driver nor a guest image is built.
    """
    machine, nested = meta.get("machine"), meta.get("nestedKvm")
    if not isinstance(machine, bool) or not isinstance(nested, bool):
        raise TypeError(f"{name}: features are not booleans: {meta!r}")
    return Features(machine=machine or name in MACHINE_AGGREGATES, nested_kvm=nested)


def run(
    nix: str,
    name: str,
    nested_kvm: bool,
    suite: str,
    scenarios: Sequence[str],
    store_path: Path,
    meta_path: Path,
) -> int:
    """Check one built machine test. Buck2 has already built its assembly
    (the NixOS test run itself) and its `[meta]` before this command starts."""
    root = Path.cwd()
    meta = read_meta(meta_path)
    found = features(name, meta)
    if not found.machine:
        print(
            f"{name}: not a machine test by its features; regenerate the BUCK files",
            file=sys.stderr,
        )
        return 1
    if found.nested_kvm is not nested_kvm:
        print(
            f"{name}: nested_kvm label is {nested_kvm} but requiredFeatures says "
            f"{found.nested_kvm}; regenerate the BUCK files",
            file=sys.stderr,
        )
        return 1
    if suite == "fleet":
        script = meta.get("testScript")
        if not isinstance(script, str):
            print(f"{name}: its [meta] has no composed testScript", file=sys.stderr)
            return 1
        actual = included_scenarios(script, root)
        if sorted(actual) != sorted(scenarios):
            print(
                f"{name}: declared scenarios {sorted(scenarios)} differ from the composed "
                f"script's {sorted(actual)}; run python3 buck/machine_tests.py refresh-scenarios",
                file=sys.stderr,
            )
            return 1
    result = store_path.read_text().strip()
    valid = subprocess.run([nix, "path-info", result], capture_output=True, check=False)
    if not result.startswith("/nix/store/") or valid.returncode != 0:
        print(f"{name}: assembly produced no valid store path ({result!r})", file=sys.stderr)
        return 1
    print(f"{name}: passed as {result}")
    return 0


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="machine_tests.py")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("generate")
    sub.add_parser("check")
    refresh = sub.add_parser("refresh-scenarios")
    refresh.add_argument("--buck2", default=str(ROOT / "tools" / "buck2"))
    debugger = sub.add_parser("debug")
    debugger.add_argument("name")
    debugger.add_argument("attr", nargs="?", default="driverInteractive")
    debugger.add_argument("--nix", default="nix")
    runner = sub.add_parser("run")
    runner.add_argument("--nix", required=True)
    runner.add_argument("--check", required=True)
    runner.add_argument("--nested-kvm", choices=["true", "false"], required=True)
    runner.add_argument("--suite", required=True)
    runner.add_argument("--scenario", action="append", default=[])
    runner.add_argument("--store-path", type=Path, required=True)
    runner.add_argument("--meta", type=Path, required=True)
    args = parser.parse_args(argv)
    command: str = args.command
    if command == "generate":
        for path, text in render(ROOT, load_scenarios(ROOT)).items():
            (ROOT / path).write_text(text)
        return 0
    if command == "check":
        problems = check(ROOT)
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1 if problems else 0
    if command == "debug":
        return debug(ROOT, str(args.nix), str(args.name), str(args.attr))
    if command == "refresh-scenarios":
        refresh_scenarios(ROOT, str(args.buck2))
        return 0
    return run(
        str(args.nix),
        str(args.check),
        args.nested_kvm == "true",
        str(args.suite),
        [str(s) for s in args.scenario],
        Path(args.store_path),
        Path(args.meta),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
