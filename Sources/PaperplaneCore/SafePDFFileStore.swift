import CryptoKit
import Foundation
import PDFKit

public struct PDFFileRevision: Equatable, Sendable {
    fileprivate let digest: Data

    public init(url: URL) throws {
        digest = try Self.digest(of: url)
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
        case let .coordinationFailed(message):
            return L("Couldn’t safely coordinate file access: %@", message)
        }
    }
}

/// File coordination, revision checking, and verified same-directory replacement.
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
                guard let document = PDFDocument(url: coordinatedURL), document.pageCount > 0 else {
                    throw SafePDFFileStoreError.unreadablePDF
                }
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

    @discardableResult
    public static func save(
        _ document: PDFDocument,
        to url: URL,
        expectedRevision: PDFFileRevision
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

                let candidate = coordinatedURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(coordinatedURL.lastPathComponent).paperplane-\(UUID().uuidString).tmp.pdf")
                temporaryURL = candidate
                guard document.write(to: candidate) else {
                    throw SafePDFFileStoreError.unableToWriteTemporary
                }
                guard let reopened = PDFDocument(url: candidate),
                      reopened.pageCount == document.pageCount else {
                    throw SafePDFFileStoreError.invalidTemporaryCopy
                }

                // Recheck immediately before replacement while the coordinated
                // write claim is held, in case the writer changed the source.
                guard try PDFFileRevision(url: coordinatedURL) == expectedRevision else {
                    throw SafePDFFileStoreError.externallyChanged
                }
                _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: candidate)
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
}
