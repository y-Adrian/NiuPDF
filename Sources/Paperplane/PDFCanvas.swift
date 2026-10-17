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

/// Adds native PDF text markup actions to the selected text's contextual menu.
private final class MarkupPDFView: PDFView {
    weak var readerLibrary: ReaderLibrary?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let selection = selectionForContextMenu(at: event),
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return super.menu(for: event) }

        setCurrentSelection(selection, animate: false)
        let menu = super.menu(for: event) ?? NSMenu()
        removeLegacyMarkupItems(from: menu)
        var editingItems: [NSMenuItem] = []

        editingItems.append(colorRow(icon: "highlighter", accessibilityPrefix: "高亮", iconAction: #selector(highlightFromIcon), colorAction: #selector(applyHighlightFromRow(_:)), customColorAction: #selector(chooseHighlightColor(_:)), selectedColor: readerLibrary?.selectedHighlightColor ?? .yellow))
        editingItems.append(colorRow(icon: "underline", accessibilityPrefix: "下划线", iconAction: #selector(toggleUnderlineFromIcon), colorAction: #selector(applyUnderlineFromRow(_:)), customColorAction: #selector(chooseUnderlineColor(_:)), selectedColor: readerLibrary?.selectedUnderlineColor ?? .yellow))
        editingItems.append(colorRow(icon: "strikethrough", accessibilityPrefix: "删除线", iconAction: #selector(toggleStrikeOutFromIcon), colorAction: #selector(applyStrikeOutFromRow(_:)), customColorAction: #selector(chooseStrikeOutColor(_:)), selectedColor: readerLibrary?.selectedStrikeOutColor ?? .yellow))
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
        icon: String,
        accessibilityPrefix: String,
        iconAction: Selector,
        colorAction: Selector,
        customColorAction: Selector,
        selectedColor: MarkupColor,
    ) -> NSMenuItem {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)

        let iconButton = NSButton(title: "", target: self, action: iconAction)
        iconButton.image = NSImage(systemSymbolName: icon, accessibilityDescription: accessibilityPrefix)
        iconButton.imagePosition = .imageOnly
        iconButton.isBordered = false
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

        let customColorButton = NSButton(title: "", target: self, action: customColorAction)
        customColorButton.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "自定义颜色")
        customColorButton.imagePosition = .imageOnly
        customColorButton.isBordered = false
        customColorButton.contentTintColor = MarkupColor.allCases.contains(selectedColor)
            ? NSColor.secondaryLabelColor
            : selectedColor.nsColor
        customColorButton.setFrameSize(NSSize(width: 24, height: 24))
        customColorButton.toolTip = "打开色盘或输入十六进制颜色"
        customColorButton.setAccessibilityLabel(customColorButton.toolTip ?? "自定义颜色")
        stack.addArrangedSubview(customColorButton)

        let controlCount = MarkupColor.allCases.count + 2
        let rowWidth = CGFloat(controlCount * 24 + (controlCount - 1) * 4 + 20)
        stack.frame = NSRect(x: 0, y: 0, width: rowWidth, height: 28)
        let item = NSMenuItem()
        item.view = stack
        return item
    }

    @objc private func highlightFromIcon() { readerLibrary?.highlightSelection() }
    @objc private func applyHighlightFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag) else { return }
        readerLibrary?.applyHighlight(color: MarkupColor.allCases[sender.tag])
    }
    @objc private func toggleNote() { readerLibrary?.toggleNoteAnnotation() }
    @objc private func toggleUnderlineFromIcon() { readerLibrary?.underlineSelection() }
    @objc private func applyUnderlineFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag) else { return }
        readerLibrary?.applyUnderline(color: MarkupColor.allCases[sender.tag])
    }
    @objc private func toggleStrikeOutFromIcon() { readerLibrary?.strikeOutSelection() }
    @objc private func applyStrikeOutFromRow(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag) else { return }
        readerLibrary?.applyStrikeOut(color: MarkupColor.allCases[sender.tag])
    }

    @objc private func chooseHighlightColor(_ sender: NSButton) {
        presentColorPicker(from: sender, initialColor: readerLibrary?.selectedHighlightColor ?? .yellow) { [weak self] color in
            self?.readerLibrary?.applyHighlight(color: color)
        }
    }

    @objc private func chooseUnderlineColor(_ sender: NSButton) {
        presentColorPicker(from: sender, initialColor: readerLibrary?.selectedUnderlineColor ?? .yellow) { [weak self] color in
            self?.readerLibrary?.applyUnderline(color: color)
        }
    }

    @objc private func chooseStrikeOutColor(_ sender: NSButton) {
        presentColorPicker(from: sender, initialColor: readerLibrary?.selectedStrikeOutColor ?? .yellow) { [weak self] color in
            self?.readerLibrary?.applyStrikeOut(color: color)
        }
    }

    private func presentColorPicker(
        from button: NSButton,
        initialColor: MarkupColor,
        apply: @escaping (MarkupColor) -> Void
    ) {
        let panel = MarkupColorPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "自定义标注颜色"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.contentViewController = NSHostingController(
            rootView: MarkupColorPickerPopover(initialColor: initialColor) { [weak self, weak panel] color in
                apply(color)
                panel?.close()
                if self?.colorPickerPanel === panel { self?.colorPickerPanel = nil }
            }
        )
        colorPickerPanel = panel

        if let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            panel.setFrameTopLeftPoint(NSPoint(x: buttonRect.minX, y: buttonRect.maxY + 8))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var colorPickerPanel: NSPanel?
}

