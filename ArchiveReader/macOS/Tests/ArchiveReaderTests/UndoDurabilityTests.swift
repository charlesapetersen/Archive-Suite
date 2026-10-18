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
        XCTAssertEqual(model.undoDepth, 0, "the failed entry is dropped, not kept for a retry")
        XCTAssertTrue(model.statusMessage.contains("1 could not be undone"))
        XCTAssertTrue(model.statusMessage.contains("b.pdf"))
        XCTAssertEqual(fixtureNavigationModel(pinnedTo: fixture.root).undoDepth, 0,
                       "partial attempts consume the whole group, including after relaunch")
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

}
