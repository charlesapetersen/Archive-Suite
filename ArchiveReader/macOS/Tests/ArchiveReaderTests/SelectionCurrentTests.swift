import AppKit
import ArchiveCore
import SwiftUI
import XCTest
@testable import ArchiveReader

/// W40.reader-selection-current (the owner's Reader notes of 2026-11-10, points 10, 12 and 13): the selection has an
/// anchor and a cursor, so ⇧↑/⇧↓ extend the same run in the list and in the preview sheet; the file on view in the
/// sheet or a document window is marked in the list, drawn and spoken; and when every selected row leaves the list,
/// the next row takes the selection while the rows that stay keep their place on screen. Rows are made in memory
/// under a path that does not exist; nothing is read from or written to disk except a scratch content index.
@MainActor
final class SelectionCurrentTests: XCTestCase {

    private let base = "/private/tmp/W40-selection-current-\(UUID().uuidString)"

    // MARK: - Fixture

    private func rows(_ count: Int) -> [ArchiveFile] {
        (0..<count).map { i in
            let url = URL(fileURLWithPath: String(format: "\(base)/Box/doc %03d.pdf", i))
            let tags = ["Unread", "1950"]
            return ArchiveLibrary.row(CorpusEntry(url: url, tagNames: tags, labelNumber: nil,
                                                  contentModified: Date(timeIntervalSince1970: 1_000),
                                                  contentTypeIdentifier: "com.adobe.pdf", isDataless: false),
                                      tagNames: tags, labelNumber: nil)
        }
    }

    private func settle(_ model: NavigationModel, _ indexer: ContentIndexer) async {
        for _ in 0..<3 {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, indexer.progress != nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// A model listing `count` unread rows by name, and the scratch index it was given.
    private func model(rows count: Int, _ testName: String = #function) async throws -> (NavigationModel, ContentIndexer) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionCurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let indexer = ContentIndexer(url: scratch.appendingPathComponent("content.sqlite3"), extractPDFForTesting: { _ in
            ExtractedContent(fullBody: "", strippedBody: "", classification: nil, pageCount: 2)
        })
        let model = NavigationModel(defaults: fixtureDefaults(testName), indexer: indexer)
        model.library.replaceFilesForTesting(rows(count))
        await settle(model, indexer)
        model.sort = [ARSortDescriptor(field: .name, ascending: true)]
        model.recompute()
        await settle(model, indexer)
        XCTAssertEqual(model.displayed.count, count, "precondition: every row is listed")
        addTeardownBlock { await indexer.closeForTesting() }
        return (model, indexer)
    }

    private func ids(_ model: NavigationModel, _ positions: ClosedRange<Int>) -> Set<ArchiveFile.ID> {
        Set(model.displayed[positions].map(\.id))
    }

    // MARK: - ⇧↑/⇧↓ (point 10)

    func testShiftArrowsExtendFromTheAnchorAndShrinkBackPastIt() async throws {
        let (model, _) = try await model(rows: 12)
        model.selection = [model.displayed[5].id]
        model.extendSelectionInList(1)
        model.extendSelectionInList(1)
        XCTAssertEqual(model.selection, ids(model, 5...7), "⇧↓ twice from row 5")
        XCTAssertEqual(model.selectionAnchor, model.displayed[5].id)
        XCTAssertEqual(model.selectionCursor, model.displayed[7].id)

        for _ in 0..<3 { model.extendSelectionInList(-1) }
        XCTAssertEqual(model.selection, ids(model, 4...5), "⇧↑ three times: back to the anchor, then one above it")
        XCTAssertEqual(model.selectionCursor, model.displayed[4].id)

        model.moveSelectionInList(1)
        XCTAssertEqual(model.selection, [model.displayed[6].id], "a plain arrow collapses to one row, as before")
        XCTAssertEqual(model.selectionAnchor, model.displayed[6].id, "one row is both ends")
    }

    func testExtendingCarriesOnARunTheListStarted() async throws {
        let (model, _) = try await model(rows: 12)
        // The user ⇧↑ed from row 5 to row 3 in the list; the table reports the selection, then its ends.
        model.selection = [model.displayed[5].id]
        model.selection = ids(model, 3...5)
        model.noteSelectionEnds(cursor: model.displayed[3].id, otherEnd: model.displayed[5].id)
        model.extendSelectionInList(-1)
        XCTAssertEqual(model.selection, ids(model, 2...5), "the sheet's ⇧↑ grows the list's run upward")
        model.extendSelectionInList(1)
        XCTAssertEqual(model.selection, ids(model, 3...5), "and ⇧↓ shrinks it from the same end")
    }

