import AppKit
import ArchiveCore
import XCTest
@testable import ArchiveReader

/// `W40.fix-reader-quality-popups`: the Quality column's cell is a text cell that opens a popup's menu on a click,
/// instead of an `NSPopUpButton` per row (each laid itself out through a SwiftUI graph, ~3 ms a row). It must still
/// be that popup to accessibility, check the file's value, and write a choice through `applyEdit(.setQuality)` to
/// the file the menu was opened on. The cell comes from the table's own cell factory. Scratch `mktemp` fixtures only.
@MainActor
final class QualityCellTests: XCTestCase {

    private var savedLedgerURL: URL!
    private var ledgerDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // The writes add audit lines; keep them out of the real ledger.
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QualityCellTests-\(UUID().uuidString)", isDirectory: true)
        AuditLedger.shared.fileURL = ledgerDir.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerDir)
        try await super.tearDown()
    }

    private struct Fixture {
        let model: NavigationModel
        let coordinator: AppKitTableView.Coordinator
        let table: NSTableView
        let column: NSTableColumn
        let files: [URL]
    }

    private func makeFixture(_ testName: String = #function) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QualityCellTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try [("alpha.pdf", ["Unread", "Smith", "Q2"]), ("beta.pdf", ["Unread", "Smith"])].map { name, tags -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            return url
        }
        let model = fixtureNavigationModel(pinnedTo: root, testName)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quality"))
        column.width = 80
        table.addTableColumn(column)
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = table
        return Fixture(model: model, coordinator: coordinator, table: table, column: column, files: files)
    }

    /// The Quality cell for `url` as the table would make it now.
    private func qualityCell(_ f: Fixture, for url: URL) throws -> QualityCellView {
        f.coordinator.showRows(f.model.displayed)
        let file = try XCTUnwrap(f.model.displayed.first { $0.url.path == url.path }, "\(url.lastPathComponent) is listed")
        let cell = try XCTUnwrap(f.coordinator.makeCell(tableView: f.table, column: f.column, itemID: file.id)
            as? QualityCellView, "the Quality column makes a QualityCellView")
        cell.frame = NSRect(x: 0, y: 0, width: 80, height: 21)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private func tagsOnDisk(_ url: URL) throws -> Set<String> {
        Set(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    private func event(clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 10), modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                         clickCount: clickCount, pressure: 1))
    }

    func testTheCellShowsTheValueAndIsThePopupToAccessibility() throws {
        let f = try makeFixture()
        let alpha = try qualityCell(f, for: f.files[0])
        XCTAssertEqual(alpha.textField?.stringValue, "Q2")
        XCTAssertTrue(alpha.button.isAccessibilityElement())
        XCTAssertEqual(alpha.button.accessibilityRole(), .popUpButton)
        XCTAssertEqual(alpha.button.accessibilityIdentifier(), "ar.quality.menu.alpha.pdf")
        XCTAssertEqual(alpha.button.accessibilityLabel(), "Quality for alpha.pdf")
        XCTAssertEqual(alpha.button.accessibilityValue() as? String, "Q2")
        XCTAssertTrue(alpha.hitTest(NSPoint(x: 40, y: 10)) === alpha, "the cell takes the click, not its label")

        let beta = try qualityCell(f, for: f.files[1])
        XCTAssertEqual(beta.textField?.stringValue, "None")
        XCTAssertEqual(beta.button.accessibilityValue() as? String, "None")
    }

    func testTheMenuOffersNoneAndEveryLevelWithTheValueChecked() throws {
        let f = try makeFixture()
        let menu = try XCTUnwrap(try qualityCell(f, for: f.files[0]).makeMenu())
        XCTAssertEqual(menu.items.map(\.title), ["None"] + QualityLevels.all.map { "Q\($0)" })
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Q2"])
        let none = try XCTUnwrap(try qualityCell(f, for: f.files[1]).makeMenu())
        XCTAssertEqual(none.items.filter { $0.state == .on }.map(\.title), ["None"])
    }

    func testAChoiceWritesTheFileTheMenuWasOpenedOn() throws {
        let f = try makeFixture()
        let (alpha, beta) = (f.files[0], f.files[1])
        let cell = try qualityCell(f, for: alpha)
        let menu = try XCTUnwrap(cell.makeMenu())
        // A refresh reuses the cell for another row while the menu is open.
        cell.file = f.model.displayed.first { $0.url.path == beta.path }
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Q3" }))
        XCTAssertEqual(try tagsOnDisk(alpha), ["Unread", "Smith", "Q3"], "Q3 replaces Q2 on the file the menu was opened on")
        XCTAssertEqual(try tagsOnDisk(beta), ["Unread", "Smith"], "the row the cell shows now is untouched")
        XCTAssertTrue(f.model.selection.isEmpty, "the choice acts on the cell's file, not the selection")
    }

    func testModifiedAndDoubleClicksAndEmptyRowsGoToTheTable() throws {
        let f = try makeFixture()
        let cell = try qualityCell(f, for: f.files[0])
        XCTAssertFalse(cell.handleMouseDown(try event(modifiers: .command)), "⌘-click extends the selection")
        XCTAssertFalse(cell.handleMouseDown(try event(modifiers: .shift)), "⇧-click extends the selection")
        XCTAssertFalse(cell.handleMouseDown(try event(clickCount: 2)), "a double-click opens the file")
        cell.file = nil
        XCTAssertFalse(cell.handleMouseDown(try event()), "a row with no file has no menu")
        XCTAssertNil(cell.makeMenu())
        XCTAssertFalse(cell.button.isAccessibilityElement())
        XCTAssertNil(cell.toolTip, "a row with no file offers nothing")
        XCTAssertEqual(cell.textField?.stringValue, "")
    }
}
