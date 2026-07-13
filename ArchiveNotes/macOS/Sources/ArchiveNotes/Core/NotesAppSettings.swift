import Foundation
import CoreGraphics

/// `UserDefaults` keys for the Notes browser layout + window state (W6-S1). Kept in one place so
/// the shell view and the persistence accessor agree — mirrors ArchiveReader's `SettingsKey`
/// (`Core/AppSettings.swift`) and the Notes `ZoteroSettingsKey` idiom. `an.`-prefixed to stay clear
/// of Reader's `ar.` keys (distinct bundle domains already isolate them; the prefix is
/// belt-and-suspenders + self-documenting, per 06-viewers §1).
enum NotesLayoutSettingsKey {
    static let windowW = "an.windowWidth"
    static let windowH = "an.windowHeight"
    static let treeWidth = "an.treeWidth"
    static let detailWidth = "an.detailWidth"
    static let showTree = "an.showTree"
    static let hiddenColumns = "an.hiddenColumns"   // [String] — item-list columns hidden (W6-S3)
}

/// Resolved, validated Notes layout/window settings. A pure value type so the resolution logic is
/// testable against a scratch `UserDefaults` without touching `.standard` (mirrors `ZoteroSettings`).
///
/// Out-of-range panel widths clamp to their divider range (a corrupt/foreign value can never wedge
/// the layout); a never-saved or undersized window size resolves to `nil` → the window opens at its
/// default size.
struct NotesLayoutSettings: Equatable, Sendable {
    var windowSize: CGSize?
    var treeWidth: Double
    var detailWidth: Double
    var showTree: Bool
    var hiddenColumns: Set<String>

    static let defaultTreeWidth = 220.0,  treeWidthMin = 160.0,  treeWidthMax = 400.0
    static let defaultDetailWidth = 360.0, detailWidthMin = 260.0, detailWidthMax = 700.0
    /// A saved window dimension below this is treated as "unset" (guards a zero/garbage frame).
    static let windowFloor = 200.0

    /// The divider clamp ranges, as `CGFloat` for `PanelDivider` (the layout's single source of truth).
    static var treeWidthRange: ClosedRange<CGFloat> { CGFloat(treeWidthMin)...CGFloat(treeWidthMax) }
    static var detailWidthRange: ClosedRange<CGFloat> { CGFloat(detailWidthMin)...CGFloat(detailWidthMax) }

    init(windowSize: CGSize?, treeWidth: Double, detailWidth: Double,
         showTree: Bool, hiddenColumns: Set<String>) {
        self.windowSize = windowSize
        self.treeWidth = treeWidth
        self.detailWidth = detailWidth
        self.showTree = showTree
        self.hiddenColumns = hiddenColumns
    }

    /// Read + validate from a defaults store (point-of-use).
    init(reading d: UserDefaults) {
        let w = d.double(forKey: NotesLayoutSettingsKey.windowW)
        let h = d.double(forKey: NotesLayoutSettingsKey.windowH)
        windowSize = (w > Self.windowFloor && h > Self.windowFloor) ? CGSize(width: w, height: h) : nil

        let tw = d.object(forKey: NotesLayoutSettingsKey.treeWidth) as? Double ?? Self.defaultTreeWidth
        treeWidth = min(Self.treeWidthMax, max(Self.treeWidthMin, tw))

        let dw = d.object(forKey: NotesLayoutSettingsKey.detailWidth) as? Double ?? Self.defaultDetailWidth
        detailWidth = min(Self.detailWidthMax, max(Self.detailWidthMin, dw))

        showTree = d.object(forKey: NotesLayoutSettingsKey.showTree) as? Bool ?? true
        hiddenColumns = Set(d.stringArray(forKey: NotesLayoutSettingsKey.hiddenColumns) ?? [])
    }
}

/// Point-of-use accessor over `UserDefaults.standard`, mirroring `ZoteroSettingsStore` and
/// ArchiveReader's `AppSettings`. The shell persists the window size here on close and restores it
/// on open (DV-1 pattern); the live panel-width binding uses `@AppStorage` over the same keys.
enum NotesAppSettings {
    private static var d: UserDefaults { .standard }

    static var current: NotesLayoutSettings { NotesLayoutSettings(reading: d) }

    /// Remembered browser-window size. `nil` until the window has been resized past the sanity floor.
    /// `into:` is injectable so the persist/restore round-trip is testable against a scratch domain.
    static var windowSize: CGSize? { current.windowSize }
    static func setWindowSize(_ s: CGSize, into store: UserDefaults = .standard) {
        store.set(Double(s.width), forKey: NotesLayoutSettingsKey.windowW)
        store.set(Double(s.height), forKey: NotesLayoutSettingsKey.windowH)
    }

    /// Item-list columns the user has hidden (W6-S3 consumes this; the key lives here so the layout
    /// key set is centralized). Mirrors Reader's `AppSettings.hiddenColumns`.
    static var hiddenColumns: Set<String> { current.hiddenColumns }
    static func setHiddenColumns(_ hidden: Set<String>, into store: UserDefaults = .standard) {
        store.set(Array(hidden).sorted(), forKey: NotesLayoutSettingsKey.hiddenColumns)
    }
}
