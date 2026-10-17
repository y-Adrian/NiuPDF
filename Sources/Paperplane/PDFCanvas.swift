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
        self.target = target
        self.action = action
        isBordered = false
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let box = bounds.insetBy(dx: 2.5, dy: 2.5)
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
        let y = style == .underline ? origin.y + 1.5 : origin.y + glyphSize.height * 0.56
        line.move(to: CGPoint(x: origin.x - 2, y: y))
        line.line(to: CGPoint(x: origin.x + glyphSize.width + 2, y: y))
        line.stroke()
    }
}

/// Adds native PDF text markup actions to the selected text's contextual menu.
private final class MarkupPDFView: PDFView, NSPopoverDelegate {
    weak var readerLibrary: ReaderLibrary?
    private var contextMenuSelection: PDFSelection?
    private var notePopover: NSPopover?
    private weak var expandedNote: CommentBubblePDFAnnotation?
    private var noteIconAnimationTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: false) {
            let pagePoint = convert(viewPoint, to: page)
            if let note = page.annotation(at: pagePoint) as? CommentBubblePDFAnnotation {
                toggleNotePopover(note, on: page)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func toggleNotePopover(_ note: CommentBubblePDFAnnotation, on page: PDFPage) {
        if expandedNote === note, notePopover?.isShown == true {
            notePopover?.performClose(nil)
            return
        }
        closeNotePopover()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.contentViewController = CommentNotePopoverViewController(note: note) { [weak self, weak note] contents in
            note?.contents = contents
            self?.needsDisplay = true
        }
        expandedNote = note
        notePopover = popover
        animateNoteIcon(note, to: 1)
        popover.show(relativeTo: convert(note.bounds, from: page), of: self, preferredEdge: .maxY)
    }

    private func closeNotePopover() {
        notePopover?.delegate = nil
        if notePopover?.isShown == true { notePopover?.performClose(nil) }
        if let expandedNote { animateNoteIcon(expandedNote, to: 0) }
        expandedNote = nil
        notePopover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if let expandedNote { animateNoteIcon(expandedNote, to: 0) }
        expandedNote = nil
        notePopover = nil
    }

    private func animateNoteIcon(_ note: CommentBubblePDFAnnotation, to target: CGFloat) {
        noteIconAnimationTimer?.invalidate()
        let start = note.expansionProgress
        let startTime = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = 0.18
        noteIconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self, weak note] timer in
            guard let self, let note else {
                timer.invalidate()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let linearProgress = min(1, elapsed / duration)
            let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
            note.expansionProgress = start + (target - start) * easedProgress
            self.needsDisplay = true
            if linearProgress >= 1 {
                note.expansionProgress = target
                timer.invalidate()
                self.noteIconAnimationTimer = nil
                self.needsDisplay = true
            }
        }
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
        var editingItems: [NSMenuItem] = []

        editingItems.append(colorRow(iconStyle: .highlight, accessibilityPrefix: "高亮", iconAction: #selector(highlightFromIcon), colorAction: #selector(applyHighlightFromRow(_:)), selectedColor: readerLibrary?.selectedHighlightColor ?? .yellow))
        editingItems.append(colorRow(iconStyle: .underline, accessibilityPrefix: "下划线", iconAction: #selector(toggleUnderlineFromIcon), colorAction: #selector(applyUnderlineFromRow(_:)), selectedColor: readerLibrary?.selectedUnderlineColor ?? .yellow))
        editingItems.append(colorRow(iconStyle: .strikethrough, accessibilityPrefix: "删除线", iconAction: #selector(toggleStrikeOutFromIcon), colorAction: #selector(applyStrikeOutFromRow(_:)), selectedColor: readerLibrary?.selectedStrikeOutColor ?? .yellow))
        let noteTitle = readerLibrary?.hasNoteAnnotationForSelection() == true ? "移除标注" : "添加标注"
        editingItems.append(actionItem(noteTitle, action: #selector(toggleNote)))
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

        let iconButton = MarkupToolIconButton(style: iconStyle, target: self, action: iconAction)
        iconButton.setFrameSize(NSSize(width: 24, height: 24))
        iconButton.toolTip = accessibilityPrefix == "高亮" ? "添加当前颜色高亮" : "使用当前颜色切换\(accessibilityPrefix)"
        iconButton.setAccessibilityLabel(iconButton.toolTip ?? accessibilityPrefix)
        stack.addArrangedSubview(iconButton)

        for (index, color) in MarkupColor.allCases.enumerated() {
            let button = NSButton(title: "", target: self, action: colorAction)
            button.tag = index
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: color.title)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = color.nsColor
            button.setFrameSize(NSSize(width: 24, height: 24))
            button.toolTip = "\(color.title)\(accessibilityPrefix)"
            button.setAccessibilityLabel(button.toolTip ?? color.title)
            if color == selectedColor {
                button.layer = CALayer()
                button.wantsLayer = true
                button.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
                button.layer?.borderWidth = 1
                button.layer?.cornerRadius = 12
            }
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
    }
    @objc private func toggleNote() { readerLibrary?.toggleNoteAnnotation() }
    @objc private func toggleUnderlineFromIcon() { readerLibrary?.underlineSelection() }
    @objc private func applyUnderlineFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let contextMenuSelection else { return }
        readerLibrary?.applyUnderline(color: MarkupColor.allCases[sender.tag], to: contextMenuSelection)
    }
    @objc private func toggleStrikeOutFromIcon() { readerLibrary?.strikeOutSelection() }
    @objc private func applyStrikeOutFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let contextMenuSelection else { return }
        readerLibrary?.applyStrikeOut(color: MarkupColor.allCases[sender.tag], to: contextMenuSelection)
    }

}

struct ThumbnailSidebar: View {
    let document: PDFDocument
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
                                    thumbnail(for: page, selected: selectedIndex == index)
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
                                Text(context(for: results[index], on: page))
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

    private func context(for selection: PDFSelection, on page: PDFPage) -> String {
        guard let text = page.string, let needle = selection.string, !needle.isEmpty,
              let range = text.range(of: needle, options: .caseInsensitive) else {
            return selection.string ?? "无法提取匹配文本"
        }
        let start = text.index(range.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 45, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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

private func thumbnail(for page: PDFPage, selected: Bool) -> some View {
    let image = page.thumbnail(of: CGSize(width: 150, height: 190), for: .mediaBox)
    return Group {
        if let data = image.tiffRepresentation, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
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
