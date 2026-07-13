import Foundation

/// `UserDefaults` keys for the Notes Zotero integration options (05-zotero §D.8).
/// Kept in one place so the Options UI and the models agree — mirrors ArchiveReader's
/// `SettingsKey` pattern (`Core/AppSettings.swift`).
enum ZoteroSettingsKey {
    static let enabled = "notes.zotero.enabled"
    static let clipboardDetect = "notes.zotero.clipboardDetect"
    static let host = "notes.zotero.host"
    static let port = "notes.zotero.port"
    static let styleID = "notes.zotero.cslStyleID"
}

/// Resolved, validated Zotero settings. A pure value type so the resolution logic is
/// testable against a scratch `UserDefaults` without touching `.standard` (05-zotero §D.8).
///
/// Empty/blank host or style and out-of-range ports fall back to the defaults, so a
/// half-cleared Options field can never break probing.
struct ZoteroSettings: Equatable, Sendable {
    var enabled: Bool
    var clipboardDetect: Bool
    var host: String
    var port: Int
    var styleID: String

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 23119
    static let defaultStyleID = "chicago-note-bibliography"

    static let `default` = ZoteroSettings(
        enabled: true, clipboardDetect: true,
        host: defaultHost, port: defaultPort, styleID: defaultStyleID)

    init(enabled: Bool, clipboardDetect: Bool, host: String, port: Int, styleID: String) {
        self.enabled = enabled
        self.clipboardDetect = clipboardDetect
        self.host = host
        self.port = port
        self.styleID = styleID
    }

    /// Read + validate from a defaults store (point-of-use).
    init(reading d: UserDefaults) {
        enabled = d.object(forKey: ZoteroSettingsKey.enabled) as? Bool ?? true
        clipboardDetect = d.object(forKey: ZoteroSettingsKey.clipboardDetect) as? Bool ?? true

        let h = (d.string(forKey: ZoteroSettingsKey.host) ?? "").trimmingCharacters(in: .whitespaces)
        host = h.isEmpty ? Self.defaultHost : h

        let p = d.object(forKey: ZoteroSettingsKey.port) as? Int ?? Self.defaultPort
        port = (1...65535).contains(p) ? p : Self.defaultPort

        let s = (d.string(forKey: ZoteroSettingsKey.styleID) ?? "").trimmingCharacters(in: .whitespaces)
        styleID = s.isEmpty ? Self.defaultStyleID : s
    }

    /// The `ZoteroClient.Config` derived from host/port (timeout keeps the client default).
    var clientConfig: ZoteroClient.Config {
        ZoteroClient.Config(host: host, port: port)
    }
}

/// Point-of-use accessor over `UserDefaults.standard`, mirroring ArchiveReader's `AppSettings`.
/// Models read `ZoteroSettingsStore.current` at each action so an Options change takes effect
/// on the next probe/detect without any observation plumbing.
enum ZoteroSettingsStore {
    private static var d: UserDefaults { .standard }

    static var current: ZoteroSettings { ZoteroSettings(reading: d) }

    static func setEnabled(_ v: Bool) { d.set(v, forKey: ZoteroSettingsKey.enabled) }
    static func setClipboardDetect(_ v: Bool) { d.set(v, forKey: ZoteroSettingsKey.clipboardDetect) }
    static func setHost(_ v: String) { d.set(v, forKey: ZoteroSettingsKey.host) }
    static func setPort(_ v: Int) { d.set(v, forKey: ZoteroSettingsKey.port) }
    static func setStyleID(_ v: String) { d.set(v, forKey: ZoteroSettingsKey.styleID) }
}
