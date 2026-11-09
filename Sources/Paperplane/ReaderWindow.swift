import PDFKit
import PaperplaneCore
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
            if library.expandedMode == .export, library.document != nil {
                ExportBar()
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
        // Opening publishes many properties; doing it during the appearance
        // update is "publishing changes from within view updates".
        .onAppear { DispatchQueue.main.async { library.restoreLastDocument() } }
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

            ModeTab(
                title: L("Export"),
                symbol: "square.and.arrow.up",
                isActive: library.expandedMode == .export
            ) {
                library.expandedMode = library.expandedMode == .export ? nil : .export
            }
            .disabled(library.document == nil)
            .help(L("Show or hide the export options"))

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
            if case let .paused(reason) = library.autosaveState {
                Text(L("· Autosave Paused"))
                    .foregroundStyle(.orange)
                    .help(reason)
            } else if library.hasUnsavedChanges {
                Text(L("· Edited"))
            } else if library.autosaveState == .saved {
                Text(L("· Saved Automatically"))
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
            Spacer(minLength: 0)
            group([.highlight, .underline, .strikeOut])
            group([.ink, .textBox])
            HStack(spacing: 2) {
                shapeMenu
                toolButton(.note)
            }
            Divider().frame(height: 20)
            colorRow
            styleControls
            Spacer(minLength: 0)
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
            toolLabel(for: tool, isActive: library.activeTool == tool)
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

    /// The active tool's colors, one click away beside the tools. Tools without
    /// a color (selection, notes) show the highlight colors dimmed, so the row
    /// keeps its place.
    private var colorRow: some View {
        let tool = library.activeTool
        let hasColor = tool != .select && tool != .note
        let palette = hasColor ? tool.colorChoices : MarkupColor.allCases
        let current = library.color(for: hasColor ? tool : .highlight)
        return HStack(spacing: 6) {
            ForEach(palette) { color in
                Button { library.chooseColor(color, for: tool) } label: {
                    swatch(color, isSelected: hasColor && color == current)
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
                .accessibilityValue(hasColor && color == current ? L("Selected") : "")
            }
        }
        .disabled(!hasColor)
        .opacity(hasColor ? 1 : 0.35)
    }

    /// Line width for drawings and shapes; font and size for text boxes.
    @ViewBuilder
    private var styleControls: some View {
        let tool = library.activeTool
        if tool == .ink || tool.isShape {
            Divider().frame(height: 20)
            HStack(spacing: 2) {
                ForEach(ReaderLibrary.strokeWidths, id: \.self) { width in
                    Button { library.chooseStrokeWidth(width) } label: {
                        toolLabel(isActive: library.strokeWidth == width) {
                            Capsule()
                                .fill(Color.primary)
                                .frame(width: 18, height: width)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("%ld pt", Int(width)))
                    .accessibilityLabel(L("Line Width") + " " + L("%ld pt", Int(width)))
                }
            }
        } else if tool == .textBox {
            Divider().frame(height: 20)
            HStack(spacing: 8) {
                FontFamilyMenu(family: library.textFontFamily) { family in
                    library.chooseTextFont(family: family, size: library.textFontSize)
                }
                Menu {
                    ForEach(ReaderLibrary.fontSizes, id: \.self) { size in
                        Button(L("%ld pt", Int(size))) { library.chooseTextFont(family: library.textFontFamily, size: size) }
                    }
                } label: {
                    Text(L("%ld pt", Int(library.textFontSize)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Font Size"))
            }
        }
    }

    private func swatch(_ color: MarkupColor, isSelected: Bool) -> some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            // An outline in the label color keeps black visible on a dark bar.
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.75))
            .frame(width: 16, height: 16)
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Circle())
    }

    private func toolLabel(symbol: String, isActive: Bool) -> some View {
        toolLabel(isActive: isActive) { Image(systemName: symbol).font(.system(size: 15)) }
    }

    /// Markup tools use the same lettered icons as the context menu.
    private func toolLabel(for tool: AnnotationTool, isActive: Bool) -> some View {
        toolLabel(isActive: isActive) {
            if tool.marksText {
                Image(nsImage: MarkupGlyph.image(for: tool, side: 20))
            } else {
                Image(systemName: tool.symbol).font(.system(size: 15))
            }
        }
    }

    private func toolLabel<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 30, height: 26)
            .background(isActive ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .contentShape(Rectangle())
    }

    private func toggle(_ tool: AnnotationTool) {
        library.chooseTool(tool)
    }

    private func pick(_ shape: AnnotationTool) {
        lastShape = shape
        library.activeTool = shape
    }
}

/// Font families for text boxes: the system font, common Latin and Chinese
/// families that are installed, then every installed family.
enum FontChoices {
    static let common = [
        "Helvetica Neue", "Times New Roman", "Georgia", "Avenir Next", "Courier New", "Menlo",
        "PingFang SC", "Songti SC", "Kaiti SC", "STHeiti", "Hiragino Sans GB", "Yuanti SC"
    ].filter { all.contains($0) }

    static let all = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    /// The family's name as the system shows it, such as 苹方 for PingFang SC.
    static func displayName(_ family: String?) -> String {
        guard let family else { return L("System Font") }
        return NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }
}

struct FontFamilyMenu: View {
    let family: String?
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            Button(FontChoices.displayName(nil)) { choose(nil) }
            Divider()
            ForEach(FontChoices.common, id: \.self) { name in
                Button(FontChoices.displayName(name)) { choose(name) }
            }
            Divider()
            Menu(L("All Fonts")) {
                ForEach(FontChoices.all, id: \.self) { name in
                    Button(FontChoices.displayName(name)) { choose(name) }
                }
            }
        } label: {
            Text(FontChoices.displayName(family))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Font"))
    }
}

