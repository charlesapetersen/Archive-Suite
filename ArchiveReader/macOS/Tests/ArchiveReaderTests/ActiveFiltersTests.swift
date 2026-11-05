import XCTest
@testable import ArchiveReader

/// W40.fix-reader-filter-bar (reader-1 row 8): every filter and search in effect is a removable chip, and an
/// empty list caused by one says which and offers to clear it. The owner searched a name, chose another folder
/// in the tree, and saw an empty list without noticing the search still applied. Scratch `mktemp` fixtures only.
@MainActor
final class ActiveFiltersTests: XCTestCase {

    // MARK: chips (pure)

    func testNothingInEffectGivesNoChips() {
        XCTAssertTrue(ActiveFilterChip.chips(filter: LibraryFilter(), smartFolderName: nil, fullTextQuery: nil).isEmpty)
    }

    func testEveryFacetInEffectIsAChipInTheBarsOrder() {
        var f = LibraryFilter()
        f.pathPrefix = "/scratch/Box 3"
        f.read = .unread
        f.qualities = [2, 1]
        f.subjects = ["Smith"]
        f.dateFromYear = 1950; f.dateToYear = 1960
        f.searchText = " memo "
        f.needsAttentionOnly = true
        f.ambiguousDatesOnly = true
        let chips = ActiveFilterChip.chips(filter: f, smartFolderName: "Drafts", fullTextQuery: "fox")
        XCTAssertEqual(chips.map(\.facet), [.smartFolder, .folder, .read, .quality(1), .quality(2), .tag("Smith"),
                                            .dates, .name, .text, .needsAttention, .ambiguousDates])
        XCTAssertEqual(chips.map(\.label), ["Smart folder: Drafts", "Folder: Box 3", "Unread", "Q1", "Q2", "Tag: Smith",
                                            "Years: 1950\u{2013}1960", "Name: memo", "Text: \u{201c}fox\u{201d}",
                                            "Needs attention", "Ambiguous dates"])
        // the health filters keep the identifiers their toggles had, which the UI tests click
        XCTAssertEqual(chips.last?.accessibilityIdentifier, "ar.filter.ambiguousDates")
    }

    func testAnOCRQueryWhoseResultsAreNotInIsNotYetAChip() {
        XCTAssertTrue(ActiveFilterChip.chips(filter: LibraryFilter(), smartFolderName: nil, fullTextQuery: nil).isEmpty)
        XCTAssertTrue(ActiveFilterChip.chips(filter: LibraryFilter(), smartFolderName: nil, fullTextQuery: "  ").isEmpty)
    }

    func testRemovingAFacetTurnsOffThatOneOnly() {
        var f = LibraryFilter()
        f.subjects = ["A", "B"]; f.qualities = [1, 3]; f.searchText = "x"; f.pathPrefix = "/p"
        let g = f.removing(.tag("A")).removing(.quality(3)).removing(.name)
        XCTAssertEqual(g.subjects, ["B"]); XCTAssertEqual(g.qualities, [1])
        XCTAssertEqual(g.searchText, ""); XCTAssertEqual(g.pathPrefix, "/p")
        XCTAssertNil(f.removing(.folder).pathPrefix)
    }

    // MARK: the empty list's sentence (pure)

    private func chips(_ f: LibraryFilter) -> [ActiveFilterChip] {
        ActiveFilterChip.chips(filter: f, smartFolderName: nil, fullTextQuery: nil)
    }

    func testOneCauseIsNamedWithTheFolderTheListIsLookingIn() {
        var f = LibraryFilter(); f.pathPrefix = "/scratch/Jones"; f.searchText = "smith"
        XCTAssertEqual(ActiveFilterChip.emptyExplanation(chips: chips(f), causes: [.name]),
                       "The file-name filter \u{201c}smith\u{201d} hides every file in the folder \u{201c}Jones\u{201d}.")
    }

    func testSeveralCausesAndNoSingleCause() {
        var f = LibraryFilter(); f.read = .read; f.qualities = [1]
        XCTAssertEqual(ActiveFilterChip.emptyExplanation(chips: chips(f), causes: [.read, .quality(1)]),
                       "Each of these hides every file: Read \u{b7} Q1.")
        XCTAssertEqual(ActiveFilterChip.emptyExplanation(chips: chips(f), causes: []),
                       "No file matches these together: Read \u{b7} Q1.")
    }

    // MARK: the owner's case, on the model

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ActiveFiltersTests-root-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (folder, name) in [("Smith", "Smith letter.pdf"), ("Jones", "Jones memo.pdf")] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        return root
    }

    func testANameSearchCarriedIntoAnotherFolderIsBlamedAndClearingItBringsTheRowsBack() throws {
        let root = try makeRoot()
        let model = fixtureNavigationModel(pinnedTo: root)
        model.filter.read = .all
        model.recompute()
        XCTAssertEqual(model.displayed.count, 2, "precondition: both files are listed")
        XCTAssertTrue(model.emptyListCauses.isEmpty)

        model.filter.searchText = "smith"
        model.recompute()
        XCTAssertEqual(model.displayed.map(\.name), ["Smith letter.pdf"])

        let jones = model.displayed[0].path.replacingOccurrences(of: "/Smith/Smith letter.pdf", with: "/Jones")
        model.setFolderScope(jones)
        XCTAssertTrue(model.displayed.isEmpty, "precondition: the search still applies in the new folder")
        XCTAssertEqual(model.activeFilterChips.map(\.facet), [.folder, .name], "both are shown in effect")
        XCTAssertEqual(model.emptyListCauses, [.name], "the name is blamed, not the folder the user chose")
        XCTAssertEqual(model.emptyListExplanation,
                       "The file-name filter \u{201c}smith\u{201d} hides every file in the folder \u{201c}Jones\u{201d}.")

        model.removeFilter(.name)
        XCTAssertEqual(model.displayed.map(\.name), ["Jones memo.pdf"])
        XCTAssertEqual(model.filterSearchText, "", "the field empties with the chip")
        XCTAssertEqual(model.activeFilterChips.map(\.facet), [.folder])
        XCTAssertTrue(model.emptyListCauses.isEmpty)
    }

    func testTheFolderIsNotBlamedWhileAnotherFilterAloneIs() throws {
        let root = try makeRoot()
        let model = fixtureNavigationModel(pinnedTo: root)
        model.filter.read = .read    // neither file is Read
        model.recompute()
        XCTAssertTrue(model.displayed.isEmpty)
        XCTAssertEqual(model.emptyListCauses, [.read])

        let smithFolder = model.library.files.first { $0.name.hasPrefix("Smith") }!.path
            .replacingOccurrences(of: "/Smith letter.pdf", with: "")
        model.filter.read = .all
        model.filter.searchText = "jones"
        model.setFolderScope(smithFolder)
        XCTAssertTrue(model.displayed.isEmpty)
        XCTAssertEqual(model.emptyListCauses, [.name])

        model.removeFilter(.folder)
        XCTAssertEqual(model.displayed.map(\.name), ["Jones memo.pdf"])
    }
}
