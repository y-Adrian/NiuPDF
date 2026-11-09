import AppKit
import PDFKit

/// A note icon drawn by the page overlay: the note of a markup annotation, or a
/// standalone `/Text` note whose native PDFKit icon is hidden on screen.
struct CommentMarker {
    let annotation: PDFAnnotation
    /// Page-space center of the icon. The icon keeps a constant on-screen size.
    let center: CGPoint
    /// Page-space text rectangles the note belongs to, tinted while hovering.
    let linkedRects: [CGRect]
}

/// Implemented by the reader's PDF view so the library and overlays can reach it.
@MainActor
protocol AnnotationOverlayHost: AnyObject {
    func refreshAnnotationOverlays()
    func editAnnotation(_ annotation: PDFAnnotation)
}

// MARK: - Layout

/// Places markup note icons close to the first line of their text without
/// covering glyphs: in the whitespace above that line, then beside its ends.
/// Icons that share a line are shifted apart so they never overlap.
enum CommentMarkerLayout {
    /// Page-space slot reserved per icon; about 16 px on screen at 115 %.
    private static let slotSize: CGFloat = 14
    private static let anchorGap: CGFloat = 2
    private static let stackGap: CGFloat = 2
    private static let pageInset: CGFloat = 4
    /// Keys from earlier versions that link a standalone note to its text.
    private static let legacyAnchorKey = PDFAnnotationKey(rawValue: "/PaperplaneAnchor")

    private enum Axis {
        case horizontal
        case vertical
    }

