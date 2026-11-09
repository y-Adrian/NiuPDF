import PDFKit

/// Some pages of one document, in the order they go into a merge.
public struct MergeSource {
    public var document: PDFDocument
    public var pages: [Int]

    public init(document: PDFDocument, pages: [Int]) {
        self.document = document
        self.pages = pages
    }
}

/// Combining pages of several documents into a new one.
public enum DocumentMerger {
    /// A new document holding copies of the sources' pages, annotations
    /// included, in source order. Pages out of range are skipped. The sources
    /// are not changed, and the copies stay valid after they close.
    public static func merge(_ sources: [MergeSource]) -> PDFDocument {
        document(with: sources.flatMap(pageCopies(of:)))
    }

    /// Merges the sources and writes the result to `url`.
    public static func write(_ sources: [MergeSource], to url: URL) throws {
        try write(merge(sources), to: url)
    }

    /// Writes a merged document; an empty one is an error, not an empty file.
    public static func write(_ merged: PDFDocument, to url: URL) throws {
        guard merged.pageCount > 0, merged.write(to: url) else { throw DocumentExportError.unableToWrite }
    }

    /// Copies of a source's pages, in its order, skipping pages out of range.
    public static func pageCopies(of source: MergeSource) -> [PDFPage] {
        source.pages
            .filter { $0 >= 0 && $0 < source.document.pageCount }
            .compactMap { source.document.page(at: $0).flatMap(copy(of:)) }
    }

    /// A new document made of `pages`, which must not belong to a document yet.
    public static func document(with pages: [PDFPage]) -> PDFDocument {
        let merged = PDFDocument()
        for page in pages { merged.insert(page, at: merged.pageCount) }
        return merged
    }

    /// A copy of a page with its annotations. `PDFPage.copy()` gives each note
    /// a popup the original did not have, which would be written as an extra
    /// annotation; on a page that had no popups, they are removed. (Reading
    /// `popup` on the original is avoided: it can lose the note's text.)
    public static func copy(of page: PDFPage) -> PDFPage? {
        guard let copy = page.copy() as? PDFPage else { return nil }
        guard !page.annotations.contains(where: { $0.type == "Popup" }) else { return copy }
        for annotation in copy.annotations where annotation.type == "Popup" {
            copy.removeAnnotation(annotation)
        }
        return copy
    }
}
