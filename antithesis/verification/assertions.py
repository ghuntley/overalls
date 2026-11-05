"""Static authored SDK callsite and researched property roster scan."""

from __future__ import annotations

import argparse
import ast
import json
import re
from dataclasses import dataclass
from pathlib import Path

from schema import EvidenceError, Json, atomic_json, narrow_json, obj

SAFETY = frozenset({"always", "always_or_unreachable", "unreachable"})
KINDS = SAFETY | {"sometimes", "reachable"}
DISPLAY_KIND = {
    "Always": "always",
    "AlwaysOrUnreachable": "always_or_unreachable",
    "Unreachable": "unreachable",
    "Sometimes": "sometimes",
    "Reachable": "reachable",
}
HEADING = re.compile(r"^### ([a-z0-9][a-z0-9-]*) — ", re.MULTILINE)
TYPE = re.compile(
    r"\*\*Type\*\* \| (Safety|Liveness) \(`?(AlwaysOrUnreachable|Always|Unreachable|Sometimes|Reachable)`? primary\)"
)
LITERAL = re.compile(r'\*\*"([^"]+)"\*\*')


@dataclass(frozen=True)
class Callsite:
    kind: str
    message: str
    file: str
    line: int

    def wire(self) -> dict[str, Json]:
        return {"kind": self.kind, "message": self.message, "file": self.file, "line": self.line}


@dataclass(frozen=True)
class Property:
    slug: str
    primary_kind: str
    message: str

    def wire(self) -> dict[str, Json]:
        return {"slug": self.slug, "primary_kind": self.primary_kind, "message": self.message}


def python_calls(path: Path, root: Path) -> list[Callsite]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    names: dict[str, str] = {}
    modules: set[str] = set()
    package_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "antithesis.assertions":
            names.update(
                {
                    alias.asname or alias.name: alias.name
                    for alias in node.names
                    if alias.name in KINDS
                }
            )
        if isinstance(node, ast.ImportFrom) and node.module == "antithesis":
            package_modules.update(
                alias.asname or alias.name for alias in node.names if alias.name == "assertions"
            )
        if isinstance(node, ast.Import):
            modules.update(
                alias.asname or alias.name
                for alias in node.names
                if alias.name == "antithesis.assertions"
            )
    result: list[Callsite] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        kind: str | None = None
        if isinstance(func, ast.Name) and func.id in names:
            kind = names[func.id]
        elif isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
            if func.value.id in modules or func.value.id in package_modules:
                kind = func.attr
        elif (
            isinstance(func, ast.Attribute)
            and isinstance(func.value, ast.Attribute)
            and isinstance(func.value.value, ast.Name)
            and func.value.value.id == "antithesis"
            and func.value.attr == "assertions"
        ):
            kind = func.attr
        if kind not in KINDS:
            continue
        index = 0 if kind in {"reachable", "unreachable"} else 1
        if len(node.args) <= index:
            raise EvidenceError(f"nonliteral SDK assertion at {path}:{node.lineno}")
        argument = node.args[index]
        if not isinstance(argument, ast.Constant) or not isinstance(argument.value, str):
            raise EvidenceError(f"nonliteral SDK assertion at {path}:{node.lineno}")
        result.append(Callsite(kind, argument.value, str(path.relative_to(root)), node.lineno))
    return result


def elixir_calls(path: Path, root: Path) -> list[Callsite]:
    source = path.read_text(encoding="utf-8")
    prefixes = {"OverallsAntithesis.SDK", "SDK"}
    prefixes.update(
        re.findall(
            r"\balias\s+OverallsAntithesis\.SDK\s*,\s*as:\s*([A-Za-z_][A-Za-z_0-9]*)", source
        )
    )
    imported = bool(re.search(r"\bimport\s+OverallsAntithesis\.SDK\b", source))
    prefix = "|".join(re.escape(item) for item in sorted(prefixes))
    qualifier = rf"(?:(?:{prefix})\.)?" if imported else rf"(?:{prefix})\."
    starter = re.compile(
        rf"\b{qualifier}(always_or_unreachable|always|sometimes|reachable|unreachable)\s*\(",
        re.MULTILINE,
    )
    pattern = re.compile(
        rf"\b{qualifier}(always_or_unreachable|always|sometimes|reachable|unreachable)\s*\(\s*\"((?:[^\"\\]|\\.)*)\"",
        re.MULTILINE,
    )
    literal_starts = {match.start() for match in pattern.finditer(source)}
    for call in starter.finditer(source):
        line_start = source.rfind("\n", 0, call.start()) + 1
        if source[line_start : call.start()].lstrip().startswith("#"):
            continue
        if call.start() not in literal_starts:
            raise EvidenceError(
                f"nonliteral Elixir SDK assertion at {path}:{source.count(chr(10), 0, call.start()) + 1}"
            )
    result: list[Callsite] = []
    for match in pattern.finditer(source):
        line_start = source.rfind("\n", 0, match.start()) + 1
        if source[line_start : match.start()].lstrip().startswith("#"):
            continue
        if "#{" in match.group(2):
            raise EvidenceError(
                f"interpolated Elixir SDK assertion at {path}:{source.count(chr(10), 0, match.start()) + 1}"
            )
        try:
            message = json.loads(f'"{match.group(2)}"')
        except json.JSONDecodeError as exc:
            raise EvidenceError(
                f"invalid Elixir SDK message at {path}:{source.count(chr(10), 0, match.start()) + 1}"
            ) from exc
        if not isinstance(message, str):
            raise EvidenceError(f"invalid Elixir SDK message at {path}")
        result.append(
            Callsite(
                match.group(1),
                message,
                str(path.relative_to(root)),
                source.count("\n", 0, match.start()) + 1,
            )
        )
    return result


