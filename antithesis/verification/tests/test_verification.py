"""Focused identity, assertion and durable campaign regression tests."""

from __future__ import annotations

import json
import multiprocessing
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from assertions import roster, scan_catalog
from campaign import (
    MAX_ACTIVE_ATTEMPTS,
    initialize,
    modify,
    policy_duration,
    reserve,
    transition,
    verify_manifest,
)
from identity import (
    CopyInput,
    _image_hashes,
    buck2_output,
    compare_context_trees,
    docker_copies,
    selected_stages,
    sha256,
    verify_catalog_link,
    verify_current_context,
    verify_image_contexts,
    verify_image_copies,
    verify_image_copy,
    verify_image_selection,
    verify_staged_catalog,
    verify_staged_selection,
    walk_inputs,
)
from schema import EvidenceError, Json, arr, atomic_json, field, integer, narrow_json, obj, string
from selection import (
    Selection,
    hosted_compose,
    manifest,
    materialization,
    read_selection,
    rendered_compose,
    selected_files,
    stage,
    validate_compose,
    verify_materialization,
)


def archive_rootfs(rootfs: Path) -> None:
    def root_owned(member: tarfile.TarInfo) -> tarfile.TarInfo:
        member.uid = member.gid = 0
        member.uname = member.gname = ""
        return member

    with tarfile.open(rootfs.with_name("rootfs.tar"), "w", dereference=False) as archive:
        archive.add(rootfs, arcname=".", filter=root_owned)


def hash_output(lines: str) -> bytes:
    return b"".join(line.encode("utf-8") + b"\0" for line in lines.splitlines())


def mutant_receipt(base: str, mutant: str, scope: str, target: str) -> dict[str, Json]:
    return obj(
        narrow_json(
            {
                "format": 1,
                "baseline_identity_sha256": base,
                "mutant_identity_sha256": mutant,
                "harness_scope_sha256": scope,
                "property_message": target,
                "patch_sha256": "a" * 64,
            }
        ),
        "mutant receipt",
    )


def reserve_worker(
    path_text: str, identity: str, message: str, queue: multiprocessing.Queue[str]
) -> None:
    try:
        outcome = modify(
            Path(path_text),
            "reserve",
            identity,
            [message],
            purpose="mutant",
            property_message=message,
        )
        queue.put(str(outcome["attempt_id"]))
    except EvidenceError as exc:
        queue.put(f"refused:{exc}")


