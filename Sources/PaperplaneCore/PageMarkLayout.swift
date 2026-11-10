import CoreGraphics
import Foundation

/// A color as stored with a watermark or header: sRGB components.
public struct MarkColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = MarkColor(red: 0, green: 0, blue: 0)
    public static let gray = MarkColor(red: 0.5, green: 0.5, blue: 0.5)
}

/// Where a header or footer text sits, as the page is shown.
public enum MarkPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight

    public var isTop: Bool { [.topLeft, .topCenter, .topRight].contains(self) }
}

/// Headers and footers, page numbers among them. Texts may hold the tokens
/// below; date and file name are fixed when the header is applied, so a page
/// shows the same text after reopening.
public struct HeaderFooterSettings: Codable, Hashable, Sendable {
    public static let pageToken = "{page}"
    public static let pageCountToken = "{pages}"
    public static let dateToken = "{date}"
    public static let fileToken = "{file}"

    /// Text by position; empty or missing positions show nothing.
    public var texts: [MarkPosition: String] = [:]
    public var fontSize: Double = 10
    public var color: MarkColor = .black
    /// Distance from the shown page edges, in points.
    public var margin: Double = 28
    /// The number shown on the first page that gets the header.
    public var firstNumber: Int = 1
    /// Page range text as in `PageRangeParser`; empty for all pages.
    public var pages: String = ""
    public var date: String = ""
    public var fileName: String = ""

    public init() {}

    public var isEmpty: Bool {
        texts.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The text at `position` with its tokens filled in. `ordinal` counts the
    /// pages with this header from 0; `count` is how many there are.
    public func text(at position: MarkPosition, ordinal: Int, count: Int) -> String {
        (texts[position] ?? "")
            .replacingOccurrences(of: Self.pageToken, with: "\(firstNumber + ordinal)")
            .replacingOccurrences(of: Self.pageCountToken, with: "\(firstNumber + max(count, 1) - 1)")
            .replacingOccurrences(of: Self.dateToken, with: date)
            .replacingOccurrences(of: Self.fileToken, with: fileName)
    }

    /// Whether some text changes with the page's place in the document.
    public var isNumbered: Bool {
        texts.values.contains { $0.contains(Self.pageToken) || $0.contains(Self.pageCountToken) }
    }

    // Positions are encoded as a plain object of strings.
    private enum CodingKeys: String, CodingKey {
        case texts, fontSize, color, margin, firstNumber, pages, date, fileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
        texts = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in MarkPosition(rawValue: key).map { ($0, value) } })
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 10
        color = try container.decodeIfPresent(MarkColor.self, forKey: .color) ?? .black
        margin = try container.decodeIfPresent(Double.self, forKey: .margin) ?? 28
        firstNumber = try container.decodeIfPresent(Int.self, forKey: .firstNumber) ?? 1
        pages = try container.decodeIfPresent(String.self, forKey: .pages) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: texts.map { ($0.key.rawValue, $0.value) }), forKey: .texts)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(color, forKey: .color)
        try container.encode(margin, forKey: .margin)
        try container.encode(firstNumber, forKey: .firstNumber)
        try container.encode(pages, forKey: .pages)
        try container.encode(date, forKey: .date)
        try container.encode(fileName, forKey: .fileName)
    }
}

