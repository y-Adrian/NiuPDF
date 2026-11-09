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

    func highlightSelection() {
        guard selectedText != nil else { return }
        toggleTextMarkup(
            type: .highlight,
            color: selectedHighlightColor.nsColor
        )
    }

    func toggleHighlight(in selection: PDFSelection) {
        toggleTextMarkup(
            type: .highlight,
            color: selectedHighlightColor.nsColor,
            in: selection
        )
    }

    func underlineSelection() {
        applyUnderline(color: selectedUnderlineColor)
    }

    func toggleUnderline(in selection: PDFSelection) {
        toggleTextMarkup(type: .underline, color: selectedUnderlineColor.nsColor, in: selection)
    }

    func strikeOutSelection() {
        applyStrikeOut(color: selectedStrikeOutColor)
    }

    func toggleStrikeOut(in selection: PDFSelection) {
        toggleTextMarkup(type: .strikeOut, color: selectedStrikeOutColor.nsColor, in: selection)
    }

    func applyHighlight(color: MarkupColor) {
        guard let selection = selectedText else { return }
        applyHighlight(color: color, to: selection)
    }

    func applyHighlight(color: MarkupColor, to selection: PDFSelection) {
        selectedHighlightColor = color
        replaceTextMarkup(type: .highlight, color: color.nsColor, selection: selection)
    }

    func applyUnderline(color: MarkupColor) {
        guard let selection = selectedText else { return }
        applyUnderline(color: color, to: selection)
    }

    func applyUnderline(color: MarkupColor, to selection: PDFSelection) {
        selectedUnderlineColor = color
        replaceTextMarkup(type: .underline, color: color.nsColor, selection: selection)
    }

    func applyStrikeOut(color: MarkupColor) {
        guard let selection = selectedText else { return }
        applyStrikeOut(color: color, to: selection)
    }

    func applyStrikeOut(color: MarkupColor, to selection: PDFSelection) {
        selectedStrikeOutColor = color
        replaceTextMarkup(type: .strikeOut, color: color.nsColor, selection: selection)
    }

    func removeNoteAnnotations(in selection: PDFSelection) {
        recordAnnotationEdit("移除笔记", pages: selection.pages) {
            for (note, page) in noteAnnotations(in: selection) { page.removeAnnotation(note) }
        }
    }

    /// Creates a standards-compliant PDF `/Text` note. Keep these values together so
    /// the note's size, placement, and translucency can be tuned without changing
    /// selection or persistence behavior.
    func toggleNoteAnnotation(in selection: PDFSelection) {
        if hasNoteAnnotation(in: selection) {
            removeNoteAnnotations(in: selection)
            pdfView?.clearSelection()
            return
        }

        guard let page = selection.pages.first else { return }
        let selectionBounds = selection.bounds(for: page)
        guard !selectionBounds.isNull, !selectionBounds.isEmpty else { return }

        let style = NoteAnnotationStyle()
        let noteBounds = style.bounds(for: selectionBounds, on: page)
        // Snap to whole page points so the icon's vector edges land on the pixel
        // grid instead of a half pixel, which is what makes it look soft.
        let alignedBounds = CGRect(
            x: noteBounds.minX.rounded(),
            y: noteBounds.minY.rounded(),
            width: noteBounds.width,
            height: noteBounds.height
        )
        // Use PDFKit's native text-note icon: PDFKit draws it as a vector at the
        // current display scale, which stays sharp at every zoom level. Custom
        // `draw` overrides are cached as a low-resolution appearance instead.
        let note = PDFAnnotation(bounds: alignedBounds, forType: .text, withProperties: nil)
        note.iconType = .comment
        note.color = style.color.withAlphaComponent(style.opacity)
        let border = PDFBorder()
        border.lineWidth = style.borderWidth
        note.border = border
        note.contents = ""
        // The icon sits beside the text, not on it, so remember which text it
        // belongs to; otherwise "Remove Note" could never find it again.
        note.setValue(Self.anchorString(for: selectionBounds), forAnnotationKey: Self.noteAnchorKey)
        recordAnnotationEdit("添加笔记", pages: [page]) {
            page.addAnnotation(note)
        }
        pdfView?.clearSelection()
        onNoteCreated?(note, page)
    }

    /// Set by the PDF view so a freshly created note opens its editor right away.
    var onNoteCreated: ((PDFAnnotation, PDFPage) -> Void)?

    func hasNoteAnnotation(in selection: PDFSelection) -> Bool {
        !noteAnnotations(in: selection).isEmpty
    }

    /// Custom key holding the selected text's page rectangle as "x y w h". PDF
    /// readers ignore unknown annotation keys, and PDFKit keeps it across saves.
    private static let noteAnchorKey = PDFAnnotationKey(rawValue: "/PaperplaneAnchor")

    private static func anchorString(for rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    private static func anchorRect(of note: PDFAnnotation) -> CGRect? {
        guard let raw = note.value(forAnnotationKey: noteAnchorKey) as? String else { return nil }
        let values = raw.split(separator: " ").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// Notes created here match through their anchor; notes from other apps have
    /// none, so they still match when the icon itself touches the selection.
    private func noteAnnotations(in selection: PDFSelection) -> [(PDFAnnotation, PDFPage)] {
        selection.pages.flatMap { page -> [(PDFAnnotation, PDFPage)] in
            let bounds = selection.bounds(for: page)
            return page.annotations
                .filter { $0.type == Self.annotationTypeName(.text) }
                .filter { (Self.anchorRect(of: $0) ?? $0.bounds).intersects(bounds) }
                .map { ($0, page) }
        }
    }

    func noteContents(_ note: PDFAnnotation) -> String {
        note.contents ?? ""
    }

    func setNoteContents(_ note: PDFAnnotation, to text: String) {
        let previous = note.contents ?? ""
        guard previous != text else { return }
        note.contents = text
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setNoteContents(note, to: previous)
        }
        pdfView?.undoManager?.setActionName("编辑笔记")
        annotationsDidChange()
    }

    func deleteAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        recordAnnotationEdit("删除批注", pages: [page]) {
            page.removeAnnotation(annotation)
        }
    }

    // MARK: - Edit tracking and undo

    /// Runs an annotation mutation, then registers one undo step that restores
    /// exactly the annotations it added or removed on the touched pages.
    private func recordAnnotationEdit(_ actionName: String, pages: [PDFPage], _ body: () -> Void) {
        let before = pages.map { Set($0.annotations.map(ObjectIdentifier.init)) }
        let beforeAnnotations = pages.map(\.annotations)
        body()
        var added: [(PDFAnnotation, PDFPage)] = []
        var removed: [(PDFAnnotation, PDFPage)] = []
        for (index, page) in pages.enumerated() {
            let after = Set(page.annotations.map(ObjectIdentifier.init))
            added += page.annotations.filter { !before[index].contains(ObjectIdentifier($0)) }.map { ($0, page) }
            removed += beforeAnnotations[index].filter { !after.contains(ObjectIdentifier($0)) }.map { ($0, page) }
        }
        guard !added.isEmpty || !removed.isEmpty else { return }
        registerAnnotationUndo(added: added, removed: removed, actionName: actionName)
        annotationsDidChange()
    }

    private func registerAnnotationUndo(
        added: [(PDFAnnotation, PDFPage)],
        removed: [(PDFAnnotation, PDFPage)],
        actionName: String
    ) {
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            for (annotation, page) in added { page.removeAnnotation(annotation) }
            for (annotation, page) in removed { page.addAnnotation(annotation) }
            // Registering the inverse while undoing makes it the redo step.
            target.registerAnnotationUndo(added: removed, removed: added, actionName: actionName)
            target.annotationsDidChange()
        }
        undoManager.setActionName(actionName)
    }

    private func annotationsDidChange() {
        hasUnsavedChanges = true
        annotationRevision += 1
        refreshPDFView()
    }

    private static func annotationTypeName(_ type: PDFAnnotationSubtype) -> String {
        type.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
                guard let type = annotation.type, let kind = Self.listedAnnotationKinds[type] else { continue }
                let text: String
                if type == "Text" || type == "FreeText" {
                    text = annotation.contents ?? ""
                } else {
                    text = page.selection(for: annotation.bounds)?.string ?? annotation.contents ?? ""
                }
                items.append(AnnotationListItem(
                    id: ObjectIdentifier(annotation),
                    annotation: annotation,
                    page: page,
                    pageIndex: index,
                    kind: kind,
                    text: text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    private var selectedText: PDFSelection? {
        guard let selection = pdfView?.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }

    private func toggleTextMarkup(type: PDFAnnotationSubtype, color: NSColor) {
        guard let selection = selectedText else { return }
        toggleTextMarkup(type: type, color: color, in: selection)
    }

    private func toggleTextMarkup(type: PDFAnnotationSubtype, color: NSColor, in selection: PDFSelection) {
        recordAnnotationEdit(markupActionName(type), pages: selection.pages) {
            let existing = annotations(ofType: type, in: selection)
            if !existing.isEmpty {
                removeAnnotations(ofType: type, in: selection)
                if existing.allSatisfy({ colorsMatch($0.color, color) }) { return }
            }
            addTextMarkup(type: type, color: color, selection: selection)
        }
        pdfView?.clearSelection()
        refreshPDFView()
    }

    private func replaceTextMarkup(type: PDFAnnotationSubtype, color: NSColor, selection: PDFSelection) {
        recordAnnotationEdit(markupActionName(type), pages: selection.pages) {
            removeMatchingAnnotations(ofType: type, in: selection)
            addTextMarkup(type: type, color: color, selection: selection)
        }
        pdfView?.clearSelection()
        refreshPDFView()
    }

    private func markupActionName(_ type: PDFAnnotationSubtype) -> String {
        switch type {
        case .underline: "下划线"
        case .strikeOut: "删除线"
        default: "高亮"
        }
    }

    /// Color swatches replace annotations created for the same selected line. Matching
    /// line rectangles avoids deleting an entire longer annotation just because a
    /// smaller selection happens to intersect its broad bounding box.
    private func removeMatchingAnnotations(ofType type: PDFAnnotationSubtype, in selection: PDFSelection) {
        let annotationType = type.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let targetBounds = line.bounds(for: page)
                guard !targetBounds.isNull, !targetBounds.isEmpty else { continue }
                for annotation in page.annotations where
                    annotation.type == annotationType && sameMarkupBounds(annotation.bounds, targetBounds) {
                    page.removeAnnotation(annotation)
                }
            }
        }
    }

    private func sameMarkupBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        let tolerance: CGFloat = 1.5
        return abs(first.minX - second.minX) <= tolerance
            && abs(first.minY - second.minY) <= tolerance
            && abs(first.maxX - second.maxX) <= tolerance
            && abs(first.maxY - second.maxY) <= tolerance
    }

    private func addTextMarkup(type: PDFAnnotationSubtype, color: NSColor, selection: PDFSelection) {
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                if type == .underline {
                    let border = PDFBorder()
                    border.lineWidth = 2
                    annotation.border = border
                }
                let strikeOffset = type == .strikeOut ? min(3, bounds.height * 0.2) : 0
                let quadTop = max(0, bounds.height - strikeOffset)
                annotation.quadrilateralPoints = [
                    NSValue(point: CGPoint(x: 0, y: quadTop)),
                    NSValue(point: CGPoint(x: bounds.width, y: quadTop)),
                    NSValue(point: CGPoint(x: 0, y: 0)),
                    NSValue(point: CGPoint(x: bounds.width, y: 0))
                ]
                annotation.color = color
                page.addAnnotation(annotation)
            }
        }
        refreshPDFView()
    }

    private func hasAnnotation(ofType type: PDFAnnotationSubtype, in selection: PDFSelection) -> Bool {
        !annotations(ofType: type, in: selection).isEmpty
    }

    private func annotations(ofType type: PDFAnnotationSubtype, in selection: PDFSelection) -> [PDFAnnotation] {
        selection.pages.flatMap { page in
            let bounds = selection.bounds(for: page)
            return page.annotations.filter { annotation in
                annotation.type == type.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    && annotation.bounds.intersects(bounds)
            }
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

    private func removeAnnotations(ofType type: PDFAnnotationSubtype, in selection: PDFSelection) {
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            for annotation in page.annotations where
                annotation.type == type.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    && annotation.bounds.intersects(bounds) {
                page.removeAnnotation(annotation)
            }
        }
    }

    private func refreshPDFView() {
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
    }

    private struct NoteAnnotationStyle {
        // PDF page-space points. PDFKit lays its native text-note icon out at 24 pt,
        // and at that size the rect stays stable across save and reopen.
        var iconSize: CGFloat = 24
        // Gap kept between the icon and the text it is anchored to.
        var anchorGap: CGFloat = 2
        // Gap kept between two icons that share the same anchor line.
        var stackGap: CGFloat = 2
        var pageInset: CGFloat = 4
        // Applied to the standard note annotation color; 1 is fully opaque.
        var opacity: CGFloat = 1
        // A fine border keeps the small icon distinct without a heavy dark frame.
        var borderWidth: CGFloat = 0.6
        var color: NSColor = .systemYellow

        private enum Axis {
            case horizontal
            case vertical
        }

        /// Places the note as close as possible to the selected text without
        /// covering glyphs: first in the whitespace directly above the selected
        /// line, then beside that line's end. Notes that share an anchor line are
        /// shifted apart so their icons never overlap.
        func bounds(for selection: CGRect, on page: PDFPage) -> CGRect {
            let pageBounds = page.bounds(for: .mediaBox)
            let minX = pageBounds.minX + pageInset
            let maxX = pageBounds.maxX - iconSize - pageInset
            let minY = pageBounds.minY + pageInset
            let maxY = pageBounds.maxY - iconSize - pageInset

            let lines = pageLineBounds(on: page).sorted { $0.maxY > $1.maxY }
            let anchorLine = lines.first(where: { $0.intersects(selection) }) ?? selection
            let lineAbove = lines
                .filter { $0.minY > anchorLine.maxY }
                .min(by: { $0.minY < $1.minY })
            let occupied = page.annotations
                .filter { $0.type == noteType }
                .map(\.bounds)

            // 1) Directly above the selected line, inside the inter-line whitespace.
            let ceiling = lineAbove?.minY ?? (pageBounds.maxY - pageInset)
            if ceiling - anchorLine.maxY >= iconSize + 2 * anchorGap {
                let base = CGRect(
                    x: selection.midX - iconSize / 2,
                    y: anchorLine.maxY + anchorGap,
                    width: iconSize,
                    height: iconSize
                )
                if let rect = resolve(base, axis: .horizontal, lines: lines, occupied: occupied, minX: minX, maxX: maxX, minY: minY, maxY: maxY) {
                    return rect
                }
            }

            // 2) Beside the selected line's end (right first, then left).
            let rightBase = CGRect(
                x: anchorLine.maxX + anchorGap,
                y: anchorLine.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            if let rect = resolve(rightBase, axis: .vertical, lines: lines, occupied: occupied, minX: minX, maxX: maxX, minY: minY, maxY: maxY) {
                return rect
            }
            let leftBase = CGRect(
                x: anchorLine.minX - anchorGap - iconSize,
                y: anchorLine.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            if let rect = resolve(leftBase, axis: .vertical, lines: lines, occupied: occupied, minX: minX, maxX: maxX, minY: minY, maxY: maxY) {
                return rect
            }

            // 3) Best effort: beside the selection itself, clamped to the page.
            return CGRect(
                x: min(max(selection.maxX + anchorGap, minX), maxX),
                y: min(max(selection.midY - iconSize / 2, minY), maxY),
                width: iconSize,
                height: iconSize
            )
        }

        private func resolve(
            _ base: CGRect,
            axis: Axis,
            lines: [CGRect],
            occupied: [CGRect],
            minX: CGFloat,
            maxX: CGFloat,
            minY: CGFloat,
            maxY: CGFloat
        ) -> CGRect? {
            let step = iconSize + stackGap
            let offsets: [CGFloat] = [0, step, -step, 2 * step, -2 * step, 3 * step, -3 * step, 4 * step, -4 * step, 5 * step, -5 * step]
            for offset in offsets {
                let candidate: CGRect
                switch axis {
                case .horizontal:
                    candidate = CGRect(x: base.minX + offset, y: base.minY, width: iconSize, height: iconSize)
                case .vertical:
                    candidate = CGRect(x: base.minX, y: base.minY + offset, width: iconSize, height: iconSize)
                }
                let inPage = candidate.minX >= minX && candidate.minX <= maxX
                    && candidate.minY >= minY && candidate.minY <= maxY
                let coversText = lines.contains { $0.intersects(candidate) }
                let overlapsNote = occupied.contains { $0.intersects(candidate) }
                if inPage && !coversText && !overlapsNote {
                    return candidate
                }
            }
            return nil
        }

        private func pageLineBounds(on page: PDFPage) -> [CGRect] {
            guard let text = page.string, !text.isEmpty else { return [] }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let full = page.selection(for: range) else { return [] }
            return full.selectionsByLine().compactMap { selection in
                let bounds = selection.bounds(for: page)
                return bounds.isNull || bounds.isEmpty ? nil : bounds
            }
        }

        private var noteType: String {
            PDFAnnotationSubtype.text.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let document, let fileURL, let fileRevision else { return false }
        do {
            self.fileRevision = try SafePDFFileStore.save(
                document,
                to: fileURL,
                expectedRevision: fileRevision
            )
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
