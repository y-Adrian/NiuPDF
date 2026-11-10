import AppKit
import PDFKit
import UniformTypeIdentifiers

/// An image placed on a page. PDFKit writes what `draw` paints into the
/// annotation's appearance, so the file shows the image in any reader. After
/// reopening it is a plain stamp drawn from that appearance: it moves and
/// resizes, but only this class can be copied, since a copy made from the
/// annotation's dictionary would have no appearance.
final class ImageStamp: PDFAnnotation {
    /// Marks images placed by this app, for the annotation list.
    static let markerKey = PDFAnnotationKey(rawValue: "/PaperplaneImage")

    private(set) var image: NSImage

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        setValue("1", forAnnotationKey: Self.markerKey)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `PDFPage.copy()` copies annotations with this; PDFKit's own copy would
    /// leave `image` unset, and the copied page would show an empty stamp.
    override func copy(with zone: NSZone? = nil) -> Any { duplicate() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.setAlpha(color.alphaComponent > 0 ? color.alphaComponent : 1)
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }

    static func isImage(_ annotation: PDFAnnotation) -> Bool {
        annotation is ImageStamp || annotation.value(forAnnotationKey: markerKey) != nil
    }

    /// A new image annotation with the same image and place.
    func duplicate() -> ImageStamp {
        let copy = ImageStamp(image: image, bounds: bounds)
        copy.color = color
        copy.userName = userName
        return copy
    }
}

/// Where a link goes.
enum LinkTarget: Equatable {
    case web(URL)
    case page(Int)

    init?(_ annotation: PDFAnnotation) {
        if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
            self = .web(url)
        } else if let page = (annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination)?.page,
                  let document = page.document {
            self = .page(document.index(for: page))
        } else {
            return nil
        }
    }
}

/// Inserting images and links.
extension ReaderLibrary {
    // MARK: Images

    /// Asks for an image file and places it on the current page.
    func presentInsertImagePanel() {
        guard canAnnotate else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Insert")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0 else {
            errorMessage = L("“%@” couldn’t be read as an image.", url.lastPathComponent)
            return
        }
        insertImage(image, actionName: L("Insert Image"))
    }

    /// Places an image in the middle of the visible part of the current page,
    /// at most `maximumWidth` of the page wide, and selects it.
    @discardableResult
    func insertImage(_ image: NSImage, actionName: String, maximumWidth: CGFloat = 0.4) -> PDFAnnotation? {
        guard canAnnotate, let document, let page = pdfView?.currentPage ?? document.page(at: currentPageIndex) else { return nil }
        let pageBox = page.bounds(for: .cropBox)
        var size = image.size
        let limit = CGSize(width: pageBox.width * maximumWidth, height: pageBox.height * 0.5)
        let scale = min(1, limit.width / size.width, limit.height / size.height)
        size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        var center = CGPoint(x: pageBox.midX, y: pageBox.midY)
        if let pdfView, pdfView.currentPage === page {
            let visible = pdfView.convert(pdfView.bounds, to: page).intersection(pageBox)
            if !visible.isEmpty { center = CGPoint(x: visible.midX, y: visible.midY) }
        }
        let stamp = ImageStamp(image: image, bounds: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                                             width: size.width, height: size.height))
        recordAnnotationEdit(actionName, pages: [page]) { page.addAnnotation(stamp) }
        select(stamp, extending: false)
        return stamp
    }

    // MARK: Links

    /// Annotations ▸ Add Link: asks where the selected text should link to.
    func addLinkToSelection() {
        guard canAnnotate else { return }
        guard let selection = pdfView?.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("Select the text to link first.")
            return
        }
        guard let target = askForLinkTarget() else { return }
        addLink(over: selection, to: target)
    }

    /// Links over each line of the selection, to a web address or a page.
    func addLink(over selection: PDFSelection, to target: LinkTarget) {
        guard canAnnotate else { return }
        let lines = selection.selectionsByLine().flatMap { line in
            line.pages.map { page in (page, line.bounds(for: page)) }
        }.filter { !$0.1.isEmpty }
        guard !lines.isEmpty else { return }
        let pages = Array(Set(lines.map { ObjectIdentifier($0.0) })).compactMap { id in lines.first { ObjectIdentifier($0.0) == id }?.0 }
        recordAnnotationEdit(L("Add Link"), pages: pages) {
            for (page, bounds) in lines {
                page.addAnnotation(Self.makeLink(bounds: bounds, to: target, in: document))
            }
        }
        pdfView?.clearSelection()
    }

    func changeLink(_ link: PDFAnnotation, to target: LinkTarget) {
        guard canAnnotate, let page = link.page else { return }
        recordAnnotationEdit(L("Edit Link"), pages: [page]) {
            page.removeAnnotation(link)
            page.addAnnotation(Self.makeLink(bounds: link.bounds, to: target, in: document))
        }
    }

    func removeLink(_ link: PDFAnnotation) {
        guard canAnnotate, let page = link.page else { return }
        recordAnnotationEdit(L("Remove Link"), pages: [page]) { page.removeAnnotation(link) }
    }

    private static func makeLink(bounds: CGRect, to target: LinkTarget, in document: PDFDocument?) -> PDFAnnotation {
        let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        // No visible border, as links in most documents.
        let border = PDFBorder()
        border.lineWidth = 0
        link.border = border
        switch target {
        case .web(let url):
            link.url = url
        case .page(let index):
            if let page = document?.page(at: index) {
                link.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
            }
        }
        return link
    }

    /// Asks for a link's web address; nil when the user cancels. Links to a
    /// page of this document are not offered: PDFKit writes a new link's page
    /// as a placeholder name instead of a reference to the page, in any
    /// document opened from a file, so the link would go nowhere once saved.
    func askForLinkTarget(current: LinkTarget? = nil) -> LinkTarget? {
        let alert = NSAlert()
        alert.messageText = current == nil ? L("Add Link") : L("Edit Link")
        alert.informativeText = L("Enter a web address or an email address.")
        alert.addButton(withTitle: current == nil ? L("Add") : L("Change"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://example.com"
        switch current {
        case .web(let url): field.stringValue = url.absoluteString
        case .page, nil: break
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if let target = Self.linkTarget(from: field.stringValue, pageCount: pageCount) { return target }
            alert.informativeText = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) != nil
                ? L("Links to pages of this document aren’t available yet: they would lose their page when saved. Enter a web address instead.")
                : L("Enter a web address such as example.com, or an email address such as mailto:name@example.com.")
        }
    }

    /// A web or mail address; a bare host gets https. Page numbers are not
    /// accepted (see `askForLinkTarget`).
    static func linkTarget(from text: String, pageCount: Int) -> LinkTarget? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Int(text) == nil else { return nil }
        let candidate = text.contains("://") || text.hasPrefix("mailto:") ? text : "https://" + text
        guard let url = URL(string: candidate), let scheme = url.scheme,
              scheme == "mailto" || (url.host?.contains(".") ?? false) else { return nil }
        return .web(url)
    }

    /// The link under a point of the page view, if any.
    func link(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.last { $0.type == "Link" && $0.bounds.contains(point) }
    }
}
