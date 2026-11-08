import XCTest
import AppKit
@testable import ArchiveReader

/// The real header chooser, with scratch defaults and an off-screen table; no corpus access.
@MainActor
final class ColumnHeaderMenuTests: XCTestCase {
    func testHeaderChoicesStayDisabledAndHideShowPersistsWithoutChangingSort() throws {
        let defaults = fixtureDefaults()
        let model = NavigationModel(defaults: defaults)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        let header = ColumnPickerHeaderView(frame: NSRect(x: 0, y: 0, width: 1200, height: 24))
        table.headerView = header
        AppKitTableView.addColumns(to: table)
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: model, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.applyHiddenColumns(model.effectiveHiddenColumns, to: table)
        header.isColumnAvailable = { model.isColumnAvailable($0) }
        header.currentSort = { model.sort }
        header.onSetColumnVisible = { id, visible in
            model.setColumn(id, visible: visible)
            coordinator.applyHiddenColumns(model.effectiveHiddenColumns, to: table)
        }
        let sortBefore = model.sort
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        func menu() throws -> NSMenu {
            let menu = try XCTUnwrap(header.menu(for: event))
            menu.update()  // The same validation AppKit performs when opening the menu.
            return menu
        }
        func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.first { $0.representedObject as? String == id })
        }
        func invoke(_ item: NSMenuItem) throws {
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        }

        var choices = try menu()
        XCTAssertEqual(choices.items.compactMap { $0.representedObject as? String }.prefix(9),
                       AppKitTableView.columnDefinitions.map(\.id)[...])
        XCTAssertEqual(try item("flag", in: choices).title, "⚑ Flag")
        XCTAssertEqual(try item("warning", in: choices).title, "⚠︎ Needs attention")
        let name = try item("name", in: choices)
        XCTAssertFalse(name.isEnabled)
        XCTAssertEqual(name.state, .on)
        let capture = try item(AppKitTableView.captureMarkerColumnID, in: choices)
        XCTAssertFalse(capture.isEnabled)
        XCTAssertEqual(capture.state, .off)
        try invoke(name)
        try invoke(capture)
        XCTAssertTrue(model.hiddenColumns.isEmpty, "even direct dispatch cannot change disabled choices")

        let typeColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "type" })
        XCTAssertEqual(try item("type", in: choices).state, .on)
        try invoke(try item("type", in: choices))
        XCTAssertTrue(typeColumn.isHidden)
        XCTAssertEqual(model.hiddenColumns, ["type"])
        XCTAssertEqual(AppSettings.hiddenColumns(in: defaults), ["type"])
        XCTAssertEqual(NavigationModel(defaults: defaults).hiddenColumns, ["type"], "a new window remembers the choice")
        choices = try menu()
        XCTAssertEqual(try item("type", in: choices).state, .off, "a hidden column stays in the chooser")
        try invoke(try item("type", in: choices))
        XCTAssertFalse(typeColumn.isHidden)
        XCTAssertTrue(model.hiddenColumns.isEmpty)
        XCTAssertEqual(model.sort, sortBefore, "column choices do not change sorting")
    }

    func testHeaderRendersWithAHiddenColumn() throws {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 1000, height: 200))
        let header = ColumnPickerHeaderView(frame: NSRect(x: 0, y: 0, width: 1000, height: 24))
        table.headerView = header
        AppKitTableView.addColumns(to: table)
        for column in table.tableColumns where ["type", AppKitTableView.captureMarkerColumnID].contains(column.identifier.rawValue) {
            column.isHidden = true
        }
        let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: header, size: CGSize(width: 1000, height: 24)))
        writeRenderArtifact(data, named: "column-header-type-hidden.png")
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        _ = try XCTUnwrap(assertRendersNonBlank(image, "column chooser header"))
    }
}
