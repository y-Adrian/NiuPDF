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
    case searchResults
}

enum MarkupColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .pink: "粉色"
        case .purple: "紫色"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(calibratedRed: 1, green: 0.82, blue: 0.16, alpha: 1)
        case .green: NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.42, alpha: 1)
        case .blue: NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.96, alpha: 1)
        case .pink: NSColor(calibratedRed: 0.96, green: 0.38, blue: 0.58, alpha: 1)
        case .purple: NSColor(calibratedRed: 0.64, green: 0.40, blue: 0.88, alpha: 1)
        }
    }
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
    @Published var selectedMarkupColor: MarkupColor = .yellow
    @Published var focusSearch = false
    @Published var isSidebarVisible = true
    @Published var sidebarMode: SidebarMode = .thumbnails
    @Published var errorMessage: String?
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
            errorMessage = "无法恢复最近打开的 PDF。请重新选择文件。\n\(error.localizedDescription)"
        }
    }

    func presentOpenPanel() {
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

    func open(_ url: URL) {
        open(url, restoringLastDocument: false)
    }

    private func open(_ url: URL, restoringLastDocument: Bool) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        let opened: (document: PDFDocument, revision: PDFFileRevision)
        do {
            opened = try SafePDFFileStore.read(from: url)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            return
        }

        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        if didStartAccess { scopedURL = url }
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
            return
        }
        searchResults = document.findString(query, withOptions: options)
        searchResultIndex = 0
        pdfView?.highlightedSelections = searchResults
        showCurrentSearchResult()
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
        addTextMarkup(type: .highlight, color: selectedMarkupColor.nsColor.withAlphaComponent(0.42))
    }

    func underlineSelection() {
        addTextMarkup(type: .underline, color: selectedMarkupColor.nsColor)
    }

    func strikeOutSelection() {
        addTextMarkup(type: .strikeOut, color: selectedMarkupColor.nsColor)
    }

    private func addTextMarkup(type: PDFAnnotationSubtype, color: NSColor) {
        guard let selection = pdfView?.currentSelection else { return }
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
            annotation.color = color
            page.addAnnotation(annotation)
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
    }

    func save() {
        guard let document, let fileURL, let fileRevision else { return }
        do {
            self.fileRevision = try SafePDFFileStore.save(
                document,
                to: fileURL,
                expectedRevision: fileRevision
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
