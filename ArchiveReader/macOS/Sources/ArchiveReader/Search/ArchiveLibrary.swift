import Foundation
import Combine
import ArchiveCore

struct ResolvedLibraryRoot: Sendable {
    let url: URL
    let markerGUID: UUID?
}

/// Injectable only so the warm-start contract can be tested without a timing race. Production uses
/// the same dedicated thread as before; a test can hold this request after cache rows are published,
/// inspect that intermediate state, then run and deliver the real revalidation pass.
struct IndexedLibraryScanRequest: Sendable {
    let root: URL
    let cached: [LibraryIndexPath: LibraryIndexEntry]
    let isCancelled: @Sendable () -> Bool
    let onBatch: (@Sendable (CorpusScanBatch) -> Void)?
    let completion: @Sendable (DiscoveryPass) -> Void
}

/// Discovers the tagged-PDF universe by **walking the filesystem** (`ArchiveCore.CorpusWalker`).
///
/// The master predicate is unchanged — a file belongs to the library iff it carries a `Read` or
/// `Unread` tag (`CorpusWalker.tracksReadState`, shared so discovery and the write path cannot drift).
/// Tag facets here are for display/sort/filter only; the authoritative read for a write is done inside
/// `TagWriter`.
///
/// **Why this is not `NSMetadataQuery` any more (W26, owner directive 2026-08-04).** On 2026-08-04 the
/// owner pointed the Reader at 1,849 correctly-tagged PDFs and was told *"No Read/Unread-tagged PDFs
/// were found in this folder."* The Data volume's Spotlight index was dead — `mdfind` returned 0 for
/// that folder, for `$HOME`, for `/Applications` and for the real corpus — and this class had **no
/// Release filesystem fallback at all** (the working walk was `#if DEBUG`). Two failures: the index
/// went blind, and the app then blamed the files. The old "no per-file disk I/O (the fast path at
/// 150k)" justification was already void: `ContentIndexer` opens and extracts text from every PDF
/// anyway, and a measured full walk of the real corpus (123,028 files) takes 10.15 s single-threaded.
///
/// So discovery is now deterministic, and — the part that actually fixes the incident — it can say
/// **"I could not look"** separately from **"there is nothing here"**: see `phase` / `LibraryPhase`.
@MainActor
final class ArchiveLibrary: ObservableObject {
    @Published private(set) var files: [ArchiveFile] = []
    /// Replaced `isGathering: Bool` outright (plan §7a.4 / the walk2 item): one boolean could not both
    /// drive a list-blanking spinner and gate destructive content-index pruning once discovery
    /// revalidates behind rows that are already on screen.
    @Published private(set) var phase: LibraryPhase = .noRoot
    @Published private(set) var scopeDescription = "No folder selected"
    /// A clean walk can be authoritative even when this volume cannot supply live events. Keep that
    /// verdict separate from `phase`, but surface it beside scan failures so the Reader never goes
    /// quietly stale. The fallback is explicit rescan + stale window-activation revalidation.
    @Published private(set) var liveUpdateFailure: DiscoveryFailure?
    var discoveryFailure: DiscoveryFailure? { phase.failure ?? liveUpdateFailure }

    /// The root being walked, so `rescan()` needs no argument.
    private var root: URL?

    /// When discovery last completed a clean pass on a root that held still. Dates `.revalidating`
    /// and `.degraded`, so the UI can say what it knew and when instead of an undated wrong claim.
    private var lastSettled: Date?

    // MARK: - Live change scheduling

    typealias WatcherFactory = (URL, @escaping CorpusWatcher.Handler) -> any CorpusWatching
    private let watcherFactory: WatcherFactory
    private let indexedScanStarter: @MainActor (IndexedLibraryScanRequest) -> Void
    private let minimumRootRescanInterval: TimeInterval
    private let libraryIndex: LibraryIndex?
    private let watcherStartTimeout: TimeInterval
    private let scanStallTimeout: TimeInterval
    private var watcher: (any CorpusWatching)?

    /// The walk's own stall reporting (`W26.fsev-fu2`). `filesSeenInCurrentPass` is the discriminator:
    /// a walk that has examined even one file is demonstrably past the root probe, whatever else is
    /// slow about it. `stalledScan` names the pass a deadline has already spoken about, so the verdict
    /// is withdrawn exactly once and cannot be re-applied to its successor.
    private var scanStallDeadline: DispatchWorkItem?
    private var stalledScan: UInt64?
    private var filesSeenInCurrentPass = 0

    /// A stream start dispatched off the main thread that has not reported yet (`W26.fsev-fu1`).
    private struct PendingWatcherStart {
        let watcher: any CorpusWatching
        let rootGeneration: UInt64
        var deadline: DispatchWorkItem?
        /// A stream that comes up *after* discovery has already started owes one catch-up pass:
        /// `kFSEventStreamEventIdSinceNow` cannot replay an interval it was not watching.
        var owesCatchUpPass: Bool
    }
    private var pendingWatcherStart: PendingWatcherStart?
    /// True while the launch walk is waiting for that start. Gates `beginScan` and `drainWatchWork`,
    /// which is what preserves `W26.fsev`'s stream-before-walk ordering now that the start is async.
    private var watcherStartHoldsDiscovery = false
    /// The one pass held by that flag. At most one, because every path that could start a second one
    /// is gated on the same flag.
    private var passWaitingForWatcher: (@MainActor () -> Void)?
    private var rootResolver: (@MainActor () -> ResolvedLibraryRoot?)?
    private var rootGeneration: UInt64 = 0
    private var watchWorkInFlight = false
    private var watchCancellation: CorpusWatchCancellation?
    private var pendingWatchRequest = CorpusWatchRequest()
    private var queuedRootRescan = false
    private var queuedRootRescanIsUrgent = false
    private var lastRootScanStartedAt: Date?
    private var scheduledRootRescan: DispatchWorkItem?
    private var indexRoot: LibraryIndexRoot?
    private var cachedIndexEntries: [LibraryIndexPath: LibraryIndexEntry] = [:]
    private var indexPreparation: Task<Void, Never>?
    private var indexCommit: Task<Void, Never>?
#if DEBUG
    private(set) var rootScanStartsForTesting = 0
#endif

