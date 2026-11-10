import Foundation
import Security

/// Document passwords the user chose to remember, kept in the login keychain
/// with one item per file path, as reading positions and bookmarks are. A
/// moved or renamed file asks again.
enum PasswordKeychain {
    struct Entry: Identifiable, Hashable {
        let path: String
        var id: String { path }
        var fileName: String { (path as NSString).lastPathComponent }
    }

    /// Posted after a password is saved or removed.
    static let didChange = Notification.Name("PasswordKeychainDidChange")

    /// Per bundle, so probe and development builds keep their own items.
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "app.paperplane.reader") + ".document-password"
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func password(for url: URL) -> String? {
        var query = query(account: key(for: url))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String, for url: URL) -> Bool {
        let existing = query(account: key(for: url))
        // Replace rather than update: an item keeps the access list of the
        // build that created it, so after a rebuild an updated item could be
        // written but not read back. Deleting it needs no permission.
        SecItemDelete(existing as CFDictionary)
        var item = existing
        item[kSecValueData as String] = Data(password.utf8)
        // Shown in Keychain Access.
        item[kSecAttrLabel as String] = "Paperplane: " + url.lastPathComponent
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    static func remove(path: String) {
        if SecItemDelete(query(account: path) as CFDictionary) == errSecSuccess {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func remove(for url: URL) {
        remove(path: key(for: url))
    }

    /// Files with a saved password, by name. Reads attributes only, never the passwords.
    static func entries() -> [Entry] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items
            .compactMap { ($0[kSecAttrAccount as String] as? String).map(Entry.init(path:)) }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// Item by item: on macOS one delete call may remove only the first match.
    static func removeAll() {
        for entry in entries() { remove(path: entry.path) }
    }
}
