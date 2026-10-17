import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.f1 — what the Reader's undo actually is, against what `CLAUDE.md` Safety Protocol §11–§12 promise.
///
/// §12 promises an append-only audit ledger that is the source for undo. The ledger now records every write
/// (`W40.audit-ledger`, `AuditLedgerTests`), but undo does not read it yet (`W40.audit-ledger-undo`, row
/// `R-46`): undo is `NavigationModel`'s private in-memory `undoStack`. These tests pin what that means on
/// scratch `mktemp` fixtures, through the same `mark` → `undoLast` path ⌘Z takes:
///
/// 1. The undo history does not outlive the model. A relaunch (here, a second model on the same root and
///    defaults domain) starts with nothing to undo and no record of the change.
/// 2. `undoLast` drops a file whose inverse write throws (`try?`) and reports only the files it undid, so
///    a partly failed undo reads as a complete one. §11 requires partial failures to be surfaced. That
///    assertion is held by `XCTExpectFailure` until `W40.fix-reader-undo-partial` lands; when it does, the
///    expected failure turns into an unexpected pass and this test fails until the wrapper is removed.
/// 3. Found on the way: §6's identity re-check does not see a file swapped under its path, so undo re-tags
///    it (`W40.fix-identity-url-cache`, S1; the last two tests). Evidence:
///    `verification/evidence/reader/W40.f1-undo.md`.
@MainActor
final class UndoDurabilityTests: XCTestCase {

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

    func testTheUndoHistoryDoesNotSurviveARelaunch() throws {
        let fixture = try makeRoot(files: ["a.pdf"])
        let defaults = fixtureDefaults(pinnedTo: fixture.root)

        let first = NavigationModel(defaults: defaults)
        try select(fixture.files, in: first)
        first.mark(.read)
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"], "precondition: the mark was written to disk")
        XCTAssertEqual(first.undoDepth, 1, "the session that made the change can undo it")

        // Same root, same defaults domain: everything a relaunch would read back.
        let relaunched = NavigationModel(defaults: defaults)
        XCTAssertEqual(relaunched.undoDepth, 0,
                       "undo is memory-only: after a relaunch the change can no longer be undone")
        relaunched.undoLast()
        XCTAssertEqual(try tags(fixture.files[0]), ["Read"], "…and ⌘Z there changes nothing on disk")
        XCTAssertEqual(relaunched.statusMessage, "", "…nor says anything: there is no record to consult")
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
        XCTAssertEqual(model.statusMessage, "Undid 1 change.",
                       "today: the count of what was undone, with no word about the file that was not")

        XCTExpectFailure("W40.fix-reader-undo-partial (S3): undoLast drops a failed file silently (try?) "
                         + "and reports only the count it undid; Safety §11 requires the failure be surfaced")
        XCTAssertTrue(model.statusMessage.contains("could not"),
                      "a partly failed undo must say how many files it could not undo, as `mark` does")
    }

    /// Found while writing the test above (it first swapped the file rather than deleting it, expecting
    /// §6 to refuse). `undoLast` re-verifies against the identity captured at the original edit, but
    /// `FileIdentity.capture` reads `fileResourceIdentifier` through the `URL` it is handed, and a reused
    /// `URL` instance answers from its resource-value cache. The edit and the undo both pass the
    /// `ArchiveFile`'s own `url`, so the check compares the cache with itself and a different file at
    /// that path is re-tagged.
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

        XCTExpectFailure("W40.fix-identity-url-cache (S1): FileIdentity.capture answers from a reused URL's "
                         + "resource-value cache, so §6 does not see the swap and undo re-tags a different file")
        XCTAssertEqual(try tags(swapped), ["Read"], "§6: a file swapped under the path must not be re-tagged")
        XCTAssertEqual(model.statusMessage, "Undid 0 changes.", "…so nothing was undone")
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
        XCTExpectFailure("W40.fix-identity-url-cache (S1): a reused URL returns its cached fileResourceIdentifier")
        XCTAssertFalse(reused.matches(before), "the same URL instance must see the replacement too")
    }
}