    static func markers(
        on page: PDFPage,
        noteOf: (PDFAnnotation) -> String,
        showsStandaloneNote: (PDFAnnotation) -> Bool
    ) -> [CommentMarker] {
        var markers: [CommentMarker] = []
        var occupied: [CGRect] = []

        for note in page.annotations where note.type == "Text" && showsStandaloneNote(note) {
            let center = CGPoint(x: note.bounds.midX, y: note.bounds.midY)
            markers.append(CommentMarker(annotation: note, center: center, linkedRects: legacyAnchor(of: note).map { [$0] } ?? []))
            occupied.append(slot(around: center))
        }

        let noted = page.annotations.filter {
            MarkupEngine.isMarkup($0) && !noteOf($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !noted.isEmpty else { return markers }
        let lines = pageLineBounds(on: page).sorted { $0.maxY > $1.maxY }
        for markup in noted {
            let linked = MarkupEngine.lineRects(of: markup)
            guard let firstLine = linked.max(by: { $0.maxY < $1.maxY }) else { continue }
            let rect = place(near: firstLine, on: page, lines: lines, occupied: occupied)
            occupied.append(rect)
            markers.append(CommentMarker(annotation: markup, center: CGPoint(x: rect.midX, y: rect.midY), linkedRects: linked))
        }
        return markers
    }

    private static func slot(around center: CGPoint) -> CGRect {
        CGRect(x: center.x - slotSize / 2, y: center.y - slotSize / 2, width: slotSize, height: slotSize)
    }

    private static func legacyAnchor(of note: PDFAnnotation) -> CGRect? {
        guard let raw = note.value(forAnnotationKey: legacyAnchorKey) as? String else { return nil }
        let values = raw.split(separator: " ").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func place(near selection: CGRect, on page: PDFPage, lines: [CGRect], occupied: [CGRect]) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let minX = pageBounds.minX + pageInset
        let maxX = pageBounds.maxX - slotSize - pageInset
        let minY = pageBounds.minY + pageInset
        let maxY = pageBounds.maxY - slotSize - pageInset

        let anchorLine = lines.first(where: { $0.intersects(selection) }) ?? selection
        let lineAbove = lines
            .filter { $0.minY > anchorLine.maxY }
            .min(by: { $0.minY < $1.minY })
        func resolve(_ base: CGRect, _ axis: Axis) -> CGRect? {
            Self.resolve(base, axis: axis, lines: lines, occupied: occupied, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
        }

        // 1) Above the selection's end, inside the whitespace between lines.
        let ceiling = lineAbove?.minY ?? (pageBounds.maxY - pageInset)
        if ceiling - anchorLine.maxY >= slotSize + 2 * anchorGap {
            let base = CGRect(x: selection.maxX - slotSize / 2, y: anchorLine.maxY + anchorGap, width: slotSize, height: slotSize)
            if let rect = resolve(base, .horizontal) { return rect }
        }
        // 2) Beside the line's end, then its start.
        let right = CGRect(x: anchorLine.maxX + anchorGap, y: anchorLine.midY - slotSize / 2, width: slotSize, height: slotSize)
        if let rect = resolve(right, .vertical) { return rect }
        let left = CGRect(x: anchorLine.minX - anchorGap - slotSize, y: anchorLine.midY - slotSize / 2, width: slotSize, height: slotSize)
        if let rect = resolve(left, .vertical) { return rect }
        // 3) Best effort: at the selection's upper-right corner, clamped to the page.
        return CGRect(
            x: min(max(selection.maxX - slotSize / 2, minX), maxX),
            y: min(max(selection.maxY - slotSize / 2, minY), maxY),
            width: slotSize,
            height: slotSize
        )
    }

    private static func resolve(
        _ base: CGRect,
        axis: Axis,
        lines: [CGRect],
        occupied: [CGRect],
        minX: CGFloat,
        maxX: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> CGRect? {
        let step = slotSize + stackGap
        let offsets: [CGFloat] = [0, -step, step, -2 * step, 2 * step, -3 * step, 3 * step, -4 * step, 4 * step]
        for offset in offsets {
            let candidate = axis == .horizontal
                ? base.offsetBy(dx: offset, dy: 0)
                : base.offsetBy(dx: 0, dy: offset)
            let inPage = candidate.minX >= minX && candidate.minX <= maxX
                && candidate.minY >= minY && candidate.minY <= maxY
            if inPage, !lines.contains(where: { $0.intersects(candidate) }), !occupied.contains(where: { $0.intersects(candidate) }) {
                return candidate
            }
        }
        return nil
    }

    private static func pageLineBounds(on page: PDFPage) -> [CGRect] {
        guard let text = page.string, !text.isEmpty,
              let full = page.selection(for: NSRange(location: 0, length: (text as NSString).length)) else { return [] }
        return full.selectionsByLine().compactMap { selection in
            let bounds = selection.bounds(for: page)
            return bounds.isNull || bounds.isEmpty ? nil : bounds
        }
    }
}

// MARK: - Icon

/// A small filled speech bubble in the markup's color. Lines inside mean the note
/// has text; an empty standalone note is drawn hollow.
enum CommentIcon {
    static let screenSize: CGFloat = 16

    static func draw(in rect: CGRect, color: NSColor, hasText: Bool) {
        let unit = rect.width / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }

        let body = CGRect(origin: point(1.5, 4.5), size: CGSize(width: 13 * unit, height: 9 * unit))
        let bubble = NSBezierPath(roundedRect: body, xRadius: 2.2 * unit, yRadius: 2.2 * unit)
        let tail = NSBezierPath()
        tail.move(to: point(4, 4.8))
        tail.line(to: point(3.6, 1.6))
        tail.line(to: point(7.6, 4.8))
        tail.close()
        bubble.append(tail)

        let opaque = color.usingColorSpace(.deviceRGB)?.withAlphaComponent(1) ?? .systemYellow
        let outline = opaque.blended(withFraction: 0.35, of: .black) ?? opaque
        (hasText ? opaque : NSColor.white).setFill()
        bubble.fill()
        outline.setStroke()
        bubble.lineWidth = max(unit * 0.8, 0.1)
        bubble.stroke()

        guard hasText else { return }
        let lines = NSBezierPath()
        lines.move(to: point(4.3, 10.6))
        lines.line(to: point(11.7, 10.6))
        lines.move(to: point(4.3, 7.6))
        lines.line(to: point(9, 7.6))
        lines.lineWidth = 1.3 * unit
        lines.lineCapStyle = .round
        (isLight(opaque) ? outline : .white).setStroke()
        lines.stroke()
    }

    private static func isLight(_ color: NSColor) -> Bool {
        0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent > 0.72
    }
}

// MARK: - Overlay

/// Supplies one overlay per page. PDFKit sizes each overlay to its page's
/// coordinate space and scrolls and zooms it with the page, so icons stay
/// aligned with the text and are drawn as vectors at every zoom level.
final class AnnotationOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    weak var library: ReaderLibrary?
    private let overlays = NSHashTable<PageAnnotationOverlay>.weakObjects()

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        MainActor.assumeIsolated {
            library?.prepareNotes(on: page)
            let overlay = PageAnnotationOverlay(page: page, library: library)
            overlays.add(overlay)
            return overlay
        }
    }

    @MainActor
    func refreshAll() {
        for overlay in overlays.allObjects { overlay.refresh() }
    }
}

@MainActor
final class PageAnnotationOverlay: NSView {
    private let page: PDFPage
    private weak var library: ReaderLibrary?
    private weak var hovered: PDFAnnotation?
    private var previewPopover: NSPopover?

