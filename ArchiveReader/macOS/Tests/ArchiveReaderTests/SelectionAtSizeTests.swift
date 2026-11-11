import XCTest
@testable import ArchiveReader

/// W40.fix-reader-selection-at-size: the selection is resolved against the list by binary search on its sort
/// keys, not by a scan of every row, so what it yields has to match the scan exactly: the listed rows, in the
/// list's order, a row the list does not show left out. The inspector holds its target while hidden, and the
/// indexing count no longer republishes the model. The cost itself is asserted at size in `ReaderChainAtSizeTests`.
@MainActor
final class SelectionAtSizeTests: XCTestCase {

    private func scratchRoot(files: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SelectionAtSize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for i in 0..<files {
            let pdf = root.appendingPathComponent(String(format: "doc-%02d.pdf", i))
            try Data("scratch PDF".utf8).write(to: pdf)
            try (pdf as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        return root
    }

    private func settledModel(files: Int) throws -> NavigationModel {
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: try scratchRoot(files: files)))
        let deadline = Date().addingTimeInterval(5)
        while model.displayed.count < files && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.displayed.count, files, "precondition: every scratch file is listed")
        return model
    }

    private func resort(_ model: NavigationModel, _ sort: [ARSortDescriptor]) {
        model.sort = sort
        model.recompute()
        let deadline = Date().addingTimeInterval(5)
        while model.displayed.map(\.name) != model.displayed.map(\.name).sorted(by: { a, b in
            sort.first?.ascending == false ? a > b : a < b
        }) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testTheSelectedFilesAreTheListedRowsInListOrderInEitherDirection() throws {
        let model = try settledModel(files: 12)
        for ascending in [true, false] {
            resort(model, [ARSortDescriptor(field: .name, ascending: ascending)])
            let listed = model.displayed
            let picked = [listed[9], listed[2], listed[5]]
            model.selection = Set(picked.map(\.id))
            XCTAssertEqual(model.selectedFiles.map(\.path), [2, 5, 9].map { listed[$0].path },
                           "ascending \(ascending): the list's order, whatever order they were picked in")
        }
    }

    func testARowTheListDoesNotShowIsLeftOutAsTheScanLeftItOut() throws {
        let model = try settledModel(files: 6)
        let listed = model.displayed
        let stranger = URL(fileURLWithPath: "/nowhere/not-in-the-library.pdf")
        model.selection = [listed[1].id, stranger, listed[4].id]
        XCTAssertEqual(model.selectedFiles.map(\.path), [listed[1].path, listed[4].path])
    }

    func testThePreviewArrowStepsFromTheEndOfTheSelection() throws {
        let model = try settledModel(files: 8)
        let listed = model.displayed
        model.selection = [listed[2].id, listed[4].id]
        model.moveSelectionInList(1)
        XCTAssertEqual(model.selection, [listed[5].id])
        model.selection = [listed[2].id, listed[4].id]
        model.moveSelectionInList(-1)
        XCTAssertEqual(model.selection, [listed[1].id])
        model.selection = [listed[7].id]
        model.moveSelectionInList(1)
        XCTAssertEqual(model.selection, [listed[7].id], "the last row stays put")
    }

    func testAHiddenInspectorHoldsItsTargetAndTakesTheSelectionWhenShown() throws {
        let model = try settledModel(files: 6)
        let listed = model.displayed
        model.showingEditor = true
        model.selection = [listed[0].id]
        XCTAssertEqual(model.inspectorTarget.paths, [listed[0].path])
        let shown = model.inspectorTarget.generation

        model.showingEditor = false
        model.selection = [listed[3].id]
        XCTAssertEqual(model.inspectorTarget.paths, [listed[0].path], "hidden, it is not rebuilt for the selection")
        XCTAssertEqual(model.inspectorTarget.generation, shown)

        model.showingEditor = true
        XCTAssertEqual(model.inspectorTarget.paths, [listed[3].path], "shown again, it edits the selection")
        XCTAssertNotEqual(model.inspectorTarget.generation, shown)
    }

    func testTheSameFilesInANewOrderKeepTheInspectorsIdentity() throws {
        let model = try settledModel(files: 6)
        resort(model, [ARSortDescriptor(field: .name, ascending: true)])
        model.showingEditor = true
        model.selection = Set(model.displayed.prefix(3).map(\.id))
        let generation = model.inspectorTarget.generation
        resort(model, [ARSortDescriptor(field: .name, ascending: false)])
        XCTAssertEqual(Set(model.inspectorTarget.paths), Set(model.selectedFiles.map(\.path)))
        XCTAssertEqual(model.inspectorTarget.paths, model.selectedFiles.map(\.path), "it follows the new order")
        XCTAssertEqual(model.inspectorTarget.generation, generation, "a draft typed in it survives a re-sort")
    }

    func testTheSelectionIsWrittenOnceTheArrowKeysPause() throws {
        let defaults = fixtureDefaults(pinnedTo: try scratchRoot(files: 4))
        let model = NavigationModel(defaults: defaults)
        let deadline = Date().addingTimeInterval(5)
        while model.displayed.count < 4 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let listed = model.displayed
        for row in listed { model.selection = [row.id] }
        XCTAssertNotEqual(defaults.stringArray(forKey: "lastSelectionFileURLs"), [listed[3].id.absoluteString],
                          "not on every change")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(defaults.stringArray(forKey: "lastSelectionFileURLs"), [listed[3].id.absoluteString],
                       "once the changes pause")
    }

    func testAnIndexingTickDoesNotRepublishTheModel() throws {
        let model = try settledModel(files: 2)
        var published = 0
        let sink = model.objectWillChange.sink { _ in published += 1 }
        defer { sink.cancel() }
        model.indexProgress.value = (done: 1, total: 10)   // as the indexer's sink does, the count goes here
        model.indexProgress.value = (done: 2, total: 10)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(model.indexingProgress?.done, 2)
    }
}