    /// `watcherStartTimeout` bounds how long the launch walk waits for the FSEvents stream to come up
    /// before going ahead without it (`W26.fsev-fu1`). Two seconds is generous for the `open(2)` this
    /// covers — microseconds on local disk, and the only cost of firing early is one catch-up pass.
    ///
    /// `scanStallTimeout` bounds how long a pass may examine **zero** files before the app says so
    /// (`W26.fsev-fu2`). Five seconds rather than the stream's two, because this one covers real work:
    /// a healthy walk emits its first 500-file batch in ~40 ms (measured 123,028 files in 10.15 s), so
    /// five seconds with nothing seen means the root probe itself has not returned. Firing early costs
    /// only a sentence that the next progress callback — or the finished pass — withdraws.
    init(minimumRootRescanInterval: TimeInterval = 1.0,
         libraryIndexURL: URL? = ArchiveLibrary.defaultLibraryIndexURL,
         watcherStartTimeout: TimeInterval = 2.0,
         scanStallTimeout: TimeInterval = 5.0,
         watcherFactory: @escaping WatcherFactory = { root, handler in
             CorpusWatcher(root: root, handler: handler)
         },
         indexedScanStarter: @escaping @MainActor (IndexedLibraryScanRequest) -> Void = { request in
             LibraryScan.revalidateOnDedicatedThread(
                root: request.root, cached: request.cached,
                isCancelled: request.isCancelled, onBatch: request.onBatch,
                completion: request.completion
             )
         }) {
        self.minimumRootRescanInterval = max(0, minimumRootRescanInterval)
        self.libraryIndex = libraryIndexURL.map { LibraryIndex(url: $0) }
        self.watcherStartTimeout = max(0, watcherStartTimeout)
        self.scanStallTimeout = max(0, scanStallTimeout)
        self.watcherFactory = watcherFactory
        self.indexedScanStarter = indexedScanStarter
    }

    static var defaultLibraryIndexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveReader", isDirectory: true)
            .appendingPathComponent("library-index-v1.sqlite3")
    }

    // MARK: - The write-vs-walk ordering guard (replaced ~80 lines of TTL/convergence overlay)
    //
    // The deleted `PendingWrite` machinery (`pending`, `settleTimer`, `overrideTTL`,
    // `overrideDecision`, `sameTags`/`sameLabel`, `armSettleTimer` — and its 8-case test file) existed
    // for exactly one reason: Spotlight kept re-emitting a file's OLD `kMDItemUserTags` after a
    // verified write, so a laggy reload clobbered the correct value. There is no index to lag now.
    //
    // But deleting it outright would have removed the only WRITE-VS-WALK ORDERING guard, and the
    // plan's original justification ("a re-walk reads the same disk through the same primitive, so it
    // converges") confused convergence with sequencing (plan §7a.2). The real hazard: the owner marks
    // 2,000 rows Read; a rescan starts around write #300 and reads files #300–#2000 *while their
    // writes are still pending*; its emission then lands after `applyVerifiedWrites` and publishes
    // pre-write values over verified ones.
    //
    // The replacement is a sequence number, not a timer: one monotonic counter stamps both scan starts
    // and verified writes, and a row whose write is NEWER than the pass's start keeps the verified
    // value. No TTL, no timer, no value comparison — an ordering guarantee instead of a race that
    // usually settles.
    private struct VerifiedWrite { let after: [String]; let afterLabel: Int?; let seq: UInt64 }
    private var verifiedWrites: [URL: VerifiedWrite] = [:]
    private var clock: UInt64 = 0
    /// Generation of the pass whose result may still be published. Bumped per pass, so a superseded
    /// pass's late completion is dropped rather than publishing stale rows over a newer root's
    /// (`ContentIndexer`'s generation-token discipline, same shape).
    private var currentScan: UInt64 = 0
    private var inFlight: ScanCancellation?

#if DEBUG
    /// Launch/defaults key that pins the app to a fixture root (XCUITest + unit tests).
    private static let fixtureRootKey = "ARUITestRootPath"
#endif

    // MARK: - Starting and re-running discovery

    /// Start (or restart) discovery within a scope. `nil` clears the library.
    ///
    /// Note what is gone with Spotlight: there is no whole-Mac scope any more. The old `nil`-scope
    /// branch set `NSMetadataQueryLocalComputerScope` and was documented "future use" — dead code that
    /// only a Spotlight index could have served, and walking the whole Mac is not something this app
    /// should ever do.
    func start(scope: URL?, markerGUID: UUID? = nil) {
        watchCancellation?.cancel()
        watchCancellation = nil
        indexPreparation?.cancel(); indexPreparation = nil
        indexCommit?.cancel(); indexCommit = nil
        stopWatcher()
        inFlight?.cancel()
        inFlight = nil
        cancelScanStallDeadline()
        scheduledRootRescan?.cancel()
        scheduledRootRescan = nil
        pendingWatchRequest = CorpusWatchRequest()
        queuedRootRescan = false
        queuedRootRescanIsUrgent = false
        watchWorkInFlight = false       // any old completion is rejected by `rootGeneration`
        rootGeneration &+= 1
        // Invalidate a completion from the preceding root immediately. An indexed start does async
        // cache preparation before its own `beginScan`; without this bump the old pass still matched
        // `currentScan` during that gap and could publish old-root rows into the new root.
        clock &+= 1
        currentScan = clock
        files = []
        verifiedWrites.removeAll()      // no override may leak across roots
        lastSettled = nil
        lastRootScanStartedAt = nil
        liveUpdateFailure = nil
        cachedIndexEntries = [:]
        indexRoot = scope.flatMap { url in
            markerGUID.map { LibraryIndexRoot(path: LibraryIndexPath(url).value, markerGUID: $0) }
        }
        root = scope
        guard let scope else {
            phase = .noRoot
            scopeDescription = "No folder selected"
            return
        }
        scopeDescription = scope.lastPathComponent
        phase = .firstScan(done: 0, seen: 0)
        // Off the main thread, and the walk below waits behind it rather than the main thread waiting
        // on its `open(2)` — see `startWatcher(root:holdingDiscovery:)`. The warm-start snapshot is
        // deliberately NOT held: it comes from the cache database, not from the watched volume.
        startWatcher(root: scope, holdingDiscovery: true)
        if usesPersistedIndex, let indexRoot, let libraryIndex {
            prepareInitialIndexedScan(root: scope, indexRoot: indexRoot, index: libraryIndex,
                                      rootGeneration: rootGeneration)
        } else {
            beginScan(root: scope)
        }
    }

    /// Whether this root may use the persisted warm-start cache at all.
    ///
    /// Fixture roots must answer NO on **every** path that starts a pass, not just the first one:
    /// they stay synchronous (`beginScan`'s fixture branch finishes before the caller returns, which
    /// is the contract the deep-link/UI fixture tests are calibrated against) and they never open the
    /// real Application Support database. Gating only `start(scope:)` left ⌘⌥R — `rescan()` →
    /// `requestRootRescan` → `drainWatchWork` — going through the async indexed path, which both
    /// broke that synchrony and let a unit test write the owner's live cache.
    private var usesPersistedIndex: Bool {
#if DEBUG
        if isFixtureRoot { return false }
#endif
        return indexRoot != nil && libraryIndex != nil
    }

