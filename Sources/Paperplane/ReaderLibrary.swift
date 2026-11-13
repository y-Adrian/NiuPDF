import AppKit
import OSLog
import PDFKit
import PaperplaneCore
import SwiftUI
import UniformTypeIdentifiers

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
    let listKind: AnnotationListKind
    /// The color the annotation shows: a text box's text color, otherwise its own.
    let color: MarkupColor
    /// `userName`, trimmed; empty when the annotation names no author.
    let author: String
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

    static let white = MarkupColor(hex: "FFFFFF", title: L("White"))
    static let lightYellow = MarkupColor(hex: "FFF6BF", title: L("Light Yellow"))
    static let lightBlue = MarkupColor(hex: "DCEEFF", title: L("Light Blue"))
    static let lightGreen = MarkupColor(hex: "DDF5DF", title: L("Light Green"))
    static let lightPink = MarkupColor(hex: "FFE1E1", title: L("Light Pink"))
    static let lightGray = MarkupColor(hex: "EDEDED", title: L("Light Gray"))
    /// Text box backgrounds: light, opaque colors that keep text readable.
    static let backgroundCases = [white, lightYellow, lightBlue, lightGreen, lightPink, lightGray]
}

/// The annotation tools in the toolbar. A tool stays active for repeated use,
/// as in PDF Expert, until another tool is chosen or Esc returns to `select`.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case squiggly
    case strikeOut
    case textBox
    case note
    case ink
    case rectangle
    case ellipse
    case arrow
    /// Marks areas to redact; see `Redaction.swift`.
    case redact

    var id: String { rawValue }

    static let shapes: [AnnotationTool] = [.rectangle, .ellipse, .arrow]
    /// Tools that mark selected text, in toolbar order.
    static let markupTools: [AnnotationTool] = [.highlight, .underline, .squiggly, .strikeOut]

    var title: String {
        switch self {
        case .select: L("Select")
        case .highlight: L("Highlight")
        case .underline: L("Underline")
        case .squiggly: L("Squiggly")
        case .strikeOut: L("Strikethrough")
        case .textBox: L("Text Box")
        case .note: L("Note")
        case .ink: L("Draw")
        case .rectangle: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .arrow: L("Arrow")
        case .redact: L("Redact")
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .squiggly: "water.waves"
        case .strikeOut: "strikethrough"
        case .textBox: "character.textbox"
        case .note: "text.bubble"
        case .ink: "scribble"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .redact: "rectangle.inset.filled"
        }
    }

    /// Tools applied to text selected by dragging.
    var marksText: Bool { Self.markupTools.contains(self) }
    var isShape: Bool { Self.shapes.contains(self) }
    var colorChoices: [MarkupColor] { marksText ? MarkupColor.allCases : MarkupColor.drawingCases }
}

