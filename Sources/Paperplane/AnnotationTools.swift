import AppKit
import PDFKit

/// What the overlay draws while a drawing or shape tool is being dragged.
enum ToolPreview {
    case ink([CGPoint])
    case shape(AnnotationTool, from: CGPoint, to: CGPoint)
}

/// Mouse handling for the toolbar's annotation tools. The PDF view asks it
/// first; when it returns false the view handles the event as usual (text
/// selection, which the markup tools then mark).
@MainActor
final class AnnotationToolHandler {
    private weak var view: PDFView?
    private weak var library: ReaderLibrary?
    private weak var overlayProvider: AnnotationOverlayProvider?
    private var drag: Drag?
    private var textEditor: InlineTextBoxEditor?

    private enum Drag {
        case ink(page: PDFPage, points: [CGPoint])
        case shape(page: PDFPage, tool: AnnotationTool, start: CGPoint, end: CGPoint)
        /// Drags the selected drawings, shapes and text boxes together. A click
        /// without a drag on one that was already selected opens its popover.
        case move(page: PDFPage, clicked: PDFAnnotation, annotations: [PDFAnnotation], originals: [AnnotationGeometry], start: CGPoint, moved: Bool, wasSelected: Bool)
        case resize(page: PDFPage, annotation: PDFAnnotation, handle: ResizeHandle, original: AnnotationGeometry, moved: Bool)
    }

    /// Handle hit radius and drawn size, in screen points.
    static let handleSize: CGFloat = 8

    init(view: PDFView, library: ReaderLibrary?, overlayProvider: AnnotationOverlayProvider) {
        self.view = view
        self.library = library
        self.overlayProvider = overlayProvider
    }

    func mouseDown(_ event: NSEvent) -> Bool {
        endTextEditing()
        guard let library, let (page, point) = pagePoint(of: event) else { return false }
        switch library.activeTool {
        case .select:
            if event.clickCount == 2, let box = annotation(at: point, on: page, where: { $0.type == "FreeText" }) {
                beginEditing(box, on: page)
                return true
            }
            if let (annotation, handle) = handle(at: point, on: page) {
                drag = .resize(page: page, annotation: annotation, handle: handle, original: AnnotationGeometry(annotation), moved: false)
                return true
            }
            guard let movable = annotation(at: point, on: page, where: ReaderLibrary.isMovable) else {
                // A click on empty space or text clears the selection and selects text as usual.
                library.clearAnnotationSelection()
                return false
            }
            if event.modifierFlags.contains(.shift) {
                library.select(movable, extending: true)
                return true
            }
            let wasSelected = library.isSelected(movable)
            if !wasSelected { library.select(movable, extending: false) }
            let group = library.selectedAnnotations.filter { ReaderLibrary.isMovable($0) && $0.page === page }
            drag = .move(page: page, clicked: movable, annotations: group, originals: group.map(AnnotationGeometry.init), start: point, moved: false, wasSelected: wasSelected)
            return true
        case .highlight, .underline, .squiggly, .strikeOut:
            return false
        case .note:
            library.addStandaloneNote(at: point, on: page)
            return true
        case .textBox:
            if let box = annotation(at: point, on: page, where: { $0.type == "FreeText" }) {
                beginEditing(box, on: page)
            } else {
                beginEditing(library.beginTextBox(at: point, on: page), on: page)
            }
            return true
        case .ink:
            drag = .ink(page: page, points: [point])
            return true
        case .rectangle, .ellipse, .arrow, .redact:
            drag = .shape(page: page, tool: library.activeTool, start: point, end: point)
            return true
        }
    }

    func mouseDragged(_ event: NSEvent) -> Bool {
        guard let drag, let view else { return false }
        let viewPoint = view.convert(event.locationInWindow, from: nil)
        switch drag {
        case let .ink(page, points):
            let point = view.convert(viewPoint, to: page)
            self.drag = .ink(page: page, points: points + [point])
            showPreview(.ink(points + [point]), on: page)
        case let .shape(page, tool, start, _):
            let point = view.convert(viewPoint, to: page)
            self.drag = .shape(page: page, tool: tool, start: start, end: point)
            showPreview(.shape(tool, from: start, to: point), on: page)
        case let .move(page, clicked, annotations, originals, start, _, wasSelected):
            let point = view.convert(viewPoint, to: page)
            for (annotation, original) in zip(annotations, originals) {
                original.offsetBy(dx: point.x - start.x, dy: point.y - start.y).apply(to: annotation)
            }
            self.drag = .move(page: page, clicked: clicked, annotations: annotations, originals: originals, start: start, moved: true, wasSelected: wasSelected)
            overlayProvider?.overlay(for: page)?.needsDisplay = true
        case let .resize(page, annotation, handle, original, _):
            let point = view.convert(viewPoint, to: page)
            ReaderLibrary.resized(original, type: annotation.type ?? "", handle: handle, to: point).apply(to: annotation)
            self.drag = .resize(page: page, annotation: annotation, handle: handle, original: original, moved: true)
            overlayProvider?.overlay(for: page)?.needsDisplay = true
        }
        return true
    }

