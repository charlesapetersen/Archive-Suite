import XCTest
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class LedgerUndoHistoryTests: XCTestCase {
    private var root: URL!
    private var savedLedger: URL!
    private var ledger: AuditLedger { .shared }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerUndo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedLedger = ledger.fileURL
        ledger.fileURL = root.appendingPathComponent("history.jsonl")
    }

    override func tearDown() async throws {
        ledger.fileURL = savedLedger
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String = "a.pdf", tags: [String] = ["Unread"]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("scratch data".utf8).write(to: url)
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return url
    }

    func testBoundCountsConsumedGroupsSoOlderHistoryCannotResurface() throws {
        let url = try file()
        for i in 0..<105 { _ = try TagWriter.apply(TagDelta(add: ["T\(i)"]), to: url) }
        let history = ledger.undoGroups(in: root)
        XCTAssertEqual(history.count, 100)
        XCTAssertEqual(history.first?.first?.delta.add, ["T5"])
        for group in history { XCTAssertTrue(ledger.beginUndo(try XCTUnwrap(group.first?.group))) }
        XCTAssertTrue(ledger.undoGroups(in: root).isEmpty, "T0–T4 cannot reappear")
    }

    func testMalformedUnsupportedUnverifiedAndUndoLinesAreNotSources() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        var entry = try XCTUnwrap(ledger.entries().first)
        entry.group = UUID(); entry.v = 999; ledger.append(entry)
        entry.group = UUID(); entry.v = 1; entry.unverified = "failed verification"; ledger.append(entry)
        entry.group = UUID(); entry.unverified = nil; entry.op = .undo; ledger.append(entry)
        let handle = try FileHandle(forWritingTo: ledger.fileURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\nnot JSON\n".utf8)); try handle.close()
        XCTAssertEqual(ledger.undoGroups(in: root).count, 1)
    }

    func testBookmarkFallbackAndDisagreementAndMissingIdentity() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        var entry = try XCTUnwrap(ledger.entries().first)
        entry.bookmark = Data("invalid bookmark".utf8)
        XCTAssertEqual(try AuditLedger.undoTarget(entry).url.path, url.path, "path + inode fallback")
        let other = try file("other.pdf")
        entry.bookmark = try other.bookmarkData()
        XCTAssertThrowsError(try AuditLedger.undoTarget(entry), "disagreeing bookmark must refuse")
        entry.bookmark = nil; entry.file = nil
        XCTAssertThrowsError(try AuditLedger.undoTarget(entry), "missing recorded identity never disables §6")
    }

    func testHistoryFollowsMovedRootAndNeverWritesOutsideCurrentRoot() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        let entry = try XCTUnwrap(ledger.entries().first)
        let moved = root.appendingPathExtension("moved")
        let oldLedger = ledger.fileURL
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        ledger.fileURL = moved.appendingPathComponent(oldLedger.lastPathComponent)
        XCTAssertEqual(ledger.undoGroups(in: moved).count, 1)
        XCTAssertEqual(try AuditLedger.undoTarget(entry).url.deletingLastPathComponent().path, moved.path)
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("OtherArchive-\(UUID())")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let otherModel = fixtureNavigationModel(pinnedTo: emptyRoot)
        XCTAssertEqual(otherModel.undoDepth, 0)
        otherModel.undoLast()
        XCTAssertEqual(Set(try XCTUnwrap(TagReading.read(moved.appendingPathComponent(url.lastPathComponent)).tagNames)), ["Unread", "X"])
    }

    func testRelaunchRestoresOccurrenceCountsAndLabelAndNeverReplays() throws {
        let url = try file(tags: ["Unread", "A", "A"])
        _ = try TagWriter.apply(TagDelta(remove: ["A"], color: .set(.box)), to: url)
        let defaults = fixtureDefaults(pinnedTo: root)
        NavigationModel(defaults: defaults).undoLast()
        let tags = try XCTUnwrap(TagReading.read(URL(fileURLWithPath: url.path)).tagNames)
        XCTAssertEqual(tags.filter { $0 == "A" }.count, 2)
        XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber, 0)
        let second = NavigationModel(defaults: defaults)
        XCTAssertEqual(second.undoDepth, 0)
        second.undoLast()
        XCTAssertEqual(try XCTUnwrap(TagReading.read(URL(fileURLWithPath: url.path)).tagNames).filter { $0 == "A" }.count, 2)
    }

    func testRecordingGapBlocksOlderUndoAndPersistsBarrierOnRecovery() throws {
        let url = try file(tags: ["Unread", "X"])
        let model = fixtureNavigationModel(pinnedTo: root)
        let row = try XCTUnwrap(model.library.files.first)
        model.applyEdit(.removeSubject("X"), to: row)
        let ledgerURL = ledger.fileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: ledgerURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path) }
        model.applyEdit(.addSubject("X"), to: row)
        XCTAssertTrue(ledger.hasRecordingGap)
        XCTAssertTrue(model.statusMessage.contains("undo is unavailable"))
        XCTAssertEqual(model.undoDepth, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
        model.undoLast()
        XCTAssertEqual(try XCTUnwrap(TagReading.read(url).tagNames).filter { $0 == "X" }.count, 1,
                       "must not replay the older removal's occurrence inverse")
        model.applyEdit(.addSubject("After recovery"), to: row)
        XCTAssertFalse(ledger.hasRecordingGap)
        XCTAssertTrue(ledger.entries().contains { $0.op == .historyBarrier })
        XCTAssertEqual(model.undoDepth, 1)
        model.undoLast()
        XCTAssertEqual(Set(try XCTUnwrap(TagReading.read(url).tagNames)), ["Unread", "X"])
        XCTAssertEqual(AuditLedger(fileURL: ledgerURL).undoGroups(in: root).count, 0,
                       "a reopened ledger must not cross the persisted gap")
    }

    func testRecoveryWithinAnActionStillReportsLostHistory() throws {
        let url = try file(tags: ["Unread", "X"])
        _ = try TagWriter.apply(TagDelta(add: ["Recorded"]), to: url)
        let model = fixtureNavigationModel(pinnedTo: root)
        let row = try XCTUnwrap(model.library.files.first)
        let historyURL = ledger.fileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: historyURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path) }
        let group = UUID()
        try AuditLedger.withContext(group: group) {
            _ = try TagWriter.apply(TagDelta(add: ["Not recorded"]), to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
            _ = try TagWriter.apply(TagDelta(add: ["Recovered"]), to: url)
        }
        XCTAssertFalse(ledger.hasRecordingGap, "later member recovered within the action")
        // Inline and batch action announcements share the same audit-failure generation check.
        model.applyEdit(.addSubject("Final"), to: row)
        XCTAssertTrue(model.statusMessage.contains("undo history is incomplete"))
    }

    func testSameFileWritesWithinGroupUndoInReverseOrder() throws {
        let url = try file(tags: ["Unread", "X"])
        AuditLedger.withContext(group: UUID()) {
            _ = try? TagWriter.renameToken(from: "X", to: "Y", on: url)
            _ = try? TagWriter.renameToken(from: "Y", to: "Z", on: url)
        }
        let model = fixtureNavigationModel(pinnedTo: root)
        XCTAssertEqual(model.undoDepth, 1)
        model.undoLast()
        XCTAssertEqual(Set(try XCTUnwrap(TagReading.read(url).tagNames)), ["Unread", "X"])
    }

    /// W40.fix-reader-undo-partial: a retried step with two writes to one file is re-recorded in write
    /// order, so the retry still undoes the newer write first (the reverse order leaves X, Y behind).
    func testARetriedSameFileStepStillUndoesInReverseOrder() throws {
        let url = try file(tags: ["Unread", "X"])
        AuditLedger.withContext(group: UUID()) {
            _ = try? TagWriter.renameToken(from: "X", to: "Y", on: url)
            _ = try? TagWriter.renameToken(from: "Y", to: "Z", on: url)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        let model = fixtureNavigationModel(pinnedTo: root)
        model.undoLast()
        XCTAssertEqual(model.undoDepth, 1, "both writes are kept for a retry")
        XCTAssertEqual(ledger.undoGroups(in: root).last?.count, 2)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        fixtureNavigationModel(pinnedTo: root).undoLast()
        XCTAssertEqual(Set(try XCTUnwrap(TagReading.read(url).tagNames)), ["Unread", "X"])
    }

    func testInterruptedUndoIsNeverOfferedAgain() throws {
        let url = try file(tags: ["Unread", "X", "X"])
        _ = try TagWriter.apply(TagDelta(remove: ["X"]), to: url)
        let group = try XCTUnwrap(ledger.undoGroups(in: root).last?.first?.group)
        XCTAssertTrue(ledger.beginUndo(group))
        // Simulate quitting immediately after reservation, before the first inverse.
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).count, 0)
        fixtureNavigationModel(pinnedTo: root).undoLast()
        XCTAssertEqual(try XCTUnwrap(TagReading.read(url).tagNames), ["Unread"])
    }

    func testThreeThousandFileRenameTiming() throws {
        let files = try (0..<3_000).map { try file("\($0).pdf", tags: ["Unread", "Old"]) }
        let start = Date()
        AuditLedger.withContext(group: UUID()) {
            for url in files { _ = try? TagWriter.renameToken(from: "Old", to: "New", on: url) }
        }
        let writeSeconds = Date().timeIntervalSince(start)
        let loadStart = Date()
        let groups = ledger.undoGroups(in: root)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 3_000)
        XCTAssertTrue(files.allSatisfy { TagReading.read(URL(fileURLWithPath: $0.path)).tagNames?.contains("New") == true })
        let appendLedger = AuditLedger(fileURL: root.appendingPathComponent("append-timing.jsonl"))
        let sample = try XCTUnwrap(groups.first?.first)
        let appendStart = Date()
        for _ in files { XCTAssertTrue(appendLedger.append(sample)) }
        let appendSeconds = Date().timeIntervalSince(appendStart)
        print("LEDGER_APPEND_TIMING 3000 appends=\(appendSeconds)s")
        print("LEDGER_TIMING 3000-file rename=\(writeSeconds)s reconstruction=\(loadSeconds)s bytes=\((try Data(contentsOf: ledger.fileURL)).count)")
    }
}
