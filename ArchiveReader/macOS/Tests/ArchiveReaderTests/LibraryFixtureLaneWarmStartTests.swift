import XCTest
import ArchiveCore
@testable import ArchiveReader

/// `W26.verify-fu2` — the two DEBUG launch hooks that make the fixture lane's WARM start observable,
/// and the existing contract they are not allowed to disturb.
///
/// A fixture root deliberately has no warm-start cache at all: `usesPersistedIndex` answers NO, so it
/// scans synchronously and never opens the real `library-index-v1.sqlite3`. That is what made the
/// warm-start UI unverifiable in the VM — there is nothing warm to look at. `ARUITestLibraryIndexPath`
/// buys warm start back for exactly the lane that names its own SCRATCH database;
/// `ARUITestScanHoldSeconds` turns the `.revalidating` window from a sub-100 ms transient into a state
/// a UI test can enter deliberately.
///
/// Both keys are read from the INJECTED defaults domain (`fixtureDefaults`), so nothing here can reach
/// the owner's `com.archivereader.app` domain — the `W26.fixturehang` leak. Scratch corpora and
/// scratch SQLite files only.
@MainActor
final class LibraryFixtureLaneWarmStartTests: XCTestCase {

    /// The contract the hooks must not break. With NO index key, a pinned fixture root is still
    /// synchronous — `DocumentPageLinkTests` and `RootMarkerStateTests` read `files` the instant
    /// construction returns — and still writes no cache database at all.
    func testAFixtureRootWithoutTheIndexKeyStaysSynchronousAndPersistsNothing() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(under: scratch)
        let database = scratch.appendingPathComponent("must-not-be-created.sqlite3")
        let library = makeLibrary(pinnedTo: corpus, indexURL: database, defaults: laneDefaults(pinnedTo: corpus))

        library.start(scope: corpus, markerGUID: Self.marker)

        // Synchronous: no `await`, no polling. This assertion IS the calibration the fixture lane relies on.
        XCTAssertTrue(library.phase.isSettled, "a fixture root without an index key must settle inline")
        XCTAssertEqual(library.files.map(\.url.lastPathComponent).sorted(), ["one.pdf", "two.pdf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path),
                       "no index key means no persisted cache is opened, let alone written")
        await library.closeLibraryIndexForTesting()
    }

    /// The hold key alone changes nothing. Without a scratch cache there are no warm rows for a hold to
    /// hold over, so the hook must stay off rather than half-enable the async path under the existing
    /// fixture tests.
    func testTheHoldKeyAloneCannotSwitchAFixtureRootOntoTheAsynchronousPath() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(under: scratch)
        let defaults = laneDefaults(pinnedTo: corpus)
        defaults.set(30.0, forKey: "ARUITestScanHoldSeconds")   // absurdly long, deliberately ignored
        let library = makeLibrary(pinnedTo: corpus,
                                  indexURL: scratch.appendingPathComponent("unused.sqlite3"),
                                  defaults: defaults)

        library.start(scope: corpus, markerGUID: Self.marker)

