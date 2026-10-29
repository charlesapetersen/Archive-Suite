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

    @Test func uiTestWindowCloseDoesNotOverwriteSharedWindowSize() {
        let d = scratchDefaults()
        let remembered = CGSize(width: 1200, height: 800)
        NotesAppSettings.setWindowSize(remembered, into: d)

        // The harness closes the auto-opened Extracts scene before every test. Its frame must never
        // become the shared size both Notes and Extracts restore from; an ordinary close still writes.
        NotesAppSettings.persistWindowSizeOnDisappear(
            CGSize(width: 640, height: 560),
            isUITestHarness: true,
            into: d
        )
        #expect(NotesLayoutSettings(reading: d).windowSize == remembered)

        let ordinaryClose = CGSize(width: 1280, height: 900)
        NotesAppSettings.persistWindowSizeOnDisappear(
            ordinaryClose,
            isUITestHarness: false,
            into: d
        )
        #expect(NotesLayoutSettings(reading: d).windowSize == ordinaryClose)
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

    /// W40.fix-notes-editor-squeezed: the metadata inspector takes a quarter of the detail pane, between
    /// a floor and the old 280 pt ceiling, so a short window no longer leaves the editor about 100 pt.
    @Test func metadataHeightScalesWithThePane() {
        #expect(DetailPaneLayout.metadataMaxHeight(paneHeight: 500) == 125)   // minimum window
        #expect(DetailPaneLayout.metadataMaxHeight(paneHeight: 840) == 210)   // 1440×900
        #expect(DetailPaneLayout.metadataMaxHeight(paneHeight: 2000) == 280)  // capped
        #expect(DetailPaneLayout.metadataMaxHeight(paneHeight: 200) == 90)    // floored
        // The editor keeps the larger share of what the metadata could take.
        for h in stride(from: CGFloat(500), through: 1400, by: 100) {
            #expect(DetailPaneLayout.metadataMaxHeight(paneHeight: h) <= h / 2)
        }
    }

    // MARK: stacked layout (W48.notes-stacked-layout)

    @Test func layoutModeDefaultsToSideBySideAndRoundTrips() {
        let d = scratchDefaults()
        #expect(NotesLayoutSettings(reading: d).layoutMode == .sideBySide)
        #expect(NotesLayoutSettings(reading: d).listHeight == NotesLayoutSettings.defaultListHeight)
        // `@AppStorage` stores the enum's raw value under the same key the settings read.
        d.set(NotesLayoutMode.stacked.rawValue, forKey: NotesLayoutSettingsKey.layoutMode)
        #expect(NotesLayoutSettings(reading: d).layoutMode == .stacked)
        d.set("diagonal", forKey: NotesLayoutSettingsKey.layoutMode)   // foreign value → the default
        #expect(NotesLayoutSettings(reading: d).layoutMode == .sideBySide)
    }

    @Test func layoutModeKeysAreDistinctAndPrefixed() {
        let keys = [NotesLayoutSettingsKey.layoutMode, NotesLayoutSettingsKey.listHeight]
        #expect(keys == ["an.layoutMode", "an.listHeight"])
        let others = [NotesLayoutSettingsKey.windowW, NotesLayoutSettingsKey.windowH, NotesLayoutSettingsKey.treeWidth,
                      NotesLayoutSettingsKey.detailWidth, NotesLayoutSettingsKey.showTree,
                      NotesLayoutSettingsKey.metadataCollapsed]
        #expect(Set(keys).isDisjoint(with: others))
        #expect(NotesLayoutMode.allCases.map(\.title) == ["Side by Side", "List Above Note"])
    }

    @Test func listHeightClampsLikeTheWidths() {
        let d = scratchDefaults()
        d.set(10.0, forKey: NotesLayoutSettingsKey.listHeight)
        #expect(NotesLayoutSettings(reading: d).listHeight == NotesLayoutSettings.listHeightMin)
        d.set(5000.0, forKey: NotesLayoutSettingsKey.listHeight)
        #expect(NotesLayoutSettings(reading: d).listHeight == NotesLayoutSettings.listHeightMax)
        d.set(300.0, forKey: NotesLayoutSettingsKey.listHeight)
        #expect(NotesLayoutSettings(reading: d).listHeight == 300)
        // The view lays out through the same clamp, and a non-number never becomes a height.
        #expect(NotesLayoutSettings.clampedListHeight(-1) == NotesLayoutSettings.listHeightMin)
        #expect(NotesLayoutSettings.clampedListHeight(.nan) == NotesLayoutSettings.defaultListHeight)
        #expect(NotesLayoutSettings.clampedListHeight(.infinity) == NotesLayoutSettings.defaultListHeight)
        #expect(NotesLayoutSettings.listHeightRange == 140...440)
        #expect(NotesLayoutSettings.listHeightRange.contains(CGFloat(NotesLayoutSettings.defaultListHeight)))
        // At its tallest the list still leaves the note its floor inside a laptop-height window.
        #expect(NotesLayoutSettings.listHeightMax + 7 + NotesLayoutSettings.stackedDetailMinHeight < 800)
    }
}
