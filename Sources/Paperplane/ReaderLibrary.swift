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
        case .continuous: L("Continuous Scroll")
        case .singlePage: L("Single Page")
        case .twoPage: L("Two Pages Continuous")
        case .twoPageBook: L("Cover + Two Pages")
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

enum ToolbarMode {
    case annotate
    case export
}

enum ImageExportRange: String, CaseIterable, Identifiable {
    case currentPage
    case allPages
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentPage: L("Current Page")
        case .allPages: L("All Pages")
        case .custom: L("Page Range")
        }
    }
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

    static let yellow = MarkupColor(hex: "FFD129", title: L("Yellow"))
    static let orange = MarkupColor(hex: "FF9F0A", title: L("Orange"))
    static let red = MarkupColor(hex: "FF3B30", title: L("Red"))
    static let green = MarkupColor(hex: "34C759", title: L("Green"))
    static let cyan = MarkupColor(hex: "32ADE6", title: L("Cyan"))
    static let blue = MarkupColor(hex: "007AFF", title: L("Blue"))
    static let purple = MarkupColor(hex: "AF52DE", title: L("Purple"))
    static let black = MarkupColor(hex: "1C1C1E", title: L("Black"))
    static let allCases = [yellow, orange, red, green, cyan, blue, purple]
    /// Colors for text boxes, drawings and shapes; black is no use as a highlight.
    static let drawingCases = [black, red, orange, yellow, green, cyan, blue, purple]
}

