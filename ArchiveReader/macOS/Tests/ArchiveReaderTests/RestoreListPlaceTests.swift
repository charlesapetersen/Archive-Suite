import XCTest
@testable import ArchiveReader

/// W40.fix-reader-restore-scroll: a relaunch returns to the rows the user was looking at, not just to the
/// smart folder and the selection (reader-1, row 35). The table reports its top row as it scrolls; the next
/// launch asks the table to put that row back at the top. The table half — the clip-view arithmetic — is
/// covered by `RestoreScrollUITests` in the VM; this is the model's half, which decides what is asked for.
@MainActor
final class RestoreListPlaceTests: XCTestCase {

    private func scratchRoot(files: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RestoreListPlace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for i in 0..<files {
            let pdf = root.appendingPathComponent(String(format: "doc-%02d.pdf", i))
            try Data("scratch PDF".utf8).write(to: pdf)
            try (pdf as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        return root
    }

    /// The list follows the library one main-queue hop later, and the resume runs on that hop.
    private func settle(_ model: NavigationModel) {
        let deadline = Date().addingTimeInterval(5)
        while model.displayed.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// The place is written once scrolling stops (0.3 s), not for every row passed.
    private func noteAndWait(_ model: NavigationModel, _ id: ArchiveFile.ID) {
        model.noteTopVisibleRow(id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    func testARelaunchPutsTheLastTopRowBackAtTheTop() throws {
        let root = try scratchRoot(files: 6)
        let defaults = fixtureDefaults(pinnedTo: root)

        let first = NavigationModel(defaults: defaults)
        settle(first)
        let row = try XCTUnwrap(first.displayed.dropFirst(3).first, "precondition: the rows are listed").id
        noteAndWait(first, row)
        XCTAssertEqual(defaults.string(forKey: "lastTopRowFileURL"), row.absoluteString,
                       "the top row has to persist, or the relaunch has nothing to return to")

        let second = NavigationModel(defaults: defaults)
        let before = second.scrollRequest
        settle(second)
        XCTAssertGreaterThan(second.scrollRequest, before, "the relaunch has to ask the table to scroll")
        XCTAssertEqual(second.scrollTargetID, row)
        XCTAssertTrue(second.scrollTargetAtTop, "to the top, where it was — not merely into view")
    }

    /// The first draw is at the top of the list. If that were saved before the resume ran, every relaunch
    /// would overwrite the place it is returning to.
    func testTheUnscrolledFirstDrawDoesNotOverwriteTheSavedPlace() throws {
        let root = try scratchRoot(files: 6)
        let defaults = fixtureDefaults(pinnedTo: root)
        let seed = NavigationModel(defaults: defaults)
        settle(seed)
        let saved = seed.displayed[4].id
        noteAndWait(seed, saved)

        let model = NavigationModel(defaults: defaults)
        model.noteTopVisibleRow(model.library.files[0].id)   // before the resume: ignored
        settle(model)
        noteAndWait(model, model.displayed[0].id)            // while the place is being restored: ignored
        XCTAssertEqual(defaults.string(forKey: "lastTopRowFileURL"), saved.absoluteString)

        model.userMovedInList()                              // the user scrolls: their place is saved
        noteAndWait(model, model.displayed[1].id)
        XCTAssertEqual(defaults.string(forKey: "lastTopRowFileURL"), model.displayed[1].id.absoluteString)
    }

    /// Rows still arriving (a smart folder's text search, a cold scan) move the table's offset off the row,
    /// so each recompute puts it back — until the user moves, after which the list is theirs.
    func testThePlaceIsKeptWhileRowsArriveAndDroppedOnceTheUserMoves() throws {
        let root = try scratchRoot(files: 6)
        let defaults = fixtureDefaults(pinnedTo: root)
        let seed = NavigationModel(defaults: defaults)
        settle(seed)
        let saved = seed.displayed[2].id
        noteAndWait(seed, saved)

        let model = NavigationModel(defaults: defaults)
        settle(model)
        var request = model.scrollRequest
        model.recompute()
        XCTAssertGreaterThan(model.scrollRequest, request, "a recompute while restoring scrolls back to the row")
        XCTAssertEqual(model.scrollTargetID, saved)

        model.userMovedInList()
        request = model.scrollRequest
        model.recompute()
        XCTAssertEqual(model.scrollRequest, request, "after the user moves, a recompute must not pull the list back")
    }

    /// Choosing another folder, filter or sort while the place is still being restored is the user's move:
    /// the list must not jump to the old row because it happens to be listed there too.
    func testAFilterChangeDropsThePlaceBeingRestored() throws {
        let root = try scratchRoot(files: 6)
        let defaults = fixtureDefaults(pinnedTo: root)
        let seed = NavigationModel(defaults: defaults)
        settle(seed)
        noteAndWait(seed, seed.displayed[3].id)

        let model = NavigationModel(defaults: defaults)
        settle(model)
        XCTAssertTrue(model.scrollTargetAtTop, "precondition: the place is being restored")
        let request = model.scrollRequest
        model.filter.searchText = "doc"   // still lists every row, the saved one included
        model.recompute()
        XCTAssertEqual(model.displayed.count, 6)
        XCTAssertEqual(model.scrollRequest, request, "a changed filter must not pull the list back to the old row")
    }

    /// With no saved top row (or one no longer listed), the restored selection is at least scrolled into view.
    func testWithoutASavedTopRowTheRestoredSelectionIsShown() throws {
        let root = try scratchRoot(files: 6)
        let defaults = fixtureDefaults(pinnedTo: root)
        let seed = NavigationModel(defaults: defaults)
        settle(seed)
        let selected = seed.displayed[5].id
        seed.selection = [selected]
        defaults.set(root.appendingPathComponent("gone.pdf").absoluteString, forKey: "lastTopRowFileURL")

        let model = NavigationModel(defaults: defaults)
        settle(model)
        XCTAssertEqual(model.selection, [selected])
        XCTAssertEqual(model.scrollTargetID, selected)
        XCTAssertFalse(model.scrollTargetAtTop)
    }
}
