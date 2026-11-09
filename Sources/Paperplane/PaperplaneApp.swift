import AppKit
import SwiftUI

/// Settles unsaved annotations in every window before quitting, and routes
/// PDFs opened from Finder to the reader windows.
final class PaperplaneAppDelegate: NSObject, NSApplicationDelegate {
    /// Set when unsaved changes were already settled, as by "Restart Now".
    var skipsUnsavedChangesPrompt = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Start on the start page, not with the windows of the last session.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        // Single-document settings from before windows had their own documents.
        for key in ["lastOpenedPDFBookmark", "lastOpenedPDFPageIndex", "lastOpenedPDFZoomScale"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit adds an English "Toggle Sidebar" for split views; this app has
        // its own sidebar commands under View.
        DispatchQueue.main.async {
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                for item in menu.items where item.action == NSSelectorFromString("toggleSidebar:") {
                    menu.removeItem(item)
                }
            }
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if skipsUnsavedChangesPrompt { return .terminateNow }
        return AppModel.shared.confirmClosingAll() ? .terminateNow : .terminateCancel
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }
}

@main
struct PaperplaneApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: PaperplaneAppDelegate

    var body: some Scene {
        WindowGroup(id: "reader") {
            DocumentWindowRoot()
        }
        .windowStyle(.titleBar)
        .commands { ReaderCommands() }

        // Adds "Settings…" with ⌘, to the app menu.
        Settings {
            SettingsView()
        }
    }
}

/// Menu commands act on the document in the frontmost window. Shortcuts follow
/// macOS Preview where it has one, so they match what Mac users already know.
struct ReaderCommands: Commands {
    @FocusedObject private var focusedLibrary: ReaderLibrary?
    @ObservedObject private var appModel = AppModel.shared

    /// SwiftUI's focused object can be empty right after tabs change; the key
    /// window's document is then the one the commands mean.
    private var library: ReaderLibrary? { focusedLibrary ?? appModel.activeLibrary }

    /// Items are disabled only when the frontmost window is known to have no
    /// document. When SwiftUI has not reported a focused window, they stay
    /// enabled and act on the key window's document, so a shortcut is never
    /// swallowed by an item whose enabled state is out of date.
    private var knownEmpty: Bool { focusedLibrary.map { $0.document == nil } ?? false }
    private var knownNoResults: Bool { focusedLibrary.map { $0.searchResults.isEmpty } ?? false }

