import XCTest
import SwiftUI
import AppKit
@testable import ArchiveNotes

/// W40.fix-notes-clear-all-advanced (owner session notes-2 row 26): an Advanced Search in effect is plain, as a
/// chip in the filter bar's In effect row, and Clear All takes the row away. Lays the real bar out headlessly at the
/// list's narrow width; the UITest (`NotesAdvancedSearchUITests`) checks the chip in the accessibility tree.
@MainActor
final class NotesFilterBarInEffectLayoutTests: XCTestCase {
    func testAdvancedSearchAddsTheInEffectRowAndClearAllRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-ineffect-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        let model = NotesModel(organization: store, index: index)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)

        func barHeight() -> CGFloat {
            let host = NSHostingView(rootView: NotesFilterBar(nav: nav).frame(width: 360))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        let plain = barHeight()
        var title = NotesSearchRule(field: .title)
        title.text = "budget"
        nav.runAdvancedSearch(NotesAdvancedSearch(rules: [title]))
        XCTAssertEqual(nav.activeFilterChips.map(\.facet), [.advancedSearch])
        let withSearch = barHeight()
        XCTAssertGreaterThan(withSearch, plain + 12,
                             "the In effect row adds a line to the bar, saw \(plain) then \(withSearch)")
        nav.clearAll()
        XCTAssertEqual(barHeight(), plain, accuracy: 1, "Clear All leaves no row behind")

        await index.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// W40.suite-reader-notes-consistency (owner, Notes session 2 row 21: "the filtering UI should match the
    /// Reader's"): the Reader's arrangement. Kind, quality, the tag field and Dates share the first row, the search
    /// has a row of its own under it, the year range is in the Dates popover rather than two fields in the bar, and at
    /// the list's narrowest nothing runs past the bar's edge.
    func testTheBarIsLaidOutAsTheReaders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-filterbar-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        let nav = NotesNavigationModel(model: NotesModel(organization: store, index: index), defaultKind: .note)

        func host(width: CGFloat) -> NSView {
            let host = NSHostingView(rootView: NotesFilterBar(nav: nav).frame(width: width))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            host.layoutSubtreeIfNeeded()
            return host
        }
        let wide = host(width: 1000)
        let tagField = try XCTUnwrap(views(NSTokenField.self, in: wide).first, "the tag filter's field")
        let search = try XCTUnwrap(views(NSTextField.self, in: wide).first { $0.placeholderString == "Search notes…" },
                                   "the search field")
        let kind = try XCTUnwrap(views(NSSegmentedControl.self, in: wide).first, "the kind control")
        func frame(_ v: NSView) -> CGRect { v.convert(v.bounds, to: wide) }
        XCTAssertLessThan(abs(frame(tagField).midY - frame(kind).midY), 8,
                          "the tag field is on the kind control's row: \(frame(tagField)) vs \(frame(kind))")
        let below = wide.isFlipped ? frame(search).minY >= frame(kind).maxY : frame(search).maxY <= frame(kind).minY
        XCTAssertTrue(below, "the search has its own row under the filters: \(frame(search)) vs \(frame(kind))")
        XCTAssertFalse(views(NSTextField.self, in: wide).contains { ["From", "To"].contains($0.placeholderString) },
                       "the year range is in the Dates popover, not the bar")

        let narrow = host(width: NotesLayoutSettings.listMinWidth)
        for control in views(NSControl.self, in: narrow) where !control.isHidden {
            let f = control.convert(control.bounds, to: narrow)
            XCTAssertLessThanOrEqual(f.maxX, narrow.bounds.width + 0.5, "\(type(of: control)) runs past the bar: \(f)")
            XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(type(of: control)) starts before the bar: \(f)")
        }

        await index.close()
        try? FileManager.default.removeItem(at: root)
    }
}
