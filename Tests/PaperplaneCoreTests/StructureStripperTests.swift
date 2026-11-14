import Foundation
import PDFKit
import XCTest
@testable import PaperplaneCore

final class StructureStripperTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-structure-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testStripRemovesStructureFromTaggedPDF() throws {
        let source = fixture("tagged.pdf")
        let data = try Data(contentsOf: source)
        let stripped = try XCTUnwrap(StructureStripper.strip(data), "A tagged PDF must be stripped.")

        let document = try XCTUnwrap(PDFDocument(data: stripped))
        XCTAssertEqual(document.pageCount, 1, "The stripped PDF must still open with its pages intact.")

        // After PDFKit re-serializes the stripped document, no structure remains.
        let reserialized = try XCTUnwrap(document.dataRepresentation())
        let text = String(data: reserialized, encoding: .isoLatin1) ?? ""
        XCTAssertFalse(text.contains("/StructTreeRoot"))
        XCTAssertFalse(text.contains("/MarkInfo"))
    }

    func testStripReturnsNilForUntaggedPDF() throws {
        let data = try Data(contentsOf: fixture("existing-annotation.pdf"))
        XCTAssertNil(StructureStripper.strip(data))
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }
}
