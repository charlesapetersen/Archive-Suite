import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.tag-rename-suite (Tier-2): the Reader's side of the suite's tag change log (SPEC/tag-format.md invariant 8).
/// A rename is recorded with its ledger group as its id; Undo withdraws it and Redo restores it; Notes' changes are
/// offered with their file counts and applied through the ordinary rename (TagWriter, one Undo) without being recorded
/// again. Scratch `mktemp` roots and a scratch ledger only.
@MainActor
final class TagChangeLogReaderTests: XCTestCase {

    private var ledgerURL: URL!
    private var savedLedgerURL: URL!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagChangeLogReaderTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit-ledger.jsonl")
        AuditLedger.shared.fileURL = ledgerURL
        suite = "TagChangeLogReaderTests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    /// a, c: "Lincoln"; b: "lincoln"; d: "Douglass". With a durable root marker unless `marker` is false.
    private func makeRoot(marker: Bool = true) throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagChangeLogReaderTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        if marker { _ = try RootMarker.ensure(at: root, kind: .reader, name: "Scratch") }
        let tags = [["Unread", "Lincoln"], ["Unread", "lincoln"], ["Unread", "Lincoln"], ["Unread", "Douglass"]]
        let files = try zip(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], tags).map { name, t -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(t, forKey: .tagNamesKey)
            return url
        }
        return (root, files)
    }

    private func model(_ root: URL, _ testName: String = #function) -> NavigationModel {
        let model = fixtureNavigationModel(pinnedTo: root, testName)
        model.tagChangeDefaultsSuite = suite
        let deadline = Date().addingTimeInterval(10)
        while model.allSubjects.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return model
    }

    /// `model` for an async test: there the main queue runs only while the test awaits, not while it spins the run loop.
    private func loadedModel(_ root: URL, _ testName: String = #function) async throws -> NavigationModel {
        let model = fixtureNavigationModel(pinnedTo: root, testName)
        model.tagChangeDefaultsSuite = suite
        let deadline = Date().addingTimeInterval(10)
        while model.allSubjects.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.allSubjects.isEmpty, "library loaded")
        return model
    }

    private func tags(_ url: URL) -> [String] {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    private func log(_ root: URL) -> [TagChange] { TagChangeLog.load(root: root).document?.changes ?? [] }

    /// The log is written off the main actor: wait for `condition`.
    private func waitFor(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), what)
    }

    func testARenameIsRecordedWithItsLedgerGroupAndUndoWithdrawsItRedoRestoresIt() throws {
        let fixture = try makeRoot()
        let model = model(fixture.root)
        XCTAssertNotNil(model.tagChangeRoot, "a durable marker, so a log")
        model.renameTag(from: "Lincoln", to: "Abraham Lincoln")
        XCTAssertEqual(Set(tags(fixture.files[1])), ["Unread", "Abraham Lincoln"])
        waitFor("recorded") { log(fixture.root).count == 1 }
        let entry = try XCTUnwrap(log(fixture.root).first)
        XCTAssertEqual(entry.app, TagChangeLog.reader)
        XCTAssertEqual(entry.from, "Lincoln")
        XCTAssertEqual(entry.to, "Abraham Lincoln")
        XCTAssertEqual(entry.id, AuditLedger.shared.entries().first?.group, "its id is the rename's ledger group")

        model.undoLast()
        XCTAssertEqual(Set(tags(fixture.files[1])), ["Unread", "lincoln"])
        waitFor("withdrawn by Undo") { log(fixture.root).first?.withdrawn == true }
        model.redoLast()
        XCTAssertEqual(Set(tags(fixture.files[1])), ["Unread", "Abraham Lincoln"])
        waitFor("restored by Redo") { log(fixture.root).first?.withdrawn == false }
        model.undoLast()
        waitFor("withdrawn by the Redo's Undo") { log(fixture.root).first?.withdrawn == true }
        XCTAssertEqual(log(fixture.root).count, 1, "Undo and Redo record nothing new")
    }

    func testOtherTagEditsNeverTouchTheLog() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let d = try XCTUnwrap(model.library.files.first { $0.url.path == fixture.files[3].path })
        model.applyEdit(.addSubject("Slavery"), to: d)
        model.undoLast()
        await model.refreshTagChangeInbox()   // reads after every queued log write
        XCTAssertEqual(TagChangeLog.load(root: fixture.root), .missing)
    }

    func testWithoutADurableMarkerNothingIsRecorded() throws {
        let fixture = try makeRoot(marker: false)
        let model = model(fixture.root)
        XCTAssertNil(model.tagChangeRoot)
        model.renameTag(from: "Lincoln", to: "Abraham Lincoln")
        XCTAssertEqual(Set(tags(fixture.files[0])), ["Unread", "Abraham Lincoln"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(ContainerFile.folderName).path))
    }

    func testANotesChangeIsOfferedAndAppliedThroughTheRenameWithoutBeingRecordedAgain() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let notes = TagChange(app: TagChangeLog.notes, from: "Lincoln", to: "Emancipation")
        let facet = TagChange(app: TagChangeLog.notes, from: "Douglass", to: "Q1")
        let nobody = TagChange(app: TagChangeLog.notes, from: "Nobody", to: "Somebody")
        try TagChangeLog.record([notes, facet, nobody], root: fixture.root)
        XCTAssertEqual(log(fixture.root).count, 2, "the facet entry is never recorded")

        await model.refreshTagChangeInbox()
        let offer = try XCTUnwrap(model.tagChangeOffers.first)
        XCTAssertEqual(model.tagChangeOffers.count, 1)
        XCTAssertEqual(offer.id, notes.id)
        XCTAssertEqual(offer.count, 3, "case variants are one tag")
        XCTAssertTrue(offer.summary.hasPrefix("Notes renamed “Lincoln” to “Emancipation”"))

        model.applyTagChange(offer)
        XCTAssertEqual(Set(tags(fixture.files[1])), ["Unread", "Emancipation"])
        XCTAssertEqual(Set(tags(fixture.files[3])), ["Unread", "Douglass"])
        XCTAssertTrue(model.tagChangeOffers.isEmpty)
        await model.refreshTagChangeInbox()   // reads after every queued log write
        XCTAssertEqual(log(fixture.root).count, 2, "applying it records nothing new")
        XCTAssertEqual(model.undoDepth, 1, "one Undo step")
        await model.refreshTagChangeInbox()
        XCTAssertTrue(model.tagChangeOffers.isEmpty, "handled, so not offered again")

        // Notes undoes it: the Reader says so once and changes nothing.
        try TagChangeLog.setWithdrawn([notes.id], true, root: fixture.root)
        await model.refreshTagChangeInbox()
        let notice = try XCTUnwrap(model.tagChangeOffers.first)
        XCTAssertTrue(notice.isWithdrawal)
        model.dismissTagChange(notice)
        await model.refreshTagChangeInbox()
        XCTAssertTrue(model.tagChangeOffers.isEmpty)
        XCTAssertEqual(Set(tags(fixture.files[1])), ["Unread", "Emancipation"])
    }

    func testSkipIsNotAskedAgain() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        try TagChangeLog.record([TagChange(app: TagChangeLog.notes, from: "Douglass", to: "Frederick Douglass")],
                                root: fixture.root)
        await model.refreshTagChangeInbox()
        model.dismissTagChange(try XCTUnwrap(model.tagChangeOffers.first))
        await model.refreshTagChangeInbox()
        XCTAssertTrue(model.tagChangeOffers.isEmpty)
        XCTAssertEqual(Set(tags(fixture.files[3])), ["Unread", "Douglass"])
    }
}
