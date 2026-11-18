import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.reader-jpeg-read: Mark Read and Unread work on the JPEGS tree beside MAIN, undo reverses them there,
/// every other tag change stays inside MAIN, and the status line says why a file was not changed.
/// Scratch files only.
@MainActor
final class ReadStateJPEGTreeTests: XCTestCase {

    private var savedLedgerURL: URL!
    private var ledgerRoot: URL!

    override func setUp() async throws {
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("JPEGReadLedger-\(UUID())")
        AuditLedger.shared.fileURL = ledgerRoot.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerRoot)
    }

    private struct Fixture { let parent, pdf, jpeg, outside: URL }

    /// The granted common parent, with MAIN, its JPEGS sibling and a third folder that is neither.
    private func makeParent() throws -> Fixture {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReadStateJPEGTreeTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        func file(_ folder: String, _ name: String) throws -> URL {
            let box = parent.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("Box 1")
            try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
            let url = box.appendingPathComponent(name)
            try Data("scratch \(name)".utf8).write(to: url)
            try setTags(["Unread", "Subject/Letters"], on: url)
            return url
        }
        return Fixture(parent: parent,
                       pdf: try file(ReaderArchiveLayout.mainDirectoryName, "letter.pdf"),
                       jpeg: try file(ReaderArchiveLayout.jpegDirectoryName, "letter.jpg"),
                       outside: try file("Other", "stray.pdf"))
    }

    private func setTags(_ tags: [String], on url: URL) throws {
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// A fresh URL each time: a reused `URL` caches its resource values and would never see the write.
    private func tags(_ url: URL) throws -> [String] {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func row(_ url: URL, in model: NavigationModel) throws -> ArchiveFile {
        try XCTUnwrap(model.library.files.first { $0.url.path == url.path }, "discovery lists \(url.lastPathComponent)")
    }

    private func select(_ urls: [URL], in model: NavigationModel) throws {
        model.recompute()
        let ids = Set(try urls.map { try row($0, in: model).id })
        model.selection = ids
        XCTAssertEqual(model.selectedFiles.count, urls.count, "precondition: the selection resolves")
    }

    func testMarkReadWritesAJPEGAndUndoReversesIt() throws {
        let fixture = try makeParent()
        let model = fixtureNavigationModel(pinnedTo: fixture.parent)
        try select([fixture.jpeg], in: model)

        model.mark(.read)

        XCTAssertEqual(Set(try tags(fixture.jpeg)), ["Read", "Subject/Letters"], "the JPEG's read state changed")
        XCTAssertEqual(model.statusMessage, "Marked 1 Read.")
        XCTAssertEqual(try row(fixture.jpeg, in: model).readState, .read, "the row shows the verified write")
        XCTAssertEqual(model.undoDepth, 1, "a JPEG mark is undoable like a PDF one")

        model.undoLast()
        XCTAssertEqual(Set(try tags(fixture.jpeg)), ["Unread", "Subject/Letters"])
        XCTAssertEqual(model.undoDepth, 0)
        XCTAssertEqual(model.redoDepth, 1, "and redoable")
        model.redoLast()
        XCTAssertEqual(Set(try tags(fixture.jpeg)), ["Read", "Subject/Letters"])
    }

    func testTheReadCellTogglesAJPEG() throws {
        let fixture = try makeParent()
        let model = fixtureNavigationModel(pinnedTo: fixture.parent)
        model.toggleReadState(for: try row(fixture.jpeg, in: model))
        XCTAssertEqual(Set(try tags(fixture.jpeg)), ["Read", "Subject/Letters"])
    }

    func testClearReadStateWorksOnAJPEG() throws {
        let fixture = try makeParent()
        let model = fixtureNavigationModel(pinnedTo: fixture.parent)
        model.clearReadState(for: try row(fixture.jpeg, in: model))
        XCTAssertEqual(try tags(fixture.jpeg), ["Subject/Letters"])
        model.undoLast()
        XCTAssertEqual(Set(try tags(fixture.jpeg)), ["Unread", "Subject/Letters"], "and its undo is allowed there")
    }

    /// Review finding: undo follows a moved file by bookmark. A subject change made in MAIN must not be
    /// reversed once the file sits in the JPEGS tree, where only read state may be written.
    func testASubjectUndoIsRefusedAfterTheFileMovesIntoTheJPEGTree() throws {
        let fixture = try makeParent()
        let model = fixtureNavigationModel(pinnedTo: fixture.parent)
        XCTAssertTrue(model.commitSubjectEdit(from: [], to: ["Moved"],
                                              for: try row(fixture.pdf, in: model)))
        XCTAssertTrue(try tags(fixture.pdf).contains("Moved"), "precondition: the subject was written")
        XCTAssertEqual(model.undoDepth, 1)

        let moved = fixture.jpeg.deletingLastPathComponent().appendingPathComponent("moved.pdf")
        try FileManager.default.moveItem(at: fixture.pdf, to: moved)
        model.undoLast()

        XCTAssertTrue(try tags(moved).contains("Moved"), "no subject change is written in the JPEGS tree")
        XCTAssertTrue(model.statusMessage.contains("could not be undone"), model.statusMessage)
    }

    func testOtherTagChangesStayInsideMain() throws {
        let fixture = try makeParent()
        let model = fixtureNavigationModel(pinnedTo: fixture.parent)
        let jpegRow = try row(fixture.jpeg, in: model)
        XCTAssertEqual(model.reverifyCacheRows([jpegRow]).outside, 1, "a subject or colour change is refused there")
        XCTAssertEqual(model.reverifyCacheRows([jpegRow], readState: true).files.count, 1)
        XCTAssertFalse(model.isInsideReadStateTree(fixture.outside))
        XCTAssertEqual(model.readStateRoots().count, 2, "MAIN and JPEGS, never the granted parent itself")
    }

    func testAMixedMarkSaysWhatHappenedToEachFile() throws {
        let fixture = try makeParent()
        let already = fixture.pdf.deletingLastPathComponent().appendingPathComponent("done.pdf")
        try Data("scratch done".utf8).write(to: already)
        try setTags(["Read"], on: already)
        let model = fixtureNavigationModel(pinnedTo: fixture.parent)
        try select([fixture.pdf, fixture.jpeg, fixture.outside, already], in: model)
        // A marker file: its read-state tag went away on disk after discovery. Mark Read never adds one
        // (Safety §10), so it is left alone and the status line says so.
        try setTags(["Subject/Letters"], on: fixture.pdf)

        model.mark(.read)

        XCTAssertEqual(try tags(fixture.pdf), ["Subject/Letters"], "no read-state tag was added")
        XCTAssertEqual(Set(try tags(fixture.jpeg)), ["Read", "Subject/Letters"])
        XCTAssertEqual(Set(try tags(fixture.outside)), ["Unread", "Subject/Letters"], "outside both trees: untouched")
        XCTAssertEqual(model.statusMessage,
                       "Marked 1 Read. 1 was already Read. 1 has no Read or Unread tag, so it was left alone. "
                       + "1 is outside the folders whose tags Reader changes, so it was not changed.")
    }

    func testTheStatusLineWording() {
        typealias C = NavigationModel.MarkCounts
        XCTAssertEqual(NavigationModel.markStatus(.read, C(changed: 2)), "Marked 2 Read.")
        XCTAssertEqual(NavigationModel.markStatus(.read, C()), "Marked 0 Read.")
        XCTAssertEqual(NavigationModel.markStatus(.unread, C(noReadState: 3)),
                       "3 have no Read or Unread tag, so they were left alone.")
        XCTAssertEqual(NavigationModel.markStatus(.read, C(changed: 1, failed: 1)), "Marked 1; 1 could not update.")
        XCTAssertEqual(NavigationModel.markStatus(.unread, C(already: 2, outside: 2)),
                       "2 were already Unread. 2 are outside the folders whose tags Reader changes, "
                       + "so they were not changed.")
    }
}
