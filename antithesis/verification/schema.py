"""Validated JSON and atomic, locked state for local Antithesis evidence."""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
from collections.abc import Callable, Generator
from contextlib import contextmanager
from pathlib import Path

type Json = bool | int | float | str | list[Json] | dict[str, Json] | None


class EvidenceError(ValueError):
    """External evidence is absent or violates its declared schema."""


def narrow_json(value: object) -> Json:
    """Reject arbitrary decoded objects and non-finite numbers at the boundary."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        if not (-float("inf") < value < float("inf")):
            raise EvidenceError("non-finite JSON number")
        return value
    if isinstance(value, list):
        return [narrow_json(item) for item in value]
    if isinstance(value, dict):
        result: dict[str, Json] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise EvidenceError("non-string JSON key")
            result[key] = narrow_json(item)
        return result
    raise EvidenceError(f"unsupported JSON value: {type(value).__name__}")


def read_json(path: Path) -> Json:
    try:
        return narrow_json(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot read JSON evidence {path}: {exc}") from exc


def obj(value: Json, name: str) -> dict[str, Json]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{name} must be an object")
    return value


def arr(value: Json, name: str) -> list[Json]:
    if not isinstance(value, list):
        raise EvidenceError(f"{name} must be an array")
    return value


def string(value: Json, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{name} must be a nonempty string")
    return value


def integer(value: Json, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvidenceError(f"{name} must be an integer")
    return value


def field(data: dict[str, Json], key: str) -> Json:
    if key not in data:
        raise EvidenceError(f"missing {key}")
    return data[key]


def canonical(data: Json) -> bytes:
    return (
        json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    ).encode()


def atomic_json(path: Path, data: Json) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(canonical(data))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def locked(path: Path) -> Generator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path.with_suffix(path.suffix + ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def update(path: Path, transform: Callable[[Json | None], Json]) -> Json:
    with locked(path):
        old = read_json(path) if path.exists() else None
        new = transform(old)
        atomic_json(path, new)
        return new
