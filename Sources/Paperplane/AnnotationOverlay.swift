import AppKit
import PDFKit

/// A note icon drawn by the page overlay: the note of a markup annotation, or a
/// standalone `/Text` note whose native PDFKit icon is hidden on screen.
struct CommentMarker {
    let annotation: PDFAnnotation
    /// Page-space center of the icon.
    let center: CGPoint
    /// Page-space side, proportional to the text's line height so the icon
    /// scales with the text. Nil keeps a constant on-screen size instead, for
    /// standalone notes, which have no line of their own.
    let side: CGFloat?
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

/// Puts each markup note icon at the top-right corner of the first line of its
/// text, like a superscript, sized in proportion to that line's height.
/// Icons that would overlap move further right.
enum CommentMarkerLayout {
    /// Icon side as a fraction of the line height.
    private static let sizeRatio: CGFloat = 0.7
    /// Gap from the end of the text, as a fraction of the icon side.
    private static let gapRatio: CGFloat = 0.1
    /// How much of the icon sits below the line's top edge, as a fraction of its side.
    private static let dropRatio: CGFloat = 0.55
    /// Key from earlier versions that links a standalone note to its text.
    private static let legacyAnchorKey = PDFAnnotationKey(rawValue: "/PaperplaneAnchor")

    static func markers(
        on page: PDFPage,
        noteOf: (PDFAnnotation) -> String,
        showsStandaloneNote: (PDFAnnotation) -> Bool
    ) -> [CommentMarker] {
        var markers: [CommentMarker] = []
        var occupied: [CGRect] = []

        for note in page.annotations where note.type == "Text" && showsStandaloneNote(note) {
            markers.append(CommentMarker(
                annotation: note,
                center: CGPoint(x: note.bounds.midX, y: note.bounds.midY),
                side: nil,
                linkedRects: legacyAnchor(of: note).map { [$0] } ?? []
            ))
            occupied.append(note.bounds)
        }

        let pageBounds = page.bounds(for: .mediaBox)
        for markup in page.annotations where MarkupEngine.isMarkup(markup)
            && !noteOf(markup).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let linked = MarkupEngine.lineRects(of: markup)
            guard let firstLine = linked.max(by: { $0.maxY < $1.maxY }) else { continue }
            let side = max(firstLine.height * sizeRatio, 4)
            var rect = CGRect(
                x: firstLine.maxX + side * gapRatio,
                y: firstLine.maxY - side * dropRatio,
                width: side,
                height: side
            )
            while occupied.contains(where: { $0.intersects(rect) }) { rect.origin.x += side * (1 + gapRatio) }
            rect.origin.x = min(rect.minX, pageBounds.maxX - side)
            rect.origin.y = min(rect.minY, pageBounds.maxY - side)
            occupied.append(rect)
            markers.append(CommentMarker(
                annotation: markup,
                center: CGPoint(x: rect.midX, y: rect.midY),
                side: side,
                linkedRects: linked
            ))
        }
        return markers
    }

    private static func legacyAnchor(of note: PDFAnnotation) -> CGRect? {
        guard let raw = note.value(forAnnotationKey: legacyAnchorKey) as? String else { return nil }
        let values = raw.split(separator: " ").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
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
    private var constantIconSide: CGFloat { CommentIcon.screenSize / max(pdfView?.scaleFactor ?? 1, 0.05) }

    private func iconRect(_ marker: CommentMarker) -> CGRect {
        let side = marker.side ?? constantIconSide
        return CGRect(x: marker.center.x - side / 2, y: marker.center.y - side / 2, width: side, height: side)
    }

    private func marker(at point: CGPoint) -> CommentMarker? {
        let slop = 3 / max(pdfView?.scaleFactor ?? 1, 0.05)
        return markers.last { iconRect($0).insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    func refresh() {
        // Zooming or editing moves icons, so a shown preview would point at the old spot.
        if hovered != nil { setHovered(nil) }
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
        guard let marker, let window, let text = library?.note(of: marker.annotation),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NotePreviewPanel.shared.hide()
            return
        }
        NotePreviewPanel.shared.show(text, near: window.convertToScreen(convert(iconRect(marker), to: nil)))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, hovered != nil { NotePreviewPanel.shared.hide() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Read-only hover preview of a note: a borderless tooltip-style panel, so it
/// has no popover arrow and never takes focus or clicks.
@MainActor
private final class NotePreviewPanel {
    static let shared = NotePreviewPanel()

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true

        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 8
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = 240
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        panel.contentView = background
    }

    /// Shows the text above `anchor` (screen coordinates), or below it when
    /// there is no room above.
    func show(_ text: String, near anchor: NSRect) {
        label.stringValue = text
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize
        let gap: CGFloat = 6
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        if let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame {
            if origin.y + size.height > visible.maxY { origin.y = anchor.minY - gap - size.height }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
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
