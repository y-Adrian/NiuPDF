import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    @EnvironmentObject private var library: ReaderLibrary
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = MarkupPDFView()
        view.readerLibrary = library
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
        library.onNoteCreated = { [weak view] note, page in
            // Let the context menu finish dismissing before the popover appears.
            DispatchQueue.main.async { view?.editNote(note, on: page) }
        }
        view.window?.isDocumentEdited = library.hasUnsavedChanges
        if let page = document.page(at: library.currentPageIndex) { view.go(to: page) }
        library.applyPendingRestoredZoom(to: view)

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
            library.applyPendingRestoredZoom(to: view)
        }
        if library.pdfView !== view { library.pdfView = view }
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
            Task { @MainActor in library.updateZoomScale(view.scaleFactor) }
        }
    }
}

private final class MarkupToolIconButton: NSButton {
    enum Style {
        case highlight
        case underline
        case strikethrough
    }

    private let style: Style

    init(style: Style, target: AnyObject, action: Selector) {
        self.style = style
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let box = CGRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        if style == .highlight {
            NSColor.systemYellow.setFill()
            NSBezierPath(rect: box).fill()
        }

        let glyph = "A" as NSString
        let font = NSFont.systemFont(ofSize: 17, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let glyphSize = glyph.size(withAttributes: attributes)
        let origin = CGPoint(
            x: bounds.midX - glyphSize.width / 2,
            y: bounds.midY - glyphSize.height / 2
        )
        glyph.draw(at: origin, withAttributes: attributes)

        guard style != .highlight else { return }
        NSColor.systemRed.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1.6
        // AppKit's button drawing coordinates place the string's origin at the top
        // edge here, so the underline belongs near the far edge of the glyph box.
        let y = style == .underline ? origin.y + glyphSize.height - 2 : origin.y + glyphSize.height * 0.56
        line.move(to: CGPoint(x: origin.x - 2, y: y))
        line.line(to: CGPoint(x: origin.x + glyphSize.width + 2, y: y))
        line.stroke()
    }
}

private final class MarkupColorSwatchButton: NSButton {
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

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

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
            let diameter = max(0, min(bounds.width, bounds.height) - 10)
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

/// Popover editor for a `/Text` note's contents. Text is committed when the
/// popover closes, so clicking elsewhere keeps what was typed.
private final class NoteEditorController: NSViewController, NSPopoverDelegate {
    private let note: PDFAnnotation
    private weak var library: ReaderLibrary?
    private let textView = NSTextView()
    private var isDeleted = false
    weak var popover: NSPopover?

