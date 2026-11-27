import Foundation
import LocalAuthentication
import Security

/// Stores and retrieves API keys from the macOS Keychain.
struct KeychainHelper {
    private static let service = "com.archiveprocessor.app"
    private static let lock = NSLock()

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
    /// A key equal to the stored one is not written again: every write resets the item's partition list to this
    /// build's signature, after which `/usr/bin/security` and the bench scripts are refused (W47.gateway-key-rewrites).
    @discardableResult
    static func save(account: String, password: String) -> Bool {
        if isHeadlessTestMode { return false }   // never write the real Keychain in a headless test
        guard let data = password.data(using: .utf8) else { return false }
        lock.lock(); defer { lock.unlock() }
        if read(account: account, allowInteraction: true) == password { return true }

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

    static func load(account: String, allowInteraction: Bool = true) -> String? {
        if isHeadlessTestMode {
            #if DEBUG
            return ProcessorUITestConfiguration.standInKey(for: account)   // nil unless a UI test names the account
            #else
            return nil
            #endif
        }
        return lock.withLock { read(account: account, allowInteraction: allowInteraction) }
    }

    private static func read(account: String, allowInteraction: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let result: CFTypeRef?
        if allowInteraction {
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            result = item
        } else {
            query[kSecUseAuthenticationContext as String] = quietContext()
            result = ArchiveCopyKeychainItemQuietly(query as CFDictionary)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the account holds an item, without reading the secret and without ever asking the user: only the
    /// item's attributes are requested, under a context that may not interact (W46.settings-interviews, which lists
    /// the keys it finds at first start; reading them would pop the Keychain prompt for each one). A Keychain that will
    /// not answer without asking (locked) says nothing about the item, so it counts as not found: a key not listed is
    /// one that is not used.
    static func exists(account: String) -> Bool {
        if isHeadlessTestMode { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: quietContext()
        ]
        return lock.withLock { ArchiveCopyKeychainItemQuietly(query as CFDictionary) != nil }
    }

    private static func quietContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func delete(account: String) {
        if isHeadlessTestMode { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = lock.withLock { SecItemDelete(query as CFDictionary) }
    }
}
