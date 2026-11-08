import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-redo: Redo Tag Change reverses the newest undo through the same ledger and the same
/// fresh-read occurrence step as undo, on scratch files only.
@MainActor
final class RedoTagChangeTests: XCTestCase {
    private var root: URL!
    private var savedLedger: URL!
    private var ledger: AuditLedger { .shared }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Redo-\(UUID())")
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

    private func tags(_ url: URL) throws -> [String] {
        try XCTUnwrap(TagReading.read(URL(fileURLWithPath: url.path)).tagNames)
    }

    private func label(_ url: URL) throws -> Int? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }

    private func model() -> NavigationModel { fixtureNavigationModel(pinnedTo: root) }

    func testRedoReappliesTheUndoneChangeAndSurvivesARelaunch() throws {
        let url = try file(tags: ["Unread", "A", "A"])
        _ = try TagWriter.apply(TagDelta(add: ["B"], remove: ["A"], color: .set(.box)), to: url)
        let changed = try tags(url), changedLabel = try label(url)
        let first = model()
        XCTAssertEqual(first.redoDepth, 0, "nothing undone yet")
        first.undoLast()
        XCTAssertEqual(try tags(url).sorted(), ["A", "A", "Unread"])
        XCTAssertEqual(first.redoDepth, 1)
        XCTAssertEqual(first.nextRedoFileNames(), ["a.pdf"])

        let relaunched = model()
        XCTAssertEqual(relaunched.redoDepth, 1, "redo survives a quit, as undo does")
        relaunched.redoLast()
        XCTAssertEqual(try tags(url).sorted(), changed.sorted())
        XCTAssertEqual(try label(url), changedLabel)
        XCTAssertTrue(relaunched.statusMessage.hasPrefix("Redid 1 change"), relaunched.statusMessage)
        XCTAssertEqual(relaunched.redoDepth, 0)
        XCTAssertEqual(relaunched.undoDepth, 1, "the redone change can be undone again")

        let again = model()
        XCTAssertEqual(again.redoDepth, 0, "a redo is never replayed after a relaunch")
        again.redoLast()
        XCTAssertEqual(try tags(url).sorted(), changed.sorted())
        again.undoLast()
        XCTAssertEqual(try tags(url).sorted(), ["A", "A", "Unread"])
        XCTAssertEqual(try label(url) ?? 0, 0)
        again.redoLast()
        XCTAssertEqual(try tags(url).sorted(), changed.sorted(), "undo and redo alternate as often as asked")
    }

    func testRedoesTheNewestUndoFirstAndAWholeGroupAtOnce() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        AuditLedger.withContext(group: UUID()) {
            _ = try? TagWriter.apply(TagDelta(add: ["First"]), to: a)
            _ = try? TagWriter.apply(TagDelta(add: ["First"]), to: b)
        }
        _ = try TagWriter.apply(TagDelta(add: ["Second"]), to: a)
        let m = model()
        m.undoLast(); m.undoLast()
        XCTAssertEqual(try tags(a), ["Unread"])
        XCTAssertEqual(m.redoDepth, 2)
        XCTAssertEqual(Set(m.nextRedoFileNames()), ["a.pdf", "b.pdf"], "the group's undo was the newest")
        m.redoLast()
        XCTAssertEqual(Set(try tags(a)), ["Unread", "First"])
        XCTAssertEqual(Set(try tags(b)), ["Unread", "First"])
        XCTAssertEqual(m.statusMessage, "Redid 2 changes in 2 files: Subjects: added “First” (2 files).")
        m.redoLast()
        XCTAssertEqual(Set(try tags(a)), ["Unread", "First", "Second"])
        XCTAssertEqual(m.redoDepth, 0)
        XCTAssertEqual(m.undoDepth, 2)
    }

    func testANewChangeEndsTheRedoHistory() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        let m = model()
        m.undoLast()
        XCTAssertEqual(m.redoDepth, 1)
        let other = try file("other.pdf")
        _ = try TagWriter.apply(TagDelta(add: ["New"]), to: other)
        let after = model()
        XCTAssertEqual(after.redoDepth, 0, "a new undoable change clears the redo stack")
        after.redoLast()
        XCTAssertEqual(try tags(url), ["Unread"])
    }

    func testARedoNeverStacksOnAChangeMadeSinceTheUndo() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        let m = model()
        m.undoLast()
        // Put back by hand (Finder, another app): not on the ledger, so the redo is still offered.
        try (url as NSURL).setResourceValue(["Unread", "X", "Other"], forKey: .tagNamesKey)
        XCTAssertEqual(m.redoDepth, 1)
        m.redoLast()
        XCTAssertEqual(try tags(url).sorted(), ["Other", "Unread", "X"], "no second X; the other edit survives")
        XCTAssertEqual(m.statusMessage, "Redid 0 changes.")
    }

    func testRedoRefusesAReplacedFile() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        let m = model()
        m.undoLast()
        try FileManager.default.removeItem(at: url)
        let replacement = try file()
        m.redoLast()
        XCTAssertEqual(try tags(replacement), ["Unread"], "§6: the redo never tags a different file")
        XCTAssertTrue(m.statusMessage.contains("could not be redone"), m.statusMessage)
        XCTAssertEqual(m.redoDepth, 0, "an identity refusal is not offered again")
    }

    func testAnInterruptedRedoIsNeverOfferedAgain() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        model().undoLast()
        let group = try XCTUnwrap(ledger.redoGroups(in: root).last?.first?.group)
        XCTAssertTrue(ledger.beginRedo(group))
        XCTAssertEqual(AuditLedger(fileURL: ledger.fileURL).redoGroups(in: root).count, 0)
        XCTAssertTrue(ledger.undoGroups(in: root).isEmpty, "the marker is not an undo source either")
        model().redoLast()
        XCTAssertEqual(try tags(url), ["Unread"])
    }

    func testAPartlyFailedRedoKeepsTheFailedFileForARetry() throws {
        let a = try file("a.pdf"), b = try file("b.pdf")
        AuditLedger.withContext(group: UUID()) {
            _ = try? TagWriter.apply(TagDelta(add: ["X"]), to: a)
            _ = try? TagWriter.apply(TagDelta(add: ["X"]), to: b)
        }
        let m = model()
        m.undoLast()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: b.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: b.path) }
        m.redoLast()
        XCTAssertEqual(Set(try tags(a)), ["Unread", "X"])
        XCTAssertEqual(try tags(b), ["Unread"])
        XCTAssertTrue(m.statusMessage.contains("Redo again to retry"), m.statusMessage)
        XCTAssertEqual(m.redoDepth, 1)
        XCTAssertEqual(m.nextRedoFileNames(), ["b.pdf"], "only the file that failed")
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: b.path)
        model().redoLast()
        XCTAssertEqual(Set(try tags(b)), ["Unread", "X"])
        XCTAssertEqual(model().redoDepth, 0)
    }

    func testAnUnclosedRedoIsABarrier() throws {
        let url = try file()
        _ = try TagWriter.apply(TagDelta(add: ["X"]), to: url)
        _ = try TagWriter.apply(TagDelta(add: ["Y"]), to: url)
        let m = model()
        m.undoLast(); m.undoLast()
        // A redo whose process died mid-action: its intent was synchronized, its `actionDone` never written.
        ledger.append(AuditLedger.marker(.actionIntent, group: UUID()), synchronize: true)
        XCTAssertEqual(model().redoDepth, 0)
        XCTAssertEqual(model().undoDepth, 0)
    }
}