#if DEBUG
    /// Whether this process is pinned to a fixture root. One spelling, so the several behaviours that
    /// key off it (no persisted index, a synchronous walk, an inline watcher start) cannot drift apart.
    private var isFixtureRoot: Bool {
        UserDefaults.standard.string(forKey: Self.fixtureRootKey) != nil
    }
#endif

    /// RootChanged/Mount/Unmount must go back through the bookmark owner rather than assuming the old
    /// path still names the granted directory. `NavigationModel` installs this before starting a root.
    func setRootResolver(_ resolver: @escaping @MainActor () -> ResolvedLibraryRoot?) {
        rootResolver = resolver
    }

    /// Re-walk the current root, keeping the rows already on screen (File ▸ Rescan Archive Folder, ⌘⌥R).
    ///
    /// `CorpusWatcher` normally applies external changes live. This explicit path remains the immediate
    /// recovery control for a journal-less volume and the operator's way to demand a full proof now.
    func rescan() {
        guard let root else { return }
        retryWatcherIfNeeded(root: root)
        requestRootRescan(urgent: true)
    }

    /// The journal-unavailable fallback. There is intentionally no periodic timer competing with the
    /// content indexer: activation retries the stream, and re-walks only when the last clean settle is
    /// older than five minutes. Explicit ⌘⌥R remains available at any age.
    func revalidateOnActivation(now: Date = Date(), staleAfter: TimeInterval = 5 * 60) {
        guard let root, watcher == nil else { return }   // a live stream needs no polling at all
        // The retry cannot report synchronously any more — its `FSEventStreamCreate` opens the root off
        // the main thread (`W26.fsev-fu1`) — so the catch-up walk for a stream that DOES come back is
        // requested by the start's own completion (`owesCatchUpPass`) rather than from here. What is
        // left here is the volume that stays journal-less: re-walk only once the snapshot is stale.
        retryWatcherIfNeeded(root: root)
        guard let lastSettled, now.timeIntervalSince(lastSettled) >= staleAfter else { return }
        requestRootRescan(urgent: true)
    }

    private func prepareInitialIndexedScan(root: URL, indexRoot: LibraryIndexRoot,
                                           index: LibraryIndex, rootGeneration: UInt64) {
        indexPreparation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let snapshot: LibraryIndexSnapshot
            do {
                snapshot = try await index.snapshot(for: indexRoot)
            } catch is CancellationError {
                return
            } catch {
                NSLog("LibraryIndex: warm start unavailable: \(error)")
                guard let self, !Task.isCancelled, rootGeneration == self.rootGeneration else { return }
                self.indexPreparation = nil
                self.beginScan(root: root)
                return
            }
            guard let self, !Task.isCancelled, rootGeneration == self.rootGeneration else { return }
            self.cachedIndexEntries = snapshot.entries
            self.publishWarmSnapshot(snapshot)

            do {
                let scan = try await index.beginScan(root: indexRoot)
                guard !Task.isCancelled, rootGeneration == self.rootGeneration else { return }
                self.indexPreparation = nil
                self.beginScan(root: root, cached: snapshot.entries, indexScan: scan)
            } catch is CancellationError {
                return
            } catch {
                NSLog("LibraryIndex: scan provenance unavailable: \(error)")
                guard !Task.isCancelled, rootGeneration == self.rootGeneration else { return }
                self.indexPreparation = nil
                // Revalidate against the loaded map even when persistence is unavailable; stat/ctime
                // still proves which raw-tag rows are reusable, and disk remains the sole truth.
                self.beginScan(root: root, cached: snapshot.entries)
            }
        }
    }

    private func prepareSubsequentIndexedScan(root: URL) {
        guard indexPreparation == nil, let indexRoot, let index = libraryIndex else {
            if indexRoot == nil || libraryIndex == nil { beginScan(root: root) }
            return
        }
        let rootGeneration = self.rootGeneration
        let cached = cachedIndexEntries
        indexPreparation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let scan = try await index.beginScan(root: indexRoot)
                guard let self, !Task.isCancelled, rootGeneration == self.rootGeneration else { return }
                self.indexPreparation = nil
                self.beginScan(root: root, cached: cached, indexScan: scan)
            } catch is CancellationError {
                return
            } catch {
                NSLog("LibraryIndex: could not start persisted revalidation: \(error)")
                guard let self, !Task.isCancelled, rootGeneration == self.rootGeneration else { return }
                self.indexPreparation = nil
                self.beginScan(root: root, cached: cached)
            }
        }
    }

    private func publishWarmSnapshot(_ snapshot: LibraryIndexSnapshot) {
        guard let root else { return }
        let rootPath = LibraryIndexPath(root)
        let warm = snapshot.entries.values
            .filter { LibraryIndexPath($0.path).isContained(in: rootPath) }
            .filter(\.tracked)
            .map { Self.row($0, provenance: .cache(asOf: snapshot.asOf)) }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        guard !warm.isEmpty || snapshot.asOf != nil else { return } // truly cold root
        files = warm
        lastSettled = snapshot.asOf
        phase = .revalidating(asOf: snapshot.asOf)
    }

    private func beginScan(root: URL, cached: [LibraryIndexPath: LibraryIndexEntry] = [:],
                           indexScan: LibraryIndexScan? = nil) {
        // `W26.fsev` requires the stream to be watching before the walk reads anything, or a change in
        // between is lost for good. Since `W26.fsev-fu1` the stream comes up off the main thread, so
        // the *walk* waits here — one deferred call — instead of the main thread waiting on `open(2)`.
        // `drainWatchWork` is gated on the same flag, so at most this one pass can ever be waiting.
        if watcherStartHoldsDiscovery {
            passWaitingForWatcher = { [weak self] in
                self?.beginScan(root: root, cached: cached, indexScan: indexScan)
            }
            return
        }
#if DEBUG
        rootScanStartsForTesting += 1
#endif
        clock += 1
        let generation = clock
        let rootGeneration = self.rootGeneration
        currentScan = generation
        let token = ScanCancellation()
        inFlight = token
        lastRootScanStartedAt = Date()

#if DEBUG
        // A fixture root scans SYNCHRONOUSLY — same walker, same predicate, same failure accounting;
        // only the delivery thread differs. That distinction is the whole point: pre-W26 this key
        // selected a different discovery *mechanism* (the `#if DEBUG` fixture loader), which is how a
        // Release build shipped with no filesystem discovery at all. Two shipped tests
        // (`DocumentPageLinkTests`, `RootMarkerStateTests`) assert on `files` the moment
        // `NavigationModel()` returns, and the XCUITest fixture lane's `waitForRows` timings were
        // calibrated against a synchronous load.
        if UserDefaults.standard.string(forKey: Self.fixtureRootKey) != nil {
            finish(LibraryScan.pass(root: root, isCancelled: { token.isCancelled }),
                   generation: generation, rootGeneration: rootGeneration, indexScan: nil)
            return
        }
#endif
        // Everything below here hands the walk to another thread and cannot be waited on. Arm the
        // stall deadline first, and only here: the fixture branch above has already finished, and the
        // `watcherStartHoldsDiscovery` branch at the top of this function has not started anything
        // yet (the stream's own deadline covers that interval).
        armScanStallDeadline(generation: generation)
        // Progress only — NOT rows. See `finish`: rows are published once per pass, atomically.
        let onBatch: @Sendable (CorpusScanBatch) -> Void = { batch in
            let found = batch.entries.filter { CorpusWalker.tracksReadState($0.tagNames) }.count
            let seen = batch.filesSeen
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.reportProgress(generation: generation,
                                                                found: found, seen: seen) }
            }
        }
        let completion: @Sendable (DiscoveryPass) -> Void = { [weak self] pass in
            MainActor.assumeIsolated {
                self?.finish(pass, generation: generation, rootGeneration: rootGeneration,
                             indexScan: indexScan)
            }
        }
        if indexScan != nil || !cached.isEmpty {
            indexedScanStarter(IndexedLibraryScanRequest(
                root: root, cached: cached, isCancelled: { token.isCancelled },
                onBatch: onBatch, completion: completion
            ))
        } else {
            LibraryScan.onDedicatedThread(root: root,
                                          isCancelled: { token.isCancelled },
                                          onBatch: onBatch, completion: completion)
        }
    }

    /// Real progress — a count Spotlight could never give. Only meaningful during a first scan; a
    /// revalidation deliberately leaves the on-screen rows and their counts alone.
    private func reportProgress(generation: UInt64, found: Int, seen: Int) {
        guard generation == currentScan else { return }
        // Tracked for EVERY pass, not just a first scan, because this is what `scanDidStall` reads:
        // a revalidation records no visible progress, but it is just as capable of hanging on the
        // root probe, and "still scanning" is just as false about it.
        filesSeenInCurrentPass = max(filesSeenInCurrentPass, seen)
        if stalledScan == generation, seen > 0 {
            // It answered after all. Withdraw the stall BEFORE adding to the counts: a walk that is
            // producing files must not keep a phase `LibraryEmptyState` reads as "could not look".
            stalledScan = nil
            phase = files.isEmpty ? .firstScan(done: 0, seen: 0) : .revalidating(asOf: lastSettled)
        }
        guard case let .firstScan(done, _) = phase else { return }
        phase = .firstScan(done: done + found, seen: seen)
    }

    /// Report — never cancel — a walk that has not answered (`W26.fsev-fu2`).
    ///
    /// `W26.fsev-fu1` bounded the FSEvents stream's `open(2)`, so an unopenable root draws a window
    /// and the status bar says live updates are not responding. `CorpusWalker`'s own `opendir(3)`
    /// probe blocks on the *same* root with no bound at all, so the list's state stayed
    /// `.firstScan(done: 0, seen: 0)` — an honest status bar above a spinner that lies for ever.
    ///
    /// This is a *reported* deadline, not a cancellation, and the distinction is forced rather than
    /// chosen: a thread blocked in `opendir`/`readdir` cannot be interrupted, and `ScanCancellation`
    /// is only consulted between directory entries, which a stalled probe never reaches. The pass
    /// keeps running and supersedes this verdict if it ever comes back — through the same generation
    /// token every other late completion already goes through.
    private func armScanStallDeadline(generation: UInt64) {
        cancelScanStallDeadline()
        guard scanStallTimeout > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scanDidStall(generation: generation) }
        }
        scanStallDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scanStallTimeout, execute: work)
    }

    private func cancelScanStallDeadline() {
        scanStallDeadline?.cancel()
        scanStallDeadline = nil
        stalledScan = nil
        filesSeenInCurrentPass = 0
    }

    /// The pass has run for `scanStallTimeout` without examining a single file, so it never got past
    /// the root. Say so as a **degraded** phase: `.firstScan` blanks the list behind a spinner and
    /// `LibraryEmptyState` reads it as `.scanning`, which is the shape of claim this wave exists to
    /// stop the app from making about a folder it has not read.
    ///
    /// ⚠️ Deliberately NOT routed through `DiscoveryHealth`. That type judges a *finished* pass, and
    /// callers of `isSettled` — content-index pruning above all — are entitled to assume a phase it
    /// produced describes one. `.degraded` is not settled, so this grants no pruning and makes no
    /// absence authoritative; it only replaces one sentence with a truer one.
    private func scanDidStall(generation: UInt64) {
        scanStallDeadline = nil
        guard generation == currentScan, inFlight != nil, filesSeenInCurrentPass == 0 else { return }
        stalledScan = generation
        phase = .degraded(.scanStalled, asOf: lastSettled)
    }

    /// Publish a finished pass: rows first, then the verdict about how much of it to trust.
    ///
    /// **Rows are published once, atomically, at the end of the pass** — batches drive the progress
    /// counter only. Two reasons, both load-bearing: (1) `pruneIfSettled` computes
    /// `indexedUnderRoot.subtracting(currentPaths)`, so a PARTIAL row list makes everything not yet
    /// walked look deleted (plan §7a.11's sharpening) — publishing progressively is exactly what would
    /// endanger it; (2) `NavigationModel.libraryDidChange` rebuilds the folder tree, subject cache and
    /// smart-folder counts per emission, so 200 partial emissions at corpus scale would be quadratic
    /// work for a list the user cannot use yet anyway.
    private func finish(_ pass: DiscoveryPass, generation: UInt64, rootGeneration: UInt64,
                        indexScan: LibraryIndexScan?) {
        guard rootGeneration == self.rootGeneration, generation == currentScan else { return }
        // The walk is over, whatever it found — including a pass already reported stalled, which is
        // exactly the "let a late-arriving pass supersede it" half of the item.
        cancelScanStallDeadline()
        let next = DiscoveryHealth.phase(after: pass.result, root: pass.rootStability,
                                         finishedAt: Date(), lastSettled: lastSettled)

        guard let indexScan, let index = libraryIndex else {
            let nextFiles = merged(pass: pass, generation: generation,
                                   absenceIsAuthoritative: next.isSettled)
            publishFinishedPass(nextFiles, next: next, generation: generation)
            return
        }

        let result = pass.result
        let verdict = LibraryIndexScanVerdict(
            finishedAt: Date(),
            filesSeen: result.filesSeen,
            directoryErrors: result.directoryErrors.count,
            outcome: result.rootUnreadable ? "failed" : (next.isSettled ? "complete" : "partial"),
            absenceIsAuthoritative: next.isSettled
        )
        let persistedRoot = indexRoot
        indexCommit = Task { [weak self] in
            guard !Task.isCancelled else { return }
            var refreshed: LibraryIndexSnapshot?
            do {
                try await index.completeScan(indexScan, entries: result.entries, verdict: verdict)
                if let persistedRoot, !Task.isCancelled {
                    refreshed = try await index.snapshot(for: persistedRoot)
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("LibraryIndex: scan persistence failed: \(error)")
            }
            guard let self, !Task.isCancelled,
                  rootGeneration == self.rootGeneration, generation == self.currentScan else { return }
            self.indexCommit = nil
            if let refreshed { self.cachedIndexEntries = refreshed.entries }
            // Merge only when the durable commit is ready to publish. A verified TagWriter result may
            // have landed while SQLite was working; `merged` observes its newer sequence and keeps it.
            let nextFiles = self.merged(pass: pass, generation: generation,
                                        absenceIsAuthoritative: next.isSettled)
            self.publishFinishedPass(nextFiles, next: next, generation: generation)
        }
    }

    private func publishFinishedPass(_ nextFiles: [ArchiveFile], next: LibraryPhase,
                                     generation: UInt64) {
        guard generation == currentScan else { return }
        inFlight = nil
        files = nextFiles
        if case let .settled(asOf, _) = next { lastSettled = asOf }
        // A coalesced recovery request received during this pass means discovery is still in
        // progress. Never publish an authoritative `.settled` window while the queued pass waits for
        // its minimum interval or runs; content-index pruning keys directly off this state.
        if queuedRootRescan {
            phase = files.isEmpty ? .firstScan(done: 0, seen: 0) : .revalidating(asOf: lastSettled)
        } else {
            phase = next
        }
        drainWatchWork()
    }

    // MARK: - FSEvents delivery and bounded revalidation

    /// Bring up this root's FSEvents stream — **without opening the root on the main thread.**
    ///
    /// `FSEventStreamCreate` `open(2)`s every watched path. On local disk that is microseconds, which is
    /// how it survived a whole wave sitting on the main actor inside `NavigationModel.init()`; under an
    /// unanswerable TCC prompt, a stalled network/cloud mount or a disconnected volume the `open` never
    /// returns and **the app never draws a window** (`W26.fsev-fu1`, from a stack sample of a 9-minute
    /// 0%-CPU hang, not from a reading).
    ///
    /// `holdingDiscovery` is what keeps `W26.fsev`'s ordering guarantee — the stream must be watching
    /// before the launch walk reads anything. The walk is *deferred* (`passWaitingForWatcher`) rather
    /// than *waited on*, so the ordering survives while the main thread does not block.
    /// `watcherStartTimeout` bounds that deferral: a root that will not open must degrade to "no live
    /// updates, list what you can" rather than to "no window at all".
    ///
    /// A dedicated `Thread`, not a shared queue: a start stuck in `open(2)` must not occupy a pool slot
    /// that the NEXT root's start would then queue behind. Such a start is unkillable — FSEvents offers
    /// no cancel — so its thread, and the security scope it took, leak for the life of the process.
    /// That is the price of the stall itself, not of this deferral.
    private func startWatcher(root: URL, holdingDiscovery: Bool) {
        // One start at a time: a second `FSEventStreamCreate` on a root whose first one is stuck would
        // block identically and leak a second thread. ⚠️ Returning here would ALSO drop
        // `holdingDiscovery`, so a `holdingDiscovery: true` caller must never reach it — and cannot:
        // `start(scope:)` calls `stopWatcher()` first, which clears `pendingWatcherStart`. Only
        // `retryWatcherIfNeeded` can land here, and it passes `false`.
        guard pendingWatcherStart == nil else { return }
#if DEBUG
        if isFixtureRoot {
            startWatcherInline(root: root)
            return
        }
#endif
        let generation = rootGeneration
        let made = makeWatcher(root: root, generation: generation)
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.watcherStartDidStall(generation: generation) }
        }
        pendingWatcherStart = PendingWatcherStart(watcher: made, rootGeneration: generation,
                                                  deadline: deadline,
                                                  owesCatchUpPass: !holdingDiscovery)
        watcherStartHoldsDiscovery = holdingDiscovery
        DispatchQueue.main.asyncAfter(deadline: .now() + watcherStartTimeout, execute: deadline)

        let thread = Thread { [weak self] in
            let result = made.start()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        made.stop()          // the library is gone; do not leave a stream running
                        return
                    }
                    self.watcherDidStart(made, result: result)
                }
            }
        }
        thread.name = "ArchiveReader.CorpusWatcherStart"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

