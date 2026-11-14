import CryptoKit
import Foundation
import PDFKit

public struct PDFFileRevision: Equatable, Sendable {
    fileprivate let digest: Data

    public init(url: URL) throws {
        digest = try Self.digest(of: url)
    }

    /// The revision of an in-memory PDF byte stream, so a save can report the
    /// new revision without reading the just-written file back from disk.
    fileprivate init(data: Data) {
        digest = Data(SHA256.hash(data: data))
    }

    fileprivate static func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

public enum SafePDFFileStoreError: LocalizedError, Equatable {
    case unreadablePDF
    case externallyChanged
    case unableToWriteTemporary
    case invalidTemporaryCopy
    case inPlaceWriteFailed(keptCopy: String)
    case coordinationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return L("The PDF file can’t be read.")
        case .externallyChanged:
            return L("The file was changed by another app after it was opened. To protect those changes, it was not overwritten. Reopen the file before editing it again.")
        case .unableToWriteTemporary:
            return L("Couldn’t write a temporary PDF. The original file is unchanged.")
        case .invalidTemporaryCopy:
            return L("The temporary PDF failed verification. The original file is unchanged.")
        case let .inPlaceWriteFailed(keptCopy):
            return L("Couldn’t finish writing the PDF. A verified copy of your changes was kept at %@.", keptCopy)
        case let .coordinationFailed(message):
            return L("Couldn’t safely coordinate file access: %@", message)
        }
    }
}

