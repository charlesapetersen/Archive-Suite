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
        NotesAppSettings.setWindowKindFilter(.all, for: .note, into: d)
        NotesAppSettings.setWindowKindFilter(.notes, for: .extract, into: d)
        // The two windows persist under distinct keys — neither clobbers the other.
        #expect(NotesAppSettings.windowKindFilter(for: .note, from: d) == .all)
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
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["sources", "sentWith"])
        #expect(NotesAppSettings.windowHiddenColumns(for: .extract, from: d) == ["sentWith"])
    }

    /// W40.suite-date-design: the Sent-with column is opt-in. A set saved before it existed keeps it hidden; once
    /// shown, it stays shown across a save and a load, in that window only.
    @Test func sentWithColumnIsHiddenUntilShown() {
        let d = scratchDefaults()
        d.set(["tags"], forKey: NotesLayoutSettingsKey.noteWindowHiddenColumns)   // saved before the column
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["tags", "sentWith"])
        NotesAppSettings.setWindowHiddenColumns(["tags"], for: .note, into: d)    // the user shows it
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["tags"])
        #expect(NotesAppSettings.windowHiddenColumns(for: .extract, from: d) == ["sentWith"])
        NotesAppSettings.setWindowHiddenColumns(["tags", "sentWith"], for: .note, into: d)   // and hides it again
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["tags", "sentWith"])
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
        #expect(NotesAppSettings.windowHiddenColumns(for: .note, from: d) == ["tags", "sources", "sentWith"])
        #expect(NotesAppSettings.windowHiddenColumns(for: .extract, from: d) == ["tags", "sentWith"])
    }

    /// W40.notes-detail-layout: the inspector panel is shown by default, and its width clamps like the others.
    @Test func inspectorDefaultsShownAndClampsItsWidth() {
        let d = scratchDefaults()
        #expect(NotesLayoutSettings(reading: d).showInspector == true)
        #expect(NotesLayoutSettings(reading: d).inspectorWidth == NotesLayoutSettings.defaultInspectorWidth)
        #expect(NotesLayoutSettings.inspectorWidthRange.contains(CGFloat(NotesLayoutSettings.defaultInspectorWidth)))
        d.set(false, forKey: NotesLayoutSettingsKey.showInspector)
        d.set(10.0, forKey: NotesLayoutSettingsKey.inspectorWidth)
        #expect(NotesLayoutSettings(reading: d).showInspector == false)
        #expect(NotesLayoutSettings(reading: d).inspectorWidth == NotesLayoutSettings.inspectorWidthMin)
        d.set(5000.0, forKey: NotesLayoutSettingsKey.inspectorWidth)
        #expect(NotesLayoutSettings(reading: d).inspectorWidth == NotesLayoutSettings.inspectorWidthMax)
    }

    /// W40.notes-window-panes: the formatting bar, the note header and the tag bar are shown until hidden, each
    /// under its own `an.` key, apart from the panels' keys.
    @Test func notePanePartsDefaultShownAndRoundTrip() {
        let d = scratchDefaults()
        let shown = NotesLayoutSettings(reading: d)
        #expect(shown.showFormattingBar && shown.showNoteHeader && shown.showTagBar)
        d.set(false, forKey: NotesLayoutSettingsKey.showFormattingBar)
        #expect(NotesLayoutSettings(reading: d).showFormattingBar == false)
        #expect(NotesLayoutSettings(reading: d).showNoteHeader && NotesLayoutSettings(reading: d).showTagBar)
        d.set(false, forKey: NotesLayoutSettingsKey.showNoteHeader)
        d.set(false, forKey: NotesLayoutSettingsKey.showTagBar)
        let hidden = NotesLayoutSettings(reading: d)
        #expect(!hidden.showNoteHeader && !hidden.showTagBar)
        let keys = [NotesLayoutSettingsKey.showFormattingBar, NotesLayoutSettingsKey.showNoteHeader,
                    NotesLayoutSettingsKey.showTagBar]
        #expect(keys == ["an.showFormattingBar", "an.showNoteHeader", "an.showTagBar"])
        #expect(Set(keys).isDisjoint(with: [NotesLayoutSettingsKey.showTree, NotesLayoutSettingsKey.showInspector]))
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
                      NotesLayoutSettingsKey.showInspector, NotesLayoutSettingsKey.inspectorWidth]
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
        #expect(NotesLayoutSettings.listHeightRange == 160...1600)
        #expect(NotesLayoutSettings.listHeightRange.contains(CGFloat(NotesLayoutSettings.defaultListHeight)))
        #expect(NotesLayoutSettings.stackedMinHeight == 487)
    }

    /// The VM's 612 pt window squeezed the stacked editor to 9 pt: the list must give way to the note first.
    @Test func stackedListGivesWayToTheNote() {
        // Not measured yet: only the remembered value's own clamp applies.
        #expect(NotesLayoutSettings.stackedListHeight(stored: 300, paneHeight: 0) == 300)
        #expect(NotesLayoutSettings.stackedListRange(paneHeight: 0) == NotesLayoutSettings.listHeightRange)
        // Going down, only the note's floor stops the list: a 1200 pt pane gives it 873, a 2400 pt one the ceiling.
        #expect(NotesLayoutSettings.stackedListHeight(stored: 440, paneHeight: 1200) == 440)
        #expect(NotesLayoutSettings.stackedListHeight(stored: 900, paneHeight: 1200) == 873)
        #expect(NotesLayoutSettings.stackedListRange(paneHeight: 1200) == 160...873)
        #expect(NotesLayoutSettings.stackedListRange(paneHeight: 2400) == 160...1600)
        // A 900 pt pane: the note keeps 320 (480 before its fields moved to the inspector, W40.notes-detail-layout),
        // the list gets what is left (573), never below its floor.
        #expect(NotesLayoutSettings.stackedListHeight(stored: 440, paneHeight: 900) == 440)
        #expect(NotesLayoutSettings.stackedListHeight(stored: 700, paneHeight: 900) == 573)
        #expect(NotesLayoutSettings.stackedListRange(paneHeight: 900) == 160...573)
        #expect(NotesLayoutSettings.stackedListHeight(stored: 300, paneHeight: 450) == 160)
        #expect(NotesLayoutSettings.stackedListRange(paneHeight: 450) == 160...160)
        // Whatever the pane, list + divider + note fit whenever the pane is at least the stacked minimum.
        for pane in stride(from: NotesLayoutSettings.stackedMinHeight, through: 1400, by: 37) {
            for stored in [0.0, 140, 160, 220, 240, 440, 900, 9000, .nan] {
                let list = NotesLayoutSettings.stackedListHeight(stored: stored, paneHeight: pane)
                #expect(list + 7 + NotesLayoutSettings.stackedDetailMinHeight <= pane + 0.001)
                #expect(list >= NotesLayoutSettings.listHeightMin)
            }
        }
    }
}
