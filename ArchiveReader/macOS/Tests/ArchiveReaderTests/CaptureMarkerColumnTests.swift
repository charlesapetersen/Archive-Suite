import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// The page-2 classification column, named Capture marker since W40.fix-reader-columns (it was Provenance),
/// and the list's other column affordances from that item: header tooltips, the ⚑ and ⚠︎ sorts, and the
/// visible column chooser that shares `NavigationModel.hiddenColumns` with the header's menu.
@MainActor
final class CaptureMarkerColumnTests: XCTestCase {
    func testCaptureMarkerColumnIsNamedAndExplainedAndHiddenOnlyByChoice() throws {
        let definition = try XCTUnwrap(
            AppKitTableView.columnDefinitions.first { $0.id == AppKitTableView.captureMarkerColumnID }
        )
        XCTAssertEqual(definition.title, "Capture marker")
        XCTAssertTrue(definition.toolTip.contains("Box, Folder, Document Start"))

        let defaults = fixtureDefaults()
        XCTAssertTrue(AppSettings.hiddenColumns(in: defaults).isEmpty,
                      "no column starts hidden; Capture marker hides itself while it would be blank")
        AppSettings.setHiddenColumns(["type"], in: defaults)
        XCTAssertEqual(AppSettings.hiddenColumns(in: defaults), ["type"], "the user's choice survives relaunch")
    }

