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
        XCTAssertEqual(all.map(\.op), [.actionIntent, .apply, .actionDone,
                                       .actionIntent, .apply, .apply, .actionDone])
        XCTAssertEqual(Set(all.suffix(4).map(\.group)), [group], "intent, records and done share the group")
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

    func testACrashBeforeTheActionClosedIsABarrierAfterRelaunch() throws {
        let a = try file()
        _ = try TagWriter.apply(TagDelta(add: ["Older"]), to: a)
        _ = try TagWriter.apply(TagDelta(add: ["Crashed"]), to: a)
        try dropLastLines(1)   // died after the record, before `actionDone`
        let relaunched = AuditLedger(fileURL: ledger.fileURL)
        XCTAssertTrue(relaunched.undoGroups(in: root).isEmpty,
                      "neither the unclosed action nor the older one is offered")
        // A later complete action is offered alone: the barrier stays where the crash left it.
        _ = try TagWriter.apply(TagDelta(add: ["Newer"]), to: a)
        let history = AuditLedger(fileURL: ledger.fileURL).undoGroups(in: root)
        XCTAssertEqual(history.map { $0.map(\.delta.add) }, [[["Newer"]]])
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
            ledger.writeAhead()
            AuditLedger.context?.journal?.markIncomplete()   // what a failed record append does
        }
        XCTAssertEqual(ledger.allEntries().map(\.op), [.actionIntent], "an incomplete action is never closed")
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
            ledger.writeAhead()
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