/// A text or image laid over pages.
public struct WatermarkSettings: Codable, Hashable, Sendable {
    public var usesImage = false
    public var text = ""
    public var fontSize: Double = 60
    public var color: MarkColor = .gray
    public var opacity: Double = 0.3
    /// Counterclockwise, in degrees, as the page is shown.
    public var angle: Double = 45
    /// An image's width as a share of the shown page width.
    public var imageScale: Double = 0.5
    /// Repeats the watermark over the whole page.
    public var tiled = false
    /// Page range text as in `PageRangeParser`; empty for all pages.
    public var pages = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WatermarkSettings()
        usesImage = try container.decodeIfPresent(Bool.self, forKey: .usesImage) ?? defaults.usesImage
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? defaults.text
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        color = try container.decodeIfPresent(MarkColor.self, forKey: .color) ?? defaults.color
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? defaults.opacity
        angle = try container.decodeIfPresent(Double.self, forKey: .angle) ?? defaults.angle
        imageScale = try container.decodeIfPresent(Double.self, forKey: .imageScale) ?? defaults.imageScale
        tiled = try container.decodeIfPresent(Bool.self, forKey: .tiled) ?? defaults.tiled
        pages = try container.decodeIfPresent(String.self, forKey: .pages) ?? defaults.pages
    }
}

/// Where watermarks and headers go on a page. Layout happens in shown space:
/// the page as displayed, after its rotation, with the origin at its bottom
/// left. `transform` maps shown space to page space.
public struct PageMarkLayout: Equatable, Sendable {
    public let cropBox: CGRect
    public let rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        self.rotation = ((rotation % 360) + 360) % 360
    }

    private var isSideways: Bool { rotation == 90 || rotation == 270 }

    /// The page size as shown.
    public var shownSize: CGSize {
        isSideways ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
    }

    /// Shown space to page space. A page shown turned clockwise by the
    /// rotation needs its marks turned counterclockwise by the same angle.
    public var transform: CGAffineTransform {
        // Exact quarter turns: sine and cosine would leave rounding errors.
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: cropBox.maxX, ty: cropBox.minY)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: cropBox.maxX, ty: cropBox.maxY)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: cropBox.minX, ty: cropBox.maxY)
        default: CGAffineTransform(translationX: cropBox.minX, y: cropBox.minY)
        }
    }

    /// The shown rect of a header or footer text of `size`.
    public func rect(for position: MarkPosition, size: CGSize, margin: CGFloat) -> CGRect {
        let shown = shownSize
        let x: CGFloat
        switch position {
        case .topLeft, .bottomLeft: x = margin
        case .topCenter, .bottomCenter: x = (shown.width - size.width) / 2
        case .topRight, .bottomRight: x = shown.width - margin - size.width
        }
        let y = position.isTop ? shown.height - margin - size.height : margin
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// `rect` in shown space as an annotation's bounds in page space.
    public func pageRect(_ rect: CGRect) -> CGRect {
        rect.applying(transform).integral
    }

    /// Centers, in shown space, for a watermark of `size` turned by `angle`
    /// degrees: the middle of the page, or a grid covering it when tiled.
    public func watermarkCenters(size: CGSize, angle: Double, tiled: Bool) -> [CGPoint] {
        let shown = shownSize
        let middle = CGPoint(x: shown.width / 2, y: shown.height / 2)
        guard tiled else { return [middle] }
        // The extent of the turned watermark, plus a gap of half its height.
        let radians = angle * .pi / 180
        let width = abs(size.width * cos(radians)) + abs(size.height * sin(radians))
        let height = abs(size.width * sin(radians)) + abs(size.height * cos(radians))
        let gap = max(size.height, 12)
        let stepX = max(width + gap, 24), stepY = max(height + gap, 24)
        var centers: [CGPoint] = []
        // Rows are offset by half a step, as in a brick wall, and run past the
        // edges so the corners are covered.
        let rows = Int((shown.height / stepY).rounded(.up)) + 1
        let columns = Int((shown.width / stepX).rounded(.up)) + 1
        for row in -rows...rows {
            let offset = row.isMultiple(of: 2) ? 0 : stepX / 2
            for column in -columns...columns {
                let point = CGPoint(x: middle.x + CGFloat(column) * stepX + offset, y: middle.y + CGFloat(row) * stepY)
                if point.x > -width / 2, point.x < shown.width + width / 2, point.y > -height / 2, point.y < shown.height + height / 2 {
                    centers.append(point)
                }
            }
        }
        return centers
    }
}
