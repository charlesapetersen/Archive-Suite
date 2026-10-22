import Foundation
import Security

/// The Drive tokens as one record, so the access token, refresh token and expiry are written and read together.
struct DriveTokens: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
}

/// Where the token record is kept. The app uses `KeychainTokenVault`; the host tests use an in-memory one.
protocol DriveTokenVault: Sendable {
    func read() -> Data?
    /// Replaces the stored record. False if it could not be written.
    func write(_ data: Data) -> Bool
    /// Removes the record. True if it is gone afterwards (including when there was none).
    func delete() -> Bool
}

/// One generic-password item, readable after the first unlock and never leaving this device: not in an iCloud
/// or iTunes backup and not restored to another phone (W40.i-fix-ios-drive-token-keychain). Android keeps the
/// same tokens in private SharedPreferences with `allowBackup=false`.
struct KeychainTokenVault: DriveTokenVault {
    static let service = "com.archiveprocessor.capture.ios.drive"
    static let account = "oauth-tokens"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// What every write sets, the protection class included (so an update cannot leave an older, weaker class).
    static func writeAttributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    func write(_ data: Data) -> Bool {
        let attrs = Self.writeAttributes(data)
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Thread-safe token storage so `DriveClient`'s synchronous token provider (called off the main thread)
/// can read the current access/refresh tokens without actor-isolation conflicts.
///
/// Foundation and Security only, so the host tests (`scripts/test-ios-capture-queue.sh`) compile it standalone.
final class TokenStore: @unchecked Sendable {
    /// Where builds before W40.i-fix-ios-drive-token-keychain kept the tokens. `load()` removes them and does
    /// not read them: there is no production material to carry over, and a phone signed in on such a build
    /// signs in once more.
    static let legacyDefaultsKeys = ["driveAccessToken", "driveRefreshToken", "driveTokenExpiry"]

    private let lock = NSLock()
    private var current = DriveTokens()
    private let vault: DriveTokenVault
    private let defaults: UserDefaults

    init(vault: DriveTokenVault = KeychainTokenVault(), defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
    }

    var accessToken: String? { lock.withLock { current.accessToken } }
    var refreshToken: String? { lock.withLock { current.refreshToken } }
    var expiry: Date? { lock.withLock { current.expiry } }

    func update(accessToken: String?, refreshToken: String?, expiry: Date?) {
        lock.withLock {
            if let at = accessToken { current.accessToken = at }
            if let rt = refreshToken { current.refreshToken = rt }
            current.expiry = expiry
        }
    }

    func clear() {
        lock.withLock { current = DriveTokens() }
    }

    /// Set in UserDefaults once tokens have been loaded on this install. UserDefaults goes with the app when it
    /// is deleted and a Keychain item does not, so a launch without the marker is a fresh install and drops
    /// any item a deleted copy left behind: deleting the app signs it out, as on Android.
    static let installMarkerKey = "driveTokenStoreInstalled"

    func load() {
        for key in Self.legacyDefaultsKeys { defaults.removeObject(forKey: key) }
        if !defaults.bool(forKey: Self.installMarkerKey) {
            _ = vault.delete()
            defaults.set(true, forKey: Self.installMarkerKey)
        }
        let stored = vault.read().flatMap { try? JSONDecoder().decode(DriveTokens.self, from: $0) }
        lock.withLock { current = stored ?? DriveTokens() }
    }

    /// Writes the current tokens, or deletes the item when there are none. False if the Keychain refused, in
    /// which case the tokens still work for this launch but the next one starts signed out (or, after a sign-out
    /// whose delete failed, signed in). Written under the lock so two persists cannot land out of order.
    @discardableResult
    func persist() -> Bool {
        lock.withLock {
            if current == DriveTokens() { return vault.delete() }
            guard let data = try? JSONEncoder().encode(current) else { return false }
            return vault.write(data)
        }
    }
}