        XCTAssertTrue(library.phase.isSettled, "a 30 s hold must not reach a root that has no warm cache")
        XCTAssertEqual(library.files.count, 2)
        await library.closeLibraryIndexForTesting()
    }

    /// `ARUITestLibraryIndexPath` SUBSTITUTES for whatever database the caller passed, and that
    /// substitution is what keeps the owner's real Application Support file out of reach while a
    /// fixture is pinned: the passed URL is never created, the named one is.
    func testTheIndexKeySubstitutesForThePassedDatabaseAndWarmStartsFromIt() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(under: scratch)
        let ignored = scratch.appendingPathComponent("stand-in-for-the-real-one.sqlite3")
        let scratchDB = scratch.appendingPathComponent("fixture-warm-start.sqlite3")

        let cold = makeLibrary(pinnedTo: corpus, indexURL: ignored,
                               defaults: laneDefaults(pinnedTo: corpus, scratchIndex: scratchDB))
        cold.start(scope: corpus, markerGUID: Self.marker)
        try await wait("the cold pass and its SQLite commit") { cold.phase.isSettled }
        XCTAssertEqual(cold.files.count, 2)
        XCTAssertFalse(try XCTUnwrap(cold.files.first).provenance.isCache, "a cold pass has no cache to read")
        await cold.closeLibraryIndexForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: scratchDB.path),
                      "the named scratch database is the one that got written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignored.path),
                       "the passed URL must be substituted away, not used as a fallback")

        // Second launch, same scratch database: this is warm start, in the fixture lane, for the first
        // time. The pass is held at the production `indexedScanStarter` seam rather than by the DEBUG
        // hold key, so this test proves the SUBSTITUTION on its own — and holding it is not optional:
        // released, revalidation of two files finishes inside 10 ms and the run above observed
        // `settled` before it could ever see `revalidating`. That transient is the whole reason the
        // hold key exists for the UI lane.
        let paused = PausedFixtureLaneScan()
        let warm = makeLibrary(pinnedTo: corpus, indexURL: ignored,
                               defaults: laneDefaults(pinnedTo: corpus, scratchIndex: scratchDB),
                               starter: { paused.request = $0 })
        warm.start(scope: corpus, markerGUID: Self.marker)
        try await wait("the cache to publish before revalidation") { paused.request != nil }
        guard case let .revalidating(asOf) = warm.phase else {
            return XCTFail("warm fixture rows must paint as revalidating, got \(warm.phase)")
        }
        XCTAssertNotNil(asOf, "the preceding clean pass dates the cache")
        XCTAssertTrue(try XCTUnwrap(warm.files.first).provenance.isCache)

        let request = try XCTUnwrap(paused.request)
        request.completion(LibraryScan.revalidatedPass(root: request.root, cached: request.cached,
                                                       isCancelled: request.isCancelled,
                                                       onBatch: request.onBatch))
        try await wait("revalidation to settle") { warm.phase.isSettled }
        XCTAssertFalse(try XCTUnwrap(warm.files.first).provenance.isCache)
        await warm.closeLibraryIndexForTesting()
    }

    /// The hold's whole purpose, plus the thing it must not be mistaken for. `.revalidating` survives
    /// well past a stall deadline shorter than the hold, because the hold is the app waiting on the
    /// TEST — not the archive folder failing to answer. Then the real pass runs and settles.
    func testTheHoldKeepsWarmRowsRevalidatingAndIsNeverReportedAsAStall() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(under: scratch)
        let scratchDB = scratch.appendingPathComponent("fixture-warm-start.sqlite3")

        let cold = makeLibrary(pinnedTo: corpus, indexURL: scratchDB,
                               defaults: laneDefaults(pinnedTo: corpus, scratchIndex: scratchDB))
        cold.start(scope: corpus, markerGUID: Self.marker)
        try await wait("the cold pass to seed the cache") { cold.phase.isSettled }
        await cold.closeLibraryIndexForTesting()

        // A stall deadline FIVE TIMES shorter than the hold. Without the ordering in `beginScan` this
        // is precisely the run that would report "Archive folder has not answered" about its own hook.
        let warm = makeLibrary(pinnedTo: corpus, indexURL: scratchDB,
                               defaults: laneDefaults(pinnedTo: corpus, scratchIndex: scratchDB,
                                                      hold: 1.0),
                               stallAfter: 0.2)
        warm.start(scope: corpus, markerGUID: Self.marker)
        try await wait("the cache rows to publish") { !warm.files.isEmpty }

        try await Task.sleep(nanoseconds: 600_000_000)   // 3x the stall deadline, inside the hold
        guard case .revalidating = warm.phase else {
            return XCTFail("the held pass must still be revalidating, not degraded — got \(warm.phase)")
        }
        XCTAssertNil(warm.phase.failure, "a hold the app itself imposed is not a folder that went quiet")
        XCTAssertNil(warm.discoveryFailure)
        XCTAssertEqual(warm.files.count, 2, "and the warm rows stay on screen throughout")

        try await wait("the hold to expire and the pass to settle") { warm.phase.isSettled }
        XCTAssertEqual(warm.files.map(\.url.lastPathComponent).sorted(), ["one.pdf", "two.pdf"])
        await warm.closeLibraryIndexForTesting()
    }

    // MARK: - Fixtures

    /// Fixed so the two launches of a warm-start test agree on the cache key, exactly as the GUI
    /// fixture's `.archive-suite-root.json` GUID does for the VM lane.
    private static let marker = UUID(uuidString: "a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40")!

    /// Named `laneDefaults`, not an overload of `fixtureDefaults`: an overload whose extra arguments
    /// all have defaults would be ambiguous with the shared helper at every call site.
    private func laneDefaults(pinnedTo root: URL, scratchIndex: URL? = nil,
                              hold: TimeInterval? = nil,
                              _ testName: String = #function) -> UserDefaults {
        let suite = fixtureDefaults(pinnedTo: root, testName)
        if let scratchIndex { suite.set(scratchIndex.path, forKey: "ARUITestLibraryIndexPath") }
        if let hold { suite.set(hold, forKey: "ARUITestScanHoldSeconds") }
        return suite
    }

    private func makeLibrary(pinnedTo root: URL, indexURL: URL, defaults: UserDefaults,
                             stallAfter: TimeInterval = 5.0,
                             starter: (@MainActor (IndexedLibraryScanRequest) -> Void)? = nil) -> ArchiveLibrary {
        if let starter {
            return ArchiveLibrary(minimumRootRescanInterval: 0,
                                  libraryIndexURL: indexURL,
                                  scanStallTimeout: stallAfter,
                                  defaults: defaults,
                                  watcherFactory: { _, _ in SilentFixtureLaneWatcher() },
                                  indexedScanStarter: starter)
        }
        return ArchiveLibrary(minimumRootRescanInterval: 0,
                              libraryIndexURL: indexURL,
                              scanStallTimeout: stallAfter,
                              defaults: defaults,
                              watcherFactory: { _, _ in SilentFixtureLaneWatcher() })
    }

    private func makeScratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryFixtureLaneWarmStartTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCorpus(under scratch: URL) throws -> URL {
        let root = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["one.pdf", "two.pdf"] {
            let url = root.appendingPathComponent(name)
            try Data("PDF fixture bytes".utf8).write(to: url)
            try (URL(fileURLWithPath: url.path) as NSURL)
                .setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        return root
    }

    private func wait(_ description: String, timeout: TimeInterval = 15,
                      until condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }
}

@MainActor
private final class PausedFixtureLaneScan {
    var request: IndexedLibraryScanRequest?
}

/// The stream is not what these tests are about: it comes up instantly so the walk is never held behind
/// `W26.fsev-fu1`'s own deadline.
private final class SilentFixtureLaneWatcher: CorpusWatching {
    func start() -> CorpusWatcherStartResult { .started }
    func stop() {}
    func flushSync() -> Bool { true }
}
