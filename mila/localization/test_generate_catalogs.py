from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from generate_catalogs import generate


class CatalogGeneratorTest(unittest.TestCase):
    def test_arb_source_is_supported_for_mila_catalogs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "app_en.arb").write_text(
                '{"appTitle":"Mila","@appTitle":{"description":"name"}}',
                encoding="utf-8",
            )
            output = source / "out"
            generate(source, output)
            bundle = json.loads((output / "en.json").read_text(encoding="utf-8"))
            self.assertEqual(bundle["domains"]["mila"]["messages"][0]["id"], "appTitle")

    def test_deterministic_bundle_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gettext" / "en" / "LC_MESSAGES"
            source.mkdir(parents=True)
            (source / "shared.po").write_text(
                'msgid ""\nmsgstr "Language: en\\n"\n\n'
                'msgctxt "nav"\nmsgid "Hello %{name}"\nmsgstr "Hello %{name}"\n',
                encoding="utf-8",
            )
            first, second = root / "one", root / "two"
            generate(root / "gettext", first)
            generate(root / "gettext", second)
            self.assertEqual((first / "en.json").read_bytes(), (second / "en.json").read_bytes())
            manifest = json.loads((first / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["schema"], 1)
            self.assertEqual(manifest["locales"], ["en"])

    def test_placeholder_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "en" / "LC_MESSAGES"
            source.mkdir(parents=True)
            (source / "shared.po").write_text(
                'msgid "Hello %{name}"\nmsgstr "Hello"\n', encoding="utf-8"
            )
            with self.assertRaises(ValueError):
                generate(Path(directory), Path(directory) / "out")


if __name__ == "__main__":
    unittest.main()
