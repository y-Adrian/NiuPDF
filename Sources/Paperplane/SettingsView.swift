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

/// Restarts the app bundle. A `swift run` build is a bare executable with no
/// bundle to reopen, so it can only be restarted by hand.
@MainActor
enum AppRelauncher {
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func relaunch() {
        let delegate = NSApp.delegate as? PaperplaneAppDelegate
        // Settle unsaved annotations first, so quitting cannot be cancelled
        // after the new instance has started.
        guard delegate?.library?.confirmDiscardingUnsavedChanges() ?? true else { return }
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
