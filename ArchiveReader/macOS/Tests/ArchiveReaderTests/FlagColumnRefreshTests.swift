import AppKit
import XCTest
@testable import ArchiveReader

/// `W40.fix-reader-flag` (owner session reader-1, row 23): Toggle Flag (⇧⌘F) showed nothing. The flag went into
/// `FlagStore`, but the table reloaded rows only when `displayedGeneration` moved, and a flag does not move it, so
/// the ⚑ cell kept its old value until something else redrew the row. The table now redraws the flag cell of each
/// row whose flag changed. Scratch `mktemp` fixtures; the model's flags live on the fixture's own defaults.
@MainActor
final class FlagColumnRefreshTests: XCTestCase {

    private struct Fixture {
        let model: NavigationModel
        let defaults: UserDefaults
        let coordinator: AppKitTableView.Coordinator
        let table: NSTableView
        let column: NSTableColumn
        let files: [URL]
    }

    private func makeFixture(withFlagColumn: Bool = true, _ testName: String = #function) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlagColumnRefreshTests-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try ["alpha.pdf", "beta.pdf", "gamma.pdf"].map { name -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread", "Smith"], forKey: .tagNamesKey)
            return url
        }
        let defaults = fixtureDefaults(pinnedTo: root, testName)
        let model = NavigationModel(defaults: defaults)
        model.recompute()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(withFlagColumn ? "flag" : "name"))
        table.addTableColumn(column)
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = table
        coordinator.showRows(model.displayed)
        XCTAssertEqual(model.displayed.count, 3, "the fixture lists its three files")
        return Fixture(model: model, defaults: defaults, coordinator: coordinator, table: table, column: column, files: files)
    }

    private func row(_ f: Fixture, _ url: URL) throws -> Int {
        try XCTUnwrap(f.coordinator.currentSnapshotIDs.firstIndex { $0.path == url.path }, "\(url.lastPathComponent) is listed")
    }

    private func flagCell(_ f: Fixture, _ url: URL) throws -> NSTextField {
        let file = try XCTUnwrap(f.model.displayed.first { $0.url.path == url.path })
        let cell = f.coordinator.makeCell(tableView: f.table, column: f.column, itemID: file.id)
        return try XCTUnwrap((cell as? NSTableCellView)?.textField)
    }

    /// Failed before the fix: nothing redrew a row when only its flag changed.
    func testTogglingAFlagRedrawsThatRowsFlagCell() throws {
        let f = try makeFixture()
        let (alpha, beta) = (f.files[0], f.files[1])
        XCTAssertEqual(f.coordinator.reloadFlagChanges(f.model.flags.flagged), [], "the first call only records the set")

        f.model.toggleFlag(paths: [alpha.path])
        XCTAssertTrue(f.model.flags.isFlagged(alpha.path))
        XCTAssertEqual(f.coordinator.reloadFlagChanges(f.model.flags.flagged), IndexSet(integer: try row(f, alpha)),
                       "the flagged row, and only it, is redrawn")
        XCTAssertEqual(try flagCell(f, alpha).stringValue, "⚑")
        XCTAssertEqual(try flagCell(f, alpha).accessibilityLabel(), "Flagged")
        XCTAssertEqual(try flagCell(f, beta).stringValue, "")

        XCTAssertEqual(f.coordinator.reloadFlagChanges(f.model.flags.flagged), [], "nothing changed, nothing redrawn")

        f.model.toggleFlag(paths: [alpha.path, beta.path])   // one unflagged → both flagged
        XCTAssertEqual(f.coordinator.reloadFlagChanges(f.model.flags.flagged), IndexSet(integer: try row(f, beta)))

        f.model.toggleFlag(paths: [alpha.path, beta.path])   // both flagged → both cleared
        XCTAssertEqual(f.coordinator.reloadFlagChanges(f.model.flags.flagged),
                       IndexSet([try row(f, alpha), try row(f, beta)]))
        XCTAssertEqual(try flagCell(f, alpha).stringValue, "")
        XCTAssertEqual(try flagCell(f, alpha).accessibilityLabel(), "Not flagged")
    }

    /// The flags are kept on the model's defaults, so a fixture model never writes the host app's own.
    func testFlagsPersistOnTheModelsDefaults() throws {
        let f = try makeFixture()
        f.model.toggleFlag(paths: [f.files[2].path])
        XCTAssertTrue(FlagStore(defaults: f.defaults).isFlagged(f.files[2].path))
        XCTAssertFalse(FlagStore(defaults: .standard).isFlagged(f.files[2].path))
    }

    func testATableWithoutAFlagColumnRedrawsNothing() throws {
        let f = try makeFixture(withFlagColumn: false)
        f.coordinator.reloadFlagChanges(f.model.flags.flagged)
        f.model.toggleFlag(paths: [f.files[0].path])
        XCTAssertEqual(f.coordinator.reloadFlagChanges(f.model.flags.flagged), [])
    }
}