class VerificationTests(unittest.TestCase):
    def test_research_catalog_keeps_planned_bootstrap_safety_separate_from_marker(self) -> None:
        root = Path(__file__).resolve().parents[3]
        catalog = root / "antithesis/scratchbook/property-catalog.md"
        properties = scan_catalog(catalog)
        bootstrap = next(
            prop for prop in properties if prop.slug == "bootstrap-setup-complete-single-owner"
        )
        self.assertEqual(bootstrap.primary_kind, "always")
        self.assertEqual(
            bootstrap.message,
            "Bootstrap setup marker follows independent readiness and retains one live owner",
        )
        data = roster(root, catalog, {"antithesis/workload/core/bootstrap.py"})
        self.assertIn(
            "bootstrap-setup-complete-single-owner",
            arr(field(data, "missing_primary_properties"), "missing primary properties"),
        )
        self.assertNotIn(
            "bootstrap-setup-complete-single-owner",
            arr(field(data, "mismatched_primary_properties"), "mismatched primary properties"),
        )
        self.assertIn(
            "Overalls bootstrap observed Control connection and independent oracle",
            arr(field(data, "supportive_messages"), "supportive messages"),
        )

    def test_image_hashes_preserve_backslash_escaped_paths(self) -> None:
        path = "/opt/overalls/line\\nwith\\backslash"
        digest = "a" * 64
        with patch(
            "identity.command_bytes",
            return_value=f"{digest}  {path}".encode() + b"\0",
        ) as query:
            self.assertEqual(
                _image_hashes(["podman", "run"], "sha256:" + "b" * 64, [path]),
                {path: digest},
            )
        query.assert_called_once_with(
            [
                "podman",
                "run",
                "--entrypoint",
                "/usr/bin/sha256sum",
                "sha256:" + "b" * 64,
                "--zero",
                path,
            ]
        )

    def test_source_inventory_excludes_lilly_tmp_but_keeps_other_tmp_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ignored = root / "lilly/tmp/exunit-fixture"
            ignored.parent.mkdir(parents=True)
            ignored.touch()
            fifo = root / "lilly/tmp/exunit-fixture.fifo"
            fifo.parent.mkdir(parents=True, exist_ok=True)
            os.mkfifo(fifo)
            kept = root / "lilly/lib/tmp/fixture.ex"
            kept.parent.mkdir(parents=True)
            kept.write_text("fixture", encoding="utf-8")
            records = walk_inputs(root, ("lilly",), excluded_paths=frozenset({"lilly/tmp"}))
            paths = {str(item["path"]) for item in records}
            self.assertNotIn("lilly/tmp", paths)
            self.assertNotIn("lilly/tmp/exunit-fixture.fifo", paths)
            self.assertIn("lilly/lib/tmp", paths)
            self.assertIn("lilly/lib/tmp/fixture.ex", paths)

    def test_current_context_requires_built_output_and_exact_staging(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = root / "staged"
            expected = root / "expected"
            for base in (staged, expected):
                (base / "rootfs/opt/overalls").mkdir(parents=True)
                (base / "identity.json").write_bytes(b'{"name":"workload"}')
                (base / "closure-store-paths.txt").write_bytes(b"/nix/store/example\n")
                (base / "rootfs/opt/overalls/image-identity.json").write_bytes(b"identity")
            output = "/nix/store/" + "a" * 32 + "-current"
            (staged / "rootfs/opt/overalls/context-output.txt").write_text(
                output + "\n", encoding="utf-8"
            )
            (staged / "context-output.txt").write_text(output + "\n", encoding="utf-8")
            archive_rootfs(staged / "rootfs")
            self.assertEqual(
                compare_context_trees(staged, expected, "workload", output),
                walk_inputs(
                    staged, ("identity.json", "closure-store-paths.txt", "rootfs"), frozenset()
                ),
            )
            (staged / "rootfs/opt/overalls/image-identity.json").write_bytes(b"stale")
            archive_rootfs(staged / "rootfs")
            with self.assertRaisesRegex(EvidenceError, "differs from current built output"):
                compare_context_trees(staged, expected, "workload", output)
            (staged / "rootfs/opt/overalls/context-output.txt").write_bytes(b"old output\n")
            archive_rootfs(staged / "rootfs")
            with self.assertRaisesRegex(EvidenceError, "no current output stamp"):
                compare_context_trees(staged, expected, "workload", output)
            derivation = "/nix/store/" + "d" * 32 + "-workload-context.drv"
            with (
                patch("identity.buck2_output", return_value=derivation) as buck2,
                patch("identity.command", return_value="/nix/store/" + "a" * 32 + "-unbuilt"),
                self.assertRaisesRegex(EvidenceError, "not built"),
            ):
                verify_current_context(root, "workload", staged)
            buck2.assert_called_once_with(root, "//:package-antithesis-workload-context[drv]")
            with (
                patch("identity.buck2_output", return_value="not a derivation"),
                self.assertRaisesRegex(EvidenceError, "invalid current Nix context derivation"),
            ):
                verify_current_context(root, "workload", staged)

    def test_buck2_output_reads_the_reported_output_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            out = root / "drv.txt"
            out.write_text("/nix/store/" + "d" * 32 + "-x.drv\n", encoding="utf-8")
            target = "//:package-antithesis-workload-context[drv]"
            listing = f"root{target} {out}\n".encode()
            ran = subprocess.CompletedProcess([], 0, stdout=listing, stderr=b"")
            with patch("identity.subprocess.run", return_value=ran):
                self.assertEqual(buck2_output(root, target), "/nix/store/" + "d" * 32 + "-x.drv")
            other = subprocess.CompletedProcess([], 0, stdout=b"root//:other /x\n", stderr=b"")
            with (
                patch("identity.subprocess.run", return_value=other),
                self.assertRaisesRegex(EvidenceError, "reported no output"),
            ):
                buck2_output(root, target)

    def test_image_context_evidence_is_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = root / "antithesis/build/contexts/workload"
            context.mkdir(parents=True)
            identity = b'{"name":"workload"}\n'
            closure = b"/nix/store/example\n"
            output = "/nix/store/" + "a" * 32 + "-current"
            stamp = (output + "\n").encode()
            (context / "identity.json").write_bytes(identity)
            (context / "closure-store-paths.txt").write_bytes(closure)
            (context / "context-output.txt").write_bytes(stamp)
            records: list[dict[str, Json]] = [{"stage": "workload", "current_nix_context": output}]
            images: dict[str, Json] = {"workload": {"image_id": "sha256:" + "a" * 64}}
            with patch("identity.command_bytes", side_effect=[identity, closure, stamp]):
                verify_image_contexts(root, "podman", records, images)
            with (
                patch("identity.command_bytes", side_effect=[identity, closure.rstrip(b"\n")]),
                self.assertRaisesRegex(EvidenceError, "stale Nix context evidence"),
            ):
                verify_image_contexts(root, "podman", records, images)
            with (
                patch("identity.command_bytes", side_effect=[identity, closure, b"old output\n"]),
                self.assertRaisesRegex(EvidenceError, "stale Nix context evidence"),
            ):
                verify_image_contexts(root, "podman", records, images)

    def test_docker_copy_inventory_rejects_stale_and_extra_paths(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        copies = docker_copies(repository)
        self.assertIn(
            CopyInput("antithesis/control_peer/", "/opt/overalls-antithesis/control-peer/", None),
            copies["workload"],
        )
        # The selection-scoped catalog is a direct COPY, so its lineage is
        # checked like every other workload input. It lands beside the
        # workload source; the rootfs link /opt/antithesis/catalog resolves to
        # its single ``workload`` module tree.
        self.assertIn(
            CopyInput(
                "antithesis/build/selected-test/catalog/", "/opt/overalls-antithesis/catalog/", None
            ),
            copies["workload"],
        )
        self.assertNotIn(
            CopyInput("antithesis/build/selected-test/catalog/", "/opt/antithesis/catalog/", None),
            copies["workload"],
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dockerfile = root / "antithesis/Dockerfile"
            dockerfile.parent.mkdir(parents=True)
            dockerfile.write_text(
                "FROM scratch AS workload\nCOPY --from=builder /source /destination\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(EvidenceError, "unsupported Dockerfile COPY"):
                docker_copies(root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "antithesis/operator"
            source.mkdir(parents=True)
            (source / "runner.exs").write_bytes(b"current")
            copied = CopyInput("antithesis/operator/", "/opt/overalls/operator/", None)
            path = "/opt/overalls/operator/runner.exs"
            listing = f"f\t755\t{path}\t\t."
            # The source mode is 0644, so a mode change also fails closed.
            with (
                patch("identity.command", return_value=listing),
                self.assertRaisesRegex(EvidenceError, "COPY paths differ"),
            ):
                verify_image_copy(root, "podman", "sha256:" + "a" * 64, copied)
            listing = f"f\t644\t{path}\t\t."
            digest = sha256(b"current")
            with (
                patch("identity.command", return_value=listing),
                patch("identity.command_bytes", return_value=f"{digest}  {path}".encode() + b"\0"),
            ):
                verify_image_copy(root, "podman", "sha256:" + "a" * 64, copied)
            with (
                patch(
                    "identity.command",
                    side_effect=[listing + "\nf\t644\t/opt/overalls/operator/stale.exs\t\t."],
                ),
                self.assertRaisesRegex(EvidenceError, "COPY paths differ"),
            ):
                verify_image_copy(root, "podman", "sha256:" + "a" * 64, copied)
            with (
                patch("identity.command", return_value=listing),
                patch(
                    "identity.command_bytes",
                    return_value=f"{'0' * 64}  {path}".encode() + b"\0",
                ),
                self.assertRaisesRegex(EvidenceError, "COPY bytes differ"),
            ):
                verify_image_copy(root, "podman", "sha256:" + "a" * 64, copied)

    def test_docker_copy_inventory_checks_rootfs_lineage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rootfs = root / "antithesis/build/contexts/workload/rootfs"
            (rootfs / "etc").mkdir(parents=True)
            (rootfs / "etc/base").write_bytes(b"rootfs bytes")
            (rootfs / "etc/link").symlink_to("base")
            (rootfs / "opt/overalls").mkdir(parents=True)
            archive_rootfs(rootfs)
            operator = root / "antithesis/operator"
            operator.mkdir(parents=True)
            (operator / "runner.exs").write_bytes(b"operator bytes")
            dockerfile = root / "antithesis/Dockerfile"
            dockerfile.write_text(
                "FROM scratch AS workload\n"
                "ADD antithesis/build/contexts/workload/rootfs.tar /\n"
                "COPY antithesis/operator/ /opt/overalls/operator/\n",
                encoding="utf-8",
            )
            image_id = "sha256:" + "a" * 64
            rootfs_listing = (
                "d\t755\t/etc\t\t.\n"
                "f\t644\t/etc/base\t\t.\n"
                "l\t777\t/etc/link\tbase\t.\n"
                "d\t755\t/opt\t\t.\n"
                "d\t755\t/opt/overalls\t\t.\n"
                "d\t755\t/opt/overalls/operator\t\t.\n"
                "f\t644\t/opt/overalls/operator/runner.exs\t\t.\n"
            )
            operator_path = "/opt/overalls/operator/runner.exs"
            with (
                patch(
                    "identity.command",
                    side_effect=[
                        rootfs_listing,
                        f"f\t644\t{operator_path}\t\t.",
                    ],
                ),
                patch(
                    "identity.command_bytes",
                    side_effect=[
                        f"{sha256(b'rootfs bytes')}  /etc/base".encode() + b"\0",
                        f"{sha256(b'operator bytes')}  {operator_path}".encode() + b"\0",
                    ],
                ),
            ):
                verify_image_copies(
                    root, "podman", ["workload"], {"workload": {"image_id": image_id}}
                )
            with (
                patch(
                    "identity.command",
                    return_value=rootfs_listing,
                ),
                patch(
                    "identity.command_bytes",
                    return_value=f"{'0' * 64}  /etc/base".encode() + b"\0",
                ),
                self.assertRaisesRegex(EvidenceError, "image COPY bytes differ.*rootfs.tar"),
            ):
                verify_image_copies(
                    root, "podman", ["workload"], {"workload": {"image_id": image_id}}
                )

    def test_rootfs_copy_accepts_only_default_later_copy_ancestors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rootfs = root / "rootfs"
            (rootfs / "etc").mkdir(parents=True)
            (rootfs / "etc/base").write_bytes(b"rootfs bytes")
            copied = CopyInput("rootfs/", "/", None)
            later = (
                CopyInput("test/", "/opt/antithesis/test/v1/", None),
                CopyInput("workload/", "/opt/overalls-antithesis/workload/", None),
            )
            source = "d\t755\t/etc\t\t.\nf\t644\t/etc/base\t\t."
            ancestors = (
                "d\t755\t/opt\t\t.\n"
                "d\t755\t/opt/antithesis\t\t.\n"
                "d\t755\t/opt/antithesis/test\t\t.\n"
                "d\t755\t/opt/overalls-antithesis\t\t."
            )
            digest = sha256(b"rootfs bytes")

            def verify(listing: str) -> None:
                with (
                    patch("identity.command", return_value=listing),
                    patch(
                        "identity.command_bytes",
                        return_value=f"{digest}  /etc/base".encode() + b"\0",
                    ),
                ):
                    verify_image_copy(
                        root,
                        "podman",
                        "sha256:" + "a" * 64,
                        copied,
                        ignored_destinations=later,
                        prune_runtime_filesystems=True,
                    )

            verify(source + "\n" + ancestors)
            invalid = (
                ancestors + "\nd\t755\t/opt/unrelated\t\t.",
                ancestors.replace("d\t755\t/opt/antithesis\t\t.", "f\t755\t/opt/antithesis\t\t."),
                ancestors.replace("d\t755\t/opt/antithesis\t\t.", "d\t700\t/opt/antithesis\t\t."),
                ancestors.replace(
                    "d\t755\t/opt/antithesis\t\t.", "d\t755\t/opt/antithesis\tlink\t."
                ),
            )
            for extra in invalid:
                with (
                    self.subTest(extra=extra),
                    self.assertRaisesRegex(EvidenceError, "COPY paths differ"),
                ):
                    verify(source + "\n" + extra)

    def test_executable_and_compiled_docs_in_inventory_but_reports_out(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "antithesis/test/v1/control/first_probe.py"
            docs = root / "marshall/priv/docs/index.md"
            report = root / "antithesis/scratchbook/report.md"
            review = root / "docs/architecture/reviews/review.md"
            for path in (executable, docs, report, review):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("v1", encoding="utf-8")
            paths = {
                str(item["path"]) for item in walk_inputs(root, ("antithesis/test", "marshall"))
            }
            self.assertIn("antithesis/test/v1/control/first_probe.py", paths)
            self.assertIn("marshall/priv/docs/index.md", paths)
            self.assertNotIn("antithesis/scratchbook/report.md", paths)
            self.assertNotIn("docs/architecture/reviews/review.md", paths)
            before = walk_inputs(root, ("antithesis/test", "marshall"))
            executable.write_text("v2", encoding="utf-8")
            self.assertNotEqual(before, walk_inputs(root, ("antithesis/test", "marshall")))
            after = walk_inputs(root, ("antithesis/test", "marshall"))
            report.write_text("review changed", encoding="utf-8")
            self.assertEqual(after, walk_inputs(root, ("antithesis/test", "marshall")))

    def test_roster_uses_literal_sdk_calls_and_primary_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = root / "antithesis/workload/core/probe.py"
            fixture = root / "antithesis/workload/tests/test_probe.py"
            elixir = root / "marshall/lib/marshall/application.ex"
            catalog = root / "antithesis/scratchbook/property-catalog.md"
            for path in (code, fixture, elixir, catalog):
                path.parent.mkdir(parents=True, exist_ok=True)
            code.write_text(
                'from antithesis.assertions import always as invariant, reachable\ninvariant(True, "property one")\nreachable("progress")\n',
                encoding="utf-8",
            )
            fixture.write_text(
                'from antithesis.assertions import always\nalways(True, "fixture only")\n',
                encoding="utf-8",
            )
            elixir.write_text(
                'defmodule Example do\n  alias OverallsAntithesis.SDK\n  SDK.reachable("app started")\nend\n',
                encoding="utf-8",
            )
            catalog.write_text(
                '### one — One\n| **Type** | Safety (`Always` primary) |\n| **Invariant** | `Always` **"property one"**. |\n\n### two — Two\n| **Type** | Safety (`Unreachable` primary) |\n| **Invariant** | `Unreachable` **"property two"**. |\n',
                encoding="utf-8",
            )
            data = roster(root, catalog)
            self.assertEqual(data["authored_safety_count"], 1)
            self.assertEqual(data["authored_callsite_count"], 3)
            self.assertEqual(data["missing_primary_properties"], ["two"])

    def test_changed_source_invalidates_frozen_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "antithesis/test/v1/control/first_probe.py"
            source.parent.mkdir(parents=True)
            source.write_text("version = 1", encoding="utf-8")
            original = walk_inputs(root, ("antithesis/test",))
            payload = obj(
                narrow_json(
                    {
                        "selection": "control-core",
                        "selected_compose": "antithesis/config/docker-compose.yaml",
                        "engine": "podman",
                        "source_files": original,
                    }
                ),
                "payload",
            )
            digest = sha256(
                json.dumps(
                    payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
                ).encode()
            )
            path = root / "identity.json"
            atomic_json(path, {**payload, "identity_sha256": digest})
            with patch("campaign.freeze", return_value={"identity_sha256": digest}):
                verify_manifest(path, root)
            source.write_text("version = 2", encoding="utf-8")
            changed = walk_inputs(root, ("antithesis/test",))
            self.assertNotEqual(original, changed)
            with (
                patch("campaign.freeze", return_value={"identity_sha256": "changed"}),
                self.assertRaises(EvidenceError),
            ):
                verify_manifest(path, root)

    def test_dynamic_sdk_message_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = root / "marshall/lib/marshall/application.ex"
            code.parent.mkdir(parents=True)
            code.write_text(
                'defmodule Example do\n  require OverallsAntithesis.SDK\n  OverallsAntithesis.SDK.always("message #{id}", true)\nend\n',
                encoding="utf-8",
            )
            from assertions import scan_calls

            with self.assertRaises(EvidenceError):
                scan_calls(root)
            code.write_text(
                "defmodule Example do\n  require OverallsAntithesis.SDK\n  OverallsAntithesis.SDK.always(message, true)\nend\n",
                encoding="utf-8",
            )
            with self.assertRaises(EvidenceError):
                scan_calls(root)
            code.unlink()
            python = root / "antithesis/workload/core/probe.py"
            python.parent.mkdir(parents=True)
            python.write_text(
                "from antithesis.assertions import always\nalways(True, message)\n",
                encoding="utf-8",
            )
            with self.assertRaises(EvidenceError):
                scan_calls(root)

    def test_budget_baseline_and_concurrency(self) -> None:
        ledger = initialize(None, "identity-a", ["safety"], harness_scope="fixed-harness")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-a", "mutant", "safety")
        baseline = reserve(ledger, "identity-a", "baseline", None)
        transition(ledger, str(baseline["attempt_id"]), "submitted", "run-1", duration_minutes=60)
        with self.assertRaises(EvidenceError):
            transition(ledger, str(baseline["attempt_id"]), "completed", result="green")
        transition(
            ledger,
            str(baseline["attempt_id"]),
            "completed",
            result="green",
            duration_minutes=60,
            receipt={
                "format": 1,
                "run_id": "run-1",
                "identity_sha256": "identity-a",
                "result": "green",
                "setup_complete": True,
                "execution_scope": "control-core",
            },
        )
        self.assertEqual(
            obj(
                field(obj(field(ledger, "configurations"), "configurations"), "control-core"),
                "control-core configuration",
            )["green_baseline"],
            "identity-a",
        )
        initialize(
            ledger,
            "identity-mutant",
            ["safety"],
            harness_scope="fixed-harness",
            mutation=mutant_receipt("identity-a", "identity-mutant", "fixed-harness", "safety"),
        )
        first = reserve(ledger, "identity-mutant", "mutant", "safety")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-mutant", "mutant", "safety")
        transition(ledger, str(first["attempt_id"]), "submitted", "run-2", duration_minutes=15)
        reserve(ledger, "identity-mutant", "mutant", "safety")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-mutant", "mutant", "safety")
        with self.assertRaises(EvidenceError):
            initialize(ledger, "identity-b", ["safety"])
        for item in arr(field(ledger, "attempts"), "attempts"):
            attempt = obj(item, "attempt")
            if attempt["status"] == "reserved":
                transition(ledger, str(attempt["attempt_id"]), "abandoned")
            elif attempt["status"] == "submitted":
                with self.assertRaises(EvidenceError):
                    transition(ledger, str(attempt["attempt_id"]), "abandoned")
                transition(
                    ledger,
                    str(attempt["attempt_id"]),
                    "completed",
                    result="unknown",
                    duration_minutes=15,
                )
        initialize(ledger, "identity-b", ["safety"])
        self.assertIsNone(
            obj(
                field(obj(field(ledger, "configurations"), "configurations"), "control-core"),
                "control-core configuration",
            )["green_baseline"]
        )
        self.assertEqual(len(arr(field(ledger, "attempts"), "attempts")), 3)
        self.assertEqual(ledger["ceiling"], 5)
        for purpose in ("bootstrap", "baseline"):
            reserve(ledger, "identity-b", purpose, None)
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-b", "bootstrap", None)

    def test_campaign_duration_policy_is_bound_at_each_transition(self) -> None:
        ledger = initialize(None, "identity", ["safety"], harness_scope="fixed-harness")
        baseline = reserve(ledger, "identity", "baseline", None)
        self.assertEqual(baseline["requested_duration_minutes"], 60)
        with self.assertRaisesRegex(EvidenceError, "submitted duration is required"):
            transition(ledger, str(baseline["attempt_id"]), "submitted", "baseline-run")
        with self.assertRaisesRegex(EvidenceError, "differs from reserved"):
            transition(
                ledger,
                str(baseline["attempt_id"]),
                "submitted",
                "baseline-run",
                duration_minutes=15,
            )
        transition(
            ledger,
            str(baseline["attempt_id"]),
            "submitted",
            "baseline-run",
            duration_minutes=60,
        )
        with self.assertRaisesRegex(EvidenceError, "observed duration is required"):
            transition(ledger, str(baseline["attempt_id"]), "completed", result="unknown")
        with self.assertRaisesRegex(EvidenceError, "differs from reserved"):
            transition(
                ledger,
                str(baseline["attempt_id"]),
                "completed",
                result="unknown",
                duration_minutes=15,
            )
        transition(
            ledger,
            str(baseline["attempt_id"]),
            "completed",
            result="unknown",
            duration_minutes=60,
        )
        self.assertEqual(
            obj(arr(field(ledger, "attempts"), "attempts")[0], "baseline attempt")[
                "observed_duration_minutes"
            ],
            60,
        )
        self.assertEqual(
            {
                purpose: policy_duration(purpose)
                for purpose in ("bootstrap", "mutant", "retry", "resweep")
            },
            {"bootstrap": 15, "mutant": 15, "retry": 15, "resweep": 15},
        )

    def test_default_image_selection_contains_only_ready_templates(self) -> None:
        root = Path(__file__).resolve().parents[3]
        selection = read_selection(root / "antithesis/verification/selections/control-core.json")
        data = manifest(root, selection)
        self.assertEqual(
            selection.templates,
            (
                "control",
                "control_rotation",
                "control_dispatch",
                "control_legacy_request",
                "control_delivery",
                "host_sessions",
                "host_rotation",
            ),
        )
        self.assertTrue(
            all(
                any(f"/{template}/" in string(name, "command") for template in selection.templates)
                for name in arr(field(data, "commands"), "commands")
            )
        )
        commands = [string(item, "command") for item in arr(field(data, "commands"), "commands")]
        for template in selection.singleton_templates:
            self.assertEqual(sum(f"/{template}/" in command for command in commands), 1)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "selected-test"
            stage(root, selection, output)
            staged_root = Path(directory)
            # The verifier resolves the standard ignored build location; a
            # copied fixture exercises the exact tree content validator.
            replica = staged_root / "antithesis/build/selected-test"
            replica.parent.mkdir(parents=True)
            import shutil

            shutil.copytree(output, replica)
            verify_staged_selection(staged_root, data)
            verify_staged_catalog(staged_root, data)
            catalog = replica / "catalog/workload"
            staged_modules = {
                str(path.relative_to(catalog)) for path in catalog.rglob("*") if path.is_file()
            }
            runtime_modules = {
                string(field(obj(item, "dependency"), "path"), "path").removeprefix(
                    "antithesis/workload/"
                )
                for item in arr(field(data, "runtime_dependencies"), "runtime dependencies")
            }
            self.assertEqual(staged_modules, runtime_modules)
            self.assertIn("core/__init__.py", staged_modules)
            self.assertIn("core/bootstrap.py", staged_modules)
            self.assertIn("control/host_sessions.py", staged_modules)
            self.assertIn("control/version_refusal.py", staged_modules)
            # Same package, untraced module: only the repository-origin commands import it.
            self.assertNotIn("repository/scenarios.py", staged_modules)
            self.assertFalse(any(name.startswith("backup/") for name in staged_modules))
            extra = catalog / "backup/scenarios.py"
            extra.parent.mkdir()
            extra.write_text("unselected module", encoding="utf-8")
            with self.assertRaisesRegex(EvidenceError, "extra or missing modules"):
                verify_staged_catalog(staged_root, data)
            shutil.rmtree(extra.parent)
            module = catalog / "core/bootstrap.py"
            original = module.read_bytes()
            module.write_text("stale module", encoding="utf-8")
            with self.assertRaisesRegex(EvidenceError, "differs from source"):
                verify_staged_catalog(staged_root, data)
            module.write_bytes(original)
            verify_staged_catalog(staged_root, data)
            (replica / "catalog/second").mkdir()
            with self.assertRaisesRegex(EvidenceError, "exactly one workload module tree"):
                verify_staged_catalog(staged_root, data)
            (replica / "catalog/second").rmdir()
            # The manifest binds both the copied tree and the rootfs link the
            # instrumentor resolves; a drifted path in either fails closed.
            self.assertEqual(
                string(field(data, "image_catalog_root"), "catalog root"),
                "/opt/overalls-antithesis/catalog/workload",
            )
            self.assertEqual(
                string(field(data, "image_catalog_link"), "catalog link"),
                "/opt/antithesis/catalog",
            )
            drifted = dict(data)
            drifted["image_catalog_link"] = "/opt/antithesis/catalog/workload"
            with self.assertRaisesRegex(EvidenceError, "unexpected image catalog link"):
                verify_staged_catalog(staged_root, drifted)
            drifted = dict(data)
            drifted["image_catalog_root"] = "/opt/antithesis/catalog/workload"
            with self.assertRaisesRegex(EvidenceError, "unexpected image catalog root"):
                verify_staged_catalog(staged_root, drifted)
            # The staged workload rootfs must present /opt/antithesis/catalog
            # as one link to the copied tree: a real directory of packages is
            # split into one instrumentor root per package and the SDK then
            # registers only one package's catalog per process.
            link = staged_root / "antithesis/build/contexts/workload/rootfs/opt/antithesis/catalog"
            rootfs = link.parents[2]
            link.parent.mkdir(parents=True)
            archive_rootfs(rootfs)
            with self.assertRaisesRegex(EvidenceError, "lacks the single-root catalog link"):
                verify_catalog_link(staged_root)
            (link / "workload").mkdir(parents=True)
            archive_rootfs(rootfs)
            with self.assertRaisesRegex(EvidenceError, "lacks the single-root catalog link"):
                verify_catalog_link(staged_root)
            shutil.rmtree(link)
            link.symlink_to("/opt/overalls-antithesis/catalog")
            archive_rootfs(rootfs)
            with self.assertRaisesRegex(EvidenceError, "unexpected tree"):
                verify_catalog_link(staged_root)
            link.unlink()
            link.symlink_to("/opt/overalls-antithesis/catalog/workload")
            archive_rootfs(rootfs)
            verify_catalog_link(staged_root)
            command = replica / "v1/control/serial_driver_smoke.py"
            command.write_text("stale command", encoding="utf-8")
            with self.assertRaises(EvidenceError):
                verify_staged_selection(staged_root, data)
            command.write_bytes(
                (root / "antithesis/test/v1/control/serial_driver_smoke.py").read_bytes()
            )
            shutil.rmtree(replica / "catalog")
            with self.assertRaisesRegex(EvidenceError, "extra or missing entries"):
                verify_staged_selection(staged_root, data)

    def test_selected_commands_keep_assertions_in_traced_modules(self) -> None:
        selection = Selection(
            name="probe",
            compose_files=("antithesis/config/docker-compose.yaml",),
            templates=("probe",),
            runtime_packages=("core",),
            singleton_templates=(),
            services=("workload",),
            workload_environment=("ANTITHESIS_DB_HOST",),
            bootstrap_template="probe",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            core = root / "antithesis/workload/core"
            core.mkdir(parents=True)
            (core / "__init__.py").write_text('"""core"""\n', encoding="utf-8")
            (core / "bootstrap.py").write_text("READY = True\n", encoding="utf-8")
            (core / "config.py").write_text("VALUE = 1\n", encoding="utf-8")
            launcher = root / "antithesis/workload/bootstrap.py"
            launcher.write_text("from core.bootstrap import READY\n", encoding="utf-8")
            command = root / "antithesis/test/v1/probe/serial_driver_probe.py"
            command.parent.mkdir(parents=True)
            command.write_text("from core.config import VALUE\nprint(VALUE)\n", encoding="utf-8")
            files, dependencies = selected_files(root, selection)
            self.assertEqual(files, [command])
            # Importing ``core.config`` executes ``core/__init__.py`` too, so the
            # initializer is a traced runtime dependency and catalog member. The
            # top-level launcher keeps the staged catalog root a module directory.
            self.assertEqual(
                dependencies,
                [launcher, core / "__init__.py", core / "bootstrap.py", core / "config.py"],
            )
            launcher.unlink()
            with self.assertRaisesRegex(EvidenceError, "catalog launcher is missing"):
                selected_files(root, selection)
            launcher.write_text("from core.bootstrap import READY\n", encoding="utf-8")
            command.write_text(
                'from antithesis.assertions import reachable\nreachable("probe ran")\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(EvidenceError, "declares SDK assertions"):
                selected_files(root, selection)

    def test_image_selection_rejects_broad_command_tree(self) -> None:
        root = Path(__file__).resolve().parents[3]
        selection = read_selection(root / "antithesis/verification/selections/control-core.json")
        data = manifest(root, selection)
        records = [obj(item, "file") for item in arr(field(data, "files"), "files")]
        paths = [
            "/opt/antithesis/test/"
            + string(field(item, "path"), "path").removeprefix("antithesis/test/")
            for item in records
        ]
        directories = sorted({str(Path(path).parent) for path in paths})
        hashes = [string(field(item, "sha256"), "hash") for item in records]
        runtime_records = [
            obj(item, "runtime dependency")
            for item in arr(field(data, "runtime_dependencies"), "runtime dependencies")
        ]
        runtime_paths = [
            "/opt/overalls-antithesis/workload/"
            + string(field(item, "path"), "path").removeprefix("antithesis/workload/")
            for item in runtime_records
        ]
        runtime_hashes = [string(field(item, "sha256"), "hash") for item in runtime_records]
        workload_records = [
            item
            for item in walk_inputs(root, ("antithesis/workload",))
            if item["path"] != "antithesis/workload"
        ]
        workload_listing: list[str] = []
        workload_hashes: list[str] = []
        for item in workload_records:
            source = string(field(item, "path"), "workload source")
            path = "/opt/overalls-antithesis/workload" + source.removeprefix("antithesis/workload")
            kind = string(field(item, "kind"), "workload kind")
            marker = {"file": "f", "directory": "d", "symlink": "l"}[kind]
            mode = format(integer(field(item, "mode"), "workload mode"), "o")
            target = string(field(item, "target"), "workload target") if kind == "symlink" else ""
            workload_listing.append(f"{marker}\t{mode}\t{path}\t{target}\t.")
            if kind == "file":
                workload_hashes.append(f"{string(field(item, 'sha256'), 'hash')}  {path}")
        responses = [
            json.dumps(data),
            "\n".join([*directories, *paths]),
            "\n".join(f"{digest}  {path}" for digest, path in zip(hashes, paths, strict=True)),
            "\n".join("755" for _ in paths),
            "\n".join(
                f"{digest}  {path}"
                for digest, path in zip(runtime_hashes, runtime_paths, strict=True)
            ),
            "\n".join(workload_listing),
            "\n".join(workload_hashes),
        ]

        def patch_queries() -> ExitStack:
            stack = ExitStack()
            stack.enter_context(
                patch(
                    "identity.command",
                    side_effect=[responses[0], responses[1], responses[3], responses[5]],
                )
            )
            stack.enter_context(
                patch(
                    "identity.command_bytes",
                    side_effect=[
                        hash_output(responses[2]),
                        hash_output(responses[4]),
                        hash_output(responses[6]),
                    ],
                )
            )
            return stack

        image = "sha256:" + "0" * 64
        with patch_queries():
            verify_image_selection(root, "podman", image, data)
        responses[1] += "\n/opt/antithesis/test/v1/repository/first_unready.py"
        with patch_queries(), self.assertRaises(EvidenceError):
            verify_image_selection(root, "podman", image, data)
        responses[1] = "\n".join([*directories, *paths, "/opt/antithesis/test/v1/control/extra"])
        with patch_queries(), self.assertRaises(EvidenceError):
            verify_image_selection(root, "podman", image, data)
        responses[1] = "\n".join([*directories, *paths])
        responses[4] = responses[4].replace(runtime_hashes[0], "0" * 64, 1)
        with patch_queries(), self.assertRaises(EvidenceError):
            verify_image_selection(root, "podman", image, data)
        responses[4] = "\n".join(
            f"{digest}  {path}" for digest, path in zip(runtime_hashes, runtime_paths, strict=True)
        )
        responses[5] += "\nf\t644\t/opt/overalls-antithesis/workload/core/stale.py\t\t."
        with patch_queries(), self.assertRaises(EvidenceError):
            verify_image_selection(root, "podman", image, data)
        responses[5] = "\n".join(workload_listing)
        # A module outside the selected command import graph must still bind
        # the image to this source tree.
        nonselected = next(
            item
            for item in workload_records
            if item["kind"] == "file"
            and item["path"] not in {record["path"] for record in runtime_records}
        )
        stale_path = "/opt/overalls-antithesis/workload" + string(
            field(nonselected, "path"), "nonselected source"
        ).removeprefix("antithesis/workload")
        responses[6] = responses[6].replace(
            f"{string(field(nonselected, 'sha256'), 'hash')}  {stale_path}",
            f"{'0' * 64}  {stale_path}",
        )
        with patch_queries(), self.assertRaises(EvidenceError):
            verify_image_selection(root, "podman", image, data)

    def test_materialized_graph_uses_inspected_images_and_named_volumes(self) -> None:
        rendered = obj(
            narrow_json(
                {
                    "x-build": {"context": "local"},
                    "services": {
                        "workload": {
                            "image": "overalls-antithesis/workload:local",
                            "build": {"target": "workload"},
                            "volumes": [
                                {"type": "volume", "source": "secrets", "target": "/run/secrets"}
                            ],
                        }
                    },
                }
            ),
            "rendered",
        )
        self.assertEqual(selected_stages(rendered), ["workload"])
        hosted = hosted_compose(rendered)
        self.assertNotIn(
            "build", obj(field(obj(field(hosted, "services"), "services"), "workload"), "workload")
        )
        self.assertNotIn("x-build", hosted)
        service = obj(field(obj(field(rendered, "services"), "services"), "workload"), "workload")
        service["image"] = "elsewhere/workload:latest"
        with self.assertRaises(EvidenceError):
            selected_stages(rendered)
        service["image"] = "overalls-antithesis/workload:local"
        service["volumes"] = narrow_json(
            [{"type": "bind", "source": "/tmp/secrets", "target": "/run/secrets"}]
        )
        with self.assertRaises(EvidenceError):
            hosted_compose(rendered)

    def test_materialized_config_receipt_binds_graph_and_image_ids(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        selection = read_selection(
            repository / "antithesis/verification/selections/control-core.json"
        )
        rendered = obj(
            narrow_json(
                {
                    "services": {
                        "workload": {
                            "image": "overalls-antithesis/workload:local",
                            "build": {"target": "workload"},
                            "volumes": [],
                        }
                    }
                }
            ),
            "rendered",
        )
        image_data = obj(
            narrow_json(
                {
                    "workload": {
                        "tag": "overalls-antithesis/workload:local",
                        "image_id": "sha256:" + "a" * 64,
                    }
                }
            ),
            "images",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "antithesis/runtime/configs/control-core"
            with (
                patch("selection.rendered_compose", return_value=rendered),
                patch("selection.images", return_value=image_data),
            ):
                materialization(root, selection, "podman", output)
            verify_materialization(root, selection, "podman", rendered, image_data)
            changed_images = obj(narrow_json(image_data), "changed images")
            obj(field(changed_images, "workload"), "workload")["image_id"] = "sha256:" + "b" * 64
            with self.assertRaises(EvidenceError):
                verify_materialization(root, selection, "podman", rendered, changed_images)
            (output / "unexpected.txt").write_text("not hosted", encoding="utf-8")
            with self.assertRaises(EvidenceError):
                verify_materialization(root, selection, "podman", rendered, image_data)

    def test_optional_profiles_select_only_their_ready_command_family(self) -> None:
        root = Path(__file__).resolve().parents[3]
        for name, family, expected_count in (
            ("repository-origin", "repository", 4),
            ("access-smtp", "access", 3),
            ("recorder-host", "recorder", 3),
            ("admission-stub", "admission", 2),
            ("backup-restic", "backup", 5),
            ("satellite-standin", "satellite", 4),
            ("guest-lifecycle", "guest_lifecycle", 1),
        ):
            with self.subTest(profile=name):
                selection = read_selection(
                    root / "antithesis/verification/selections" / f"{name}.json"
                )
                data = manifest(root, selection)
                commands = [
                    string(item, "command") for item in arr(field(data, "commands"), "commands")
                ]
                self.assertEqual(len(commands), expected_count)
                self.assertTrue(
                    all(command.startswith(f"antithesis/test/v1/{family}/") for command in commands)
                )
                self.assertEqual(selection.bootstrap_template, name)

    def test_selection_rejects_optional_overlay_without_profile(self) -> None:
        root = Path(__file__).resolve().parents[3]
        selection = read_selection(root / "antithesis/verification/selections/control-core.json")
        services = {name: {} for name in selection.services}
        environment = {
            key: "/run/overalls-secrets/fixture.json" for key in selection.workload_environment
        }
        environment["ANTITHESIS_DB_HOST"] = "pg"
        environment["ANTITHESIS_MARSHALL_URLS"] = "https://marshall-a,https://marshall-b"
        environment["ANTITHESIS_CONTROL_CREDENTIAL_FILE"] = (
            "/run/overalls-control-secrets/lilly-a-credential.json"
        )
        environment["ANTITHESIS_CONTROL_REQUEST_DIR"] = "/run/overalls-control-requests"
        services["workload"] = {
            "environment": environment,
            "depends_on": {
                name: {"condition": "service_healthy"}
                for name in ("pg", "marshall-a", "marshall-b", "enrollment", "lilly-a")
            },
            "volumes": [
                {"target": "/run/overalls-secrets"},
                {"target": "/run/overalls-control-secrets"},
                {"target": "/run/overalls-control-requests/requests"},
                {"target": "/run/overalls-control-requests/results"},
            ],
        }
        config = obj(narrow_json({"services": services}), "rendered Compose")
        validate_compose(selection, config)
        services["origin"] = {}
        with self.assertRaises(EvidenceError):
            validate_compose(selection, obj(narrow_json({"services": services}), "overlay Compose"))

    def test_recorder_profile_requires_gated_vm_and_read_only_witnesses(self) -> None:
        root = Path(__file__).resolve().parents[3]
        selection = read_selection(root / "antithesis/verification/selections/recorder-host.json")

        def rendered(**changes: object) -> dict[str, Json]:
            environment: dict[str, object] = {
                key: "/run/overalls-secrets/fixture.json" for key in selection.workload_environment
            }
            environment.update(
                {
                    "ANTITHESIS_DB_HOST": "pg",
                    "ANTITHESIS_MARSHALL_URLS": "https://marshall-a,https://marshall-b",
                    "ANTITHESIS_CONTROL_CREDENTIAL_FILE": (
                        "/run/overalls-control-secrets/lilly-a-credential.json"
                    ),
                    "ANTITHESIS_CONTROL_REQUEST_DIR": "/run/overalls-control-requests",
                    "ANTITHESIS_BOOTSTRAP_PROFILE": "recorder-host",
                    "ANTITHESIS_RECORDER_REQUESTS": "/run/overalls-recorder-requests",
                    "ANTITHESIS_RECORDER_RESULTS": "/run/overalls-recorder-results",
                    "ANTITHESIS_RECORDER_OBSERVATION": "/run/overalls-recorder-observation",
                    "ANTITHESIS_RECORDER_LEDGER": (
                        "/var/lib/overalls-antithesis-recorder/ledger.sqlite"
                    ),
                }
            )
            volumes: list[dict[str, object]] = [
                {"target": "/run/overalls-secrets"},
                {"target": "/run/overalls-control-secrets"},
                {"target": "/run/overalls-control-requests/requests"},
                {"target": "/run/overalls-control-requests/results"},
                {"target": "/run/overalls-recorder-requests"},
                {"target": "/run/overalls-recorder-results", "read_only": True},
                {"target": "/run/overalls-recorder-observation", "read_only": True},
                {"target": "/var/lib/overalls-antithesis-recorder"},
            ]
            depends = {
                name: {"condition": "service_healthy"}
                for name in (
                    "pg",
                    "marshall-a",
                    "marshall-b",
                    "enrollment",
                    "lilly-a",
                    "recorder-host-vmm",
                )
            }
            services: dict[str, object] = {name: {} for name in selection.services}
            services["recorder-host-vmm"] = {"healthcheck": {"test": ["CMD", "true"]}}
            services["workload"] = {
                "environment": environment,
                "depends_on": depends,
                "volumes": volumes,
            }
            if "profile" in changes:
                environment["ANTITHESIS_BOOTSTRAP_PROFILE"] = changes["profile"]
            if changes.get("writable_observation"):
                volumes[6] = {"target": "/run/overalls-recorder-observation"}
            if changes.get("ungated"):
                depends["recorder-host-vmm"] = {"condition": "service_started"}
            if changes.get("vm_state"):
                volumes.append({"target": "/var/lib/recorder-hostvm/state"})
            return obj(narrow_json({"services": services}), "recorder Compose")

        validate_compose(selection, rendered())
        for change in (
            {"profile": "control-core"},
            {"writable_observation": True},
            {"ungated": True},
            {"vm_state": True},
        ):
            with self.subTest(change=change), self.assertRaises(EvidenceError):
                validate_compose(selection, rendered(**change))

    def test_admission_stub_profile_selects_stub_without_physical_claims(self) -> None:
        root = Path(__file__).resolve().parents[3]
        selection = read_selection(root / "antithesis/verification/selections/admission-stub.json")
        data = manifest(root, selection)
        runtime = {
            string(field(obj(item, "dependency"), "path"), "path")
            for item in arr(field(data, "runtime_dependencies"), "runtime dependencies")
        }
        # The stub profile never declares the live-ZFS physical assertions.
        for module in ("physical_scenario.py", "physical.py", "verdict.py", "capacity.py"):
            self.assertNotIn(f"antithesis/workload/admission/{module}", runtime)

        def rendered(**changes: object) -> dict[str, Json]:
            environment: dict[str, object] = {
                key: "/run/overalls-secrets/fixture.json" for key in selection.workload_environment
            }
            environment.update(
                {
                    "ANTITHESIS_DB_HOST": "pg",
                    "ANTITHESIS_MARSHALL_URLS": "https://marshall-a,https://marshall-b",
                    "ANTITHESIS_CONTROL_CREDENTIAL_FILE": (
                        "/run/overalls-control-secrets/lilly-a-credential.json"
                    ),
                    "ANTITHESIS_CONTROL_REQUEST_DIR": "/run/overalls-control-requests",
                    "ANTITHESIS_CONTROL_OPERATOR_ROOT": "/run/overalls-control-requests",
                    "ANTITHESIS_REPOSITORY_FIXTURE_FILE": (
                        "/run/overalls-control-secrets/fixture.json"
                    ),
                    "ANTITHESIS_BOOTSTRAP_PROFILE": "admission-stub",
                }
            )
            stub = {"OVERALLS_ANTITHESIS_STORAGE_STUB": "1"}
            services: dict[str, object] = {name: {} for name in selection.services}
            services["lilly-a"] = {
                "image": "overalls-antithesis/lilly:local",
                "environment": dict(stub),
            }
            services["enrollment"] = {"environment": dict(stub)}
            services["workload"] = {
                "environment": environment,
                "depends_on": {
                    name: {"condition": "service_healthy"}
                    for name in ("pg", "marshall-a", "marshall-b", "enrollment", "lilly-a")
                },
                "volumes": [
                    {"target": "/run/overalls-secrets"},
                    {"target": "/run/overalls-control-secrets"},
                    {"target": "/run/overalls-control-requests/requests"},
                    {"target": "/run/overalls-control-requests/results"},
                ],
            }
            if changes.get("physical"):
                environment["ANTITHESIS_PHYSICAL_SAMPLE_FILE"] = "/run/physical.json"
            if changes.get("no_stub"):
                services["lilly-a"] = {"image": "overalls-antithesis/lilly:local"}
            if changes.get("guest_lilly"):
                services["lilly-a"] = {
                    "image": "overalls-antithesis/lilly-guest:local",
                    "environment": dict(stub),
                }
            if changes.get("profile"):
                environment["ANTITHESIS_BOOTSTRAP_PROFILE"] = "control-core"
            return obj(narrow_json({"services": services}), "admission Compose")

        validate_compose(selection, rendered())
        for change in ("physical", "no_stub", "guest_lilly", "profile"):
            with self.subTest(change=change), self.assertRaises(EvidenceError):
                validate_compose(selection, rendered(**{change: True}))

    @unittest.skipUnless(shutil.which("docker-compose"), "Compose CLI unavailable")
    def test_guest_lifecycle_compose_keeps_guest_sockets_out_of_workload(self) -> None:
        root = Path(__file__).resolve().parents[3]
        selection = read_selection(root / "antithesis/verification/selections/guest-lifecycle.json")
        healthy = {"condition": "service_healthy"}

        def volume(source: str, target: str, read_only: bool = False) -> dict[str, object]:
            return {"type": "volume", "source": source, "target": target, "read_only": read_only}

        def graph(mutation: str = "") -> dict[str, Json]:
            environment = {
                key: "/run/overalls-secrets/fixture.json" for key in selection.workload_environment
            }
            environment.update(
                {
                    "ANTITHESIS_DB_HOST": "pg",
                    "ANTITHESIS_MARSHALL_URLS": "https://marshall-a,https://marshall-b",
                    "ANTITHESIS_CONTROL_CREDENTIAL_FILE": (
                        "/run/overalls-control-secrets/lilly-a-credential.json"
                    ),
                    "ANTITHESIS_CONTROL_REQUEST_DIR": "/run/overalls-control-requests",
                    "ANTITHESIS_BOOTSTRAP_PROFILE": (
                        "control-core" if mutation == "profile" else "guest-lifecycle"
                    ),
                }
            )
            gated = ["pg", "marshall-a", "marshall-b", "enrollment", "lilly-a"]
            if mutation != "ungated":
                gated.append("guest-vmm")
            workload_volumes = [
                volume("oracle-credentials", "/run/overalls-secrets", True),
                volume("control-credentials", "/run/overalls-control-secrets", True),
                volume("control-requests", "/run/overalls-control-requests/requests"),
                volume("control-results", "/run/overalls-control-requests/results", True),
            ]
            if mutation == "workload_witness":
                workload_volumes.append(
                    volume("guest-vmm-witness", "/run/overalls-guest-witness", True)
                )
            enrollment_volumes = [
                volume("guest-vmm-witness", "/run/overalls-guest-witness", True),
                volume("guest-catalog", "/run/overalls-guest-catalog", True),
            ]
            if mutation == "enrollment_control":
                enrollment_volumes.append(volume("guest-vmm-control", "/run/overalls-guest-vmm"))
            services: dict[str, object] = {name: {} for name in selection.services}
            services["workload"] = {
                "environment": environment,
                "depends_on": {name: healthy for name in gated},
                "volumes": workload_volumes,
            }
            services["lilly-a"] = {
                "image": (
                    "overalls-antithesis/lilly:local"
                    if mutation == "lilly_image"
                    else "overalls-antithesis/lilly-guest:local"
                ),
                "depends_on": {"guest-vmm": healthy},
                "environment": {
                    "OVERALLS_ANTITHESIS_GUEST_SOCKET": "/run/overalls-guest-vmm/control.sock",
                    "OVERALLS_ANTITHESIS_GUEST_IMAGE": "/opt/overalls/guest-vmm/image",
                },
                "volumes": [
                    volume("guest-vmm-control", "/run/overalls-guest-vmm"),
                    volume("guest-catalog", "/run/overalls-guest-catalog"),
                ],
            }
            services["enrollment"] = {
                "environment": {
                    "OVERALLS_ANTITHESIS_GUEST_WITNESS_SOCKET": (
                        "/run/overalls-guest-witness/witness.sock"
                    ),
                    "OVERALLS_ANTITHESIS_GUEST_CATALOG": "1",
                },
                "volumes": enrollment_volumes,
            }
            return obj(narrow_json({"services": services}), "guest Compose")

        validate_compose(selection, graph())
        for mutation in (
            "workload_witness",
            "ungated",
            "lilly_image",
            "enrollment_control",
            "profile",
        ):
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                validate_compose(selection, graph(mutation))

    def test_backup_and_satellite_profiles_refuse_weakened_fixtures(self) -> None:
        root = Path(__file__).resolve().parents[3]
        backup = read_selection(root / "antithesis/verification/selections/backup-restic.json")
        rendered = rendered_compose(root, backup)
        workload = obj(field(obj(field(rendered, "services"), "s"), "workload"), "w")
        workload["volumes"] = [
            item
            for item in arr(field(workload, "volumes"), "v")
            if field(obj(item, "v"), "target") != "/var/lib/overalls-backup-fixture"
        ]
        with self.assertRaises(EvidenceError):
            validate_compose(backup, rendered)

        satellite = read_selection(
            root / "antithesis/verification/selections/satellite-standin.json"
        )
        for weaken in ("network", "results", "secret"):
            with self.subTest(weaken=weaken):
                rendered = rendered_compose(root, satellite)
                services = obj(field(rendered, "services"), "services")
                standin = obj(field(services, "guest-standin"), "stand-in")
                if weaken == "network":
                    standin["network_mode"] = "service:workload"
                elif weaken == "results":
                    workload = obj(field(services, "workload"), "workload")
                    for item in arr(field(workload, "volumes"), "v"):
                        mount = obj(item, "v")
                        if field(mount, "target") == "/run/overalls-guest-standin/results":
                            mount["read_only"] = False
                else:
                    arr(field(standin, "volumes"), "v").append(
                        {"type": "volume", "source": "x", "target": "/run/overalls-secrets"}
                    )
                with self.assertRaises(EvidenceError):
                    validate_compose(satellite, rendered)

    def test_global_budget_across_configs(self) -> None:
        ledger = initialize(
            None, "identity-a", ["safety", "safety-two"], "antithesis/config/a.yaml"
        )
        initialize(ledger, "identity-b", ["safety", "safety-two"], "antithesis/config/b.yaml")
        self.assertEqual(ledger["ceiling"], 10)
        for index in range(10):
            config, identity = (
                ("antithesis/config/a.yaml", "identity-a")
                if index % 2 == 0
                else ("antithesis/config/b.yaml", "identity-b")
            )
            reserve(ledger, identity, "bootstrap", None, config)
            if index == 4:
                for item in arr(field(ledger, "attempts"), "attempts"):
                    transition(ledger, str(obj(item, "attempt")["attempt_id"]), "abandoned")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-a", "bootstrap", None, "antithesis/config/a.yaml")
        initialize(ledger, "identity-c", ["new safety"], "antithesis/config/c.yaml")
        self.assertEqual(ledger["ceiling"], 15)
        self.assertEqual(ledger["safety_messages"], ["new safety", "safety", "safety-two"])

    def test_rebuild_preserves_spend_and_baselines_are_per_config(self) -> None:
        ledger = initialize(None, "identity-a", ["safety"], "antithesis/config/a.yaml")
        initialize(ledger, "identity-b", ["safety"], "antithesis/config/b.yaml")
        baseline = reserve(ledger, "identity-a", "baseline", None, "antithesis/config/a.yaml")
        transition(
            ledger, str(baseline["attempt_id"]), "submitted", "a-baseline", duration_minutes=60
        )
        transition(
            ledger,
            str(baseline["attempt_id"]),
            "completed",
            result="green",
            duration_minutes=60,
            receipt={
                "format": 1,
                "run_id": "a-baseline",
                "identity_sha256": "identity-a",
                "result": "green",
                "setup_complete": True,
                "execution_scope": "config-a",
            },
        )
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-b", "mutant", "safety", "antithesis/config/b.yaml")
        initialize(ledger, "identity-a2", ["safety"], "antithesis/config/a.yaml")
        self.assertEqual(len(arr(field(ledger, "attempts"), "attempts")), 1)
        self.assertIsNone(
            obj(
                field(
                    obj(field(ledger, "configurations"), "configurations"),
                    "antithesis/config/a.yaml",
                ),
                "configuration a",
            )["green_baseline"]
        )
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity-a2", "mutant", "safety", "antithesis/config/a.yaml")

    def test_mutant_requires_authored_target_and_exact_lineage(self) -> None:
        ledger = initialize(
            None,
            "baseline",
            ["authored", "catalog-only"],
            authored_messages=["authored"],
            harness_scope="fixed-harness",
        )
        baseline = reserve(ledger, "baseline", "baseline", None)
        transition(
            ledger, str(baseline["attempt_id"]), "submitted", "green-run", duration_minutes=60
        )
        transition(
            ledger,
            str(baseline["attempt_id"]),
            "completed",
            result="green",
            duration_minutes=60,
            receipt={
                "format": 1,
                "run_id": "green-run",
                "identity_sha256": "baseline",
                "result": "green",
                "setup_complete": True,
                "execution_scope": "control-core",
            },
        )
        with self.assertRaises(EvidenceError):
            initialize(
                ledger,
                "mutant",
                ["authored", "catalog-only"],
                authored_messages=["authored"],
                harness_scope="changed-harness",
                mutation=mutant_receipt("baseline", "mutant", "changed-harness", "authored"),
            )
        with self.assertRaises(EvidenceError):
            initialize(
                ledger,
                "mutant",
                ["authored", "catalog-only"],
                authored_messages=["authored"],
                harness_scope="fixed-harness",
                mutation=mutant_receipt("baseline", "mutant", "fixed-harness", "catalog-only"),
            )
        initialize(
            ledger,
            "mutant",
            ["authored", "catalog-only"],
            authored_messages=["authored"],
            harness_scope="fixed-harness",
            mutation=mutant_receipt("baseline", "mutant", "fixed-harness", "authored"),
        )
        attempt = reserve(ledger, "mutant", "mutant", "authored")
        self.assertEqual(attempt["baseline_identity_sha256"], "baseline")
        self.assertEqual(attempt["identity_sha256"], "mutant")
        self.assertEqual(attempt["patch_sha256"], "a" * 64)
        with self.assertRaises(EvidenceError):
            reserve(ledger, "mutant", "mutant", "catalog-only")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "baseline", "mutant", "authored")

    def test_legacy_per_config_ledger_is_refused_without_resetting_spend(self) -> None:
        old = {"format": 1, "attempts": [{"attempt_id": "spent"}]}
        with self.assertRaises(EvidenceError):
            initialize(narrow_json(old), "identity", ["safety"])

    def test_inflight_limit_and_config_binding(self) -> None:
        messages = [f"safety-{index}" for index in range(8)]
        ledger = initialize(None, "identity", messages, "antithesis/config/a.yaml")
        for _ in range(MAX_ACTIVE_ATTEMPTS):
            reserve(ledger, "identity", "bootstrap", None, "antithesis/config/a.yaml")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity", "bootstrap", None, "antithesis/config/a.yaml")
        with self.assertRaises(EvidenceError):
            reserve(ledger, "identity", "bootstrap", None, "antithesis/config/b.yaml")

    def test_race_reserves_only_one_mutant_selection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            modify(path, "init", "identity", ["safety"], harness_scope="fixed-harness")
            baseline = modify(path, "reserve", "identity", ["safety"], purpose="baseline")
            modify(
                path,
                "submitted",
                "identity",
                ["safety"],
                attempt_id=str(baseline["attempt_id"]),
                run_id="baseline",
                duration_minutes=60,
            )
            modify(
                path,
                "completed",
                "identity",
                ["safety"],
                attempt_id=str(baseline["attempt_id"]),
                result="green",
                duration_minutes=60,
                receipt={
                    "format": 1,
                    "run_id": "baseline",
                    "identity_sha256": "identity",
                    "result": "green",
                    "setup_complete": True,
                    "execution_scope": "control-core",
                },
            )
            modify(
                path,
                "init",
                "mutant",
                ["safety"],
                harness_scope="fixed-harness",
                mutation=mutant_receipt("identity", "mutant", "fixed-harness", "safety"),
            )
            queue: multiprocessing.Queue[str] = multiprocessing.Queue()
            children = [
                multiprocessing.Process(
                    target=reserve_worker, args=(str(path), "mutant", "safety", queue)
                )
                for _ in range(4)
            ]
            for child in children:
                child.start()
            results = [queue.get(timeout=10) for _ in children]
            for child in children:
                child.join(timeout=10)
                self.assertEqual(child.exitcode, 0)
            self.assertEqual(sum(not result.startswith("refused:") for result in results), 1)


if __name__ == "__main__":
    unittest.main()
