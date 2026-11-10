import Foundation
import PDFKit
import XCTest
@testable import PaperplaneCore

final class PDFPasswordSettingsTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testProblems() {
        XCTAssertEqual(PDFPasswordSettings().problem, .nothingToProtect)
        XCTAssertNil(PDFPasswordSettings(openPassword: "a").problem)
        XCTAssertEqual(PDFPasswordSettings(restrictsPermissions: true).problem, .missingPermissionsPassword)
        XCTAssertEqual(PDFPasswordSettings(openPassword: "a", restrictsPermissions: true, permissionsPassword: "a").problem, .samePasswords)
        XCTAssertNil(PDFPasswordSettings(restrictsPermissions: true, permissionsPassword: "b").problem)
        XCTAssertNil(PDFPasswordSettings(openPassword: "", restrictsPermissions: false, permissionsPassword: "ignored").writeOptions)
    }

    func testOpenPasswordAloneEncryptsWithFullAccessOnceOpened() throws {
        let url = try save(PDFPasswordSettings(openPassword: "open"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.isEncrypted)
        XCTAssertTrue(document.isLocked)
        XCTAssertFalse(document.unlock(withPassword: "wrong"))
        XCTAssertTrue(document.unlock(withPassword: "open"))
        XCTAssertEqual(document.permissionsStatus, .owner)
        XCTAssertEqual(document.page(at: 0)?.annotations.filter { $0.type == "Square" }.count, 1)
    }

    func testRestrictionsNeedThePermissionsPassword() throws {
        let settings = PDFPasswordSettings(openPassword: "open", restrictsPermissions: true, permissionsPassword: "owner",
                                           allowsPrinting: true, allowsCopying: false, allowsCommenting: false, allowsChanges: false)
        let url = try save(settings)
        let reader = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(reader.isLocked)
        XCTAssertTrue(reader.unlock(withPassword: "open"))
        XCTAssertEqual(reader.permissionsStatus, .user)
        XCTAssertTrue(reader.allowsPrinting)
        XCTAssertFalse(reader.allowsCopying)
        XCTAssertFalse(reader.allowsCommenting)
        XCTAssertFalse(reader.allowsDocumentChanges)
        XCTAssertFalse(reader.allowsDocumentAssembly)

        let owner = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(owner.unlock(withPassword: "owner"))
        XCTAssertEqual(owner.permissionsStatus, .owner)
        XCTAssertTrue(owner.allowsCommenting)
    }

    func testRestrictionsWithoutOpenPasswordOpenFreely() throws {
        let url = try save(PDFPasswordSettings(restrictsPermissions: true, permissionsPassword: "owner", allowsCommenting: true))
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.isEncrypted)
        XCTAssertFalse(document.isLocked)
        XCTAssertEqual(document.permissionsStatus, .user)
        XCTAssertTrue(document.allowsCommenting)
        XCTAssertFalse(document.allowsDocumentAssembly)
    }

    func testSavingAgainKeepsPasswordsAndRemovalDropsThem() throws {
        let url = try save(PDFPasswordSettings(openPassword: "open"))
        var (document, revision) = try SafePDFFileStore.read(from: url)
        XCTAssertTrue(document.unlock(withPassword: "open"))
        document.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 20, height: 20), forType: .circle, withProperties: nil))
        revision = try SafePDFFileStore.save(document, to: url, expectedRevision: revision)

        let resaved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(resaved.isLocked, "A plain save keeps the password.")
        XCTAssertTrue(resaved.unlock(withPassword: "open"))
        XCTAssertEqual(resaved.page(at: 0)?.annotations.filter { $0.type == "Circle" }.count, 1)

        (document, revision) = try SafePDFFileStore.read(from: url)
        XCTAssertTrue(document.unlock(withPassword: "open"))
        try SafePDFFileStore.save(document, to: url, expectedRevision: revision, writeOptions: PDFPasswordSettings.removalOptions)
        let removed = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertFalse(removed.isLocked)
        XCTAssertTrue(removed.allowsCommenting && removed.allowsDocumentAssembly && removed.allowsCopying && removed.allowsPrinting)
        XCTAssertEqual(removed.page(at: 0)?.annotations.filter { $0.type == "Circle" }.count, 1)
    }

    /// Writes a copy of a fixture, with one added square, under `settings`.
    private func save(_ settings: PDFPasswordSettings) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: fixture("markup-regression.pdf"), to: url)
        let (document, revision) = try SafePDFFileStore.read(from: url)
        document.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 30, height: 30), forType: .square, withProperties: nil))
        try SafePDFFileStore.save(document, to: url, expectedRevision: revision, writeOptions: try XCTUnwrap(settings.writeOptions))
        return url
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }
}
