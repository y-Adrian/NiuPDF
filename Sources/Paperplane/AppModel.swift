import AppKit
import SwiftUI

/// A file in the "recent" list. The bookmark keeps sandbox access to the file
/// across launches.
struct RecentDocument: Identifiable, Codable, Equatable {
    var path: String
    var bookmark: Data
    var openedAt: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Where a file was last read, kept per file so each document reopens at its
/// own page and zoom.
enum ReadingPositions {
    private static let key = "readingPositions"
    private static let limit = 200

    static func position(for url: URL) -> (page: Int, zoom: CGFloat?)? {
        guard let entry = all()[url.standardizedFileURL.path] else { return nil }
        // A file can have a zoom recorded before its page ever changed.
        let page = Int(entry["page"] ?? 0)
        let zoom = entry["zoom"].map { CGFloat($0) }
        return (page, zoom.flatMap { $0 > 0 ? $0 : nil })
    }

    static func record(page: Int? = nil, zoom: CGFloat? = nil, for url: URL) {
        var positions = all()
        let path = url.standardizedFileURL.path
        var entry = positions[path] ?? [:]
        if let page { entry["page"] = Double(page) }
        if let zoom { entry["zoom"] = Double(zoom) }
        entry["at"] = Date().timeIntervalSince1970
        positions[path] = entry
        if positions.count > limit {
            // Forget the files read longest ago.
            let oldest = positions.sorted { ($0.value["at"] ?? 0) < ($1.value["at"] ?? 0) }.prefix(positions.count - limit)
            for (path, _) in oldest { positions[path] = nil }
        }
        UserDefaults.standard.set(positions, forKey: key)
    }

    private static func all() -> [String: [String: Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
    }
}

/// App-wide state shared by every reader window: which windows are open, the
/// recent files, and routing files to a window or a new tab.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var recentDocuments: [RecentDocument] = []
    private let libraries = NSHashTable<ReaderLibrary>.weakObjects()
    /// Opens a new reader window; set by the first window from SwiftUI's environment.
    var openWindowAction: (() -> Void)?
    /// What each newly created window should do, in creation order.
    private var pendingWindowRequests: [WindowRequest] = []
    /// Files handed over before any window existed, such as from Finder at launch.
    private var pendingExternalFiles: [URL] = []

    private struct WindowRequest {
        var url: URL?
        weak var tabParent: NSWindow?
    }

    private static let recentsKey = "recentDocuments"
    private static let recentsLimit = 20

    private var keyWindowObservers: [NSObjectProtocol] = []

    private init() {
        // Menus act on the key window's document; tell them when it changes.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            })
        }
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let recents = try? JSONDecoder().decode([RecentDocument].self, from: data) {
            recentDocuments = recents
        }
    }

    // MARK: Windows

    func register(_ library: ReaderLibrary) {
        libraries.add(library)
        if !pendingExternalFiles.isEmpty {
            let files = pendingExternalFiles
            pendingExternalFiles = []
            open(files, preferring: library)
        }
    }

    var openLibraries: [ReaderLibrary] { libraries.allObjects }

    /// The library of the key window, if it is a reader window.
    var activeLibrary: ReaderLibrary? {
        openLibraries.first { $0.window?.isKeyWindow == true } ?? openLibraries.first { $0.window?.isMainWindow == true }
    }

    /// Called by a new window once its NSWindow exists: it takes its pending
    /// request, opening a file and joining a tab group as asked.
    func windowDidAppear(_ library: ReaderLibrary, window: NSWindow) {
        guard !pendingWindowRequests.isEmpty else { return }
        let request = pendingWindowRequests.removeFirst()
        if let parent = request.tabParent, parent !== window, parent.isVisible {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        if let url = request.url {
            library.open(url, confirmingUnsavedChanges: false)
        }
    }

    func newTab() {
        requestWindow(url: nil, tabParent: activeLibrary?.window)
    }

    func newWindow() {
        requestWindow(url: nil, tabParent: nil)
    }

    private func requestWindow(url: URL?, tabParent: NSWindow?) {
        pendingWindowRequests.append(WindowRequest(url: url, tabParent: tabParent))
        openWindowAction?()
    }

    // MARK: Opening

    /// Opens files: an already open file comes to the front; the first new file
    /// goes into `preferred` (or the active window) when it is empty, and the
    /// rest open as tabs next to it.
    func open(_ urls: [URL], preferring preferred: ReaderLibrary? = nil) {
        let target = preferred ?? activeLibrary
        guard target != nil || openWindowAction != nil else {
            pendingExternalFiles += urls
            return
        }
        var newFiles: [URL] = []
        var lastShown: ReaderLibrary?
        for url in urls {
            if let open = library(showing: url) {
                lastShown = open
            } else if !newFiles.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                newFiles.append(url)
            }
        }
        if newFiles.isEmpty {
            if let lastShown { bringToFront(lastShown) }
            return
        }
        if let target, target.document == nil {
            target.open(newFiles.removeFirst(), confirmingUnsavedChanges: false)
        }
        for url in newFiles {
            requestWindow(url: url, tabParent: target?.window ?? activeLibrary?.window)
        }
    }

