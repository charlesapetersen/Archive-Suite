import XCTest
import ArchiveCore

/// W26.vocab Tier-2: the **composition** the Processor's harvest actually performs, on real scratch
/// files — `CorpusWalker.scan` walking a tree with `TagVocabulary.add` as the predicate-sink.
///
/// `TagVocabularyTests` covers the store in isolation (relaunch, cross-root accumulation, the `$HOME`
/// guard, facet filtering). None of it walks a filesystem, so none of it would catch the harvest being
/// wired up wrongly: a sink predicate that accumulated rows, a stamp set by a pass that did not finish,
/// or a walk that reads tags through a different primitive than the write path does. Those are the
/// claims here, and they are made against real on-disk Finder tags.
///
/// Deliberately `import ArchiveCore`, not `@testable` — every symbol used here is public API that the
/// Processor calls.
final class TagVocabularyHarvestTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w26-vocab-harvest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func makeRoot(_ name: String) throws -> URL {
        let root = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A real file carrying real Finder tags, written through the same resource-value API the Finder uses.
    @discardableResult
    private func makeTagged(_ name: String, in root: URL, tags: [String], label: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func store() -> TagVocabulary {
        TagVocabulary(fileURL: dir.appendingPathComponent("vocab-\(UUID()).json"))
    }

    /// The exact harvest composition from `SystemTagsProvider.harvest`: a predicate that always returns
    /// `false` (so no rows accumulate) with the ingest in `onTagsRead`, which is the only hook that
    /// carries the file's Finder label.
    @discardableResult
    private func harvest(_ root: URL, into vocabulary: TagVocabulary,
                         isCancelled: @escaping @Sendable () -> Bool = { false }) -> CorpusScanResult {
        CorpusWalker.scan(root: root,
                          predicate: { _ in false },
                          isCancelled: isCancelled,
                          onTagsRead: { rawTags, labelNumber in
                              vocabulary.add(rawTags: rawTags, labelNumber: labelNumber)
                          })
    }

    /// `SystemTagsProvider.mayStamp`, mirrored so the tests exercise the same rule the app applies.
    private func mayStamp(_ result: CorpusScanResult, root: URL) -> Bool {
        guard result.completed, !result.rootUnreadable else { return false }
        let rootPath = root.standardizedFileURL.path
        return !result.directoryErrors.contains { $0.url.standardizedFileURL.path == rootPath }
    }

    // MARK: - The harvest itself

    /// The subject names on disk end up in the vocabulary, and the structural facets do not — measured
    /// through the real walker rather than by handing `add` a literal array.
    ///
    /// The marker colour is the case that only a filesystem test can catch: "Red" is dropped because the
    /// file's Finder label is 6, and the label is only knowable from the walk. An earlier draft of the
    /// harvest ingested through the predicate (tag names only, no label) and this test is what caught it
    /// — "Red" and "Purple" became permanent suggestions, since the app stamps one on every output.
    func testHarvestCollectsSubjectsFromRealFinderTagsOnDisk() throws {
        let root = try makeRoot("archive")
        try makeTagged("a.pdf", in: root, tags: ["Red", "Watergate", "1972", "Unread"], label: 6)
        try makeTagged("b.pdf", in: root, tags: ["Labor Unions", "P9", "Read"])

        let vocabulary = store()
        let result = harvest(root, into: vocabulary)

        XCTAssertTrue(result.completed, "a readable scratch tree must produce a completed pass")
        XCTAssertEqual(Set(vocabulary.snapshot()), ["Watergate", "Labor Unions"],
                       "subjects only: \(vocabulary.snapshot())")
    }

    /// The other half of the marker-colour rule, and the reason it cannot just be a blocklist of the two
    /// colour words: a document about the Red Scare, tagged "Red" with the label explicitly *cleared*,
    /// keeps "Red" as a subject suggestion.
    ///
    /// The label must be written explicitly, and that is a measured property of the platform rather than
    /// a quirk of this test: setting `.tagNamesKey` to `["Red", …]` alone makes macOS derive label 6, so
    /// on a real volume there is no such thing as a file tagged "Red" with no label unless something
    /// writes 0 afterwards. `MacOSTagger`'s colour-authoritative path is exactly that something — it
    /// writes `targetLabel = 0` when the app assigned no colour, which is what `MacOSTaggerParityTests`
    /// `.testRedAsSubject` pins. So this fixture reproduces a state the Processor really does create.
    func testAColourWordWithoutTheMatchingLabelStaysASubject() throws {
        let root = try makeRoot("archive")
        try makeTagged("scare.pdf", in: root, tags: ["Red", "1955", "Unread"], label: 0)
        try makeTagged("box.pdf", in: root, tags: ["Purple", "Rcpt", "Unread"], label: 3)

        let vocabulary = store()
        harvest(root, into: vocabulary)

        XCTAssertEqual(Set(vocabulary.snapshot()), ["Red", "Rcpt"],
                       "unlabelled 'Red' kept, labelled 'Purple' dropped: \(vocabulary.snapshot())")
    }

    /// The platform premise the test above depends on, pinned separately so a change in it fails as
    /// itself rather than as a confusing vocabulary assertion: a bare `.tagNamesKey = ["Red"]` write
    /// yields Finder label 6 with no label write at all.
    func testPremiseAColourTagAloneMakesMacOSDeriveTheLabel() throws {
        let root = try makeRoot("archive")
        let url = try makeTagged("bare.pdf", in: root, tags: ["Red", "Unread"])
        let label = try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
        XCTAssertEqual(label, 6, "a colour tag round-trips as a label on its own")
    }

    /// A file the harvest does not *match* is still ingested. `onTagsRead` fires for every successful
    /// read, matching or not, which is what lets the predicate stay a constant `false`.
    func testEveryReadFileIsIngestedEvenThoughNothingMatchesThePredicate() throws {
        let root = try makeRoot("archive")
        try makeTagged("tracked.pdf", in: root, tags: ["Watergate", "Unread"])
        try makeTagged("untracked.pdf", in: root, tags: ["Loose Subject"])   // no Read/Unread at all

        let vocabulary = store()
        let result = harvest(root, into: vocabulary)

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(Set(vocabulary.snapshot()), ["Watergate", "Loose Subject"],
                       "\(vocabulary.snapshot())")
    }

    /// The predicate is a sink, so the walker must accumulate **no rows**. This is the whole reason the
    /// harvest can run over a 100k-file corpus without holding a library in memory, and it is a one-word
    /// change away from being false — the comment at the call site says "do not fix this to return true".
    func testTheSinkPredicateMakesTheWalkerAccumulateNothing() throws {
        let root = try makeRoot("archive")
        for i in 0..<12 { try makeTagged("f\(i).pdf", in: root, tags: ["Subject \(i)", "Unread"]) }

        let vocabulary = store()
        let result = harvest(root, into: vocabulary)

        XCTAssertEqual(result.filesSeen, 12, "every file was examined")
        XCTAssertTrue(result.entries.isEmpty,
                      "a vocabulary harvest must keep strings, not CorpusEntry rows: \(result.entries.count)")
        XCTAssertEqual(vocabulary.count, 12, "…while still absorbing every subject")
    }

    /// Nested directories are harvested, not just the top level — the archive is `Box/Folder/file.pdf`.
    func testHarvestDescendsIntoSubdirectories() throws {
        let root = try makeRoot("archive")
        let nested = root.appendingPathComponent("Box 4/Folder 12", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makeTagged("deep.pdf", in: nested, tags: ["Deep Subject", "Unread"])

        let vocabulary = store()
        harvest(root, into: vocabulary)

        XCTAssertTrue(vocabulary.snapshot().contains("Deep Subject"), "\(vocabulary.snapshot())")
    }

    // MARK: - Only a completed pass may claim the root

    /// A cancelled walk keeps whatever it absorbed (the set never shrinks) but must NOT be stamped, so
    /// the next warm-up walks the root again. Stamping an interrupted pass is how a root silently never
    /// gets covered.
    func testACancelledHarvestKeepsItsNamesButLeavesTheRootDue() throws {
        let root = try makeRoot("archive")
        for i in 0..<40 { try makeTagged("f\(i).pdf", in: root, tags: ["Subj \(i)", "Unread"]) }

        let vocabulary = store()
        vocabulary.noteRoot(root)

        let cancelAfter = 1
        let seen = Counter()
        let result = CorpusWalker.scan(root: root,
                                       predicate: { _ in false },
                                       isCancelled: { seen.value > cancelAfter },
                                       onTagsRead: { rawTags, labelNumber in
                                           vocabulary.add(rawTags: rawTags, labelNumber: labelNumber)
                                           seen.increment()
                                       })

        XCTAssertTrue(result.cancelled, "the walk must actually have been cancelled")
        XCTAssertFalse(result.completed)
        if mayStamp(result, root: root) { vocabulary.markHarvested(root) }

        XCTAssertGreaterThan(vocabulary.count, 0, "names absorbed before the cancel are kept")
        XCTAssertEqual(vocabulary.rootsNeedingHarvest(current: root).map { $0.path }, [root.path],
                       "an interrupted pass must leave the root due")
    }

    /// The positive control for the case above: a pass that finished stamps the root, and the root then
    /// stops being offered.
    func testACompletedHarvestStampsTheRootAndItStopsBeingDue() throws {
        let root = try makeRoot("archive")
        try makeTagged("a.pdf", in: root, tags: ["Watergate", "Unread"])

        let vocabulary = store()
        vocabulary.noteRoot(root)
        XCTAssertEqual(vocabulary.rootsNeedingHarvest(current: root).count, 1, "due before")

        let result = harvest(root, into: vocabulary)
        if mayStamp(result, root: root) { vocabulary.markHarvested(root) }

        XCTAssertTrue(vocabulary.rootsNeedingHarvest(current: root).isEmpty, "not due after")
    }

    /// A root that vanished is not stamped — and `completed` alone would have stamped it.
    ///
    /// Measured, not assumed: `FileManager.enumerator(at:)` returns a live enumerator for a directory
    /// that does not exist. It reports the root to the error handler and then ends, so the pass comes
    /// back `completed == true`, `rootUnreadable == false`, `filesSeen == 0` — a walk that read nothing
    /// looking exactly like a walk that found nothing. This test pins the distinction, and both
    /// assertions below fail against the plain `result.completed` gate.
    func testAVanishedRootIsNotStampedEvenThoughThePassSaysItCompleted() throws {
        let root = try makeRoot("archive")
        let vocabulary = store()
        vocabulary.noteRoot(root)
        try FileManager.default.removeItem(at: root)

        let result = harvest(root, into: vocabulary)

        XCTAssertTrue(result.completed, "premise: the walker calls this pass complete")
        XCTAssertFalse(result.rootUnreadable, "premise: and does NOT call the root unreadable")
        XCTAssertEqual(result.filesSeen, 0)
        XCTAssertFalse(mayStamp(result, root: root), "…but the harvest must refuse to stamp it")

        if mayStamp(result, root: root) { vocabulary.markHarvested(root) }
        XCTAssertEqual(vocabulary.rootsNeedingHarvest(current: root).count, 1,
                       "a root we never read stays due")
    }

    /// The other side of that rule: a denied *sub*directory still stamps. An unstamped root is re-walked
    /// on every tagging-UI appearance, so one permanently-unreadable subfolder must not turn a corpus
    /// walk into a walk per card.
    func testADeniedSubdirectoryStillStampsTheRoot() throws {
        let root = try makeRoot("archive")
        try makeTagged("top.pdf", in: root, tags: ["Watergate", "Unread"])
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try makeTagged("hidden.pdf", in: locked, tags: ["Hidden Subject", "Unread"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }

        let vocabulary = store()
        vocabulary.noteRoot(root)
        let result = harvest(root, into: vocabulary)

        try XCTSkipUnless(!result.directoryErrors.isEmpty,
                          "this environment could descend the 0o000 directory; case N/A")
        XCTAssertTrue(mayStamp(result, root: root),
                      "a subdirectory error is not a reason to re-walk forever: \(result.directoryErrors)")
        XCTAssertTrue(vocabulary.snapshot().contains("Watergate"), "the readable half still landed")
    }

    // MARK: - Across roots, and across a relaunch

    /// The SUITE_TODO gate, end to end through the walker and the file: harvest two real trees, then
    /// reopen the store as a *new* process would and find the union of both.
    func testTwoHarvestedRootsSurviveARelaunchAsOneVocabulary() throws {
        let fileURL = dir.appendingPathComponent("relaunch.json")
        let rootA = try makeRoot("archive-a")
        let rootB = try makeRoot("archive-b")
        try makeTagged("a.pdf", in: rootA, tags: ["Watergate", "Unread"])
        try makeTagged("b.pdf", in: rootB, tags: ["Iran Contra", "Unread"])

        do {
            let vocabulary = TagVocabulary(fileURL: fileURL)
            for root in [rootA, rootB] {
                vocabulary.noteRoot(root)
                let result = harvest(root, into: vocabulary)
                if mayStamp(result, root: root) { vocabulary.markHarvested(root) }
            }
            vocabulary.flush()
        }

        let reopened = TagVocabulary(fileURL: fileURL)
        XCTAssertEqual(Set(reopened.snapshot()), ["Watergate", "Iran Contra"],
                       "both roots' subjects survive: \(reopened.snapshot())")
        XCTAssertTrue(reopened.rootsNeedingHarvest(current: rootA).isEmpty,
                      "harvest stamps survive too, so a relaunch does not re-walk")
        XCTAssertNil(reopened.loadFailure)
    }

    /// Removing a tag from disk does not remove it from the vocabulary. Deliberate: the store is a
    /// monotonic cache of strings for a suggestion list, so nothing here ever needs an authoritative
    /// pass, and a degraded walk can never shrink the suggestions.
    func testAReHarvestNeverPrunesANameWhoseFileLostTheTag() throws {
        let root = try makeRoot("archive")
        let file = try makeTagged("a.pdf", in: root, tags: ["Watergate", "Unread"])

        let vocabulary = store()
        harvest(root, into: vocabulary)
        XCTAssertTrue(vocabulary.snapshot().contains("Watergate"))

        try (file as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        harvest(root, into: vocabulary)

        XCTAssertTrue(vocabulary.snapshot().contains("Watergate"),
                      "the vocabulary only grows: \(vocabulary.snapshot())")
    }

    /// A file whose tags cannot be read contributes nothing and does **not** poison the pass: the other
    /// files' subjects still land, and the pass is `completed` (so the root is stamped) while not being
    /// `isClean`. The harvest deliberately uses `completed`, not `isClean` — nothing is ever pruned, so
    /// one unreadable file is not a reason to re-walk 100k of them.
    func testAnUnreadableFileIsCountedButDoesNotBlockTheHarvest() throws {
        let root = try makeRoot("archive")
        try makeTagged("good.pdf", in: root, tags: ["Watergate", "Unread"])
        let denied = try makeTagged("denied.pdf", in: root, tags: ["Secret Subject", "Unread"])
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: denied.path) }

        let vocabulary = store()
        let result = harvest(root, into: vocabulary)

        try XCTSkipUnless(result.unreadable.count == 1,
                          "this volume did not deny the xattr read; unreadable-file case N/A")
        XCTAssertTrue(result.completed, "one denied file does not make the pass incomplete")
        XCTAssertFalse(result.isClean)
        XCTAssertTrue(vocabulary.snapshot().contains("Watergate"))
        XCTAssertFalse(vocabulary.snapshot().contains("Secret Subject"),
                       "a file we could not read contributes nothing: \(vocabulary.snapshot())")
    }
}

/// Thread-safe counter — the walker's predicate and `isCancelled` are `@Sendable` and run on the
/// walking thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
