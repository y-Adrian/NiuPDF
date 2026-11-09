import Foundation

extension Bundle {
    /// The bundle holding this app's string tables: the app bundle in the Xcode
    /// build, the generated resource bundle when built with SwiftPM.
    static var paperplane: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}

/// Returns the UI string for `key`, which is its English text, in the user's
/// language. Every key needs an entry in each `Localizable.strings` table.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .paperplane, comment: "")
}

/// Localized format string filled with `arguments`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: arguments)
}
