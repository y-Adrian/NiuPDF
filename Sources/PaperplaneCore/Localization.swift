import Foundation

private final class BundleToken {}

extension Bundle {
    /// The bundle holding PaperplaneCore's string tables: the framework in the
    /// Xcode build, the generated resource bundle when built with SwiftPM.
    static var paperplaneCore: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }
}

/// Returns the message for `key`, which is its English text, in the user's language.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .paperplaneCore, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: arguments)
}