    init(note: PDFAnnotation, library: ReaderLibrary) {
        self.note = note
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
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
        textView.string = library?.noteContents(note) ?? ""
        scrollView.documentView = textView

        let deleteButton = NSButton(title: "删除笔记", target: self, action: #selector(deleteNote))
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

        let stack = NSStackView(views: [scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        scrollView.widthAnchor.constraint(equalToConstant: 260).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        buttons.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    @objc private func finish() { popover?.performClose(nil) }

    @objc private func deleteNote() {
        isDeleted = true
        library?.deleteAnnotation(note)
        popover?.performClose(nil)
    }

    func popoverWillClose(_ notification: Notification) {
        guard !isDeleted else { return }
        library?.setNoteContents(note, to: textView.string)
    }
}

/// Adds native PDF text markup actions to the selected text's contextual menu.
private final class MarkupPDFView: PDFView {
    weak var readerLibrary: ReaderLibrary?
    private var contextMenuSelection: PDFSelection?
    private var notePopover: NSPopover?

    /// Clicking a note opens its editor instead of starting a text selection.
    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1,
           let page = page(for: viewPoint, nearest: false),
           let note = page.annotation(at: convert(viewPoint, to: page)),
           note.type == "Text" {
            editNote(note, on: page)
            return
        }
        super.mouseDown(with: event)
    }

    func editNote(_ note: PDFAnnotation, on page: PDFPage) {
        guard let readerLibrary, window != nil else { return }
        notePopover?.close()
        let controller = NoteEditorController(note: note, library: readerLibrary)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = controller
        controller.popover = popover
        notePopover = popover
        let anchor = convert(note.bounds, from: page)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let selection = selectionForContextMenu(at: event),
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            contextMenuSelection = nil
            return super.menu(for: event)
        }

        contextMenuSelection = selection
        setCurrentSelection(selection, animate: false)
        let menu = super.menu(for: event) ?? NSMenu()
        removeLegacyMarkupItems(from: menu)
        removeNativeNoteItems(from: menu)
        var editingItems: [NSMenuItem] = []

        editingItems.append(colorRow(iconStyle: .highlight, accessibilityPrefix: "高亮", iconAction: #selector(highlightFromIcon), colorAction: #selector(applyHighlightFromRow(_:)), selectedColor: readerLibrary?.selectedHighlightColor ?? .yellow))
        editingItems.append(colorRow(iconStyle: .underline, accessibilityPrefix: "下划线", iconAction: #selector(toggleUnderlineFromIcon), colorAction: #selector(applyUnderlineFromRow(_:)), selectedColor: readerLibrary?.selectedUnderlineColor ?? .yellow))
        editingItems.append(colorRow(iconStyle: .strikethrough, accessibilityPrefix: "删除线", iconAction: #selector(toggleStrikeOutFromIcon), colorAction: #selector(applyStrikeOutFromRow(_:)), selectedColor: readerLibrary?.selectedStrikeOutColor ?? .yellow))
        let hasNote = readerLibrary?.hasNoteAnnotation(in: selection) == true
        editingItems.append(actionItem(hasNote ? "Remove Note" : "Add Note", action: #selector(toggleNoteAnnotation)))
        editingItems.append(.separator())

        for item in editingItems.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    private func removeNativeNoteItems(from menu: NSMenu) {
        let noteTitles: Set<String> = ["add note", "remove note"]
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            if let submenu = item.submenu { removeNativeNoteItems(from: submenu) }
            if noteTitles.contains(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                menu.removeItem(at: index)
            }
        }
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

    private func removeLegacyMarkupItems(from menu: NSMenu) {
        let legacyTitles = ["highlight", "underline", "strikethrough", "strike out", "高亮", "下划线", "删除线", "移除高亮"]
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            if let submenu = item.submenu {
                removeLegacyMarkupItems(from: submenu)
                if submenu.items.isEmpty {
                    menu.removeItem(at: index)
                    continue
                }
            }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // PDFKit's legacy markup palette is exposed as a blank-title custom view,
            // so title matching alone leaves the old colors and U/S buttons behind.
            if item.view != nil && title.isEmpty {
                menu.removeItem(at: index)
                continue
            }
            if !title.isEmpty && legacyTitles.contains(where: title.contains) {
                menu.removeItem(at: index)
            }
        }
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func colorRow(
        iconStyle: MarkupToolIconButton.Style,
        accessibilityPrefix: String,
        iconAction: Selector,
        colorAction: Selector,
        selectedColor: MarkupColor,
    ) -> NSMenuItem {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        stack.setContentHuggingPriority(.required, for: .horizontal)

        let iconButton = MarkupToolIconButton(style: iconStyle, target: self, action: iconAction)
        iconButton.setFrameSize(NSSize(width: 24, height: 24))
        iconButton.toolTip = accessibilityPrefix == "高亮" ? "添加当前颜色高亮" : "使用当前颜色切换\(accessibilityPrefix)"
        iconButton.setAccessibilityLabel(iconButton.toolTip ?? accessibilityPrefix)
        stack.addArrangedSubview(iconButton)

        for (index, color) in MarkupColor.allCases.enumerated() {
            let button = MarkupColorSwatchButton(selected: color == selectedColor, target: self, action: colorAction)
            button.tag = index
            button.contentTintColor = color.nsColor
            button.toolTip = "\(color.title)\(accessibilityPrefix)"
            button.setAccessibilityLabel(button.toolTip ?? color.title)
            stack.addArrangedSubview(button)
        }

        let controlCount = MarkupColor.allCases.count + 1
        let rowWidth = CGFloat(controlCount * 24 + (controlCount - 1) * 4 + 20)
        stack.frame = NSRect(x: 0, y: 0, width: rowWidth, height: 28)
        let item = NSMenuItem()
        item.view = stack
        return item
    }

    @objc private func highlightFromIcon() {
        guard let contextMenuSelection else { return }
        readerLibrary?.toggleHighlight(in: contextMenuSelection)
    }
    @objc private func applyHighlightFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let contextMenuSelection else { return }
        readerLibrary?.applyHighlight(color: MarkupColor.allCases[sender.tag], to: contextMenuSelection)
        updateSelectedSwatch(in: sender)
    }
    @objc private func toggleNoteAnnotation() {
        guard let contextMenuSelection else { return }
        readerLibrary?.toggleNoteAnnotation(in: contextMenuSelection)
    }
    @objc private func toggleUnderlineFromIcon() {
        guard let contextMenuSelection else { return }
        readerLibrary?.toggleUnderline(in: contextMenuSelection)
    }
    @objc private func applyUnderlineFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let contextMenuSelection else { return }
        readerLibrary?.applyUnderline(color: MarkupColor.allCases[sender.tag], to: contextMenuSelection)
        updateSelectedSwatch(in: sender)
    }
    @objc private func toggleStrikeOutFromIcon() {
        guard let contextMenuSelection else { return }
        readerLibrary?.toggleStrikeOut(in: contextMenuSelection)
    }
    @objc private func applyStrikeOutFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let contextMenuSelection else { return }
        readerLibrary?.applyStrikeOut(color: MarkupColor.allCases[sender.tag], to: contextMenuSelection)
        updateSelectedSwatch(in: sender)
    }

    private func updateSelectedSwatch(in sender: NSButton) {
        guard let stack = sender.superview as? NSStackView else { return }
        for case let swatch as MarkupColorSwatchButton in stack.arrangedSubviews {
            swatch.setSelectedColor(swatch === sender)
        }
    }

}

struct ThumbnailSidebar: View {
    let document: PDFDocument
    /// Annotation revision; a change re-renders thumbnails so new markup shows.
    let revision: Int
    @Binding var selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            Button {
                                selectedIndex = index
                                onSelect(index)
                            } label: {
                                VStack(spacing: 6) {
                                    thumbnail(for: page, selected: selectedIndex == index, revision: revision)
                                    Text("第 \(index + 1) 页")
                                        .font(.caption)
                                        .foregroundStyle(selectedIndex == index ? Color.accentColor : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: selectedIndex) { value in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }
}

struct PDFOutlineSidebar: View {
    let document: PDFDocument
    let onSelect: (Int) -> Void

    var body: some View {
        Group {
            if let root = document.outlineRoot, root.numberOfChildren > 0 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<root.numberOfChildren, id: \.self) { index in
                            if let item = root.child(at: index) {
                                PDFOutlineEntry(item: item, document: document, onSelect: onSelect)
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("没有文档大纲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("此 PDF 没有嵌入目录大纲。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
            }
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
                                Text("第 \(document.index(for: page) + 1) 页")
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
            return selection.string ?? "无法提取匹配文本"
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

struct AnnotationListSidebar: View {
    let items: [AnnotationListItem]
    let onSelect: (AnnotationListItem) -> Void
    let onDelete: (AnnotationListItem) -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "highlighter")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("还没有批注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("选中文字后右键即可高亮、划线或添加笔记。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: { row(for: item) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("删除批注", role: .destructive) { onDelete(item) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(for item: AnnotationListItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: item.annotation.color.withAlphaComponent(1)))
                .frame(width: 9, height: 9)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(item.kind) · 第 \(item.pageIndex + 1) 页")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(item.text.isEmpty ? "（无文字）" : item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(item.text.isEmpty ? .tertiary : .primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
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
            Text(item.label ?? "未命名条目")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label ?? "未命名条目")
    }
}

/// The sidebar re-renders on every library change (page turns, zoom steps), so
/// rasterizing each visible page again every time made scrolling and zooming stutter.
@MainActor
private enum ThumbnailCache {
    private static let images = NSCache<PDFPage, NSImage>()
    private static var revision = -1

    static func image(for page: PDFPage, revision: Int) -> NSImage {
        if revision != self.revision {
            images.removeAllObjects()
            self.revision = revision
        }
        if let image = images.object(forKey: page) { return image }
        let image = page.thumbnail(of: CGSize(width: 150, height: 190), for: .mediaBox)
        images.setObject(image, forKey: page)
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
