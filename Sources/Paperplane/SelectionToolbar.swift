import AppKit
import PDFKit

/// A floating row of actions above text selected with the select tool: a
/// note, Copy, Translate and Read Aloud, then the markup tools and colors, as
/// in the context menu but one click away. What a restricted file forbids is
/// left out. It is a borderless child panel that never takes focus, so
/// the PDF view keeps the selection and the keyboard.
@MainActor
final class SelectionToolbar: NSObject {
    /// Defaults key for the setting that turns the toolbar off.
    static let enabledKey = "showsSelectionToolbar"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private weak var view: PDFView?
    private weak var library: ReaderLibrary?
    private let panel: NSPanel
    private let stack = NSStackView()
    private var selection: PDFSelection?
    private var toolButtons: [MarkupToolIconButton] = []
    private var swatches: [MarkupColorSwatchButton] = []
    private var noteButton: NSButton?
    private var copyButton: NSButton?
    private var translateButton: NSButton?
    private var readButton: NSButton?
    private var observers: [NSObjectProtocol] = []

    private static let tools = AnnotationTool.markupTools

    init(view: PDFView, library: ReaderLibrary?) {
        self.view = view
        self.library = library
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        // A light card like the annotation editor, also in dark mode.
        panel.appearance = NSAppearance(named: .aqua)

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
        buildRow()
    }

    var isVisible: Bool { panel.isVisible }

