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
    // Per-window kind featuring (W7-S4, 07-extracts §4): the Note vs Extract window each remember the
    // last kind their segmented control showed, separately.
    static let noteWindowKind = "an.noteWindow.kindFilter"
    static let extractWindowKind = "an.extractWindow.kindFilter"
    // Per-window hidden columns (W14.4): each window remembers its own hidden-column set so the
    // extract-only "sources" column can default hidden in the Note window (always blank there) while
    // staying visible in the Extracts window. `hiddenColumns` above stays as the pre-W14.4 global
    // legacy key (now read-only — it seeds a first-open per-window default).
    static let noteWindowHiddenColumns = "an.noteWindow.hiddenColumns"
    static let extractWindowHiddenColumns = "an.extractWindow.hiddenColumns"
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

    /// The `KindFilter` the given window last showed (W7-S4, 07-extracts §4). Each window features its
    /// own kind by default (Note→`.notes`, Extract→`.extracts`); once the user retargets the segmented
    /// control, that choice is remembered per window. `nil` (never set / unrecognized raw value) ⟹ the
    /// caller falls back to the window default. `from:`/`into:` injectable so the round-trip is testable
    /// against a scratch domain (mirrors `setWindowSize` / `setHiddenColumns`).
    static func windowKindFilter(for windowKind: Item.Kind, from store: UserDefaults = .standard) -> KindFilter? {
        store.string(forKey: kindKey(windowKind)).flatMap(KindFilter.init(rawValue:))
    }
    static func setWindowKindFilter(_ kind: KindFilter, for windowKind: Item.Kind, into store: UserDefaults = .standard) {
        store.set(kind.rawValue, forKey: kindKey(windowKind))
    }
    private static func kindKey(_ windowKind: Item.Kind) -> String {
        windowKind == .extract ? NotesLayoutSettingsKey.extractWindowKind : NotesLayoutSettingsKey.noteWindowKind
    }

    /// Item-list columns hidden in the given window (W14.4). Visibility is remembered per window
    /// (mirrors `windowKindFilter`), so the extract-only **Sources** column defaults to hidden in the
    /// Note window — where `sourcesText` is always blank — while staying visible in the Extracts
    /// window. When a window's key is unset (never toggled) the per-window `defaultHiddenColumns`
    /// apply; once the user toggles any column in the header picker, that window's explicit set is
    /// persisted and used verbatim (an explicitly-empty set ⟹ "show all", distinct from "never set").
    /// `from:`/`into:` injectable so the round-trip is testable against a scratch domain.
    static func windowHiddenColumns(for windowKind: Item.Kind, from store: UserDefaults = .standard) -> Set<String> {
        if let saved = store.stringArray(forKey: hiddenColumnsKey(windowKind)) {
            return Set(saved)   // explicit per-window choice (an empty array = user showed everything)
        }
        let legacy = Set(store.stringArray(forKey: NotesLayoutSettingsKey.hiddenColumns) ?? [])
        return defaultHiddenColumns(for: windowKind, legacy: legacy)
    }
    static func setWindowHiddenColumns(_ hidden: Set<String>, for windowKind: Item.Kind, into store: UserDefaults = .standard) {
        store.set(Array(hidden).sorted(), forKey: hiddenColumnsKey(windowKind))
    }
    /// The hidden-column set for a freshly-opened window (no explicit per-window choice yet): the Note
    /// window hides the always-blank "sources" column; the Extract window hides nothing. Any `legacy`
    /// global hides (the pre-W14.4 shared key) are folded in so an upgrading user keeps prior choices.
    static func defaultHiddenColumns(for windowKind: Item.Kind, legacy: Set<String> = []) -> Set<String> {
        let base: Set<String> = windowKind == .extract ? [] : ["sources"]
        return base.union(legacy)
    }
    private static func hiddenColumnsKey(_ windowKind: Item.Kind) -> String {
        windowKind == .extract ? NotesLayoutSettingsKey.extractWindowHiddenColumns : NotesLayoutSettingsKey.noteWindowHiddenColumns
    }
}
