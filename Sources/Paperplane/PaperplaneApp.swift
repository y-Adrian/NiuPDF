import SwiftUI

@main
struct PaperplaneApp: App {
    @StateObject private var library = ReaderLibrary()

    var body: some Scene {
        WindowGroup {
            ReaderWindow()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开 PDF…") { library.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("存储") { library.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(library.document == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("查找…") { library.focusSearch.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(library.document == nil)
            }
        }
    }
}
