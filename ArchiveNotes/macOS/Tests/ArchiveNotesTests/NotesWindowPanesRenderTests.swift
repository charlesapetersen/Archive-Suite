import XCTest
import SwiftUI
import AppKit
@testable import ArchiveNotes

/// W40.notes-window-panes (owner session notes-2 row 22): with the tag bar under the note hidden, the inspector edits
/// the tags. Lays the real tag editor out headlessly, both ways, over a scratch store (never the real one) and checks
/// it draws; XCUITest sees the accessibility tree, not pixels.
@MainActor
final class NotesWindowPanesRenderTests: XCTestCase {
    private var root: URL!
    private var index: NotesIndex!
    private var model: NotesModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-panes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        model = NotesModel(organization: org, index: index, noteStore: NoteStore(root: root))
    }

    override func tearDown() async throws {
        await index.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// Draws `host` into a bitmap and counts pixels that differ from its top-left (background) pixel.
    private func inkedPixels(_ host: NSView) throws -> Int {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let background = rep.colorAt(x: 0, y: 0)
        var inked = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where rep.colorAt(x: x, y: y) != background { inked += 1 }
        }
        return inked
    }

    private func host(inInspector: Bool, width: CGFloat) -> NSHostingView<some View> {
        let t = Date(timeIntervalSince1970: 0)
        let item = ItemSummary(id: UUID(), title: "Memo", kind: .note, date: nil, datePrecision: nil,
                               dateUncertain: false, sortDate: nil, quality: nil,
                               created: t, modified: t, mtime: 0, managedTags: ["Labor", "Strikes"])
        let host = NSHostingView(rootView: NoteTagBar(model: model, item: item, inInspector: inInspector)
            .frame(width: width, alignment: .topLeading)
            .background(Color.white))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 160)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testInspectorTagsDrawWithTheFieldUnderTheTokens() throws {
        let inspector = host(inInspector: true, width: 240)
        XCTAssertGreaterThan(try inkedPixels(inspector), 300, "the inspector's tags draw")
        XCTAssertFalse(views(NSTextField.self, in: inspector).isEmpty, "the inspector offers the add-tag field")

        let bar = host(inInspector: false, width: 600)
        XCTAssertGreaterThan(try inkedPixels(bar), 300, "the tag bar still draws")
        // The bar is one line; the inspector stacks its title, the tokens and the field.
        XCTAssertGreaterThan(inspector.fittingSize.height, bar.fittingSize.height + 20,
                             "the inspector's tags stack: \(inspector.fittingSize.height) vs \(bar.fittingSize.height)")
    }
}
