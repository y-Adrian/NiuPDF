import AppKit
import SwiftUI

/// Asks about unsaved annotations before the app quits.
final class PaperplaneAppDelegate: NSObject, NSApplicationDelegate {
    weak var library: ReaderLibrary?
    /// Set when unsaved changes were already settled, as by "Restart Now".
    var skipsUnsavedChangesPrompt = false

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if skipsUnsavedChangesPrompt { return .terminateNow }
        return library?.confirmDiscardingUnsavedChanges() == false ? .terminateCancel : .terminateNow
    }
}

@main
struct PaperplaneApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: PaperplaneAppDelegate
    @StateObject private var library = ReaderLibrary()

    var body: some Scene {
        WindowGroup {
            ReaderWindow()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear { appDelegate.library = library }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Open PDF…")) { library.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Save")) { library.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(library.document == nil)
            }
            CommandGroup(after: .textEditing) {
                Button(L("Find…")) { library.focusSearch.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(library.document == nil)
            }
            CommandMenu(L("Page Layout")) {
                Button(ReaderLayout.continuous.title) { library.layoutMode = .continuous }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button(ReaderLayout.singlePage.title) { library.layoutMode = .singlePage }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button(ReaderLayout.twoPage.title) { library.layoutMode = .twoPage }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button(ReaderLayout.twoPageBook.title) { library.layoutMode = .twoPageBook }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Divider()
                Button(L("Fit Width")) { library.fitWidth() }
                    .disabled(library.document == nil)
                Button(L("Fit Page")) { library.fitPage() }
                    .disabled(library.document == nil)
            }
        }

        // Adds "Settings…" with ⌘, to the app menu.
        Settings {
            SettingsView()
        }
    }
}
