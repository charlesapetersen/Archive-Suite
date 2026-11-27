import XCTest
import Darwin
@testable import ArchiveCore

/// The suite's tag change log on scratch folders (SPEC/tag-format.md invariant 8; Tier-2, W40.tag-rename-suite):
/// only `.archivesuite/tag-changes.json` is written; entries append, trim and withdraw; a newer, unreadable or linked
/// log is refused, never overwritten; and the inbox offers, settles and reports withdrawals as the design says.
final class TagChangeLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagChangeLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        let suite = root.appendingPathComponent(ContainerFile.folderName)
        chmod(suite.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    private func change(_ from: String, _ to: String, app: String = TagChangeLog.reader,
                        at seconds: TimeInterval = 1_800_000_000) -> TagChange {
        TagChange(at: Date(timeIntervalSince1970: seconds), app: app, from: from, to: to)
    }

    private func changes() -> [TagChange] { TagChangeLog.load(root: root).document?.changes ?? [] }

    func testRecordCreatesTheLogAndAppendsInOrder() throws {
        XCTAssertEqual(TagChangeLog.load(root: root), .missing)
        let a = change("Civil rights", "Civil Rights Movement"), b = change("Enviroment", "Environment")
        try TagChangeLog.record([a], root: root)
        try TagChangeLog.record([b], root: root)
        XCTAssertEqual(changes(), [a, b])
        // Nothing else in the folder.
        let top = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(top, [ContainerFile.folderName])
        let suite = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(ContainerFile.folderName).path)
        XCTAssertEqual(suite, [TagChangeLog.fileName])
    }

    func testTheSameEntryIsNotAddedTwice() throws {
        let a = change("A tag", "B tag")
        try TagChangeLog.record([a], root: root)
        try TagChangeLog.record([a], root: root)
        XCTAssertEqual(changes(), [a])
    }

    func testFacetTokensAndEmptyOrSameSpellingsAreNeverRecorded() throws {
        try TagChangeLog.record([change("Q1", "Q2"), change("1984", "Lincoln"), change("Red", "Crimson"),
                                 change("Box", "Carton"), change("", "X tag"), change("Same", "Same"),
                                 change("Lincoln", "Q3")], root: root)
        XCTAssertEqual(TagChangeLog.load(root: root), .missing, "nothing recordable, so no log is made")
        // A subject that only looks like a facet in another case is a subject.
        try TagChangeLog.record([change("red", "Crimson")], root: root)
        XCTAssertEqual(changes().map(\.from), ["red"])
    }

    func testTheLogKeepsTheNewestEntries() throws {
        let many = (0..<(TagChangeLog.maxEntries + 5)).map { change("Tag \($0)", "Topic \($0)") }
        try TagChangeLog.record(Array(many.prefix(TagChangeLog.maxEntries)), root: root)
        try TagChangeLog.record(Array(many.suffix(5)), root: root)
        let kept = changes()
        XCTAssertEqual(kept.count, TagChangeLog.maxEntries)
        XCTAssertEqual(kept.first?.from, "Tag 5")
        XCTAssertEqual(kept.last?.from, "Tag \(TagChangeLog.maxEntries + 4)")
    }

    func testWithdrawAndRedo() throws {
        let a = change("A tag", "B tag"), b = change("C tag", "D tag")
        try TagChangeLog.record([a, b], root: root)
        try TagChangeLog.setWithdrawn([a.id], true, root: root)
        XCTAssertEqual(changes().map(\.withdrawn), [true, false])
        try TagChangeLog.setWithdrawn([a.id], false, root: root)
        XCTAssertEqual(changes().map(\.withdrawn), [false, false])
    }

    func testWithdrawingWithNoLogMakesNone() throws {
        try TagChangeLog.setWithdrawn([UUID()], true, root: root)
        XCTAssertEqual(TagChangeLog.load(root: root), .missing)
    }

    func testANewerLogIsNeitherReadNorOverwritten() throws {
        let suite = root.appendingPathComponent(ContainerFile.folderName)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let bytes = Data(#"{"schemaVersion": 2, "changes": [], "future": true}"#.utf8)
        try bytes.write(to: TagChangeLog.url(in: root))
        XCTAssertEqual(TagChangeLog.load(root: root), .newer)
        XCTAssertThrowsError(try TagChangeLog.record([change("A tag", "B tag")], root: root))
        XCTAssertThrowsError(try TagChangeLog.setWithdrawn([UUID()], true, root: root))
        XCTAssertEqual(try Data(contentsOf: TagChangeLog.url(in: root)), bytes)
    }

    func testAnUnreadableLogIsLeftAlone() throws {
        let suite = root.appendingPathComponent(ContainerFile.folderName)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let bytes = Data("not json".utf8)
        try bytes.write(to: TagChangeLog.url(in: root))
        guard case .unreadable = TagChangeLog.load(root: root) else { return XCTFail("expected unreadable") }
        XCTAssertThrowsError(try TagChangeLog.record([change("A tag", "B tag")], root: root))
        XCTAssertEqual(try Data(contentsOf: TagChangeLog.url(in: root)), bytes)
    }

    func testALinkedLogIsRefusedAndItsTargetUntouched() throws {
        let suite = root.appendingPathComponent(ContainerFile.folderName)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        let bytes = Data(#"{"schemaVersion": 1, "changes": []}"#.utf8)
        try bytes.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: TagChangeLog.url(in: root), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try TagChangeLog.record([change("A tag", "B tag")], root: root))
        XCTAssertEqual(try Data(contentsOf: elsewhere), bytes)
    }

    func testAReadOnlyFolderThrowsAndChangesNothing() throws {
        try TagChangeLog.record([change("A tag", "B tag")], root: root)
        let before = try Data(contentsOf: TagChangeLog.url(in: root))
        let suite = root.appendingPathComponent(ContainerFile.folderName)
        XCTAssertEqual(chmod(suite.path, 0o555), 0)
        XCTAssertThrowsError(try TagChangeLog.record([change("C tag", "D tag")], root: root))
        XCTAssertEqual(try Data(contentsOf: TagChangeLog.url(in: root)), before)
        // Reading still works.
        XCTAssertEqual(changes().count, 1)
    }

    func testConcurrentWritersLoseNoEntry() throws {
        let entries = (0..<24).map { change("Tag \($0)", "Topic \($0)") }
        let root = self.root!
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: entries.count) { i in
            do { try TagChangeLog.record([entries[i]], root: root) } catch { failures.add() }
        }
        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(Set(changes().map(\.id)), Set(entries.map(\.id)))
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: The inbox

    func testInboxOffersOtherAppsChangesThatSomethingCarries() {
        let mine = change("Own tag", "Own topic", app: TagChangeLog.notes)
        let carried = change("Civil rights", "Civil Rights Movement")
        let absent = change("Nobody", "Somebody")
        let doc = TagChangeDocument(changes: [mine, carried, absent])
        let box = TagChangeLog.inbox(doc, app: TagChangeLog.notes, handled: [], applied: [],
                                     carried: [tagKey("CIVIL RIGHTS"), tagKey("Own tag")])
        XCTAssertEqual(box.offers, [carried], "matched by tagKey, own entries skipped")
        XCTAssertEqual(box.settled, [], "a tag nothing carries now may be carried later: passed over, not settled")
        let later = TagChangeLog.inbox(doc, app: TagChangeLog.notes, handled: [], applied: [],
                                       carried: [tagKey("Nobody")])
        XCTAssertEqual(later.offers, [absent])
        XCTAssertTrue(box.withdrawals.isEmpty)
    }

    func testInboxFollowsAChainOfChanges() {
        let ab = change("Alpha tag", "Beta tag"), bc = change("Beta tag", "Gamma tag")
        let box = TagChangeLog.inbox(TagChangeDocument(changes: [ab, bc]), app: TagChangeLog.notes, handled: [],
                                     applied: [], carried: [tagKey("Alpha tag")])
        XCTAssertEqual(box.offers, [ab, bc])
    }

    func testInboxPassesOverWithdrawnAndSkipsHandledAndReportsWithdrawalsOfAppliedOnes() {
        var withdrawnUnseen = change("A tag", "B tag"); withdrawnUnseen.withdrawn = true
        var withdrawnApplied = change("C tag", "D tag"); withdrawnApplied.withdrawn = true
        let handled = change("E tag", "F tag")
        let doc = TagChangeDocument(changes: [withdrawnUnseen, withdrawnApplied, handled])
        let box = TagChangeLog.inbox(doc, app: TagChangeLog.notes,
                                     handled: [withdrawnApplied.id, handled.id], applied: [withdrawnApplied.id],
                                     carried: [tagKey("A tag"), tagKey("D tag"), tagKey("E tag")])
        XCTAssertEqual(box.offers, [])
        XCTAssertEqual(box.settled, [], "withdrawn but never applied: passed over, since a Redo may restore it")
        XCTAssertEqual(box.withdrawals, [withdrawnApplied])
        var redone = withdrawnUnseen; redone.withdrawn = false
        XCTAssertEqual(TagChangeLog.inbox(TagChangeDocument(changes: [redone]), app: TagChangeLog.notes, handled: [],
                                          applied: [], carried: [tagKey("A tag")]).offers, [redone])
    }

    func testInboxSettlesARespellingForAnAppThatIgnoresIt() {
        let respell = change("lincoln", "Lincoln", app: TagChangeLog.processor)
        let doc = TagChangeDocument(changes: [respell])
        XCTAssertEqual(TagChangeLog.inbox(doc, app: TagChangeLog.notes, handled: [], applied: [],
                                          carried: [tagKey("Lincoln")], ignoresRespelling: true).settled, [respell.id])
        XCTAssertEqual(TagChangeLog.inbox(doc, app: TagChangeLog.reader, handled: [], applied: [],
                                          carried: [tagKey("Lincoln")]).offers, [respell])
    }

    // MARK: The handled list

    func testHandledListPersistsPerRootAndIsBounded() {
        let suiteName = "TagChangeLogTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let a = TagChangeHandled(rootGUID: "root-a", suiteName: suiteName)
        let b = TagChangeHandled(rootGUID: "root-b", suiteName: suiteName)
        let ids = (0..<(TagChangeHandled.limit + 3)).map { _ in UUID() }
        a.insert(ids)
        XCTAssertEqual(a.ids.count, TagChangeHandled.limit)
        XCTAssertFalse(a.ids.contains(ids[0]))
        XCTAssertTrue(a.ids.contains(ids.last!))
        XCTAssertTrue(b.ids.isEmpty)
        let applied = TagChangeHandled.applied(rootGUID: "root-a", suiteName: suiteName)
        applied.insert([ids.last!])
        XCTAssertEqual(applied.ids, [ids.last!])
        applied.remove([ids.last!])
        XCTAssertTrue(applied.ids.isEmpty)
        XCTAssertEqual(a.ids.count, TagChangeHandled.limit, "the two lists are separate")
    }
}
