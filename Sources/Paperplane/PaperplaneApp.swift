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
            CommandMenu("页面布局") {
                Button("连续滚动") { library.layoutMode = .continuous }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("单页") { library.layoutMode = .singlePage }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("双页连续") { library.layoutMode = .twoPage }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("封面 + 双页") { library.layoutMode = .twoPageBook }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Divider()
                Button("适合宽度") { library.fitWidth() }
                    .disabled(library.document == nil)
                Button("适合页面") { library.fitPage() }
                    .disabled(library.document == nil)
            }
        }
    }
}