@MainActor
final class ReaderLibrary: ObservableObject {
    @Published var document: PDFDocument?
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var pageCount = 0
    /// True for the next `currentPageIndex` change that came from a direct
    /// navigation (menu, thumbnail, search, bookmark), so the thumbnail sidebar
    /// animates to it; scroll-driven page changes leave it false and the sidebar
    /// follows instantly instead. Not @Published: it is only read by the
    /// sidebar's onChange, which is driven by `currentPageIndex`.
    var animatesSidebarReveal = false
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
    @Published var selectedSquigglyColor: MarkupColor = .red
    /// Color for text boxes, drawings and shapes.
    @Published var drawingColor: MarkupColor = .red
    /// Opacity of new highlights, underlines and strikethroughs, per tool.
    @Published var markupOpacities: [AnnotationTool: CGFloat] = [:]
    /// Opacity of new text boxes, drawings and shapes.
    @Published var drawingOpacity: CGFloat = 1
    /// Line width for new drawings and shapes, in page points.
    @Published var strokeWidth: CGFloat = 2
    /// Font family for new text boxes; nil is the system font.
    @Published var textFontFamily: String?
    @Published var textFontSize: CGFloat = 14
    /// Background of new text boxes; nil leaves them clear.
    @Published var textBoxBackground: MarkupColor?
    /// Border of new text boxes in points; 0 is none. Borders are black, as
    /// PDFKit draws them in other readers whatever the color asked for.
    @Published var textBoxBorderWidth: CGFloat = 0
    /// Set by the text box editor so style changes reach the box being typed.
    var onTypingStyleChange: (() -> Void)?
    /// The markup tool last applied, which the context menu's colors apply to.
    var lastMarkupTool: AnnotationTool = .highlight
    @Published var activeTool: AnnotationTool = .select {
        didSet {
            guard activeTool != oldValue else { return }
            if activeTool != .select { selectedAnnotations = [] }
            onToolChange?()
        }
    }
    /// Annotations selected for editing: their frame and handles are drawn by
    /// the page overlay, and Delete, arrow keys, copy and paste act on them.
    @Published var selectedAnnotations: [PDFAnnotation] = [] {
        didSet { (pdfView as? AnnotationOverlayHost)?.refreshAnnotationOverlays() }
    }
    /// The toolbar tab whose row is expanded under the toolbar; one at a time.
    /// Leaving the annotation row returns to plain selection.
    @Published var expandedMode: ToolbarMode? {
        didSet { if expandedMode != .annotate { activeTool = .select } }
    }
    var isAnnotationBarVisible: Bool {
        get { expandedMode == .annotate }
        set {
            guard !newValue || canAnnotate else { return }
            expandedMode = newValue ? .annotate : (expandedMode == .annotate ? nil : expandedMode)
        }
    }
    /// Set by the PDF view: ends drags and inline text editing on a tool change.
    var onToolChange: (() -> Void)?
    /// Set by the PDF view: commits a text box still being typed into.
    var commitPendingEdits: (() -> Void)?
    @Published var focusSearch = false
    /// Set by "Go to Page…" to put the cursor in the page number field.
    @Published var focusPageField = false
    /// Pages selected in the thumbnail sidebar; page commands act on these, or
    /// on the current page when none are selected.
    @Published var selectedPages = IndexSet()
    /// Where a shift-click range starts.
    var pageSelectionAnchor: Int?
    /// Pages being dragged within the thumbnail sidebar.
    var draggedPages: IndexSet?
    @Published var isSidebarVisible = true
    @Published var sidebarMode: SidebarMode = .thumbnails
    /// The open file's bookmarks; see Bookmarks.swift.
    @Published var bookmarks: [PageBookmark] = []
    /// The page each bookmark belongs to, so bookmarks follow moved pages.
    var bookmarkPages: [UUID: PDFPage] = [:]
    @Published var errorMessage: String? {
        didSet { if let errorMessage { Logger.problems.error("Shown: \(errorMessage, privacy: .public)") } }
    }
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
    /// The file asked for a password when it was opened.
    @Published private(set) var requiresOpenPassword = false
    /// What readers without the permissions password may do, when the file
    /// restricts it and this window was opened without that password.
    @Published private(set) var readerRestrictions: PDFPasswordSettings?
    /// Shows the sheet that sets or changes the passwords.
    @Published var isEditingPassword = false
    /// Shows the signature sheet.
    @Published var isAddingSignature = false
    /// The crop or split sheet, while shown.
    @Published var pageSheet: PageSheet?
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
    /// The open password just written, so the reopened file can be checked as a reader.
    private var pendingReaderPassword: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Switching to another app is a natural moment to have everything on disk.
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autosaveNow()
                ReadingPositions.flush()
            }
        })
        // PDFKit fills in form fields itself; see `formFieldDidChange`.
        observers.append(center.addObserver(forName: Self.formDidChangeValue, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let document = self.document, note.object as? PDFDocument === document else { return }
                self.formFieldDidChange()
            }
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
        ReadingPositions.flush()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    /// Opens a file in this window, replacing its document. Each file comes
    /// back at the page and zoom it was last read at.
    func open(_ url: URL, confirmingUnsavedChanges: Bool = true, password knownPassword: String? = nil) {
        if confirmingUnsavedChanges { guard confirmDiscardingUnsavedChanges() else { return } }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        let opened: (document: PDFDocument, revision: PDFFileRevision)
        do {
            opened = try SafePDFFileStore.read(from: url)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            Logger.opening.error("Couldn’t read \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
            return
        }

        let previousPassword = documentPassword
        documentPassword = nil
        let wasLocked = opened.document.isLocked
        if wasLocked, !unlock(opened.document, at: url, knownPassword: knownPassword) {
            Logger.opening.info("Password entry cancelled for \(url.lastPathComponent, privacy: .public)")
            documentPassword = previousPassword
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            return
        }
        // A file that opens freely may still restrict changes until its
        // permissions password is given.
        if !wasLocked, let knownPassword, opened.document.unlock(withPassword: knownPassword),
           opened.document.permissionsStatus == .owner {
            documentPassword = knownPassword
        }

        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        // Clear the reference when this URL needed no scope, so the previous URL is
        // never stopped a second time on the next open.
        scopedURL = didStartAccess ? url : nil
        pdfView?.undoManager?.removeAllActions(withTarget: self)
        noteProtection(of: opened.document, wasLocked: wasLocked, at: url)
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
        refreshPageMarks(in: opened.document)
        document = opened.document
        fileURL = url
        // The annotation tools stay closed while the file forbids annotations.
        if !canAnnotate, expandedMode == .annotate { expandedMode = nil }
        fileRevision = opened.revision
        pageCount = opened.document.pageCount
        let remembered = ReadingPositions.position(for: url)
        currentPageIndex = min(max(remembered?.page ?? 0, 0), max(opened.document.pageCount - 1, 0))
        pendingRestoredZoomScale = remembered?.zoom
        if pendingRestoredZoomScale == nil { pdfView?.autoScales = true }
        searchText = ""
        searchResults = []
        searchResultIndex = 0
        annotationListFilter = AnnotationListFilter()
        selectedPages = []
        pageSelectionAnchor = nil
        selectedAnnotations = []
        errorMessage = nil
        loadBookmarks()
        AppModel.shared.noteOpened(url)
        Logger.opening.info("Opened \(url.lastPathComponent, privacy: .public) (\(opened.document.pageCount) pages) in window \(self.window?.windowNumber ?? -1); window visible: \(self.window?.isVisible ?? false)")
    }

    /// Unlocks an encrypted PDF with its saved or entered password; false when the user cancels.
    func unlock(_ document: PDFDocument, at url: URL, knownPassword: String? = nil) -> Bool {
        if let knownPassword, document.unlock(withPassword: knownPassword) {
            documentPassword = knownPassword
            return true
        }
        guard let password = Self.askForPassword(unlocking: document, at: url) else { return false }
        // Kept in memory only, to unlock the copies that exports render from.
        documentPassword = password
        return true
    }

    /// Whether the password prompt offers to remember the password, as last chosen.
    static let remembersPasswordsKey = "remembersDocumentPasswords"

    /// The password saved in the keychain for this file while it still works;
    /// otherwise asks until a password unlocks `document`, and saves it when
    /// the user chooses to. Nil when the user cancels.
    static func askForPassword(unlocking document: PDFDocument, at url: URL) -> String? {
        let name = url.lastPathComponent
        var message = L("“%@” is password protected. Enter its password to open it.", name)
        var remembers = UserDefaults.standard.bool(forKey: remembersPasswordsKey)
        if let saved = PasswordKeychain.password(for: url) {
            if document.unlock(withPassword: saved) {
                Logger.opening.info("Unlocked \(name, privacy: .public) with its saved password")
                return saved
            }
            // The file's password changed since it was saved.
            PasswordKeychain.remove(for: url)
            message = L("The saved password no longer opens “%@”. Enter its current password.", name)
            remembers = true
        }
        while true {
            let alert = NSAlert()
            alert.messageText = L("Enter Document Password")
            alert.informativeText = message
            alert.addButton(withTitle: L("Open"))
            alert.addButton(withTitle: L("Cancel"))
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
            let checkbox = NSButton(checkboxWithTitle: L("Remember password in Keychain"), target: nil, action: nil)
            checkbox.state = remembers ? .on : .off
            checkbox.sizeToFit()
            checkbox.frame.origin = .zero
            accessory.frame.size.width = max(240, checkbox.frame.width)
            accessory.addSubview(field)
            accessory.addSubview(checkbox)
            alert.accessoryView = accessory
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            remembers = checkbox.state == .on
            UserDefaults.standard.set(remembers, forKey: remembersPasswordsKey)
            let password = field.stringValue
            if document.unlock(withPassword: password) {
                if remembers, !PasswordKeychain.save(password, for: url) {
                    Logger.opening.error("Couldn’t save the password of \(name, privacy: .public) to the keychain")
                }
                return password
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
        animatesSidebarReveal = true
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
        guard canPrint else {
            errorMessage = L("This document doesn’t allow printing.")
            return
        }
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
        let selection = searchResults[searchResultIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        // Reveal the match in the sidebar right away; the pageChanged
        // notification would otherwise update the page a beat later.
        if let page = selection.pages.first, let document {
            let index = document.index(for: page)
            if index != NSNotFound {
                animatesSidebarReveal = true
                updateCurrentPage(index)
            }
        }
    }

    // MARK: - Text markup

    private enum MarkupIntent {
        /// Markup icon: erases the selected part when it is already marked in this
        /// color, otherwise marks it, merging with overlapping markup of the type.
        case toggle
        /// Color swatch: always marks the selection in the chosen color.
        case apply
    }

    /// Marks the selection with a markup tool in its current color, or
    /// removes that markup where the selection already has it.
    func toggleMarkup(_ tool: AnnotationTool, in selection: PDFSelection) {
        editMarkup(tool, color: color(for: tool), in: selection, intent: .toggle)
    }

    /// Marks the selection with a markup tool in a color, which becomes the
    /// tool's color.
    func applyMarkup(_ tool: AnnotationTool, color: MarkupColor, to selection: PDFSelection) {
        setColor(color, for: tool)
        editMarkup(tool, color: color, in: selection, intent: .apply)
    }

    private func editMarkup(_ tool: AnnotationTool, color: MarkupColor, in selection: PDFSelection, intent: MarkupIntent) {
        guard canAnnotate else { return }
        lastMarkupTool = tool
        let styled = color.nsColor.withAlphaComponent(opacity(for: tool))
        recordAnnotationEdit(tool.title, pages: selection.pages) {
            for page in selection.pages {
                markCharacters(tool, color: styled, characters: MarkupEngine.characters(of: selection, on: page), on: page, intent: intent)
            }
        }
        pdfView?.clearSelection()
    }

    /// Applies one markup edit on one page and returns the annotation that now
    /// covers the characters, or nil when the edit erased markup.
    @discardableResult
    private func markCharacters(
        _ tool: AnnotationTool,
        color: NSColor,
        characters: IndexSet,
        on page: PDFPage,
        intent: MarkupIntent
    ) -> PDFAnnotation? {
        let wanted = MarkupEngine.visibleCharacters(characters, on: page)
        guard !wanted.isEmpty else { return nil }
        let overlapping = page.annotations
            .filter { MarkupEngine.tool(of: $0) == tool }
            .map { ($0, MarkupEngine.characters(of: $0, on: page)) }
            .filter { !$0.1.intersection(wanted).isEmpty }
        let covered = overlapping.reduce(IndexSet()) { $0.union($1.1) }

        if intent == .toggle, !overlapping.isEmpty,
           // Opacity does not matter: the same color toggles markup off.
           overlapping.allSatisfy({ colorsMatch($0.0.color, color, ignoringOpacity: true) }),
           wanted.isSubset(of: covered) {
            // Erase only the selected part; what is left keeps its color and note.
            for (annotation, marked) in overlapping {
                page.removeAnnotation(annotation)
                let remaining = marked.subtracting(characters)
                for (index, run) in MarkupEngine.runs(of: remaining, on: page).enumerated() {
                    guard let piece = MarkupEngine.makeAnnotation(tool: tool, color: annotation.color, characters: run, on: page) else { continue }
                    Self.stampOpacity(of: piece)
                    page.addAnnotation(piece)
                    if tool == .squiggly { handOverToOverlay(piece) }
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
        guard let merged = MarkupEngine.makeAnnotation(tool: tool, color: color, characters: characters.union(covered), on: page) else {
            return nil
        }
        Self.stampOpacity(of: merged)
        page.addAnnotation(merged)
        if tool == .squiggly { handOverToOverlay(merged) }
        storeNote(notes.joined(separator: "\n\n"), for: merged)
        return merged
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

    private func colorsMatch(_ first: NSColor, _ second: NSColor, ignoringOpacity: Bool = false) -> Bool {
        guard let first = first.usingColorSpace(.deviceRGB),
              let second = second.usingColorSpace(.deviceRGB) else {
            return first.isEqual(second)
        }
        let tolerance: CGFloat = 0.02
        return abs(first.redComponent - second.redComponent) < tolerance
            && abs(first.greenComponent - second.greenComponent) < tolerance
            && abs(first.blueComponent - second.blueComponent) < tolerance
            && (ignoringOpacity || abs(first.alphaComponent - second.alphaComponent) < tolerance)
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
        guard canAnnotate else { return }
        pdfView?.clearSelection()
        if let existing = markups(in: selection).first {
            onEditAnnotation?(existing)
            return
        }
        guard let page = selection.pages.first else { return }
        let characters = MarkupEngine.characters(of: selection, on: page)
        var created: PDFAnnotation?
        let edit = captureAnnotationEdit(pages: [page]) {
            created = markCharacters(.highlight, color: styledColor(for: .highlight), characters: characters, on: page, intent: .apply)
        }
        guard let created else {
            edit.revert()
            return
        }
        pendingCreation = (created, edit)
        annotationRevision += 1
        refreshPDFView(on: [page])
        onEditAnnotation?(created)
    }

    func removeNote(in selection: PDFSelection) {
        guard canAnnotate else { return }
        guard let markup = notedMarkup(in: selection) else { return }
        setNote(markup, to: "")
        pdfView?.clearSelection()
    }

    /// Called when the editor popover closes. Empty notes are not kept: a pending
    /// "Add Note" highlight is dropped and an empty standalone note is deleted.
    func finishEditing(_ annotation: PDFAnnotation, note: String) {
        guard canAnnotate else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : note
        if let pending = pendingCreation, pending.annotation === annotation {
            pendingCreation = nil
            if text.isEmpty {
                pending.edit.revert()
                annotationRevision += 1
                refreshPDFView(on: pending.edit.pages)
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
        guard canAnnotate else { return }
        let previous = note(of: annotation)
        guard previous != text else { return }
        storeNote(text, for: annotation)
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setNote(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(text.isEmpty ? L("Delete Note") : L("Edit Note"))
        annotationsDidChange(on: annotation.page.map { [$0] })
    }

    func setColor(_ annotation: PDFAnnotation, to color: MarkupColor) {
        guard canAnnotate else { return }
        if let tool = MarkupEngine.tool(of: annotation) {
            setColor(color, for: tool)
        } else if ["FreeText", "Ink", "Square", "Circle", "Line"].contains(annotation.type ?? "") {
            drawingColor = color
        }
        // A new color keeps the annotation's opacity.
        let nsColor = color.nsColor.withAlphaComponent(displayColor(of: annotation).alphaComponent)
        if pendingCreation?.annotation === annotation {
            // Part of a creation step that is not committed yet.
            applyDisplayColor(nsColor, to: annotation)
            annotationRevision += 1
            refreshPDFView(on: annotation.page.map { [$0] })
            return
        }
        setColor(annotation, to: nsColor)
    }

    /// Changes one annotation's opacity, which also becomes the default for
    /// new annotations of its kind.
    func setOpacity(_ annotation: PDFAnnotation, to opacity: CGFloat) {
        guard canAnnotate else { return }
        let current = displayColor(of: annotation)
        let previous = current.alphaComponent
        guard abs(previous - opacity) > 0.005 else { return }
        setOpacity(opacity, for: Self.defaultsTool(for: annotation))
        applyDisplayColor(current.withAlphaComponent(opacity), to: annotation)
        if pendingCreation?.annotation === annotation {
            annotationRevision += 1
            refreshPDFView(on: annotation.page.map { [$0] })
            return
        }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setOpacity(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Opacity"))
        annotationsDidChange(on: annotation.page.map { [$0] })
    }

    /// The tool whose color and opacity defaults an annotation's kind uses.
    static func defaultsTool(for annotation: PDFAnnotation) -> AnnotationTool {
        MarkupEngine.tool(of: annotation) ?? .ink
    }

    private func setColor(_ annotation: PDFAnnotation, to color: NSColor) {
        let previous = displayColor(of: annotation)
        guard !colorsMatch(previous, color) else { return }
        applyDisplayColor(color, to: annotation)
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setColor(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Color"))
        annotationsDidChange(on: annotation.page.map { [$0] })
    }

    func deleteAnnotation(_ annotation: PDFAnnotation) {
        guard canAnnotate else { return }
        if let pending = pendingCreation, pending.annotation === annotation {
            pendingCreation = nil
            pending.edit.revert()
            annotationRevision += 1
            refreshPDFView(on: pending.edit.pages)
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
        case .squiggly: selectedSquigglyColor
        case .strikeOut: selectedStrikeOutColor
        default: drawingColor
        }
    }

    func setColor(_ color: MarkupColor, for tool: AnnotationTool) {
        switch tool {
        case .highlight: selectedHighlightColor = color
        case .underline: selectedUnderlineColor = color
        case .squiggly: selectedSquigglyColor = color
        case .strikeOut: selectedStrikeOutColor = color
        default: drawingColor = color
        }
    }

    static let opacities: [CGFloat] = [1, 0.75, 0.5, 0.25]

    /// Whether a tool's annotations can be see-through. Text boxes cannot:
    /// PDFKit drops the alpha of a text color as soon as it is set.
    static func hasOpacity(_ tool: AnnotationTool) -> Bool {
        tool != .select && tool != .note && tool != .textBox && tool != .redact
    }

    /// Opacity for new annotations of a tool: each markup tool has its own;
    /// drawings and shapes share one.
    func opacity(for tool: AnnotationTool) -> CGFloat {
        guard Self.hasOpacity(tool) else { return 1 }
        return tool.marksText ? markupOpacities[tool] ?? 1 : drawingOpacity
    }

    func setOpacity(_ opacity: CGFloat, for tool: AnnotationTool) {
        guard Self.hasOpacity(tool) else { return }
        if tool.marksText {
            markupOpacities[tool] = opacity
        } else {
            drawingOpacity = opacity
        }
    }

    /// Toolbar opacity: the default for new annotations made with the tool.
    func chooseOpacity(_ opacity: CGFloat, for tool: AnnotationTool) {
        setOpacity(opacity, for: tool)
    }

    /// The color, with its opacity, of new annotations made with a tool.
    func styledColor(for tool: AnnotationTool) -> NSColor {
        color(for: tool).nsColor.withAlphaComponent(opacity(for: tool))
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
            toggleMarkup(tool, in: selection)
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
        applyMarkup(tool, color: color, to: selection)
    }

    /// Marks text selected while a markup tool is active.
    func applyActiveTool(to selection: PDFSelection) {
        guard activeTool.marksText else { return }
        applyMarkup(activeTool, color: color(for: activeTool), to: selection)
    }

    /// Places a standalone note centered on a page point and opens its editor.
    func addStandaloneNote(at point: CGPoint, on page: PDFPage) {
        guard canAnnotate else { return }
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
        refreshPDFView(on: [page])
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
        box.fontColor = styledColor(for: .textBox)
        box.color = textBoxBackground?.nsColor ?? .clear
        box.alignment = .left
        box.border = Self.border(width: textBoxBorderWidth)
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
        guard canAnnotate else { return }
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let pending = pendingCreation, pending.annotation === box {
            pendingCreation = nil
            if isEmpty {
                pending.edit.revert()
                annotationRevision += 1
                refreshPDFView(on: pending.edit.pages)
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
        annotationsDidChange(on: box.page.map { [$0] })
    }

    /// Adds a freehand drawing through page points.
    func addInk(through points: [CGPoint], on page: PDFPage) {
        guard canAnnotate, points.count > 1 else { return }
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
        ink.color = styledColor(for: .ink)
        Self.stampOpacity(of: ink)
        handOverToOverlay(ink)
        recordAnnotationEdit(L("Draw"), pages: [page]) { page.addAnnotation(ink) }
    }

    /// Adds a rectangle, ellipse or arrow dragged from `start` to `end`.
    func addShape(_ tool: AnnotationTool, from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        guard canAnnotate else { return }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard max(rect.width, rect.height) >= 4 else { return }
        if tool == .redact {
            addRedactionMarks([(page, rect)])
            return
        }
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
        shape.color = styledColor(for: tool)
        Self.stampOpacity(of: shape)
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
        guard canAnnotate else { return }
        let previous = annotation.border?.lineWidth ?? 1
        guard abs(previous - width) > 0.01 else { return }
        strokeWidth = width
        annotation.border = Self.border(width: width)
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setStrokeWidth(annotation, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Line Width"))
        annotationsDidChange(on: annotation.page.map { [$0] })
    }

    static let textBoxBorderWidths: [CGFloat] = [0, 1, 2, 3]

    /// The background a text box shows, or nil when it is clear.
    static func background(of box: PDFAnnotation) -> MarkupColor? {
        guard box.color.alphaComponent > 0, box.color.usingColorSpace(.deviceRGB) != nil else { return nil }
        return MarkupColor(nearest: box.color, among: MarkupColor.backgroundCases)
    }

    /// Toolbar background and border: the defaults for new text boxes, also
    /// applied to the text box being typed.
    func chooseTextBoxBackground(_ color: MarkupColor?) {
        textBoxBackground = color
        if let box = annotationBeingTyped {
            setBackground(of: box, to: color)
            onTypingStyleChange?()
        }
    }

    func chooseTextBoxBorder(_ width: CGFloat) {
        textBoxBorderWidth = width
        if let box = annotationBeingTyped {
            setBorderWidth(of: box, to: width)
            onTypingStyleChange?()
        }
    }

    func setBackground(of box: PDFAnnotation, to color: MarkupColor?) {
        guard canAnnotate else { return }
        let previous = Self.background(of: box)
        guard previous?.hex != color?.hex else { return }
        textBoxBackground = color
        box.color = color?.nsColor ?? .clear
        if pendingCreation?.annotation === box {
            refreshPDFView(on: box.page.map { [$0] } ?? [])
            return
        }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setBackground(of: box, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Background"))
        annotationsDidChange(on: box.page.map { [$0] })
    }

    func setBorderWidth(of box: PDFAnnotation, to width: CGFloat) {
        guard canAnnotate else { return }
        let previous = box.border?.lineWidth ?? 0
        guard abs(previous - width) > 0.01 else { return }
        textBoxBorderWidth = width
        box.border = Self.border(width: width)
        Self.stampTextStyle(of: box)
        if pendingCreation?.annotation === box {
            refreshPDFView(on: box.page.map { [$0] })
            return
        }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setBorderWidth(of: box, to: previous)
        }
        pdfView?.undoManager?.setActionName(L("Change Border"))
        annotationsDidChange(on: box.page.map { [$0] })
    }

    func setFont(of box: PDFAnnotation, family: String?, size: CGFloat) {
        guard canAnnotate else { return }
        let previous = (family: Self.fontFamily(of: box), size: box.font?.pointSize ?? Self.textBoxFontSize)
        guard previous.family != family || abs(previous.size - size) > 0.01 else { return }
        textFontFamily = family
        textFontSize = size
        box.font = Self.font(family: family, size: size)
        Self.stampTextStyle(of: box)
        if pendingCreation?.annotation === box {
            // Part of a creation step that is not committed yet.
            refreshPDFView(on: box.page.map { [$0] })
            return
        }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            target.setFont(of: box, family: previous.family, size: previous.size)
        }
        pdfView?.undoManager?.setActionName(L("Change Font"))
        annotationsDidChange(on: box.page.map { [$0] })
    }

    /// Annotations the select tool can drag to a new place.
    static func isMovable(_ annotation: PDFAnnotation) -> Bool {
        ["FreeText", "Ink", "Square", "Circle", "Line"].contains(annotation.type ?? "") || ImageStamp.isImage(annotation)
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
            Self.stampOpacity(of: annotation)
        }
    }

    /// PDFKit writes an annotation's opacity only into its appearance stream,
    /// which other readers show correctly, but reads the color back opaque.
    /// Annotations made here also keep the opacity under this key, restored
    /// when their page is prepared. Text boxes keep it in their text style.
    private static let opacityKey = PDFAnnotationKey(rawValue: "/PaperplaneOpacity")

    static func stampOpacity(of annotation: PDFAnnotation) {
        let alpha = annotation.color.alphaComponent
        if alpha < 0.995 {
            annotation.setValue(String(format: "%.3f", alpha), forAnnotationKey: opacityKey)
        } else {
            annotation.removeValue(forAnnotationKey: opacityKey)
        }
    }

    private static func restoreOpacity(of annotation: PDFAnnotation) {
        guard let raw = annotation.value(forAnnotationKey: opacityKey),
              let alpha = Double("\(raw)"), alpha > 0, alpha < 1,
              abs(annotation.color.alphaComponent - alpha) > 0.005 else { return }
        annotation.color = annotation.color.withAlphaComponent(alpha)
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
    /// "size r g b a font border" (a PostScript name, or "system"; the border
    /// width in points) under this key, restored when the document opens.
    /// The background is the annotation color, which PDFKit keeps.
    private static let textStyleKey = PDFAnnotationKey(rawValue: "/PaperplaneTextStyle")

    private static func stampTextStyle(of box: PDFAnnotation) {
        let size = box.font?.pointSize ?? textBoxFontSize
        let color = (box.fontColor ?? .black).usingColorSpace(.deviceRGB) ?? .black
        let values = [size, color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        let fontName = fontFamily(of: box) == nil ? "system" : (box.font?.fontName ?? "system")
        let style = values.map { String(format: "%.3f", $0) } + [fontName, String(format: "%.1f", box.border?.lineWidth ?? 0)]
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
        // Boxes stamped before borders existed have none.
        let borderWidth = tokens.count > 6 ? Double(tokens[6]).map { CGFloat($0) } ?? 0 : 0
        box.border = border(width: borderWidth)
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
    func handOverToOverlay(_ annotation: PDFAnnotation) {
        annotation.shouldDisplay = false
        hiddenNativeAnnotations[ObjectIdentifier(annotation)] = annotation
    }

    /// Drawings, shapes, text boxes, watermarks and headers on a page for the overlay to draw.
    func overlayDrawnAnnotations(on page: PDFPage) -> [PDFAnnotation] {
        prepareNotes(on: page)
        return page.annotations.filter {
            (Self.overlayDrawnTypes.contains($0.type ?? "") || MarkupEngine.isSquiggly($0) || $0 is PageMark)
                && hiddenNativeAnnotations[ObjectIdentifier($0)] != nil
                && $0 !== annotationBeingTyped
        }
    }

    /// Hands a page's note icons, drawings, shapes and text boxes over to the
    /// overlay. Annotations their author hid stay hidden. Idempotent per page.
    func prepareNotes(on page: PDFPage) {
        guard preparedNotePages.insert(ObjectIdentifier(page)).inserted else { return }
        remakePageMarks(on: page)
        for annotation in page.annotations {
            let type = annotation.type ?? ""
            if type != "FreeText" { Self.restoreOpacity(of: annotation) }
            // Text boxes from other apps keep PDFKit's rendering, which follows
            // their own appearance stream more faithfully than a redraw would.
            let drawable = type == "FreeText" ? Self.restoreTextStyle(of: annotation) : Self.overlayDrawnTypes.contains(type)
            // PDFKit draws squiggly markup as a straight line, or not at all.
            if (type == "Text" || drawable || MarkupEngine.isSquiggly(annotation)), annotation.shouldDisplay {
                handOverToOverlay(annotation)
            }
            if MarkupEngine.isMarkup(annotation), let text = annotation.contents, !text.isEmpty {
                storeNote(text, for: annotation)
            }
        }
    }

    /// Restores what `prepareNotes` changed so the saved file is standard, and
    /// leaves out an annotation still waiting for its text (a note being written
    /// in its popover), which is not part of the document yet.
    func withNativeNotesRestored<T>(_ body: () throws -> T) rethrows -> T {
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
        var pages: [PDFPage] {
            var seen = Set<ObjectIdentifier>()
            return (added + removed).compactMap { entry in
                let page = entry.1
                return seen.insert(ObjectIdentifier(page)).inserted ? page : nil
            }
        }

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
    func recordAnnotationEdit(_ actionName: String, pages: [PDFPage], _ body: () -> Void) {
        commit(captureAnnotationEdit(pages: pages, body), actionName: actionName)
    }

    private func commit(_ edit: AnnotationEdit, actionName: String) {
        guard !edit.isEmpty else { return }
        registerAnnotationUndo(edit, actionName: actionName)
        annotationsDidChange(on: edit.pages)
    }

    private func registerAnnotationUndo(_ edit: AnnotationEdit, actionName: String) {
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            edit.revert()
            // Registering the inverse while undoing makes it the redo step.
            target.registerAnnotationUndo(AnnotationEdit(added: edit.removed, removed: edit.added), actionName: actionName)
            target.annotationsDidChange(on: edit.pages)
        }
        undoManager.setActionName(actionName)
    }

    /// Every document edit, annotation or page, ends here: it counts the change
    /// for undo-aware "edited", refreshes views and schedules autosave.
    func annotationsDidChange(on pages: [PDFPage]? = nil) {
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
        // Deleted, cut or undone annotations leave the selection.
        if selectedAnnotations.contains(where: { $0.page == nil }) {
            selectedAnnotations.removeAll { $0.page == nil }
        }
        refreshPDFView(on: pages)
        scheduleAutosave()
    }

    /// A form field changed (see `FormFields.swift`). Every change, also PDFKit
    /// undoing one, counts as a new edit: its undo steps are not this app's, so
    /// a filled form is never taken for saved.
    func formFieldDidChange() {
        guard document != nil else { return }
        if changeCount < savedChangeCount { savedChangeCount = -1 }
        changeCount += 1
        hasUnsavedChanges = changeCount != savedChangeCount
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

    private func refreshPDFView(on pages: [PDFPage]? = nil) {
        guard let pdfView else { return }
        if let pages, !pages.isEmpty {
            for page in pages {
                let rect = pdfView.convert(page.bounds(for: .mediaBox), from: page).insetBy(dx: -8, dy: -8)
                pdfView.setNeedsDisplay(rect.intersection(pdfView.bounds))
            }
            (pdfView as? AnnotationOverlayHost)?.refreshAnnotationOverlays(on: pages)
        } else {
            pdfView.setNeedsDisplay(pdfView.bounds)
            (pdfView as? AnnotationOverlayHost)?.refreshAnnotationOverlays()
        }
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

    /// Narrows the annotation list; cleared when another file opens.
    @Published var annotationListFilter = AnnotationListFilter()

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
                guard let type = annotation.type,
                      let kind = ImageStamp.isImage(annotation) ? L("Image")
                        : Self.isRedactionMark(annotation) ? L("Redaction Mark")
                        : MarkupEngine.tool(of: annotation)?.title ?? Self.listedAnnotationKinds[type],
                      let listKind = AnnotationListKind.of(annotation),
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
                    listKind: listKind,
                    color: MarkupColor(nearest: displayColor(of: annotation).withAlphaComponent(1), among: MarkupColor.drawingCases),
                    author: annotation.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
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
        animatesSidebarReveal = true
        updateCurrentPage(document.index(for: page))
    }

    // MARK: - Export

    static let exportResolutions: [CGFloat] = [72, 150, 300]
    @Published var exportFlattensAnnotations = false
    /// Recompresses images in the exported copy; the open file is left alone.
    @Published var exportReducesFileSize = false
    @Published var textExportFormat: TextExportFormat = .plainText
    @Published var imageExportFormat: PageImageFormat = .png
    @Published var imageExportRange: ImageExportRange = .currentPage
    @Published var imageExportPages = ""
    @Published var imageExportResolution: CGFloat = 150
    /// Images written so far and in all, while an image export runs.
    @Published private(set) var exportProgress: (done: Int, total: Int)?
    /// Pages read so far while text is recognized; see `TextRecognitionSheet.swift`.
    @Published var recognitionProgress: (done: Int, total: Int)?
    /// The title of `PageProgressSheet`.
    @Published var progressTitle = ""
    var recognitionTask: Task<Void, Never>?
    /// A short result shown in the export row for a few seconds.
    @Published private(set) var exportStatus: String?
    private var exportTask: Task<Void, Never>?

    /// Writes a PDF copy, with annotations editable or flattened into the pages.
    func exportPDFCopy() {
        guard let document else { return }
        commitPendingEdits?()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let name = exportReducesFileSize ? L("%@ (Compressed)", displayName)
            : exportFlattensAnnotations ? L("%@ (Flattened)", displayName) : L("%@ (Copy)", displayName)
        panel.nameFieldStringValue = name + ".pdf"
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
                try DocumentExporter.writeCopy(of: document, to: url, flattenAnnotations: exportFlattensAnnotations,
                                               reducesFileSize: exportReducesFileSize, repairingButtons: buttonWidgetStates(in: document))
            }
            if exportReducesFileSize, let fileURL, let before = Self.fileSize(fileURL), let after = Self.fileSize(url) {
                let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
                showExportStatus(L("Exported “%@” (%@ → %@).", url.lastPathComponent, format(before), format(after)))
            } else {
                showExportStatus(L("Exported “%@”.", url.lastPathComponent))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Saves the document's text as plain text, rich text or Word.
    func exportText() {
        guard let document else { return }
        guard canCopy else {
            errorMessage = L("This document doesn’t allow copying its content, so its text can’t be exported.")
            return
        }
        commitPendingEdits?()
        let format = textExportFormat
        let data: Data
        do {
            data = try DocumentConverter.textData(of: document, format: format)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = displayName + "." + format.fileExtension
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            showExportStatus(L("Exported “%@”.", url.lastPathComponent))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renders the chosen pages to image files in the background. One page is
    /// saved under a chosen name; several go into a chosen folder.
    func exportImages() {
        guard let document, exportProgress == nil else { return }
        guard canCopy else {
            errorMessage = L("This document doesn’t allow copying its content, so its pages can’t be exported as images.")
            return
        }
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
    /// A copy for showing elsewhere (the slideshow): every annotation in
    /// standard form, so PDFKit draws them all, and unlocked.
    func displaySnapshot() -> PDFDocument? {
        commitPendingEdits?()
        return document.flatMap(exportSnapshot(of:))?.value
    }

    func exportSnapshot(of document: PDFDocument) -> UncheckedSendable<PDFDocument>? {
        guard let data = withNativeNotesRestored({ document.dataRepresentation() }),
              let copy = PDFDocument(data: data) else { return nil }
        if copy.isLocked {
            guard let documentPassword, copy.unlock(withPassword: documentPassword) else { return nil }
        }
        return UncheckedSendable(value: copy)
    }

    func showExportStatus(_ text: String) {
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

    /// Records how the opened file is protected. Restrictions show only without
    /// the permissions password, since with it PDFKit grants everything; a
    /// file that opens without a password is then checked again as a reader.
    private func noteProtection(of document: PDFDocument, wasLocked: Bool, at url: URL) {
        requiresOpenPassword = wasLocked
        var reader = document
        if document.isEncrypted, document.permissionsStatus == .owner, let fresh = PDFDocument(url: url),
           !fresh.isLocked || pendingReaderPassword.map({ fresh.unlock(withPassword: $0) }) == true {
            reader = fresh
        }
        pendingReaderPassword = nil
        let restricted = reader.isEncrypted && reader.permissionsStatus != .owner
            && !(reader.allowsPrinting && reader.allowsCopying && reader.allowsCommenting
                 && reader.allowsDocumentChanges && reader.allowsDocumentAssembly)
        readerRestrictions = restricted ? PDFPasswordSettings(
            restrictsPermissions: true,
            allowsPrinting: reader.allowsPrinting,
            allowsCopying: reader.allowsCopying,
            allowsCommenting: reader.allowsCommenting,
            allowsChanges: reader.allowsDocumentChanges && reader.allowsDocumentAssembly
        ) : nil
    }

    /// Unlocks the restrictions with the permissions password; false when it
    /// does not grant full access.
    func liftRestrictions(with password: String) -> Bool {
        guard let document, let fileURL else { return false }
        if document.unlock(withPassword: password), document.permissionsStatus == .owner {
            documentPassword = password
            objectWillChange.send()
            return true
        }
        // PDFKit may not raise an open document's access; check the password
        // on a fresh copy and reopen with it. Nothing is unsaved: edits were blocked.
        guard let fresh = PDFDocument(url: fileURL), fresh.unlock(withPassword: password), fresh.permissionsStatus == .owner else { return false }
        open(fileURL, confirmingUnsavedChanges: false, password: password)
        return self.document?.permissionsStatus == .owner
    }

    /// Writes the document with new passwords and restrictions, or with none,
    /// then reopens it with `password` so this window holds the file as written.
    func rewriteProtection(options: [PDFDocumentWriteOption: Any], reopeningWith password: String?, readerPassword: String? = nil) throws {
        commitPendingEdits?()
        guard let document, let fileURL, let fileRevision else { throw SafePDFFileStoreError.unreadablePDF }
        autosaveTask?.cancel()
        self.fileRevision = try withNativeNotesRestored {
            try SafePDFFileStore.save(document, to: fileURL, expectedRevision: fileRevision, writeOptions: options,
                                      repairingButtons: buttonWidgetStates())
        }
        savedChangeCount = changeCount
        hasUnsavedChanges = false
        pendingReaderPassword = readerPassword
        open(fileURL, confirmingUnsavedChanges: false, password: password)
    }

    private func writeDocument() throws {
        guard let document, let fileURL, let fileRevision else { throw SafePDFFileStoreError.unreadablePDF }
        // PDFKit leaves out annotation and page changes that the document's
        // restrictions forbid, so refuse rather than lose them silently.
        if changeCount != savedChangeCount, !canAnnotate || !canChangePages {
            throw DocumentProtectionError.restricted
        }
        autosaveTask?.cancel()
        self.fileRevision = try withNativeNotesRestored {
            try SafePDFFileStore.save(document, to: fileURL, expectedRevision: fileRevision, repairingButtons: buttonWidgetStates())
        }
        savedChangeCount = changeCount
        hasUnsavedChanges = false
    }
}

/// Hands a value to a background task that alone uses it from then on.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
