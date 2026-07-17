import Testing
import Foundation
import CoreGraphics
@testable import ArchiveNotes

/// W6-S1 — Notes browser layout/window persistence. Every test reads/writes a throwaway
/// `UserDefaults(suiteName:)` so `.standard` is never touched (deterministic, isolated) — mirrors
/// `ZoteroSettingsTests`. Covers defaults, the window-size persist/restore round-trip, panel-width
/// clamping, the tree-visibility toggle, and hidden-columns.
@Suite("NotesAppSettings")
struct NotesAppSettingsTests {

    /// A fresh, empty defaults domain unique to each test.
    private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let suite = "test.notes.layout.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: defaults

    @Test func emptyStoreYieldsDefaults() {
        let s = NotesLayoutSettings(reading: scratchDefaults())
        #expect(s.windowSize == nil)
        #expect(s.treeWidth == NotesLayoutSettings.defaultTreeWidth)
        #expect(s.detailWidth == NotesLayoutSettings.defaultDetailWidth)
        #expect(s.showTree == true)
        #expect(s.hiddenColumns.isEmpty)
    }

    // MARK: window size — persist/restore round-trip

    @Test func windowSizeRoundTrips() {
        let d = scratchDefaults()
        NotesAppSettings.setWindowSize(CGSize(width: 1200, height: 800), into: d)
        #expect(NotesLayoutSettings(reading: d).windowSize == CGSize(width: 1200, height: 800))
    }

    @Test func windowSizeBelowFloorIsUnset() {
        let d = scratchDefaults()
        // A garbage/zero frame (below the sanity floor) must resolve to nil, not a 10×10 window.
        NotesAppSettings.setWindowSize(CGSize(width: 10, height: 10), into: d)
        #expect(NotesLayoutSettings(reading: d).windowSize == nil)
    }

    @Test func windowSizeUnsetWhenOnlyOneDimensionSaved() {
        let d = scratchDefaults()
        d.set(1200.0, forKey: NotesLayoutSettingsKey.windowW)   // height never saved → treat as unset
        #expect(NotesLayoutSettings(reading: d).windowSize == nil)
    }

    // MARK: panel-width clamping

    @Test func treeWidthClampsBelowMin() {
        let d = scratchDefaults()
        d.set(50.0, forKey: NotesLayoutSettingsKey.treeWidth)
        #expect(NotesLayoutSettings(reading: d).treeWidth == NotesLayoutSettings.treeWidthMin)
    }

    @Test func treeWidthClampsAboveMax() {
        let d = scratchDefaults()
        d.set(9999.0, forKey: NotesLayoutSettingsKey.treeWidth)
        #expect(NotesLayoutSettings(reading: d).treeWidth == NotesLayoutSettings.treeWidthMax)
    }

    @Test func treeWidthInRangeIsVerbatim() {
        let d = scratchDefaults()
        d.set(275.0, forKey: NotesLayoutSettingsKey.treeWidth)
        #expect(NotesLayoutSettings(reading: d).treeWidth == 275.0)
    }

    @Test func detailWidthClampsBothEnds() {
        let lo = scratchDefaults()
        lo.set(10.0, forKey: NotesLayoutSettingsKey.detailWidth)
        #expect(NotesLayoutSettings(reading: lo).detailWidth == NotesLayoutSettings.detailWidthMin)

        let hi = scratchDefaults()
        hi.set(5000.0, forKey: NotesLayoutSettingsKey.detailWidth)
        #expect(NotesLayoutSettings(reading: hi).detailWidth == NotesLayoutSettings.detailWidthMax)
    }

    @Test func widthRangesAreConsistentWithDefaults() {
        // The persisted default must sit inside the divider's clamp range, else a fresh install
        // would immediately clamp on first read.
        #expect(NotesLayoutSettings.treeWidthRange.contains(CGFloat(NotesLayoutSettings.defaultTreeWidth)))
        #expect(NotesLayoutSettings.detailWidthRange.contains(CGFloat(NotesLayoutSettings.defaultDetailWidth)))
    }

    // MARK: tree toggle

    @Test func showTreeRoundTripsFalse() {
        let d = scratchDefaults()
        d.set(false, forKey: NotesLayoutSettingsKey.showTree)
        #expect(NotesLayoutSettings(reading: d).showTree == false)
    }

    // MARK: hidden columns

    @Test func hiddenColumnsRoundTrip() {
        let d = scratchDefaults()
        NotesAppSettings.setHiddenColumns(["tags", "quality"], into: d)
        #expect(NotesLayoutSettings(reading: d).hiddenColumns == ["tags", "quality"])
    }

    @Test func hiddenColumnsEmptyByDefault() {
        #expect(NotesLayoutSettings(reading: scratchDefaults()).hiddenColumns.isEmpty)
    }

    // MARK: per-window kind featuring (W7-S4)

    @Test func windowKindDefaultsToNilUnset() {
        let d = scratchDefaults()
        #expect(NotesAppSettings.windowKindFilter(for: .note, from: d) == nil)
        #expect(NotesAppSettings.windowKindFilter(for: .extract, from: d) == nil)
    }

    @Test func windowKindRoundTripsPerWindowIndependently() {
        let d = scratchDefaults()
        NotesAppSettings.setWindowKindFilter(.both, for: .note, into: d)
        NotesAppSettings.setWindowKindFilter(.notes, for: .extract, into: d)
        // The two windows persist under distinct keys — neither clobbers the other.
        #expect(NotesAppSettings.windowKindFilter(for: .note, from: d) == .both)
        #expect(NotesAppSettings.windowKindFilter(for: .extract, from: d) == .notes)
    }

    @Test func windowKindUnrecognizedRawValueIsNil() {
        let d = scratchDefaults()
        d.set("nonsense", forKey: NotesLayoutSettingsKey.noteWindowKind)
        #expect(NotesAppSettings.windowKindFilter(for: .note, from: d) == nil)   // → caller uses default
    }

    // MARK: per-window hidden columns (W14.4)

    @Test func windowHiddenColumnsDefaultHidesSourcesInNoteWindowOnly() {
        let d = scratchDefaults()   // never toggled → per-window defaults apply
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["sources"])
        #expect(NotesAppSettings.windowHiddenColumns(for: .extract, from: d).isEmpty)
    }

    @Test func windowHiddenColumnsRoundTripsPerWindowIndependently() {
        let d = scratchDefaults()
        NotesAppSettings.setWindowHiddenColumns(["tags"], for: .note, into: d)
        NotesAppSettings.setWindowHiddenColumns(["quality", "instances"], for: .extract, into: d)
        // Distinct keys — neither window clobbers the other.
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["tags"])
        #expect(NotesAppSettings.windowHiddenColumns(for: .extract, from: d) == ["quality", "instances"])
    }

    @Test func windowHiddenColumnsExplicitEmptyOverridesDefault() {
        let d = scratchDefaults()
        // A user un-hiding everything in the Note window persists an empty set — that means "show all",
        // NOT "fall back to the sources-hidden default".
        NotesAppSettings.setWindowHiddenColumns([], for: .note, into: d)
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d).isEmpty)
    }

    @Test func windowHiddenColumnsSeedFromLegacyGlobalOnFirstOpen() {
        let d = scratchDefaults()
        // Pre-W14.4 upgrade path: a legacy global hidden set seeds the first-open per-window default,
        // unioned with the window default (Note window also hides the blank "sources" column).
        NotesAppSettings.setHiddenColumns(["tags"], into: d)
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["tags", "sources"])
        #expect(NotesAppSettings.windowHiddenColumns(for: .extract, from: d) == ["tags"])
    }
}