    func mouseUp(_ event: NSEvent) -> Bool {
        guard let drag else { return false }
        self.drag = nil
        switch drag {
        case let .ink(page, points):
            showPreview(nil, on: page)
            library?.addInk(through: points, on: page)
        case let .shape(page, tool, start, end):
            showPreview(nil, on: page)
            library?.addShape(tool, from: start, to: end, on: page)
        case let .move(_, clicked, annotations, originals, _, moved, wasSelected):
            if moved {
                library?.commitGeometry(annotations, from: originals, actionName: L("Move Annotation"))
            } else if wasSelected {
                // A second click on a selected annotation opens its style popover.
                library?.onEditAnnotation?(clicked)
            }
        case let .resize(_, annotation, _, original, moved):
            if moved {
                library?.commitGeometry([annotation], from: [original], actionName: L("Resize Annotation"))
            }
        }
        return true
    }

    var cursor: NSCursor? {
        switch library?.activeTool ?? .select {
        case .select: nil
        case .highlight, .underline, .squiggly, .strikeOut, .textBox: .iBeam
        case .note, .ink, .rectangle, .ellipse, .arrow, .redact: .crosshair
        }
    }

    /// Commits a text box being typed into, as when the user clicks away.
    func endTextEditing() {
        textEditor?.commit()
        textEditor = nil
    }

    func toolDidChange() {
        endTextEditing()
        drag = nil
    }

    private func beginEditing(_ box: PDFAnnotation, on page: PDFPage) {
        guard let library, let overlay = overlayProvider?.overlay(for: page) else { return }
        textEditor = InlineTextBoxEditor(box: box, overlay: overlay, library: library) { [weak self] editor in
            if self?.textEditor === editor { self?.textEditor = nil }
        }
    }

    /// The handle of a selected, resizable annotation nearest the point. The
    /// reach is the handle's on-screen size, but at most a quarter of the
    /// annotation's shorter side, so at low zoom a click inside a small shape
    /// still moves it instead of grabbing a handle.
    private func handle(at point: CGPoint, on page: PDFPage) -> (PDFAnnotation, ResizeHandle)? {
        guard let library, let view else { return nil }
        let screenReach = Self.handleSize / max(view.scaleFactor, 0.05)
        var best: (annotation: PDFAnnotation, handle: ResizeHandle, distance: CGFloat)?
        for annotation in library.selectedAnnotations where annotation.page === page && ReaderLibrary.isResizable(annotation) {
            let size = annotation.type == "Line" ? screenReach * 4 : min(annotation.bounds.width, annotation.bounds.height)
            let reach = min(screenReach, max(size / 4, 2))
            for (handle, center) in ReaderLibrary.handles(for: annotation) {
                let distance = hypot(center.x - point.x, center.y - point.y)
                if distance <= reach, distance < (best?.distance ?? .infinity) {
                    best = (annotation, handle, distance)
                }
            }
        }
        return best.map { ($0.annotation, $0.handle) }
    }

    private func pagePoint(of event: NSEvent) -> (PDFPage, CGPoint)? {
        guard let view else { return nil }
        let viewPoint = view.convert(event.locationInWindow, from: nil)
        guard let page = view.page(for: viewPoint, nearest: false) else { return nil }
        return (page, view.convert(viewPoint, to: page))
    }

    private func annotation(at point: CGPoint, on page: PDFPage, where matches: (PDFAnnotation) -> Bool) -> PDFAnnotation? {
        page.annotations.last { matches($0) && $0.bounds.contains(point) }
    }

    private func showPreview(_ preview: ToolPreview?, on page: PDFPage) {
        overlayProvider?.overlay(for: page)?.toolPreview = preview
    }
}

