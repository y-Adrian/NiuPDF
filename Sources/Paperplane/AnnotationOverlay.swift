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
    func refreshAnnotationOverlays(on pages: [PDFPage])
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
    /// Resting opacity, so text under an icon stays readable; hovering shows it fully.
    static let restingOpacity: CGFloat = 0.45

    static func draw(in rect: CGRect, color: NSColor, hasText: Bool, opacity: CGFloat = 1) {
        // Fade the icon as a whole; per-part alpha would let the lines and
        // outline show through the fill.
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setAlpha(opacity)
        context?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            context?.endTransparencyLayer()
            context?.restoreGState()
        }

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

    @MainActor
    func refresh(on pages: [PDFPage]) {
        let pageIDs = Set(pages.map(ObjectIdentifier.init))
        for overlay in overlays.allObjects where pageIDs.contains(ObjectIdentifier(overlay.page)) {
            overlay.refresh()
        }
    }

    @MainActor
    func overlay(for page: PDFPage) -> PageAnnotationOverlay? {
        overlays.allObjects.first { $0.page === page }
    }
}

@MainActor
final class PageAnnotationOverlay: NSView {
    let page: PDFPage
    /// Live outline of the drawing or shape being dragged.
    var toolPreview: ToolPreview? {
        didSet { needsDisplay = true }
    }
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
        let annotations = library?.overlayDrawnAnnotations(on: page) ?? []
        // Watermarks and headers first, below drawings and shapes.
        if let context = NSGraphicsContext.current?.cgContext {
            for case let mark as PageMark in annotations { mark.drawContent(in: context) }
        }
        for annotation in annotations where !(annotation is PageMark) {
            VectorAnnotationRenderer.draw(annotation)
        }
        drawSelection()
        drawToolPreview()
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
                hasText: hasText,
                opacity: marker.annotation === hovered ? 1 : CommentIcon.restingOpacity
            )
        }
    }

    /// A dashed frame around each selected annotation on this page, with
    /// handles on drawings, shapes and text boxes (end points on arrows).
    private func drawSelection() {
        guard let library else { return }
        let selected = library.selectedAnnotations.filter { $0.page === page }
        guard !selected.isEmpty else { return }
        let scale = max(pdfView?.scaleFactor ?? 1, 0.05)
        let handleSide = AnnotationToolHandler.handleSize / scale
        let accent = NSColor.controlAccentColor
        for annotation in selected {
            if annotation.type != "Line" {
                let frame: CGRect
                if MarkupEngine.isMarkup(annotation) {
                    let lines = MarkupEngine.lineRects(of: annotation)
                    frame = lines.dropFirst().reduce(lines.first ?? annotation.bounds) { $0.union($1) }
                } else {
                    frame = annotation.bounds
                }
                let outline = NSBezierPath(rect: frame.insetBy(dx: -2 / scale, dy: -2 / scale))
                outline.lineWidth = 1 / scale
                outline.setLineDash([4 / scale, 3 / scale], count: 2, phase: 0)
                accent.setStroke()
                outline.stroke()
            }
            guard ReaderLibrary.isResizable(annotation) else { continue }
            for (_, center) in ReaderLibrary.handles(for: annotation) {
                let rect = CGRect(x: center.x - handleSide / 2, y: center.y - handleSide / 2, width: handleSide, height: handleSide)
                let handle = annotation.type == "Line" ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
                NSColor.white.setFill()
                handle.fill()
                handle.lineWidth = 1.2 / scale
                accent.setStroke()
                handle.stroke()
            }
        }
    }

    private func drawToolPreview() {
        guard let toolPreview, let library else { return }
        let path = NSBezierPath()
        path.lineWidth = library.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch toolPreview {
        case let .ink(points):
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
        case let .shape(tool, start, end):
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            switch tool {
            case .ellipse:
                path.appendOval(in: rect)
            case .arrow:
                path.move(to: start)
                path.line(to: end)
                let angle = atan2(end.y - start.y, end.x - start.x)
                for spread in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                    path.move(to: end)
                    path.line(to: CGPoint(x: end.x + 10 * cos(angle + spread), y: end.y + 10 * sin(angle + spread)))
                }
            default:
                path.appendRect(rect)
            }
        }
        library.drawingColor.nsColor.setStroke()
        path.stroke()
    }

    /// Only the icons and an inline text box editor take clicks; everywhere else
    /// text selection goes to the PDF view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        if let hit = super.hitTest(point), hit !== self { return hit }
        return marker(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let marker = marker(at: convert(event.locationInWindow, from: nil)) else { return }
        setHovered(nil)
        library?.select(marker.annotation, extending: event.modifierFlags.contains(.shift))
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
        // Light like the note editor, also in dark mode.
        panel.appearance = NSAppearance(named: .aqua)
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
    private var fontPopup: NSPopUpButton?
    private var sizePopup: NSPopUpButton?
    private var isDeleted = false
    weak var popover: NSPopover?

    init(annotation: PDFAnnotation, library: ReaderLibrary) {
        self.annotation = annotation
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private var isMarkup: Bool { MarkupEngine.isMarkup(annotation) }
    /// Markup and standalone notes carry a note; text boxes, drawings and
    /// shapes only get colors and delete here.
    private var showsNoteField: Bool { isMarkup || annotation.type == "Text" }
    private var palette: [MarkupColor] {
        if isMarkup { return MarkupColor.allCases }
        return annotation.type == "Text" ? [] : MarkupColor.drawingCases
    }

    /// One plain light surface for the whole popover: the color swatches sit on
    /// the same background as the note text, separated only by hairlines.
    override func loadView() {
        let width: CGFloat = 264
        var rows: [NSView] = []
        if !palette.isEmpty {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            for (index, color) in palette.enumerated() {
                let button = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyUpOrDown
                button.tag = index
                button.contentTintColor = color.nsColor
                button.toolTip = color.title
                button.setAccessibilityLabel(color.title)
                button.widthAnchor.constraint(equalToConstant: 18).isActive = true
                button.heightAnchor.constraint(equalToConstant: 18).isActive = true
                swatches.append(button)
                row.addArrangedSubview(button)
            }
            updateSwatches()
            rows.append(row)
            rows.append(Self.hairline())
        }
        if let opacityRow = opacityRow() {
            rows.append(opacityRow)
            rows.append(Self.hairline())
        }
        if let styleRow = styleRow() {
            rows.append(styleRow)
            rows.append(Self.hairline())
        }
        if annotation.type == "FreeText" {
            rows.append(boxRow())
            rows.append(Self.hairline())
        }

        if showsNoteField { rows += noteRows() }

        let deleteTitle = isMarkup ? L("Delete Markup") : (annotation.type == "Text" ? L("Delete Note") : L("Delete Annotation"))
        let deleteButton = Self.textButton(deleteTitle, color: .systemRed, target: self, action: #selector(deleteAnnotation))
        let doneButton = Self.textButton(L("Done"), color: .controlAccentColor, target: self, action: #selector(finish))
        // Plain Return inserts a line break in the note; ⌘Return finishes.
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = .command
        doneButton.toolTip = L("Done (⌘↩)")
        let buttons = NSStackView(views: [deleteButton, NSView(), doneButton])
        buttons.orientation = .horizontal
        buttons.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for row in rows { row.widthAnchor.constraint(equalToConstant: width).isActive = true }
        view = stack
    }

    /// Opacity for markup, drawings and shapes. Standalone notes have no
    /// color choice, and text boxes cannot keep a see-through text color.
    private func opacityRow() -> NSView? {
        guard !palette.isEmpty, annotation.type != "FreeText" else { return nil }
        let values = ReaderLibrary.opacities
        let labels = values.map { L("%ld%%", Int(($0 * 100).rounded())) }
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(pickOpacity(_:)))
        let current = (library?.displayColor(of: annotation) ?? annotation.color).alphaComponent
        control.selectedSegment = values.firstIndex { abs($0 - current) < 0.01 } ?? -1
        control.controlSize = .small
        control.setAccessibilityLabel(L("Opacity"))
        let title = NSTextField(labelWithString: L("Opacity"))
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        // The label keeps its width; the segments give way if space is short.
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return row
    }

    @objc private func pickOpacity(_ sender: NSSegmentedControl) {
        guard ReaderLibrary.opacities.indices.contains(sender.selectedSegment) else { return }
        library?.setOpacity(annotation, to: ReaderLibrary.opacities[sender.selectedSegment])
    }

    /// Background and border of a text box.
    private func boxRow() -> NSView {
        let background = NSPopUpButton()
        background.addItem(withTitle: L("None"))
        background.menu?.addItem(.separator())
        for color in MarkupColor.backgroundCases {
            let item = NSMenuItem(title: color.title, action: nil, keyEquivalent: "")
            item.image = TextBoxStyleImages.swatch(color)
            item.representedObject = color.hex
            background.menu?.addItem(item)
        }
        let current = ReaderLibrary.background(of: annotation)?.hex
        if let index = background.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            background.selectItem(at: index)
        }
        background.target = self
        background.action = #selector(pickBackground(_:))
        background.setAccessibilityLabel(L("Background"))

        let border = NSPopUpButton()
        for width in ReaderLibrary.textBoxBorderWidths {
            border.addItem(withTitle: width == 0 ? L("None") : L("%ld pt", Int(width)))
            border.lastItem?.representedObject = width
        }
        let currentWidth = annotation.border?.lineWidth ?? 0
        border.selectItem(at: ReaderLibrary.textBoxBorderWidths.firstIndex { abs($0 - currentWidth) < 0.01 } ?? 0)
        border.target = self
        border.action = #selector(pickBorder(_:))
        border.setAccessibilityLabel(L("Border"))

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            return field
        }
        background.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label(L("Background")), background, label(L("Border")), border])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return row
    }

    @objc private func pickBackground(_ sender: NSPopUpButton) {
        let hex = sender.selectedItem?.representedObject as? String
        library?.setBackground(of: annotation, to: MarkupColor.backgroundCases.first { $0.hex == hex })
    }

    @objc private func pickBorder(_ sender: NSPopUpButton) {
        guard let width = sender.selectedItem?.representedObject as? CGFloat else { return }
        library?.setBorderWidth(of: annotation, to: width)
    }

    /// Line width for drawings and shapes; font family and size for text boxes.
    private func styleRow() -> NSView? {
        let controls: [NSView]
        switch annotation.type {
        case "Ink", "Square", "Circle", "Line":
            let widths = ReaderLibrary.strokeWidths
            let control = NSSegmentedControl(images: widths.map(Self.lineImage), trackingMode: .selectOne, target: self, action: #selector(pickWidth(_:)))
            for (index, width) in widths.enumerated() {
                control.setToolTip(L("%ld pt", Int(width)), forSegment: index)
            }
            let current = annotation.border?.lineWidth ?? 1
            control.selectedSegment = widths.firstIndex { abs($0 - current) < 0.01 } ?? -1
            control.setAccessibilityLabel(L("Line Width"))
            controls = [control]
        case "FreeText":
            let family = NSPopUpButton()
            family.addItem(withTitle: FontChoices.displayName(nil))
            family.lastItem?.representedObject = nil
            family.menu?.addItem(.separator())
            for name in FontChoices.common + [""] + FontChoices.all {
                if name.isEmpty {
                    family.menu?.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: FontChoices.displayName(name), action: nil, keyEquivalent: "")
                item.representedObject = name
                family.menu?.addItem(item)
            }
            let current = ReaderLibrary.fontFamily(of: annotation)
            if let index = family.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
                family.selectItem(at: index)
            }
            family.target = self
            family.action = #selector(pickFont(_:))
            family.setAccessibilityLabel(L("Font"))
            // Long family names give way first; the size menu keeps its width.
            family.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fontPopup = family

            let size = NSPopUpButton()
            for value in ReaderLibrary.fontSizes {
                size.addItem(withTitle: L("%ld pt", Int(value)))
                size.lastItem?.representedObject = value
            }
            let currentSize = annotation.font?.pointSize ?? ReaderLibrary.textBoxFontSize
            if let index = ReaderLibrary.fontSizes.firstIndex(where: { abs($0 - currentSize) < 0.01 }) {
                size.selectItem(at: index)
            }
            size.target = self
            size.action = #selector(pickFont(_:))
            size.setAccessibilityLabel(L("Font Size"))
            sizePopup = size
            controls = [family, size]
        default:
            return nil
        }
        let row = NSStackView(views: controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return row
    }

    /// A horizontal line of the given thickness for the line width control.
    private static func lineImage(_ width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            let height = min(width, rect.height)
            NSBezierPath(roundedRect: CGRect(x: 2, y: rect.midY - height / 2, width: rect.width - 4, height: height), xRadius: height / 2, yRadius: height / 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func pickWidth(_ sender: NSSegmentedControl) {
        guard ReaderLibrary.strokeWidths.indices.contains(sender.selectedSegment) else { return }
        library?.setStrokeWidth(annotation, to: ReaderLibrary.strokeWidths[sender.selectedSegment])
    }

    @objc private func pickFont(_ sender: NSPopUpButton) {
        let family = fontPopup?.selectedItem?.representedObject as? String
        let size = sizePopup?.selectedItem?.representedObject as? CGFloat ?? ReaderLibrary.textBoxFontSize
        library?.setFont(of: annotation, family: family, size: size)
    }

    private func noteRows() -> [NSView] {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 264, height: 104))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = library?.note(of: annotation) ?? ""
        textView.setAccessibilityLabel(L("Note"))
        scrollView.documentView = textView
        scrollView.heightAnchor.constraint(equalToConstant: 104).isActive = true
        return [scrollView, Self.hairline()]
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The popover's own material is a translucent gray; paint its frame,
        // arrow included, with the same light background as the text area.
        guard let frameView = view.window?.contentView?.superview,
              !frameView.subviews.contains(where: { $0 is PopoverBackgroundView }) else { return }
        let background = PopoverBackgroundView(frame: frameView.bounds)
        background.autoresizingMask = [.width, .height]
        frameView.addSubview(background, positioned: .below, relativeTo: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if showsNoteField { view.window?.makeFirstResponder(textView) }
    }

    private static func hairline() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private static func textButton(_ title: String, color: NSColor, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
        return button
    }

    private func updateSwatches() {
        let current = (library?.displayColor(of: annotation) ?? annotation.color).usingColorSpace(.deviceRGB)
        for (index, button) in swatches.enumerated() {
            let candidate = palette[index].nsColor.usingColorSpace(.deviceRGB)
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
            button.setAccessibilityValue(isCurrent ? L("Selected") : nil)
        }
    }

    @objc private func pickColor(_ sender: NSButton) {
        guard palette.indices.contains(sender.tag) else { return }
        library?.setColor(annotation, to: palette[sender.tag])
        updateSwatches()
    }

    @objc private func finish() { popover?.performClose(nil) }

    @objc private func deleteAnnotation() {
        isDeleted = true
        library?.deleteAnnotation(annotation)
        popover?.performClose(nil)
    }

    func popoverWillClose(_ notification: Notification) {
        guard !isDeleted, showsNoteField else { return }
        library?.finishEditing(annotation, note: textView.string)
    }
}

/// Fills the popover frame with the text background color, which follows the
/// light and dark appearance.
private final class PopoverBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
