import XCTest
import ArchiveCore
@testable import ArchiveReader

/// `W26.fsev-fu2` — the WALK's half of the launch stall.
///
/// `W26.fsev-fu1` bounded the FSEvents stream's `open(2)`, so an unopenable root draws a window and the
/// status bar says live updates are not responding. `CorpusWalker`'s own `opendir(3)` probe blocks on
/// the same root with no bound at all, and the pass then never calls `finish` — so `LibraryPhase` sat
/// at `.firstScan(done: 0, seen: 0)` and `LibraryEmptyState` read that as `.scanning`: an honest status
/// bar above a spinner that lies for ever.
///
/// **A held pass is the real mechanism, not a stand-in for it.** These tests take the production
/// `indexedScanStarter` seam and simply never deliver the request — which is exactly what a thread
/// blocked in `opendir` does. Provoking a genuinely blocking `opendir` needs an unresponsive network
/// mount or an unanswered TCC prompt; neither is available to a unit test, and the code under test
/// cannot tell the difference: it only ever observes "no completion, no progress".
///
/// Scratch corpora and scratch SQLite files only.
@MainActor
final class LibraryScanStallTests: XCTestCase {

    /// The item's own test, both halves: a first scan whose walk never returns reaches a *stated*
    /// degraded phase, and a pass that finishes after the deadline still publishes its rows.
    func testAWalkThatNeverAnswersDegradesInsteadOfSpinningForever() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(file: "report.pdf", tags: ["Unread"], under: scratch)
        let held = HeldScans()
        let library = makeLibrary(scratch: scratch, stallAfter: 0.5, held: held)

        library.start(scope: corpus, markerGUID: UUID())
        // Synchronous, so this precondition cannot race the deadline: before it fires, the app is in
        // precisely the state the item describes — scanning, blaming nothing, showing nothing.
        XCTAssertTrue(library.phase.isFirstScan)
        XCTAssertNil(library.phase.failure)

        try await wait("the walk to be handed to its thread") { held.latest != nil }
        try await wait("the stall deadline") { library.phase.failure == .scanStalled }

        XCTAssertFalse(library.phase.isFirstScan,
                       "the list-blanking spinner is what the deadline exists to take down")
        XCTAssertEqual(library.discoveryFailure?.message, "Archive folder has not answered")
        XCTAssertTrue(library.discoveryFailure?.detail.contains("no answer yet") == true)

        // The walk finally comes back. The generation token already permits a late pass to supersede
        // the interim verdict; nothing about the deadline may stand in its way.
        let request = try XCTUnwrap(held.latest)
        request.completion(LibraryScan.revalidatedPass(root: request.root, cached: request.cached,
                                                       isCancelled: request.isCancelled))
        try await wait("the late pass to publish") { library.phase.isSettled }