/// Types straight into a text box. The text view lives in the page overlay, so
/// it is laid out in page points and scrolls and zooms with the page.
@MainActor
final class InlineTextBoxEditor: NSObject, NSTextViewDelegate {
    private let box: PDFAnnotation
    private weak var library: ReaderLibrary?
    private let textView = NSTextView()
    private let onFinish: (InlineTextBoxEditor) -> Void
    private var isFinished = false

    init(box: PDFAnnotation, overlay: NSView, library: ReaderLibrary, onFinish: @escaping (InlineTextBoxEditor) -> Void) {
        self.box = box
        self.library = library
        self.onFinish = onFinish
        super.init()

        textView.frame = box.bounds
        textView.font = box.font ?? .systemFont(ofSize: ReaderLibrary.textBoxFontSize)
        textView.textColor = box.fontColor ?? .black
        textView.insertionPointColor = box.fontColor ?? .black
        textView.string = box.contents ?? ""
        textView.isRichText = false
        textView.allowsUndo = true
        // The overlay skips the box while it is typed into; show its background here.
        textView.drawsBackground = box.color.alphaComponent > 0
        textView.backgroundColor = box.color.alphaComponent > 0 ? box.color : .clear
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.wantsLayer = true
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.layer?.borderWidth = 0.75
        textView.delegate = self
        textView.setAccessibilityLabel(L("Text Box"))

        // The overlay skips the box while its text is shown in the editor.
        library.annotationBeingTyped = box
        library.onTypingStyleChange = { [weak self] in self?.applyBoxStyle() }
        overlay.addSubview(textView)
        fitHeight()
        overlay.window?.makeFirstResponder(textView)
    }

    func commit() {
        guard !isFinished else { return }
        isFinished = true
        let text = textView.string
        let bounds = textView.frame
        textView.delegate = nil
        textView.removeFromSuperview()
        if library?.annotationBeingTyped === box {
            library?.annotationBeingTyped = nil
            library?.onTypingStyleChange = nil
        }
        library?.finishTextBox(box, text: text, bounds: bounds)
        onFinish(self)
    }

    /// Follows font, size and color chosen in the toolbar while typing.
    private func applyBoxStyle() {
        // The overlay skips the box while it is typed into; show its background here.
        textView.drawsBackground = box.color.alphaComponent > 0
        textView.backgroundColor = box.color.alphaComponent > 0 ? box.color : .clear
        textView.font = box.font ?? .systemFont(ofSize: ReaderLibrary.textBoxFontSize)
        textView.textColor = box.fontColor ?? .black
        textView.insertionPointColor = box.fontColor ?? .black
        fitHeight()
    }

    func textDidChange(_ notification: Notification) {
        fitHeight()
    }

    func textDidEndEditing(_ notification: Notification) {
        commit()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        commit()
        return true
    }

    /// Grows or shrinks the box downward to fit its text, keeping the top edge.
    private func fitHeight() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let font = textView.font ?? .systemFont(ofSize: ReaderLibrary.textBoxFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = max(layout.usedRect(for: container).height, lineHeight) + textView.textContainerInset.height * 2 + 2
        let top = textView.frame.maxY
        textView.frame = CGRect(x: textView.frame.minX, y: top - height, width: textView.frame.width, height: height)
    }
}

/// Draws drawings, shapes and text boxes as vectors at the current zoom, in
/// page coordinates, so they stay sharp where PDFKit's rendering would not.
@MainActor
enum VectorAnnotationRenderer {
    static func draw(_ annotation: PDFAnnotation) {
        let lineWidth = annotation.border?.lineWidth ?? 1
        let origin = annotation.bounds.origin
        switch annotation.type {
        case "Ink":
            // Ink paths are relative to the annotation's origin.
            let shift = AffineTransform(translationByX: origin.x, byY: origin.y)
            annotation.color.setStroke()
            for path in annotation.paths ?? [] {
                guard let copy = path.copy() as? NSBezierPath else { continue }
                copy.transform(using: shift)
                copy.lineWidth = lineWidth
                copy.lineCapStyle = .round
                copy.lineJoinStyle = .round
                copy.stroke()
            }
        case "Square", "Circle":
            let rect = annotation.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = annotation.type == "Square" ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
            if let fill = annotation.interiorColor {
                fill.setFill()
                path.fill()
            }
            guard lineWidth > 0 else { return }
            path.lineWidth = lineWidth
            annotation.color.setStroke()
            path.stroke()
        case "Line":
            let start = CGPoint(x: origin.x + annotation.startPoint.x, y: origin.y + annotation.startPoint.y)
            let end = CGPoint(x: origin.x + annotation.endPoint.x, y: origin.y + annotation.endPoint.y)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            appendArrowHead(annotation.startLineStyle, at: start, from: end, width: lineWidth, to: path)
            appendArrowHead(annotation.endLineStyle, at: end, from: start, width: lineWidth, to: path)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            annotation.color.setStroke()
            path.stroke()
        case "FreeText":
            drawText(of: annotation)
        case "Underline", "Squiggly":
            if MarkupEngine.isSquiggly(annotation) { drawSquiggle(annotation) }
        default:
            break
        }
    }

