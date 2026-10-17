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
                        ThumbnailSidebar(document: document, selectedIndex: $library.currentPageIndex) { index in
                            library.goToPage(index + 1)
                        }
                        .frame(width: 205)
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
            Button { library.setZoom(1) } label: { Text("\(Int(library.zoomScale * 100))%") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
                .disabled(library.document == nil)
                .help("重设缩放")
            Button { library.zoom(by: 1.18) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(library.document == nil)
                .help("放大")

            Button { library.highlightSelection() } label: {
                Image(systemName: "highlighter")
            }
            .disabled(library.document == nil)
            .help("高亮选中的文字")

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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在文稿中查找", text: $library.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { library.find(library.searchText) }
                .onChange(of: library.focusSearch) { value in
                    if value { isFocused = true; library.focusSearch = false }
                }
                .onChange(of: isFocused) { focused in
                    if focused { library.focusSearch = false }
                }
            if !library.searchText.isEmpty {
                Text(library.searchResults.isEmpty ? "0 项" : "\(library.searchResultIndex + 1)/\(library.searchResults.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
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
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }
}