/// The expanded export row: a PDF copy with annotations kept or flattened, and
/// page images. While images are written it shows progress and Cancel.
private struct ExportBar: View {
    @EnvironmentObject private var library: ReaderLibrary

    var body: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            if let progress = library.exportProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 220)
                Text(L("Exporting %ld of %ld…", progress.done, progress.total))
                    .monospacedDigit()
                Button(L("Cancel")) { library.cancelExport() }
            } else {
                pdfCopyControls
                Divider().frame(height: 20)
                imageControls
            }
            if let status = library.exportStatus {
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var pdfCopyControls: some View {
        HStack(spacing: 8) {
            Label(L("PDF Copy"), systemImage: "doc.on.doc")
                .foregroundStyle(.secondary)
            Picker(L("Annotations"), selection: $library.exportFlattensAnnotations) {
                Text(L("Keep Annotations")).tag(false)
                Text(L("Flatten Annotations")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L("Flattened annotations become part of the page and can no longer be edited."))
            Button(L("Export…")) { library.exportPDFCopy() }
                .buttonStyle(.bordered)
        }
    }

    private var imageControls: some View {
        HStack(spacing: 8) {
            Label(L("Images"), systemImage: "photo")
                .foregroundStyle(.secondary)
            Picker(L("Format"), selection: $library.imageExportFormat) {
                Text(verbatim: "PNG").tag(PageImageFormat.png)
                Text(verbatim: "JPEG").tag(PageImageFormat.jpeg)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker(L("Pages"), selection: $library.imageExportRange) {
                ForEach(ImageExportRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if library.imageExportRange == .custom {
                TextField(L("1-3, 5"), text: $library.imageExportPages)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { library.exportImages() }
            }
            Menu {
                ForEach(ReaderLibrary.exportResolutions, id: \.self) { resolution in
                    Button(L("%ld dpi", Int(resolution))) { library.imageExportResolution = resolution }
                }
            } label: {
                Text(L("%ld dpi", Int(library.imageExportResolution)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Resolution"))
            Button(L("Export…")) { library.exportImages() }
                .buttonStyle(.bordered)
        }
    }
}