    /// A wave under each line of squiggly markup, at the height where it
    /// meets the least text: below the glyphs when the space between lines is
    /// free, otherwise along the bottom of its own line, cut where glyphs
    /// reach down through it (y, g, p…), as browsers cut underlines.
    private static func drawSquiggle(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        annotation.color.setStroke()
        for placement in SquiggleInk.placements(for: annotation, on: page) {
            let line = placement.line, wave = placement.wave
            NSGraphicsContext.saveGraphicsState()
            if !placement.gaps.isEmpty {
                // Even-odd clip: everything except the gaps.
                let clip = NSBezierPath(rect: line.insetBy(dx: -4, dy: -line.height))
                for gap in placement.gaps {
                    clip.appendRect(CGRect(x: gap.lowerBound, y: line.minY - line.height, width: gap.upperBound - gap.lowerBound, height: line.height * 3))
                }
                clip.windingRule = .evenOdd
                clip.addClip()
            }
            let path = squiggle(from: line.minX, to: line.maxX, at: wave.center, amplitude: wave.amplitude, wavelength: wave.wavelength)
            path.lineWidth = wave.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A smooth wave along y from `left` to `right`.
    nonisolated static func squiggle(from left: CGFloat, to right: CGFloat, at y: CGFloat, amplitude: CGFloat, wavelength: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: left, y: y))
        var x = left
        var up = true
        let half = wavelength / 2
        while x < right {
            let next = min(x + half, right)
            let peak = CGPoint(x: (x + next) / 2, y: y + (up ? amplitude : -amplitude) * 2 * (next - x) / half)
            path.curve(to: CGPoint(x: next, y: y), controlPoint1: peak, controlPoint2: peak)
            x = next
            up.toggle()
        }
        return path
    }

    private static func appendArrowHead(_ style: PDFLineStyle, at tip: CGPoint, from tail: CGPoint, width: CGFloat, to path: NSBezierPath) {
        guard style == .openArrow || style == .closedArrow else { return }
        let length = max(8, width * 4)
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let left = CGPoint(x: tip.x + length * cos(angle + .pi * 5 / 6), y: tip.y + length * sin(angle + .pi * 5 / 6))
        let right = CGPoint(x: tip.x + length * cos(angle - .pi * 5 / 6), y: tip.y + length * sin(angle - .pi * 5 / 6))
        path.move(to: left)
        path.line(to: tip)
        path.line(to: right)
        if style == .closedArrow { path.close() }
    }

