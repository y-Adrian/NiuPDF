import AppKit
import SwiftUI

/// Interface language choice. macOS fixes an app's language at launch (PDFKit
/// and the system menus included), so a change applies after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    private static let choiceKey = "interfaceLanguage"
    /// The standard per-app override that Foundation reads at launch.
    private static let appleLanguagesKey = "AppleLanguages"

    /// Language names are shown in their own language so they can always be found.
    var title: String {
        switch self {
        case .system: L("Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static var saved: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: choiceKey) ?? "") ?? .system
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.choiceKey)
        if self == .system {
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        } else {
            defaults.set([rawValue], forKey: Self.appleLanguagesKey)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L("General"), systemImage: "gearshape") }
        }
        .frame(width: 420)
    }
}

private struct GeneralSettings: View {
    /// The language this process is running in, fixed at launch.
    private let launchLanguage = AppLanguage.saved
    @State private var language = AppLanguage.saved

    var body: some View {
        Form {
            Picker(L("Language"), selection: $language) {
                ForEach(AppLanguage.allCases) { choice in
                    Text(verbatim: choice.title).tag(choice)
                }
            }
            .onChange(of: language) { $0.save() }

            AutosaveSetting()

            SelectionToolbarSetting()

            SavedPasswordsSetting()

            if language != launchLanguage {
                HStack {
                    Text(L("Takes effect after Paperplane restarts."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if AppRelauncher.canRelaunch {
                        Button(L("Restart Now")) { AppRelauncher.relaunch() }
                    }
                }
                .font(.callout)
            }
        }
        .padding(20)
    }
}

private struct AutosaveSetting: View {
    /// Shared by every window; each document watches the defaults for changes.
    @AppStorage(ReaderLibrary.autosaveKey) private var isAutosaveEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("Save annotations automatically"), isOn: $isAutosaveEnabled)
            Text(L("Changes are written to the PDF a moment after each edit, and when you switch apps or quit."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

private struct SelectionToolbarSetting: View {
    @AppStorage(SelectionToolbar.enabledKey) private var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("Show markup tools for selected text"), isOn: $isEnabled)
            Text(L("Highlight, underline, strikethrough, note and copy appear above text you select."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

/// Files whose passwords are remembered in the keychain, each removable.
private struct SavedPasswordsSetting: View {
    @State private var entries: [PasswordKeychain.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Saved Passwords"))
            if entries.isEmpty {
                Text(L("Choose “Remember password in Keychain” when opening a protected PDF, and it opens without asking next time."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack {
                                Image(systemName: "lock.doc")
                                    .foregroundStyle(.secondary)
                                Text(entry.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(entry.path)
                                Spacer()
                                Button {
                                    PasswordKeychain.remove(path: entry.path)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(L("Forget Password"))
                                .accessibilityLabel(L("Forget Password for “%@”", entry.fileName))
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(L("Remembered passwords open these files without asking."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Forget All…"), action: confirmForgetAll)
                }
            }
        }
        .padding(.top, 8)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: PasswordKeychain.didChange)) { _ in reload() }
    }

    private func reload() {
        entries = PasswordKeychain.entries()
    }

    private func confirmForgetAll() {
        let alert = NSAlert()
        alert.messageText = L("Forget all saved passwords?")
        alert.informativeText = L("These files will ask for their passwords again.")
        alert.addButton(withTitle: L("Forget All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PasswordKeychain.removeAll()
    }
}

/// Restarts the app bundle. A `swift run` build is a bare executable with no
/// bundle to reopen, so it can only be restarted by hand.
@MainActor
enum AppRelauncher {
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func relaunch() {
        let delegate = NSApp.delegate as? PaperplaneAppDelegate
        // Settle unsaved annotations in every window first, so quitting cannot
        // be cancelled after the new instance has started.
        guard AppModel.shared.confirmClosingAll() else { return }
        delegate?.skipsUnsavedChangesPrompt = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    (NSApp.delegate as? PaperplaneAppDelegate)?.skipsUnsavedChangesPrompt = false
                    NSAlert(error: error).runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
