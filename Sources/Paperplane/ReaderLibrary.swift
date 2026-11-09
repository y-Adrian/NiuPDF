import AppKit
import PDFKit
import PaperplaneCore
import SwiftUI

enum ReaderLayout: String, CaseIterable, Identifiable {
    case continuous
    case singlePage
    case twoPage
    case twoPageBook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuous: "连续滚动"
        case .singlePage: "单页"
        case .twoPage: "双页连续"
        case .twoPageBook: "封面 + 双页"
        }
    }

    var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .continuous: .singlePageContinuous
        case .singlePage: .singlePage
        case .twoPage, .twoPageBook: .twoUpContinuous
        }
    }

    var displaysAsBook: Bool { self == .twoPageBook }
    var isTwoPage: Bool { self == .twoPage || self == .twoPageBook }
}

enum SidebarMode {
    case thumbnails
    case outline
    case annotations
    case searchResults
}

/// One row of the annotation list sidebar.
struct AnnotationListItem: Identifiable {
    let id: ObjectIdentifier
    let annotation: PDFAnnotation
    let page: PDFPage
    let pageIndex: Int
    let kind: String
    let text: String
    /// The note attached to markup; empty for standalone notes, whose text is `text`.
    let note: String
}

struct MarkupColor: Identifiable, Hashable {
    let hex: String
    let title: String

    var id: String { hex }
    var nsColor: NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    init(hex: String, title: String) {
        self.hex = hex.uppercased()
        self.title = title
    }

    static let yellow = MarkupColor(hex: "FFD129", title: "黄色")
    static let orange = MarkupColor(hex: "FF9F0A", title: "橙色")
    static let red = MarkupColor(hex: "FF3B30", title: "红色")
    static let green = MarkupColor(hex: "34C759", title: "绿色")
    static let cyan = MarkupColor(hex: "32ADE6", title: "青色")
    static let blue = MarkupColor(hex: "007AFF", title: "蓝色")
    static let purple = MarkupColor(hex: "AF52DE", title: "紫色")
    static let allCases = [yellow, orange, red, green, cyan, blue, purple]
}

@MainActor
final class ReaderLibrary: ObservableObject {
    @Published var document: PDFDocument?
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var pageCount = 0
    @Published var zoomScale: CGFloat = 1
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchResultIndex = 0
    @Published var isCaseSensitiveSearch = false
    @Published var isWholeWordSearch = false
    @Published var isRegularExpressionSearch = false
    @Published var selectedHighlightColor: MarkupColor = .yellow
    @Published var selectedUnderlineColor: MarkupColor = .yellow
    @Published var selectedStrikeOutColor: MarkupColor = .yellow
    @Published var focusSearch = false
    @Published var isSidebarVisible = true
    @Published var sidebarMode: SidebarMode = .thumbnails
    @Published var errorMessage: String?
    /// Bumped after every annotation edit, undo and redo so views that list or
    /// render annotations (thumbnails, annotation list) refresh.
    @Published private(set) var annotationRevision = 0
    @Published private(set) var hasUnsavedChanges = false {
        didSet { pdfView?.window?.isDocumentEdited = hasUnsavedChanges }
    }
    @Published var layoutMode: ReaderLayout = ReaderLayout(
        rawValue: UserDefaults.standard.string(forKey: "readerLayoutMode") ?? ""
    ) ?? .continuous {
        didSet { UserDefaults.standard.set(layoutMode.rawValue, forKey: "readerLayoutMode") }
    }

    weak var pdfView: PDFView?
    private var scopedURL: URL?
    private var fileRevision: PDFFileRevision?
    private var didAttemptRestore = false
    private var pendingRestoredZoomScale: CGFloat?