    /// Lays text out like the inline editor (default line fragment padding,
    /// 2 pt top inset), so a box does not shift when editing ends.
    private static func drawText(of box: PDFAnnotation) {
        if box.color.alphaComponent > 0 {
            box.color.setFill()
            box.bounds.fill()
        }
        // Black inside the box's edge, as PDFKit draws it for other readers.
        if let width = box.border?.lineWidth, width > 0 {
            let frame = NSBezierPath(rect: box.bounds.insetBy(dx: width / 2, dy: width / 2))
            frame.lineWidth = width
            NSColor.black.setStroke()
            frame.stroke()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = box.alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: box.font ?? .systemFont(ofSize: ReaderLibrary.textBoxFontSize),
            .foregroundColor: box.fontColor ?? .black,
            .paragraphStyle: paragraph
        ]
        let padding = NSTextContainer().lineFragmentPadding
        let rect = CGRect(x: box.bounds.minX + padding, y: box.bounds.minY, width: box.bounds.width - padding * 2, height: box.bounds.height - 2)
        (box.contents ?? "").draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}

/// The highlight, underline and strikethrough icons: a letter on a yellow
/// block, or with a red line under or through it. The toolbar and the context
/// menu both use these so the tools look the same everywhere.
enum MarkupGlyph {
    /// An image drawn when displayed, so the letter follows light and dark mode.
    static func image(for tool: AnnotationTool, side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(tool, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = tool.title
        return image
    }

    private static func draw(_ tool: AnnotationTool, in rect: CGRect) {
        let side = min(rect.width, rect.height)
        if tool == .highlight {
            let block = CGRect(x: rect.midX - side * 0.4, y: rect.midY - side * 0.4, width: side * 0.8, height: side * 0.8)
            NSColor(calibratedRed: 1, green: 0.82, blue: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: block, xRadius: side * 0.08, yRadius: side * 0.08).fill()
        }
        let font = NSFont.systemFont(ofSize: side * 0.68, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tool == .highlight ? NSColor.black : NSColor.labelColor
        ]
        let letter = "A" as NSString
        let size = letter.size(withAttributes: attributes)
        // Center the capital letter itself, not the line box around it.
        let baseline = rect.midY - font.capHeight / 2
        letter.draw(at: CGPoint(x: rect.midX - size.width / 2, y: baseline + font.descender), withAttributes: attributes)

        guard tool == .underline || tool == .squiggly || tool == .strikeOut else { return }
        let lineY = tool == .strikeOut ? baseline + font.capHeight * 0.45 : baseline - side * 0.1
        let left = rect.midX - size.width / 2 - side * 0.06
        let right = rect.midX + size.width / 2 + side * 0.06
        let line = tool == .squiggly
            ? VectorAnnotationRenderer.squiggle(from: left, to: right, at: lineY, amplitude: side * 0.05, wavelength: side * 0.22)
            : NSBezierPath()
        if tool != .squiggly {
            line.move(to: CGPoint(x: left, y: lineY))
            line.line(to: CGPoint(x: right, y: lineY))
        }
        line.lineWidth = max(1.4, side * 0.07)
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        NSColor.systemRed.setStroke()
        line.stroke()
    }
}

/// Where a squiggle goes on each line, found from the page's text (rendered
/// with annotations off) around the bottom of the line. Cached per
/// annotation: the text under markup does not change.
@MainActor
enum SquiggleInk {
    struct Wave {
        var center: CGFloat
        var amplitude: CGFloat
        var lineWidth: CGFloat
        var wavelength: CGFloat
        /// Half the wave's height, stroke included, with some air.
        var reach: CGFloat { amplitude + lineWidth / 2 + 0.6 }
    }

    struct Placement {
        var line: CGRect
        var wave: Wave
        /// Horizontal page ranges to leave out where glyphs cross the wave.
        var gaps: [ClosedRange<CGFloat>]
    }

    /// The wave's shape for a line, centered just above the bottom of the
    /// line box, which reaches down to the descenders.
    static func wave(for line: CGRect) -> Wave {
        let amplitude = max(0.5, line.height * 0.05)
        let lineWidth = max(0.5, line.height * 0.045)
        let gap = max(0.2, line.height * 0.02)
        return Wave(
            center: line.minY + gap + amplitude + lineWidth / 2,
            amplitude: amplitude,
            lineWidth: lineWidth,
            wavelength: max(2.5, line.height * 0.3)
        )
    }

    private final class Entry {
        let key: String
        let placements: [Placement]
        init(key: String, placements: [Placement]) {
            self.key = key
            self.placements = placements
        }
    }

    private static let cache = NSMapTable<PDFAnnotation, Entry>.weakToStrongObjects()

    static func placements(for annotation: PDFAnnotation, on page: PDFPage) -> [Placement] {
        let lines = MarkupEngine.lineRects(of: annotation)
        let key = "\(lines)\(page.rotation)"
        if let entry = cache.object(forKey: annotation), entry.key == key { return entry.placements }
        let placements = lines.map { place(under: $0, on: page) }
        cache.setObject(Entry(key: key, placements: placements), forKey: annotation)
        return placements
    }

