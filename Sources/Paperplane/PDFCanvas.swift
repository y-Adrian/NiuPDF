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
        guard let selection = currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return super.menu(for: event) }

        let menu = NSMenu()
        menu.addItem(actionItem("高亮", action: #selector(addHighlight)))
        menu.addItem(actionItem("下划线", action: #selector(addUnderline)))
        menu.addItem(actionItem("删除线", action: #selector(addStrikeOut)))
        return menu
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func addHighlight() { readerLibrary?.highlightSelection() }
    @objc private func addUnderline() { readerLibrary?.underlineSelection() }
    @objc private func addStrikeOut() { readerLibrary?.strikeOutSelection() }
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