#if DEBUG
    /// The fixture lane keeps the pre-`W26.fsev-fu1` inline start, deliberately.
    ///
    /// `beginScan`'s fixture branch is synchronous because two shipped tests read `files` the moment
    /// `NavigationModel()` returns and the XCUITest lane's `waitForRows` timings were calibrated against
    /// that; deferring the walk behind an off-thread start would break both, and the catch-up pass a
    /// late stream owes would perturb every fixture test that counts passes. The hazard cannot arise
    /// here: a fixture root is a scratch directory the test itself just created on local disk, so its
    /// `open(2)` cannot block on a permission prompt, a stalled mount or a missing volume.
    private func startWatcherInline(root: URL) {
        let made = makeWatcher(root: root, generation: rootGeneration)
        install(made, result: made.start(), owesCatchUpPass: false)
    }
#endif

    private func makeWatcher(root: URL, generation: UInt64) -> any CorpusWatching {
        watcherFactory(root) { [weak self] request in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.receiveWatchRequest(request, rootGeneration: generation)
                }
            }
        }
    }

    private func watcherDidStart(_ made: any CorpusWatching, result: CorpusWatcherStartResult) {
        // Identity, not merely generation: every abandonment path clears `pendingWatcherStart`, so a
        // stream nobody is waiting for any more gets stopped instead of installed — including one whose
        // `open` finally returned long after its root was replaced.
        guard let pending = pendingWatcherStart, pending.watcher === made,
              pending.rootGeneration == rootGeneration, root != nil else {
            made.stop()
            return
        }
        pending.deadline?.cancel()
        pendingWatcherStart = nil
        install(made, result: result, owesCatchUpPass: pending.owesCatchUpPass)
        releaseDiscoveryHold()
    }

    private func install(_ made: any CorpusWatching, result: CorpusWatcherStartResult,
                         owesCatchUpPass: Bool) {
        switch result {
        case .started:
            watcher = made
            liveUpdateFailure = nil
            // A SinceNow stream cannot replay what it was not watching, so a stream that arrived after
            // discovery had already begun pays for the gap with exactly one catch-up pass.
            if owesCatchUpPass { requestRootRescan(urgent: true) }
        case .journalUnavailable:
            made.stop()
            watcher = nil
            liveUpdateFailure = .liveUpdatesUnavailable
        }
    }

    /// The stream's `open(2)` outran its deadline. Say so and stop holding the app hostage to it: a
    /// list of what can be read, plus an honest "not responding", beats a window that never appears.
    ///
    /// The start is **not** abandoned — if it ever returns, `install` still adopts the stream and pays
    /// for the interval it missed. That is why `owesCatchUpPass` is set here rather than at the start.
    private func watcherStartDidStall(generation: UInt64) {
        guard var pending = pendingWatcherStart, pending.rootGeneration == generation,
              generation == rootGeneration else { return }
        pending.deadline = nil
        pending.owesCatchUpPass = true
        pendingWatcherStart = pending
        liveUpdateFailure = .liveUpdatesStalled
        releaseDiscoveryHold()
    }

    /// Let the pass that was waiting for the stream run. Idempotent.
    private func releaseDiscoveryHold() {
        watcherStartHoldsDiscovery = false
        let held = passWaitingForWatcher
        passWaitingForWatcher = nil
        held?()
        drainWatchWork()
    }

    /// Bring the stream back after a journal failure or a stalled start (⌘⌥R, window activation).
    ///
    /// Asynchronous since `W26.fsev-fu1`, so it reports no outcome and the caller must not condition
    /// anything on one: a start that succeeds requests its own catch-up pass. It also never holds
    /// discovery — the operator asked for a walk *now*, and a stalled stream must not delay it.
    private func retryWatcherIfNeeded(root: URL) {
        guard watcher == nil, pendingWatcherStart == nil else { return }
        startWatcher(root: root, holdingDiscovery: false)
    }

    private func stopWatcher() {
        pendingWatcherStart?.deadline?.cancel()
        // Dropping the reference is what abandons an in-flight start: `watcherDidStart` checks identity,
        // so one still stuck in `open(2)` stops itself if it ever returns.
        pendingWatcherStart = nil
        watcherStartHoldsDiscovery = false
        passWaitingForWatcher = nil
        watcher?.stop()
        watcher = nil
    }

    private func receiveWatchRequest(_ request: CorpusWatchRequest, rootGeneration: UInt64) {
        guard root != nil, rootGeneration == self.rootGeneration else { return }
        if request.reResolveRoot {
            stopWatcher()
            inFlight?.cancel()
            let resolved = rootResolver?()
            if rootResolver != nil {
                start(scope: resolved?.url, markerGUID: resolved?.markerGUID)
            }
            else { requestRootRescan(urgent: true) }   // standalone/test library: safest fallback
            return
        }
        if request.fullRescan {
            pendingWatchRequest = CorpusWatchRequest()
            requestRootRescan(urgent: false)
            return
        }
        pendingWatchRequest.merge(request)
        drainWatchWork()
    }

    /// At most one full re-walk is active and at most one is queued. Further callbacks merely keep
    /// that one bit set. A short minimum interval prevents a fast/small root from spinning if a writer
    /// produces a sustained stream; this delayed work item is event-triggered, not a periodic timer.
    private func requestRootRescan(urgent: Bool) {
        guard root != nil else { return }
        queuedRootRescan = true
        queuedRootRescanIsUrgent = queuedRootRescanIsUrgent || urgent
        pendingWatchRequest = CorpusWatchRequest()
        // A pass reported stalled keeps its degraded phase (`W26.fsev-fu2`). `drainWatchWork` cannot
        // start the queued rescan while that walk is still in flight, so an optimistic "Scanning…"
        // here would put back the very spinner the deadline exists to remove — and ⌘⌥R, the control
        // whose tooltip says it will NOT force a stalled read to return, is the likeliest caller.
        if !phase.isScanning, stalledScan == nil {
            phase = files.isEmpty ? .firstScan(done: 0, seen: 0) : .revalidating(asOf: lastSettled)
        }
        drainWatchWork()
    }

    private func drainWatchWork() {
        guard inFlight == nil, !watchWorkInFlight, indexPreparation == nil,
              !watcherStartHoldsDiscovery, let root else { return }

        if queuedRootRescan {
            let urgent = queuedRootRescanIsUrgent
            let elapsed = lastRootScanStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let delay = urgent ? 0 : max(0, minimumRootRescanInterval - elapsed)
            if delay > 0 {
                guard scheduledRootRescan == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.scheduledRootRescan = nil
                        self?.drainWatchWork()
                    }
                }
                scheduledRootRescan = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return
            }
            scheduledRootRescan?.cancel()
            scheduledRootRescan = nil
            queuedRootRescan = false
            queuedRootRescanIsUrgent = false
            pendingWatchRequest = CorpusWatchRequest() // the new pass covers every callback received so far
            if usesPersistedIndex { prepareSubsequentIndexedScan(root: root) }
            else { beginScan(root: root) }
            return
        }

        guard !pendingWatchRequest.isEmpty else { return }
        let request = pendingWatchRequest
        pendingWatchRequest = CorpusWatchRequest()
        watchWorkInFlight = true
        let rootGeneration = self.rootGeneration
        clock += 1
        let readGeneration = clock
        let cancellation = CorpusWatchCancellation()
        watchCancellation = cancellation
        CorpusWatchWork.onDedicatedThread(root: root, request: request,
                                          cancellation: cancellation) { [weak self] changes in
            MainActor.assumeIsolated {
                self?.finishWatchWork(changes, rootGeneration: rootGeneration,
                                      readGeneration: readGeneration)
            }
        }
    }

    private func finishWatchWork(_ changes: CorpusWatchChangeSet,
                                 rootGeneration: UInt64,
                                 readGeneration: UInt64) {
        guard rootGeneration == self.rootGeneration else { return }
        watchWorkInFlight = false
        watchCancellation = nil
        apply(changes, readGeneration: readGeneration)
        drainWatchWork()
    }

    /// Merge a path/subtree batch once. A clean subtree may authoritatively replace only that prefix;
    /// an unreadable subtree keeps every unseen prior row, the same conservative rule as a full pass.
    private func apply(_ changes: CorpusWatchChangeSet, readGeneration: UInt64) {
        var rows = Dictionary(uniqueKeysWithValues: files.map { (LibraryIndexPath($0.url), $0) })
        let priorRows = rows
        var failures: [CorpusReadFailure] = []
        var folderFailures = 0

        for change in changes.paths {
            let path = LibraryIndexPath(change.url)
            // Every non-directory inspection positively proves that the old subtree no longer
            // exists. Clear the whole prefix first; then a tracked replacement may add the exact
            // path back. This covers directory -> regular-file replacement without trusting rename
            // or removal flags.
            switch change.inspection {
            case .tracked, .untracked, .directorySymbolicLink, .nonRegular, .vanished:
                rows = rows.filter { !CorpusWatchRequest.contains($0.key.value, under: path.value) }
            case .directory, .unreadable:
                break
            }

            if let write = verifiedWrites[change.url], write.seq > readGeneration {
                // The user's verified edit happened after this read began. It has the same precedence
                // as in `merged(pass:)`; an older external revalidation cannot undo its tags. When
                // this read did produce a tracked entry, retain its fresh content mtime/type so a
                // concurrent external content edit still invalidates the content index.
                if CorpusWalker.tracksReadState(write.after) {
                    if case let .tracked(entry) = change.inspection {
                        rows[path] = Self.row(entry, tagNames: write.after,
                                              labelNumber: write.afterLabel)
                    } else if let base = priorRows[path] {
                        rows[path] = Self.rebuilt(base, after: write.after,
                                                 afterLabel: write.afterLabel)
                    }
                }
                continue
            }

            switch change.inspection {
            case let .tracked(entry):
                rows[path] = Self.row(entry, tagNames: entry.tagNames, labelNumber: entry.labelNumber)
            case .untracked:
                break
            case .directorySymbolicLink, .nonRegular, .vanished:
                break
            case let .unreadable(failure):
                failures.append(failure)       // keep the last-known row; absence is not proven
            case .directory:
                folderFailures += 1            // work converts this to a subtree; defensive only
            }
        }

        for change in changes.subtrees {
            let outcome = DiscoveryHealth.failure(for: change.pass.result, root: change.pass.rootStability)
            if outcome == nil {
                let subtreePath = LibraryIndexPath(change.url).value
                rows = rows.filter { !CorpusWatchRequest.contains($0.key.value, under: subtreePath) }
            } else {
                failures.append(contentsOf: change.pass.result.unreadable)
                folderFailures += change.pass.result.directoryErrors.count
                if change.pass.result.rootUnreadable || change.pass.rootStability != .heldStill {
                    folderFailures += 1
                }
            }
            for entry in change.pass.result.entries {
                let path = LibraryIndexPath(entry.url)
                if let write = verifiedWrites[entry.url], write.seq > readGeneration {
                    if CorpusWalker.tracksReadState(write.after) {
                        rows[path] = Self.row(entry, tagNames: write.after,
                                             labelNumber: write.afterLabel)
                    } else {
                        rows.removeValue(forKey: path)
                    }
                } else {
                    rows[path] = Self.row(entry, tagNames: entry.tagNames,
                                          labelNumber: entry.labelNumber)
                }
            }

            // A clean subtree replacement removed its prior rows before installing the pass. A file
            // read as untracked before a newer verified edit will therefore be absent from `entries`;
            // reinsert that last-known row with the verified value rather than losing the user edit.
            for (url, write) in verifiedWrites
                where write.seq > readGeneration
                    && CorpusWatchRequest.contains(url.path, under: change.url.path) {
                let path = LibraryIndexPath(url)
                if CorpusWalker.tracksReadState(write.after), let base = priorRows[path] {
                    rows[path] = Self.rebuilt(base, after: write.after,
                                              afterLabel: write.afterLabel)
                } else {
                    rows.removeValue(forKey: path)
                }
            }
        }

        let nextFiles = rows.values.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        if nextFiles != files { files = nextFiles }

        if !failures.isEmpty || folderFailures > 0 {
            let synthetic = CorpusScanResult(entries: [], unreadable: failures,
                                             directoryErrors: (0..<folderFailures).map {
                                                 CorpusReadFailure(url: root ?? URL(fileURLWithPath: "/"),
                                                                   reason: "live subtree could not be read (\($0))")
                                             },
                                             filesSeen: 0, vanishedMidScan: 0,
                                             rootUnreadable: false, cancelled: false)
            if let failure = DiscoveryHealth.failure(for: synthetic, root: .heldStill) {
                phase = .degraded(failure, asOf: lastSettled)
            }
        } else if nextFiles.isEmpty, !changes.paths.isEmpty || !changes.subtrees.isEmpty {
            // A path-local read cannot maintain the full walk's exact `filesSeen` denominator. If a
            // live edit empties the tracked library, establish it before the empty-state UI says
            // "folder empty" or "none of N are tagged" (e.g. launch scanned 0, then an untracked file
            // was created). This rare boundary is one coalesced root pass, never per-event polling.
            requestRootRescan(urgent: false)
        }

        // Live reads are serialized with full walks and with one another. Once a live read stamped
        // after a verified write has merged, no older operation remains that could overwrite that
        // write, so its ordering guard can be retired. Without this, a healthy watcher plus no manual
        // rescans would retain one entry for every Reader edit for the process's entire lifetime.
        verifiedWrites = verifiedWrites.filter { $0.value.seq > readGeneration }
    }

    @discardableResult
    func flushWatcherForTesting() -> Bool { watcher?.flushSync() ?? false }

    func receiveWatchRequestForTesting(_ request: CorpusWatchRequest) {
        receiveWatchRequest(request, rootGeneration: rootGeneration)
    }

