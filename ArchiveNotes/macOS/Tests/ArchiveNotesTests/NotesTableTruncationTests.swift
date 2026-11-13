import AppKit
import ArchiveCore
import ArchiveCoreUI
import SwiftUI
import XCTest
@testable import ArchiveNotes

/// W40.fix-notes-list-overrun: accessibility bounds can fit while the glyphs draw across
/// neighbouring columns. Render the production cell factory in a real table, with an empty
/// column after the text so any escaped ink is observable. No window or real store is opened.
/// With `usesAutomaticRowHeights` restored (the pre-W40.fix-notes-row-clip table) this fails: the title
/// field sizes to its text, 981 pt in a 180 pt column, and draws across the columns after it.
@MainActor
final class NotesTableTruncationTests: XCTestCase {
    func testLongTextStaysInsideItsTableColumn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NotesIndex(url: root.appendingPathComponent("index.sqlite"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let model = NotesModel(organization: organization)
        let stamp = Date(timeIntervalSince1970: 0)
        let item = ItemSummary(
            id: UUID(), title: "Memorandum to the Governor regarding the 1978 budget and its consequences "
                + "for local government finance, county services, school districts, with attachments",
            kind: .note, date: "1965-11-17", datePrecision: .day, dateUncertain: false,
            sortDate: 19651117, quality: 2, created: stamp, modified: stamp, mtime: 0,
            managedTags: ["Department of Finance", "Correspondence", "Governor's Office", "Budget"],
            sentWith: ArchiveDate(year: 1966))
        model.replaceItems([item])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        let view = NotesTableView(model: nav, selection: .constant([]), onDoubleClick: {},
                                  buildContextMenu: { _ in nil })

        for column in ["title", "date", "tags"] {
            try assertContained(view, itemID: item.id, column: column, name: column)
        }
        let first = try await organization.createFolder(name: "First")
        let second = try await organization.createFolder(name: "Second")
        try await organization.addMembership(item: item.id, folder: first.id)
        try await organization.addMembership(item: item.id, folder: second.id)
        nav.recompute()
        XCTAssertEqual(nav.instanceCounts[item.id], 2, "exercise the attributed replicated-title path")
        try assertContained(view, itemID: item.id, column: "title", name: "replicated-title")
        await index.close()
    }

    /// W40.suite-reader-notes-consistency (owner, Notes session 2 row 12): the Tags column's chips wrap as the
    /// Reader's do and the row grows to hold them; a column wide enough for one line gives the row back its one-line
    /// height, and hiding the column does too. A selected row's chips are outlined, at the same height.
    func testTagsWrapAndTheRowGrowsToHoldThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NotesIndex(url: root.appendingPathComponent("index.sqlite"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let model = NotesModel(organization: organization)
        let stamp = Date(timeIntervalSince1970: 0)
        let tags = ["Department of Finance", "Correspondence", "Governor's Office", "Budget"]
        let tagged = ItemSummary(id: UUID(), title: "Tagged", kind: .note, date: nil, datePrecision: nil,
                                 dateUncertain: false, sortDate: nil, quality: nil, created: stamp, modified: stamp,
                                 mtime: 0, managedTags: tags)
        let bare = ItemSummary(id: UUID(), title: "Bare", kind: .note, date: nil, datePrecision: nil,
                               dateUncertain: false, sortDate: nil, quality: nil, created: stamp, modified: stamp,
                               mtime: 0, managedTags: [])
        model.replaceItems([tagged, bare])
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        let host = NSHostingView(rootView: NotesTableView(model: nav, selection: .constant([]), onDoubleClick: {},
                                                          buildContextMenu: { _ in nil }))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 300)
        host.layoutSubtreeIfNeeded()
        func findTable(in parent: NSView) -> NSTableView? {
            if let table = parent as? NSTableView { return table }
            return parent.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        let table = try XCTUnwrap(findTable(in: host))
        let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "tags" })
        column.isHidden = false
        let rowOf = { (id: UUID) in try XCTUnwrap(nav.displayed.firstIndex { $0.id == id }) }
        let taggedRow = try rowOf(tagged.id), bareRow = try rowOf(bare.id)
        let font = NSFont.systemFont(ofSize: 13)

        column.width = 180
        table.layoutSubtreeIfNeeded()
        let oneLine = table.rowHeight + table.intercellSpacing.height   // rect(ofRow:) includes the spacing
        let narrow = TagChips.layout(tags, font: font, width: NotesTagsCellView.chipsWidth(inColumn: 180))
        XCTAssertGreaterThan(Set(narrow.chips.map(\.frame.minY)).count, 1, "four tags wrap in a 180 pt column")
        XCTAssertGreaterThan(table.rect(ofRow: taggedRow).height, oneLine + 10, "the row grows to hold its chips")
        XCTAssertEqual(table.rect(ofRow: bareRow).height, oneLine, "a row with no tags keeps one line")
        let index0 = try XCTUnwrap(table.tableColumns.firstIndex(of: column))
        let cell = try XCTUnwrap(table.view(atColumn: index0, row: taggedRow, makeIfNecessary: true)
                                 as? NotesTagsCellView)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.chips.titles, tags)
        XCTAssertEqual(cell.chips.frame.height, narrow.height, accuracy: 0.5, "the cell shows every line of chips")
        XCTAssertLessThanOrEqual(cell.chips.frame.maxY, cell.bounds.height + 0.5, "the chips stay inside the row")
        XCTAssertEqual(cell.chips.accessibilityValue() as? String, tags.joined(separator: ", "))

