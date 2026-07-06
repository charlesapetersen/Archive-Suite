import Foundation
import Security

/// Stores and retrieves API keys from the macOS Keychain.
struct KeychainHelper {
    private static let service = "com.archiveprocessor.app"

    /// Saves (or updates) the key. Returns whether it was durably written — callers should surface a
    /// failure instead of showing "Saved", since a silently-dropped key causes later auth errors with
    /// no explanation (e.g. a locked keychain or an entitlement/access-group mismatch).
    @discardableResult
    static func save(account: String, password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Raced with another writer that created it first — update instead.
                return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
            }
            return addStatus == errSecSuccess
        default:
            return false   // locked keychain, entitlement/auth error, etc. — report, don't swallow.
        }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
