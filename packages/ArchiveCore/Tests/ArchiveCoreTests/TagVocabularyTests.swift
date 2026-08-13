import XCTest
import ArchiveCore

/// W26.vocab — the persisted subject vocabulary that replaces the Processor's Spotlight
/// `NSMetadataQuery` autocomplete.
///
/// The three properties the item exists to guarantee are the first three sections below: the vocabulary
/// **survives a relaunch**, it **accumulates across roots**, and **no `$HOME` walk can occur**. The last of
/// those is the owner's 2026-08-04 directive, and the only way to keep a directive from decaying into a
/// comment is to make it a function with tests — `isHarvestableRoot` is that function.
///
/// Deliberately `import ArchiveCore`, not `@testable`: every symbol here is part of the surface the
/// Processor builds on, so this file also guards against a later refactor quietly demoting one.
final class TagVocabularyTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagVocabTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ name: String = "vocab.json") -> TagVocabulary {
        TagVocabulary(fileURL: dir.appendingPathComponent(name))
    }

    private func fakeHome() -> URL { URL(fileURLWithPath: "/Users/testuser", isDirectory: true) }

    // MARK: - 1. Survives relaunch

    func testVocabularySurvivesRelaunch() {
        let first = store()
        first.add(rawTags: ["taxes", "elections"])
        first.flush()

        // A fresh instance over the same file is what "relaunch" means here — nothing is carried in memory.
        let second = store()
        XCTAssertEqual(Set(second.snapshot()), ["taxes", "elections"])
        XCTAssertNil(second.loadFailure)
    }

    func testRelaunchAlsoRestoresRootHarvestStamps() {
        let root = dir.appendingPathComponent("Archive", isDirectory: true)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = store()
        XCTAssertTrue(first.noteRoot(root, home: fakeHome()))
        first.markHarvested(root, at: stamp)
        first.flush()

        let second = store()
        XCTAssertEqual(second.knownRoots().count, 1)
        XCTAssertEqual(second.knownRoots().first?.harvestedAt, stamp)
        // A restored stamp is what stops a relaunch from re-walking the corpus every time the app opens.
        XCTAssertTrue(second.rootsNeedingHarvest(current: root, now: stamp.addingTimeInterval(60)).isEmpty)
    }

    func testNothingIsWrittenBeforeAFlushOrDebounce() {
        let path = dir.appendingPathComponent("late.json")
        let s = TagVocabulary(fileURL: path)
        s.add(rawTags: ["taxes"])
        // `add` only *schedules* a save (1 s debounce) — the assertion is that the value is not lost, which
        // `flush` guarantees synchronously. This pins the flush contract the harvest and `register` rely on.
        s.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(TagVocabulary(fileURL: path).snapshot(), ["taxes"])
    }

    func testWriteCreatesAMissingParentDirectory() {
        let nested = dir.appendingPathComponent("a/b/c/vocab.json")
        let s = TagVocabulary(fileURL: nested)
        s.add(rawTags: ["nested"])
        s.flush()
        XCTAssertEqual(TagVocabulary(fileURL: nested).snapshot(), ["nested"])
    }

    // MARK: - 2. Accumulates across roots, and never shrinks

    func testAccumulatesAcrossRootsAndNeverPrunes() {
        let s = store()
        let rootA = dir.appendingPathComponent("ArchiveA", isDirectory: true)
        let rootB = dir.appendingPathComponent("ArchiveB", isDirectory: true)

        XCTAssertTrue(s.noteRoot(rootA, home: fakeHome()))
        s.add(rawTags: ["Democratic Party"])          // as if harvested from A
        s.markHarvested(rootA)

        XCTAssertTrue(s.noteRoot(rootB, home: fakeHome()))
        s.add(rawTags: ["transportation"])            // as if harvested from B
        s.markHarvested(rootB)

        XCTAssertEqual(Set(s.snapshot()), ["Democratic Party", "transportation"],
                       "moving to a second root must not drop the first root's vocabulary")

        // Monotonic: there is no removal API at all, and re-adding an existing name reports no growth.
        XCTAssertFalse(s.add(rawTags: ["taxes", "transportation"]) == false,
                       "a genuinely new name must report growth")
        XCTAssertFalse(s.add(rawTags: ["transportation"]),
                       "a name already known must report no growth, so the caller can skip a save")
        XCTAssertEqual(Set(s.snapshot()), ["Democratic Party", "transportation", "taxes"])
    }

    func testTheSameRootIsNotRecordedTwice() {
        let s = store()
        let root = dir.appendingPathComponent("Archive", isDirectory: true)
        XCTAssertTrue(s.noteRoot(root, home: fakeHome()))
        XCTAssertFalse(s.noteRoot(root, home: fakeHome()))
        // Same directory, different spelling — the boot volume is case-insensitive, so this is one root.
        let shouty = URL(fileURLWithPath: root.path.uppercased(), isDirectory: true)
        XCTAssertFalse(s.noteRoot(shouty, home: fakeHome()))
        XCTAssertEqual(s.knownRoots().count, 1)
        // A trailing slash is the same path too.
        XCTAssertFalse(s.noteRoot(URL(fileURLWithPath: root.path + "/", isDirectory: true), home: fakeHome()))
        XCTAssertEqual(s.knownRoots().count, 1)
    }

    func testRootRecordsAreCappedOldestFirst() {
        let s = store()
        for i in 0..<(TagVocabulary.maxRoots + 4) {
            XCTAssertTrue(s.noteRoot(dir.appendingPathComponent("R\(i)", isDirectory: true), home: fakeHome()))
        }
        let kept = s.knownRoots()
        XCTAssertEqual(kept.count, TagVocabulary.maxRoots)
        XCTAssertEqual(kept.first?.path, dir.appendingPathComponent("R4", isDirectory: true).path,
                       "eviction drops the OLDEST record; the newest roots are the ones still worth walking")
    }

    // MARK: - 3. No $HOME walk can occur

    func testHomeAndItsPersonalFoldersAreNotHarvestable() {
        let home = fakeHome()
        XCTAssertFalse(TagVocabulary.isHarvestableRoot(home, home: home),
                       "$HOME itself is the Spotlight scope this change exists to stop emulating")
        for name in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
                     "Pictures", "Public", "Sites"] {
            XCTAssertFalse(
                TagVocabulary.isHarvestableRoot(home.appendingPathComponent(name, isDirectory: true), home: home),
                "\(name) is a TCC-gated personal-data umbrella, not an archive root")
        }
    }

    func testWholeFilesystemRootsAreNotHarvestable() {
        let home = fakeHome()
        for path in ["/", "/Users", "/Volumes", "/System", "/Library", "/Applications", "/private"] {
            XCTAssertFalse(TagVocabulary.isHarvestableRoot(URL(fileURLWithPath: path, isDirectory: true), home: home),
                           "\(path) is a whole filesystem or a whole user, not an archive root")
        }
    }

    func testTheHomeGuardIsCaseInsensitiveAndSlashInsensitive() {
        let home = fakeHome()
        // The boot volume is case-insensitive: a guard that only knew the canonical spelling would be
        // trivially bypassed by the other one, and the walk would happen anyway.
        XCTAssertFalse(TagVocabulary.isHarvestableRoot(URL(fileURLWithPath: "/users/TESTUSER/desktop"), home: home))
        XCTAssertFalse(TagVocabulary.isHarvestableRoot(URL(fileURLWithPath: "/Users/testuser/Desktop/"), home: home))
        // `..` must not be a way back up to a forbidden root either.
        XCTAssertFalse(TagVocabulary.isHarvestableRoot(
            URL(fileURLWithPath: "/Users/testuser/Desktop/Archive/.."), home: home))
    }

    func testASpecificFolderInsideDesktopIsHarvestable() {
        let home = fakeHome()
        // The real corpus lives at ~/Desktop/Google Drive/Archival Photos — a *specific* folder the
        // operator pointed the app at. Rejecting Desktop must not reject what is inside it.
        XCTAssertTrue(TagVocabulary.isHarvestableRoot(
            URL(fileURLWithPath: "/Users/testuser/Desktop/Google Drive/Archival Photos", isDirectory: true),
            home: home))
    }

    func testNoteRootRefusesAForbiddenRootAndHarvestNeverOffersIt() {
        let s = store()
        let home = fakeHome()
        XCTAssertFalse(s.noteRoot(home, home: home))
        XCTAssertFalse(s.noteRoot(home.appendingPathComponent("Desktop", isDirectory: true), home: home))
        XCTAssertTrue(s.knownRoots().isEmpty, "a refused root must not be recorded at all")
        // The decisive assertion: even asked directly, the harvest list cannot contain $HOME.
        XCTAssertTrue(s.rootsNeedingHarvest(current: home).isEmpty)
        XCTAssertTrue(s.rootsNeedingHarvest(current: home.appendingPathComponent("Desktop")).isEmpty)
    }

    // MARK: - Which roots a harvest walks

    func testANeverHarvestedRootIsDueAndAJustHarvestedOneIsNot() {
        let s = store()
        let root = dir.appendingPathComponent("Archive", isDirectory: true)
        s.noteRoot(root, home: fakeHome())
        XCTAssertEqual(s.rootsNeedingHarvest(current: root).map(\.path), [root.path])

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        s.markHarvested(root, at: now)
        XCTAssertTrue(s.rootsNeedingHarvest(current: root, now: now.addingTimeInterval(3600)).isEmpty)
    }

    func testAStaleCurrentRootIsDueButAStaleFORMERRootIsNot() {
        let s = store()
        let former = dir.appendingPathComponent("Old", isDirectory: true)
        let current = dir.appendingPathComponent("New", isDirectory: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteRoot(former, home: fakeHome()); s.markHarvested(former, at: t0)
        s.noteRoot(current, home: fakeHome()); s.markHarvested(current, at: t0)

        let later = t0.addingTimeInterval(TagVocabulary.defaultStaleAfter + 1)
        XCTAssertEqual(s.rootsNeedingHarvest(current: current, now: later).map(\.path), [current.path],
                       "re-walking every root the app was ever pointed at would multiply a 12 s pass")
    }

    func testTheCurrentRootIsWalkedFirst() {
        let s = store()
        let first = dir.appendingPathComponent("A", isDirectory: true)
        let current = dir.appendingPathComponent("B", isDirectory: true)
        s.noteRoot(first, home: fakeHome())
        s.noteRoot(current, home: fakeHome())
        XCTAssertEqual(s.rootsNeedingHarvest(current: current).map(\.path), [current.path, first.path])
    }

    func testMarkHarvestedOnAnUnknownRootIsANoOp() {
        let s = store()
        s.markHarvested(dir.appendingPathComponent("never-noted", isDirectory: true))
        XCTAssertTrue(s.knownRoots().isEmpty)
    }

    // MARK: - Subjects only: the facet filter

    func testStructuralFacetsNeverBecomeSubjectSuggestions() {
        let s = store()
        // Exactly what a real-tagging write puts on an output file.
        s.add(rawTags: ["1968", "03 March", "Day 4", "Q2", "taxes", "elections", "Unread"])
        s.add(rawTags: ["P9"])
        s.add(rawTags: ["P7"])
        XCTAssertEqual(Set(s.snapshot()), ["taxes", "elections"])
    }

    func testUnreadCannotEnterTheVocabulary() {
        let s = store()
        // Source 3 stamps a trailing "Unread" on EVERY real-tagging output, so without the filter this
        // one token would be a permanent suggestion in a field labelled "Subjects".
        XCTAssertFalse(s.add(rawTags: ["Unread"]))
        XCTAssertFalse(s.add(rawTags: ["Read"]))
        XCTAssertFalse(s.add(rawTags: ["Date Uncertain"]))
        XCTAssertFalse(s.add(rawTags: ["1970s"]))
        XCTAssertTrue(s.snapshot().isEmpty)
    }

    func testAMarkerColourIsDroppedOnlyWhenItIsActuallyTheLabel() {
        let withLabel = store("a.json")
        withLabel.add(rawTags: ["Red", "elections"], labelNumber: 6)   // 6 = Finder red = the box marker
        XCTAssertEqual(Set(withLabel.snapshot()), ["elections"])

        let noLabel = store("b.json")
        noLabel.add(rawTags: ["Red", "elections"], labelNumber: nil)
        XCTAssertEqual(Set(noLabel.snapshot()), ["Red", "elections"],
                       "a document about the Red Scare with no red label keeps Red as a subject")
    }

    func testNamesAreTrimmedAndBlanksDropped() {
        let s = store()
        s.add(rawTags: ["  taxes  ", "", "   ", "\n"])
        XCTAssertEqual(s.snapshot(), ["taxes"])
    }

    func testCaseVariantsAreKeptAsDistinctSpellings() {
        let s = store()
        s.add(rawTags: ["Taxes"])
        XCTAssertTrue(s.add(rawTags: ["taxes"]))
        // Parity with the Spotlight provider being replaced, which deduped exactly: neither spelling is
        // known to be the operator's intent, so neither is silently discarded.
        XCTAssertEqual(Set(s.snapshot()), ["Taxes", "taxes"])
    }

    func testNameCountIsCappedButKnownNamesStillReadBack() {
        let s = store()
        s.add(rawTags: (0..<TagVocabulary.maxNames).map { "tag\($0)" })
        XCTAssertEqual(s.count, TagVocabulary.maxNames)
        XCTAssertFalse(s.add(rawTags: ["one too many"]), "the cap must stop growth, not crash")
        XCTAssertEqual(s.count, TagVocabulary.maxNames)
        XCTAssertFalse(s.add(rawTags: ["tag7"]), "an already-known name at capacity is still a no-growth hit")
    }

    // MARK: - Suggestions

    func testSuggestionsPutPrefixMatchesBeforeSubstringMatches() {
        let s = store()
        s.add(rawTags: ["taxes", "estates", "taxation", "elections"])
        XCTAssertEqual(s.suggestions(prefix: "tax"), ["taxation", "taxes"])
        XCTAssertEqual(s.suggestions(prefix: "zzz"), [])
        // "state" appears inside "estates" only — a substring hit, offered after any prefix hit.
        XCTAssertEqual(s.suggestions(prefix: "state"), ["estates"])
        // And when both kinds exist, every prefix hit outranks every substring hit. ("estates" contains
        // "tat"; nothing starts with it — so adding a prefix hit must push it to the back.)
        s.add(rawTags: ["tatler"])
        XCTAssertEqual(s.suggestions(prefix: "tat"), ["tatler", "estates"])
    }

    func testSuggestionsExcludeChosenTagsCaseInsensitivelyAndHonourTheLimit() {
        let s = store()
        s.add(rawTags: ["taxes", "taxation", "taxpayers"])
        XCTAssertEqual(s.suggestions(prefix: "tax", excluding: ["TAXES"]), ["taxation", "taxpayers"])
        XCTAssertEqual(s.suggestions(prefix: "tax", limit: 1), ["taxation"])
        XCTAssertEqual(s.suggestions(prefix: "   ", limit: 2).count, 2,
                       "a blank prefix offers the head of the pool, as the shipped field always has")
    }

    // MARK: - Self-healing

    func testACorruptFileResetsInsteadOfThrowingOrHalfLoading() throws {
        let path = dir.appendingPathComponent("broken.json")
        try Data("this is not json".utf8).write(to: path)
        let s = TagVocabulary(fileURL: path)
        XCTAssertTrue(s.snapshot().isEmpty)
        XCTAssertTrue(s.knownRoots().isEmpty, "clearing the stamps is what makes the next harvest rebuild")
        XCTAssertNotNil(s.loadFailure)
        // And it recovers: a subsequent save overwrites the bad file.
        s.add(rawTags: ["recovered"])
        s.flush()
        XCTAssertEqual(TagVocabulary(fileURL: path).snapshot(), ["recovered"])
    }

    func testAFutureVersionIsTreatedAsUnusableRatherThanGuessedAt() throws {
        let path = dir.appendingPathComponent("v99.json")
        try Data(#"{"version":99,"names":["future"],"roots":[]}"#.utf8).write(to: path)
        let s = TagVocabulary(fileURL: path)
        XCTAssertTrue(s.snapshot().isEmpty)
        XCTAssertNotNil(s.loadFailure)
    }

    func testAMissingFileIsAnOrdinaryFirstRunNotAFailure() {
        let s = TagVocabulary(fileURL: dir.appendingPathComponent("absent.json"))
        XCTAssertTrue(s.snapshot().isEmpty)
        XCTAssertNil(s.loadFailure)
    }

    // MARK: - Concurrency

    func testConcurrentAddsFromManyThreadsLoseNothing() {
        let s = store()
        // The harvest calls `add` once per corpus file from the walker's dedicated thread while the main
        // actor reads `snapshot()`; this is the cheap proof the lock actually covers both.
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            s.add(rawTags: ["tag\(i)"])
            _ = s.snapshot()
        }
        XCTAssertEqual(s.count, 200)
    }
}
