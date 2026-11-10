"""Writes a small AcroForm PDF by hand, without PDFKit or a PDF library, as
another producer would: text, multi-line text, check box, radio group, combo
box, list box and a read-only field, with NeedAppearances. Standard library
only; generate.py calls `write`, or run it directly with an output path."""
import sys
from pathlib import Path


def write(path: Path) -> None:

    objects = {}
    def obj(n, body): objects[n] = body

    def box(x, y, w, h): return f"[{x} {y} {x+w} {y+h}]"
    def stream(content):
        data = content.encode("latin-1")
        return f"<< /Length {len(data)} >>\nstream\n".encode() + data + b"\nendstream"

    # 1 catalog, 2 pages, 3 page, 4 content, 5 font, 6 acroform
    obj(1, b"<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>")
    obj(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    labels = [("Name:", 700), ("Notes:", 640), ("I agree", 560), ("Color:", 520), ("Country:", 470), ("Fruit:", 400), ("Read-only:", 330)]
    content = "BT /F1 12 Tf " + " ".join(f"1 0 0 1 60 {y+6} Tm ({t}) Tj" for t, y in labels) + " ET"
    content += " 0.6 G 140 700 m 140 700 l S"
    obj(4, stream(content))
    obj(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    # Appearance streams for check and radio states.
    obj(20, stream("q 0 g BT /ZaDb 12 Tf 3 4 Td (4) Tj ET Q").replace(b"<< /Length", b"<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Resources << /Font << /ZaDb 21 0 R >> >> /Length"))
    obj(22, stream("").replace(b"<< /Length", b"<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length"))
    obj(21, b"<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>")
    obj(23, stream("q 0 g BT /ZaDb 10 Tf 4 4 Td (l) Tj ET Q").replace(b"<< /Length", b"<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Resources << /Font << /ZaDb 21 0 R >> >> /Length"))

    annots = []
    def widget(n, extra, rect):
        annots.append(n)
        obj(n, f"<< /Type /Annot /Subtype /Widget /Rect {rect} /P 3 0 R /F 4 /MK << /BC [0.4 0.4 0.4] /BG [0.95 0.95 1] >> {extra} >>".encode())

    widget(10, "/FT /Tx /T (name) /DA (/Helv 12 Tf 0 g) /V ()", box(140, 695, 260, 22))
    widget(11, "/FT /Tx /T (notes) /Ff 4096 /DA (/Helv 10 Tf 0 g) /V ()", box(140, 600, 260, 60))
    widget(12, "/FT /Btn /T (agree) /V /Off /AS /Off /AP << /N << /Yes 20 0 R /Off 22 0 R >> >>", box(140, 556, 18, 18))
    # Radio group: parent 13, kids 14, 15
    objects[13] = b"<< /FT /Btn /T (color) /Ff 49152 /V /Off /Kids [14 0 R 15 0 R] >>"
    for n, state, x in [(14, "Red", 140), (15, "Blue", 200)]:
        annots.append(n)
        obj(n, f"<< /Type /Annot /Subtype /Widget /Parent 13 0 R /Rect {box(x, 516, 18, 18)} /P 3 0 R /F 4 /AS /Off /MK << /BC [0.4 0.4 0.4] >> /AP << /N << /{state} 23 0 R /Off 22 0 R >> >> >>".encode())
    widget(16, "/FT /Ch /T (country) /Ff 131072 /Opt [(China) (Japan) (France)] /DA (/Helv 12 Tf 0 g) /V (Japan)", box(140, 465, 160, 22))
    widget(17, "/FT /Ch /T (fruit) /Opt [(Apple) (Banana) (Cherry) (Durian)] /DA (/Helv 12 Tf 0 g)", box(140, 360, 160, 60))
    widget(18, "/FT /Tx /T (fixed) /Ff 1 /DA (/Helv 12 Tf 0 g) /V (Cannot change)", box(140, 325, 200, 22))

    obj(3, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [{' '.join(f'{n} 0 R' for n in annots)}] >>".encode())
    fields = [10, 11, 12, 13, 16, 17, 18]
    obj(6, f"<< /Fields [{' '.join(f'{n} 0 R' for n in fields)}] /NeedAppearances true /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R /ZaDb 21 0 R >> >> >>".encode())

    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for n in sorted(objects):
        offsets[n] = len(out)
        out += f"{n} 0 obj\n".encode() + objects[n] + b"\nendobj\n"
    size = max(objects) + 1
    xref = len(out)
    out += f"xref\n0 {size}\n0000000000 65535 f \n".encode()
    for n in range(1, size):
        out += (f"{offsets[n]:010d} 00000 n \n" if n in offsets else "0000000000 65535 f \n").encode()
    out += f"trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    Path(path).write_bytes(bytes(out))


if __name__ == "__main__":
    write(Path(sys.argv[1]))