        let before = table.rect(ofRow: taggedRow).height
        cell.backgroundStyle = .emphasized
        XCTAssertTrue(cell.chips.emphasized, "a selected row's chips are outlined")
        XCTAssertEqual(table.rect(ofRow: taggedRow).height, before, "selecting never changes the row's height")

        column.width = 600
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.rect(ofRow: taggedRow).height, oneLine, "one line of chips fits a wide column")

        column.width = 180
        table.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(table.rect(ofRow: taggedRow).height, oneLine + 10)
        column.isHidden = true
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        XCTAssertEqual(table.rect(ofRow: taggedRow).height, oneLine, "with the Tags column hidden every row is one line")
        await index.close()
    }

    private func assertContained(_ view: NotesTableView, itemID: UUID,
                                 column: String, name: String) throws {
        // Host the real bridge, so production row sizing, cells and constraints all participate.
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 100)
        host.layoutSubtreeIfNeeded()
        func findTable(in parent: NSView) -> NSTableView? {
            if let table = parent as? NSTableView { return table }
            return parent.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        let table = try XCTUnwrap(findTable(in: host))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        scroll.appearance = NSAppearance(named: .aqua)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .white
        table.headerView = nil
        // Leave one real column and one empty sentinel. Hide the others without touching defaults.
        for col in table.tableColumns { col.isHidden = col.identifier.rawValue != column }
        let tested = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == column })
        tested.width = 180
        let empty = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("empty"))
        empty.width = 500
        table.addTableColumn(empty)
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        let testedIndex = table.tableColumns.firstIndex(of: tested)!
        let cell = try XCTUnwrap(table.view(atColumn: testedIndex, row: 0, makeIfNecessary: true) as? NSTableCellView)
        table.layoutSubtreeIfNeeded()
        // The Tags column draws chips, not a text field (W40.suite-reader-notes-consistency).
        let field: NSView = try XCTUnwrap(column == "tags" ? (cell as? NotesTagsCellView)?.chips : cell.textField)
        let columnRect = table.rect(ofColumn: testedIndex)
        XCTAssertLessThanOrEqual(table.convert(field.bounds, from: field).maxX, columnRect.maxX + 0.5,
                                 "\(name): the field must yield to its column width")

        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w40-notes-\(name).png")
        try data.write(to: url)
        print("ARTIFACT \(name): \(url.path)")
        let row = table.convert(table.rect(ofRow: 0), to: scroll)
        let scale = CGFloat(bitmap.pixelsWide) / scroll.frame.width
        let top = scroll.isFlipped ? row.minY : scroll.frame.height - row.maxY
        let rowPixels = Int(top * scale)..<Int((top + row.height) * scale)
        let edge = Int((columnRect.maxX + 1) * scale)
        func inkCount(_ xs: Range<Int>) -> Int {
            var count = 0
            for y in rowPixels {
                for x in xs {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(inkCount(Int(columnRect.midX * scale)..<edge), 20,
                             "\(name): text must actually draw in the far half of its own column")
        XCTAssertEqual(inkCount(edge..<bitmap.pixelsWide), 0,
                       "\(name): text drew into the next column, beyond its accessibility bounds")
    }
}

