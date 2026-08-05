import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.walk2 — **the incident, inverted, against the PRODUCTION discovery path.**
///
/// ⚠️ **Every case here requires `ARUITestRootPath` to be ABSENT, and asserts it** (plan §7a.9). That
/// key used to select a different discovery *mechanism* — the `#if DEBUG` fixture loader — so a
/// regression test that set it would have exercised a filesystem walk and proved nothing about the
/// Release build, which had no filesystem discovery at all. Since walk2 the key changes only the
/// delivery *thread* (synchronous, for the two shipped tests that assert right after `init`), so
/// leaving it unset is what makes these run the real thing: a dedicated `Thread`, off the main actor,
/// delivering through the same completion the app uses.
///
/// **The headline case must have failed for the right reason before the swap.** `testANeverIndexed…`
/// walks a temp directory Spotlight has never touched. On `003ca59` this reached `NSMetadataQuery`,
/// which returns nothing for such a path, so it would have found 0 of 3 tagged files — which is
/// precisely what the owner saw over 1,849 of them.
///
/// Throwaway temp fixtures only — never the corpus, and never the app's granted root.
@MainActor
final class LibraryDiscoverySwapTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeRoot() throws -> URL {
        XCTAssertNil(UserDefaults.standard.string(forKey: "ARUITestRootPath"),
                     "these cases must run the PRODUCTION path — plan §7a.9. A leaked key voids them.")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryDiscoverySwapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        addTeardownBlock {
            unseal(path)                       // a sealed entry blocks its own removal
            try? FileManager.default.removeItem(atPath: path)
        }
        return dir
    }

    @discardableResult
    private func makeFile(_ name: String, tags: [String] = [], in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty {
            // A FRESH URL for the write: `URL` caches resource values on its backing `NSURL`, which is
            // how this wave's first measurement came to assert nothing (plan §4a.1).
            try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        return url
    }

    /// Wait for the in-flight pass to finish. `Task.sleep` yields the main actor, so the library's
    /// `DispatchQueue.main.async` completion can run — which is also the proof that it is asynchronous.
    private func waitForPass(_ library: ArchiveLibrary, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !library.phase.isScanning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("discovery did not finish within \(timeout)s (phase: \(library.phase))")
    }

    private func names(_ library: ArchiveLibrary) -> [String] {
        library.files.map { $0.url.lastPathComponent }.sorted()
    }

    // MARK: - 1. THE regression guard for the whole wave

    func testANeverIndexedFolderStillListsEveryTaggedFile() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], in: root)
        try makeFile("b.pdf", tags: ["Read", "Subject/Rosevelt"], in: root)
        try makeFile("Box 1/c.pdf", tags: ["unread"], in: root)     // nested + case-insensitive
        try makeFile("untagged.pdf", in: root)
        try makeFile("subject-only.pdf", tags: ["Subject/Bar"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)

        // Proof this is the production path and not the synchronous fixture one: nothing is published
        // yet, because the walk is on another thread and this actor has not yielded.
        XCTAssertTrue(library.phase.isFirstScan, "the production path scans off the main actor")
        XCTAssertTrue(library.files.isEmpty)

        try await waitForPass(library)

        XCTAssertEqual(names(library), ["a.pdf", "b.pdf", "c.pdf"],
                       "a folder Spotlight has never indexed must still list every tagged file")
        guard case let .settled(_, scanned) = library.phase else {
            return XCTFail("expected .settled, got \(library.phase)")
        }
        XCTAssertEqual(scanned, 5, "all five regular files were examined; three matched")
        XCTAssertEqual(LibraryEmptyState.forPhase(library.phase, rowCount: 3, displayedCount: 3), nil)
    }

    // MARK: - 2. "Nothing is tagged" is only said with a denominator

    func testAGenuinelyUntaggedFolderSaysSoAndCountsWhatItScanned() async throws {
        let root = try makeRoot()
        try makeFile("one.pdf", in: root)
        try makeFile("two.pdf", in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)

        XCTAssertTrue(library.files.isEmpty)
        guard case let .settled(_, scanned) = library.phase else {
            return XCTFail("expected .settled, got \(library.phase)")
        }
        XCTAssertEqual(scanned, 2)
        XCTAssertEqual(LibraryEmptyState.forPhase(library.phase, rowCount: 0, displayedCount: 0),
                       .nothingTagged(scanned: 2),
                       "the ONLY wording allowed to blame the folder — and it quotes the count")
    }

    // MARK: - 3. An unreadable file KEEPS its row, and the pass loses its authority

    func testASealedFileKeepsItsRowAndDegradesThePass() async throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = try makeRoot()
        try makeFile("readable.pdf", tags: ["Read"], in: root)
        let sealed = try makeFile("sealed.pdf", tags: ["Unread", "Subject/Foo"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)
        XCTAssertEqual(names(library), ["readable.pdf", "sealed.pdf"])
        XCTAssertTrue(library.phase.isSettled)
        let rowBefore = try XCTUnwrap(library.files.first { $0.url.lastPathComponent == "sealed.pdf" })

        // Now make one file's tags unreadable and re-walk.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sealed.path)
        library.rescan()
        try await waitForPass(library)

        // plan §7a.3, walk2's half: "I could not read it" must not render as "it is gone".
        XCTAssertEqual(names(library), ["readable.pdf", "sealed.pdf"],
                       "an unreadable file keeps its last-known row rather than vanishing")
        let rowAfter = try XCTUnwrap(library.files.first { $0.url.lastPathComponent == "sealed.pdf" })
        XCTAssertEqual(rowAfter.tags, rowBefore.tags,
                       "and it keeps the tags we last read — never coerced to none (the W26.deny bug)")
        XCTAssertEqual(rowAfter.readState, .unread)
        XCTAssertEqual(library.phase.failure, .partiallyUnreadable(files: 1, folders: 0))
        XCTAssertFalse(library.phase.isSettled,
                       "§7a.4: a degraded pass must not authorise pruning content-index rows")
    }

    /// A directory denial is more dangerous than a file denial: the enumerator never yields its
    /// descendants, so there is no per-file failure URL from which to recover them. A degraded pass's
    /// absences are non-authoritative as a set; every previously-visible unseen row must survive.
    func testAnUnreadableDirectoryKeepsPreviouslyVisibleDescendantRows() async throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = try makeRoot()
        try makeFile("visible.pdf", tags: ["Read"], in: root)
        let hidden = try makeFile("Sealed/hidden.pdf", tags: ["Unread", "Subject/Foo"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)
        XCTAssertEqual(names(library), ["hidden.pdf", "visible.pdf"])

        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: hidden.deletingLastPathComponent().path)
        library.rescan()
        try await waitForPass(library)

        XCTAssertEqual(names(library), ["hidden.pdf", "visible.pdf"],
                       "a folder we could not enter is not evidence that its prior rows disappeared")
        XCTAssertEqual(library.phase.failure, .partiallyUnreadable(files: 0, folders: 1))
        XCTAssertFalse(library.phase.isSettled)
    }

    // MARK: - 4. An unreadable ROOT is unreadable, not empty

    func testASealedRootIsDegradedRatherThanEmpty() async throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = try makeRoot()
        try makeFile("hidden-by-permissions.pdf", tags: ["Unread"], in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)

        XCTAssertTrue(library.files.isEmpty, "nothing could be read, so nothing is listed")
        XCTAssertEqual(library.phase.failure, .rootUnreadable,
                       "and the app says THAT, instead of stating a fact about the folder's contents")
        XCTAssertEqual(LibraryEmptyState.forPhase(library.phase, rowCount: 0, displayedCount: 0),
                       .couldNotLook(.rootUnreadable))
    }

    // MARK: - 5. The ordering guard that replaced the TTL overlay (plan §7a.2)

    /// Deterministic by construction, not by timing: the walk runs on another thread and delivers via
    /// `DispatchQueue.main.async`, so nothing it publishes can land until this test yields the main
    /// actor. Calling `applyVerifiedWrites` before the first `await` therefore guarantees the write is
    /// stamped NEWER than the in-flight pass — which is exactly the 2,000-row-mark-Read scenario, where
    /// a re-walk reads files whose writes have not landed yet and its emission arrives afterwards.
    func testAVerifiedWriteOutranksAWalkThatStartedBeforeIt() async throws {
        let root = try makeRoot()
        let target = try makeFile("target.pdf", tags: ["Unread"], in: root)
        try makeFile("other.pdf", tags: ["Unread"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)
        XCTAssertEqual(library.files.first { $0.url == target }?.readState, .unread)

        // A pass starts…
        library.rescan()
        // …and a verified write lands while it is in flight. On disk the file still says "Unread"; the
        // write's re-read (`.after`) is ground truth and must survive the pass's emission.
        library.applyVerifiedWrites([TagWriteResult(url: target, before: ["Unread"], after: ["Read"],
                                                    beforeLabel: nil, afterLabel: nil,
                                                    inverse: TagDelta(add: ["Unread"], remove: ["Read"]))])
        XCTAssertEqual(library.files.first { $0.url == target }?.readState, .read,
                       "the write shows immediately, so the row can leave a filtered view at once")

        try await waitForPass(library)

        XCTAssertEqual(library.files.first { $0.url == target }?.readState, .read,
                       "a walk that started BEFORE the write must not publish the pre-write value")
        XCTAssertEqual(library.files.first { $0.url.lastPathComponent == "other.pdf" }?.readState, .unread,
                       "and it is only that row — everything else comes from disk as usual")
    }

    /// The other half of the same guard: once a pass that started AFTER the write completes, the disk
    /// is authoritative again. Without this the override would be a permanent lie about the file.
    func testAWalkThatStartedAfterTheWriteIsAuthoritativeAgain() async throws {
        let root = try makeRoot()
        let target = try makeFile("target.pdf", tags: ["Unread"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)

        // A write claiming "Read" that never reached the disk (the disk still says Unread).
        library.applyVerifiedWrites([TagWriteResult(url: target, before: ["Unread"], after: ["Read"],
                                                    beforeLabel: nil, afterLabel: nil,
                                                    inverse: TagDelta(add: ["Unread"], remove: ["Read"]))])
        XCTAssertEqual(library.files.first { $0.url == target }?.readState, .read)

        library.rescan()                 // starts after the write → the walk wins
        try await waitForPass(library)

        XCTAssertEqual(library.files.first { $0.url == target }?.readState, .unread,
                       "no TTL and no timer: the next pass to start after the write simply supersedes it")
    }

    /// A write that leaves no Read/Unread tag drops the row, because membership no longer holds.
    /// Spotlight used to do this a beat later on its next update; nothing else would now.
    func testAWriteThatClearsReadStateRemovesTheRow() async throws {
        let root = try makeRoot()
        let target = try makeFile("target.pdf", tags: ["Unread"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)
        XCTAssertEqual(names(library), ["target.pdf"])

        library.applyVerifiedWrites([TagWriteResult(url: target, before: ["Unread"], after: [],
                                                    beforeLabel: nil, afterLabel: nil,
                                                    inverse: TagDelta(add: ["Unread"]))])

        XCTAssertTrue(library.files.isEmpty, "it no longer carries a Read or Unread tag")
    }

    // MARK: - 6. Rescan, and a superseded pass

    func testRescanPicksUpAFileAddedAfterTheFirstPass() async throws {
        let root = try makeRoot()
        try makeFile("first.pdf", tags: ["Unread"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)
        XCTAssertEqual(names(library), ["first.pdf"])

        try makeFile("second.pdf", tags: ["Read"], in: root)
        XCTAssertEqual(names(library), ["first.pdf"], "no watcher yet — W26.fsev is the next item")

        library.rescan()
        // A rescan behind existing rows must NOT blank them: `.firstScan` is the only phase whose
        // spinner covers the list, and this is not it.
        XCTAssertFalse(library.phase.isFirstScan)
        XCTAssertEqual(names(library), ["first.pdf"], "rows stay on screen while the pass runs")
        try await waitForPass(library)

        XCTAssertEqual(names(library), ["first.pdf", "second.pdf"])
    }

    /// A root switch mid-scan must not let the old root's pass publish over the new one
    /// (`ContentIndexer`'s generation-token discipline, same shape).
    func testASupersededPassPublishesNothing() async throws {
        let rootA = try makeRoot()
        for i in 0..<40 { try makeFile("a\(i).pdf", tags: ["Unread"], in: rootA) }
        let rootB = try makeRoot()
        try makeFile("b.pdf", tags: ["Read"], in: rootB)

        let library = ArchiveLibrary()
        library.start(scope: rootA)
        library.start(scope: rootB)      // before A's pass can deliver — this actor has not yielded
        try await waitForPass(library)

        XCTAssertEqual(names(library), ["b.pdf"], "A's pass must publish nothing at all")
        XCTAssertEqual(library.scopeDescription, rootB.lastPathComponent)

        // And nothing arrives late either.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(names(library), ["b.pdf"])
    }

    func testClearingTheRootEmptiesTheLibraryAndSaysNoRoot() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], in: root)

        let library = ArchiveLibrary()
        library.start(scope: root)
        try await waitForPass(library)
        XCTAssertFalse(library.files.isEmpty)

        library.start(scope: nil)

        XCTAssertTrue(library.files.isEmpty)
        XCTAssertEqual(library.phase, .noRoot)
        XCTAssertEqual(library.scopeDescription, "No folder selected")
    }
}

/// Restore owner access below `path` so a deliberately sealed fixture entry can be deleted.
private func unseal(_ path: String) {
    let fm = FileManager.default
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    guard let en = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                 options: [], errorHandler: { _, _ in true }) else { return }
    while let u = en.nextObject() as? URL {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
}
