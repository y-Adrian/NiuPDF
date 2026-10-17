"""Run a PDFKit -> pypdf -> PDFKit annotation preservation roundtrip."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from pypdf import PdfReader, PdfWriter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "TestCorpus" / "fixtures" / "existing-annotation.pdf"


def annotation_counts(path: Path) -> tuple[int, int]:
    reader = PdfReader(path, strict=True)
    annotations = [
        annotation.get_object()
        for page in reader.pages
        for annotation in (page.get("/Annots") or [])
    ]
    return (
        sum(annotation.get("/Subtype") == "/Highlight" for annotation in annotations),
        sum(annotation.get("/Subtype") == "/Underline" for annotation in annotations),
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check_interop_roundtrip.py <PDFKitInteropProbe executable>")
    probe = Path(sys.argv[1]).resolve()
    if not probe.is_file():
        raise SystemExit(f"PDFKit probe executable not found: {probe}")

    with tempfile.TemporaryDirectory(prefix="paperplane-interop-") as directory:
        temp = Path(directory)
        pdfkit_first = temp / "pdfkit-first.pdf"
        external_roundtrip = temp / "external-roundtrip.pdf"
        pdfkit_final = temp / "pdfkit-final.pdf"

        subprocess.run([str(probe), "roundtrip", str(SOURCE), str(pdfkit_first)], check=True)
        if annotation_counts(pdfkit_first) != (1, 1):
            raise AssertionError("pypdf could not read exactly one standard highlight and one underline from PDFKit output")

        # pypdf stands in for a second PDF implementation while preserving the annotations.
        writer = PdfWriter(clone_from=str(pdfkit_first))
        writer.add_metadata({"/Subject": "A-B-A interoperability regression fixture"})
        with external_roundtrip.open("wb") as stream:
            writer.write(stream)
        if annotation_counts(external_roundtrip) != (1, 1):
            raise AssertionError("The external-library roundtrip changed annotation counts")

        subprocess.run([str(probe), "roundtrip", str(external_roundtrip), str(pdfkit_final)], check=True)
        final_counts = annotation_counts(pdfkit_final)
        if final_counts != (1, 1):
            raise AssertionError(f"The A-B-A roundtrip changed annotations: {final_counts}")

        original = PdfReader(SOURCE, strict=True)
        final = PdfReader(pdfkit_final, strict=True)
        if len(final.pages) != len(original.pages):
            raise AssertionError("The A-B-A roundtrip changed the page count")
        if final.pages[0].extract_text() != original.pages[0].extract_text():
            raise AssertionError("The A-B-A roundtrip changed page text")
        print("A -> PDFKit -> pypdf -> PDFKit roundtrip passed; the source fixture was not modified.")


if __name__ == "__main__":
    main()
