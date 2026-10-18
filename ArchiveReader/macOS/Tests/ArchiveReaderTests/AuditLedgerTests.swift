import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.audit-ledger — Safety Protocol §12: every tag change the Reader makes leaves one append-only
/// ledger line, written outside the archive. Driven through the same `NavigationModel` paths the UI
/// takes, on scratch `mktemp` fixtures, with the shared ledger pointed at a scratch file per test.
@MainActor
final class AuditLedgerTests: XCTestCase {

    private var ledgerURL: URL!
    private var savedLedgerURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AuditLedgerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit-ledger.jsonl")
        AuditLedger.shared.fileURL = ledgerURL
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    private func makeRoot(files names: [String]) throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AuditLedgerTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try names.map { name -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread", "Smith"], forKey: .tagNamesKey)
            return url
        }
        return (root, files)
    }

    private func select(_ urls: [URL], in model: NavigationModel) {
        model.selection = Set(model.library.files.filter { f in urls.contains { $0.path == f.url.path } }.map(\.id))
        XCTAssertEqual(model.selectedFiles.count, urls.count, "precondition: the selection resolves")
    }

    private func inode(_ url: URL) -> UInt64? {
        var st = stat()
        return stat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    func testABulkMarkIsOneGroupWithALinePerFile() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        select(fixture.files, in: model)
        model.mark(.read)
        XCTAssertEqual(model.statusMessage, "Marked 2 Read.", "precondition: both files were marked")

        let entries = AuditLedger.shared.entries()
        XCTAssertEqual(entries.count, 2, "one line per file written")
        XCTAssertEqual(Set(entries.map(\.group)).count, 1, "a bulk action is one group, as it is one undo")
        XCTAssertEqual(Set(entries.map(\.path)), Set(fixture.files.map(\.path)))
        for e in entries {
            XCTAssertEqual(e.op, .readState)
            XCTAssertNil(e.undoes)
            XCTAssertNil(e.unverified)
            XCTAssertEqual(e.before, ["Unread", "Smith"])
            XCTAssertEqual(Set(e.after), ["Read", "Smith"])
            XCTAssertEqual(e.delta, .init(add: ["Read"], remove: ["Unread"], label: nil),
                           "the delta names only what changed — the subject tag is not in it")
            XCTAssertEqual(e.inverse, .init(add: ["Unread"], remove: ["Read"], label: nil))
            XCTAssertNotNil(e.bookmark, "a bookmark, so the file can be found again after a move")
            XCTAssertEqual(e.file?.inode, inode(URL(fileURLWithPath: e.path)))
        }
    }

    func testAnUndoIsRecordedAndNamesTheGroupItUndoes() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        select(fixture.files, in: model)
        model.mark(.read)
        let forwardGroup = try XCTUnwrap(AuditLedger.shared.entries().first?.group)

        model.undoLast()
        let entries = AuditLedger.shared.entries()
        XCTAssertEqual(entries.count, 5, "one durable attempt marker, then two verified inverse writes")
        let undo = Array(entries.suffix(2))
        XCTAssertEqual(undo.map(\.op), [.undo, .undo])
        XCTAssertEqual(Set(undo.map(\.undoes)), [forwardGroup])
        XCTAssertEqual(Set(undo.map(\.group)).count, 1)
        XCTAssertNotEqual(undo[0].group, forwardGroup)
        XCTAssertEqual(undo[0].delta, .init(add: ["Unread"], remove: ["Read"], label: nil))
    }

    func testANoOpWritesNoLine() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        select(fixture.files, in: model)
        model.mark(.unread)   // already Unread
        XCTAssertEqual(AuditLedger.shared.entries().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path), "nothing changed, nothing written")
    }

    func testARefusedWriteLeavesNoLine() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        XCTAssertThrowsError(try TagWriter.apply(TagDelta(add: ["X"]), to: fixture.files[0],
                                                 expecting: FileIdentity.capture(fixture.root)),
                             "a wrong identity is refused before any write")
        try FileManager.default.removeItem(at: fixture.files[0])
        XCTAssertThrowsError(try TagWriter.apply(TagDelta(add: ["X"]), to: fixture.files[0]))
        XCTAssertEqual(AuditLedger.shared.entries().count, 0)
    }

    func testInlineEditsAndRenamesAreRecorded() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        let a = try XCTUnwrap(model.library.files.first { $0.url.path == fixture.files[0].path })
        model.commitSubjectEdit(from: ["Smith"], to: ["Smith", "Jones"], for: a)
        model.renameTag(from: "Smith", to: "Smyth")

        let entries = AuditLedger.shared.entries()
        XCTAssertEqual(entries.map(\.op), [.apply, .rename, .rename])
        XCTAssertEqual(entries[0].delta.add, ["Jones"])
        XCTAssertEqual(Set(entries.suffix(2).map(\.group)).count, 1, "a corpus-wide rename is one group")
        XCTAssertNotEqual(entries[0].group, entries[1].group)
    }

    func testTheLedgerIsAppendOnlyAndSurvivesATornLine() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        _ = try TagWriter.setReadState(.read, on: fixture.files[0])
        let first = try Data(contentsOf: ledgerURL)

        // A crash mid-append leaves a partial last line; the history before it must stay readable.
        let h = try FileHandle(forWritingTo: ledgerURL)
        try h.seekToEnd(); try h.write(contentsOf: Data(#"{"v":1,"op":"ap"#.utf8)); try h.close()

        _ = try TagWriter.setReadState(.read, on: fixture.files[1])
        let after = try Data(contentsOf: ledgerURL)
        XCTAssertEqual(after.prefix(first.count), first, "earlier lines are never rewritten")
        // The torn fragment is skipped; the entries either side of it both read back.
        XCTAssertEqual(AuditLedger.shared.entries().map(\.path), fixture.files.map(\.path))
    }

    func testTheProductionLedgerIsInTheAppsSupportDirectoryAndTestsAreNot() throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertFalse(AuditLedger.defaultFileURL().path.hasPrefix(support.path),
                       "the unit-test host never writes the owner's ledger")
        XCTAssertEqual(AuditLedger.defaultFileURL().lastPathComponent, "audit-ledger.jsonl")
    }
}
