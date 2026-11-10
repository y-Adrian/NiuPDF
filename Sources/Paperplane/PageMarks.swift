import AppKit
import PaperplaneCore
import PDFKit

/// A watermark, or one header or footer text, on one page. Like `ImageStamp`,
/// PDFKit writes what `draw` paints into the annotation's appearance, so any
/// reader shows it. On screen the page overlay draws it, as vectors, like
/// drawings and shapes (see `drawShown`). Its settings are kept under a marker key: after reopening,
/// text marks are made again from them, so page numbers follow page changes
/// and the marks can be changed or removed as a whole.
final class PageMark: PDFAnnotation {
    enum Kind {
        case watermark
        case headerFooter

        var markerKey: PDFAnnotationKey {
            switch self {
            case .watermark: PDFAnnotationKey(rawValue: "/PaperplaneWatermark")
            case .headerFooter: PDFAnnotationKey(rawValue: "/PaperplaneHeaderFooter")
            }
        }
    }

    /// What the marker key holds, as JSON.
    struct Record: Codable, Equatable {
        var watermark: WatermarkSettings?
        var headerFooter: HeaderFooterSettings?
        var position: MarkPosition?
    }

    let kind: Kind
    let record: Record
    /// A watermark's image; images are not kept in the record, so an image
    /// watermark from an earlier session stays a plain stamp.
    let image: CGImage?
    /// A header's text with its page number filled in.
    private(set) var text: String
    private(set) var layout: PageMarkLayout

    /// Print, ReadOnly and Locked: other readers neither move nor select it.
    private static let flags = 4 | 64 | 128

    private init(kind: Kind, record: Record, image: CGImage?, text: String, layout: PageMarkLayout) {
        self.kind = kind
        self.record = record
        self.image = image
        self.text = text
        self.layout = layout
        super.init(bounds: layout.cropBox, forType: .stamp, withProperties: nil)
        if let data = try? Self.encoder.encode(record), let json = String(data: data, encoding: .utf8) {
            setValue(json, forAnnotationKey: kind.markerKey)
        }
        setValue(NSNumber(value: Self.flags), forAnnotationKey: .flags)
        bounds = frame
    }

    static func watermark(_ settings: WatermarkSettings, image: CGImage?, on page: PDFPage) -> PageMark {
        PageMark(kind: .watermark, record: Record(watermark: settings), image: image, text: settings.text, layout: layout(of: page))
    }

