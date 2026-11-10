import AppKit
import PDFKit
import PaperplaneCore
import SwiftUI
import UniformTypeIdentifiers

/// One file in the merge list, with the pages to take from it.
struct MergeItem: Identifiable {
    let id = UUID()
    let url: URL
    /// The open window's document when the file is open, so unsaved changes
    /// are merged too; otherwise a copy read from disk.
    let document: PDFDocument
    /// Pages such as "1-3, 5"; empty means all pages.
    var pageRange = ""

    var name: String { url.lastPathComponent }

    /// Zero-based pages to take, or nil when the range is not valid.
    var pages: [Int]? { try? parsedPages() }

    /// Why the range is not valid, if it is not.
    var pageRangeError: String? {
        do {
            _ = try parsedPages()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func parsedPages() throws -> [Int] {
        let text = pageRange.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return Array(0..<document.pageCount) }
        return try PageRangeParser.pages(from: text, pageCount: document.pageCount)
    }
}

enum MergeError: LocalizedError {
    case destinationOpen(String)

    var errorDescription: String? {
        switch self {
        case let .destinationOpen(name): L("“%@” is open. Close it or choose another name.", name)
        }
    }
}

/// The files of the merge window, shared so menus can add to it.
@MainActor
final class MergeModel: ObservableObject {
    static let shared = MergeModel()

    @Published var items: [MergeItem] = []
    @Published var errorMessage: String?
    private let thumbnails = NSCache<PDFPage, NSImage>()

    /// Each page of the result, with the file it comes from.
    var previewPages: [(item: MergeItem, index: Int)] {
        items.flatMap { item in (item.pages ?? []).map { (item, $0) } }
    }

    var canMerge: Bool {
        !items.isEmpty && items.allSatisfy { $0.pages?.isEmpty == false }
    }

    func thumbnail(for page: PDFPage) -> NSImage {
        if let image = thumbnails.object(forKey: page) { return image }
        let image = page.thumbnail(of: CGSize(width: 150, height: 190), for: .mediaBox)
        thumbnails.setObject(image, forKey: page)
        return image
    }

