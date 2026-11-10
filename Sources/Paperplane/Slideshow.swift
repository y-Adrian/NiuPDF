import AppKit
import PDFKit

/// Full-screen presentation of the document, one page at a time on black.
/// It shows a snapshot taken when it starts, drawn at screen resolution,
/// so drawings and notes look as they do in an export.
@MainActor
final class Slideshow {
    private static var current: Slideshow?

    private let view: SlideView
    private weak var library: ReaderLibrary?

    /// Starts at the library's current page on its window's screen.
    static func start(for library: ReaderLibrary) {
        guard current == nil, let snapshot = library.displaySnapshot(), snapshot.pageCount > 0 else { return }
        let show = Slideshow(document: snapshot, page: library.currentPageIndex, library: library)
        current = show
        show.present(on: library.window?.screen ?? NSScreen.main)
    }

    static var isRunning: Bool { current != nil }

    private init(document: PDFDocument, page: Int, library: ReaderLibrary) {
        self.library = library
        view = SlideView(document: document, page: min(max(page, 0), document.pageCount - 1))
        view.onExit = { [weak self] in self?.finish() }
    }

    private func present(on screen: NSScreen?) {
        guard let screen else { return }
        let options: [NSView.FullScreenModeOptionKey: Any] = [
            .fullScreenModeAllScreens: false,
            .fullScreenModeApplicationPresentationOptions: NSApplication.PresentationOptions([.hideDock, .hideMenuBar]).rawValue
        ]
        view.enterFullScreenMode(screen, withOptions: options)
        view.window?.makeFirstResponder(view)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func finish() {
        view.exitFullScreenMode(options: nil)
        // The reader follows to the page the slideshow ended on.
        library?.goToPage(view.pageIndex + 1)
        library?.window?.makeKeyAndOrderFront(nil)
        Self.current = nil
    }
}

final class SlideView: NSView {
    private let document: PDFDocument
    private(set) var pageIndex: Int
    var onExit: (() -> Void)?
    private var indicatorTimer: Timer?
    private var showsIndicator = false

    init(document: PDFDocument, page: Int) {
        self.document = document
        pageIndex = page
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func show(page index: Int) {
        let clamped = min(max(index, 0), document.pageCount - 1)
        guard clamped != pageIndex else { return NSSound.beep() }
        pageIndex = clamped
        updateAccessibility()
        flashIndicator()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel(L("Page %ld of %ld", pageIndex + 1, document.pageCount))
    }

    private func flashIndicator() {
        showsIndicator = true
        indicatorTimer?.invalidate()
        indicatorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showsIndicator = false
                self?.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let page = document.page(at: pageIndex), let context = NSGraphicsContext.current?.cgContext else { return }
        // The page as shown: its crop box, turned by its rotation.
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = min(bounds.width / turned.width, bounds.height / turned.height)
        let size = CGSize(width: turned.width * scale, height: turned.height * scale)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: turned).fill()
        // `draw(with:to:)` applies the rotation and the crop box itself.
        page.draw(with: .cropBox, to: context)
        PageMark.drawShown(on: page, for: .cropBox, in: context)
        context.restoreGState()

        if showsIndicator {
            let text = "\(pageIndex + 1) / \(document.pageCount)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            let pill = CGRect(x: bounds.midX - textSize.width / 2 - 12, y: 24, width: textSize.width + 24, height: textSize.height + 10)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 5), withAttributes: attributes)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onExit?()                              // Esc
        case 124, 125, 49, 36, 76, 121: show(page: pageIndex + 1)  // → ↓ Space Return Enter PageDown
        case 123, 126, 51, 116: show(page: pageIndex - 1)          // ← ↑ Delete PageUp
        case 115: show(page: 0)                         // Home
        case 119: show(page: document.pageCount - 1)    // End
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        show(page: pageIndex + 1)
    }

    override func rightMouseDown(with event: NSEvent) {
        show(page: pageIndex - 1)
    }

    /// ⌘. and the Esc key of the menu: leave the slideshow.
    override func cancelOperation(_ sender: Any?) {
        onExit?()
    }
}