    func library(showing url: URL) -> ReaderLibrary? {
        openLibraries.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
    }

    private func bringToFront(_ library: ReaderLibrary) {
        guard let window = library.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the standard Open panel, allowing several files.
    func presentOpenPanel(for library: ReaderLibrary?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("Open")
        guard panel.runModal() == .OK else { return }
        open(panel.urls, preferring: library)
    }

    // MARK: Recent files

    func noteOpened(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let path = url.standardizedFileURL.path
        recentDocuments.removeAll { $0.path == path }
        recentDocuments.insert(RecentDocument(path: path, bookmark: bookmark, openedAt: Date()), at: 0)
        if recentDocuments.count > Self.recentsLimit { recentDocuments.removeLast(recentDocuments.count - Self.recentsLimit) }
        saveRecents()
    }

    func openRecent(_ recent: RecentDocument, preferring library: ReaderLibrary?) {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: url.path) else {
            removeRecent(recent)
            let message = L("“%@” can no longer be found. It was removed from the recent files.", recent.name)
            if let library = library ?? activeLibrary { library.errorMessage = message }
            return
        }
        open([url], preferring: library)
    }

    func removeRecent(_ recent: RecentDocument) {
        recentDocuments.removeAll { $0.id == recent.id }
        saveRecents()
    }

    func clearRecents() {
        recentDocuments = []
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentDocuments) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    // MARK: Quitting

    /// Settles unsaved changes in every window; false when the user cancels.
    func confirmClosingAll() -> Bool {
        for library in openLibraries where !library.confirmDiscardingUnsavedChanges() {
            if let window = library.window {
                window.tabGroup?.selectedWindow = window
                window.makeKeyAndOrderFront(nil)
            }
            return false
        }
        return true
    }
}

/// Gives a SwiftUI view its NSWindow: the window becomes a tab when asked, its
/// close button asks about unsaved changes, and the library learns its window.
/// SwiftUI adds the view to its window some time after creating it, so the
/// window is picked up in `viewDidMoveToWindow`, not when the view is made.
struct WindowAccessor: NSViewRepresentable {
    let library: ReaderLibrary

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindow = { [library, coordinator = context.coordinator] window in
            guard library.window !== window else { return }
            library.window = window
            window.tabbingIdentifier = "PaperplaneReader"
            coordinator.closeGuard.install(on: window)
            AppModel.shared.windowDidAppear(library, window: window)
        }
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {
        guard let window = view.window else { return }
        // SwiftUI may set its own delegate again; keep the close guard in front.
        context.coordinator.closeGuard.install(on: window)
        window.representedURL = library.fileURL
    }

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    @MainActor
    final class Coordinator {
        let closeGuard: WindowCloseGuard
        init(library: ReaderLibrary) { closeGuard = WindowCloseGuard(library: library) }
    }
}

final class WindowObservingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

/// Sits in front of SwiftUI's own window delegate to ask about unsaved changes
/// before a window or tab closes, forwarding everything else unchanged.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var library: ReaderLibrary?
    private weak var original: NSWindowDelegate?

    init(library: ReaderLibrary) {
        self.library = library
    }

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard library?.confirmDiscardingUnsavedChanges() ?? true else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        library?.close()
        original?.windowWillClose?(notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// One reader window or tab, each with its own document.
struct DocumentWindowRoot: View {
    @StateObject private var library = ReaderLibrary()
    @ObservedObject private var appModel = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ReaderWindow()
            .environmentObject(library)
            .environmentObject(appModel)
            .focusedSceneObject(library)
            .frame(minWidth: 900, minHeight: 620)
            .navigationTitle(library.fileURL == nil ? L("Paperplane") : library.displayName)
            .background(WindowAccessor(library: library))
            .onAppear {
                appModel.openWindowAction = { openWindow(id: "reader") }
                appModel.register(library)
            }
    }
}