    /// Picks the wave's height. It stays inside its own line box, at the
    /// height crossing the fewest glyphs, so it reads as part of that line and
    /// keeps clear of the next. Only when glyphs fill the bottom of the line
    /// (Chinese text sits on it) does it move below the box, and only if the
    /// space there is clearly emptier.
    private static func place(under line: CGRect, on page: PDFPage) -> Placement {
        var wave = wave(for: line)
        let highest = line.minY + line.height * 0.22, lowest = line.minY - line.height * 0.3
        // The band covers every candidate wave, stroke included.
        let band = CGRect(x: line.minX, y: lowest - wave.reach - 0.5, width: line.width, height: highest - lowest + wave.reach * 2 + 1)
        // `draw(with:to:)` applies page rotation, which would move the band;
        // rotated pages keep the default, uncut wave.
        guard page.rotation == 0, let ink = InkMap(page: page, band: band) else {
            return Placement(line: line, wave: wave, gaps: [])
        }
        let preferred = wave.center
        func best(from top: CGFloat, to bottom: CGFloat) -> (center: CGFloat, columns: Int)? {
            var result: (center: CGFloat, columns: Int, distance: CGFloat)?
            var center = top
            while center >= bottom {
                let columns = ink.inkColumns(from: center - wave.reach, to: center + wave.reach).count { $0 }
                let distance = abs(center - preferred)
                if result == nil || columns < result!.columns || (columns == result!.columns && distance < result!.distance) {
                    result = (center, columns, distance)
                }
                center -= 0.25
            }
            return result.map { ($0.center, $0.columns) }
        }
        let insideLowest = line.minY + wave.amplitude + wave.lineWidth / 2
        var chosen = best(from: highest, to: insideLowest) ?? (preferred, 0)
        if CGFloat(chosen.columns) > CGFloat(ink.width) * 0.2,
           let below = best(from: insideLowest - 0.25, to: lowest),
           below.columns * 2 < chosen.columns {
            chosen = below
        }
        wave.center = chosen.center
        let gaps = ink.gaps(from: wave.center - wave.reach, to: wave.center + wave.reach, pad: wave.lineWidth * 1.5 + 0.4, minimumPiece: wave.wavelength * 0.75)
        return Placement(line: line, wave: wave, gaps: gaps)
    }

    /// Dark pixels of the page's text in a band, at 4 pixels per point.
    private struct InkMap {
        let band: CGRect
        let scale: CGFloat = 4
        let width: Int
        let height: Int
        let ink: [Bool]

        init?(page: PDFPage, band: CGRect) {
            self.band = band
            width = Int((band.width * scale).rounded(.up))
            height = Int((band.height * scale).rounded(.up))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data else { return nil }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -band.minX, y: -band.minY)
            let showed = page.displaysAnnotations
            page.displaysAnnotations = false
            page.draw(with: .mediaBox, to: context)
            page.displaysAnnotations = showed
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var ink = [Bool](repeating: false, count: width * height)
            for index in 0..<(width * height) {
                let offset = index * 4
                ink[index] = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2]) < 140
            }
            self.ink = ink
        }

        /// For each pixel column, whether text ink lies between two page heights.
        func inkColumns(from low: CGFloat, to high: CGFloat) -> [Bool] {
            // Row 0 is the top of the band.
            let top = max(0, Int(((band.maxY - high) * scale).rounded(.down)))
            let bottom = min(height, Int(((band.maxY - low) * scale).rounded(.up)))
            guard top < bottom else { return [Bool](repeating: false, count: width) }
            return (0..<width).map { x in (top..<bottom).contains { ink[$0 * width + x] } }
        }

        /// Page ranges to leave out: runs of inked columns widened by `pad`,
        /// merged when the wave left between them would be shorter than
        /// `minimumPiece`.
        func gaps(from low: CGFloat, to high: CGFloat, pad: CGFloat, minimumPiece: CGFloat) -> [ClosedRange<CGFloat>] {
            let columns = inkColumns(from: low, to: high)
            var gaps: [ClosedRange<CGFloat>] = []
            var start: Int?
            for x in 0...width {
                let inked = x < width && columns[x]
                if inked, start == nil { start = x }
                if !inked, let begin = start {
                    let gap = (band.minX + CGFloat(begin) / scale - pad)...(band.minX + CGFloat(x) / scale + pad)
                    if let last = gaps.last, gap.lowerBound - last.upperBound < minimumPiece {
                        gaps[gaps.count - 1] = last.lowerBound...gap.upperBound
                    } else {
                        gaps.append(gap)
                    }
                    start = nil
                }
            }
            return gaps
        }
    }
}
