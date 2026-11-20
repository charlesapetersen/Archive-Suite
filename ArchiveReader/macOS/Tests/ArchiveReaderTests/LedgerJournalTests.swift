import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-ledger-durability: the write-ahead journal around each forward action, what a crash
/// mid-action leaves offered as undo, and the ledger's numbered segments. Scratch files and a scratch
/// ledger only.
@MainActor
final class LedgerJournalTests: XCTestCase {
    private var root: URL!
    private var savedLedger: URL!
    private var savedLimit: UInt64 = 0
    private var ledger: AuditLedger { .shared }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerJournal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedLedger = ledger.fileURL
        savedLimit = ledger.segmentByteLimit
        ledger.fileURL = root.appendingPathComponent("history.jsonl")
    }

    override func tearDown() async throws {
        ledger.fileURL = savedLedger
        ledger.segmentByteLimit = savedLimit
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String = "a.pdf", tags: [String] = ["Unread"]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("scratch data".utf8).write(to: url)
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return url
    }

    /// What a process death leaves: the file as it was, less its last `count` lines.
    private func dropLastLines(_ count: Int) throws {
        let url = ledger.fileURL
        var lines = try Data(contentsOf: url).split(separator: 0x0A, omittingEmptySubsequences: true)
        lines.removeLast(count)
        try (lines.map { Data($0) + Data([0x0A]) }.reduce(Data(), +)).write(to: url)
    }

    func testAnActionIsJournalledAroundItsRecords() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["One"]), to: a)
        let group = UUID()
        try AuditLedger.withContext(group: group) {
            _ = try TagWriter.apply(TagDelta(add: ["Two"]), to: a)
            _ = try TagWriter.apply(TagDelta(add: ["Two"]), to: b)
        }
        let all = ledger.allEntries()
        // b.pdf was not declared, so its own intent lists it before its write.
        XCTAssertEqual(all.map(\.op), [.actionIntent, .apply, .actionDone,
                                       .actionIntent, .apply, .actionIntent, .apply, .actionDone])
        XCTAssertEqual(Set(all.suffix(5).map(\.group)), [group], "intents, records and done share the group")
        XCTAssertEqual(all[3].files?.map(\.path), [a.path])
        XCTAssertEqual(all[5].files?.map(\.path), [b.path])
        XCTAssertEqual(ledger.entries().map(\.op), [.apply, .apply, .apply], "entries() hides the markers")
        XCTAssertEqual(ledger.undoGroups(in: root).count, 2)
    }

    func testANoOpActionAndAnUndoAreNotJournalled() throws {
        let a = try file("a.pdf", tags: ["Unread", "X"])
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: a)
        XCTAssertTrue(ledger.allEntries().isEmpty, "the transform decided not to write: no intent")
        let model = fixtureNavigationModel(pinnedTo: root)
        let row = try XCTUnwrap(model.library.files.first)
        model.applyEdit(.addSubject("Y"), to: row)
        model.undoLast()
        XCTAssertEqual(ledger.allEntries().map(\.op), [.actionIntent, .apply, .actionDone, .undoAttempt, .undo])
    }

    func testACrashThatLostOnlyTheDoneLineCountsAsComplete() throws {
        let a = try file()
        _ = try TagWriter.apply(TagDelta(add: ["Older"]), to: a)
        _ = try TagWriter.apply(TagDelta(add: ["Crashed"]), to: a)
        try dropLastLines(1)   // died after the record, before `actionDone`
        XCTAssertEqual(ledger.allEntries().last?.op, .apply, "precondition")
        let history = AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root)
        XCTAssertEqual(history.map { $0.map(\.delta.add) }, [[["Older"]], [["Crashed"]]],
                       "every line is present and the file reads as its after-state")
    }

    func testACrashedActionWhoseFileChangedSinceIsWithheldWithOlderChangesToThatFile() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["OlderB"]), to: b)
        _ = try TagWriter.apply(TagDelta(add: ["OlderA"]), to: a)
        _ = try TagWriter.apply(TagDelta(add: ["Crashed"]), to: a)
        try dropLastLines(1)
        try (a as NSURL).setResourceValue(["Unread", "OlderA", "Crashed", "Finder"], forKey: .tagNamesKey)
        let history = AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root)
        XCTAssertEqual(history.map { $0.map(\.delta.add) }, [[["OlderB"]]],
                       "a.pdf no longer proves the action; b.pdf's older history stays")
    }

    func testABulkCrashWithALostRecordWithholdsOnlyItsFiles() throws {
        let a = try file("a.pdf"), b = try file("b.pdf"), c = try file("c.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["OlderA"]), to: a)
        _ = try TagWriter.apply(TagDelta(add: ["OlderC"]), to: c)
        try AuditLedger.withContext(group: UUID(), files: [a, b]) {
            _ = try TagWriter.apply(TagDelta(add: ["Bulk"]), to: a)
            _ = try TagWriter.apply(TagDelta(add: ["Bulk"]), to: b)
        }
        try dropLastLines(2)   // b's tag reached the disk; neither its record nor `actionDone` did
        let history = AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root)
        XCTAssertEqual(history.map { $0.map(\.delta.add) }, [[["OlderC"]]],
                       "the action and a.pdf's older change are withheld; c.pdf is outside its list")
        // A change to a listed file by the same process ran beside the action, which may have written the file
        // after it unrecorded: withheld. One after a relaunch is offered.
        _ = try TagWriter.apply(TagDelta(add: ["SameLaunch"]), to: b)
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).map { $0.map(\.delta.add) },
                       [[["OlderC"]]])
        AuditLedger.simulateRelaunch()
        _ = try TagWriter.apply(TagDelta(add: ["Newer"]), to: b)
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).map { $0.map(\.delta.add) },
                       [[["OlderC"]], [["Newer"]]])
    }

    func testAWithheldOlderGroupTakesItsOtherFilesWithIt() throws {
        let a = try file("a.pdf"), c = try file("c.pdf"), d = try file("d.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["OldestC"]), to: c)
        _ = try TagWriter.apply(TagDelta(add: ["D"]), to: d)
        try AuditLedger.withContext(group: UUID(), files: [a, c]) {
            _ = try TagWriter.apply(TagDelta(add: ["Both"]), to: a)
            _ = try TagWriter.apply(TagDelta(add: ["Both"]), to: c)
        }
        _ = try TagWriter.apply(TagDelta(add: ["Crashed"]), to: a)
        try dropLastLines(2)   // a's tag reached the disk unrecorded
        let history = AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root)
        XCTAssertEqual(history.map { $0.map(\.delta.add) }, [[["D"]]],
                       "Both is withheld through a.pdf, and OldestC beneath it through c.pdf")
    }

    func testADeclaredBulkActionHasOneIntentAndAnUndeclaredFileExtendsIt() throws {
        let a = try file("a.pdf"), b = try file("b.pdf"), c = try file("c.pdf")
        try AuditLedger.withContext(group: UUID(), files: [a, b]) {
            _ = try TagWriter.apply(TagDelta(add: ["X"]), to: a)
            _ = try TagWriter.apply(TagDelta(add: ["X"]), to: b)
            _ = try TagWriter.apply(TagDelta(add: ["X"]), to: c)
            _ = try TagWriter.apply(TagDelta(add: ["Y"]), to: a)
        }
        let all = ledger.allEntries()
        XCTAssertEqual(all.map(\.op), [.actionIntent, .apply, .apply, .actionIntent, .apply, .apply, .actionDone])
        XCTAssertEqual(all[0].files?.map(\.path), [a.path, b.path])
        XCTAssertNil(all[0].extends)
        XCTAssertEqual(all[3].files?.map(\.path), [c.path])
        XCTAssertEqual(all[3].extends, true)
        XCTAssertEqual(all[0].files?.first?.file, AuditLedger.fileNumber(a))
        // The extending intent is part of the proof: lose only `actionDone` and the action stands.
        try dropLastLines(1)
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).count, 1)
    }

    func testARunningActionIsNotOfferedButOlderOnesOnOtherFilesAre() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["OlderB"]), to: b)
        _ = try TagWriter.apply(TagDelta(add: ["OlderA"]), to: a)
        var during: [[[String]]] = []
        try AuditLedger.withContext(group: UUID()) {
            _ = try TagWriter.apply(TagDelta(add: ["Running"]), to: a)
            during = ledger.undoGroups(in: root).map { $0.map(\.delta.add) }
        }
        XCTAssertEqual(during, [[["OlderB"]]])
        XCTAssertEqual(ledger.undoGroups(in: root).count, 3, "once closed, all three")
    }

    func testAnotherChangeBetweenTheActionsWritesToAFileMeansNoProof() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["OlderB"]), to: b)
        try AuditLedger.withContext(group: UUID(), files: [a]) {
            _ = try TagWriter.apply(TagDelta(add: ["First"]), to: a)
            try AuditLedger.withContext(group: UUID()) { _ = try TagWriter.apply(TagDelta(add: ["Beside"]), to: a) }
            _ = try TagWriter.apply(TagDelta(remove: ["Beside"]), to: a)   // back to the first record's after-state
        }
        try dropLastLines(2)   // the second write's record and `actionDone`
        AuditLedger.simulateRelaunch()
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).map { $0.map(\.delta.add) },
                       [[["OlderB"]]], "a.pdf reads as the first record's after-state, but that proves nothing")
    }

    func testANewerRetryGroupOnACrashedActionsFileIsWithheld() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["OlderB"]), to: b)
        _ = try TagWriter.apply(TagDelta(add: ["Retried"]), to: a)
        let retried = try XCTUnwrap(ledger.entries().last)
        try AuditLedger.withContext(group: UUID(), files: [a]) {
            _ = try TagWriter.apply(TagDelta(add: ["Crashed"]), to: a)
        }
        try dropLastLines(2)   // a's tag reached the disk unrecorded
        // A retry group has no intent, so no process is named: it may have run beside the crashed action.
        XCTAssertTrue(ledger.keepForRetry([retried], of: retried.group))
        AuditLedger.simulateRelaunch()
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).map { $0.map(\.delta.add) },
                       [[["OlderB"]]])
    }

    func testARunningActionReadAcrossABarrierIsNotOffered() throws {
        let a = try file()
        var during: [[Entry]] = []
        try AuditLedger.withContext(group: UUID()) {
            _ = try TagWriter.apply(TagDelta(add: ["One"]), to: a)
            ledger.append(AuditLedger.marker(.historyBarrier, group: UUID()))   // a recovered recording failure
            _ = try TagWriter.apply(TagDelta(add: ["Two"]), to: a)
            during = ledger.undoGroups(in: root)
        }
        XCTAssertTrue(during.isEmpty, "its intent lies beyond the barrier, but it is still running")
    }

    private typealias Entry = AuditLedger.Entry

    func testAnIntentWithoutFilesIsStillAFullBarrier() throws {
        let b = try file("b.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["Older"]), to: b)
        ledger.append(AuditLedger.marker(.actionIntent, group: UUID()), synchronize: true)
        XCTAssertTrue(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).isEmpty)
    }

    func testACrashBetweenTheIntentAndTheRecordIsABarrier() throws {
        let a = try file()
        _ = try TagWriter.apply(TagDelta(add: ["Older"]), to: a)
        _ = try TagWriter.apply(TagDelta(add: ["Unrecorded"]), to: a)
        try dropLastLines(2)   // the tag reached the disk; neither its record nor `actionDone` did
        XCTAssertEqual(ledger.allEntries().last?.op, .actionIntent, "precondition")
        XCTAssertTrue(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).isEmpty,
                      "Older's inverse must not be offered across a change with no record")
    }

    func testAFailedRecordLeavesTheActionOpen() throws {
        let group = UUID()
        AuditLedger.withContext(group: group) {
            ledger.writeAhead(root.appendingPathComponent("a.pdf"))
            AuditLedger.context?.journal?.markIncomplete()   // what a failed record append does
            ledger.writeAhead(root.appendingPathComponent("b.pdf"))
        }
        XCTAssertEqual(ledger.allEntries().map(\.op), [.actionIntent, .actionIntent],
                       "an incomplete action is never closed, and a later file is still listed before its write")
    }

    func testANestedContextForTheSameActionKeepsOneJournal() throws {
        let a = try file()
        let group = UUID()
        try AuditLedger.withContext(group: group) {
            try AuditLedger.withContext(group: group) { _ = try TagWriter.apply(TagDelta(add: ["In"]), to: a) }
            _ = try TagWriter.apply(TagDelta(add: ["Out"]), to: a)
        }
        XCTAssertEqual(ledger.allEntries().map(\.op), [.actionIntent, .apply, .apply, .actionDone])
    }

    func testAnUnverifiedWriteLeavesItsActionOpen() throws {
        let a = try file()
        _ = try TagWriter.apply(TagDelta(add: ["Older"]), to: a)
        AuditLedger.withContext(group: UUID()) {
            ledger.writeAhead(a)
            ledger.recordUnverified(.apply, a, "simulated verification failure")
        }
        XCTAssertNotEqual(ledger.allEntries().last?.op, .actionDone)
        XCTAssertTrue(AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root).isEmpty,
                      "an uncertain change blocks older inverses")
    }

    func testAnUnreadableLiveFileOffersNothingFromOlderSegments() throws {
        ledger.segmentByteLimit = 3_000
        let a = try file()
        for i in 0..<6 { _ = try TagWriter.apply(TagDelta(add: ["T\(i)"]), to: a) }
        XCTAssertFalse(AuditLedger.segments(of: ledger.fileURL).isEmpty, "precondition")
        let live = ledger.fileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: live.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: live.path) }
        XCTAssertTrue(AuditLedger(fileURL: live).undoGroups(in: root).isEmpty)
    }

    func testSegmentsAreKeptUnchangedAndUndoReadsAcrossThem() throws {
        ledger.segmentByteLimit = 3_000
        let a = try file("a.pdf"), b = try file("b.pdf")
        for i in 0..<12 { _ = try TagWriter.apply(TagDelta(add: ["T\(i)"]), to: a) }
        let firstSegments = AuditLedger.segments(of: ledger.fileURL)
        XCTAssertGreaterThan(firstSegments.count, 1, "precondition: the live file was cut")
        XCTAssertEqual(firstSegments.map(\.number), Array(1...firstSegments.count))
        let firstBytes = try Data(contentsOf: firstSegments[0].url)

        let group = UUID()
        try AuditLedger.withContext(group: group) {
            for i in 0..<6 { _ = try TagWriter.apply(TagDelta(add: ["Bulk\(i)"]), to: i.isMultiple(of: 2) ? a : b) }
        }
        XCTAssertEqual(try Data(contentsOf: firstSegments[0].url), firstBytes, "a closed segment is never rewritten")
        XCTAssertEqual(ledger.entries().count, 18, "every record survives the cuts")

        let history = AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root)
        XCTAssertEqual(history.count, 13)
        XCTAssertEqual(history.first?.first?.delta.add, ["T0"])
        XCTAssertEqual(history.last?.count, 6, "a group cut across segments is still one undo step")
        XCTAssertEqual(history.last?.first?.delta.add, ["Bulk5"], "members in reverse write order")
    }

    func testTheHundredGroupWindowSpansSegments() throws {
        ledger.segmentByteLimit = 4_000
        let a = try file()
        for i in 0..<105 { _ = try TagWriter.apply(TagDelta(add: ["T\(i)"]), to: a) }
        XCTAssertGreaterThan(AuditLedger.segments(of: ledger.fileURL).count, 10, "precondition")
        let history = ledger.undoGroups(in: root)
        XCTAssertEqual(history.count, 100)
        XCTAssertEqual(history.first?.first?.delta.add, ["T5"])
    }

    func testSegmentNamesIgnoreOtherFiles() throws {
        let live = ledger.fileURL
        for name in ["history.000002.jsonl", "history.000001.jsonl", "history.x.jsonl", "history.jsonl.bak",
                     "other.000003.jsonl", "history..jsonl"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(AuditLedger.segments(of: live).map(\.number), [1, 2])
        XCTAssertEqual(AuditLedger.segmentURL(of: live, number: 3).lastPathComponent, "history.000003.jsonl")
    }
}
