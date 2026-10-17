import AppKit
import PDFKit
import SwiftUI

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
    @Published var focusSearch = false
    @Published var isSidebarVisible = true
    @Published var errorMessage: String?

    weak var pdfView: PDFView?
    private var scopedURL: URL?

    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "未打开文稿" }

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
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        guard let pdf = PDFDocument(url: url) else {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            errorMessage = "无法打开这个 PDF 文件。请确认文件未损坏，或尝试其他文件。"
            return
        }

        if didStartAccess { scopedURL = url }
        document = pdf
        fileURL = url
        pageCount = pdf.pageCount
        currentPageIndex = 0
        searchText = ""
        searchResults = []
        searchResultIndex = 0
        errorMessage = nil
        if let firstPage = pdf.page(at: 0) { pdfView?.go(to: firstPage) }
    }

    func goToPage(_ oneBasedPage: Int) {
        guard let document, document.pageCount > 0 else { return }
        let index = min(max(oneBasedPage - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        pdfView?.go(to: page)
        currentPageIndex = index
    }

    func stepPage(_ delta: Int) {
        goToPage(currentPageIndex + delta + 1)
    }

    func zoom(by factor: CGFloat) {
        guard let pdfView else { return }
        pdfView.scaleFactor = min(max(pdfView.scaleFactor * factor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        zoomScale = pdfView.scaleFactor
    }

    func setZoom(_ scale: CGFloat) {
        guard let pdfView else { return }
        pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        zoomScale = pdfView.scaleFactor
    }

    func find(_ text: String) {
        searchText = text
        guard let document, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            searchResultIndex = 0
            pdfView?.highlightedSelections = nil
            return
        }
        searchResults = document.findString(text, withOptions: [.caseInsensitive])
        searchResultIndex = 0
        pdfView?.highlightedSelections = searchResults
        showCurrentSearchResult()
    }

    func moveSearchResult(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchResultIndex = (searchResultIndex + delta + searchResults.count) % searchResults.count
        showCurrentSearchResult()
    }

    private func showCurrentSearchResult() {
        guard searchResults.indices.contains(searchResultIndex), let pdfView else { return }
        pdfView.setCurrentSelection(searchResults[searchResultIndex], animate: true)
        pdfView.go(to: searchResults[searchResultIndex])
    }

    func highlightSelection() {
        guard let selection = pdfView?.currentSelection else { return }
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.42)
            annotation.contents = "高亮"
            page.addAnnotation(annotation)
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
    }

    func save() {
        guard let document, let fileURL else { return }
        guard document.write(to: fileURL) else {
            errorMessage = "无法保存到原文件。请检查文件权限，或将 PDF 另存到其他位置。"
            return
        }
    }
}
