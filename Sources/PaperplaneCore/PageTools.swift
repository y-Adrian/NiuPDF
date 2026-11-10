import AppKit
import PDFKit

/// Margins as seen on screen, in points: after the page's rotation.
public struct PageMargins: Equatable, Sendable {
    public var top: CGFloat
    public var right: CGFloat
    public var bottom: CGFloat
    public var left: CGFloat

    public init(top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public static let zero = PageMargins()

    /// Top, right, bottom, left.
    var clockwise: [CGFloat] { [top, right, bottom, left] }

    init(clockwise values: [CGFloat]) {
        self.init(top: values[0], right: values[1], bottom: values[2], left: values[3])
    }
}

/// Cropping pages: a crop box inside the media box, from margins measured on
/// the page as it is shown, so a rotated page crops the edge the user sees.
public enum PageCropper {
    /// The crop box that leaves `margins` (as shown) off `mediaBox`, or nil
    /// when nothing would be left.
    public static func cropBox(mediaBox: CGRect, rotation: Int, margins: PageMargins) -> CGRect? {
        let page = unrotated(margins, rotation: rotation)
        // Checked before making the rect: CGRect reports negative sizes as positive.
        let width = mediaBox.width - page.left - page.right
        let height = mediaBox.height - page.top - page.bottom
        guard width >= 18, height >= 18 else { return nil }
        return CGRect(x: mediaBox.minX + page.left, y: mediaBox.minY + page.bottom, width: width, height: height).integral
    }

    /// The margins (as shown) between `mediaBox` and `cropBox`.
    public static func margins(mediaBox: CGRect, cropBox: CGRect, rotation: Int) -> PageMargins {
        let crop = cropBox.intersection(mediaBox)
        let page = PageMargins(
            top: mediaBox.maxY - crop.maxY,
            right: mediaBox.maxX - crop.maxX,
            bottom: crop.minY - mediaBox.minY,
            left: crop.minX - mediaBox.minX
        )
        return rotated(page, rotation: rotation)
    }

    /// Margins (as shown) that trim the white space around the page's
    /// content, keeping `padding` points; nil for a blank page.
    public static func contentMargins(of page: PDFPage, padding: CGFloat = 6) -> PageMargins? {
        let media = page.bounds(for: .mediaBox)
        // Two pixels per point is enough to find content edges.
        let scale: CGFloat = 2
        let width = Int(media.width * scale), height = Int(media.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -media.minX, y: -media.minY)
        // Unrotated: the margins are measured in page space, then turned.
        let rotation = page.rotation
        page.rotation = 0
        page.draw(with: .mediaBox, to: context)
        page.rotation = rotation

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            let line = pixels + row * width
            for column in 0..<width where line[column] < 245 {
                minX = min(minX, column); maxX = max(maxX, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run from the top of the page.
        let content = CGRect(
            x: media.minX + CGFloat(minX) / scale,
            y: media.minY + CGFloat(height - 1 - maxRow) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxRow - minRow + 1) / scale
        ).insetBy(dx: -padding, dy: -padding).intersection(media)
        return margins(mediaBox: media, cropBox: content, rotation: rotation)
    }

    /// Shown edges are the page's edges turned clockwise by the rotation.
    private static func unrotated(_ shown: PageMargins, rotation: Int) -> PageMargins {
        let steps = ((rotation / 90) % 4 + 4) % 4
        let values = shown.clockwise
        return PageMargins(clockwise: (0..<4).map { values[($0 + steps) % 4] })
    }

    private static func rotated(_ page: PageMargins, rotation: Int) -> PageMargins {
        let steps = ((rotation / 90) % 4 + 4) % 4
        let values = page.clockwise
        return PageMargins(clockwise: (0..<4).map { values[($0 - steps + 4) % 4] })
    }
}

/// Which pages go into which file when a document is split.
public enum DocumentSplitter {
    /// Consecutive groups of `size` pages; the last may be shorter.
    public static func groups(every size: Int, pageCount: Int) -> [[Int]] {
        guard size > 0, pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: size).map { Array($0..<min($0 + size, pageCount)) }
    }

    /// One file per comma-separated part of text such as "1-3, 4-8, 9-":
    /// each part is a range as in `PageRangeParser`.
    public static func groups(from text: String, pageCount: Int) throws -> [[Int]] {
        let normalized = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
        let parts = normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw DocumentExportError.invalidPageRange(pageCount: pageCount) }
        return try parts.map { try PageRangeParser.pages(from: $0, pageCount: pageCount) }
    }

    /// "1-3" or "4" for naming a part's file.
    public static func label(for group: [Int]) -> String {
        guard let first = group.first, let last = group.last else { return "" }
        return first == last ? "\(first + 1)" : "\(first + 1)-\(last + 1)"
    }
}
