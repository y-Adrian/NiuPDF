import AppKit
import PDFKit
import PaperplaneCore

/// Page management: rotate, delete, insert, move and extract. Every change to
/// which pages the document has, or their order, goes through
/// `changePageOrder(to:)`, whose undo restores the previous order, so all of
/// them undo and redo the same way. Annotations travel with their pages.
extension ReaderLibrary {
    /// The pages a page command acts on: the selection, or the current page.
    var targetPages: IndexSet {
        let valid = selectedPages.filteredIndexSet { $0 < pageCount }
        return valid.isEmpty ? IndexSet(integer: currentPageIndex) : valid
    }

    private var allPages: [PDFPage] {
        guard let document else { return [] }
        return (0..<document.pageCount).compactMap { document.page(at: $0) }
    }

    // MARK: Selection

    enum PageSelectionMode {
        case single
        case toggle
        case range
    }

    /// Click (single), ⌘-click (toggle) or ⇧-click (range) on a thumbnail.
    func selectPage(_ index: Int, mode: PageSelectionMode) {
        switch mode {
        case .single:
            selectedPages = IndexSet(integer: index)
            pageSelectionAnchor = index
            goToPage(index + 1)
        case .toggle:
            var selection = selectedPages.isEmpty ? IndexSet(integer: currentPageIndex) : selectedPages
            if selection.contains(index), selection.count > 1 {
                selection.remove(index)
            } else {
                selection.insert(index)
            }
            selectedPages = selection
            pageSelectionAnchor = index
        case .range:
            let anchor = pageSelectionAnchor ?? currentPageIndex
            selectedPages = IndexSet(integersIn: min(anchor, index)...max(anchor, index))
        }
    }

    // MARK: Operations

    func rotatePages(_ indexes: IndexSet? = nil, by degrees: Int) {
        guard let document else { return }
        let pages = (indexes ?? targetPages).compactMap { document.page(at: $0) }
        guard !pages.isEmpty else { return }
        setRotations(pages, to: pages.map { ($0.rotation + degrees + 360) % 360 })
    }

