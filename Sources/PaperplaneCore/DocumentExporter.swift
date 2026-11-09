import AppKit
import PDFKit

public enum PageImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }
}

public enum DocumentExportError: LocalizedError, Equatable {
    case invalidPageRange(pageCount: Int)
    case unableToWrite

    public var errorDescription: String? {
        switch self {
        case let .invalidPageRange(pageCount):
            return L("Enter pages such as 1-3, 5 or 8-, between 1 and %ld.", pageCount)
        case .unableToWrite:
            return L("The exported file couldn’t be written.")
        }
    }
}

/// Writing PDF copies and rendering pages to images.
public enum DocumentExporter {
    /// Writes a copy of the document. Flattening draws the annotations into
    /// the page content, so they look the same everywhere but can no longer be
    /// edited.
    public static func writeCopy(of document: PDFDocument, to url: URL, flattenAnnotations: Bool) throws {
        let options: [PDFDocumentWriteOption: Any] = flattenAnnotations ? [.burnInAnnotationsOption: true] : [:]
        guard document.write(to: url, withOptions: options) else { throw DocumentExportError.unableToWrite }
    }

    /// Renders a page, with its annotations and rotation, on white at `dpi`.
    public static func imageData(for page: PDFPage, dpi: CGFloat, format: PageImageFormat) -> Data? {
        // `draw(with:to:)` applies the page's rotation itself; only the image
        // size has to follow it.
        let box = page.bounds(for: .cropBox)
        let rotated = box.applying(page.transform(for: .cropBox)).standardized
        let scale = dpi / 72
        let width = Int((rotated.width * scale).rounded())
        let height = Int((rotated.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png:
            return representation.representation(using: .png, properties: [:])
        case .jpeg:
            return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }
}

public enum PageRangeParser {
    /// Zero-based page indexes, in document order without repeats, from text
    /// such as "1-3, 5, 8-" ("8-" runs to the last page). Accepts full-width
    /// commas and dashes as typed with a Chinese input method.
    public static func pages(from text: String, pageCount: Int) throws -> [Int] {
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "－", with: "-")
        let parts = normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, pageCount > 0 else { throw DocumentExportError.invalidPageRange(pageCount: pageCount) }
        var pages = IndexSet()
        for part in parts {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let first: Int?
            let last: Int?
            switch bounds.count {
            case 1:
                first = Int(bounds[0])
                last = first
            case 2:
                first = Int(bounds[0])
                last = bounds[1].isEmpty ? pageCount : Int(bounds[1])
            default:
                first = nil
                last = nil
            }
            guard let first, let last, first >= 1, last <= pageCount, first <= last else {
                throw DocumentExportError.invalidPageRange(pageCount: pageCount)
            }
            pages.insert(integersIn: (first - 1)..<last)
        }
        return Array(pages)
    }
}