/// File coordination, revision checking, and verified replacement. A copy is
/// written and reopened before the original is touched. When the folder is
/// writable the copy sits beside the original and replaces it atomically; the
/// App Sandbox grants access to the chosen file only, so otherwise the copy is
/// made in the app's temporary folder and written over the original in place.
/// Callers keep the security-scoped URL access alive for the full operation.
public enum SafePDFFileStore {
    public static func read(from url: URL) throws -> (document: PDFDocument, revision: PDFFileRevision) {
        var result: (PDFDocument, PDFFileRevision)?
        var accessError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let revision = try PDFFileRevision(url: coordinatedURL)
                let rawData = try Data(contentsOf: coordinatedURL)
                // Drop a tagged PDF's structure so PDFKit does not re-resolve it
                // on every save; see StructureStripper. Fall back to the raw
                // bytes when the file is not tagged or cannot be stripped.
                let document: PDFDocument
                if let stripped = StructureStripper.strip(rawData), let doc = PDFDocument(data: stripped) {
                    document = doc
                } else if let doc = PDFDocument(data: rawData) {
                    document = doc
                } else {
                    throw SafePDFFileStoreError.unreadablePDF
                }
                guard document.pageCount > 0 else { throw SafePDFFileStoreError.unreadablePDF }
                result = (document, revision)
            } catch {
                accessError = error
            }
        }

        if let coordinationError {
            throw SafePDFFileStoreError.coordinationFailed("\(coordinationError.domain) (\(coordinationError.code)): \(coordinationError.localizedDescription)")
        }
        if let accessError { throw accessError }
        guard let result else { throw SafePDFFileStoreError.unreadablePDF }
        return result
    }

    /// Writes with options only when given: passwords and restrictions, or
    /// none at all to keep what the document already has.
    private static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]?) -> Bool {
        guard let options else { return document.write(to: url) }
        return document.write(to: url, withOptions: options)
    }

    @discardableResult
    public static func save(
        _ document: PDFDocument,
        to url: URL,
        expectedRevision: PDFFileRevision,
        writeOptions: [PDFDocumentWriteOption: Any]? = nil,
        repairingButtons buttons: [ButtonWidgetState] = []
    ) throws -> PDFFileRevision {
        var updatedRevision: PDFFileRevision?
        var operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            var temporaryURL: URL?
            do {
                guard try PDFFileRevision(url: coordinatedURL) == expectedRevision else {
                    throw SafePDFFileStoreError.externallyChanged
                }

                let beside = coordinatedURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(coordinatedURL.lastPathComponent).paperplane-\(UUID().uuidString).tmp.pdf")
                let replacesAtomically = write(document, to: beside, options: writeOptions)
                let candidate = replacesAtomically
                    ? beside
                    : FileManager.default.temporaryDirectory.appendingPathComponent("paperplane-\(UUID().uuidString).pdf")
                temporaryURL = candidate
                guard replacesAtomically || write(document, to: candidate, options: writeOptions) else {
                    throw SafePDFFileStoreError.unableToWriteTemporary
                }
                try ButtonFieldRepair.repairFile(at: candidate, buttons: buttons)
                guard let reopened = PDFDocument(url: candidate),
                      reopened.pageCount == document.pageCount else {
                    throw SafePDFFileStoreError.invalidTemporaryCopy
                }

                // Recheck immediately before replacement while the coordinated
                // write claim is held, in case the writer changed the source.
                guard try PDFFileRevision(url: coordinatedURL) == expectedRevision else {
                    throw SafePDFFileStoreError.externallyChanged
                }
                if replacesAtomically {
                    _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: candidate)
                } else {
                    do {
                        try overwrite(coordinatedURL, withContentsOf: candidate)
                    } catch {
                        // The original may be partly written; keep the verified copy.
                        temporaryURL = nil
                        throw SafePDFFileStoreError.inPlaceWriteFailed(keptCopy: candidate.path)
                    }
                    try? FileManager.default.removeItem(at: candidate)
                }
                temporaryURL = nil
                updatedRevision = try PDFFileRevision(url: coordinatedURL)
            } catch {
                operationError = error
            }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        if let coordinationError {
            throw SafePDFFileStoreError.coordinationFailed("\(coordinationError.domain) (\(coordinationError.code)): \(coordinationError.localizedDescription)")
        }
        if let operationError { throw operationError }
        guard let updatedRevision else { throw SafePDFFileStoreError.unreadablePDF }
        return updatedRevision
    }

    /// Saves an already-serialized PDF byte stream with the same coordination,
    /// revision checking and verified replacement as `save(_:to:...)`, but
    /// without touching a `PDFDocument`, so it can run on a background thread.
    /// The caller serializes the document on the main thread first.
    @discardableResult
    public static func save(
        data: Data,
        to url: URL,
        expectedRevision: PDFFileRevision,
        pageCount: Int,
        repairingButtons buttons: [ButtonWidgetState] = []
    ) throws -> PDFFileRevision {
        var updatedRevision: PDFFileRevision?
        var operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            var temporaryURL: URL?
            do {
                guard try PDFFileRevision(url: coordinatedURL) == expectedRevision else {
                    throw SafePDFFileStoreError.externallyChanged
                }

                let repaired = ButtonFieldRepair.repair(data, buttons: buttons) ?? data
                // Verify the bytes reopen as a PDF with the right number of
                // pages before the original is touched.
                guard let reopened = PDFDocument(data: repaired), reopened.pageCount == pageCount else {
                    throw SafePDFFileStoreError.invalidTemporaryCopy
                }

                let beside = coordinatedURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(coordinatedURL.lastPathComponent).paperplane-\(UUID().uuidString).tmp.pdf")
                let replacesAtomically: Bool
                let candidate: URL
                do {
                    try repaired.write(to: beside, options: .atomic)
                    replacesAtomically = true
                    candidate = beside
                } catch {
                    // The App Sandbox grants access to the chosen file only,
                    // so write to the temporary folder and replace in place.
                    replacesAtomically = false
                    candidate = FileManager.default.temporaryDirectory.appendingPathComponent("paperplane-\(UUID().uuidString).pdf")
                    try repaired.write(to: candidate, options: .atomic)
                }
                temporaryURL = candidate

                // Recheck immediately before replacement while the coordinated
                // write claim is held, in case the writer changed the source.
                guard try PDFFileRevision(url: coordinatedURL) == expectedRevision else {
                    throw SafePDFFileStoreError.externallyChanged
                }
                if replacesAtomically {
                    _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: candidate)
                } else {
                    do {
                        try overwrite(coordinatedURL, withContentsOf: candidate)
                    } catch {
                        // The original may be partly written; keep the verified copy.
                        temporaryURL = nil
                        throw SafePDFFileStoreError.inPlaceWriteFailed(keptCopy: candidate.path)
                    }
                    try? FileManager.default.removeItem(at: candidate)
                }
                temporaryURL = nil
                updatedRevision = PDFFileRevision(data: repaired)
            } catch {
                operationError = error
            }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        if let coordinationError {
            throw SafePDFFileStoreError.coordinationFailed("\(coordinationError.domain) (\(coordinationError.code)): \(coordinationError.localizedDescription)")
        }
        if let operationError { throw operationError }
        guard let updatedRevision else { throw SafePDFFileStoreError.unreadablePDF }
        return updatedRevision
    }

    private static func overwrite(_ url: URL, withContentsOf source: URL) throws {
        let data = try Data(contentsOf: source)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
