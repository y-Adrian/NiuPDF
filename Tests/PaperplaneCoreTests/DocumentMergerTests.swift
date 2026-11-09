import PDFKit
import XCTest
@testable import PaperplaneCore

final class DocumentMergerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-merge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testMergeKeepsOrderRangesAndAnnotations() throws {
        let marked = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let annotationCount = try XCTUnwrap(marked.page(at: 0)?.annotations.count)
        XCTAssertGreaterThan(annotationCount, 0)
        let large = try XCTUnwrap(PDFDocument(url: fixture("large-501-pages.pdf")))
        let largeText = { (index: Int) in large.page(at: index)?.string ?? "" }

        let url = temporaryDirectory.appendingPathComponent("merged.pdf")
        try DocumentMerger.write([
            MergeSource(document: large, pages: [4, 2]),
            MergeSource(document: marked, pages: [0]),
            MergeSource(document: large, pages: [0, 999, -1])
        ], to: url)

        let merged = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(merged.pageCount, 4, "Out-of-range pages are skipped.")
        XCTAssertEqual(merged.page(at: 0)?.string, largeText(4))
        XCTAssertEqual(merged.page(at: 1)?.string, largeText(2))
        // PDFPage.copy() adds a popup to each note; it must not become an extra annotation.
        XCTAssertEqual(merged.page(at: 2)?.annotations.map(\.type), marked.page(at: 0)?.annotations.map(\.type))
        XCTAssertEqual(merged.page(at: 2)?.annotations.map(\.contents), marked.page(at: 0)?.annotations.map(\.contents))
        XCTAssertEqual(merged.page(at: 3)?.string, largeText(0))
        XCTAssertEqual(large.pageCount, 501, "Merging must not change the sources.")
        XCTAssertEqual(marked.page(at: 0)?.annotations.count, annotationCount)
    }

    func testEmptyMergeIsNotWritten() {
        let url = temporaryDirectory.appendingPathComponent("empty.pdf")
        XCTAssertThrowsError(try DocumentMerger.write([], to: url)) { error in
            XCTAssertEqual(error as? DocumentExportError, .unableToWrite)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }
}