def scan_calls(root: Path, selected_paths: set[str] | None = None) -> list[Callsite]:
    if selected_paths is not None:
        paths = [root / name for name in sorted(selected_paths)]
        for path in paths:
            if not path.is_file() or path.suffix not in {".py", ".ex", ".exs"}:
                raise EvidenceError(f"selected assertion source missing: {path}")
        result: list[Callsite] = []
        for path in paths:
            result.extend(
                python_calls(path, root) if path.suffix == ".py" else elixir_calls(path, root)
            )
        return sorted(result, key=lambda call: (call.file, call.line, call.message))
    paths: list[Path] = []
    for directory in (
        "antithesis/workload",
        "antithesis/test",
        "antithesis/lilly",
        "marshall/lib",
        "lilly/lib",
        "audi/lib",
        "porsche/lib",
        "ziggy/lib",
        "galileo/lib",
        "brady/lib",
        "enrico/lib",
    ):
        base = root / directory
        if base.exists():
            paths.extend(
                path
                for path in base.rglob("*")
                if path.suffix in {".py", ".ex", ".exs"}
                and "tests" not in path.parts
                and "test" not in path.relative_to(root).parts[:-1]
            )
    # Antithesis test commands are executable; only nested unit-test fixtures are excluded.
    paths.extend((root / "antithesis/test").rglob("*.py"))
    result: list[Callsite] = []
    for path in sorted(set(paths)):
        result.extend(
            python_calls(path, root) if path.suffix == ".py" else elixir_calls(path, root)
        )
    return sorted(result, key=lambda call: (call.file, call.line, call.message))


def scan_catalog(path: Path) -> list[Property]:
    source = path.read_text(encoding="utf-8")
    headings = list(HEADING.finditer(source))
    result: list[Property] = []
    for number, heading in enumerate(headings):
        block = source[
            heading.end() : headings[number + 1].start()
            if number + 1 < len(headings)
            else len(source)
        ]
        kind = TYPE.search(block)
        literal = LITERAL.search(block)
        if kind is None or literal is None:
            raise EvidenceError(f"catalog {heading.group(1)} lacks primary type or literal")
        message = literal.group(1)
        result.append(Property(heading.group(1), DISPLAY_KIND[kind.group(2)], message))
    if not result:
        raise EvidenceError("empty research property catalog")
    return result


def roster(root: Path, catalog: Path, selected_paths: set[str] | None = None) -> dict[str, Json]:
    """@cc [owner:ghuntley,label:verification] literal-roster-boundary
    A researched primary MUST be distinct from an authored SDK callsite. Safety
    counts MUST deduplicate by literal message, while supportive reachability
    and liveness callsites MUST remain visible without increasing the safety count.
    """
    calls = scan_calls(root, selected_paths)
    properties = scan_catalog(catalog)
    by_message: dict[str, list[Callsite]] = {}
    for call in calls:
        by_message.setdefault(call.message, []).append(call)
    messages = [prop.message for prop in properties]
    duplicate_catalog = sorted({message for message in messages if messages.count(message) > 1})
    duplicate_calls = sorted(message for message, sites in by_message.items() if len(sites) > 1)
    missing = [prop.slug for prop in properties if prop.message not in by_message]
    mismatched = [
        prop.slug
        for prop in properties
        if prop.message in by_message
        and any(call.kind != prop.primary_kind for call in by_message[prop.message])
    ]
    authored_safety = sorted(
        message
        for message, sites in by_message.items()
        if any(site.kind in SAFETY for site in sites)
    )
    return obj(
        narrow_json(
            {
                "format": 1,
                "catalog_properties": [prop.wire() for prop in properties],
                "authored_callsites": [call.wire() for call in calls],
                "catalog_count": len(properties),
                "authored_callsite_count": len(calls),
                "authored_safety_messages": authored_safety,
                "authored_safety_count": len(authored_safety),
                "missing_primary_properties": missing,
                "mismatched_primary_properties": mismatched,
                "duplicate_catalog_messages": duplicate_catalog,
                "duplicate_callsite_messages": duplicate_calls,
                "supportive_messages": sorted(
                    message for message in by_message if message not in authored_safety
                ),
            }
        ),
        "roster",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    result = roster(root, args.catalog or root / "antithesis/scratchbook/property-catalog.md")
    if args.output:
        atomic_json(args.output, result)
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
