#!/usr/bin/env python3
"""Generate deterministic, synthetic PDFs for local regression checks."""

from __future__ import annotations

import hashlib
import json
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader, PdfWriter
from pypdf.constants import UserAccessPermissions
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"


def make_long_document(path: Path) -> None:
    pdf = canvas.Canvas(str(path), pagesize=letter, invariant=1, pageCompression=1)
    pdf.setTitle("Synthetic 501-page performance fixture")
    for page_number in range(1, 502):
        pdf.setFont("Helvetica-Bold", 16)
        pdf.drawString(54, 735, f"Performance fixture — page {page_number} of 501")
        pdf.setFont("Helvetica", 10)
        for line in range(28):
            pdf.drawString(54, 690 - line * 21, f"Synthetic text line {line + 1:02d}; page {page_number:03d}.")
        pdf.showPage()
    pdf.save()


def make_scanned_document(path: Path) -> None:
    image = Image.new("RGB", (1240, 1754), "white")
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default(size=34)
    draw.rectangle((72, 72, 1168, 1682), outline=(90, 90, 90), width=3)
    draw.text((140, 180), "SYNTHETIC SCAN FIXTURE", fill=(20, 20, 20), font=font)
    draw.text((140, 260), "Image-only page: text extraction should be empty.", fill=(25, 25, 25), font=font)
    for line in range(24):
        y = 420 + line * 43
        draw.line((145, y, 1080 - (line % 5) * 28, y), fill=(85, 85, 85), width=2)
    for x in range(110, 1200, 90):
        draw.point((x, 320 + (x % 5) * 13), fill=(60, 60, 60))

    pdf = canvas.Canvas(str(path), pagesize=letter, invariant=1, pageCompression=1)
    pdf.setTitle("Synthetic image-only scan fixture")
    pdf.drawImage(ImageReader(image), 0, 0, width=letter[0], height=letter[1], preserveAspectRatio=False)
    pdf.showPage()
    pdf.save()


def make_encrypted_document(path: Path) -> None:
    source = FIXTURES / "_encrypted-source.pdf"
    pdf = canvas.Canvas(str(source), pagesize=letter, invariant=1)
    pdf.drawString(72, 720, "Synthetic encrypted fixture; user password: reader-test")
    pdf.save()
    writer = PdfWriter(clone_from=str(source))
    writer.encrypt(
        user_password="reader-test",
        owner_password="owner-test",
        permissions_flag=UserAccessPermissions.PRINT,
    )
    with path.open("wb") as stream:
        writer.write(stream)
    source.unlink()


def make_cjk_document(path: Path) -> None:
    for font_name in ("STSong-Light", "HeiseiMin-W3", "HYSMyeongJo-Medium"):
        pdfmetrics.registerFont(UnicodeCIDFont(font_name))
    pdf = canvas.Canvas(str(path), pagesize=letter, invariant=1)
    pdf.setTitle("Synthetic CJK and rotated-text fixture")
    pdf.setFont("STSong-Light", 18)
    pdf.drawString(60, 720, "中文字体测试：阅读、选取与查找")
    pdf.setFont("HeiseiMin-W3", 16)
    pdf.drawString(60, 680, "日本語の文字と検索")
    pdf.setFont("HYSMyeongJo-Medium", 16)
    pdf.drawString(60, 640, "한국어 글꼴 시험")
    pdf.saveState()
    pdf.translate(510, 330)
    pdf.rotate(90)
    pdf.setFont("STSong-Light", 15)
    pdf.drawString(0, 0, "旋转文本：竖向阅读布局检查")
    pdf.restoreState()
    pdf.showPage()
    pdf.save()


def make_annotated_document(path: Path) -> None:
    source = FIXTURES / "_annotation-source.pdf"
    pdf = canvas.Canvas(str(source), pagesize=letter, invariant=1)
    pdf.drawString(72, 720, "Existing highlight must survive an edit-and-save roundtrip.")
    pdf.drawString(72, 690, "The second line is intentionally left unannotated.")
    pdf.showPage()
    pdf.save()

    writer = PdfWriter(clone_from=str(source))
    writer.add_annotation(
        page_number=0,
        annotation={
            "/Type": "/Annot",
            "/Subtype": "/Highlight",
            "/Rect": [72, 714, 374, 731],
            "/QuadPoints": [72, 731, 374, 731, 72, 714, 374, 714],
            "/C": [1, 1, 0],
            "/CA": 0.35,
            "/F": 4,
            "/Contents": "Existing fixture highlight",
            "/T": "Test corpus",
        },
    )
    with path.open("wb") as stream:
        writer.write(stream)
    source.unlink()


def make_malformed_document(path: Path) -> None:
    # A truncated catalog reference with no xref or trailer; intentionally invalid.
    path.write_bytes(b"%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 999 0 R >>\nendobj\n")


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    makers = {
        "large-501-pages.pdf": make_long_document,
        "scanned-image-only.pdf": make_scanned_document,
        "encrypted-fixture.pdf": make_encrypted_document,
        "cjk-mixed-layout.pdf": make_cjk_document,
        "existing-annotation.pdf": make_annotated_document,
        "malformed-xref.pdf": make_malformed_document,
    }
    for name, maker in makers.items():
        maker(FIXTURES / name)

    details = {
        "large-501-pages.pdf": {"type": "large-document", "pages": 501, "notes": "Synthetic repeated text; no personal data."},
        "scanned-image-only.pdf": {"type": "image-only-scan", "pages": 1, "notes": "Synthetic image; no searchable text by design."},
        "encrypted-fixture.pdf": {"type": "encrypted", "pages": 1, "user_password": "reader-test", "notes": "Synthetic; owner password is owner-test."},
        "cjk-mixed-layout.pdf": {"type": "cjk-and-rotated-text", "pages": 1, "notes": "Uses standard CID fonts; includes CJK and rotated text."},
        "existing-annotation.pdf": {"type": "existing-annotations", "pages": 1, "notes": "Contains one standard PDF Highlight annotation."},
        "malformed-xref.pdf": {"type": "malformed-pdf", "pages": None, "notes": "Intentionally truncated invalid PDF; parser should fail safely."},
    }
    manifest = {
        "generated_by": "TestCorpus/generate.py",
        "license": "CC0-1.0; synthetic fixtures authored for this project",
        "fixtures": [],
    }
    for name, info in details.items():
        payload = (FIXTURES / name).read_bytes()
        manifest["fixtures"].append({
            "filename": name,
            "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            **info,
        })
    (FIXTURES / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Generated {len(manifest['fixtures'])} synthetic fixtures in {FIXTURES}")


if __name__ == "__main__":
    main()
