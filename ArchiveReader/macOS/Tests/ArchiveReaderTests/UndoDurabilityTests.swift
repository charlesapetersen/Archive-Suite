import XCTest
import ArchiveCore
@testable import ArchiveReader

/// Safety §9/§12 regression tests through the real mark → undoLast path, on scratch files.
/// W40.audit-ledger-undo reverses the original memory-only assertion: history must survive relaunch.
@MainActor
final class UndoDurabilityTests: XCTestCase {

    private var savedLedgerURL: URL!
    private var ledgerRoot: URL!

    override func setUp() async throws {
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("UndoLedger-\(UUID())")
        AuditLedger.shared.fileURL = ledgerRoot.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerRoot)
    }

    private func makeRoot(files names: [String]) throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UndoDurabilityTests-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try names.map { name -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
            return url
        }
        return (root, files)
    }

    /// A fresh URL each time: a reused `URL` caches its resource values and would never see the write.
    private func tags(_ url: URL) throws -> [String] {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func select(_ urls: [URL], in model: NavigationModel) throws {
        model.recompute()   // only listed rows can be selected (W40.fix-reader-phantom-selection)
        let ids = Set(model.library.files.filter { f in urls.contains { $0.path == f.url.path } }.map(\.id))
        XCTAssertEqual(ids.count, urls.count, "precondition: discovery lists every fixture file")
        model.selection = ids
        XCTAssertEqual(model.selectedFiles.count, urls.count, "precondition: the selection resolves")
    }

    func testTheUndoHistorySurvivesARelaunch() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let defaults = fixtureDefaults(pinnedTo: fixture.root)

        let first = NavigationModel(defaults: defaults)
        try select(fixture.files, in: first)
        first.mark(.read)
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"], "precondition: the mark was written to disk")
        XCTAssertEqual(first.undoDepth, 1, "the session that made the change can undo it")

        // Same root, same defaults domain: everything a relaunch would read back.
        let relaunched = NavigationModel(defaults: defaults)
        XCTAssertEqual(relaunched.undoDepth, 1)
        relaunched.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Unread"])
        XCTAssertEqual(relaunched.statusMessage, "Undid 1 change.")
        XCTAssertEqual(NavigationModel(defaults: defaults).undoDepth, 0, "a consumed action never returns")
    }

    func testAPartlyFailedUndoIsReportedAsComplete() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        try select(fixture.files, in: model)
        model.mark(.read)
        XCTAssertEqual(model.statusMessage, "Marked 2 Read.", "precondition: both files were marked")
        XCTAssertEqual(model.undoDepth, 1, "a bulk mark is one undo step")

        // b.pdf goes away (moved off in Finder, say), so its inverse write throws.
        try FileManager.default.removeItem(at: fixture.files[1])

        model.undoLast()

        XCTAssertEqual(try tags(fixture.files[0]), ["Unread"], "the file that could be undone was")
        XCTAssertEqual(model.undoDepth, 0, "a file that is gone is an identity refusal, never kept for a retry")
        XCTAssertTrue(model.statusMessage.contains("1 could not be undone"))
        XCTAssertTrue(model.statusMessage.contains("b.pdf"))
        XCTAssertFalse(model.statusMessage.contains("retry"))
        XCTAssertEqual(fixtureNavigationModel(pinnedTo: fixture.root).undoDepth, 0,
                       "partial attempts consume the whole group, including after relaunch")
    }

    /// Locks a file against tag writes (the user immutable flag), as a cause that may pass.
    private func setLocked(_ url: URL, _ locked: Bool) throws {
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
        if locked { addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) } }
    }

    /// W40.fix-reader-undo-partial: a member that failed for a cause that may pass comes back as its own
    /// undo step, durably, and the retry touches only that file.
    func testAFailedMemberWhoseCauseMayPassCanBeRetried() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let defaults = fixtureDefaults(pinnedTo: fixture.root)
        let model = NavigationModel(defaults: defaults)
        try select(fixture.files, in: model)
        model.mark(.read)
        XCTAssertEqual(model.undoDepth, 1, "precondition: a bulk mark is one undo step")

        try setLocked(fixture.files[1], true)
        model.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Unread"])
        XCTAssertEqual(try tags(fixture.files[1]), ["Read"], "precondition: the lock made b's undo fail")
        XCTAssertEqual(model.statusMessage, "Undid 1 change; 1 could not be undone (b.pdf). Undo again to retry.")
        XCTAssertEqual(model.undoDepth, 1, "the failed member is offered again")

        // a was reversed: a later edit to it must survive the retry, which names b alone.
        try (URL(fileURLWithPath: fixture.files[0].path) as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)
        try setLocked(fixture.files[1], false)
        let relaunched = NavigationModel(defaults: defaults)
        XCTAssertEqual(relaunched.undoDepth, 1, "the retry survives a relaunch")
        relaunched.undoLast()
        XCTAssertEqual(try tags(fixture.files[1]), ["Unread"])
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"], "the retry never re-applies a reversed member")
        XCTAssertEqual(relaunched.statusMessage, "Undid 1 change.")
        XCTAssertEqual(NavigationModel(defaults: defaults).undoDepth, 0)
    }

    /// A cause that never passes is retried a bounded number of times, then dropped, so it cannot block
    /// the older undo steps behind it forever.
    func testARetryIsDroppedAfterTheAttemptLimit() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        try select([fixture.files[0]], in: model)
        model.mark(.read)
        try select([fixture.files[1]], in: model)
        model.mark(.read)
        XCTAssertEqual(model.undoDepth, 2)

        try setLocked(fixture.files[1], true)
        for attempt in 1...AuditLedger.undoAttemptLimit {
            model.undoLast()
            XCTAssertTrue(model.statusMessage.contains("1 could not be undone (b.pdf)"))
            let last = attempt == AuditLedger.undoAttemptLimit
            XCTAssertEqual(model.statusMessage.contains("Undo again to retry"), !last, "attempt \(attempt)")
            XCTAssertEqual(model.undoDepth, last ? 1 : 2, "attempt \(attempt)")
        }
        model.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Unread"], "the older step is reachable again")
        XCTAssertEqual(try tags(fixture.files[1]), ["Read"])
    }

    func testOnlyAnIdentityRefusalIsNeverRetried() {
        XCTAssertFalse(AuditLedger.undoMayBeRetried(after: TagWriteError.identityMismatch("x"), attempt: 1))
        XCTAssertTrue(AuditLedger.undoMayBeRetried(after: TagWriteError.coordinationFailed("x"), attempt: 1))
        XCTAssertTrue(AuditLedger.undoMayBeRetried(after: TagWriteError.unreadable("x"), attempt: 1))
        XCTAssertTrue(AuditLedger.undoMayBeRetried(after: TagWriteError.verificationFailed("x"), attempt: 2))
        XCTAssertFalse(AuditLedger.undoMayBeRetried(after: TagWriteError.coordinationFailed("x"),
                                                    attempt: AuditLedger.undoAttemptLimit))
    }

    /// Found while writing the test above (it first swapped the file rather than deleting it, expecting
    /// §6 to refuse). `undoLast` re-verifies against the identity captured at the original edit, but
    /// `FileIdentity.capture` read `fileResourceIdentifier` through the `URL` it was handed, and a reused
    /// `URL` instance answers from its resource-value cache. The edit and the undo both pass the
    /// `ArchiveFile`'s own `url`, so the check compared the cache with itself and a different file at
    /// that path was re-tagged. Since `W40.fix-identity-url-cache` the capture reads through a new `URL`
    /// for the path (`URL.uncached`), so the swap is seen and the undo refuses the file.
    func testUndoRefusesAFileSwappedUnderItsPath() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        try select(fixture.files, in: model)
        model.mark(.read)
        XCTAssertEqual(model.undoDepth, 1, "precondition: the mark is undoable")

        let swapped = URL(fileURLWithPath: fixture.files[0].path)
        try FileManager.default.removeItem(at: swapped)
        try Data("a different document".utf8).write(to: swapped)
        try (swapped as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)

        model.undoLast()

        XCTAssertEqual(try tags(swapped), ["Read"], "§6: a file swapped under the path must not be re-tagged")
        XCTAssertTrue(model.statusMessage.contains("1 could not be undone"), "identity refusal is surfaced")
    }

    /// The mechanism under the test above, without the model: the same `URL` instance, before and after
    /// the file at its path is replaced.
    func testFileIdentityThroughAReusedURLSeesASwap() throws {
        let fixture = try makeRoot(files: ["c.pdf"])
        let url = fixture.files[0]
        let before = try XCTUnwrap(FileIdentity.capture(url))
        try FileManager.default.removeItem(at: url)
        try Data("a different document".utf8).write(to: URL(fileURLWithPath: url.path))

        let fresh = try XCTUnwrap(FileIdentity.capture(URL(fileURLWithPath: url.path)))
        XCTAssertFalse(fresh.matches(before), "a fresh URL sees the replacement")

        let reused = try XCTUnwrap(FileIdentity.capture(url))
        XCTAssertFalse(reused.matches(before), "the same URL instance must see the replacement too")
    }
    func testRelaunchedUndoPreservesConcurrentTagsAndBytes() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let defaults = fixtureDefaults(pinnedTo: fixture.root)
        let first = NavigationModel(defaults: defaults)
        try select(fixture.files, in: first)
        first.mark(.read)
        let bytes = try fixture.files.map { try Data(contentsOf: $0) }
        // A Finder edit is outside the Reader's ledger.
        try (URL(fileURLWithPath: fixture.files[0].path) as NSURL)
            .setResourceValue(["Read", "Finder addition"], forKey: .tagNamesKey)
        let relaunched = NavigationModel(defaults: defaults)
        XCTAssertEqual(relaunched.undoDepth, 1)
        relaunched.undoLast()
        XCTAssertEqual(Set(try tags(fixture.files[0])), ["Unread", "Finder addition"])
        XCTAssertEqual(try tags(fixture.files[1]), ["Unread"])
        XCTAssertEqual(try fixture.files.map { try Data(contentsOf: $0) }, bytes)
    }

    func testRelaunchedUndoRefusesReplacementAndConsumesAllFailures() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let defaults = fixtureDefaults(pinnedTo: fixture.root)
        let first = NavigationModel(defaults: defaults)
        try select(fixture.files, in: first)
        first.mark(.read)
        // Keep original inode alive so the filesystem cannot recycle it for the replacement.
        try FileManager.default.moveItem(at: fixture.files[0], to: fixture.root.appendingPathComponent("original.pdf"))
        try Data("replacement".utf8).write(to: fixture.files[0])
        try (fixture.files[0] as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)
        let relaunched = NavigationModel(defaults: defaults)
        relaunched.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"])
        XCTAssertTrue(relaunched.statusMessage.contains("1 could not be undone"))
        XCTAssertEqual(NavigationModel(defaults: defaults).undoDepth, 0)
    }

    func testNoOpUndoIsDurablyConsumed() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let defaults = fixtureDefaults(pinnedTo: fixture.root)
        let first = NavigationModel(defaults: defaults)
        let row = try XCTUnwrap(first.library.files.first)
        first.applyEdit(.addSubject("Temporary"), to: row)
        try (URL(fileURLWithPath: fixture.files[0].path) as NSURL)
            .setResourceValue(["Unread"], forKey: .tagNamesKey)
        NavigationModel(defaults: defaults).undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Unread"])
        XCTAssertEqual(NavigationModel(defaults: defaults).undoDepth, 0)
    }

    func testUndoRefusesToWriteWhenConsumptionCannotBeRecorded() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let first = fixtureNavigationModel(pinnedTo: fixture.root)
        try select(fixture.files, in: first)
        first.mark(.read)
        let ledger = AuditLedger.shared.fileURL
        let history = try Data(contentsOf: ledger)
        // A readable, non-writable ledger permits history reconstruction but refuses consumption.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: ledger.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path) }
        first.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"])
        XCTAssertEqual(try Data(contentsOf: ledger), history)
        XCTAssertTrue(first.statusMessage.contains("Could not record undo safely"))
    }

    /// Two undoable steps: Undo reverses the later one and leaves the earlier one undoable
    /// (W40.fix-mut-reader-undo-tests, mutant R08).
    func testUndoReversesTheLatestOfTwoSteps() throws {
        let fixture = try makeRoot(files: ["a.pdf", "b.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        try select([fixture.files[0]], in: model)
        model.mark(.read)
        try select([fixture.files[1]], in: model)
        model.mark(.read)
        XCTAssertEqual(model.undoDepth, 2, "precondition: two separate undo steps")

        model.undoLast()
        XCTAssertEqual(try tags(fixture.files[1]), ["Unread"], "the later step is undone")
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"], "the earlier step is left alone")
        XCTAssertEqual(model.undoDepth, 1)

        model.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Unread"])
    }

    /// A marked file moved out of the archive since: its bookmark still finds it, but undo refuses to
    /// write outside the current archive (mutant R09).
    func testUndoRefusesAFileMovedOutsideTheArchive() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        try select(fixture.files, in: model)
        model.mark(.read)
        XCTAssertEqual(model.undoDepth, 1, "precondition: the mark is undoable")

        let outsideDir = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("UndoOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outsideDir) }
        let moved = outsideDir.appendingPathComponent("a.pdf")
        try FileManager.default.moveItem(at: fixture.files[0], to: moved)

        model.undoLast()
        XCTAssertEqual(try tags(moved), ["Read"], "a file outside the archive must not be re-tagged")
        XCTAssertTrue(model.statusMessage.contains("1 could not be undone"), "the refusal is surfaced")
    }

}
