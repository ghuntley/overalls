"""Rootfs archive identity retains exact bytes without extracting into the checkout."""

from __future__ import annotations

import io
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from identity import archive_records, compare_context_trees, walk_inputs
from schema import EvidenceError


def root_owned(member: tarfile.TarInfo) -> tarfile.TarInfo:
    member.uid = member.gid = 0
    member.uname = member.gname = ""
    return member


def write_archive(path: Path, members: list[tuple[tarfile.TarInfo, bytes | None]]) -> None:
    with tarfile.open(path, "w") as archive:
        root = tarfile.TarInfo(".")
        root.type = tarfile.DIRTYPE
        root.mode = 0o755
        archive.addfile(root)
        for member, data in members:
            if data is not None:
                member.size = len(data)
            archive.addfile(member, io.BytesIO(data) if data is not None else None)


class ContextArchiveTest(unittest.TestCase):
    def test_exact_bytes_modes_links_and_literal_backslash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "rootfs"
            (source / "subdir").mkdir(parents=True)
            (source / "subdir/back\\slash").write_bytes(b"exact\x00bytes\n")
            (source / "subdir/back\\slash").chmod(0o451)
            (source / "subdir/link").symlink_to("/nix/store/absolute-target")
            (source / "subdir-sibling").write_bytes(b"path component ordering")
            (source / "subdir").chmod(0o550)
            path = root / "rootfs.tar"
            with tarfile.open(path, "w", dereference=False) as archive:
                archive.add(source, arcname=".", filter=root_owned)
            self.assertEqual(archive_records(path), walk_inputs(root, ("rootfs",), frozenset()))
            self.assertEqual(os.readlink(source / "subdir/link"), "/nix/store/absolute-target")

    def test_context_comparison_checks_archive_and_output_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = root / "expected"
            staged = root / "staged"
            staged.mkdir()
            (expected / "rootfs/opt/overalls").mkdir(parents=True)
            for name in ("identity.json", "closure-store-paths.txt"):
                (expected / name).write_bytes(name.encode())
                (staged / name).write_bytes(name.encode())
            output = "/nix/store/" + "a" * 32 + "-context"
            stamp = (output + "\n").encode()
            (staged / "context-output.txt").write_bytes(stamp)
            with tarfile.open(staged / "rootfs.tar", "w") as archive:
                archive.add(expected / "rootfs", arcname=".", filter=root_owned)
                member = tarfile.TarInfo("./opt/overalls/context-output.txt")
                member.mode = 0o644
                member.size = len(stamp)
                archive.addfile(member, io.BytesIO(stamp))
            records = compare_context_trees(staged, expected, "workload", output)
            self.assertIn("rootfs/opt/overalls/context-output.txt", [r["path"] for r in records])
            (staged / "context-output.txt").write_bytes(b"stale\n")
            with self.assertRaisesRegex(EvidenceError, "current output stamp"):
                compare_context_trees(staged, expected, "workload", output)
            (staged / "context-output.txt").write_bytes(stamp)
            (expected / "rootfs/extra").write_bytes(b"changed current output")
            with self.assertRaisesRegex(EvidenceError, "differs from current built output"):
                compare_context_trees(staged, expected, "workload", output)

    def test_refuses_traversal_absolute_duplicate_and_special_members(self) -> None:
        regular = tarfile.TarInfo("file")
        hardlink = tarfile.TarInfo("hardlink")
        hardlink.type = tarfile.LNKTYPE
        hardlink.linkname = "file"
        device = tarfile.TarInfo("device")
        device.type = tarfile.CHRTYPE
        cases: tuple[tuple[list[tuple[tarfile.TarInfo, bytes | None]], str], ...] = (
            ([(tarfile.TarInfo("../escape"), b"bad")], "unsafe"),
            ([(tarfile.TarInfo("/absolute"), b"bad")], "unsafe"),
            ([(regular, b"one"), (tarfile.TarInfo("./file"), b"two")], "duplicate"),
            ([(regular, b"one"), (hardlink, None)], "unsupported"),
            ([(device, None)], "unsupported"),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rootfs.tar"
            for members, message in cases:
                with self.subTest(message=message):
                    write_archive(path, members)
                    with self.assertRaisesRegex(EvidenceError, message):
                        archive_records(path)

    def test_refuses_children_below_symlinks(self) -> None:
        link = tarfile.TarInfo("link")
        link.type = tarfile.SYMTYPE
        link.linkname = "/outside"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rootfs.tar"
            write_archive(path, [(link, None), (tarfile.TarInfo("link/child"), b"bad")])
            with self.assertRaisesRegex(EvidenceError, "non-directory"):
                archive_records(path)

    def test_refuses_non_root_member_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rootfs.tar"
            for uid, gid in ((10001, 0), (0, 10001)):
                with self.subTest(uid=uid, gid=gid):
                    member = tarfile.TarInfo("file")
                    member.uid, member.gid = uid, gid
                    write_archive(path, [(member, b"fixture")])
                    with self.assertRaisesRegex(EvidenceError, "non-root ownership"):
                        archive_records(path)


if __name__ == "__main__":
    unittest.main()