    init(page: PDFPage, library: ReaderLibrary?) {
        self.page = page
        self.library = library
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private var pdfView: PDFView? {
        var view = superview
        while let current = view {
            if let pdfView = current as? PDFView { return pdfView }
            view = current.superview
        }
        return nil
    }

    private var markers: [CommentMarker] { library?.commentMarkers(on: page) ?? [] }

    /// The overlay is drawn in page points, so a constant on-screen size means
    /// dividing by the current zoom.
    private var iconSide: CGFloat { CommentIcon.screenSize / max(pdfView?.scaleFactor ?? 1, 0.05) }

    private func iconRect(_ marker: CommentMarker) -> CGRect {
        let side = iconSide
        return CGRect(x: marker.center.x - side / 2, y: marker.center.y - side / 2, width: side, height: side)
    }

    private func marker(at point: CGPoint) -> CommentMarker? {
        let slop = 3 / max(pdfView?.scaleFactor ?? 1, 0.05)
        return markers.last { iconRect($0).insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    func refresh() {
        if let hovered, !markers.contains(where: { $0.annotation === hovered }) { setHovered(nil) }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let markers = markers
        if let hovered, let marker = markers.first(where: { $0.annotation === hovered }) {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            for rect in marker.linkedRects { NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1)).fill() }
        }
        for marker in markers {
            let isStandalone = marker.annotation.type == "Text"
            let hasText = !(library?.note(of: marker.annotation) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            CommentIcon.draw(
                in: iconRect(marker),
                color: isStandalone ? MarkupColor.yellow.nsColor : marker.annotation.color,
                hasText: hasText
            )
        }
    }

    /// Only the icons take clicks; everywhere else text selection goes to the PDF view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return marker(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let marker = marker(at: convert(event.locationInWindow, from: nil)) else { return }
        setHovered(nil)
        (pdfView as? AnnotationOverlayHost)?.editAnnotation(marker.annotation)
    }

    override func resetCursorRects() {
        for marker in markers { addCursorRect(iconRect(marker), cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(marker(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ marker: CommentMarker?) {
        guard marker?.annotation !== hovered else { return }
        hovered = marker?.annotation
        needsDisplay = true
        previewPopover?.close()
        previewPopover = nil
        guard let marker, let text = library?.note(of: marker.annotation),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NotePreviewController(text: text)
        popover.show(relativeTo: iconRect(marker), of: self, preferredEdge: .maxY)
        previewPopover = popover
    }
}

/// Read-only hover preview of a note.
private final class NotePreviewController: NSViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 8
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = 240
        let container = NSStackView(views: [label])
        container.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        view = container
    }
}

// MARK: - Editor

/// Popover for one annotation: color swatches for markup, its note, and delete.
/// The note is committed when the popover closes, so clicking away keeps it.
final class AnnotationEditorController: NSViewController, NSPopoverDelegate {
    private let annotation: PDFAnnotation
    private weak var library: ReaderLibrary?
    private let textView = NSTextView()
    private var swatches: [NSButton] = []
    private var isDeleted = false
    weak var popover: NSPopover?

    init(annotation: PDFAnnotation, library: ReaderLibrary) {
        self.annotation = annotation
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private var isMarkup: Bool { MarkupEngine.isMarkup(annotation) }

    override func loadView() {
        var rows: [NSView] = []
        if isMarkup {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4
            for (index, color) in MarkupColor.allCases.enumerated() {
                let button = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.tag = index
                button.contentTintColor = color.nsColor
                button.toolTip = color.title
                button.setAccessibilityLabel(color.title)
                button.widthAnchor.constraint(equalToConstant: 22).isActive = true
                button.heightAnchor.constraint(equalToConstant: 22).isActive = true
                swatches.append(button)
                row.addArrangedSubview(button)
            }
            updateSwatches()
            rows.append(row)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 110))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = library?.note(of: annotation) ?? ""
        textView.setAccessibilityLabel("笔记")
        scrollView.documentView = textView
        scrollView.widthAnchor.constraint(equalToConstant: 260).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        rows.append(scrollView)

        let deleteButton = NSButton(title: isMarkup ? "删除标注" : "删除笔记", target: self, action: #selector(deleteAnnotation))
        deleteButton.bezelStyle = .rounded
        deleteButton.contentTintColor = .systemRed
        let doneButton = NSButton(title: "完成", target: self, action: #selector(finish))
        doneButton.bezelStyle = .rounded
        // Plain Return inserts a line break in the note; ⌘Return finishes.
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = .command
        doneButton.toolTip = "完成（⌘↩）"
        let buttons = NSStackView(views: [deleteButton, NSView(), doneButton])
        buttons.orientation = .horizontal
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        buttons.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    private func updateSwatches() {
        let current = annotation.color.usingColorSpace(.deviceRGB)
        for (index, button) in swatches.enumerated() {
            let candidate = MarkupColor.allCases[index].nsColor.usingColorSpace(.deviceRGB)
            let isCurrent = current.map { current in
                candidate.map {
                    abs($0.redComponent - current.redComponent) < 0.02
                        && abs($0.greenComponent - current.greenComponent) < 0.02
                        && abs($0.blueComponent - current.blueComponent) < 0.02
                } ?? false
            } ?? false
            button.image = NSImage(
                systemSymbolName: isCurrent ? "checkmark.circle.fill" : "circle.fill",
                accessibilityDescription: nil
            )
            button.setAccessibilityValue(isCurrent ? "已选中" : nil)
        }
    }

    @objc private func pickColor(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag) else { return }
        library?.setColor(annotation, to: MarkupColor.allCases[sender.tag])
        updateSwatches()
    }

    @objc private func finish() { popover?.performClose(nil) }

    @objc private func deleteAnnotation() {
        isDeleted = true
        library?.deleteAnnotation(annotation)
        popover?.performClose(nil)
    }

    func popoverWillClose(_ notification: Notification) {
        guard !isDeleted else { return }
        library?.finishEditing(annotation, note: textView.string)
    }
}
