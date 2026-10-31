import AppKit
import ArchiveCore
import XCTest
@testable import ArchiveReader

/// `W40.fix-reader-read-toggle` (ledger R-25): a click on a row's Read cell switches its file between Unread and
/// Read, and a right-click sets or clears the state, through the same `TagWriter` path as ⌘R and ⌘U. Before the fix
/// the AppKit Read column was a plain label: the click went nowhere and there was no menu, so these failed. The cell
/// comes from the table's own cell factory, and every gesture is delivered to whatever view the cell's hit test
/// returns, as the window would. Scratch `mktemp` fixtures only.
@MainActor
final class ReadToggleTests: XCTestCase {

    private var savedLedgerURL: URL!
    private var ledgerDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // The writes add audit lines; keep them out of the real ledger.
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReadToggleTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFixture(_ names: [String] = ["alpha.pdf", "beta.pdf"],
                             _ testName: String = #function) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReadToggleTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try names.map { name -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread", "Smith"], forKey: .tagNamesKey)
            return url
        }
        let model = fixtureNavigationModel(pinnedTo: root, testName)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("read"))
        column.width = 84
        table.addTableColumn(column)
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = table
        return Fixture(model: model, coordinator: coordinator, table: table, column: column, files: files)
    }

    /// The Read cell for `url` as the table would make it now, laid out at a row's size.
    private func readCell(_ f: Fixture, for url: URL) throws -> NSView {
        f.coordinator.showRows(f.model.displayed)
        let file = try XCTUnwrap(f.model.displayed.first { $0.url.path == url.path }, "\(url.lastPathComponent) is listed")
        let cell = f.coordinator.makeCell(tableView: f.table, column: f.column, itemID: file.id)
        cell.frame = NSRect(x: 0, y: 0, width: 84, height: 21)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// The view a click in the middle of `cell` reaches.
    private func hitView(_ cell: NSView) throws -> NSView {
        try XCTUnwrap(cell.hitTest(NSPoint(x: cell.frame.midX, y: cell.frame.midY)), "a click lands in the cell")
    }

    private func event(_ type: NSEvent.EventType, clickCount: Int = 1, at location: NSPoint = NSPoint(x: 42, y: 10),
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                         clickCount: clickCount, pressure: 1))
    }

    /// A verified write reaches the list on the next main-queue turn (`library.$files` is received on main), and the
    /// table remakes the row's cell then; wait for the row to show `state` before the next gesture.
    private func waitForRow(_ f: Fixture, _ url: URL, toShow state: ReadState?,
                            file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        func shown() -> ReadState?? { f.model.displayed.first { $0.url.path == url.path }.map(\.readState) }
        while shown() != .some(state), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(shown(), .some(state), "the row shows the verified write", file: file, line: line)
    }

    /// Read from disk through a fresh `URL`, so a cached resource value cannot answer for the file.
    private func tagsOnDisk(_ url: URL) throws -> Set<String> {
        Set(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    /// Run the main loop past the double-click interval, which a click waits out before it switches.
    private func waitOutDoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.2))
    }

    private func click(_ f: Fixture, _ url: URL, modifiers: NSEvent.ModifierFlags = []) throws {
        let target = try hitView(try readCell(f, for: url))
        target.mouseDown(with: try event(.leftMouseDown, modifiers: modifiers))
        target.mouseUp(with: try event(.leftMouseUp, modifiers: modifiers))
        waitOutDoubleClick()
    }

    private func rightClickMenu(_ f: Fixture, _ url: URL) throws -> NSMenu {
        try XCTUnwrap(try hitView(try readCell(f, for: url)).menu(for: try event(.rightMouseDown)),
                      "a right-click on the Read cell offers a menu")
    }

    func testAClickSwitchesUnreadAndReadForThatFileOnly() throws {
        let f = try makeFixture()
        let (alpha, beta) = (f.files[0], f.files[1])

        try click(f, alpha)
        XCTAssertEqual(try tagsOnDisk(alpha), ["Read", "Smith"], "a click marks an Unread file Read")
        XCTAssertEqual(try tagsOnDisk(beta), ["Unread", "Smith"], "and touches no other row")
        XCTAssertTrue(f.model.selection.isEmpty, "the click acts on the cell, not the selection")
        waitForRow(f, alpha, toShow: .read)

        try click(f, alpha)
        XCTAssertEqual(try tagsOnDisk(alpha), ["Unread", "Smith"], "a second click marks it Unread again")
        XCTAssertEqual(f.model.undoDepth, 2, "each click is its own undo step, as ⌘R and ⌘U are")
    }

    func testADoubleClickADragAndAModifiedClickDoNotWrite() throws {
        let f = try makeFixture()
        let alpha = f.files[0]

        // A double-click is the table's: it opens the file. Neither of its clicks switches the state.
        let target = try hitView(try readCell(f, for: alpha))
        target.mouseDown(with: try event(.leftMouseDown, clickCount: 1))
        target.mouseUp(with: try event(.leftMouseUp, clickCount: 1))
        target.mouseDown(with: try event(.leftMouseDown, clickCount: 2))
        target.mouseUp(with: try event(.leftMouseUp, clickCount: 2))
        waitOutDoubleClick()
        XCTAssertEqual(try tagsOnDisk(alpha), ["Unread", "Smith"], "a double-click writes nothing")

        // A press that drags, or slides off the cell before its release, is not a click.
        target.mouseDown(with: try event(.leftMouseDown))
        target.mouseDragged(with: try event(.leftMouseDragged))
        target.mouseUp(with: try event(.leftMouseUp))
        target.mouseDown(with: try event(.leftMouseDown))
        target.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 400, y: 10)))
        waitOutDoubleClick()
        XCTAssertEqual(try tagsOnDisk(alpha), ["Unread", "Smith"], "a drag or a release off the cell writes nothing")
        try click(f, alpha, modifiers: .command)
        try click(f, alpha, modifiers: .shift)
        XCTAssertEqual(try tagsOnDisk(alpha), ["Unread", "Smith"], "⌘- and ⇧-clicks extend the selection instead")
    }

    func testTheRightClickMenuSetsAndClearsTheState() throws {
        let f = try makeFixture()
        let alpha = f.files[0]

        var menu = try rightClickMenu(f, alpha)
        XCTAssertEqual(menu.items.map(\.title), ["Read", "Unread", "", "Clear Read State"])
        XCTAssertEqual(menu.item(withTitle: "Unread")?.state, .on, "the menu shows the file's state")
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Read" }))
        XCTAssertEqual(try tagsOnDisk(alpha), ["Read", "Smith"], "Read sets the state")
        waitForRow(f, alpha, toShow: .read)

        menu = try rightClickMenu(f, alpha)
        XCTAssertEqual(menu.item(withTitle: "Read")?.state, .on)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Read" }))
        XCTAssertEqual(try tagsOnDisk(alpha), ["Read", "Smith"], "choosing the state it has changes nothing")

        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Clear Read State" }))
        XCTAssertEqual(try tagsOnDisk(alpha), ["Smith"], "Clear Read State removes it and keeps the other tags")
        XCTAssertEqual(try tagsOnDisk(f.files[1]), ["Unread", "Smith"], "and touches no other row")
        XCTAssertTrue(f.model.selection.isEmpty, "the menu acts on the cell, not the selection")
    }

    /// While a menu is open a row refresh can reuse its cell for another file. The menu still acts on the file it
    /// was opened on, which is the one whose state it showed.
    func testTheMenuActsOnTheFileItWasOpenedOnAfterTheCellIsReused() throws {
        let f = try makeFixture()
        let (alpha, beta) = (f.files[0], f.files[1])
        let cell = try readCell(f, for: alpha)
        let menu = try XCTUnwrap(try hitView(cell).menu(for: try event(.rightMouseDown)))
        let cellForBeta = try XCTUnwrap(cell as? ReadStateCellView)
        cellForBeta.file = f.model.displayed.first { $0.url.path == beta.path }   // the table reuses the cell

        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Read" }))
        XCTAssertEqual(try tagsOnDisk(alpha), ["Read", "Smith"], "the file the menu was opened on is marked")
        XCTAssertEqual(try tagsOnDisk(beta), ["Unread", "Smith"], "the file the cell shows now is not")
    }

    /// A row can be behind its file. Clear Read State clears what the file holds, not what the row last showed.
    func testClearReadStateClearsTheFileEvenWhenTheRowIsBehind() throws {
        let f = try makeFixture(["alpha.pdf"])
        let alpha = f.files[0]
        let menu = try rightClickMenu(f, alpha)   // made while the row shows Unread
        try (alpha as NSURL).setResourceValue(["read", "Smith"], forKey: .tagNamesKey)

        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Clear Read State" }))
        XCTAssertEqual(try tagsOnDisk(alpha), ["Smith"], "the file's own read token goes, whatever its case")
    }
}
