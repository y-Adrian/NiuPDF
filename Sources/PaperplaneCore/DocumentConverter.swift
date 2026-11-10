import AppKit
import PDFKit

/// The text formats a document's text can be saved in.
public enum TextExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case richText
    case word

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .richText: "rtf"
        case .word: "docx"
        }
    }
}

public enum DocumentConversionError: LocalizedError, Equatable {
    case noText
    case unreadableImage(String)

    public var errorDescription: String? {
        switch self {
        case .noText:
            return L("These pages have no text to export. Scanned pages need text recognition first.")
        case let .unreadableImage(name):
            return L("“%@” couldn’t be read as an image.", name)
        }
    }
}

/// Converting between PDF and other formats: a document's text to plain or
/// rich text or Word, and images to PDF pages.
public enum DocumentConverter {
    /// The text of `pages` (all when nil), page after page. Rich text and Word
    /// keep the fonts, sizes and colors PDFKit reads, and start each page on a
    /// new page; the layout of the PDF is not kept.
    public static func textData(of document: PDFDocument, pages: [Int]? = nil, format: TextExportFormat) throws -> Data {
        let indexes = (pages ?? Array(0..<document.pageCount)).filter { $0 >= 0 && $0 < document.pageCount }
        if format == .plainText {
            let texts = indexes.map { document.page(at: $0)?.string ?? "" }
            guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw DocumentConversionError.noText
            }
            return Data(texts.joined(separator: "\n\n").utf8)
        }
        let text = NSMutableAttributedString()
        for (position, index) in indexes.enumerated() {
            if position > 0 { text.append(NSAttributedString(string: "\n\u{000C}")) }
            if let page = document.page(at: index)?.attributedString { text.append(page) }
        }
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{000C}"))).isEmpty else {
            throw DocumentConversionError.noText
        }
        let type: NSAttributedString.DocumentType = format == .word ? .officeOpenXML : .rtf
        return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
    }
}

extension DocumentConverter {
    /// `name` in `folder`, numbered ("name 2.pdf") when a file of that name
    /// exists, so nothing is replaced.
    public static func unusedURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number)" + (pathExtension.isEmpty ? "" : "." + pathExtension))
            number += 1
        }
        return url
    }
}

/// The page size for images made into PDF pages.
public enum ImagePageSize: String, CaseIterable, Identifiable, Sendable {
    /// The image's own size, from its pixels and resolution.
    case image
    case a4
    case letter

    public var id: String { rawValue }

    /// The page for an image of `size`: turned to landscape for a wide image.
    func mediaBox(for size: CGSize) -> CGRect? {
        let portrait: CGSize
        switch self {
        case .image: return nil
        case .a4: portrait = CGSize(width: 595, height: 842)
        case .letter: portrait = CGSize(width: 612, height: 792)
        }
        let landscape = size.width > size.height
        return CGRect(origin: .zero, size: landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait)
    }
}

extension DocumentConverter {
    /// A page showing the image file at `url`, turned as its orientation says,
    /// fitted into the page size (the whole page when the size is the image's).
    public static func page(fromImageAt url: URL, size: ImagePageSize) throws -> PDFPage {
        guard let data = try? Data(contentsOf: url) else { throw DocumentConversionError.unreadableImage(url.lastPathComponent) }
        return try page(fromImageData: data, named: url.lastPathComponent, size: size)
    }

    /// As `page(fromImageAt:size:)`, for an image already read; `name` is for errors.
    public static func page(fromImageData data: Data, named name: String, size: ImagePageSize) throws -> PDFPage {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
            throw DocumentConversionError.unreadableImage(name)
        }
        // With options, even empty ones, PDFKit sizes the page by the pixels
        // and ignores the image's resolution.
        let page = size.mediaBox(for: image.size).map { PDFPage(image: image, options: [.mediaBox: $0]) } ?? PDFPage(image: image)
        guard let page else { throw DocumentConversionError.unreadableImage(name) }
        return page
    }
}
