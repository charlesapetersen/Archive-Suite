import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W49.reader-batch-writes-async: a bulk Mark, edit, rename, undo or redo runs off the main actor in lanes, with a
/// count and Cancel, and leaves the same files, ledger and undo step as the inline loop did. Scratch files only.
@MainActor
final class TagBatchTests: XCTestCase {
    private var root: URL!
    private var savedLedger: URL!
    private var ledger: AuditLedger { .shared }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TagBatch-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Box"), withIntermediateDirectories: true)
        savedLedger = ledger.fileURL
        ledger.fileURL = root.appendingPathComponent("history.jsonl")
    }

    override func tearDown() async throws {
        ledger.fileURL = savedLedger
        try? FileManager.default.removeItem(at: root)
    }

    private func files(_ n: Int, tags: [String] = ["Unread", "Lincoln"]) throws -> [URL] {
        try (0..<n).map { i in
            let url = root.appendingPathComponent("Box").appendingPathComponent(String(format: "doc-%03d.pdf", i))
            try Data("scratch \(i)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            return url
        }
    }

    private func tags(_ url: URL) -> Set<String> {
        Set(TagReading.read(URL(fileURLWithPath: url.path)).tagNames ?? [])
    }

    /// A model whose batches of more than 4 files run off the main actor, with every row selected.
    private func model() -> NavigationModel {
        let m = fixtureNavigationModel(pinnedTo: root)
        m.tagBatchInlineLimit = 4
        m.selection = Set(m.displayed.map(\.id))
        return m
    }

    /// The ledger's operations as written, markers included.
    private func ledgerOps() throws -> [String] {
        try String(contentsOf: ledger.fileURL, encoding: .utf8).split(separator: "\n").compactMap { line in
            (try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["op"] as? String
        }
    }

    func testLanesKeepEachFilesMembersTogetherAndInOrder() {
        // 0 and 2 share a path, 2 and 4 an inode (a hard link): one lane, in order. 1 and 3 stand alone.
        let keys: [[String]] = [["p:/a", "i:1:10"], ["p:/b"], ["p:/a", "i:1:11"], ["p:/c", "i:1:12"], ["p:/d", "i:1:11"]]
        XCTAssertEqual(TagBatch.lanes(keys), [[0, 2, 4], [1], [3]])
        XCTAssertEqual(TagBatch.lanes([]), [])
    }

    func testALargeMarkRunsOffTheMainActorAsOneUndoStep() async throws {
        let urls = try files(30)
        let m = model()
        XCTAssertEqual(m.selectedFiles.count, 30)
        m.mark(.read)
        XCTAssertEqual(m.tagBatch?.total, 30, "the batch is running, not finished, when mark returns")
        XCTAssertEqual(m.undoDepth, 0, "no undo is offered while it runs")
        m.mark(.unread)
        XCTAssertEqual(m.statusMessage, "Wait for the tag change in progress to finish, or cancel it.")
        await m.tagBatchFinished()

        XCTAssertNil(m.tagBatch)
        for url in urls { XCTAssertEqual(tags(url), ["Read", "Lincoln"], url.lastPathComponent) }
        XCTAssertEqual(m.statusMessage, "Marked 30 Read.")
        XCTAssertTrue(m.selectedFiles.allSatisfy { $0.readState == .read }, "the rows show the writes")
        XCTAssertEqual(m.undoDepth, 1)
        // One action: its intent before every record, closed once after the last.
        let ops = try ledgerOps()
        XCTAssertEqual(ops.first, "actionIntent")
        XCTAssertEqual(ops.last, "actionDone")
        XCTAssertEqual(ops.filter { $0 == "readState" }.count, 30)
        XCTAssertEqual(ops.filter { $0 == "actionIntent" }.count, 1, "every file was declared in the one intent")

        m.undoLast()
        XCTAssertEqual(m.tagBatch?.title, "Undoing")
        await m.tagBatchFinished()
        for url in urls { XCTAssertEqual(tags(url), ["Unread", "Lincoln"], url.lastPathComponent) }
        XCTAssertTrue(m.statusMessage.hasPrefix("Undid 30 changes"), m.statusMessage)
        XCTAssertEqual(m.redoDepth, 1)

        m.redoLast()
        await m.tagBatchFinished()
        for url in urls { XCTAssertEqual(tags(url), ["Read", "Lincoln"], url.lastPathComponent) }
        XCTAssertEqual(m.undoDepth, 1, "the redone batch is one undo step again")
    }

    func testCancelStopsBeforeTheNextFileAndKeepsWhatWasWrittenAsOneStep() async throws {
        let urls = try files(40)
        let m = model()
        m.tagBatchStopAfter = 10
        m.applyEdit(.addSubject("Douglass"))
        await m.tagBatchFinished()

        let written = urls.filter { tags($0).contains("Douglass") }
        XCTAssertGreaterThanOrEqual(written.count, 10)
        XCTAssertLessThan(written.count, 40, "lanes stop before their next file")
        XCTAssertEqual(m.statusMessage,
                       "Edited \(written.count) files. Cancelled; \(40 - written.count) files left unchanged.")
        XCTAssertEqual(Set(m.nextUndoFileNames()), Set(written.map(\.lastPathComponent)))

        m.tagBatchStopAfter = nil
        m.undoLast()
        await m.tagBatchFinished()
        for url in urls { XCTAssertEqual(tags(url), ["Unread", "Lincoln"], url.lastPathComponent) }
        XCTAssertEqual(m.undoDepth, 0)
    }

    func testACancelledUndoKeepsTheRestAsAnUndoStepWithoutSpendingAnAttempt() async throws {
        let urls = try files(30)
        let m = model()
        m.tagBatchInlineLimit = 100
        m.mark(.read)                                   // inline
        XCTAssertNil(m.tagBatch)
        m.tagBatchInlineLimit = 4
        m.tagBatchStopAfter = 8
        m.undoLast()
        await m.tagBatchFinished()

        let undone = urls.filter { tags($0).contains("Unread") }
        XCTAssertGreaterThanOrEqual(undone.count, 8)
        XCTAssertLessThan(undone.count, 30)
        XCTAssertTrue(m.statusMessage.hasSuffix("were not undone. Undo again to finish."), m.statusMessage)
        XCTAssertEqual(m.undoDepth, 1, "the rest is the next undo step")
        XCTAssertEqual(m.nextUndoFileNames().count, 30 - undone.count)
        let kept = ledger.entries().filter { $0.retryOf != nil }
        XCTAssertEqual(kept.count, 30 - undone.count)
        XCTAssertTrue(kept.allSatisfy { $0.attempt == 1 }, "nothing was tried on them")

        m.tagBatchStopAfter = nil
        m.undoLast()
        await m.tagBatchFinished()
        for url in urls { XCTAssertEqual(tags(url), ["Unread", "Lincoln"], url.lastPathComponent) }
        XCTAssertEqual(m.statusMessage.contains("Cancelled"), false, m.statusMessage)
    }

    func testALargeRenameRunsOffTheMainActor() async throws {
        let urls = try files(12)
        let m = model()
        m.renameTag(from: "Lincoln", to: "Douglass")
        XCTAssertNotNil(m.tagBatch)
        await m.tagBatchFinished()
        for url in urls { XCTAssertEqual(tags(url), ["Unread", "Douglass"], url.lastPathComponent) }
        XCTAssertEqual(m.statusMessage, "Renamed “Lincoln” → “Douglass” on 12 files.")
        XCTAssertEqual(m.undoDepth, 1)
    }

    func testAQuitStopsTheBatchAndReportsItBeforeTheProcessEnds() async throws {
        let urls = try files(200)
        let m = model()
        m.mark(.read)
        XCTAssertNotNil(m.tagBatchQuitFlush)
        // The lanes run without the main actor: they make progress while it sleeps, and while a quit blocks it.
        for _ in 0..<500 where (m.tagBatchControl?.done ?? 0) < 5 { try await Task.sleep(for: .milliseconds(10)) }
        m.tagBatchQuitFlush?()                           // what willTerminate does, on the main thread
        XCTAssertNil(m.tagBatch)
        XCTAssertNil(m.tagBatchQuitFlush)
        let written = urls.filter { tags($0).contains("Read") }
        XCTAssertGreaterThanOrEqual(written.count, 5)
        XCTAssertEqual(m.statusMessage, "Marked \(written.count) Read." + NavigationModel.cancelledNote(200 - written.count))
        XCTAssertEqual(try ledgerOps().last, "actionDone", "the action is closed, not left as a barrier")
        XCTAssertEqual(m.undoDepth, 1)
        await m.tagBatchFinished()                       // the batch's own report then does nothing
        XCTAssertEqual(m.undoDepth, 1)
    }

    func testTriageDoesNotMoveOnWhileABatchRuns() async throws {
        _ = try files(12)
        let m = model()
        m.mark(.read)
        let before = m.selection
        m.markReadAndAdvance()
        XCTAssertEqual(m.selection, before, "a refused mark does not move the selection")
        XCTAssertEqual(m.statusMessage, "Wait for the tag change in progress to finish, or cancel it.")
        await m.tagBatchFinished()
    }

    func testAnImmediateCancelWritesNothingAndLeavesNoUndoStep() async throws {
        let urls = try files(10)
        let m = model()
        m.tagBatchStopAfter = 0                          // cancelled before the lanes can start
        m.mark(.read)
        m.cancelTagBatch()
        XCTAssertEqual(m.tagBatch?.cancelling, true)
        await m.tagBatchFinished()
        for url in urls { XCTAssertEqual(tags(url), ["Unread", "Lincoln"]) }
        XCTAssertEqual(m.statusMessage, "Marked 0 Read. Cancelled; 10 files left unchanged.")
        XCTAssertEqual(m.undoDepth, 0)
    }
}