    /// The key window's library when it shows a document.
    private var documentLibrary: ReaderLibrary? {
        library.flatMap { $0.document == nil ? nil : $0 }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("New Tab")) { appModel.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button(L("New Window")) { appModel.newWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button(L("Open PDF…")) { appModel.presentOpenPanel(for: library) }
                .keyboardShortcut("o", modifiers: .command)
            Menu(L("Open Recent")) {
                ForEach(appModel.recentDocuments.prefix(10)) { recent in
                    Button(recent.name) { appModel.openRecent(recent, preferring: library) }
                }
                Divider()
                Button(L("Clear Menu")) { appModel.clearRecents() }
                    .disabled(appModel.recentDocuments.isEmpty)
            }
        }
        // Replacing the save group also drops the default Close, so it is added here.
        CommandGroup(replacing: .saveItem) {
            Button(L("Close Tab")) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
            Button(L("Close Window")) { closeFrontWindowAndTabs() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button(L("Save")) { documentLibrary?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(knownEmpty)
            Divider()
            Button(L("Export…")) { documentLibrary?.expandedMode = .export }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(knownEmpty)
        }
        CommandGroup(replacing: .printItem) {
            Button(L("Print…")) { documentLibrary?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(knownEmpty)
        }
        CommandGroup(after: .textEditing) {
            Button(L("Find…")) { documentLibrary?.focusSearch.toggle() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(knownEmpty)
            Button(L("Find Next")) { library?.moveSearchResult(1) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(knownNoResults)
            Button(L("Find Previous")) { library?.moveSearchResult(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(knownNoResults)
            Button(L("Use Selection for Find")) { documentLibrary?.useSelectionForFind() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(knownEmpty)
        }
        CommandGroup(before: .toolbar) {
            Button(library?.isSidebarVisible == false ? L("Show Sidebar") : L("Hide Sidebar")) { library?.isSidebarVisible.toggle() }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button(L("Thumbnails")) { library?.showSidebar(.thumbnails) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button(L("Outline")) { library?.showSidebar(.outline) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button(L("Annotations")) { library?.showSidebar(.annotations) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Divider()
            // "=" is the key that also carries "+", so ⌘= works without Shift.
            Button(L("Zoom In")) { library?.zoom(by: 1.18) }
                .keyboardShortcut("=", modifiers: .command)
            Button(L("Zoom Out")) { library?.zoom(by: 0.85) }
                .keyboardShortcut("-", modifiers: .command)
            Button(L("Actual Size")) { library?.setZoom(1) }
                .keyboardShortcut("0", modifiers: .command)
            Button(L("Fit Page")) { library?.fitPage() }
                .keyboardShortcut("9", modifiers: .command)
            Button(L("Fit Width")) { library?.fitWidth() }
            Divider()
            Button(ReaderLayout.continuous.title) { library?.layoutMode = .continuous }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button(ReaderLayout.singlePage.title) { library?.layoutMode = .singlePage }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button(ReaderLayout.twoPage.title) { library?.layoutMode = .twoPage }
                .keyboardShortcut("3", modifiers: [.command, .control])
            Button(ReaderLayout.twoPageBook.title) { library?.layoutMode = .twoPageBook }
                .keyboardShortcut("4", modifiers: [.command, .control])
            Divider()
        }
        CommandMenu(L("Go")) {
            Button(L("Previous Page")) { library?.stepPage(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(knownEmpty)
            Button(L("Next Page")) { library?.stepPage(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(knownEmpty)
            Button(L("First Page")) { library?.goToPage(1) }
                .disabled(knownEmpty)
            Button(L("Last Page")) { library.map { $0.goToPage($0.pageCount) } }
                .disabled(knownEmpty)
            Divider()
            Button(L("Go to Page…")) { documentLibrary?.focusPageField = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(knownEmpty)
        }
        CommandMenu(L("Annotate")) {
            Button(library?.isAnnotationBarVisible == true ? L("Hide Annotation Tools") : L("Show Annotation Tools")) {
                documentLibrary?.isAnnotationBarVisible.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(knownEmpty)
            Divider()
            toolItem(.highlight, key: "h")
            toolItem(.underline, key: "u")
            toolItem(.strikeOut, key: "s")
            Divider()
            toolItem(.note, key: "n")
            toolItem(.textBox, key: "t")
            toolItem(.ink, key: "k")
            Divider()
            toolItem(.rectangle, key: "r")
            toolItem(.ellipse, key: "o")
            toolItem(.arrow, key: "a")
        }
    }

    /// Picks a tool, opening the annotation row so its state is visible.
    private func toolItem(_ tool: AnnotationTool, key: KeyEquivalent) -> some View {
        Button(tool.title) {
            guard let library = documentLibrary else { return }
            library.isAnnotationBarVisible = true
            library.chooseTool(tool)
        }
        .keyboardShortcut(key, modifiers: [.command, .control])
        .disabled(knownEmpty)
    }

    /// ⇧⌘W closes the front window with all of its tabs; each tab still asks
    /// about unsaved changes through its close guard.
    private func closeFrontWindowAndTabs() {
        guard let window = NSApp.keyWindow else { return }
        for tab in window.tabGroup?.windows ?? [window] {
            tab.performClose(nil)
            if tab.isVisible { break }   // A cancelled close stops the rest.
        }
    }
}
