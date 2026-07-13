import Testing
import Foundation
@testable import ArchiveNotes

/// W5-S5 — Zotero settings resolution + validation (05-zotero §D.8). All tests read from a
/// throwaway `UserDefaults(suiteName:)` so `.standard` is never touched (deterministic, isolated).
@Suite("ZoteroSettings")
struct ZoteroSettingsTests {

    /// A fresh, empty defaults domain unique to each test.
    private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let suite = "test.zotero.settings.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func emptyStoreYieldsDefaults() {
        let s = ZoteroSettings(reading: scratchDefaults())
        #expect(s == ZoteroSettings.default)
        #expect(s.enabled)
        #expect(s.clipboardDetect)
        #expect(s.host == "127.0.0.1")
        #expect(s.port == 23119)
        #expect(s.styleID == "chicago-note-bibliography")
    }

    @Test func storedValuesRoundTrip() {
        let d = scratchDefaults()
        d.set(false, forKey: ZoteroSettingsKey.enabled)
        d.set(false, forKey: ZoteroSettingsKey.clipboardDetect)
        d.set("192.168.0.5", forKey: ZoteroSettingsKey.host)
        d.set(24119, forKey: ZoteroSettingsKey.port)
        d.set("apa", forKey: ZoteroSettingsKey.styleID)

        let s = ZoteroSettings(reading: d)
        #expect(s.enabled == false)
        #expect(s.clipboardDetect == false)
        #expect(s.host == "192.168.0.5")
        #expect(s.port == 24119)
        #expect(s.styleID == "apa")
    }

    @Test func blankHostFallsBackToDefault() {
        let d = scratchDefaults()
        d.set("   ", forKey: ZoteroSettingsKey.host)
        #expect(ZoteroSettings(reading: d).host == ZoteroSettings.defaultHost)
    }

    @Test func hostWhitespaceIsTrimmed() {
        let d = scratchDefaults()
        d.set("  10.0.0.2  ", forKey: ZoteroSettingsKey.host)
        #expect(ZoteroSettings(reading: d).host == "10.0.0.2")
    }

    @Test func blankStyleFallsBackToDefault() {
        let d = scratchDefaults()
        d.set("", forKey: ZoteroSettingsKey.styleID)
        #expect(ZoteroSettings(reading: d).styleID == ZoteroSettings.defaultStyleID)
    }

    @Test func outOfRangePortFallsBackToDefault() {
        let d = scratchDefaults()
        d.set(0, forKey: ZoteroSettingsKey.port)
        #expect(ZoteroSettings(reading: d).port == 23119)
        d.set(70000, forKey: ZoteroSettingsKey.port)
        #expect(ZoteroSettings(reading: d).port == 23119)
    }

    @Test func inRangePortIsAccepted() {
        let d = scratchDefaults()
        d.set(80, forKey: ZoteroSettingsKey.port)
        #expect(ZoteroSettings(reading: d).port == 80)
        d.set(65535, forKey: ZoteroSettingsKey.port)
        #expect(ZoteroSettings(reading: d).port == 65535)
    }

    @Test func clientConfigDerivesHostAndPort() {
        let s = ZoteroSettings(enabled: true, clipboardDetect: true,
                               host: "10.0.0.9", port: 24120, styleID: "apa")
        let cfg = s.clientConfig
        #expect(cfg.host == "10.0.0.9")
        #expect(cfg.port == 24120)
    }

    /// Default settings drive the client at the canonical localhost endpoint.
    @Test func defaultClientConfigIsLocalhost() {
        let cfg = ZoteroSettings.default.clientConfig
        #expect(cfg.host == "127.0.0.1")
        #expect(cfg.port == 23119)
    }
}
