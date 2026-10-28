import AppKit
import ArchiveCore
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
            authors: [], sortDate: 19651117, quality: 2, created: stamp, modified: stamp, mtime: 0,
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
        let field = try XCTUnwrap(cell.textField)
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

