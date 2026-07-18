import Foundation
import Security

/// Stores and retrieves API keys from the macOS Keychain.
struct KeychainHelper {
    private static let service = "com.archiveprocessor.app"

    /// True when the app is launched in a headless test/driver mode. In that mode we NEVER touch the
    /// Keychain — so a test launch can't trigger the interactive "ArchiveProcessor wants to use the
    /// Keychain" prompt, which blocks a headless run and interrupts the owner (each ad-hoc rebuild has a
    /// new signature, so the ACL never matches and it re-prompts). The headless drivers supply any needed
    /// API key via environment variables, not the Keychain, so short-circuiting to nil/no-op here is safe
    /// and changes NOTHING for a normal (non-test) launch.
    static var isHeadlessTestMode: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["FILERELAY_TESTMODE"] != nil || e["FILERELAY_EMIT_GOLDEN"] != nil
            || e["LIVECAPTURE_TESTMODE"] != nil || e["PROCESSFILES_TESTMODE"] != nil
            || e["NETWORKSESSION_TEST"] != nil
            || e["ARCHIVEPROC_HEADLESS"] != nil
    }

    /// Saves (or updates) the key. Returns whether it was durably written — callers should surface a
    /// failure instead of showing "Saved", since a silently-dropped key causes later auth errors with
    /// no explanation (e.g. a locked keychain or an entitlement/access-group mismatch).
    @discardableResult
    static func save(account: String, password: String) -> Bool {
        if isHeadlessTestMode { return false }   // never write the real Keychain in a headless test
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
        if isHeadlessTestMode { return nil }   // no Keychain access at launch in a headless test → no prompt
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
        if isHeadlessTestMode { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