    static func header(_ settings: HeaderFooterSettings, at position: MarkPosition, text: String, on page: PDFPage) -> PageMark {
        PageMark(kind: .headerFooter, record: Record(headerFooter: settings, position: position), image: nil, text: text, layout: layout(of: page))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `PDFPage.copy()` copies annotations with this; PDFKit's own copy would
    /// leave the stored properties unset and draw nothing.
    override func copy(with zone: NSZone? = nil) -> Any {
        PageMark(kind: kind, record: record, image: image, text: text, layout: layout)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func layout(of page: PDFPage) -> PageMarkLayout {
        PageMarkLayout(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    // MARK: Finding

    static func kind(of annotation: PDFAnnotation) -> Kind? {
        if let mark = annotation as? PageMark { return mark.kind }
        if annotation.value(forAnnotationKey: Kind.watermark.markerKey) != nil { return .watermark }
        if annotation.value(forAnnotationKey: Kind.headerFooter.markerKey) != nil { return .headerFooter }
        return nil
    }

    static func isPageMark(_ annotation: PDFAnnotation) -> Bool { kind(of: annotation) != nil }

    static func record(of annotation: PDFAnnotation) -> Record? {
        if let mark = annotation as? PageMark { return mark.record }
        guard let kind = kind(of: annotation),
              let json = annotation.value(forAnnotationKey: kind.markerKey) as? String else { return nil }
        return try? JSONDecoder().decode(Record.self, from: Data(json.utf8))
    }

    /// A live mark in place of a plain stamp read from the file, for text
    /// marks whose settings can be read.
    static func remade(from annotation: PDFAnnotation, on page: PDFPage) -> PageMark? {
        guard !(annotation is PageMark), let record = record(of: annotation) else { return nil }
        if let settings = record.headerFooter, let position = record.position {
            // The number is filled in by `refreshPageMarks`.
            return header(settings, at: position, text: settings.text(at: position, ordinal: 0, count: 1), on: page)
        }
        if let settings = record.watermark, !settings.usesImage {
            return watermark(settings, image: nil, on: page)
        }
        return nil
    }

    /// Draws the marks the overlay draws instead of PDFKit, for pictures of
    /// pages made with `PDFPage.draw` (thumbnails, slideshow, previews), which
    /// leave them out. The context is set up as `draw` left it for `box`.
    static func drawShown(on page: PDFPage, for box: PDFDisplayBox, in context: CGContext) {
        let marks = page.annotations.compactMap { $0 as? PageMark }.filter { !$0.shouldDisplay }
        guard !marks.isEmpty else { return }
        context.saveGState()
        context.concatenate(page.transform(for: box))
        for mark in marks { mark.drawContent(in: context) }
        context.restoreGState()
    }

    /// Set while PDFKit makes a thumbnail: it draws hidden annotations too,
    /// and turns them wrongly on turned pages, so marks are left to `thumbnail`.
    private static var isMakingThumbnail = false

    /// `PDFPage.thumbnail` with the marks drawn the right way round.
    static func thumbnail(of page: PDFPage, size: CGSize, for box: PDFDisplayBox) -> NSImage {
        guard page.annotations.contains(where: { $0 is PageMark && !$0.shouldDisplay }) else {
            return page.thumbnail(of: size, for: box)
        }
        isMakingThumbnail = true
        let plain = page.thumbnail(of: size, for: box)
        isMakingThumbnail = false
        let bounds = page.bounds(for: box)
        let shown = page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let imageSize = plain.size
        guard shown.width > 0, shown.height > 0, imageSize.width > 0, imageSize.height > 0 else { return plain }
        let image = NSImage(size: imageSize)
        image.lockFocus()
        plain.draw(in: CGRect(origin: .zero, size: imageSize))
        if let context = NSGraphicsContext.current?.cgContext {
            // The page is fitted into the thumbnail and centered.
            let scale = min(imageSize.width / shown.width, imageSize.height / shown.height)
            context.translateBy(x: (imageSize.width - shown.width * scale) / 2, y: (imageSize.height - shown.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            drawShown(on: page, for: box, in: context)
        }
        image.unlockFocus()
        return image
    }

    // MARK: Layout and drawing

    /// Follows a new page number, rotation or crop.
    func update(text: String, layout: PageMarkLayout) {
        guard text != self.text || layout != self.layout else { return }
        self.text = text
        self.layout = layout
        bounds = frame
    }

    func update(on page: PDFPage) {
        update(text: text, layout: Self.layout(of: page))
    }

    private var markFont: NSFont {
        switch kind {
        case .watermark: .systemFont(ofSize: CGFloat(record.watermark?.fontSize ?? 60), weight: .bold)
        case .headerFooter: .systemFont(ofSize: CGFloat(record.headerFooter?.fontSize ?? 10))
        }
    }

    private func attributedText(opacity: CGFloat = 1) -> NSAttributedString {
        let color = record.watermark?.color ?? record.headerFooter?.color ?? .black
        return NSAttributedString(string: text, attributes: [
            .font: markFont,
            .foregroundColor: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: opacity)
        ])
    }

    /// The size of one watermark or of the header text, in shown space.
    private var contentSize: CGSize {
        if kind == .watermark, record.watermark?.usesImage == true {
            guard let image, image.width > 0 else { return .zero }
            let width = layout.shownSize.width * CGFloat(record.watermark?.imageScale ?? 0.5)
            return CGSize(width: width, height: width * CGFloat(image.height) / CGFloat(image.width))
        }
        let size = attributedText().size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// A header's rect in shown space.
    private var headerRect: CGRect {
        layout.rect(for: record.position ?? .bottomCenter, size: contentSize, margin: CGFloat(record.headerFooter?.margin ?? 28))
    }

    /// Bounds in page space: the whole page for a watermark, the text for a header.
    private var frame: CGRect {
        switch kind {
        case .watermark: layout.cropBox
        case .headerFooter: layout.pageRect(headerRect.insetBy(dx: -1, dy: -1))
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !Self.isMakingThumbnail else { return }
        drawContent(in: context)
    }

    /// Draws the mark in page space.
    func drawContent(in context: CGContext) {
        context.saveGState()
        // PDFKit can leave a turned text matrix behind (thumbnails of turned
        // pages), which would mirror the text.
        context.textMatrix = .identity
        context.concatenate(layout.transform)
        context.clip(to: CGRect(origin: .zero, size: layout.shownSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        switch kind {
        case .headerFooter:
            attributedText().draw(at: headerRect.origin)
        case .watermark:
            drawWatermark(in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func drawWatermark(in context: CGContext) {
        guard let settings = record.watermark else { return }
        let size = contentSize
        guard size.width > 0, size.height > 0 else { return }
        let opacity = CGFloat(min(max(settings.opacity, 0.05), 1))
        // Transparency in the color or the graphics state, not a transparency
        // group: PDFKit writes a group's form so that other readers cannot
        // find it, and the watermark disappears. Tiles do not overlap.
        let text = attributedText(opacity: opacity)
        context.setAlpha(settings.usesImage ? opacity : 1)
        for center in layout.watermarkCenters(size: size, angle: settings.angle, tiled: settings.tiled) {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: CGFloat(settings.angle) * .pi / 180)
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            if settings.usesImage, let image {
                context.interpolationQuality = .high
                context.draw(image, in: rect)
            } else {
                text.draw(at: rect.origin)
            }
            context.restoreGState()
        }
    }
}

/// Adding, changing and removing watermarks and headers.
extension ReaderLibrary {
    /// Every watermark or header mark, with its page.
    func pageMarks(_ kind: PageMark.Kind) -> [(page: PDFPage, mark: PDFAnnotation)] {
        guard let document else { return [] }
        return (0..<document.pageCount).compactMap { document.page(at: $0) }.flatMap { page in
            page.annotations.filter { PageMark.kind(of: $0) == kind }.map { (page, $0) }
        }
    }

    /// The watermark settings in the document, and its image when known.
    func currentWatermark() -> (settings: WatermarkSettings, image: CGImage?)? {
        for (_, mark) in pageMarks(.watermark) {
            if let settings = PageMark.record(of: mark)?.watermark {
                return (settings, (mark as? PageMark)?.image)
            }
        }
        return nil
    }

    func currentHeaderFooter() -> HeaderFooterSettings? {
        pageMarks(.headerFooter).lazy.compactMap { PageMark.record(of: $0.mark)?.headerFooter }.first
    }

    /// Replaces the document's watermarks with new ones on the pages in
    /// `settings.pages`; throws for a page range that cannot be read.
    func applyWatermark(_ settings: WatermarkSettings, image: CGImage?) throws {
        guard canAnnotate, let document else { return }
        let indexes = try pageIndexes(settings.pages)
        let hadMarks = !pageMarks(.watermark).isEmpty
        replacePageMarks(.watermark, actionName: hadMarks ? L("Change Watermark") : L("Add Watermark")) {
            indexes.compactMap { document.page(at: $0) }.map { page in
                (page, [PageMark.watermark(settings, image: image, on: page)])
            }
        }
    }

    /// Replaces the document's headers and footers with new ones.
    func applyHeaderFooter(_ settings: HeaderFooterSettings) throws {
        guard canAnnotate, let document else { return }
        let indexes = try pageIndexes(settings.pages)
        let settings = datedHeaderFooter(settings)
        let hadMarks = !pageMarks(.headerFooter).isEmpty
        replacePageMarks(.headerFooter, actionName: hadMarks ? L("Change Header & Footer") : L("Add Header & Footer")) {
            indexes.enumerated().compactMap { ordinal, index in
                document.page(at: index).map { page in
                    (page, Self.headerMarks(settings, ordinal: ordinal, count: indexes.count, on: page))
                }
            }
        }
    }

    func removePageMarks(_ kind: PageMark.Kind) {
        guard canAnnotate else { return }
        replacePageMarks(kind, actionName: kind == .watermark ? L("Remove Watermark") : L("Remove Header & Footer")) { [] }
    }

    /// The marks for one page; empty texts are left out.
    static func headerMarks(_ settings: HeaderFooterSettings, ordinal: Int, count: Int, on page: PDFPage) -> [PageMark] {
        MarkPosition.allCases.compactMap { position in
            let text = settings.text(at: position, ordinal: ordinal, count: count)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return PageMark.header(settings, at: position, text: text, on: page)
        }
    }

    /// Opens a watermark or header sheet; nothing happens in a read-only file.
    func showPageSheet(_ sheet: PageSheet) {
        guard canAnnotate else { return }
        pageSheet = sheet
    }

    /// Header settings with today's date and this file's name filled in.
    func datedHeaderFooter(_ settings: HeaderFooterSettings) -> HeaderFooterSettings {
        var settings = settings
        settings.date = Date().formatted(date: .numeric, time: .omitted)
        settings.fileName = displayName
        return settings
    }

    /// Zero-based page indexes for a range typed in a sheet; all pages when empty.
    func pageIndexes(_ range: String) throws -> [Int] {
        let range = range.trimmingCharacters(in: .whitespaces)
        return range.isEmpty ? Array(0..<pageCount) : try PageRangeParser.pages(from: range, pageCount: pageCount)
    }

    /// One undoable step that removes every mark of `kind` and adds new ones.
    private func replacePageMarks(_ kind: PageMark.Kind, actionName: String, _ makeMarks: () -> [(PDFPage, [PageMark])]) {
        let old = pageMarks(kind)
        let new = makeMarks()
        guard !old.isEmpty || new.contains(where: { !$0.1.isEmpty }) else { return }
        var pages: [PDFPage] = []
        for page in old.map(\.page) + new.map(\.0) where !pages.contains(where: { $0 === page }) {
            pages.append(page)
        }
        recordAnnotationEdit(actionName, pages: pages) {
            for (page, mark) in old { page.removeAnnotation(mark) }
            for (page, marks) in new {
                for mark in marks {
                    page.addAnnotation(mark)
                    handOverToOverlay(mark)
                }
            }
        }
    }

    /// Replaces the plain stamps of text marks read from the file with live
    /// marks, and hands live marks to the overlay; called once per page
    /// before it is shown or changed.
    func remakePageMarks(on page: PDFPage) {
        for annotation in page.annotations {
            if let mark = PageMark.remade(from: annotation, on: page) {
                page.removeAnnotation(annotation)
                page.addAnnotation(mark)
                handOverToOverlay(mark)
            } else if annotation is PageMark, annotation.shouldDisplay {
                handOverToOverlay(annotation)
            }
        }
    }

    /// Renumbers headers after pages move, come or go, and follows rotation
    /// and cropping. Each header counts the pages that carry the same header.
    func refreshPageMarks(in document: PDFDocument) {
        var groups: [HeaderFooterSettings: [(page: PDFPage, marks: [PageMark])]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var headers: [HeaderFooterSettings: [PageMark]] = [:]
            for case let mark as PageMark in page.annotations {
                mark.update(on: page)
                if let settings = mark.record.headerFooter { headers[settings, default: []].append(mark) }
            }
            for (settings, marks) in headers { groups[settings, default: []].append((page, marks)) }
        }
        for (settings, pages) in groups {
            for (ordinal, entry) in pages.enumerated() {
                for mark in entry.marks {
                    let text = settings.text(at: mark.record.position ?? .bottomCenter, ordinal: ordinal, count: pages.count)
                    mark.update(text: text, layout: mark.layout)
                }
            }
        }
    }

    /// The current page with `marks` in place of the marks of their kind, for
    /// the sheets' preview.
    func previewImage(of page: PDFPage, replacing kind: PageMark.Kind, with marks: [PageMark], width: CGFloat) -> NSImage? {
        let box = page.bounds(for: .cropBox)
        let shown = PageMarkLayout(cropBox: box, rotation: page.rotation).shownSize
        guard shown.width > 0, shown.height > 0 else { return nil }
        let scale = width / shown.width
        let size = CGSize(width: width, height: (shown.height * scale).rounded())
        // Live marks are hidden from PDFKit and drawn below; plain ones of this
        // kind, read from the file, are hidden while the page is drawn.
        let hidden = page.annotations.filter { PageMark.kind(of: $0) == kind && $0.shouldDisplay }
        for mark in hidden { mark.shouldDisplay = false }
        defer { for mark in hidden { mark.shouldDisplay = true } }
        // Two pixels per point, sharp on Retina displays.
        let pixels: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(size.width * pixels), height: Int(size.height * pixels), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width * pixels, height: size.height * pixels))
        context.scaleBy(x: scale * pixels, y: scale * pixels)
        page.draw(with: .cropBox, to: context)
        let others = page.annotations.compactMap { $0 as? PageMark }.filter { $0.kind != kind && !$0.shouldDisplay }
        context.saveGState()
        // `draw` turns the page itself; marks are drawn in page space.
        context.concatenate(page.transform(for: .cropBox))
        for mark in others + marks { mark.drawContent(in: context) }
        context.restoreGState()
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}
