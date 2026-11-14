import Foundation
import PDFKit
import XCTest
@testable import PaperplaneCore

final class SafePDFFileStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-safe-save-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSaveReplacesOnlyAfterVerifiedTemporaryCopy() throws {
        let source = fixture("existing-annotation.pdf")
        let originalSourceBytes = try Data(contentsOf: source)
        let target = temporaryDirectory.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: source, to: target)
        let (document, revision) = try SafePDFFileStore.read(from: target)
        let marker = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 50, height: 15), forType: .underline, withProperties: nil)
        marker.contents = "safe save probe"
        document.page(at: 0)?.addAnnotation(marker)

        _ = try SafePDFFileStore.save(document, to: target, expectedRevision: revision)

        let reopened = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { $0.type == "Underline" }.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).contains("copy.pdf"))
        XCTAssertEqual(try Data(contentsOf: source), originalSourceBytes, "The corpus fixture must remain untouched.")
    }

    func testSaveRefusesToOverwriteExternalChange() throws {
        let target = temporaryDirectory.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: fixture("existing-annotation.pdf"), to: target)
        let (document, revision) = try SafePDFFileStore.read(from: target)
        let outsideChange = Data("external writer change".utf8)
        try outsideChange.write(to: target, options: .atomic)

        XCTAssertThrowsError(try SafePDFFileStore.save(document, to: target, expectedRevision: revision)) { error in
            XCTAssertEqual(error as? SafePDFFileStoreError, .externallyChanged)
        }
        XCTAssertEqual(try Data(contentsOf: target), outsideChange)
    }

    /// The App Sandbox grants access to the file the user chose, not to its
    /// folder; a read-only folder around a writable file reproduces that.
    func testSaveWorksWhenOnlyTheFileIsWritable() throws {
        let folder = temporaryDirectory.appendingPathComponent("file-only-access", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: fixture("existing-annotation.pdf"), to: target)
        let (document, revision) = try SafePDFFileStore.read(from: target)
        let marker = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 50, height: 15), forType: .underline, withProperties: nil)
        document.page(at: 0)?.addAnnotation(marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let newRevision = try SafePDFFileStore.save(document, to: target, expectedRevision: revision)

        let reopened = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { $0.type == "Underline" }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["copy.pdf"], "No temporary file may be left behind.")
        XCTAssertEqual(try PDFFileRevision(url: target), newRevision)
    }

    func testSaveDataWritesAndReportsRevision() throws {
        let target = temporaryDirectory.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: fixture("existing-annotation.pdf"), to: target)
        let (document, revision) = try SafePDFFileStore.read(from: target)
        let marker = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 50, height: 15), forType: .underline, withProperties: nil)
        marker.contents = "data path probe"
        document.page(at: 0)?.addAnnotation(marker)
        let data = try XCTUnwrap(document.dataRepresentation())

        let newRevision = try SafePDFFileStore.save(data: data, to: target, expectedRevision: revision, pageCount: document.pageCount)

        let reopened = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { $0.type == "Underline" }.count, 1)
        XCTAssertEqual(try PDFFileRevision(url: target), newRevision)
    }

    func testSaveDataRefusesToOverwriteExternalChange() throws {
        let target = temporaryDirectory.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: fixture("existing-annotation.pdf"), to: target)
        let (document, revision) = try SafePDFFileStore.read(from: target)
        let data = try XCTUnwrap(document.dataRepresentation())
        let outsideChange = Data("external writer change".utf8)
        try outsideChange.write(to: target, options: .atomic)

        XCTAssertThrowsError(try SafePDFFileStore.save(data: data, to: target, expectedRevision: revision, pageCount: document.pageCount)) { error in
            XCTAssertEqual(error as? SafePDFFileStoreError, .externallyChanged)
        }
        XCTAssertEqual(try Data(contentsOf: target), outsideChange)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }
}
