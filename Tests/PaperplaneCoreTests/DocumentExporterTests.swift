import AppKit
import PDFKit
import XCTest
@testable import PaperplaneCore

final class DocumentExporterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPageRanges() throws {
        XCTAssertEqual(try PageRangeParser.pages(from: "1-3, 5", pageCount: 10), [0, 1, 2, 4])
        XCTAssertEqual(try PageRangeParser.pages(from: "8-", pageCount: 10), [7, 8, 9])
        XCTAssertEqual(try PageRangeParser.pages(from: "5，1–2、2", pageCount: 10), [0, 1, 4], "Full-width separators, sorted, no repeats")
        for bad in ["", "0", "11", "3-1", "a", "1--2", "2-12"] {
            XCTAssertThrowsError(try PageRangeParser.pages(from: bad, pageCount: 10), bad) { error in
                XCTAssertEqual(error as? DocumentExportError, .invalidPageRange(pageCount: 10))
            }
        }
    }

    func testImageSizeFollowsResolutionAndRotation() throws {
        // Keep the document alive: PDFKit cannot draw a page whose document is gone.
        let document = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let page = try XCTUnwrap(document.page(at: 0))
        let box = page.bounds(for: .cropBox)

        let upright = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(DocumentExporter.imageData(for: page, dpi: 150, format: .png))))
        XCTAssertEqual(upright.pixelsWide, Int((box.width * 150 / 72).rounded()))
        XCTAssertEqual(upright.pixelsHigh, Int((box.height * 150 / 72).rounded()))
        XCTAssertTrue(hasDarkPixels(upright))

        page.rotation = 90
        let turned = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(DocumentExporter.imageData(for: page, dpi: 150, format: .png))))
        XCTAssertEqual(turned.pixelsWide, upright.pixelsHigh)
        XCTAssertEqual(turned.pixelsHigh, upright.pixelsWide)
        XCTAssertTrue(hasDarkPixels(turned), "The rotated page must still be drawn inside the image.")
    }

    func testJPEGOutput() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let page = try XCTUnwrap(document.page(at: 0))
        let data = try XCTUnwrap(DocumentExporter.imageData(for: page, dpi: 72, format: .jpeg))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }

    func testCopyKeepsOrFlattensAnnotations() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let annotationCount = try XCTUnwrap(document.page(at: 0)?.annotations.count)
        XCTAssertGreaterThan(annotationCount, 0)

        let kept = temporaryDirectory.appendingPathComponent("kept.pdf")
        try DocumentExporter.writeCopy(of: document, to: kept, flattenAnnotations: false)
        XCTAssertEqual(PDFDocument(url: kept)?.page(at: 0)?.annotations.count, annotationCount)

        let flat = temporaryDirectory.appendingPathComponent("flat.pdf")
        try DocumentExporter.writeCopy(of: document, to: flat, flattenAnnotations: true)
        let flattened = try XCTUnwrap(PDFDocument(url: flat))
        XCTAssertEqual(flattened.page(at: 0)?.annotations.count, 0)
        XCTAssertEqual(flattened.pageCount, document.pageCount)
        XCTAssertEqual(document.page(at: 0)?.annotations.count, annotationCount, "Exporting must not change the open document.")
    }

    private func hasDarkPixels(_ image: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                if let color = image.colorAt(x: x, y: y), color.brightnessComponent < 0.5 { return true }
            }
        }
        return false
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }
}