    /// Note and Copy first, then the markup tools, then their colors.
    private func buildRow() {
        let note = symbolButton("text.bubble", title: L("Add Note"), action: #selector(addNote))
        let copy = symbolButton("doc.on.doc", title: L("Copy"), action: #selector(copyText))
        let translate = symbolButton("translate", title: L("Translate"), action: #selector(translate))
        let read = symbolButton("speaker.wave.2", title: L("Read Aloud"), action: #selector(readAloud))
        for button in [note, copy, translate, read] { stack.addArrangedSubview(button) }
        stack.setCustomSpacing(8, after: read)
        noteButton = note
        copyButton = copy
        translateButton = translate
        readButton = read

        toolButtons = Self.tools.map { tool in
            let button = MarkupToolIconButton(tool: tool, selected: false, target: self, action: #selector(pickTool(_:)))
            button.toolTip = tool.title
            button.setAccessibilityLabel(tool.title)
            return button
        }
        toolButtons.forEach(stack.addArrangedSubview)
        if let last = toolButtons.last { stack.setCustomSpacing(8, after: last) }

        swatches = MarkupColor.allCases.enumerated().map { index, color in
            let button = MarkupColorSwatchButton(selected: false, target: self, action: #selector(pickColor(_:)))
            button.tag = index
            button.contentTintColor = color.nsColor
            button.toolTip = color.title
            button.setAccessibilityLabel(color.title)
            return button
        }
        swatches.forEach(stack.addArrangedSubview)
    }


    private func symbolButton(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: Showing

    /// Shows the row for `selection`, above its first line or, without room
    /// there, below its last line.
    func show(for selection: PDFSelection) {
        guard Self.isEnabled, let view, let window = view.window else { return }
        self.selection = selection
        let tool = library?.lastMarkupTool ?? .highlight
        for button in toolButtons { button.setSelectedTool(button.tool == tool) }
        let color = library?.color(for: tool) ?? .yellow
        for (index, swatch) in swatches.enumerated() { swatch.setSelectedColor(MarkupColor.allCases[index] == color) }
        let canAnnotate = library?.canAnnotate ?? false
        let canCopy = library?.canCopy ?? false
        noteButton?.isHidden = !canAnnotate
        for button in toolButtons { button.isHidden = !canAnnotate }
        for swatch in swatches { swatch.isHidden = !canAnnotate }
        copyButton?.isHidden = !canCopy
        // Translating hands the text on, as copying does.
        translateButton?.isHidden = !canCopy || !SelectionTranslator.isAvailable
        let speaking = SpeechReader.shared.isSpeaking
        readButton?.image = NSImage(systemSymbolName: speaking ? "stop.circle" : "speaker.wave.2",
                                    accessibilityDescription: speaking ? L("Stop Reading") : L("Read Aloud"))
        readButton?.toolTip = speaking ? L("Stop Reading") : L("Read Aloud")
        readButton?.setAccessibilityLabel(readButton?.toolTip)
        guard place() else { return hide() }
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        observe(view, window: window)
    }

    func hide() {
        selection = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Positions the panel for the current selection; false when the
    /// selection is scrolled out of sight.
    @discardableResult
    private func place() -> Bool {
        guard let view, let window = view.window, let selection else { return false }
        let lines = selection.selectionsByLine()
        func viewRect(_ line: PDFSelection) -> CGRect? {
            guard let page = line.pages.first else { return nil }
            return view.convert(line.bounds(for: page), from: page)
        }
        let rects = lines.compactMap(viewRect)
        guard let first = rects.max(by: { $0.maxY < $1.maxY }),
              let last = rects.min(by: { $0.minY < $1.minY }) else { return false }
        // The PDF view is its own viewport; its visibleRect can be larger.
        let visible = view.bounds
        guard rects.contains(where: { $0.intersects(visible) }) else { return false }

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let gap: CGFloat = 8
        // PDFView is not flipped: larger y is higher on screen.
        var anchor = CGPoint(x: first.midX, y: first.maxY + gap)
        if anchor.y + size.height > visible.maxY {
            anchor = CGPoint(x: last.midX, y: last.minY - gap - size.height)
        }
        var frame = CGRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visible.minX + 6), visible.maxX - size.width - 6)
        frame.origin.y = min(max(frame.minY, visible.minY + 6), visible.maxY - size.height - 6)
        let screenFrame = window.convertToScreen(view.convert(frame, to: nil))
        panel.setFrame(screenFrame, display: true)
        return true
    }

    /// Follows scrolling and zooming; leaves when the selection or the window changes.
    private func observe(_ view: PDFView, window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let follow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if !self.place() { self.hide() }
            }
        }
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: follow))
        }
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main, using: follow))
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: follow))
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let view = self.view else { return }
                let text = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty || text != self.selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) { self.hide() }
            }
        })
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
        }
    }

    // MARK: Actions

    /// Marks the selection with the tool in its current color, or removes that
    /// markup when it is already there, like the context menu's tools.
    @objc private func pickTool(_ sender: MarkupToolIconButton) {
        guard let selection, let library else { return }
        hide()
        library.toggleMarkup(sender.tool, in: selection)
    }

    /// Marks the selection in the color with the tool used last.
    @objc private func pickColor(_ sender: NSButton) {
        guard MarkupColor.allCases.indices.contains(sender.tag), let selection, let library else { return }
        let color = MarkupColor.allCases[sender.tag]
        hide()
        library.applyMarkup(library.lastMarkupTool, color: color, to: selection)
    }

    @objc private func addNote() {
        guard let selection, let library else { return }
        hide()
        library.addNote(in: selection)
    }

    /// The system translation popover under the selected text.
    @objc private func translate() {
        guard let view, let selection, let text = selection.string else { return }
        hide()
        let rects = selection.selectionsByLine().compactMap { line in
            line.pages.first.map { view.convert(line.bounds(for: $0), from: $0) }
        }
        guard let first = rects.first else { return }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        SelectionTranslator.show(text, below: bounds.intersection(view.bounds), in: view)
    }

    /// Reads the selection aloud, or stops the voice that is reading.
    @objc private func readAloud() {
        guard let text = selection?.string else { return }
        hide()
        if SpeechReader.shared.isSpeaking {
            SpeechReader.shared.stop()
        } else {
            SpeechReader.shared.speak(text)
        }
    }

    /// Copies the selected text and keeps it selected.
    @objc private func copyText() {
        guard let view else { return }
        hide()
        view.copy(nil)
    }
}
