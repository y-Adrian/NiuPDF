import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderWindow: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var pageInput = "1"
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if library.isAnnotationBarVisible, library.document != nil {
                AnnotationToolBar()
                Divider()
            }
            if let document = library.document {
                HStack(spacing: 0) {
                    if library.isSidebarVisible {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                sidebarModeButton(.thumbnails, title: L("Thumbnails"), symbol: "square.grid.2x2")
                                sidebarModeButton(.outline, title: L("Outline"), symbol: "list.bullet.indent")
                                sidebarModeButton(.annotations, title: L("Annotations"), symbol: "highlighter")
                                if !library.searchResults.isEmpty {
                                    sidebarModeButton(.searchResults, title: L("Results"), symbol: "text.magnifyingglass")
                                }
                            }
                            .padding(8)
                            Divider()
                            switch library.sidebarMode {
                            case .thumbnails:
                                ThumbnailSidebar(
                                    document: document,
                                    revision: library.annotationRevision,
                                    selectedIndex: $library.currentPageIndex
                                ) { index in
                                    library.goToPage(index + 1)
                                }
                            case .outline:
                                PDFOutlineSidebar(document: document) { index in
                                    library.goToPage(index + 1)
                                }
                            case .annotations:
                                AnnotationListSidebar(
                                    items: library.annotationListItems(),
                                    onSelect: { library.reveal($0.annotation) },
                                    onDelete: { library.deleteAnnotation($0.annotation) }
                                )
                            case .searchResults:
                                SearchResultsSidebar(
                                    results: library.searchResults,
                                    document: document,
                                    selectedIndex: library.searchResultIndex
                                ) { index in
                                    library.selectSearchResult(index)
                                }
                            }
                        }
                        .frame(width: 220)
                        Divider()
                    }
                    PDFCanvas(document: document)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { statusBar }
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { library.restoreLastDocument() }
        .onChange(of: library.currentPageIndex) { value in pageInput = "\(value + 1)" }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .alert(L("Operation Failed"), isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button(L("OK"), role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { library.isSidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help(L("Show or hide the sidebar"))
            .disabled(library.document == nil)

            Button { library.presentOpenPanel() } label: {
                Label(L("Open"), systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider().frame(height: 22)

            Button { library.stepPage(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(library.document == nil || library.currentPageIndex <= 0)
                .help(L("Previous Page"))
            TextField(L("Page"), text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.center)
                .disabled(library.document == nil)
                .onSubmit { commitPageInput() }
            Text("/ \(library.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { library.stepPage(1) } label: { Image(systemName: "chevron.right") }
                .disabled(library.document == nil || library.currentPageIndex >= library.pageCount - 1)
                .help(L("Next Page"))

            Divider().frame(height: 22)

            Button { library.zoom(by: 0.85) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(library.document == nil)
                .help(L("Zoom Out"))
            Menu {
                Button(L("Fit Width")) { library.fitWidth() }
                Button(L("Fit Page")) { library.fitPage() }
                Divider()
                Button(L("Actual Size (100%)")) { library.setZoom(1) }
            } label: {
                Text("\(Int(library.zoomScale * 100))%")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)
            }
            .menuStyle(.borderlessButton)
            .disabled(library.document == nil)
            .help(L("Zoom Options"))
            Button { library.zoom(by: 1.18) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(library.document == nil)
                .help(L("Zoom In"))

            Picker(L("Page Layout"), selection: $library.layoutMode) {
                ForEach(ReaderLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help(L("Page Layout"))
            .disabled(library.document == nil)

            ModeTab(
                title: L("Annotate"),
                symbol: "pencil.tip.crop.circle",
                isActive: library.isAnnotationBarVisible
            ) {
                library.isAnnotationBarVisible.toggle()
            }
            .disabled(library.document == nil)
            .help(L("Show or hide the annotation tools"))

            Button { library.save() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(library.document == nil)
            .help(L("Save Annotations (⌘S)"))

            Spacer(minLength: 10)

            SearchField()
                .frame(width: 230)
                .disabled(library.document == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
            Text(library.displayName)
                .lineLimit(1)
            if library.hasUnsavedChanges {
                Text(L("· Edited"))
            }
            Spacer()
            Text("\(Int(library.zoomScale * 100))%")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func sidebarModeButton(_ mode: SidebarMode, title: String, symbol: String) -> some View {
        Button {
            library.sidebarMode = mode
        } label: {
            // Icon above the title so four tabs fit the 220 pt sidebar.
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(library.sidebarMode == mode ? Color.accentColor.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(library.sidebarMode == mode ? Color.accentColor : .secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("Open a PDF to Start Reading"))
                .font(.title3.weight(.medium))
            Text(L("Drag a PDF into the window, or choose one from your files."))
                .foregroundStyle(.secondary)
            Button { library.presentOpenPanel() } label: {
                Label(L("Choose PDF…"), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(24)
            }
        }
    }

    private func commitPageInput() {
        guard let page = Int(pageInput) else {
            pageInput = "\(library.currentPageIndex + 1)"
            return
        }
        library.goToPage(page)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in library.open(url) }
        }
        return true
    }
}

private struct SearchField: View {
    @EnvironmentObject private var library: ReaderLibrary
    @FocusState private var isFocused: Bool
    @State private var pendingSearch: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Find in Document"), text: $library.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    pendingSearch?.cancel()
                    library.find(library.searchText)
                }
                .onChange(of: library.searchText) { value in
                    pendingSearch?.cancel()
                    pendingSearch = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        library.find(value)
                    }
                }
                .onChange(of: library.focusSearch) { value in
                    if value { isFocused = true; library.focusSearch = false }
                }
                .onChange(of: isFocused) { focused in
                    if focused { library.focusSearch = false }
                }
            if !library.searchText.isEmpty {
                Button {
                    library.isSidebarVisible = true
                    library.sidebarMode = .searchResults
                } label: {
                    Text(library.searchResults.isEmpty ? L("No Results") : "\(library.searchResultIndex + 1)/\(library.searchResults.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(library.searchResults.isEmpty)
                Button { library.moveSearchResult(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(library.searchResults.isEmpty)
                Button { library.moveSearchResult(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(library.searchResults.isEmpty)
                Button {
                    library.searchText = ""
                    library.find("")
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
            searchOptionButton("Aa", label: L("Match Case"), isActive: library.isCaseSensitiveSearch) {
                library.isCaseSensitiveSearch.toggle()
                library.find(library.searchText)
            }
            searchOptionButton("ab", label: L("Whole Words"), isActive: library.isWholeWordSearch, usesWordBracket: true) {
                library.isWholeWordSearch.toggle()
                library.find(library.searchText)
            }
            searchOptionButton(".*", label: L("Regular Expression"), isActive: library.isRegularExpressionSearch) {
                library.isRegularExpressionSearch.toggle()
                library.find(library.searchText)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }

    private func searchOptionButton(
        _ title: String,
        label: String,
        isActive: Bool,
        usesWordBracket: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if usesWordBracket {
                    VStack(spacing: -3) {
                        Text(title)
                        WholeWordBracket()
                            .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                            .frame(width: 17, height: 5)
                    }
                } else {
                    Text(title)
                }
            }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? L("On") : L("Off"))
        .help(L("%@: %@", label, isActive ? L("On") : L("Off")))
    }
}

private struct WholeWordBracket: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 1
        var path = Path()
        path.move(to: CGPoint(x: inset, y: rect.minY))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        return path
    }
}

/// A toolbar tab that expands a row of tools below the toolbar.
private struct ModeTab: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isActive ? L("On") : L("Off"))
    }
}

/// The expanded annotation tools: text markup, drawing, text box, shapes and
/// notes, plus the color of the active tool. Choosing the active tool again
/// returns to plain selection; so does Esc.
private struct AnnotationToolBar: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var lastShape: AnnotationTool = .rectangle

    var body: some View {
        HStack(spacing: 18) {
            group([.highlight, .underline, .strikeOut])
            group([.ink, .textBox])
            HStack(spacing: 2) {
                shapeMenu
                toolButton(.note)
            }
            Spacer(minLength: 0)
            colorMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func group(_ tools: [AnnotationTool]) -> some View {
        HStack(spacing: 2) {
            ForEach(tools) { toolButton($0) }
        }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button { toggle(tool) } label: {
            toolLabel(symbol: tool.symbol, isActive: library.activeTool == tool)
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityValue(library.activeTool == tool ? L("On") : L("Off"))
    }

    /// The current shape as a normal tool button (so it can show the active
    /// state, which a menu button cannot), with a small menu to switch shapes.
    private var shapeMenu: some View {
        let current = library.activeTool.isShape ? library.activeTool : lastShape
        return HStack(spacing: 0) {
            toolButton(current)
            Menu {
                ForEach(AnnotationTool.shapes) { shape in
                    Button { pick(shape) } label: { Label(shape.title, systemImage: shape.symbol) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Shapes"))
            .accessibilityLabel(L("Shapes"))
        }
    }

    @ViewBuilder
    private var colorMenu: some View {
        let tool = library.activeTool
        if tool != .select && tool != .note {
            let current = library.color(for: tool)
            Menu {
                ForEach(tool.colorChoices) { color in
                    Button { library.setColor(color, for: tool) } label: {
                        Label { Text(color.title) } icon: { Image(nsImage: swatchImage(color.nsColor)) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(nsImage: swatchImage(current.nsColor))
                    Text(current.title)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Color"))
        }
    }

    private func toolLabel(symbol: String, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .frame(width: 30, height: 26)
            .background(isActive ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .contentShape(Rectangle())
    }

    private func toggle(_ tool: AnnotationTool) {
        library.activeTool = library.activeTool == tool ? .select : tool
    }

    private func pick(_ shape: AnnotationTool) {
        lastShape = shape
        library.activeTool = shape
    }

    /// A filled circle that menus show in color rather than as a template.
    private func swatchImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
