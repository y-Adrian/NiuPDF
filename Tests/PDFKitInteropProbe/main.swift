import AppKit
import Foundation
import PDFKit

@main
enum PDFKitInteropProbe {
    static func main() {
        guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == "roundtrip" else {
            fail("Usage: PDFKitInteropProbe roundtrip <input.pdf> <new-output.pdf>")
        }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            fail("Refusing to overwrite the input PDF.")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            fail("Output must not exist. Refusing to overwrite: \(outputURL.path)")
        }
        guard let document = PDFDocument(url: inputURL), document.pageCount > 0 else {
            fail("PDFKit could not open the input: \(inputURL.lastPathComponent)")
        }

        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        let before = annotationCounts(in: pages)
        let highlightType = PDFAnnotationSubtype.highlight.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let underlineType = PDFAnnotationSubtype.underline.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard before[highlightType, default: 0] == 1 else {
            let foundTypes = pages.flatMap(\.annotations).map { String(describing: $0.type) }
            fail("Expected exactly one pre-existing highlight (PDFKit subtype=\(highlightType)); found \(before[highlightType, default: 0]), types=\(foundTypes).")
        }

        guard before[underlineType, default: 0] <= 1 else {
            fail("Expected at most one probe underline; found \(before[underlineType, default: 0]).")
        }
        if before[underlineType, default: 0] == 0 {
            // Add one standard annotation without changing the source fixture.
            let underline = PDFAnnotation(
                bounds: CGRect(x: 72, y: 684, width: 310, height: 15),
                forType: .underline,
                withProperties: nil
            )
            underline.color = .systemBlue
            underline.contents = "PDFKit interoperability probe"
            underline.userName = "Paperplane test"
            document.page(at: 0)?.addAnnotation(underline)
        }

        guard document.write(to: outputURL) else {
            fail("PDFKit failed to write the new output file.")
        }
        guard let reopened = PDFDocument(url: outputURL), reopened.pageCount == document.pageCount else {
            fail("PDFKit could not reopen the output or the page count changed.")
        }
        let after = annotationCounts(in: (0..<reopened.pageCount).compactMap(reopened.page(at:)))
        guard after[highlightType, default: 0] == 1, after[underlineType, default: 0] == 1 else {
            fail("Roundtrip changed annotation counts: highlights=\(after[highlightType, default: 0]), underlines=\(after[underlineType, default: 0]).")
        }
        print("PDFKit roundtrip passed: \(reopened.pageCount) pages, one existing highlight preserved, one standard underline preserved.")
    }

    private static func annotationCounts(in pages: [PDFPage]) -> [String: Int] {
        pages.reduce(into: [:]) { counts, page in
            for annotation in page.annotations {
                counts[annotation.type ?? "<unknown>", default: 0] += 1
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ERROR: \(message)\n", stderr)
        exit(1)
    }
}
