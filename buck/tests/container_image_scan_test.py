"""Fixtures for the image layer scan in buck/container_image.py: a
token-shaped Namespace string is found in plain and gzip members at any
offset, including across the scanner's chunk boundary; a bare mention of the
prefix (as in documentation) and a clean image pass. Pure: no Docker and no
network.

Contract container-image-no-token: see .oss-scanner/CONTRACTS.
"""

from __future__ import annotations

import gzip
import io
import random
import sys
import tarfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from container_image import _CHUNK, TOKEN_MIN_BODY, TOKEN_PREFIX, scan


def _tar(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def _image(layer: bytes, compress: bool) -> bytes:
    blob = gzip.compress(layer) if compress else layer
    return _tar({"manifest.json": b"[]", "blobs/sha256/layer": blob, "config.json": b"{}"})


_TAR_HEADER = 512
_ALPHABET = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"


def _token(rng: random.Random) -> bytes:
    body = bytes(rng.choice(_ALPHABET) for _ in range(rng.randrange(TOKEN_MIN_BODY, 300)))
    return TOKEN_PREFIX + body


def _payload(rng: random.Random, size: int, offset: int | None, insert: bytes) -> bytes:
    data = bytearray(rng.randbytes(size).replace(b"n", b"m"))
    if offset is not None:
        data[offset : offset + len(insert)] = insert
    return bytes(data[:size])


def main() -> int:
    rng = random.Random(20261101)
    failures: list[str] = []
    cases = 0
    for _ in range(8):
        token = _token(rng)
        size = rng.randrange(len(token) + 1, 3 * _CHUNK)
        # Any offset, plus straddles of the first chunk boundary at every
        # position inside the shortest token-shaped match and at its end.
        offsets: list[int | None] = [None, rng.randrange(0, size - len(token) + 1)]
        if size > _CHUNK:
            shortest = len(TOKEN_PREFIX) + TOKEN_MIN_BODY
            # The file starts after the layer tar's 512-byte header, and the
            # scanner reads the layer blob in _CHUNK pieces from its start.
            offsets += [_CHUNK - _TAR_HEADER - k for k in [*range(shortest + 1), len(token)]]
        for offset in offsets:
            for insert, found in (
                (token, True),
                (TOKEN_PREFIX + b"` prefix", False),
                (token[: len(TOKEN_PREFIX) + TOKEN_MIN_BODY - 1] + b")", False),
            ):
                payload = _payload(rng, size, offset, insert)
                layer = _tar({"etc/file": payload})
                for compress in (False, True):
                    cases += 1
                    result = scan(io.BytesIO(_image(layer, compress)))
                    expected = ["blobs/sha256/layer"] if offset is not None and found else []
                    if result.matches != expected or result.members != 3:
                        failures.append(
                            f"size={size} offset={offset} gzip={compress} insert={len(insert)}: {result}"
                        )
    if failures:
        print("\n".join(failures[:10]), file=sys.stderr)
        return 1
    print(f"container_image scan: {cases} cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
