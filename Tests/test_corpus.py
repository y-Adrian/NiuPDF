"""Sanity checks for committed synthetic PDF fixtures."""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

from pypdf import PdfReader


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "TestCorpus" / "fixtures"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text(encoding="utf-8"))


class CorpusTests(unittest.TestCase):
    def fixture(self, name: str) -> dict:
        return next(item for item in MANIFEST["fixtures"] if item["filename"] == name)

    def test_manifest_hashes_match_fixture_bytes(self) -> None:
        for item in MANIFEST["fixtures"]:
            with self.subTest(filename=item["filename"]):
                payload = (FIXTURES / item["filename"]).read_bytes()
                self.assertEqual(len(payload), item["bytes"])
                self.assertEqual(hashlib.sha256(payload).hexdigest(), item["sha256"])

    def test_large_fixture_has_more_than_500_pages(self) -> None:
        reader = PdfReader(FIXTURES / "large-501-pages.pdf", strict=True)
        self.assertEqual(len(reader.pages), 501)

    def test_scan_fixture_has_no_searchable_text(self) -> None:
        reader = PdfReader(FIXTURES / "scanned-image-only.pdf", strict=True)
        self.assertEqual(len(reader.pages), 1)
        self.assertEqual((reader.pages[0].extract_text() or "").strip(), "")
        self.assertTrue(reader.pages[0].get("/Resources").get("/XObject"))

    def test_encrypted_fixture_requires_password_and_opens_with_fixture_password(self) -> None:
        reader = PdfReader(FIXTURES / "encrypted-fixture.pdf", strict=True)
        self.assertTrue(reader.is_encrypted)
        self.assertEqual(reader.decrypt("incorrect"), 0)
        self.assertNotEqual(reader.decrypt("reader-test"), 0)
        self.assertEqual(len(reader.pages), 1)

    def test_cjk_fixture_has_font_resources_and_rotated_text(self) -> None:
        reader = PdfReader(FIXTURES / "cjk-mixed-layout.pdf", strict=True)
        self.assertEqual(len(reader.pages), 1)
        fonts = reader.pages[0]["/Resources"]["/Font"].get_object()
        self.assertGreaterEqual(len(fonts), 3)
        text = reader.pages[0].extract_text() or ""
        self.assertIn("中文字体测试", text)
        self.assertIn("日本語", text)

    def test_existing_annotation_is_standard_highlight(self) -> None:
        reader = PdfReader(FIXTURES / "existing-annotation.pdf", strict=True)
        annotations = reader.pages[0].get("/Annots")
        self.assertIsNotNone(annotations)
        self.assertEqual(len(annotations), 1)
        annotation = annotations[0].get_object()
        self.assertEqual(annotation.get("/Subtype"), "/Highlight")
        self.assertTrue(annotation.get("/QuadPoints"))

    def test_markup_regression_fixture_has_selectable_text_and_independent_annotations(self) -> None:
        reader = PdfReader(FIXTURES / "markup-regression.pdf", strict=True)
        self.assertEqual(len(reader.pages), 1)
        text = reader.pages[0].extract_text() or ""
        self.assertIn("five highlight colors", text)
        self.assertIn("toggle off", text)
        self.assertIn("independent from highlights", text)
        self.assertIn("Select this text to check", text)

        annotations = [item.get_object() for item in reader.pages[0].get("/Annots", [])]
        subtypes = [item.get("/Subtype") for item in annotations]
        self.assertCountEqual(subtypes, ["/Highlight", "/Underline", "/Text"])
        self.assertTrue(next(item for item in annotations if item.get("/Subtype") == "/Highlight").get("/QuadPoints"))
        self.assertEqual(
            next(item for item in annotations if item.get("/Subtype") == "/Text").get("/Contents"),
            "Preserve this independent note",
        )

    def test_malformed_fixture_is_rejected_in_strict_mode(self) -> None:
        with self.assertRaises(Exception):
            PdfReader(FIXTURES / "malformed-xref.pdf", strict=True)


if __name__ == "__main__":
    unittest.main()