        XCTAssertEqual(library.files.map(\.url.lastPathComponent), ["report.pdf"])
        XCTAssertNil(library.discoveryFailure, "a finished clean pass withdraws the stall entirely")
        await library.closeLibraryIndexForTesting()
    }

    /// The one thing a timeout must never buy. `.degraded` is not settled, so no content-index pruning
    /// and no authoritative absence — and the empty state says *"could not look"* rather than reaching
    /// `.nothingTagged` / `.folderIsEmpty`, which are the 2026-08-04 incident's own sentences.
    func testAStalledScanIsNotEvidenceAboutTheFolderAndGrantsNothing() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = scratch.appendingPathComponent("empty-looking", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let held = HeldScans()
        let library = makeLibrary(scratch: scratch, stallAfter: 0.2, held: held)

        library.start(scope: corpus, markerGUID: UUID())
        try await wait("the stall deadline") { library.phase.failure == .scanStalled }

        XCTAssertFalse(library.phase.isSettled,
                       "a stalled pass may not authorise pruning or authoritative absence")
        XCTAssertTrue(library.files.isEmpty)
        XCTAssertEqual(LibraryEmptyState.forPhase(library.phase, rowCount: 0, displayedCount: 0),
                       .couldNotLook(.scanStalled),
                       "an unread folder is never described as an empty or untagged one")
        await library.closeLibraryIndexForTesting()
    }

    /// ⌘⌥R is the likeliest thing an owner staring at "has not answered" will press — and the
    /// failure's own tooltip says it will not force the stalled read to return. `requestRootRescan`
    /// optimistically resets the phase to a scanning one, but `drainWatchWork` refuses to start
    /// anything while the stalled walk is still in flight, so without the guard the press would put
    /// back the exact silent spinner this item removes.
    func testRescanningAStalledFolderDoesNotPutBackTheSpinner() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(file: "report.pdf", tags: ["Unread"], under: scratch)
        let held = HeldScans()
        let library = makeLibrary(scratch: scratch, stallAfter: 0.2, held: held)

        library.start(scope: corpus, markerGUID: UUID())
        try await wait("the stall deadline") { library.phase.failure == .scanStalled }

        library.rescan()
        XCTAssertEqual(library.phase.failure, .scanStalled,
                       "a rescan that cannot start must not overwrite the reason it cannot")
        XCTAssertEqual(held.requests.count, 1, "and it really did not start a second walk")

        // Not wedged, though: the queued rescan runs the moment the stalled walk returns.
        let request = try XCTUnwrap(held.latest)
        request.completion(LibraryScan.revalidatedPass(root: request.root, cached: request.cached,
                                                       isCancelled: request.isCancelled))
        try await wait("the queued rescan to be released") { held.requests.count == 2 }
        let second = try XCTUnwrap(held.latest)
        second.completion(LibraryScan.revalidatedPass(root: second.root, cached: second.cached,
                                                      isCancelled: second.isCancelled))
        try await wait("the rescan to settle") { library.phase.isSettled }
        XCTAssertEqual(library.files.map(\.url.lastPathComponent), ["report.pdf"])
        await library.closeLibraryIndexForTesting()
    }

    /// A walk that is merely SLOW is not a walk that is stuck. One examined file proves the pass is
    /// past the root probe, and the corpus takes 10.15 s to walk in full — so the deadline keys on
    /// files seen, never on elapsed time alone.
    func testAWalkThatIsProgressingIsNeverCalledStalled() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(file: "report.pdf", tags: ["Unread"], under: scratch)
        let held = HeldScans()
        let library = makeLibrary(scratch: scratch, stallAfter: 0.2, held: held)

        library.start(scope: corpus, markerGUID: UUID())
        try await wait("the walk to be handed to its thread") { held.latest != nil }
        try XCTUnwrap(held.latest).onBatch?(CorpusScanBatch(entries: [], filesSeen: 3))
        try await wait("progress to reach the phase") { library.phase == .firstScan(done: 0, seen: 3) }

        try await Task.sleep(nanoseconds: 500_000_000)   // well past the deadline

        XCTAssertNil(library.phase.failure, "a pass that has examined files has answered")
        XCTAssertEqual(library.phase, .firstScan(done: 0, seen: 3))
        await library.closeLibraryIndexForTesting()
    }

    /// The verdict is interim, so progress withdraws it — not only a completed pass. Without this the
    /// app would keep saying "could not look" while the walk was visibly producing rows, for as long
    /// as the rest of the walk took.
    func testTheFirstFileSeenAfterTheDeadlineWithdrawsTheStall() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = try makeCorpus(file: "report.pdf", tags: ["Unread"], under: scratch)
        let held = HeldScans()
        let library = makeLibrary(scratch: scratch, stallAfter: 0.2, held: held)

        library.start(scope: corpus, markerGUID: UUID())
        try await wait("the stall deadline") { library.phase.failure == .scanStalled }

        try XCTUnwrap(held.latest).onBatch?(CorpusScanBatch(entries: [], filesSeen: 4))
        try await wait("the stall to be withdrawn") { library.phase.failure == nil }

        XCTAssertEqual(library.phase, .firstScan(done: 0, seen: 4),
                       "and the counts resume from the progress that withdrew it")
        await library.closeLibraryIndexForTesting()
    }

    // MARK: - Fixtures

    /// A library whose walk is HELD rather than run: `indexedScanStarter` captures the request and
    /// never completes it. The cold cache database is a scratch file, so no test can reach the
    /// owner's real Application Support index.
    private func makeLibrary(scratch: URL, stallAfter: TimeInterval,
                             held: HeldScans) -> ArchiveLibrary {
        // A fixture root answers NO to the persisted index and scans SYNCHRONOUSLY, which would route
        // straight past the seam these tests hold. A leaked key from another suite must fail loudly
        // rather than quietly turn every assertion below into a tautology.
        XCTAssertNil(UserDefaults.standard.string(forKey: "ARUITestRootPath"),
                     "these tests must exercise the production asynchronous walk")
        return ArchiveLibrary(minimumRootRescanInterval: 0,
                       libraryIndexURL: scratch.appendingPathComponent("library-index.sqlite3"),
                       scanStallTimeout: stallAfter,
                       watcherFactory: { _, _ in SilentStallWatcher() },
                       indexedScanStarter: { held.hold($0) })
    }

    private func makeScratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryScanStallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCorpus(file: String, tags: [String], under scratch: URL) throws -> URL {
        let root = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(file)
        try Data("PDF fixture bytes".utf8).write(to: url)
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return root
    }

    private func wait(_ description: String, timeout: TimeInterval = 10,
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
private final class HeldScans {
    private(set) var requests: [IndexedLibraryScanRequest] = []
    func hold(_ request: IndexedLibraryScanRequest) { requests.append(request) }
    var latest: IndexedLibraryScanRequest? { requests.last }
}

/// The stream is not what is being tested here: it comes up instantly so the walk is never held
/// behind `W26.fsev-fu1`'s own deadline.
private final class SilentStallWatcher: CorpusWatching {
    func start() -> CorpusWatcherStartResult { .started }
    func stop() {}
    func flushSync() -> Bool { true }
}
