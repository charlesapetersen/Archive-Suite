import XCTest
import SwiftUI
import AppKit
@testable import ArchiveNotes

/// W40.fix-notes-template-fields (owner session notes-2 row 18): the inspector shows a template's folders and the
/// fields its notes start with, and a selected folder's template. Lays the real views out headlessly over a scratch
/// store (never the real one) and checks they draw, with the stored values seeded into their controls; XCUITest sees
/// the accessibility tree, not pixels.
@MainActor
final class TemplateInspectorRenderTests: XCTestCase {
    private var root: URL!
    private var index: NotesIndex!
    private var model: NotesModel!
    private var org: OrganizationStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-tplinspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        org = OrganizationStore(index: index)
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

    func testTemplateInspectorDrawsItsFolderAndSeedsItsFields() async throws {
        let created = await model.createTemplate(name: "Letter", kind: .note)
        let tid = try XCTUnwrap(created)
        await model.setTemplateDate("1968-03", precision: .month, for: tid)
        await model.addTemplateTag("labor", to: tid)
        let folder = try await org.createFolder(name: "Correspondence").id
        model.rebuild()
        await model.assignTemplate(tid, to: folder)
        let template = try XCTUnwrap(model.templates.first { $0.id == tid })

        let host = NSHostingView(rootView: TemplateInspector(model: model, template: template)
            .frame(width: 300, alignment: .topLeading))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        host.layoutSubtreeIfNeeded()
        // One more turn: the fields are seeded in onAppear.
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()

        let texts = views(NSTextField.self, in: host).map(\.stringValue)
        XCTAssertTrue(texts.contains("1968-03"), "the date field is seeded with the stored date, saw \(texts)")
        XCTAssertFalse(views(NSTextField.self, in: host).contains { $0.placeholderString == "One author per line" },
                       "a template has no authors field (W40.notes-remove-authors)")
        XCTAssertGreaterThan(try inkedPixels(host), 500, "the inspector draws")
        XCTAssertGreaterThan(host.fittingSize.height, 250, "folders and three fields stack, saw \(host.fittingSize.height)")
    }

    func testFolderInspectorDrawsTheFolderTemplateChoice() async throws {
        let created = await model.createTemplate(name: "Interview", kind: .note)
        let tid = try XCTUnwrap(created)
        let folder = try await org.createFolder(name: "Oral histories").id
        model.rebuild()
        await model.assignTemplate(tid, to: folder)
        let node = try XCTUnwrap(model.assignableFolders.first { $0.node.id == folder }?.node)

        let host = NSHostingView(rootView: FolderTemplateInspector(model: model, folder: node, showTemplates: {})
            .frame(width: 300, alignment: .topLeading))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(try inkedPixels(host), 300, "the folder inspector draws")
        // What it says, from the same values the view reads (the headless host has no accessibility tree to read).
        let own = model.assignedTemplateID(folder)
        XCTAssertEqual(own, tid)
        XCTAssertTrue(FolderTemplateInspector.templateNote(own: own, effective: model.effectiveTemplate(for: folder),
                                                           hasTemplates: true).contains("“Interview”"))
        let child = try await org.createFolder(name: "1970s", parent: folder).id
        model.rebuild()
        XCTAssertTrue(FolderTemplateInspector.templateNote(own: nil, effective: model.effectiveTemplate(for: child),
                                                           hasTemplates: true).hasPrefix("Inherited from a parent folder"))
        XCTAssertTrue(FolderTemplateInspector.templateNote(own: nil, effective: nil, hasTemplates: true)
            .contains("starts blank"))
    }
}
