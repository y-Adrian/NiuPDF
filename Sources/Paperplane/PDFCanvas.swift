import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    @EnvironmentObject private var library: ReaderLibrary
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = MarkupPDFView()
        view.readerLibrary = library
        // PDFKit asks for page overlays only while it builds page views for a
        // document, so the provider must be in place before the document is set.
        view.overlayProvider.library = library
        view.pageOverlayViewProvider = view.overlayProvider
        view.document = document
        view.autoScales = true
        view.displayMode = library.layoutMode.pdfDisplayMode
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 18, left: 30, bottom: 18, right: 30)
        view.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.12, alpha: 1)
                : NSColor(calibratedWhite: 0.91, alpha: 1)
        }
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 5
        view.displaysAsBook = library.layoutMode.displaysAsBook
        library.pdfView = view
        library.onEditAnnotation = { [weak view] annotation in
            // Let the context menu finish dismissing before the popover appears.
            DispatchQueue.main.async { view?.editAnnotation(annotation) }
        }
        library.onToolChange = { [weak view] in view?.toolDidChange() }
        library.commitPendingEdits = { [weak view] in view?.toolHandler.endTextEditing() }
        view.window?.isDocumentEdited = library.hasUnsavedChanges
        if let page = document.page(at: library.currentPageIndex) { view.go(to: page) }
        restorePendingZoom(on: view)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        library.applyLayout(to: view)
        if view.document !== document {
            view.document = document
            if let page = document.page(at: library.currentPageIndex) { view.go(to: page) }
            restorePendingZoom(on: view)
        }
        if library.pdfView !== view { library.pdfView = view }
    }

    /// Applying the zoom publishes `zoomScale`, which SwiftUI does not allow
    /// while it is creating or updating this view, so it waits one turn.
    private func restorePendingZoom(on view: PDFView) {
        DispatchQueue.main.async { [library] in library.applyPendingRestoredZoom(to: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    final class Coordinator: NSObject {
        private let library: ReaderLibrary
        init(library: ReaderLibrary) { self.library = library }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage,
                  let document = view.document else { return }
            let index = document.index(for: page)
            Task { @MainActor in
                library.updateCurrentPage(index)
                library.pageCount = document.pageCount
            }
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            Task { @MainActor in
                library.updateZoomScale(view.scaleFactor)
                // Note icons keep a constant on-screen size, so redraw them for the new scale.
                (view as? AnnotationOverlayHost)?.refreshAnnotationOverlays()
            }
        }
    }
}

final class MarkupToolIconButton: NSButton {
    let tool: AnnotationTool
    private(set) var isSelectedTool: Bool

    init(tool: AnnotationTool, selected: Bool, target: AnyObject, action: Selector) {
        self.tool = tool
        isSelectedTool = selected
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
        isBordered = false
        setAccessibilityElement(true)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    func setSelectedTool(_ selected: Bool) {
        guard isSelectedTool != selected else { return }
        isSelectedTool = selected
        setAccessibilityValue(selected ? L("Selected") : nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedTool {
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        MarkupGlyph.image(for: tool, side: 22).draw(
            in: bounds.insetBy(dx: 2, dy: 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}

final class MarkupColorSwatchButton: NSButton {
    private(set) var isSelectedColor: Bool

    init(selected: Bool, target: AnyObject, action: Selector) {
        isSelectedColor = selected
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 22) }

    func setSelectedColor(_ selected: Bool) {
        guard isSelectedColor != selected else { return }
        isSelectedColor = selected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedColor {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 1
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.withAlphaComponent(0.55).setFill()
            let diameter = max(0, min(bounds.width, bounds.height) - 6)
            let circle = CGRect(
                x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            NSBezierPath(ovalIn: circle).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(dirtyRect)
    }
}

/// Adds native PDF text markup actions to the selected text's contextual menu,
/// and opens the annotation editor when markup or a note icon is clicked.
private final class MarkupPDFView: PDFView, AnnotationOverlayHost {
    weak var readerLibrary: ReaderLibrary?
    let overlayProvider = AnnotationOverlayProvider()
    private var contextMenuSelection: PDFSelection?
    private var editorPopover: NSPopover?
    private var pendingMarkupClick: PDFAnnotation?
    /// Set while a markup tool waits for the text selection a drag produces.
    private var awaitsToolSelection = false
    private(set) lazy var toolHandler = AnnotationToolHandler(view: self, library: readerLibrary, overlayProvider: overlayProvider)
    private lazy var selectionToolbar = SelectionToolbar(view: self, library: readerLibrary)

    func refreshAnnotationOverlays() {
        overlayProvider.refreshAll()
    }

    func toolDidChange() {
        selectionToolbar.hide()
        toolHandler.toolDidChange()
        // Keep selected text for the markup tools, which can mark it.
        if readerLibrary?.activeTool.marksText != true { clearSelection() }
        window?.invalidateCursorRects(for: self)
    }

    /// Tools that place or draw annotations take the mouse first. Otherwise a
    /// plain click on markup opens its editor, as in PDF Expert, and dragging
    /// selects text, which an active markup tool then marks. PDFView may track
    /// the drag inside `mouseDown`, so the click is resolved after it returns
    /// or in `mouseUp`, whichever comes.
    override func mouseDown(with event: NSEvent) {
        selectionToolbar.hide()
        if toolHandler.mouseDown(event) { return }
        let tool = readerLibrary?.activeTool ?? .select
        pendingMarkupClick = tool == .select && event.clickCount == 1 ? markup(at: event) : nil
        awaitsToolSelection = tool.marksText
        super.mouseDown(with: event)
        if mouseUpAlreadyHandled() {
            resolveClick()
        } else if awaitsToolSelection {
            // The button state can lag right after PDFView's own drag tracking
            // returns; check again next turn in case no mouseUp follows.
            DispatchQueue.main.async { [weak self] in
                if self?.mouseUpAlreadyHandled() == true { self?.resolveClick() }
            }
        }
    }

    /// True when PDFView tracked the whole drag inside `mouseDown`: the button is
    /// up and no mouse-up is left for `mouseUp` to receive.
    private func mouseUpAlreadyHandled() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return false }
        let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date.distantPast, inMode: .default, dequeue: false)
        return pending == nil
    }

    override func mouseDragged(with event: NSEvent) {
        if toolHandler.mouseDragged(event) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if toolHandler.mouseUp(event) { return }
        super.mouseUp(with: event)
        resolveClick()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        toolHandler.cursor?.set()
    }

    /// Esc leaves the active tool for plain selection.
    /// Esc leaves the active tool, then clears the annotation selection.
    /// With annotations selected, Delete removes them and the arrow keys
    /// nudge them by 1 pt (10 pt with Shift).
    override func keyDown(with event: NSEvent) {
        selectionToolbar.hide()
        guard let readerLibrary else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            if readerLibrary.activeTool != .select {
                readerLibrary.activeTool = .select
                return
            }
            if !readerLibrary.selectedAnnotations.isEmpty {
                readerLibrary.clearAnnotationSelection()
                return
            }
        }
        if !readerLibrary.selectedAnnotations.isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 51, 117:   // Delete, Forward Delete
                readerLibrary.deleteSelectedAnnotations()
                return
            case 123: readerLibrary.nudgeSelection(dx: -step, dy: 0); return
            case 124: readerLibrary.nudgeSelection(dx: step, dy: 0); return
            case 125: readerLibrary.nudgeSelection(dx: 0, dy: -step); return
            case 126: readerLibrary.nudgeSelection(dx: 0, dy: step); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // Edit menu: with annotations selected, Copy, Cut and Paste act on them;
    // otherwise Copy copies selected text as before.
    override func copy(_ sender: Any?) {
        if readerLibrary?.copySelectedAnnotations() == true { return }
        super.copy(sender)
    }

    @objc func cut(_ sender: Any?) {
        readerLibrary?.cutSelectedAnnotations()
    }

    @objc func paste(_ sender: Any?) {
        readerLibrary?.pasteAnnotations()
    }

    /// PDFView validates its menu items (Copy only with selected text) but does
    /// not declare it publicly, so its implementation is called directly for
    /// everything this view does not decide itself.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return readerLibrary?.hasCopyableSelection == true || pdfViewValidates(menuItem)
        case #selector(cut(_:)):
            return readerLibrary?.hasCopyableSelection == true
        case #selector(paste(_:)):
            return readerLibrary?.canPasteAnnotations == true
        default:
            return pdfViewValidates(menuItem)
        }
    }

    private func pdfViewValidates(_ menuItem: NSMenuItem) -> Bool {
        let selector = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard PDFView.instancesRespond(to: selector),
              let implementation = class_getMethodImplementation(PDFView.self, selector) else { return true }
        typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> Bool
        return unsafeBitCast(implementation, to: Validate.self)(self, selector, menuItem)
    }

    private func resolveClick() {
        if awaitsToolSelection {
            awaitsToolSelection = false
            if let selection = currentSelection,
               !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readerLibrary?.applyActiveTool(to: selection)
            }
        }
        resolvePendingMarkupClick()
        showSelectionToolbarIfNeeded()
    }

    /// Text selected with the select tool gets the floating markup row.
    private func showSelectionToolbarIfNeeded() {
        guard readerLibrary?.activeTool == .select,
              let selection = currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectionToolbar.show(for: selection)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { selectionToolbar.hide() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func resolvePendingMarkupClick() {
        guard let annotation = pendingMarkupClick else { return }
        pendingMarkupClick = nil
        guard (currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        readerLibrary?.select(annotation, extending: NSEvent.modifierFlags.contains(.shift))
        editAnnotation(annotation)
    }

    /// Markup whose text lines, not just its overall bounds, contain the click.
    private func markup(at event: NSEvent) -> PDFAnnotation? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let point = convert(viewPoint, to: page)
        return page.annotations.last { annotation in
            MarkupEngine.isMarkup(annotation)
                && MarkupEngine.lineRects(of: annotation).contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
        }
    }

    func editAnnotation(_ annotation: PDFAnnotation) {
        guard let readerLibrary, window != nil, let page = annotation.page else { return }
        editorPopover?.close()
        let controller = AnnotationEditorController(annotation: annotation, library: readerLibrary)
        let popover = NSPopover()
        popover.behavior = .transient
        // The editor is always a light card, also in dark mode.
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = controller
        popover.delegate = controller
        controller.popover = popover
        editorPopover = popover
        let lines = MarkupEngine.isMarkup(annotation) ? MarkupEngine.lineRects(of: annotation) : [annotation.bounds]
        let anchor = lines.max(by: { $0.maxY < $1.maxY }) ?? annotation.bounds
        popover.show(relativeTo: convert(anchor, from: page), of: self, preferredEdge: .maxY)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        selectionToolbar.hide()
        guard let selection = selectionForContextMenu(at: event),
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            contextMenuSelection = nil
            return super.menu(for: event)
        }

        contextMenuSelection = selection
        setCurrentSelection(selection, animate: false)
        let menu = super.menu(for: event) ?? NSMenu()
        removeNativeAnnotationItems(from: menu)
        var editingItems: [NSMenuItem] = []

        editingItems.append(markupRow())
        if readerLibrary?.notedMarkup(in: selection) != nil {
            editingItems.append(actionItem(L("Edit Note"), action: #selector(addNote)))
            editingItems.append(actionItem(L("Delete Note"), action: #selector(removeNote)))
        } else {
            editingItems.append(actionItem(L("Add Note"), action: #selector(addNote)))
        }
        editingItems.append(.separator())

        for item in editingItems.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }


    private func selectionForContextMenu(at event: NSEvent) -> PDFSelection? {
        if let selection = currentSelection,
           !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selection
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        return page.selectionForWord(at: pagePoint)
    }

    /// Removes PDFKit's own markup and note items, which this menu replaces.
    /// They are matched by action, not title, because titles follow the UI
    /// language (for example "Remove Note" and "移除备注" are both `_removeNote:`).
    private func removeNativeAnnotationItems(from menu: NSMenu) {
        let nativeActionWords = ["markup", "note", "highlight", "underline", "strike"]
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            if let submenu = item.submenu {
                removeNativeAnnotationItems(from: submenu)
                if submenu.items.isEmpty {
                    menu.removeItem(at: index)
                    continue
                }
            }
            // PDFKit's markup palette is a custom view item with no title or action.
            if item.view != nil && item.title.isEmpty {
                menu.removeItem(at: index)
                continue
            }
            let action = item.action.map(NSStringFromSelector)?.lowercased() ?? ""
            if nativeActionWords.contains(where: action.contains) {
                menu.removeItem(at: index)
            }
        }
        // Drop separators left doubled or dangling at the top by the removals.
        for index in menu.items.indices.reversed() where menu.items[index].isSeparatorItem {
            if index == 0 || menu.items[index - 1].isSeparatorItem { menu.removeItem(at: index) }
        }
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private static let menuMarkupTools = AnnotationTool.markupTools
    /// The markup tool the context menu's colors apply to.
    private var menuMarkupTool: AnnotationTool = .highlight
    private var menuToolButtons: [MarkupToolIconButton] = []
    private var menuSwatches: [MarkupColorSwatchButton] = []

    /// One row: the three markup tools, then the colors for the chosen tool.
    /// Clicking a tool marks the text in that tool's current color and selects
    /// it; clicking a color marks the text with the selected tool in that color.
    private func markupRow() -> NSMenuItem {
        menuMarkupTool = readerLibrary?.lastMarkupTool ?? .highlight
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
        stack.setContentHuggingPriority(.required, for: .horizontal)

        menuToolButtons = Self.menuMarkupTools.enumerated().map { index, tool in
            let button = MarkupToolIconButton(tool: tool, selected: tool == menuMarkupTool, target: self, action: #selector(pickMarkupTool(_:)))
            button.tag = index
            button.toolTip = tool.title
            button.setAccessibilityLabel(tool.title)
            return button
        }
        menuToolButtons.forEach(stack.addArrangedSubview)
        // A wider gap separates the tools from their colors.
        if let last = menuToolButtons.last { stack.setCustomSpacing(10, after: last) }

        let current = readerLibrary?.color(for: menuMarkupTool) ?? .yellow
        menuSwatches = MarkupColor.allCases.enumerated().map { index, color in
            let button = MarkupColorSwatchButton(selected: color == current, target: self, action: #selector(applyColorFromRow(_:)))
            button.tag = index
            button.contentTintColor = color.nsColor
            button.toolTip = color.title
            button.setAccessibilityLabel(color.title)
            return button
        }
        menuSwatches.forEach(stack.addArrangedSubview)

        // The menu widens its item views to its own width; keep the row at its
        // natural size against the leading edge instead of spreading it out.
        let size = stack.fittingSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func pickMarkupTool(_ sender: MarkupToolIconButton) {
        guard let contextMenuSelection, let readerLibrary else { return }
        menuMarkupTool = sender.tool
        for button in menuToolButtons { button.setSelectedTool(button === sender) }
        readerLibrary.toggleMarkup(sender.tool, in: contextMenuSelection)
        let current = readerLibrary.color(for: sender.tool)
        for (index, swatch) in menuSwatches.enumerated() { swatch.setSelectedColor(MarkupColor.allCases[index] == current) }
    }

    @objc private func applyColorFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let contextMenuSelection, let readerLibrary else { return }
        let color = MarkupColor.allCases[sender.tag]
        readerLibrary.applyMarkup(menuMarkupTool, color: color, to: contextMenuSelection)
        for swatch in menuSwatches { swatch.setSelectedColor(swatch === sender) }
    }

    @objc private func addNote() {
        guard let contextMenuSelection else { return }
        readerLibrary?.addNote(in: contextMenuSelection)
    }
    @objc private func removeNote() {
        guard let contextMenuSelection else { return }
        readerLibrary?.removeNote(in: contextMenuSelection)
    }
}

/// Page thumbnails with page management: click selects, ⌘-click toggles,
/// ⇧-click selects a range; dragging reorders the selected pages, and PDFs
/// dropped from Finder are inserted where they land.
struct ThumbnailSidebar: View {
    @EnvironmentObject private var library: ReaderLibrary
    let document: PDFDocument
    /// Annotation revision; a change re-renders thumbnails so new markup shows.
    let revision: Int
    /// Insertion index under a drag, drawn as a line.
    @State private var dropIndex: Int?
    @State private var rowHeights: [Int: CGFloat] = [:]

    private var pages: [PDFPage] { (0..<document.pageCount).compactMap { document.page(at: $0) } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                        row(index: index, page: page)
                            .id(index)
                    }
                    insertionLine(visible: dropIndex == pages.count)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onPreferenceChange(RowHeightKey.self) { rowHeights = $0 }
            .onChange(of: library.currentPageIndex) { value in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private func isSelected(_ index: Int) -> Bool {
        library.selectedPages.isEmpty ? index == library.currentPageIndex : library.selectedPages.contains(index)
    }

    private func row(index: Int, page: PDFPage) -> some View {
        VStack(spacing: 0) {
            insertionLine(visible: dropIndex == index)
            VStack(spacing: 6) {
                thumbnail(for: page, selected: isSelected(index), revision: revision)
                    .overlay(alignment: .topTrailing) {
                        if library.bookmark(onPage: index) != nil {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.accentColor)
                                .padding(.trailing, 10)
                                .offset(y: 2)
                                .accessibilityLabel(L("Bookmarked"))
                        }
                    }
                Text(L("Page %ld", index + 1))
                    .font(.caption)
                    .foregroundStyle(index == library.currentPageIndex ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: RowHeightKey.self, value: [index: geometry.size.height])
        })
        .onTapGesture { library.selectPage(index, mode: Self.selectionMode()) }
        .onDrag {
            // Dragging an unselected page moves just that page.
            if !library.selectedPages.contains(index) { library.selectPage(index, mode: .single) }
            library.draggedPages = library.targetPages
            return NSItemProvider(object: Self.dragMarker as NSString)
        }
        .onDrop(of: [.fileURL, .plainText], delegate: PageDropDelegate(
            index: index,
            rowHeight: rowHeights[index] ?? 200,
            library: library,
            dropIndex: $dropIndex
        ))
        .contextMenu { pageMenu(for: index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected(index) ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func pageMenu(for index: Int) -> some View {
        // A right-click outside the selection acts on that page alone.
        let pages = library.selectedPages.contains(index) ? library.targetPages : IndexSet(integer: index)
        Button(L("Rotate Left")) { library.rotatePages(pages, by: -90) }
        Button(L("Rotate Right")) { library.rotatePages(pages, by: 90) }
        Divider()
        Button(L("Insert Blank Page")) { library.insertBlankPage(after: pages.last ?? index) }
        Button(L("Insert Pages from File…")) { library.insertPagesFromFiles(at: (pages.last ?? index) + 1) }
        Button(L("Extract Pages…")) { library.extractPages(pages) }
        Divider()
        Button(L("Delete Pages"), role: .destructive) { library.deletePages(pages) }
            .disabled(pages.count >= library.pageCount)
    }

    private func insertionLine(visible: Bool) -> some View {
        Capsule()
            .fill(visible ? Color.accentColor : .clear)
            .frame(height: 3)
            .padding(.horizontal, 6)
    }

    static let dragMarker = "paperplane.pages"

    private static func selectionMode() -> ReaderLibrary.PageSelectionMode {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return .range }
        if flags.contains(.command) { return .toggle }
        return .single
    }
}

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Drops on a thumbnail row: the upper half inserts before the page, the
/// lower half after it. Pages dragged within the sidebar move; PDF files from
/// Finder are inserted.
private struct PageDropDelegate: DropDelegate {
    let index: Int
    let rowHeight: CGFloat
    let library: ReaderLibrary
    @Binding var dropIndex: Int?

    private func insertionIndex(_ info: DropInfo) -> Int {
        info.location.y < rowHeight / 2 ? index : index + 1
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropIndex = insertionIndex(info)
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        if dropIndex == index || dropIndex == index + 1 { dropIndex = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let destination = insertionIndex(info)
        dropIndex = nil
        let files = info.itemProviders(for: [.fileURL])
        if !files.isEmpty {
            let collected = UncheckedSendable(value: NSMutableArray())
            let group = DispatchGroup()
            for provider in files {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension.lowercased() == "pdf" {
                        DispatchQueue.main.async { collected.value.add(url) }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [library] in
                let urls = collected.value.compactMap { $0 as? URL }
                MainActor.assumeIsolated {
                    if !urls.isEmpty { library.insertPages(from: urls, at: destination) }
                }
            }
            return true
        }
        guard let pages = library.draggedPages else { return false }
        library.draggedPages = nil
        library.movePages(pages, to: destination)
        return true
    }
}

/// The outline tab: the reader's bookmarks, then the PDF's own contents.
struct PDFOutlineSidebar: View {
    let document: PDFDocument
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BookmarkSection()
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Contents"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let root = document.outlineRoot, root.numberOfChildren > 0 {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(0..<root.numberOfChildren, id: \.self) { index in
                                if let item = root.child(at: index) {
                                    PDFOutlineEntry(item: item, document: document, onSelect: onSelect)
                                }
                            }
                        }
                    } else {
                        Text(L("This PDF has no embedded outline."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SearchResultsSidebar: View {
    let results: [PDFSelection]
    let document: PDFDocument
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(results.indices, id: \.self) { index in
                    if let page = results[index].pages.first {
                        Button { onSelect(index) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Page %ld", document.index(for: page) + 1))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(context(forResultAt: index, on: page))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(selectedIndex == index ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// PDFSelection does not expose its text range, so locate the match by its
    /// ordinal among this page's results; searching only for the first occurrence
    /// gave every match on a page the same context.
    private func context(forResultAt index: Int, on page: PDFPage) -> String {
        let selection = results[index]
        guard let text = page.string, let needle = selection.string, !needle.isEmpty else {
            return selection.string ?? L("Couldn’t extract the matched text")
        }
        let ordinal = results[..<index].filter { $0.pages.first === page }.count
        var searchStart = text.startIndex
        var match: Range<String.Index>?
        for _ in 0...ordinal {
            guard let found = text.range(of: needle, options: .caseInsensitive, range: searchStart..<text.endIndex) else { break }
            match = found
            searchStart = found.upperBound
        }
        guard let range = match else { return needle }
        let start = text.index(range.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 45, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// All annotations in page order. Click reveals and selects one; ⌘- or
/// ⇧-click selects several, which Delete or the context menu removes together.
struct AnnotationListSidebar: View {
    @EnvironmentObject private var library: ReaderLibrary
    let items: [AnnotationListItem]

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "highlighter")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(L("No Annotations Yet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L("Select text and Control-click to highlight, underline, or add a note."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            Button { choose(item) } label: {
                                row(for: item)
                                    .background(library.isSelected(item.annotation) ? Color.accentColor.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func choose(_ item: AnnotationListItem) {
        let flags = NSEvent.modifierFlags
        library.select(item.annotation, extending: flags.contains(.command) || flags.contains(.shift))
        library.reveal(item.annotation)
    }

    @ViewBuilder
    private func menu(for item: AnnotationListItem) -> some View {
        let count = library.selectedAnnotations.count
        if library.isSelected(item.annotation), count > 1 {
            Button(L("Delete %ld Annotations", count), role: .destructive) { library.deleteSelectedAnnotations() }
        } else {
            Button(L("Delete Annotation"), role: .destructive) { library.deleteAnnotation(item.annotation) }
        }
    }

    private func row(for item: AnnotationListItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: item.annotation.color.withAlphaComponent(1)))
                .frame(width: 9, height: 9)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("%@ · Page %ld", item.kind, item.pageIndex + 1))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(item.text.isEmpty ? L("(No text)") : item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(item.text.isEmpty ? .tertiary : .primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !item.note.isEmpty {
                    Label(item.note, systemImage: "text.bubble")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .contentShape(Rectangle())
    }
}

private struct PDFOutlineEntry: View {
    let item: PDFOutline
    let document: PDFDocument
    let onSelect: (Int) -> Void
    @State private var isExpanded = true

    var body: some View {
        if item.numberOfChildren > 0 {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(0..<item.numberOfChildren, id: \.self) { index in
                    if let child = item.child(at: index) {
                        PDFOutlineEntry(item: child, document: document, onSelect: onSelect)
                    }
                }
            } label: {
                row
            }
            .disclosureGroupStyle(.automatic)
        } else {
            row
        }
    }

    private var row: some View {
        Button {
            guard let page = item.destination?.page else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            onSelect(index)
        } label: {
            Text(item.label ?? L("Untitled"))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label ?? L("Untitled"))
    }
}

/// The sidebar re-renders on every library change (page turns, zoom steps), so
/// rasterizing each visible page again every time made scrolling and zooming stutter.
/// Each entry remembers the annotation revision it was drawn at, so several
/// open documents, each with its own revision, do not clear each other's thumbnails.
@MainActor
private enum ThumbnailCache {
    private final class Entry {
        let image: NSImage
        let revision: Int
        init(image: NSImage, revision: Int) {
            self.image = image
            self.revision = revision
        }
    }

    private static let images = NSCache<PDFPage, Entry>()

    static func image(for page: PDFPage, revision: Int) -> NSImage {
        if let entry = images.object(forKey: page), entry.revision == revision { return entry.image }
        let image = page.thumbnail(of: CGSize(width: 150, height: 190), for: .mediaBox)
        images.setObject(Entry(image: image, revision: revision), forKey: page)
        return image
    }
}

@MainActor
private func thumbnail(for page: PDFPage, selected: Bool, revision: Int) -> some View {
    let image = ThumbnailCache.image(for: page, revision: revision)
    return Group {
        if image.size.width > 0, image.size.height > 0 {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                .overlay(Image(systemName: "doc.text").foregroundStyle(.secondary))
        }
    }
    .frame(maxWidth: 142, maxHeight: 176)
    .background(.white)
    .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
    .padding(5)
    .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
    }
}