/// The annotation tools in the toolbar. A tool stays active for repeated use,
/// as in PDF Expert, until another tool is chosen or Esc returns to `select`.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case strikeOut
    case textBox
    case note
    case ink
    case rectangle
    case ellipse
    case arrow

    var id: String { rawValue }

    static let shapes: [AnnotationTool] = [.rectangle, .ellipse, .arrow]

    var title: String {
        switch self {
        case .select: L("Select")
        case .highlight: L("Highlight")
        case .underline: L("Underline")
        case .strikeOut: L("Strikethrough")
        case .textBox: L("Text Box")
        case .note: L("Note")
        case .ink: L("Draw")
        case .rectangle: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .arrow: L("Arrow")
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .textBox: "character.textbox"
        case .note: "text.bubble"
        case .ink: "scribble"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        }
    }

    /// Tools applied to text selected by dragging.
    var marksText: Bool { self == .highlight || self == .underline || self == .strikeOut }
    var isShape: Bool { Self.shapes.contains(self) }
    var colorChoices: [MarkupColor] { marksText ? MarkupColor.allCases : MarkupColor.drawingCases }
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
    /// Color for text boxes, drawings and shapes.
    @Published var drawingColor: MarkupColor = .red
    /// Line width for new drawings and shapes, in page points.
    @Published var strokeWidth: CGFloat = 2
    /// Font family for new text boxes; nil is the system font.
    @Published var textFontFamily: String?
    @Published var textFontSize: CGFloat = 14
    /// Set by the text box editor so style changes reach the box being typed.
    var onTypingStyleChange: (() -> Void)?
    /// The markup tool last applied, which the context menu's colors apply to.
    var lastMarkupTool: AnnotationTool = .highlight
    @Published var activeTool: AnnotationTool = .select {
        didSet { if activeTool != oldValue { onToolChange?() } }
    }
    /// The toolbar tab whose row is expanded under the toolbar; one at a time.
    /// Leaving the annotation row returns to plain selection.
    @Published var expandedMode: ToolbarMode? {
        didSet { if expandedMode != .annotate { activeTool = .select } }
    }
    var isAnnotationBarVisible: Bool {
        get { expandedMode == .annotate }
        set { expandedMode = newValue ? .annotate : (expandedMode == .annotate ? nil : expandedMode) }
    }
    /// Set by the PDF view: ends drags and inline text editing on a tool change.
    var onToolChange: (() -> Void)?
    /// Set by the PDF view: commits a text box still being typed into.
    var commitPendingEdits: (() -> Void)?
    @Published var focusSearch = false
    /// Set by "Go to Page…" to put the cursor in the page number field.
    @Published var focusPageField = false
    @Published var isSidebarVisible = true
    @Published var sidebarMode: SidebarMode = .thumbnails
    @Published var errorMessage: String?
    /// Bumped after every annotation edit, undo and redo so views that list or
    /// render annotations (thumbnails, annotation list) refresh.
    @Published private(set) var annotationRevision = 0
    @Published private(set) var hasUnsavedChanges = false {
        didSet { pdfView?.window?.isDocumentEdited = hasUnsavedChanges }
    }
    /// Edits since opening, counted down by undo and up by redo, so undoing back
    /// to the saved state clears "edited". -1 marks a saved state that can no
    /// longer be reached because a new edit replaced the steps that led to it.
    private var changeCount = 0
    private var savedChangeCount = 0

    /// Writes annotation changes to the file a moment after each edit, as the
    /// requirements ask ("annotations land on disk in real time"). One setting
    /// for all windows, changed in Settings.
    static let autosaveKey = "autosaveEnabled"
    var isAutosaveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.autosaveKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autosaveKey)
            autosaveSettingChanged()
        }
    }

    private func autosaveSettingChanged() {
        if isAutosaveEnabled { scheduleAutosave() } else { autosaveTask?.cancel() }
    }
    enum AutosaveState: Equatable {
        case saved
        /// Writing failed (for example the file changed elsewhere); autosave
        /// stops for this document until a manual save succeeds.
        case paused(String)
    }
    @Published private(set) var autosaveState: AutosaveState?
    private var autosaveTask: Task<Void, Never>?
    private static let autosaveDelay: UInt64 = 1_500_000_000
    private var isAutosavePaused: Bool {
        if case .paused = autosaveState { return true }
        return false
    }
    @Published var layoutMode: ReaderLayout = ReaderLayout(
        rawValue: UserDefaults.standard.string(forKey: "readerLayoutMode") ?? ""
    ) ?? .continuous {
        didSet { UserDefaults.standard.set(layoutMode.rawValue, forKey: "readerLayoutMode") }
    }

    weak var pdfView: PDFView?
    /// The window or tab showing this document.
    weak var window: NSWindow?
    private var documentPassword: String?
    private var scopedURL: URL?
    private var fileRevision: PDFFileRevision?
    private var pendingRestoredZoomScale: CGFloat?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Switching to another app is a natural moment to have everything on disk.
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveNow() }
        })
        // Settings changes the shared autosave setting for every window.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveSettingChanged() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? L("No Document") }

    /// Open panel for this window: an empty window shows the first file, and
    /// further files open as tabs.
    func presentOpenPanel() {
        AppModel.shared.presentOpenPanel(for: self)
    }

    /// The window is closing; unsaved changes were settled by its close button.
    func close() {
        commitPendingEdits?()
        autosaveTask?.cancel()
        searchTask?.cancel()
        exportTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    /// Opens a file in this window, replacing its document. Each file comes
    /// back at the page and zoom it was last read at.
    func open(_ url: URL, confirmingUnsavedChanges: Bool = true) {
        if confirmingUnsavedChanges { guard confirmDiscardingUnsavedChanges() else { return } }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        let opened: (document: PDFDocument, revision: PDFFileRevision)
        do {
            opened = try SafePDFFileStore.read(from: url)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            return
        }

        let previousPassword = documentPassword
        documentPassword = nil
        if opened.document.isLocked, !unlock(opened.document, named: url.lastPathComponent) {
            documentPassword = previousPassword
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            return
        }

        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        // Clear the reference when this URL needed no scope, so the previous URL is
        // never stopped a second time on the next open.
        scopedURL = didStartAccess ? url : nil
        pdfView?.undoManager?.removeAllActions(withTarget: self)
        resetNoteIconState()
        changeCount = 0
        savedChangeCount = 0
        hasUnsavedChanges = false
        autosaveTask?.cancel()
        autosaveState = nil
        annotationRevision += 1
        // PDFKit builds its own note badges when it first lays out a page, before
        // any overlay exists, so hand every page's notes over before display.
        // Scanning a 501-page file takes about 30 ms.
        for index in 0..<opened.document.pageCount {
            if let page = opened.document.page(at: index) { prepareNotes(on: page) }
        }
        document = opened.document
        fileURL = url
        fileRevision = opened.revision
        pageCount = opened.document.pageCount
        let remembered = ReadingPositions.position(for: url)
        currentPageIndex = min(max(remembered?.page ?? 0, 0), max(opened.document.pageCount - 1, 0))
        pendingRestoredZoomScale = remembered?.zoom
        if pendingRestoredZoomScale == nil { pdfView?.autoScales = true }
        searchText = ""
        searchResults = []
        searchResultIndex = 0
        errorMessage = nil
        AppModel.shared.noteOpened(url)
    }

    /// Asks for the user password of an encrypted PDF until it unlocks or the user cancels.
    private func unlock(_ document: PDFDocument, named name: String) -> Bool {
        var message = L("“%@” is password protected. Enter its password to open it.", name)
        while true {
            let alert = NSAlert()
            alert.messageText = L("Enter Document Password")
            alert.informativeText = message
            alert.addButton(withTitle: L("Open"))
            alert.addButton(withTitle: L("Cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if document.unlock(withPassword: field.stringValue) {
                // Kept in memory only, to unlock the copies that exports render from.
                documentPassword = field.stringValue
                return true
            }
            message = L("Incorrect password. Try again.")
        }
    }

    /// Returns true when it is fine to replace or drop the current document.
    func confirmDiscardingUnsavedChanges() -> Bool {
        commitPendingEdits?()
        guard hasUnsavedChanges, document != nil else { return true }
        if isAutosaveEnabled, !isAutosavePaused, (try? writeDocument()) != nil { return true }
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes made to “%@”?", displayName)
        alert.informativeText = L("Your annotation changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don’t Save"))
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
        if let fileURL { ReadingPositions.record(page: index, for: fileURL) }
    }

    func updateCurrentPage(_ index: Int) {
        guard document?.pageCount ?? 0 > 0 else { return }
        let safeIndex = min(max(index, 0), (document?.pageCount ?? 1) - 1)
        currentPageIndex = safeIndex
        if let fileURL { ReadingPositions.record(page: safeIndex, for: fileURL) }
    }

    // MARK: - Menu commands

    /// Searches for the selected text (⌘E), as text views do.
    func useSelectionForFind() {
        guard let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        find(text)
        focusSearch = true
    }

    func showSidebar(_ mode: SidebarMode) {
        sidebarMode = mode
        isSidebarVisible = true
    }

    /// Prints the document as it would be saved, so annotations the overlay
    /// draws on screen are included.
    func printDocument() {
        guard let document else { return }
        commitPendingEdits?()
        guard let snapshot = exportSnapshot(of: document),
              let operation = snapshot.value.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
            errorMessage = DocumentExportError.unableToWrite.localizedDescription
            return
        }
        operation.jobTitle = displayName
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
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
        if let fileURL { ReadingPositions.record(zoom: scale, for: fileURL) }
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

    private var searchTask: Task<Void, Never>?

    /// Searches page text with `NSRegularExpression`. PDFKit's `findString`
    /// ignores `.regularExpression`, so regular-expression and whole-word
    /// searches built on it never matched. The search runs in steps that
    /// yield to the UI and is cancelled when the query changes.
    func find(_ text: String) {
        searchText = text
        searchTask?.cancel()
        guard let document, let regex = searchExpression(for: text) else {
            showSearchResults([])
            return
        }
        searchTask = Task { @MainActor [weak self] in
            var results: [PDFSelection] = []
            for index in 0..<document.pageCount {
                guard !Task.isCancelled else { return }
                guard let page = document.page(at: index), let string = page.string else { continue }
                let range = NSRange(location: 0, length: (string as NSString).length)
                for match in regex.matches(in: string, range: range) where match.range.length > 0 {
                    if let selection = page.selection(for: match.range) { results.append(selection) }
                }
                if index % 25 == 24 { await Task.yield() }
            }
            guard !Task.isCancelled else { return }
            self?.showSearchResults(results)
        }
    }

    private func searchExpression(for text: String) -> NSRegularExpression? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var pattern = isRegularExpressionSearch ? text : NSRegularExpression.escapedPattern(for: text)
        if isWholeWordSearch {
            pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])"
        }
        return try? NSRegularExpression(pattern: pattern, options: isCaseSensitiveSearch ? [] : [.caseInsensitive])
    }

    private func showSearchResults(_ results: [PDFSelection]) {
        searchResults = results
        searchResultIndex = 0
        pdfView?.highlightedSelections = results.isEmpty ? nil : results
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
        lastMarkupTool = type == .underline ? .underline : (type == .strikeOut ? .strikeOut : .highlight)
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
        case .underline: L("Underline")
        case .strikeOut: L("Strikethrough")
        default: L("Highlight")
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

    /// An annotation that only counts once it gets text: the highlight made by
    /// "Add Note", a note placed with the note tool, or a new text box. It is
    /// kept, as one undo step, only if its text ends up non-empty.
    private var pendingCreation: (annotation: PDFAnnotation, edit: AnnotationEdit)?

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
        pendingCreation = (created, edit)
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
        if let pending = pendingCreation, pending.annotation === annotation {
            pendingCreation = nil
            if text.isEmpty {
                pending.edit.revert()
                annotationRevision += 1
                refreshPDFView()
            } else {
                storeNote(text, for: annotation)
                commit(pending.edit, actionName: L("Add Note"))
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
        pdfView?.undoManager?.setActionName(text.isEmpty ? L("Delete Note") : L("Edit Note"))
        annotationsDidChange()
    }

    func setColor(_ annotation: PDFAnnotation, to color: MarkupColor) {
        switch annotation.type {
        case "Highlight": selectedHighlightColor = color
        case "Underline": selectedUnderlineColor = color
        case "StrikeOut": selectedStrikeOutColor = color
        case "FreeText", "Ink", "Square", "Circle", "Line": drawingColor = color
        default: break
        }
        if pendingCreation?.annotation === annotation {
            // Part of a creation step that is not committed yet.
            applyDisplayColor(color.nsColor, to: annotation)
            annotationRevision += 1
            refreshPDFView()
            return
        }
        setColor(annotation, to: color.nsColor)
    }

    private func setColor(_ annotation: PDFAnnotation, to color: NSColor) {
        let previous = displayColor(of: annotation)
        guard !colorsMatch(previous, color) else { return }
        applyDisplayColor(color, to: annotation)
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setColor(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Color"))
        annotationsDidChange()
    }

    func deleteAnnotation(_ annotation: PDFAnnotation) {
        if let pending = pendingCreation, pending.annotation === annotation {
            pendingCreation = nil
            pending.edit.revert()
            annotationRevision += 1
            refreshPDFView()
            return
        }
        guard let page = annotation.page else { return }
        recordAnnotationEdit(annotation.type == "Text" ? L("Delete Note") : L("Delete Annotation"), pages: [page]) {
            page.removeAnnotation(annotation)
        }
    }

    // MARK: - Tools

    func color(for tool: AnnotationTool) -> MarkupColor {
        switch tool {
        case .highlight: selectedHighlightColor
        case .underline: selectedUnderlineColor
        case .strikeOut: selectedStrikeOutColor
        default: drawingColor
        }
    }

    func setColor(_ color: MarkupColor, for tool: AnnotationTool) {
        switch tool {
        case .highlight: selectedHighlightColor = color
        case .underline: selectedUnderlineColor = color
        case .strikeOut: selectedStrikeOutColor = color
        default: drawingColor = color
        }
    }

    /// Text selected in the PDF view, if any.
    private var selectedText: PDFSelection? {
        guard let selection = pdfView?.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }

    /// A toolbar tool button. A markup tool marks text that is already selected
    /// right away, as the context menu does, and stays active for further
    /// drags. Otherwise the button turns the tool on, or off when it is active.
    func chooseTool(_ tool: AnnotationTool) {
        if tool.marksText, let selection = selectedText {
            switch tool {
            case .underline: toggleUnderline(in: selection)
            case .strikeOut: toggleStrikeOut(in: selection)
            default: toggleHighlight(in: selection)
            }
            activeTool = tool
            return
        }
        activeTool = activeTool == tool ? .select : tool
    }

    /// A toolbar color dot: sets the tool's color, and with a markup tool marks
    /// selected text in that color, as the context menu's colors do.
    func chooseColor(_ color: MarkupColor, for tool: AnnotationTool) {
        setColor(color, for: tool)
        if tool == .textBox, let box = annotationBeingTyped {
            setColor(box, to: color)
            onTypingStyleChange?()
        }
        guard tool.marksText, let selection = selectedText else { return }
        switch tool {
        case .underline: applyUnderline(color: color, to: selection)
        case .strikeOut: applyStrikeOut(color: color, to: selection)
        default: applyHighlight(color: color, to: selection)
        }
    }

    /// Marks text selected while a markup tool is active.
    func applyActiveTool(to selection: PDFSelection) {
        switch activeTool {
        case .highlight: applyHighlight(color: selectedHighlightColor, to: selection)
        case .underline: applyUnderline(color: selectedUnderlineColor, to: selection)
        case .strikeOut: applyStrikeOut(color: selectedStrikeOutColor, to: selection)
        default: break
        }
    }

    /// Places a standalone note centered on a page point and opens its editor.
    func addStandaloneNote(at point: CGPoint, on page: PDFPage) {
        let side: CGFloat = 24
        let note = PDFAnnotation(
            bounds: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
            forType: .text,
            withProperties: nil
        )
        note.iconType = .comment
        note.color = MarkupColor.yellow.nsColor
        note.contents = ""
        let edit = captureAnnotationEdit(pages: [page]) { page.addAnnotation(note) }
        // The overlay draws the icon; see `prepareNotes(on:)`.
        handOverToOverlay(note)
        pendingCreation = (note, edit)
        annotationRevision += 1
        refreshPDFView()
        onEditAnnotation?(note)
    }

    static let textBoxFontSize: CGFloat = 14
    static let textBoxWidth: CGFloat = 180
    static let strokeWidths: [CGFloat] = [1, 2, 3, 5, 8]
    static let fontSizes: [CGFloat] = [9, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48]

    /// A regular font of a family, or the system font when the family is nil
    /// or not installed.
    static func font(family: String?, size: CGFloat) -> NSFont {
        guard let family,
              let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else {
            return .systemFont(ofSize: size)
        }
        return font
    }

    /// The family a text box uses, or nil for the system font.
    static func fontFamily(of box: PDFAnnotation) -> String? {
        guard let font = box.font, !font.fontName.hasPrefix(".") else { return nil }
        return font.familyName
    }

    /// Adds an empty text box whose top-left corner is at a page point. It is
    /// kept only if `finishTextBox` gives it text.
    func beginTextBox(at point: CGPoint, on page: PDFPage) -> PDFAnnotation {
        let font = Self.font(family: textFontFamily, size: textFontSize)
        let height = ceil(font.ascender - font.descender + font.leading) + 6
        let box = PDFAnnotation(
            bounds: CGRect(x: point.x, y: point.y - height, width: Self.textBoxWidth, height: height),
            forType: .freeText,
            withProperties: nil
        )
        box.font = font
        box.fontColor = drawingColor.nsColor
        box.color = .clear
        box.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        box.border = border
        box.contents = ""
        Self.stampTextStyle(of: box)
        let edit = captureAnnotationEdit(pages: [page]) { page.addAnnotation(box) }
        handOverToOverlay(box)
        pendingCreation = (box, edit)
        return box
    }

    /// Ends inline editing of a text box: commits a new box with text as one
    /// undo step, drops an empty new box, and deletes an emptied existing one.
    func finishTextBox(_ box: PDFAnnotation, text: String, bounds: CGRect) {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let pending = pendingCreation, pending.annotation === box {
            pendingCreation = nil
            if isEmpty {
                pending.edit.revert()
                annotationRevision += 1
                refreshPDFView()
            } else {
                box.contents = text
                box.bounds = bounds
                commit(pending.edit, actionName: L("Add Text Box"))
            }
            return
        }
        if isEmpty {
            deleteAnnotation(box)
            return
        }
        setTextBox(box, text: text, bounds: bounds)
    }

    private func setTextBox(_ box: PDFAnnotation, text: String, bounds: CGRect) {
        let previousText = box.contents ?? ""
        let previousBounds = box.bounds
        guard previousText != text || previousBounds != bounds else { return }
        box.contents = text
        box.bounds = bounds
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setTextBox(box, text: previousText, bounds: previousBounds)
        }
        pdfView?.undoManager?.setActionName(L("Edit Text Box"))
        annotationsDidChange()
    }

    /// Adds a freehand drawing through page points.
    func addInk(through points: [CGPoint], on page: PDFPage) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        let bounds = path.bounds.insetBy(dx: -strokeWidth * 2, dy: -strokeWidth * 2)
        // Ink paths are relative to the annotation's origin.
        let local = NSBezierPath()
        local.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
        for point in points.dropFirst() { local.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)) }
        local.lineWidth = strokeWidth
        local.lineCapStyle = .round
        local.lineJoinStyle = .round
        let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ink.add(local)
        ink.border = strokeBorder()
        ink.color = drawingColor.nsColor
        handOverToOverlay(ink)
        recordAnnotationEdit(L("Draw"), pages: [page]) { page.addAnnotation(ink) }
    }

    /// Adds a rectangle, ellipse or arrow dragged from `start` to `end`.
    func addShape(_ tool: AnnotationTool, from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard max(rect.width, rect.height) >= 4 else { return }
        let shape: PDFAnnotation
        switch tool {
        case .arrow:
            let bounds = rect.insetBy(dx: -10, dy: -10)
            shape = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            // Line end points are relative to the annotation's origin.
            shape.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            shape.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
            shape.endLineStyle = .openArrow
        case .ellipse:
            shape = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .circle, withProperties: nil)
        default:
            shape = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
        }
        shape.border = strokeBorder()
        shape.color = drawingColor.nsColor
        handOverToOverlay(shape)
        recordAnnotationEdit(L("Add Shape"), pages: [page]) { page.addAnnotation(shape) }
    }

    private func strokeBorder() -> PDFBorder {
        Self.border(width: strokeWidth)
    }

    private static func border(width: CGFloat) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width
        return border
    }

    // MARK: - Line width and fonts

    /// Toolbar line width: the default for new drawings and shapes.
    func chooseStrokeWidth(_ width: CGFloat) {
        strokeWidth = width
    }

    /// Toolbar font family or size: the default for new text boxes, also
    /// applied to the text box being typed.
    func chooseTextFont(family: String?, size: CGFloat) {
        textFontFamily = family
        textFontSize = size
        if let box = annotationBeingTyped {
            setFont(of: box, family: family, size: size)
            onTypingStyleChange?()
        }
    }

    func setStrokeWidth(_ annotation: PDFAnnotation, to width: CGFloat) {
        let previous = annotation.border?.lineWidth ?? 1
        guard abs(previous - width) > 0.01 else { return }
        strokeWidth = width
        annotation.border = Self.border(width: width)
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setStrokeWidth(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Line Width"))
        annotationsDidChange()
    }

    func setFont(of box: PDFAnnotation, family: String?, size: CGFloat) {
        let previous = (family: Self.fontFamily(of: box), size: box.font?.pointSize ?? Self.textBoxFontSize)
        guard previous.family != family || abs(previous.size - size) > 0.01 else { return }
        textFontFamily = family
        textFontSize = size
        box.font = Self.font(family: family, size: size)
        Self.stampTextStyle(of: box)
        if pendingCreation?.annotation === box {
            // Part of a creation step that is not committed yet.
            refreshPDFView()
            return
        }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setFont(of: box, family: previous.family, size: previous.size)
        }
        pdfView?.undoManager?.setActionName(L("Change Font"))
        annotationsDidChange()
    }

    /// Annotations the select tool can drag to a new place.
    static func isMovable(_ annotation: PDFAnnotation) -> Bool {
        ["FreeText", "Ink", "Square", "Circle", "Line"].contains(annotation.type ?? "")
    }

    /// Records a finished drag; the bounds were already updated while dragging.
    func commitMove(_ annotation: PDFAnnotation, from previous: CGRect) {
        let moved = annotation.bounds
        guard moved != previous else { return }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            annotation.bounds = previous
            target.commitMove(annotation, from: moved)
        }
        pdfView?.undoManager?.setActionName(L("Move Annotation"))
        annotationsDidChange()
    }

    /// The color an annotation shows: the text color for text boxes.
    func displayColor(of annotation: PDFAnnotation) -> NSColor {
        annotation.type == "FreeText" ? (annotation.fontColor ?? .black) : annotation.color
    }

    private func applyDisplayColor(_ color: NSColor, to annotation: PDFAnnotation) {
        if annotation.type == "FreeText" {
            annotation.fontColor = color
            Self.stampTextStyle(of: annotation)
        } else {
            annotation.color = color
        }
    }

    // MARK: - Note icons

    /// Annotations whose PDFKit rendering is hidden on screen because the page
    /// overlay draws them as vectors instead: standalone `/Text` note icons, and
    /// drawings, shapes and text boxes, which PDFKit on macOS 27 rasterizes at a
    /// low resolution. They are made visible again for the duration of every
    /// save, so other readers still show them.
    private var hiddenNativeAnnotations: [ObjectIdentifier: PDFAnnotation] = [:]
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

    /// PDFKit writes a text box's font and color only into its appearance
    /// stream, which other readers show correctly, but reads the box back as
    /// black 12 pt Helvetica with a 1 pt border. Text boxes made here also keep
    /// "size r g b a font" (a PostScript name, or "system") under this key,
    /// restored when the document opens.
    private static let textStyleKey = PDFAnnotationKey(rawValue: "/PaperplaneTextStyle")

    private static func stampTextStyle(of box: PDFAnnotation) {
        let size = box.font?.pointSize ?? textBoxFontSize
        let color = (box.fontColor ?? .black).usingColorSpace(.deviceRGB) ?? .black
        let values = [size, color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        let fontName = fontFamily(of: box) == nil ? "system" : (box.font?.fontName ?? "system")
        let style = values.map { String(format: "%.3f", $0) } + [fontName]
        box.setValue(style.joined(separator: " "), forAnnotationKey: textStyleKey)
    }

    /// Restores a stamped text style; false for text boxes from other apps.
    private static func restoreTextStyle(of box: PDFAnnotation) -> Bool {
        guard let raw = box.value(forAnnotationKey: textStyleKey) as? String else { return false }
        let tokens = raw.split(separator: " ").map(String.init)
        let values = tokens.prefix(5).compactMap { Double($0) }.map { CGFloat($0) }
        guard values.count == 5 else { return false }
        let fontName = tokens.count > 5 ? tokens[5] : "system"
        box.font = fontName == "system" ? .systemFont(ofSize: values[0]) : (NSFont(name: fontName, size: values[0]) ?? .systemFont(ofSize: values[0]))
        box.fontColor = NSColor(deviceRed: values[1], green: values[2], blue: values[3], alpha: values[4])
        box.border = border(width: 0)
        return true
    }

    /// Annotation types the overlay draws itself, besides note icons.
    static let overlayDrawnTypes: Set<String> = ["Ink", "Square", "Circle", "Line", "FreeText"]

    /// The text box being typed into; the overlay skips it while the inline
    /// editor shows its text.
    var annotationBeingTyped: PDFAnnotation? {
        didSet { refreshPDFView() }
    }

    /// Hides PDFKit's rendering of an annotation the overlay draws instead.
    private func handOverToOverlay(_ annotation: PDFAnnotation) {
        annotation.shouldDisplay = false
        hiddenNativeAnnotations[ObjectIdentifier(annotation)] = annotation
    }

    /// Drawings, shapes and text boxes on a page for the overlay to draw.
    func overlayDrawnAnnotations(on page: PDFPage) -> [PDFAnnotation] {
        prepareNotes(on: page)
        return page.annotations.filter {
            Self.overlayDrawnTypes.contains($0.type ?? "")
                && hiddenNativeAnnotations[ObjectIdentifier($0)] != nil
                && $0 !== annotationBeingTyped
        }
    }

    /// Hands a page's note icons, drawings, shapes and text boxes over to the
    /// overlay. Annotations their author hid stay hidden. Idempotent per page.
    func prepareNotes(on page: PDFPage) {
        guard preparedNotePages.insert(ObjectIdentifier(page)).inserted else { return }
        for annotation in page.annotations {
            let type = annotation.type ?? ""
            // Text boxes from other apps keep PDFKit's rendering, which follows
            // their own appearance stream more faithfully than a redraw would.
            let drawable = type == "FreeText" ? Self.restoreTextStyle(of: annotation) : Self.overlayDrawnTypes.contains(type)
            if (type == "Text" || drawable), annotation.shouldDisplay {
                handOverToOverlay(annotation)
            } else if MarkupEngine.isMarkup(annotation), let text = annotation.contents, !text.isEmpty {
                storeNote(text, for: annotation)
            }
        }
    }

    /// Restores what `prepareNotes` changed so the saved file is standard, and
    /// leaves out an annotation still waiting for its text (a note being written
    /// in its popover), which is not part of the document yet.
    private func withNativeNotesRestored<T>(_ body: () throws -> T) rethrows -> T {
        let pending = pendingCreation?.edit
        pending?.revert()
        for note in hiddenNativeAnnotations.values { note.shouldDisplay = true }
        for (annotation, text) in markupNotes.values { annotation.contents = text.isEmpty ? nil : text }
        defer {
            for note in hiddenNativeAnnotations.values { note.shouldDisplay = false }
            for (annotation, _) in markupNotes.values { annotation.contents = nil }
            pending?.apply()
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
            showsStandaloneNote: { [hiddenNativeAnnotations] in hiddenNativeAnnotations[ObjectIdentifier($0)] != nil }
        )
        markerCache[key] = (annotationRevision, markers)
        return markers
    }

    private func resetNoteIconState() {
        hiddenNativeAnnotations = [:]
        annotationBeingTyped = nil
        markupNotes = [:]
        preparedNotePages = []
        markerCache = [:]
        pendingCreation = nil
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

        func apply() {
            for (annotation, page) in removed { page.removeAnnotation(annotation) }
            for (annotation, page) in added { page.addAnnotation(annotation) }
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
        if pdfView?.undoManager?.isUndoing == true {
            changeCount -= 1
        } else if pdfView?.undoManager?.isRedoing == true {
            changeCount += 1
        } else {
            if changeCount < savedChangeCount { savedChangeCount = -1 }
            changeCount += 1
        }
        hasUnsavedChanges = changeCount != savedChangeCount
        annotationRevision += 1
        refreshPDFView()
        scheduleAutosave()
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard isAutosaveEnabled, !isAutosavePaused, hasUnsavedChanges else { return }
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.autosaveNow()
        }
    }

    /// Saves now if autosave applies. A text box being typed or a note still
    /// waiting for its text is not interrupted; the save waits for it.
    func autosaveNow() {
        guard isAutosaveEnabled, !isAutosavePaused, hasUnsavedChanges, document != nil else { return }
        if annotationBeingTyped != nil || pendingCreation != nil {
            scheduleAutosave()
            return
        }
        do {
            try writeDocument()
            autosaveState = .saved
        } catch {
            // Say it once; repeating the alert on every edit would be worse.
            autosaveState = .paused(error.localizedDescription)
            errorMessage = L("Autosave paused: %@ Save with ⌘S once the problem is resolved.", error.localizedDescription)
        }
    }

    private func refreshPDFView() {
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        (pdfView as? AnnotationOverlayHost)?.refreshAnnotationOverlays()
    }

    // MARK: - Annotation list

    private static let listedAnnotationKinds: [String: String] = [
        "Highlight": L("Highlight"),
        "Underline": L("Underline"),
        "StrikeOut": L("Strikethrough"),
        "Squiggly": L("Squiggly"),
        "Text": L("Note"),
        "FreeText": L("Text Box"),
        "Ink": L("Drawing"),
        "Square": L("Rectangle"),
        "Circle": L("Ellipse"),
        "Line": L("Line"),
        "Stamp": L("Stamp")
    ]

    private var annotationListCache: (revision: Int, document: ObjectIdentifier, items: [AnnotationListItem])?

    /// Every user-facing annotation in page order. Links, form widgets and popups
    /// are skipped. Cached per edit, since SwiftUI asks again on every redraw.
    func annotationListItems() -> [AnnotationListItem] {
        guard let document else { return [] }
        if let cache = annotationListCache, cache.revision == annotationRevision, cache.document == ObjectIdentifier(document) {
            return cache.items
        }
        let items = buildAnnotationListItems(in: document)
        annotationListCache = (annotationRevision, ObjectIdentifier(document), items)
        return items
    }

    private func buildAnnotationListItems(in document: PDFDocument) -> [AnnotationListItem] {
        var items: [AnnotationListItem] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let type = annotation.type, let kind = Self.listedAnnotationKinds[type],
                      pendingCreation?.annotation !== annotation else { continue }
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

    // MARK: - Export

    static let exportResolutions: [CGFloat] = [72, 150, 300]
    @Published var exportFlattensAnnotations = false
    @Published var imageExportFormat: PageImageFormat = .png
    @Published var imageExportRange: ImageExportRange = .currentPage
    @Published var imageExportPages = ""
    @Published var imageExportResolution: CGFloat = 150
    /// Images written so far and in all, while an image export runs.
    @Published private(set) var exportProgress: (done: Int, total: Int)?
    /// A short result shown in the export row for a few seconds.
    @Published private(set) var exportStatus: String?
    private var exportTask: Task<Void, Never>?

    /// Writes a PDF copy, with annotations editable or flattened into the pages.
    func exportPDFCopy() {
        guard let document else { return }
        commitPendingEdits?()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (exportFlattensAnnotations ? L("%@ (Flattened)", displayName) : L("%@ (Copy)", displayName)) + ".pdf"
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePDFCopy(of: document, to: url)
    }

    func writePDFCopy(of document: PDFDocument, to url: URL) {
        if let fileURL, url.standardizedFileURL == fileURL.standardizedFileURL {
            errorMessage = L("Choose another name. The open document is saved with ⌘S.")
            return
        }
        do {
            try withNativeNotesRestored {
                try DocumentExporter.writeCopy(of: document, to: url, flattenAnnotations: exportFlattensAnnotations)
            }
            showExportStatus(L("Exported “%@”.", url.lastPathComponent))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renders the chosen pages to image files in the background. One page is
    /// saved under a chosen name; several go into a chosen folder.
    func exportImages() {
        guard let document, exportProgress == nil else { return }
        commitPendingEdits?()
        let pages: [Int]
        switch imageExportRange {
        case .currentPage:
            pages = [currentPageIndex]
        case .allPages:
            pages = Array(0..<document.pageCount)
        case .custom:
            do {
                pages = try PageRangeParser.pages(from: imageExportPages, pageCount: document.pageCount)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        guard let destinations = imageDestinations(for: pages) else { return }
        startImageExport(of: document, to: destinations)
    }

    /// Writes each page index to its file in the background.
    func startImageExport(of document: PDFDocument, to destinations: [(Int, URL)]) {
        guard exportProgress == nil else { return }
        guard let snapshot = exportSnapshot(of: document) else {
            errorMessage = DocumentExportError.unableToWrite.localizedDescription
            return
        }
        let format = imageExportFormat
        let resolution = imageExportResolution
        let total = destinations.count
        exportProgress = (0, total)
        let report: @MainActor @Sendable (Int) -> Void = { [weak self] done in
            self?.exportProgress = (done, total)
        }
        let finish: @MainActor @Sendable (Int, String?) -> Void = { [weak self] written, failure in
            self?.finishImageExport(written: written, failure: failure, destinations: destinations)
        }
        exportTask = Task.detached(priority: .userInitiated) {
            var written = 0
            var failure: String?
            for (index, url) in destinations {
                if Task.isCancelled { break }
                guard let page = snapshot.value.page(at: index),
                      let data = DocumentExporter.imageData(for: page, dpi: resolution, format: format) else {
                    failure = DocumentExportError.unableToWrite.localizedDescription
                    break
                }
                do {
                    // Not atomic: a single chosen file grants no access to its folder.
                    try data.write(to: url)
                } catch {
                    failure = error.localizedDescription
                    break
                }
                written += 1
                await report(written)
            }
            await finish(written, failure)
        }
    }

    private func finishImageExport(written: Int, failure: String?, destinations: [(Int, URL)]) {
        exportProgress = nil
        exportTask = nil
        let total = destinations.count
        if let failure {
            errorMessage = failure
        } else if written < total {
            showExportStatus(L("Export stopped after %ld of %ld images.", written, total))
        } else if total == 1, let url = destinations.first?.1 {
            showExportStatus(L("Exported “%@”.", url.lastPathComponent))
        } else if let folder = destinations.first?.1.deletingLastPathComponent() {
            showExportStatus(L("Exported %ld images to “%@”.", total, folder.lastPathComponent))
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// Asks where the images go; nil when the user cancels.
    private func imageDestinations(for pages: [Int]) -> [(Int, URL)]? {
        let fileExtension = imageExportFormat.fileExtension
        func fileName(_ index: Int) -> String { L("%@ - Page %ld", displayName, index + 1) + "." + fileExtension }
        if pages.count == 1, let page = pages.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [imageExportFormat == .png ? .png : .jpeg]
            panel.nameFieldStringValue = fileName(page)
            panel.prompt = L("Export")
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return [(page, url)]
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        let destinations = pages.map { ($0, folder.appendingPathComponent(fileName($0))) }
        let existing = destinations.filter { FileManager.default.fileExists(atPath: $0.1.path) }.count
        if existing > 0 {
            let alert = NSAlert()
            alert.messageText = L("Replace %ld existing files?", existing)
            alert.addButton(withTitle: L("Replace"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        return destinations
    }

    /// A private copy of the document as it would be saved, for rendering off
    /// the main thread without touching the document on screen.
    private func exportSnapshot(of document: PDFDocument) -> UncheckedSendable<PDFDocument>? {
        guard let data = withNativeNotesRestored({ document.dataRepresentation() }),
              let copy = PDFDocument(data: data) else { return nil }
        if copy.isLocked {
            guard let documentPassword, copy.unlock(withPassword: documentPassword) else { return nil }
        }
        return UncheckedSendable(value: copy)
    }

    private func showExportStatus(_ text: String) {
        exportStatus = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.exportStatus == text { self?.exportStatus = nil }
        }
    }

    @discardableResult
    func save() -> Bool {
        commitPendingEdits?()
        do {
            try writeDocument()
            // A manual save that succeeds resumes autosave.
            autosaveState = isAutosaveEnabled ? .saved : nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func writeDocument() throws {
        guard let document, let fileURL, let fileRevision else { throw SafePDFFileStoreError.unreadablePDF }
        autosaveTask?.cancel()
        self.fileRevision = try withNativeNotesRestored {
            try SafePDFFileStore.save(document, to: fileURL, expectedRevision: fileRevision)
        }
        savedChangeCount = changeCount
        hasUnsavedChanges = false
    }
}

/// Hands a value to a background task that alone uses it from then on.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
