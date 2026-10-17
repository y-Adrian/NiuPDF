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
            if let document = library.document {
                HStack(spacing: 0) {
                    if library.isSidebarVisible {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                sidebarModeButton(.thumbnails, title: "缩略图", symbol: "square.grid.2x2")
                                sidebarModeButton(.outline, title: "大纲", symbol: "list.bullet.indent")
                                if !library.searchResults.isEmpty {
                                    sidebarModeButton(.searchResults, title: "结果", symbol: "text.magnifyingglass")
                                }
                            }
                            .padding(8)
                            Divider()
                            switch library.sidebarMode {
                            case .thumbnails:
                                ThumbnailSidebar(document: document, selectedIndex: $library.currentPageIndex) { index in
                                    library.goToPage(index + 1)
                                }
                            case .outline:
                                PDFOutlineSidebar(document: document) { index in
                                    library.goToPage(index + 1)
                                }
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
        .alert("操作失败", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { library.isSidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help("显示或隐藏缩略图侧边栏")
            .disabled(library.document == nil)

            Button { library.presentOpenPanel() } label: {
                Label("打开", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider().frame(height: 22)

            Button { library.stepPage(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(library.document == nil || library.currentPageIndex <= 0)
                .help("上一页")
            TextField("页", text: $pageInput)
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
                .help("下一页")

            Divider().frame(height: 22)

            Button { library.zoom(by: 0.85) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(library.document == nil)
                .help("缩小")
            Menu {
                Button("适合宽度") { library.fitWidth() }
                Button("适合页面") { library.fitPage() }
                Divider()
                Button("实际大小（100%）") { library.setZoom(1) }
            } label: {
                Text("\(Int(library.zoomScale * 100))%")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)
            }
            .menuStyle(.borderlessButton)
            .disabled(library.document == nil)
            .help("缩放选项")
            Button { library.zoom(by: 1.18) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(library.document == nil)
                .help("放大")

            Button { library.highlightSelection() } label: {
                Image(systemName: "highlighter")
            }
            .disabled(library.document == nil)
            .help("高亮选中的文字")

            Button { library.underlineSelection() } label: {
                Image(systemName: "underline")
            }
            .disabled(library.document == nil)
            .help("为选中文字添加下划线")

            Button { library.strikeOutSelection() } label: {
                Image(systemName: "strikethrough")
            }
            .disabled(library.document == nil)
            .help("为选中文字添加删除线")

            Picker("页面布局", selection: $library.layoutMode) {
                ForEach(ReaderLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help("页面布局")
            .disabled(library.document == nil)

            Button { library.save() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(library.document == nil)
            .help("存储批注（⌘S）")

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
            Label(title, systemImage: symbol)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
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
            Text("打开一份 PDF 开始阅读")
                .font(.title3.weight(.medium))
            Text("将 PDF 拖到窗口，或从文件中选择")
                .foregroundStyle(.secondary)
            Button { library.presentOpenPanel() } label: {
                Label("选择 PDF…", systemImage: "folder")
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
            TextField("在文稿中查找", text: $library.searchText)
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
                    Text(library.searchResults.isEmpty ? "0 项" : "\(library.searchResultIndex + 1)/\(library.searchResults.count)")
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
            searchOptionButton("Aa", label: "区分大小写", isActive: library.isCaseSensitiveSearch) {
                library.isCaseSensitiveSearch.toggle()
                library.find(library.searchText)
            }
            searchOptionButton("ab", label: "全词匹配", isActive: library.isWholeWordSearch, usesWordBracket: true) {
                library.isWholeWordSearch.toggle()
                library.find(library.searchText)
            }
            searchOptionButton(".*", label: "正则表达式", isActive: library.isRegularExpressionSearch) {
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
        .accessibilityValue(isActive ? "开启" : "关闭")
        .help("\(label)：\(isActive ? "已启用" : "已关闭")")
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