    private enum ReadingStateKey {
        static let bookmark = "lastOpenedPDFBookmark"
        static let pageIndex = "lastOpenedPDFPageIndex"
        static let zoomScale = "lastOpenedPDFZoomScale"
    }

    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "未打开文稿" }

    func restoreLastDocument() {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard let bookmark = UserDefaults.standard.data(forKey: ReadingStateKey.bookmark) else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            open(url, restoringLastDocument: true)
        } catch {
            forgetLastDocument()
            errorMessage = "无法恢复最近打开的 PDF。请重新选择文件。\n\(error.localizedDescription)"
        }
    }

    /// A bookmark that cannot be restored would otherwise raise the same error on every launch.
    private func forgetLastDocument() {
        UserDefaults.standard.removeObject(forKey: ReadingStateKey.bookmark)
        UserDefaults.standard.removeObject(forKey: ReadingStateKey.pageIndex)
        UserDefaults.standard.removeObject(forKey: ReadingStateKey.zoomScale)
    }

    func presentOpenPanel() {
        guard confirmDiscardingUnsavedChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "打开"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    /// Opens a user-chosen file. The open panel asks about unsaved changes before
    /// it is shown; drag and drop goes through `confirmDiscardingUnsavedChanges` here.
    func open(_ url: URL, confirmingUnsavedChanges: Bool = true) {
        if confirmingUnsavedChanges { guard confirmDiscardingUnsavedChanges() else { return } }
        open(url, restoringLastDocument: false)
    }

    private func open(_ url: URL, restoringLastDocument: Bool) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        let opened: (document: PDFDocument, revision: PDFFileRevision)
        do {
            opened = try SafePDFFileStore.read(from: url)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            if restoringLastDocument { forgetLastDocument() }
            errorMessage = error.localizedDescription
            return
        }

        if opened.document.isLocked, !unlock(opened.document, named: url.lastPathComponent) {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            return
        }

        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        // Clear the reference when this URL needed no scope, so the previous URL is
        // never stopped a second time on the next open.
        scopedURL = didStartAccess ? url : nil
        pdfView?.undoManager?.removeAllActions(withTarget: self)
        resetNoteIconState()
        hasUnsavedChanges = false
        annotationRevision += 1
        document = opened.document
        fileURL = url
        fileRevision = opened.revision
        pageCount = opened.document.pageCount
        let rememberedIndex = restoringLastDocument
            ? UserDefaults.standard.integer(forKey: ReadingStateKey.pageIndex)
            : 0
        currentPageIndex = min(max(rememberedIndex, 0), max(opened.document.pageCount - 1, 0))
        UserDefaults.standard.set(currentPageIndex, forKey: ReadingStateKey.pageIndex)
        if restoringLastDocument {
            let rememberedScale = UserDefaults.standard.double(forKey: ReadingStateKey.zoomScale)
            pendingRestoredZoomScale = rememberedScale > 0 ? CGFloat(rememberedScale) : nil
        } else {
            pendingRestoredZoomScale = nil
            pdfView?.autoScales = true
        }
        searchText = ""
        searchResults = []
        searchResultIndex = 0
        errorMessage = nil
        persistSecurityScopedBookmark(for: url)
    }

    /// Asks for the user password of an encrypted PDF until it unlocks or the user cancels.
    private func unlock(_ document: PDFDocument, named name: String) -> Bool {
        var message = "“\(name)”受密码保护。请输入密码以打开。"
        while true {
            let alert = NSAlert()
            alert.messageText = "输入文稿密码"
            alert.informativeText = message
            alert.addButton(withTitle: "打开")
            alert.addButton(withTitle: "取消")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if document.unlock(withPassword: field.stringValue) { return true }
            message = "密码不正确，请重试。"
        }
    }

    /// Returns true when it is fine to replace or drop the current document.
    func confirmDiscardingUnsavedChanges() -> Bool {
        guard hasUnsavedChanges, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "要存储对“\(displayName)”所做的更改吗？"
        alert.informativeText = "如果不存储，你的批注更改将会丢失。"
        alert.addButton(withTitle: "存储")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不存储")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func goToPage(_ oneBasedPage: Int) {
        guard let document, document.pageCount > 0 else { return }
        let index = min(max(oneBasedPage - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        pdfView?.go(to: page)
        currentPageIndex = index
        UserDefaults.standard.set(index, forKey: ReadingStateKey.pageIndex)
    }

    func updateCurrentPage(_ index: Int) {
        guard document?.pageCount ?? 0 > 0 else { return }
        let safeIndex = min(max(index, 0), (document?.pageCount ?? 1) - 1)
        currentPageIndex = safeIndex
        UserDefaults.standard.set(safeIndex, forKey: ReadingStateKey.pageIndex)
    }

    private func persistSecurityScopedBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: ReadingStateKey.bookmark)
        } catch {
            // The document remains usable in this session even if macOS cannot create a bookmark.
            errorMessage = "文稿已打开，但无法记住它以供下次恢复。\n\(error.localizedDescription)"
        }
    }

    func stepPage(_ delta: Int) {
        goToPage(currentPageIndex + delta + 1)
    }

    func zoom(by factor: CGFloat) {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(pdfView.scaleFactor * factor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        updateZoomScale(pdfView.scaleFactor)
    }

    func setZoom(_ scale: CGFloat) {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        updateZoomScale(pdfView.scaleFactor)
    }

    func fitPage() {
        setFitScale(widthOnly: false)
    }

    func fitWidth() {
        setFitScale(widthOnly: true)
    }

    private func setFitScale(widthOnly: Bool) {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return }

        let pageCountInSpread: CGFloat = layoutMode.isTwoPage ? 2 : 1
        let spreadSpacing: CGFloat = layoutMode.isTwoPage ? 10 : 0
        let availableWidth = pdfView.bounds.width
            - pdfView.pageBreakMargins.left
            - pdfView.pageBreakMargins.right
        let availableHeight = pdfView.bounds.height
            - pdfView.pageBreakMargins.top
            - pdfView.pageBreakMargins.bottom
        let widthScale = (availableWidth - spreadSpacing) / (pageBounds.width * pageCountInSpread)
        let heightScale = availableHeight / pageBounds.height
        let scale = widthOnly ? widthScale : min(widthScale, heightScale)
        guard scale.isFinite, scale > 0 else { return }

        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        updateZoomScale(pdfView.scaleFactor)
    }

    func updateZoomScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        zoomScale = scale
        UserDefaults.standard.set(Double(scale), forKey: ReadingStateKey.zoomScale)
    }

    func applyPendingRestoredZoom(to view: PDFView) {
        guard let scale = pendingRestoredZoomScale else { return }
        view.autoScales = false
        view.scaleFactor = min(max(scale, view.minScaleFactor), view.maxScaleFactor)
        pendingRestoredZoomScale = nil
        updateZoomScale(view.scaleFactor)
    }

    func applyLayout(to view: PDFView) {
        if view.displayMode != layoutMode.pdfDisplayMode {
            view.displayMode = layoutMode.pdfDisplayMode
        }
        if view.displaysAsBook != layoutMode.displaysAsBook {
            view.displaysAsBook = layoutMode.displaysAsBook
        }
    }

    func find(_ text: String) {
        searchText = text
        guard let document, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            searchResultIndex = 0
            pdfView?.highlightedSelections = nil
            leaveEmptySearchResultsSidebar()
            return
        }
        var options: NSString.CompareOptions = []
        if !isCaseSensitiveSearch { options.insert(.caseInsensitive) }
        let query: String
        if isRegularExpressionSearch {
            query = isWholeWordSearch
                ? "(?<![\\p{L}\\p{N}_])(?:\(text))(?![\\p{L}\\p{N}_])"
                : text
            options.insert(.regularExpression)
        } else if isWholeWordSearch {
            let escapedText = NSRegularExpression.escapedPattern(for: text)
            query = "(?<![\\p{L}\\p{N}_])\(escapedText)(?![\\p{L}\\p{N}_])"
            options.insert(.regularExpression)
        } else {
            query = text
        }
        if options.contains(.regularExpression), (try? NSRegularExpression(pattern: query)) == nil {
            searchResults = []
            searchResultIndex = 0
            pdfView?.highlightedSelections = nil
            leaveEmptySearchResultsSidebar()
            return
        }
        searchResults = document.findString(query, withOptions: options)
        searchResultIndex = 0
        pdfView?.highlightedSelections = searchResults
        leaveEmptySearchResultsSidebar()
        showCurrentSearchResult()
    }

    /// The results tab button disappears with the last result, so the sidebar
    /// must not stay on an empty results list the user can no longer leave by it.
    private func leaveEmptySearchResultsSidebar() {
        if searchResults.isEmpty, sidebarMode == .searchResults { sidebarMode = .thumbnails }
    }

    func moveSearchResult(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchResultIndex = (searchResultIndex + delta + searchResults.count) % searchResults.count
        showCurrentSearchResult()
    }

    func selectSearchResult(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        searchResultIndex = index
        showCurrentSearchResult()
    }

    private func showCurrentSearchResult() {
        guard searchResults.indices.contains(searchResultIndex), let pdfView else { return }
        pdfView.setCurrentSelection(searchResults[searchResultIndex], animate: true)
        pdfView.go(to: searchResults[searchResultIndex])
    }

    // MARK: - Text markup

    private enum MarkupIntent {
        /// Markup icon: erases the selected part when it is already marked in this
        /// color, otherwise marks it, merging with overlapping markup of the type.
        case toggle
        /// Color swatch: always marks the selection in the chosen color.
        case apply
    }

    func toggleHighlight(in selection: PDFSelection) {
        editMarkup(.highlight, color: selectedHighlightColor, in: selection, intent: .toggle)
    }

    func toggleUnderline(in selection: PDFSelection) {
        editMarkup(.underline, color: selectedUnderlineColor, in: selection, intent: .toggle)
    }

    func toggleStrikeOut(in selection: PDFSelection) {
        editMarkup(.strikeOut, color: selectedStrikeOutColor, in: selection, intent: .toggle)
    }

    func applyHighlight(color: MarkupColor, to selection: PDFSelection) {
        selectedHighlightColor = color
        editMarkup(.highlight, color: color, in: selection, intent: .apply)
    }

    func applyUnderline(color: MarkupColor, to selection: PDFSelection) {
        selectedUnderlineColor = color
        editMarkup(.underline, color: color, in: selection, intent: .apply)
    }

    func applyStrikeOut(color: MarkupColor, to selection: PDFSelection) {
        selectedStrikeOutColor = color
        editMarkup(.strikeOut, color: color, in: selection, intent: .apply)
    }

    private func editMarkup(_ type: PDFAnnotationSubtype, color: MarkupColor, in selection: PDFSelection, intent: MarkupIntent) {
        recordAnnotationEdit(markupActionName(type), pages: selection.pages) {
            for page in selection.pages {
                applyMarkup(type, color: color.nsColor, characters: MarkupEngine.characters(of: selection, on: page), on: page, intent: intent)
            }
        }
        pdfView?.clearSelection()
    }

    /// Applies one markup edit on one page and returns the annotation that now
    /// covers the characters, or nil when the edit erased markup.
    @discardableResult
    private func applyMarkup(
        _ type: PDFAnnotationSubtype,
        color: NSColor,
        characters: IndexSet,
        on page: PDFPage,
        intent: MarkupIntent
    ) -> PDFAnnotation? {
        let wanted = MarkupEngine.visibleCharacters(characters, on: page)
        guard !wanted.isEmpty else { return nil }
        let typeName = MarkupEngine.typeName(type)
        let overlapping = page.annotations
            .filter { $0.type == typeName }
            .map { ($0, MarkupEngine.characters(of: $0, on: page)) }
            .filter { !$0.1.intersection(wanted).isEmpty }
        let covered = overlapping.reduce(IndexSet()) { $0.union($1.1) }

        if intent == .toggle, !overlapping.isEmpty,
           overlapping.allSatisfy({ colorsMatch($0.0.color, color) }),
           wanted.isSubset(of: covered) {
            // Erase only the selected part; what is left keeps its color and note.
            for (annotation, marked) in overlapping {
                page.removeAnnotation(annotation)
                let remaining = marked.subtracting(characters)
                for (index, run) in MarkupEngine.runs(of: remaining, on: page).enumerated() {
                    guard let piece = MarkupEngine.makeAnnotation(type: type, color: annotation.color, characters: run, on: page) else { continue }
                    page.addAnnotation(piece)
                    if index == 0 { storeNote(note(of: annotation), for: piece) }
                }
            }
            return nil
        }

        // Merge the selection and every overlapping markup of this type into one
        // annotation, keeping all of their notes.
        let notes = overlapping
            .map { note(of: $0.0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (annotation, _) in overlapping { page.removeAnnotation(annotation) }
        guard let merged = MarkupEngine.makeAnnotation(type: type, color: color, characters: characters.union(covered), on: page) else {
            return nil
        }
        page.addAnnotation(merged)
        storeNote(notes.joined(separator: "\n\n"), for: merged)
        return merged
    }

    private func markupActionName(_ type: PDFAnnotationSubtype) -> String {
        switch type {
        case .underline: "下划线"
        case .strikeOut: "删除线"
        default: "高亮"
        }
    }

    /// Markup of any type under the selection, highlights first, then those with a note.
    private func markups(in selection: PDFSelection) -> [PDFAnnotation] {
        guard let page = selection.pages.first else { return [] }
        let wanted = MarkupEngine.visibleCharacters(MarkupEngine.characters(of: selection, on: page), on: page)
        guard !wanted.isEmpty else { return [] }
        return page.annotations
            .filter { MarkupEngine.isMarkup($0) }
            .filter { !MarkupEngine.characters(of: $0, on: page).intersection(wanted).isEmpty }
            .sorted { first, second in
                let firstRank = (first.type == "Highlight" ? 0 : 2) + (note(of: first).isEmpty ? 1 : 0)
                let secondRank = (second.type == "Highlight" ? 0 : 2) + (note(of: second).isEmpty ? 1 : 0)
                return firstRank < secondRank
            }
    }

    private func colorsMatch(_ first: NSColor, _ second: NSColor) -> Bool {
        guard let first = first.usingColorSpace(.deviceRGB),
              let second = second.usingColorSpace(.deviceRGB) else {
            return first.isEqual(second)
        }
        let tolerance: CGFloat = 0.02
        return abs(first.redComponent - second.redComponent) < tolerance
            && abs(first.greenComponent - second.greenComponent) < tolerance
            && abs(first.blueComponent - second.blueComponent) < tolerance
            && abs(first.alphaComponent - second.alphaComponent) < tolerance
    }

    // MARK: - Notes

    /// Set by the PDF view; opens the annotation editor popover.
    var onEditAnnotation: ((PDFAnnotation) -> Void)?

    /// A highlight created by "Add Note" whose note has not been written yet.
    /// It is kept, as one undo step, only if the note ends up with text.
    private var pendingNoteCreation: (annotation: PDFAnnotation, edit: AnnotationEdit)?

    /// Markup under the selection that already carries a note.
    func notedMarkup(in selection: PDFSelection) -> PDFAnnotation? {
        markups(in: selection).first { !note(of: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Notes belong to markup, as in PDF Expert: edit the note of the markup under
    /// the selection, or highlight the selection first and attach the note to it.
    func addNote(in selection: PDFSelection) {
        pdfView?.clearSelection()
        if let existing = markups(in: selection).first {
            onEditAnnotation?(existing)
            return
        }
        guard let page = selection.pages.first else { return }
        let characters = MarkupEngine.characters(of: selection, on: page)
        var created: PDFAnnotation?
        let edit = captureAnnotationEdit(pages: [page]) {
            created = applyMarkup(.highlight, color: selectedHighlightColor.nsColor, characters: characters, on: page, intent: .apply)
        }
        guard let created else {
            edit.revert()
            return
        }
        pendingNoteCreation = (created, edit)
        annotationRevision += 1
        refreshPDFView()
        onEditAnnotation?(created)
    }

    func removeNote(in selection: PDFSelection) {
        guard let markup = notedMarkup(in: selection) else { return }
        setNote(markup, to: "")
        pdfView?.clearSelection()
    }

    /// Called when the editor popover closes. Empty notes are not kept: a pending
    /// "Add Note" highlight is dropped and an empty standalone note is deleted.
    func finishEditing(_ annotation: PDFAnnotation, note: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : note
        if let pending = pendingNoteCreation, pending.annotation === annotation {
            pendingNoteCreation = nil
            if text.isEmpty {
                pending.edit.revert()
                annotationRevision += 1
                refreshPDFView()
            } else {
                storeNote(text, for: annotation)
                commit(pending.edit, actionName: "添加笔记")
            }
            return
        }
        if text.isEmpty, annotation.type == "Text" {
            deleteAnnotation(annotation)
            return
        }
        setNote(annotation, to: text)
    }

    func setNote(_ annotation: PDFAnnotation, to text: String) {
        let previous = note(of: annotation)
        guard previous != text else { return }
        storeNote(text, for: annotation)
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setNote(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(text.isEmpty ? "删除笔记" : "编辑笔记")
        annotationsDidChange()
    }

    func setColor(_ annotation: PDFAnnotation, to color: MarkupColor) {
        switch annotation.type {
        case "Highlight": selectedHighlightColor = color
        case "Underline": selectedUnderlineColor = color
        case "StrikeOut": selectedStrikeOutColor = color
        default: break
        }
        if pendingNoteCreation?.annotation === annotation {
            // Part of the not-yet-committed "Add Note" step.
            annotation.color = color.nsColor
            annotationRevision += 1
            refreshPDFView()
            return
        }
        setColor(annotation, to: color.nsColor)
    }

    private func setColor(_ annotation: PDFAnnotation, to color: NSColor) {
        let previous = annotation.color
        guard !colorsMatch(previous, color) else { return }
        annotation.color = color
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setColor(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName("更改颜色")
        annotationsDidChange()
    }

    func deleteAnnotation(_ annotation: PDFAnnotation) {
        if let pending = pendingNoteCreation, pending.annotation === annotation {
            pendingNoteCreation = nil
            pending.edit.revert()
            annotationRevision += 1
            refreshPDFView()
            return
        }
        guard let page = annotation.page else { return }
        recordAnnotationEdit(annotation.type == "Text" ? "删除笔记" : "删除批注", pages: [page]) {
            page.removeAnnotation(annotation)
        }
    }

    // MARK: - Note icons

    /// Standalone `/Text` notes whose PDFKit icon is hidden on screen because the
    /// page overlay draws a sharp one instead. They are made visible again for the
    /// duration of every save, so other readers still show them.
    private var hiddenNativeNotes: [ObjectIdentifier: PDFAnnotation] = [:]
    private var preparedNotePages = Set<ObjectIdentifier>()
    private var markerCache: [ObjectIdentifier: (revision: Int, markers: [CommentMarker])] = [:]

    /// Notes of markup on displayed pages. PDFKit draws its own page-scaled badge
    /// on markup that has `/Contents`, which would double the overlay icon, so on
    /// screen the text lives here and is written back for the duration of a save.
    private var markupNotes: [ObjectIdentifier: (annotation: PDFAnnotation, text: String)] = [:]

    func note(of annotation: PDFAnnotation) -> String {
        markupNotes[ObjectIdentifier(annotation)]?.text ?? annotation.contents ?? ""
    }

    private func storeNote(_ text: String, for annotation: PDFAnnotation) {
        if MarkupEngine.isMarkup(annotation) {
            markupNotes[ObjectIdentifier(annotation)] = (annotation, text)
            annotation.contents = nil
        } else {
            annotation.contents = text
        }
    }

    /// Hands a page's note icons over to the overlay before the page is drawn.
    func prepareNotes(on page: PDFPage) {
        guard preparedNotePages.insert(ObjectIdentifier(page)).inserted else { return }
        for annotation in page.annotations {
            if annotation.type == "Text", annotation.shouldDisplay {
                annotation.shouldDisplay = false
                hiddenNativeNotes[ObjectIdentifier(annotation)] = annotation
            } else if MarkupEngine.isMarkup(annotation), let text = annotation.contents, !text.isEmpty {
                storeNote(text, for: annotation)
            }
        }
    }

    /// Restores what `prepareNotes` changed so the saved file is standard.
    private func withNativeNotesRestored<T>(_ body: () throws -> T) rethrows -> T {
        for note in hiddenNativeNotes.values { note.shouldDisplay = true }
        for (annotation, text) in markupNotes.values { annotation.contents = text.isEmpty ? nil : text }
        defer {
            for note in hiddenNativeNotes.values { note.shouldDisplay = false }
            for (annotation, _) in markupNotes.values { annotation.contents = nil }
        }
        return try body()
    }

    func commentMarkers(on page: PDFPage) -> [CommentMarker] {
        prepareNotes(on: page)
        let key = ObjectIdentifier(page)
        if let cached = markerCache[key], cached.revision == annotationRevision { return cached.markers }
        let markers = CommentMarkerLayout.markers(
            on: page,
            noteOf: { [unowned self] in note(of: $0) },
            showsStandaloneNote: { [hiddenNativeNotes] in hiddenNativeNotes[ObjectIdentifier($0)] != nil }
        )
        markerCache[key] = (annotationRevision, markers)
        return markers
    }

    private func resetNoteIconState() {
        hiddenNativeNotes = [:]
        markupNotes = [:]
        preparedNotePages = []
        markerCache = [:]
        pendingNoteCreation = nil
    }

    // MARK: - Edit tracking and undo

    private struct AnnotationEdit {
        var added: [(PDFAnnotation, PDFPage)] = []
        var removed: [(PDFAnnotation, PDFPage)] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty }

        func revert() {
            for (annotation, page) in added { page.removeAnnotation(annotation) }
            for (annotation, page) in removed { page.addAnnotation(annotation) }
        }
    }

    /// Runs an annotation mutation and reports exactly which annotations it
    /// added or removed on the touched pages.
    private func captureAnnotationEdit(pages: [PDFPage], _ body: () -> Void) -> AnnotationEdit {
        let before = pages.map(\.annotations)
        body()
        var edit = AnnotationEdit()
        for (index, page) in pages.enumerated() {
            let beforeIDs = Set(before[index].map(ObjectIdentifier.init))
            let afterIDs = Set(page.annotations.map(ObjectIdentifier.init))
            edit.added += page.annotations.filter { !beforeIDs.contains(ObjectIdentifier($0)) }.map { ($0, page) }
            edit.removed += before[index].filter { !afterIDs.contains(ObjectIdentifier($0)) }.map { ($0, page) }
        }
        return edit
    }

    /// Runs an annotation mutation as one undo step.
    private func recordAnnotationEdit(_ actionName: String, pages: [PDFPage], _ body: () -> Void) {
        commit(captureAnnotationEdit(pages: pages, body), actionName: actionName)
    }

    private func commit(_ edit: AnnotationEdit, actionName: String) {
        guard !edit.isEmpty else { return }
        registerAnnotationUndo(edit, actionName: actionName)
        annotationsDidChange()
    }

    private func registerAnnotationUndo(_ edit: AnnotationEdit, actionName: String) {
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            edit.revert()
            // Registering the inverse while undoing makes it the redo step.
            target.registerAnnotationUndo(AnnotationEdit(added: edit.removed, removed: edit.added), actionName: actionName)
            target.annotationsDidChange()
        }
        undoManager.setActionName(actionName)
    }

    private func annotationsDidChange() {
        hasUnsavedChanges = true
        annotationRevision += 1
        refreshPDFView()
    }

    private func refreshPDFView() {
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        (pdfView as? AnnotationOverlayHost)?.refreshAnnotationOverlays()
    }

    // MARK: - Annotation list

    private static let listedAnnotationKinds: [String: String] = [
        "Highlight": "高亮",
        "Underline": "下划线",
        "StrikeOut": "删除线",
        "Squiggly": "波浪线",
        "Text": "笔记",
        "FreeText": "文本框",
        "Ink": "手绘",
        "Square": "矩形",
        "Circle": "椭圆",
        "Line": "线条",
        "Stamp": "图章"
    ]

    /// Every user-facing annotation in page order. Links, form widgets and popups are skipped.
    func annotationListItems() -> [AnnotationListItem] {
        guard let document else { return [] }
        var items: [AnnotationListItem] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let type = annotation.type, let kind = Self.listedAnnotationKinds[type],
                      pendingNoteCreation?.annotation !== annotation else { continue }
                var text = ""
                var noteText = note(of: annotation)
                if MarkupEngine.isMarkup(annotation) {
                    let characters = MarkupEngine.characters(of: annotation, on: page)
                    if let first = characters.first, let last = characters.last {
                        text = page.selection(for: NSRange(location: first, length: last - first + 1))?.string ?? ""
                    }
                } else if type == "Text" || type == "FreeText" {
                    text = noteText
                    noteText = ""
                }
                items.append(AnnotationListItem(
                    id: ObjectIdentifier(annotation),
                    annotation: annotation,
                    page: page,
                    pageIndex: index,
                    kind: kind,
                    text: text.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                    note: noteText
                ))
            }
        }
        return items
    }

    func reveal(_ annotation: PDFAnnotation) {
        guard let page = annotation.page, let document, let pdfView else { return }
        pdfView.go(to: annotation.bounds.insetBy(dx: -40, dy: -40), on: page)
        updateCurrentPage(document.index(for: page))
    }

    @discardableResult
    func save() -> Bool {
        guard let document, let fileURL, let fileRevision else { return false }
        do {
            self.fileRevision = try withNativeNotesRestored {
                try SafePDFFileStore.save(document, to: fileURL, expectedRevision: fileRevision)
            }
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
