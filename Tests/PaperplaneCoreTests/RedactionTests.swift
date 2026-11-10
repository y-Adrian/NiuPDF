import AppKit
import PDFKit
import XCTest
@testable import PaperplaneCore

final class RedactionTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }

    func testRedactedTextIsGoneAndTheRestIsSearchable() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        // The second line, "Existing underline must toggle off without damage."
        let secret = try XCTUnwrap(document.findString("underline must toggle", withOptions: []).first)
        let area = secret.bounds(for: page).insetBy(dx: -2, dy: -2)

        let redacted = try Redactor.redactedPage(from: page, areas: [area], dpi: 200, recognizingText: true)
        XCTAssertEqual(redacted.rotation, 90)
        XCTAssertEqual(redacted.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
        XCTAssertTrue(redacted.annotations.isEmpty, "Annotations are not part of the picture.")

        let written = PDFDocument()
        written.insert(redacted, at: 0)
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(written.dataRepresentation())))
        XCTAssertTrue(reopened.findString("must toggle", withOptions: []).isEmpty, "The redacted words are gone.")
        XCTAssertFalse(reopened.findString("five highlight colors", withOptions: []).isEmpty, "The rest is recognized again.")
        // Black where the words were.
        let data = try XCTUnwrap(DocumentExporter.imageData(for: try XCTUnwrap(reopened.page(at: 0)), dpi: 72, format: .png))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        // Turned 90° clockwise: page point (x, y) is shown at (y, x).
        let color = try XCTUnwrap(image.colorAt(x: Int(area.midY), y: Int(area.midX)))
        XCTAssertLessThan(color.brightnessComponent, 0.1)
    }

    func testWithoutRecognitionThereIsNoText() throws {
        let page = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf"))?.page(at: 0))
        let redacted = try Redactor.redactedPage(from: page, areas: [], dpi: 72, recognizingText: false)
        XCTAssertFalse(TextRecognizer.hasText(redacted))
    }
}