    func testEveryColumnHasAHeaderToolTipAndTheMarksSort() {
        let tableView = NSTableView()
        AppKitTableView.addColumns(to: tableView)
        XCTAssertEqual(tableView.tableColumns.count, AppKitTableView.columnDefinitions.count)
        for column in tableView.tableColumns {
            XCTAssertFalse(column.headerToolTip?.isEmpty ?? true, "\(column.identifier.rawValue) has no tooltip")
        }
        let keys = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map {
            ($0.identifier.rawValue, $0.sortDescriptorPrototype?.key)
        })
        XCTAssertEqual(keys["flag"], SortField.flag.rawValue)
        XCTAssertEqual(keys["warning"], SortField.attention.rawValue)
        XCTAssertEqual(AppKitTableView.columnDefinitions.first { $0.id == "flag" }?.chooserTitle, "⚑ Flag")
    }

    func testCaptureMarkerIsHiddenWhileNoFileHasOneAndTheChooserWritesTheChoice() {
        let defaults = fixtureDefaults()
        let model = NavigationModel(defaults: defaults)
        XCTAssertEqual(model.effectiveHiddenColumns, [AppKitTableView.captureMarkerColumnID],
                       "no file carries a marker, so the column would only be blank")
        XCTAssertFalse(model.isColumnAvailable(AppKitTableView.captureMarkerColumnID))
        XCTAssertTrue(model.isColumnAvailable("type"))

        model.setColumn("type", visible: false)
        model.setColumn("name", visible: false)
        XCTAssertEqual(model.hiddenColumns, ["type"], "the file name is always shown")
        XCTAssertEqual(AppSettings.hiddenColumns(in: defaults), ["type"], "persisted for the next launch")
        XCTAssertEqual(NavigationModel(defaults: defaults).hiddenColumns, ["type"], "and read back by a new window")
        model.setColumn("type", visible: true)
        XCTAssertTrue(model.hiddenColumns.isEmpty)
    }

    func testTheTableFollowsTheModelsHiddenColumns() {
        let tableView = NSTableView()
        AppKitTableView.addColumns(to: tableView)
        let model = NavigationModel(defaults: fixtureDefaults())
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        func hidden() -> Set<String> { Set(tableView.tableColumns.filter(\.isHidden).map(\.identifier.rawValue)) }

        XCTAssertTrue(coordinator.applyHiddenColumns(["quality", "name"], to: tableView))
        XCTAssertEqual(hidden(), ["quality"], "the file name column is never hidden")
        XCTAssertFalse(coordinator.applyHiddenColumns(["quality", "name"], to: tableView), "nothing changed")
        XCTAssertTrue(coordinator.applyHiddenColumns([], to: tableView))
        XCTAssertTrue(hidden().isEmpty)
    }

    func testSortingByFlagMovesAFileWhenItsFlagIsToggled() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlagSort-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.pdf", "b.pdf", "c.pdf"] {
            let url = box.appendingPathComponent(name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        let model = fixtureNavigationModel(pinnedTo: root)
        model.sort = [ARSortDescriptor(field: .name)]
        model.recompute()
        XCTAssertEqual(model.displayed.map(\.name), ["a.pdf", "b.pdf", "c.pdf"], "precondition: the fixture is listed")

        model.sort = [ARSortDescriptor(field: .flag), ARSortDescriptor(field: .name)]
        model.recompute()
        let c = try XCTUnwrap(model.displayed.last)
        XCTAssertTrue(model.toggleFlag(paths: [c.path]))
        XCTAssertEqual(model.displayed.map(\.name), ["c.pdf", "a.pdf", "b.pdf"], "the flagged file moves to the top")
        XCTAssertTrue(model.toggleFlag(paths: [c.path]))
        XCTAssertEqual(model.displayed.map(\.name), ["a.pdf", "b.pdf", "c.pdf"])
    }

    func testContentIndexBulkClassificationJoinPreservesKnownValuesAndOmitsUnknownRows() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureMarkerColumnIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let index = ContentIndex(url: scratch.appendingPathComponent("content.sqlite3"))
        try await index.open()
        try await index.upsert(path: "/box.pdf", mtime: 1, name: "box", classification: "Box", body: "box")
        try await index.upsert(path: "/start.pdf", mtime: 1, name: "start",
                               classification: "Document Start", body: "start")
        try await index.upsert(path: "/legacy.pdf", mtime: 1, name: "legacy", classification: nil, body: "legacy")

        let values = await index.classifications(for: ["/legacy.pdf", "/start.pdf", "/missing.pdf", "/box.pdf"])
        XCTAssertEqual(values, ["/box.pdf": "Box", "/start.pdf": "Document Start"])
        await index.close()
    }

    func testNavigationModelPublishesIndexedClassificationForTheTable() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureMarkerColumnModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fileURL = scratch.appendingPathComponent("fixture.pdf")
        try Data("scratch fixture".utf8).write(to: fileURL)
        try (fileURL as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)

        let indexer = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { _ in
                ExtractedContent(fullBody: "body", strippedBody: "body",
                                 classification: "Folder", pageCount: 2)
            }
        )
        do {
            let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch), indexer: indexer)
            let indexedPath = try XCTUnwrap(model.library.files.first?.url.path,
                                            "precondition: the fixture root supplies one nav row")
            XCTAssertTrue(indexedPath.hasSuffix("/fixture.pdf"))

            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, indexer.completedPassesForTesting == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThanOrEqual(indexer.completedPassesForTesting, 1,
                                        "the scratch row must actually reach the index")
            let indexed = await indexer.classifications(for: [indexedPath])
            XCTAssertEqual(indexed, [indexedPath: "Folder"],
                           "non-vacuity: the injected row exists before the model joins it")

            model.refreshFormatStatuses()
            let publicationDeadline = Date().addingTimeInterval(10)
            while Date() < publicationDeadline, model.classification(for: indexedPath) == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(model.classification(for: indexedPath), "Folder")
            XCTAssertFalse(model.effectiveHiddenColumns.contains(AppKitTableView.captureMarkerColumnID),
                           "a file with a marker brings the column back")
        }
        await indexer.closeForTesting()
        try FileManager.default.removeItem(at: scratch)
    }

    func testCaptureMarkerCellRendersItsValueToPixels() throws {
        let field = NSTextField(labelWithString: "")
        AppKitTableView.Coordinator.configureProvenanceTextField(
            field, classification: "Document Start", fontSize: 13
        )
        XCTAssertEqual(field.stringValue, "Document Start")

        let data = try XCTUnwrap(
            RenderProbe.pngData(fromAppKitView: field, size: CGSize(width: 180, height: 28)),
            "the real table-cell formatter did not produce a bitmap"
        )
        writeRenderArtifact(data, named: "w18-provenance-column.png")
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        _ = try XCTUnwrap(assertRendersNonBlank(image, "Capture marker column cell"))
    }
}
