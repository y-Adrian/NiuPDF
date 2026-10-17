import AppKit
import PDFKit
import PaperplaneCore
import SwiftUI

/// Renders a compact speech bubble while keeping the PDF's standard `/Text`
/// annotation type so other readers can still inspect and edit its contents.
final class CommentBubblePDFAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let rect = bounds.standardized
        guard rect.width > 6, rect.height > 6 else { return }

        // Build the bubble and its tail as one path so the outline has no seam.
        // Core Graphics keeps these as vector curves in PDF appearance streams.
        let minX = rect.minX + rect.width * 0.06
        let maxX = rect.maxX - rect.width * 0.06
        let minY = rect.minY + rect.height * 0.22
        let maxY = rect.maxY - rect.height * 0.06
        let radius = min(rect.width, rect.height) * 0.18
        let tailTip = CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.04)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + radius, y: maxY))
        path.addLine(to: CGPoint(x: maxX - radius, y: maxY))
        path.addCurve(to: CGPoint(x: maxX, y: maxY - radius), control1: CGPoint(x: maxX - radius * 0.45, y: maxY), control2: CGPoint(x: maxX, y: maxY - radius * 0.45))
        path.addLine(to: CGPoint(x: maxX, y: minY + radius))
        path.addCurve(to: CGPoint(x: maxX - radius, y: minY), control1: CGPoint(x: maxX, y: minY + radius * 0.45), control2: CGPoint(x: maxX - radius * 0.45, y: minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.55, y: minY))
        path.addLine(to: tailTip)
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.27, y: minY))
        path.addLine(to: CGPoint(x: minX + radius, y: minY))
        path.addCurve(to: CGPoint(x: minX, y: minY + radius), control1: CGPoint(x: minX + radius * 0.45, y: minY), control2: CGPoint(x: minX, y: minY + radius * 0.45))
        path.addLine(to: CGPoint(x: minX, y: maxY - radius))
        path.addCurve(to: CGPoint(x: minX + radius, y: maxY), control1: CGPoint(x: minX, y: maxY - radius * 0.45), control2: CGPoint(x: minX + radius * 0.45, y: maxY))
        path.closeSubpath()

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(NSColor(calibratedRed: 1, green: 0.88, blue: 0.48, alpha: 1).cgColor)
        context.setStrokeColor(NSColor(calibratedRed: 0.56, green: 0.38, blue: 0.08, alpha: 1).cgColor)
        context.setLineWidth(0.9)
        context.setLineJoin(.round)
        context.addPath(path)
        context.drawPath(using: .fillStroke)

        let dotRadius: CGFloat = 0.65
        let centerY = rect.minY + rect.height * 0.59
        for fraction in [CGFloat(0.30), 0.50, 0.70] {
            let dot = CGRect(
                x: rect.minX + rect.width * fraction - dotRadius,
                y: centerY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            context.setFillColor(NSColor(calibratedRed: 0.42, green: 0.32, blue: 0.12, alpha: 1).cgColor)
            context.fillEllipse(in: dot)
        }
        context.restoreGState()
    }
}

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

    func strikeOutSelection() {
        applyStrikeOut(color: selectedStrikeOutColor)
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

    func toggleNoteAnnotation() {
        guard let selection = selectedText else { return }
        if hasAnnotation(ofType: .text, in: selection) {
            removeAnnotations(ofType: .text, in: selection)
        } else {
            for page in selection.pages {
                let selectionBounds = selection.bounds(for: page)
                guard !selectionBounds.isNull, !selectionBounds.isEmpty else { continue }
                let noteBounds = commentIconBounds(for: selectionBounds, on: page)
                let note = CommentBubblePDFAnnotation(bounds: noteBounds, forType: .text, withProperties: nil)
                note.iconType = .comment
                note.color = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.35, alpha: 1)
                note.contents = ""
                page.addAnnotation(note)
            }
        }
        refreshPDFView()
    }

    private func commentIconBounds(for selectionBounds: CGRect, on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let size: CGFloat = 18
        let inset: CGFloat = 3
        let gap: CGFloat = 3
        let left = selectionBounds.minX - size - gap
        let right = selectionBounds.maxX + gap
        let minX = pageBounds.minX + inset
        let maxX = pageBounds.maxX - size - inset
        let x: CGFloat
        if left >= minX {
            x = left
        } else if right <= maxX {
            x = right
        } else {
            x = min(max(selectionBounds.minX, minX), maxX)
        }
        let minY = pageBounds.minY + inset
        let maxY = pageBounds.maxY - size - inset
        let y = min(max(selectionBounds.maxY - size, minY), maxY)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    func hasNoteAnnotationForSelection() -> Bool {
        guard let selection = selectedText else { return false }
        return hasAnnotation(ofType: .text, in: selection)
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
        let existing = annotations(ofType: type, in: selection)
        if !existing.isEmpty {
            removeAnnotations(ofType: type, in: selection)
            if existing.allSatisfy({ colorsMatch($0.color, color) }) {
                pdfView?.clearSelection()
                refreshPDFView()
                return
            }
        }
        addTextMarkup(type: type, color: color, selection: selection)
        pdfView?.clearSelection()
        refreshPDFView()
    }

    private func replaceTextMarkup(type: PDFAnnotationSubtype, color: NSColor, selection: PDFSelection) {
        removeMatchingAnnotations(ofType: type, in: selection)
        addTextMarkup(type: type, color: color, selection: selection)
        pdfView?.clearSelection()
        refreshPDFView()
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