    func testExtendingASelectionWithNoEndsGrowsAwayFromIt() async throws {
        let (model, _) = try await model(rows: 12)
        model.selection = Set([2, 4].map { model.displayed[$0].id })   // ⌘-clicked: no anchor, no cursor
        XCTAssertNil(model.selectionCursor)
        model.extendSelectionInList(1)
        XCTAssertEqual(model.selection, ids(model, 2...5), "from the first row down to one past the last")
        model.selection = []
        model.extendSelectionInList(1)
        XCTAssertEqual(model.selection, [model.displayed[0].id], "with nothing selected it is a plain move")
        for _ in 0..<20 { model.extendSelectionInList(1) }
        XCTAssertEqual(model.selection.count, 12, "the run stops at the end of the list")
    }

    func testThePreviewOpensOnTheRowJustAdded() async throws {
        let (model, _) = try await model(rows: 6)
        model.selection = [model.displayed[1].id]
        model.extendSelectionInList(1)
        model.extendSelectionInList(1)
        let viewer = DocumentViewerModel(persists: false, supportsFind: false, supportsPageOverview: false)
        viewer.load(model.documentSelection(), showing: model.selectionCursorPath)
        XCTAssertEqual(viewer.urls.count, 3, "the sheet loads the whole run, so ←/→ still step across it")
        XCTAssertEqual(viewer.currentFilePath, model.displayed[3].path, "and shows the row ⇧↓ just added")
        viewer.load(model.documentSelection())
        XCTAssertEqual(viewer.currentFilePath, model.displayed[1].path, "without a file named, the first, as before")
    }

