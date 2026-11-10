import PDFKit
import SwiftUI

/// A page the reader marked to come back to.
struct PageBookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var pageIndex: Int
    var title: String
    var createdAt = Date()
}

/// Bookmarks kept by the app, per file, like the reading position: adding
/// one does not edit the PDF, so read-only and locked files can have them
/// too. They stay on this Mac and do not travel with the file.
enum BookmarkStore {
    private static let key = "pageBookmarks"

    static func bookmarks(for url: URL) -> [PageBookmark] {
        guard let data = all()[url.standardizedFileURL.path],
              let bookmarks = try? JSONDecoder().decode([PageBookmark].self, from: data) else { return [] }
        return bookmarks
    }

    static func save(_ bookmarks: [PageBookmark], for url: URL) {
        var all = all()
        let path = url.standardizedFileURL.path
        if bookmarks.isEmpty {
            all[path] = nil
        } else if let data = try? JSONEncoder().encode(bookmarks) {
            all[path] = data
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    private static func all() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}

extension ReaderLibrary {
    /// Bookmarks of the open file, in page order.
    var sortedBookmarks: [PageBookmark] {
        bookmarks.sorted { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
    }

    func bookmark(onPage index: Int) -> PageBookmark? {
        bookmarks.first { $0.pageIndex == index }
    }

    /// Loads the file's bookmarks and ties each to its page object, so they
    /// follow pages that are moved, and go with pages that are deleted.
    func loadBookmarks() {
        guard let document, let fileURL else {
            bookmarks = []
            bookmarkPages = [:]
            return
        }
        bookmarks = BookmarkStore.bookmarks(for: fileURL).filter { $0.pageIndex < document.pageCount }
        bookmarkPages = Dictionary(uniqueKeysWithValues: bookmarks.compactMap { bookmark in
            document.page(at: bookmark.pageIndex).map { (bookmark.id, $0) }
        })
    }

    /// ⌘B: bookmarks the current page, or removes its bookmark. The title is
    /// the selected text when there is some, else the page number.
    func toggleBookmarkOnCurrentPage() {
        if let existing = bookmark(onPage: currentPageIndex) {
            removeBookmark(existing)
        } else {
            addBookmark(onPage: currentPageIndex)
        }
    }

    func addBookmark(onPage index: Int) {
        guard let document, let page = document.page(at: index), bookmark(onPage: index) == nil else { return }
        let selected = (pdfView?.currentSelection?.string ?? "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let title = selected.isEmpty ? L("Page %ld", index + 1) : String(selected.prefix(60))
        let bookmark = PageBookmark(pageIndex: index, title: title)
        bookmarks.append(bookmark)
        bookmarkPages[bookmark.id] = page
        saveBookmarks()
    }

    func removeBookmark(_ bookmark: PageBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarkPages[bookmark.id] = nil
        saveBookmarks()
    }

    func renameBookmark(_ bookmark: PageBookmark, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].title = trimmed
        saveBookmarks()
    }

    func goToBookmark(_ bookmark: PageBookmark) {
        goToPage(bookmark.pageIndex + 1)
    }

    /// After pages are inserted, deleted or moved: each bookmark takes its
    /// page's new index; bookmarks of deleted pages are dropped.
    func syncBookmarksToPages() {
        guard let document, !bookmarks.isEmpty else { return }
        var changed = false
        bookmarks = bookmarks.compactMap { bookmark in
            guard let page = bookmarkPages[bookmark.id] else { return bookmark }
            let index = document.index(for: page)
            guard index != NSNotFound else {
                bookmarkPages[bookmark.id] = nil
                changed = true
                return nil
            }
            if index != bookmark.pageIndex { changed = true }
            var moved = bookmark
            moved.pageIndex = index
            return moved
        }
        if changed { saveBookmarks() }
    }

    private func saveBookmarks() {
        guard let fileURL else { return }
        BookmarkStore.save(bookmarks, for: fileURL)
    }
}

/// The bookmarks at the top of the outline tab: click to go, double-click or
/// the context menu to rename, + to bookmark the current page.
struct BookmarkSection: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var editing: PageBookmark.ID?
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Bookmarks"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { library.toggleBookmarkOnCurrentPage() } label: {
                    Image(systemName: library.bookmark(onPage: library.currentPageIndex) == nil ? "plus" : "bookmark.slash")
                }
                .buttonStyle(.borderless)
                .help(library.bookmark(onPage: library.currentPageIndex) == nil ? L("Add Bookmark") : L("Remove Bookmark"))
            }
            if library.bookmarks.isEmpty {
                Text(L("Press ⌘B to bookmark the current page."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(library.sortedBookmarks) { bookmark in
                    row(bookmark)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ bookmark: PageBookmark) -> some View {
        let isCurrent = bookmark.pageIndex == library.currentPageIndex
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            if editing == bookmark.id {
                TextField(L("Bookmark Name"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($isFieldFocused)
                    .onSubmit { commit(bookmark) }
                    .onExitCommand { editing = nil }
                    .onChange(of: isFieldFocused) { focused in if !focused { commit(bookmark) } }
            } else {
                Text(bookmark.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(bookmark.pageIndex + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEditing(bookmark) }
        .onTapGesture { library.goToBookmark(bookmark) }
        .contextMenu {
            Button(L("Rename")) { beginEditing(bookmark) }
            Button(L("Delete Bookmark"), role: .destructive) { library.removeBookmark(bookmark) }
        }
        .help(L("Page %ld", bookmark.pageIndex + 1))
    }

    private func beginEditing(_ bookmark: PageBookmark) {
        draft = bookmark.title
        editing = bookmark.id
        DispatchQueue.main.async { isFieldFocused = true }
    }

    private func commit(_ bookmark: PageBookmark) {
        guard editing == bookmark.id else { return }
        library.renameBookmark(bookmark, to: draft)
        editing = nil
    }
}