private final class MarkupColorPickerPanel: NSPanel {
    override func close() {
        NSColorPanel.shared.close()
        super.close()
    }
}

private struct MarkupColorPickerPopover: View {
    @State private var selectedColor: NSColor
    @State private var hexText: String
    @State private var validationMessage: String?

    let onApply: (MarkupColor) -> Void

    init(initialColor: MarkupColor, onApply: @escaping (MarkupColor) -> Void) {
        _selectedColor = State(initialValue: initialColor.nsColor)
        _hexText = State(initialValue: "#\(initialColor.hex)")
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择颜色")
                Spacer()
                MarkupColorWell(color: $selectedColor)
                    .frame(width: 44, height: 24)
            }
            HStack(spacing: 8) {
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyHexColor)
                Button("应用", action: applyHexColor)
                    .keyboardShortcut(.defaultAction)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onChange(of: selectedColor) { newColor in
            if let color = newColor.usingColorSpace(.deviceRGB) {
                hexText = String(
                    format: "#%02X%02X%02X",
                    Int((color.redComponent * 255).rounded()),
                    Int((color.greenComponent * 255).rounded()),
                    Int((color.blueComponent * 255).rounded())
                )
                validationMessage = nil
            }
        }
        .onChange(of: hexText) { newValue in
            guard let color = MarkupColor.custom(hex: newValue) else { return }
            selectedColor = color.nsColor
            validationMessage = nil
        }
    }

    private func applyHexColor() {
        guard let color = MarkupColor.custom(hex: hexText) else {
            validationMessage = "请输入有效的六位十六进制颜色，例如 #3A7BD5。"
            return
        }
        selectedColor = color.nsColor
        onApply(color)
    }
}

private struct MarkupColorWell: NSViewRepresentable {
    @Binding var color: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(frame: .zero)
        colorWell.color = color
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        return colorWell
    }

    func updateNSView(_ colorWell: NSColorWell, context: Context) {
        context.coordinator.parent = self
        if !colorWell.color.isEqual(color) { colorWell.color = color }
    }

    final class Coordinator: NSObject {
        var parent: MarkupColorWell

        init(_ parent: MarkupColorWell) { self.parent = parent }

        @objc func colorChanged(_ sender: NSColorWell) {
            parent.color = sender.color
        }
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