    /// Adds PDFs at a position in the list (the end by default). A file opened
    /// in a reader window brings that window's document.
    func add(_ urls: [URL], at position: Int? = nil) {
        var added: [MergeItem] = []
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            if let library = AppModel.shared.library(showing: url), let document = library.document {
                added.append(MergeItem(url: url, document: document))
                continue
            }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            // Read into memory: access to a dropped file can end before the merge.
            guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else {
                errorMessage = L("“%@” couldn’t be read as a PDF.", url.lastPathComponent)
                continue
            }
            if document.isLocked, ReaderLibrary.askForPassword(unlocking: document, at: url) == nil { continue }
            added.append(MergeItem(url: url, document: document))
        }
        items.insert(contentsOf: added, at: min(position ?? items.count, items.count))
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func remove(_ ids: Set<MergeItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// Writes the merged PDF. A file open in a reader window is not replaced.
    func write(to url: URL) throws {
        if AppModel.shared.library(showing: url) != nil {
            throw MergeError.destinationOpen(url.lastPathComponent)
        }
        var pages: [PDFPage] = []
        for item in items {
            let source = MergeSource(document: item.document, pages: item.pages ?? [])
            if let library = AppModel.shared.openLibraries.first(where: { $0.document === item.document }) {
                // Copy the pages as they would be saved, notes in standard form.
                library.commitPendingEdits?()
                pages += library.withNativeNotesRestored { DocumentMerger.pageCopies(of: source) }
            } else {
                pages += DocumentMerger.pageCopies(of: source)
            }
        }
        try DocumentMerger.write(DocumentMerger.document(with: pages), to: url)
    }

    /// Asks where to save, writes the merged PDF and opens it. True when done.
    func merge() -> Bool {
        guard canMerge else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("Merged") + ".pdf"
        panel.prompt = L("Merge")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try write(to: url)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        items = []
        AppModel.shared.open([url])
        return true
    }
}

/// Merges several PDFs: files are added from Finder or a panel, reordered by
/// dragging, limited to page ranges, and the result is previewed page by page.
struct MergeWindow: View {
    @ObservedObject private var model = MergeModel.shared
    @State private var selection = Set<MergeItem.ID>()
    @State private var isDropTargeted = false
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fileList
                    .frame(width: 360)
                Divider()
                preview
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(HostWindowReader(window: $window))
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            loadURLs(from: providers) { model.add($0) }
            return true
        }
        // Pages of an open document can change while this window is behind.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.objectWillChange.send()
        }
        .alert(L("Merge PDFs"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L("OK"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Files

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Files"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if model.items.isEmpty {
                emptyList
            } else {
                List(selection: $selection) {
                    ForEach($model.items) { $item in
                        MergeFileRow(item: $item, thumbnail: item.document.page(at: 0).map(model.thumbnail(for:)))
                            .contextMenu {
                                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button(L("Remove")) { remove(selection.contains(item.id) ? selection : [item.id]) }
                            }
                    }
                    .onMove { model.items.move(fromOffsets: $0, toOffset: $1) }
                    .onInsert(of: [UTType.fileURL]) { index, providers in
                        loadURLs(from: providers) { model.add($0, at: index) }
                    }
                }
                .onDeleteCommand { remove(selection) }
            }
            HStack(spacing: 4) {
                Button { model.presentAddPanel() } label: { Image(systemName: "plus") }
                    .help(L("Add Files…"))
                Button { remove(selection) } label: { Image(systemName: "minus") }
                    .help(L("Remove"))
                    .disabled(selection.isEmpty)
                Spacer()
                Text(L("Drag files to change their order."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var emptyList: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("Drag PDFs here, or add them from your files."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("Add Files…")) { model.presentAddPanel() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(12)
        }
    }

    private func remove(_ ids: Set<MergeItem.ID>) {
        model.remove(ids)
        selection.subtract(ids)
    }

    // MARK: Preview

    private var preview: some View {
        let pages = model.previewPages
        return VStack(alignment: .leading, spacing: 0) {
            Text(L("Preview"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if pages.isEmpty {
                Text(L("The merged document’s pages appear here."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 14) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { position, entry in
                            previewCell(position: position, item: entry.item, index: entry.index)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func previewCell(position: Int, item: MergeItem, index: Int) -> some View {
        VStack(spacing: 4) {
            Group {
                if let page = item.document.page(at: index) {
                    Image(nsImage: model.thumbnail(for: page))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxWidth: 110, maxHeight: 140)
            .background(.white)
            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
            Text("\(position + 1)")
                .font(.caption.weight(.medium))
            Text(L("%@ · Page %ld", item.url.deletingPathExtension().lastPathComponent, index + 1))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .help(L("%@ · Page %ld", item.name, index + 1))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(L("%ld files, %ld pages", model.items.count, model.previewPages.count))
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("Cancel")) { window?.performClose(nil) }
                .keyboardShortcut(.cancelAction)
            Button(L("Merge…")) {
                if model.merge() { window?.close() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canMerge)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Collects dropped file URLs, then hands them over on the main thread in drop order.
    private func loadURLs(from providers: [NSItemProvider], then handle: @escaping @MainActor ([URL]) -> Void) {
        let collected = UncheckedSendable(value: NSMutableArray(array: Array(repeating: NSNull(), count: providers.count)))
        let group = DispatchGroup()
        for (offset, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { collected.value[offset] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collected.value.compactMap { $0 as? URL }
            MainActor.assumeIsolated { if !urls.isEmpty { handle(urls) } }
        }
    }
}

/// Reports the window a view is in.
private struct HostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindow = { window in DispatchQueue.main.async { self.window = window } }
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {}
}

/// A file in the merge list: first page, name, page count and the page range.
private struct MergeFileRow: View {
    @Binding var item: MergeItem
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 36, height: 46)
            .background(.white)
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                HStack(spacing: 6) {
                    TextField(L("All pages"), text: $item.pageRange)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 110)
                        .help(L("Pages such as 1-3, 5 or 8-"))
                    Text(L("of %ld", item.document.pageCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = item.pageRangeError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