    private func setRotations(_ pages: [PDFPage], to rotations: [Int]) {
        let previous = pages.map(\.rotation)
        for (page, rotation) in zip(pages, rotations) { page.rotation = rotation }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setRotations(pages, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Rotate Pages"))
        pagesDidChange(selecting: selectedPages)
    }

    func deletePages(_ indexes: IndexSet? = nil) {
        commitPendingEdits?()
        let doomed = indexes ?? targetPages
        guard doomed.count < pageCount else {
            errorMessage = L("A document needs at least one page.")
            return
        }
        let remaining = allPages.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        changePageOrder(to: remaining, actionName: L("Delete Pages"), selecting: [])
    }

    /// Inserts a blank page the size of its neighbour, after the given page.
    func insertBlankPage(after index: Int? = nil) {
        guard document != nil else { return }
        let position = (index ?? targetPages.last ?? currentPageIndex) + 1
        let neighbour = allPages[safe: position - 1] ?? allPages.first
        let page = PDFPage()
        page.setBounds(neighbour?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        var order = allPages
        order.insert(page, at: min(position, order.count))
        changePageOrder(to: order, actionName: L("Insert Blank Page"), selecting: IndexSet(integer: position))
        goToPage(position + 1)
    }

    /// Asks for PDFs and inserts all their pages after the target pages.
    func insertPagesFromFiles(at index: Int? = nil) {
        guard document != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.prompt = L("Insert")
        guard panel.runModal() == .OK else { return }
        insertPages(from: panel.urls, at: index ?? ((targetPages.last ?? currentPageIndex) + 1))
    }

    /// Inserts every page of the given PDFs at a page index, in file order;
    /// this is also how PDFs dropped on the thumbnails are merged in.
    func insertPages(from urls: [URL], at index: Int) {
        guard document != nil else { return }
        commitPendingEdits?()
        var inserted: [PDFPage] = []
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            guard let source = try? SafePDFFileStore.read(from: url).document else {
                errorMessage = SafePDFFileStoreError.unreadablePDF.localizedDescription
                return
            }
            if source.isLocked, !unlock(source, named: url.lastPathComponent) { return }
            // Copies carry their annotations and stay valid after the source closes.
            inserted += (0..<source.pageCount).compactMap { source.page(at: $0).flatMap(DocumentMerger.copy(of:)) }
        }
        guard !inserted.isEmpty else { return }
        var order = allPages
        let position = min(max(index, 0), order.count)
        order.insert(contentsOf: inserted, at: position)
        changePageOrder(to: order, actionName: L("Insert Pages"), selecting: IndexSet(integersIn: position..<(position + inserted.count)))
        goToPage(position + 1)
    }

    /// Moves pages so they start at `destination`, an insertion index counted
    /// in the current order (0 is before the first page).
    func movePages(_ indexes: IndexSet, to destination: Int) {
        let pages = allPages
        let moving = indexes.filteredIndexSet { $0 < pages.count }
        guard !moving.isEmpty else { return }
        let staying = pages.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
        let insertAt = destination - moving.count(in: 0..<min(destination, pages.count))
        var order = staying
        order.insert(contentsOf: moving.map { pages[$0] }, at: min(max(insertAt, 0), order.count))
        guard order != pages else { return }
        let start = order.firstIndex(of: pages[moving.first!]) ?? 0
        changePageOrder(to: order, actionName: L("Move Pages"), selecting: IndexSet(integersIn: start..<(start + moving.count)))
    }

    /// Asks where to save the target pages as a new PDF.
    func extractPages(_ indexes: IndexSet? = nil) {
        let pages = indexes ?? targetPages
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("%@ (Extract)", displayName) + ".pdf"
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writePages(pages, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes copies of pages, annotations included, to a new PDF.
    func writePages(_ indexes: IndexSet, to url: URL) throws {
        guard let document else { return }
        commitPendingEdits?()
        let extract = PDFDocument()
        // Copy while the overlay-drawn annotations and notes are restored, so
        // the new file holds them in standard form.
        withNativeNotesRestored {
            for (position, index) in indexes.enumerated() {
                if let copy = document.page(at: index).flatMap(DocumentMerger.copy(of:)) {
                    extract.insert(copy, at: position)
                }
            }
        }
        guard extract.pageCount > 0, extract.write(to: url) else { throw DocumentExportError.unableToWrite }
    }

    // MARK: Order changes and undo

    /// Makes the document's pages exactly `order`, then registers the inverse.
    func changePageOrder(to order: [PDFPage], actionName: String, selecting selection: IndexSet?) {
        guard let document else { return }
        let before = allPages
        guard order != before else { return }
        applyPageOrder(order, to: document)
        let previousSelection = selectedPages
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.changePageOrder(to: before, actionName: actionName, selecting: previousSelection)
        }
        pdfView?.undoManager?.setActionName(actionName)
        pagesDidChange(selecting: selection)
    }

    /// Rearranges pages in place with the fewest removals and insertions, so
    /// unaffected pages keep their objects, annotations and rendering.
    private func applyPageOrder(_ order: [PDFPage], to document: PDFDocument) {
        let wanted = Set(order.map(ObjectIdentifier.init))
        for index in stride(from: document.pageCount - 1, through: 0, by: -1) {
            if let page = document.page(at: index), !wanted.contains(ObjectIdentifier(page)) {
                document.removePage(at: index)
            }
        }
        for (position, page) in order.enumerated() {
            if position < document.pageCount, document.page(at: position) === page { continue }
            let current = document.index(for: page)
            if current != NSNotFound, current < document.pageCount, document.page(at: current) === page {
                document.removePage(at: current)
            }
            document.insert(page, at: position)
        }
    }

    private func pagesDidChange(selecting selection: IndexSet?) {
        guard let document else { return }
        pageCount = document.pageCount
        // Inserted pages hand their annotations to the overlay like the rest.
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { prepareNotes(on: page) }
        }
        selectedPages = (selection ?? []).filteredIndexSet { $0 < document.pageCount }
        syncBookmarksToPages()
        currentPageIndex = min(currentPageIndex, max(document.pageCount - 1, 0))
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { find(searchText) }
        pdfView?.layoutDocumentView()
        annotationsDidChange()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