    func testShiftArrowKeysAreTheOnlyOnesTheListSendsToTheModel() throws {
        func key(_ scalar: Int, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            let chars = String(Character(try XCTUnwrap(UnicodeScalar(scalar))))
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
        XCTAssertEqual(ContextMenuTableView.extendDelta(try key(NSDownArrowFunctionKey, 125, arrows.union(.shift))), 1)
        XCTAssertEqual(ContextMenuTableView.extendDelta(try key(NSUpArrowFunctionKey, 126, arrows.union(.shift))), -1)
        XCTAssertNil(ContextMenuTableView.extendDelta(try key(NSDownArrowFunctionKey, 125, arrows)), "plain ↓ stays the table's")
        XCTAssertNil(ContextMenuTableView.extendDelta(try key(NSDownArrowFunctionKey, 125, arrows.union([.shift, .command]))))
        XCTAssertNil(ContextMenuTableView.extendDelta(try key(Int(("J" as Character).unicodeScalars.first!.value), 38, .shift)))
    }

    // MARK: - The file on view (point 13)

    func testTheFileOnViewBelongsToWhoeverReportedItLast() async throws {
        let (model, _) = try await model(rows: 3)
        let sheet = NSObject(), window = NSObject()
        model.noteFileOnView(model.displayed[0].path, by: sheet)
        model.noteFileOnView(model.displayed[1].path, by: window)
        model.endFileOnView(by: sheet)
        XCTAssertEqual(model.fileOnViewPath, model.displayed[1].path, "a sheet closing does not clear the window's file")
        model.endFileOnView(by: window)
        XCTAssertNil(model.fileOnViewPath)
    }

    // MARK: - Rows that leave (point 12)

    func testWhenTheSelectedRowsLeaveTheNextRowTakesTheirPlace() async throws {
        let (model, indexer) = try await model(rows: 10)
        model.filter.read = .unread
        model.recompute()
        await settle(model, indexer)

        func markRead(_ positions: [Int]) async {
            let files = positions.map { model.displayed[$0] }
            model.library.applyVerifiedWrites(files.map { f in
                TagWriteResult(url: f.url, before: f.tags.raw, after: ["Read", "1950"], beforeLabel: nil, afterLabel: nil,
                               inverse: TagDelta(add: [], remove: []))
            })
            await settle(model, indexer)
        }

        let listed = model.displayed.map(\.id)
        model.selection = ids(model, 3...4)
        let patches = model.rowPatchesForTesting
        await markRead([3, 4])
        XCTAssertGreaterThan(model.rowPatchesForTesting, patches, "precondition: the tag change was patched")
        XCTAssertEqual(model.displayed.count, 8, "the two read rows left the unread list")
        XCTAssertEqual(model.selection, [listed[5]], "the row after them is selected")
        XCTAssertEqual(model.selectedFiles.map(\.id), [listed[5]], "and the selected files say so")
        XCTAssertEqual(model.selectionCursor, listed[5], "and is where the arrows go on from")
        XCTAssertTrue(model.displayedKeepsPlace, "the table is told to keep the rows' place")

        model.selection = [model.displayed.last!.id]
        await markRead([model.displayed.count - 1])
        XCTAssertEqual(model.selection, [listed[8]], "at the end of the list, the row before")

        model.selection = Set([0, 1].map { model.displayed[$0].id })
        await markRead([0])
        XCTAssertEqual(model.selection, [listed[1]], "a selected row that stays keeps the selection to itself")

        model.recompute()
        XCTAssertFalse(model.displayedKeepsPlace, "a rebuild does not keep the place")
    }

    func testTheRowAfterLeavingSkipsRowsThatLeftWithIt() {
        let list = rows(8)
        let id = list.map(\.id)
        let old = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        func position(_ f: ArchiveFile, _ l: [ArchiveFile]) -> Int? { l.firstIndex { $0.id == f.id } }
        XCTAssertEqual(NavigationModel.rowAfterLeaving([id[2]], in: list, left: [id[2], id[3], id[4]], oldRows: old,
                                                       position: position), id[5])
        XCTAssertEqual(NavigationModel.rowAfterLeaving([id[6], id[7]], in: list, left: [id[5], id[6], id[7]],
                                                       oldRows: old, position: position), id[4])
        XCTAssertNil(NavigationModel.rowAfterLeaving([id[0]], in: Array(list.prefix(1)), left: [id[0]], oldRows: old,
                                                     position: position))
    }

    // MARK: - The list's table

    private struct Table {
        let coordinator: AppKitTableView.Coordinator
        let table: ContextMenuTableView
        let scroll: NSScrollView
    }

    private func table(_ model: NavigationModel, appearance: NSAppearance.Name = .aqua) -> Table {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        scroll.appearance = NSAppearance(named: appearance)
        scroll.hasVerticalScroller = false
        let table = ContextMenuTableView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 300
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.allowsMultipleSelection = true
        table.style = .plain
        scroll.documentView = table
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: Binding(get: { model.selection }, set: { model.selection = $0 }), fontSize: 13,
            scrollRequest: 0, scrollTargetID: nil, onDoubleClick: {}, buildContextMenu: { _ in nil }))
        let dataSource = SortableDiffableDataSource(tableView: table) { tv, column, _, id in
            coordinator.makeCell(tableView: tv, column: column, itemID: id)
        }
        dataSource.rowViewProvider = { tv, _, id in coordinator.makeRowView(tableView: tv, itemID: id.base as? ArchiveFile.ID) }
        coordinator.dataSource = dataSource
        coordinator.tableView = table
        table.delegate = coordinator
        coordinator.showRows(model.displayed)
        scroll.layoutSubtreeIfNeeded()
        return Table(coordinator: coordinator, table: table, scroll: scroll)
    }

    private func scroll(_ t: Table, toTop row: Int) {
        t.coordinator.scrollRowToTop(row, in: t.scroll)
        t.scroll.layoutSubtreeIfNeeded()
    }

    /// The listed file at the top of the visible area, and how far below that edge it starts.
    private func top(_ t: Table) -> (ArchiveFile.ID, CGFloat) {
        let clip = t.scroll.contentView
        let row = t.table.row(at: NSPoint(x: 1, y: clip.bounds.minY + 0.5))
        return (t.coordinator.currentSnapshotIDs[row], t.table.rect(ofRow: row).minY - clip.bounds.minY)
    }

    func testRowsThatLeaveLeaveTheRowsOnScreenWhereTheyWere() async throws {
        let (model, _) = try await model(rows: 60)
        let all = model.displayed
        let t = table(model)
        scroll(t, toTop: 20)
        let before = top(t)
        XCTAssertEqual(before.0, all[20].id, "precondition: row 20 is at the top")

        // Two rows above the visible area leave: without the fix the list slid up by two rows.
        var shown = all
        shown.removeSubrange(5...6)
        t.coordinator.showRows(shown, keepingPlace: true)
        XCTAssertEqual(top(t).0, before.0, "the top row is still the top row")
        XCTAssertEqual(top(t).1, before.1, accuracy: 0.5, "at the same height")

        // The top row itself leaves: the next row that stays takes its place.
        let firstVisible = top(t).0
        shown.removeAll { $0.id == firstVisible }
        t.coordinator.showRows(shown, keepingPlace: true)
        XCTAssertEqual(top(t).0, all[21].id, "the row below the one that left is at the top now")

        // A rebuild (a filter, a sort) does not hold the place: the offset stands, as before.
        scroll(t, toTop: 20)
        let offsetBefore = t.scroll.contentView.bounds.minY
        shown.removeSubrange(0...3)
        t.coordinator.showRows(shown)
        XCTAssertEqual(t.scroll.contentView.bounds.minY, offsetBefore, accuracy: 0.5)
    }

    func testTheTablesLastSelectedRowIsTheModelsCursor() async throws {
        let (model, _) = try await model(rows: 12)
        let t = table(model)
        model.selection = [model.displayed[8].id]
        model.extendSelectionInList(-1)
        model.extendSelectionInList(-1)
        t.coordinator.syncSelection(model.selection)
        XCTAssertEqual(t.table.selectedRowIndexes, IndexSet(6...8))
        XCTAssertEqual(t.table.selectedRow, 6, "a plain arrow in the table moves on from the cursor")

        // The table reporting a ⇧-click to row 10 keeps the anchor and moves the cursor.
        t.table.selectRowIndexes(IndexSet(8...10), byExtendingSelection: false)
        t.table.selectRowIndexes(IndexSet(integer: 10), byExtendingSelection: true)
        t.coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        XCTAssertEqual(model.selection, ids(model, 8...10))
        XCTAssertEqual(model.selectionAnchor, model.displayed[8].id)
        XCTAssertEqual(model.selectionCursor, model.displayed[10].id)
    }

    func testTheRowOnViewIsMarkedAndSpoken() async throws {
        let (model, _) = try await model(rows: 6)
        let t = table(model)
        t.scroll.layoutSubtreeIfNeeded()
        func rowView(_ row: Int) throws -> ListRowView {
            try XCTUnwrap(t.table.rowView(atRow: row, makeIfNecessary: true) as? ListRowView, "row \(row) is the list's row")
        }
        t.coordinator.markFileOnView(model.displayed[2].path)
        XCTAssertTrue(try rowView(2).isOnView)
        XCTAssertEqual(try rowView(2).accessibilityLabel(), "on view", "VoiceOver hears it")
        XCTAssertFalse(try rowView(1).isOnView)
        XCTAssertNil(try rowView(1).accessibilityLabel())

        t.coordinator.markFileOnView(model.displayed[4].path)
        XCTAssertFalse(try rowView(2).isOnView, "the mark moves with the file")
        XCTAssertTrue(try rowView(4).isOnView)

        // Rows move under the row views: the mark follows the file, not the row number.
        t.coordinator.showRows(Array(model.displayed.dropFirst(2)))
        t.coordinator.remarkFileOnView()
        XCTAssertTrue(try rowView(2).isOnView, "the file on view is the third row now")
        XCTAssertFalse(try rowView(3).isOnView)
        t.coordinator.markFileOnView(nil)
        XCTAssertFalse(try rowView(2).isOnView)
    }

    /// The render guard for the marker: the outline draws, and stands out (3:1, the WCAG floor for a graphic)
    /// from what is behind it in each row state, in light and dark.
    func testTheOnViewOutlineDrawsInEveryRowStateInLightAndDark() async throws {
        let (model, _) = try await model(rows: 4)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (state, selected, emphasized) in [("active", true, true), ("inactive", true, false),
                                                  ("unselected", false, false)] {
                let t = table(model, appearance: appearance)
                t.table.selectRowIndexes(selected ? IndexSet([0, 1]) : [], byExtendingSelection: false)
                t.coordinator.markFileOnView(model.displayed[0].path)
                for row in 0..<2 {
                    let view = try XCTUnwrap(t.table.rowView(atRow: row, makeIfNecessary: true))
                    view.isEmphasized = emphasized
                    view.needsDisplay = true
                }
                let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: t.scroll, size: t.scroll.frame.size))
                writeRenderArtifact(data, named: "w40-on-view-\(name)-\(state).png")
                let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
                let scale = CGFloat(image.width) / t.scroll.frame.width
                func luminance(row: Int, x: CGFloat) throws -> Double {
                    let rect = t.scroll.convert(t.table.rect(ofRow: row), from: t.table)
                    let top = t.scroll.isFlipped ? rect.minY : t.scroll.frame.height - rect.maxY
                    let px = CGRect(x: x * scale, y: (top + rect.height / 2) * scale, width: 1, height: 1).integral
                    let crop = try XCTUnwrap(image.cropping(to: px))
                    return try XCTUnwrap(InkContrast.relativeLuminances(crop).first)
                }
                // The outline is 2 pt wide, 0.5 pt in from the row's edge; the middle of the row's left end is clear
                // of any cell, which starts after the half intercell space.
                let edge = 1.5 as CGFloat, inside = 3.5 as CGFloat
                let marked = try luminance(row: 0, x: edge), behind = try luminance(row: 0, x: inside)
                let ratio = InkContrast.ratio(marked, behind)
                print("[W40.onview] \(name) \(state): outline \(marked), row \(behind), contrast \(ratio)")
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(name) \(state): the outline stands out from its row")
                let plain = try luminance(row: 1, x: edge), plainBehind = try luminance(row: 1, x: inside)
                XCTAssertLessThan(InkContrast.ratio(plain, plainBehind), 1.2, "\(name) \(state): an unmarked row has none")
            }
        }
    }
}