#if DEBUG
    /// Deterministic race seam: capture a watch-read timestamp, interleave a verified write, then
    /// deliver the already-read result without racing real threads in a unit test.
    func beginWatchReadForTesting() -> UInt64 { clock += 1; return clock }

    func finishWatchReadForTesting(_ changes: CorpusWatchChangeSet, readGeneration: UInt64) {
        apply(changes, readGeneration: readGeneration)
    }

    var verifiedWriteCountForTesting: Int { verifiedWrites.count }

    /// Lets a NavigationModel write-safety test model rows already published from a warm cache.
    func replaceFilesForTesting(_ replacement: [ArchiveFile]) { files = replacement }

    func closeLibraryIndexForTesting() async { await libraryIndex?.close() }
#endif

    /// Build the row list from a completed pass. Two rules, and both are the point of this wave.
    ///
    /// 1. **A pass whose absences are not authoritative keeps every unseen existing row** (plan
    ///    §5.13 tier 1 / §7a.3). That includes a directly-unreadable file, every descendant of a
    ///    directory the enumerator could not enter, and a clean-looking short walk whose root changed
    ///    underneath it. "I could not reach it" must not render as "it is gone". A third-party tag
    ///    removal may therefore remain visible until the next clean pass — the deliberately conservative
    ///    answer when the same pass cannot prove absence.
    /// 2. **A verified write newer than this pass's start wins** (the §7a.2 ordering guard above).
    private func merged(pass: DiscoveryPass, generation: UInt64,
                        absenceIsAuthoritative: Bool) -> [ArchiveFile] {
        let result = pass.result
        var out: [ArchiveFile] = []
        out.reserveCapacity(result.entries.count)
        var placed = Set<LibraryIndexPath>()

        for entry in result.entries {
            placed.insert(LibraryIndexPath(entry.url))
            if let write = verifiedWrites[entry.url], write.seq > generation {
                // The walk read this file BEFORE the write landed; the write's verified re-read wins.
                guard CorpusWalker.tracksReadState(write.after) else { continue }
                out.append(Self.row(entry, tagNames: write.after, labelNumber: write.afterLabel))
            } else {
                guard CorpusWalker.tracksReadState(entry.tagNames) else { continue }
                out.append(Self.row(entry, tagNames: entry.tagNames, labelNumber: entry.labelNumber))
            }
        }

        if !absenceIsAuthoritative {
            for row in files where !placed.contains(LibraryIndexPath(row.url)) {
                out.append(row)
            }
        }

        // GC: an override this pass has now overtaken is finished. Anything newer than the pass stays,
        // so a *second* stale pass cannot resurrect a pre-write value either.
        verifiedWrites = verifiedWrites.filter { $0.value.seq > generation }
        return out
    }

    // MARK: - Verified writes

    /// Reflect a batch of *verified* `TagWriter` results in the model immediately, so rows leave a
    /// filtered view at once, and stamp them so a walk that started earlier cannot undo them.
    ///
    /// Pass only verified (non-throwing) results — a failed write must not move its row (Safety §11).
    /// The displayed value is `TagWriter`'s re-read `.after`/`.afterLabel` (ground truth), never a
    /// reconstruction from the model's own possibly-stale tags. Display-only: no disk write, no read.
    ///
    /// All five call sites (`mark`, group edit, inline edit, corpus-wide rename, undo) already hand in
    /// exactly that verified value, so this is now a **direct row replacement** rather than an overlay
    /// consulted on every subsequent emission.
    ///
    /// One deliberate behaviour change: a write that leaves the file with **no** Read/Unread tag drops
    /// the row from the library, because the membership predicate no longer holds. Spotlight used to do
    /// this a beat later, on its next update; doing it here is the same end state, immediately, and
    /// without a live query it is the only thing that would.
    func applyVerifiedWrites(_ results: [TagWriteResult]) {
        guard !results.isEmpty else { return }
        var replacements: [URL: VerifiedWrite] = [:]
        for r in results {
            clock += 1
            let write = VerifiedWrite(after: r.after, afterLabel: r.afterLabel, seq: clock)
            verifiedWrites[r.url] = write
            replacements[r.url] = write
        }
        files = files.compactMap { f in
            guard let write = replacements[f.url] else { return f }
            guard CorpusWalker.tracksReadState(write.after) else { return nil }
            return Self.rebuilt(f, after: write.after, afterLabel: write.afterLabel)
        }
    }

    // MARK: - Row construction

    static func row(_ entry: CorpusEntry, tagNames: [String], labelNumber: Int?) -> ArchiveFile {
        ArchiveFile(url: entry.url,
                    name: entry.url.lastPathComponent,
                    fileType: shortType(uti: entry.contentTypeIdentifier, url: entry.url),
                    tags: DocumentTags.parse(raw: tagNames, labelNumber: labelNumber),
                    // `.contentModificationDateKey`, deliberately: a Finder-tag write changes ctime,
                    // not mtime, so this is the right key for the content-index freshness check and
                    // the wrong one for detecting a tag change (plan §5.12).
                    contentModified: entry.contentModified,
                    isDataless: entry.isDataless,
                    provenance: .disk(readAt: Date()))
    }

    private static func row(_ entry: LibraryIndexEntry,
                            provenance: ArchiveFileProvenance) -> ArchiveFile {
        let url = LibraryIndexPath(entry.path).fileURL
        return ArchiveFile(url: url,
                           name: entry.name,
                           fileType: shortType(uti: nil, url: url),
                           tags: DocumentTags.parse(raw: entry.tagNames,
                                                    labelNumber: entry.labelNumber),
                           contentModified: Date(timeIntervalSince1970: entry.fingerprint.mtime),
                           isDataless: entry.fingerprint.isDataless,
                           provenance: provenance)
    }

    private static func rebuilt(_ f: ArchiveFile, after: [String], afterLabel: Int?) -> ArchiveFile {
        ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                    tags: DocumentTags.parse(raw: after, labelNumber: afterLabel),
                    contentModified: f.contentModified,
                    isDataless: f.isDataless,
                    provenance: .disk(readAt: Date()))
    }

    private static func shortType(uti: String?, url: URL) -> String {
        if uti == "com.adobe.pdf" { return "PDF" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}

/// One-way cancellation bit shared between the main actor and the walking thread.
private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
