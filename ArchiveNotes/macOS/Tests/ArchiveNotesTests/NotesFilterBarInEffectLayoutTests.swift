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
}
