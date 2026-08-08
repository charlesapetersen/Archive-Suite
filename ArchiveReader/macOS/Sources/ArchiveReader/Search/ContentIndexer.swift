import Foundation
import Combine
import ArchiveCore

/// Drives the background content-indexing of the library into `ContentIndex`, and answers full-text
/// queries. Indexing runs off the main actor (detached); @Published progress drives the UI.
@MainActor
final class ContentIndexer: ObservableObject {
    /// (done, total) while indexing; nil when idle.
    @Published private(set) var progress: (done: Int, total: Int)?

    /// Why the content index is degraded, when it is (`nil` = healthy).
    ///
    /// The index is a disposable cache, so a failure here is never data loss — but without this it
    /// was a silent lie (W23.m9): a failed `open()` or a failed batch write was swallowed by `try?`,
    /// the pass then finished like any other, and the status bar went idle over an empty index. An
    /// empty search result is indistinguishable from "no matches", and an empty format-health count
    /// reads as "nothing needs attention".
    enum Failure: Equatable, Sendable {
        /// The index could not be opened — nothing is searchable until it can be.
        case unavailable(detail: String)
        /// The pass ran, but `rows` cache rows could not be updated or removed — results are incomplete.
        case incomplete(rows: Int)

        /// One line for the status bar.
        var message: String {
            switch self {
            case .unavailable:       return "Search index unavailable"
            case .incomplete(let n): return "Search index incomplete — \(n) file\(n == 1 ? "" : "s") missing"
            }
        }

        /// The longer explanation, for the status bar's tooltip.
        var detail: String {
            switch self {
            case .unavailable(let d):
                return "Full-text search and format health can't be read from the index (\(d)). "
                     + "The index is a rebuildable cache — tags and files are unaffected."
            case .incomplete(let n):
                return "\(n) file\(n == 1 ? "" : "s") couldn't be updated in the index, so search may "
                     + "miss \(n == 1 ? "it" : "them"). The next indexing pass retries."
            }
        }
    }

    /// Published so the status bar can show a degraded index instead of an idle one.
    @Published private(set) var failure: Failure?

    private let index: ContentIndex
    /// Handle to the running detached pass so a scope change can cancel it (otherwise the stale pass
    /// holds the slot forever — its `Task.isCancelled` check was dead code without this).
    private var task: Task<Void, Never>?
    /// A newer file set requested while a pass was running. Coalesced (newest wins) and launched when
    /// the current pass finishes, so a live/incremental discovery update (an FSEvents re-inspection or a
    /// revalidation pass) is never silently dropped.
    private var pending: [ArchiveFile]?
    /// Epoch token: each launch/cancel bumps it so a superseded pass's async progress/finish callbacks
    /// can't clobber the current pass's state (same pattern as NavigationModel.ftsGeneration).
    private var generation = 0
    /// Kept below the dataless policy wrapper so tests can spy on the exact would-open-PDF boundary.
    private let extractPDF: @Sendable (URL) -> ExtractedContent?
#if DEBUG
    /// Deterministic completion seam for async driver tests; not part of user-visible state.
    private(set) var completedPassesForTesting = 0
#endif

    /// Point the driver at a specific index file. The app path uses `init()`; tests pass a scratch
    /// (or deliberately corrupt) URL so the `Failure` paths are exercisable headlessly.
    init(url: URL) {
        index = ContentIndex(url: url)
        extractPDF = PDFTextExtractor.extract
    }

    /// Test-only shape: inject at the PDF-open boundary while retaining the production dataless
    /// filter and thread-scoped no-materialisation policy around every invocation.
    init(url: URL, extractPDFForTesting: @escaping @Sendable (URL) -> ExtractedContent?) {
        index = ContentIndex(url: url)
        extractPDF = extractPDFForTesting
    }

    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveReader", isDirectory: true)
        // v2: the schema gained non-standard-PDF columns (page_count/has_text/readable). Because
        // unchanged files won't re-index into an old DB, bumping the *filename* makes the new schema a
        // clean full re-index — safe, since the index is an explicitly disposable/rebuildable cache.
        // (The stale content-index.sqlite3 is left in place: the write-surface lint bans file-delete
        // APIs app-wide, and the orphan is a rebuildable cache the user can clear.)
        self.init(url: dir.appendingPathComponent("content-index-v2.sqlite3"))
    }

    /// Incrementally index the given files (skips unchanged content via `existingMTimes`).
    ///
    /// - An **empty** set means the library was cleared (a scope change, or no tagged files): cancel any
    ///   in-flight pass and drop queued work so a stale-scope pass can't starve the new scope. The next
    ///   non-empty call (the new scope's `DidFinishGathering`) starts a fresh pass promptly.
    /// - If a pass is **already running**, the request is *coalesced* into `pending` (newest wins) and
    ///   launched on completion — not dropped. Because `needsIndex` is mtime-based and idempotent, the
    ///   follow-up pass cheaply skips everything unchanged, so a tag-only update (mark Read, edit tags)
    ///   does NOT restart the expensive initial extraction from zero.
    func startIndexing(_ files: [ArchiveFile]) {
        guard !files.isEmpty else {
            generation += 1                 // invalidate any in-flight pass's callbacks
            task?.cancel(); task = nil; pending = nil; progress = nil
            return
        }
        if task != nil { pending = files; return }
        launch(files)
    }

    private func launch(_ files: [ArchiveFile]) {
        generation += 1
        let gen = generation
        let idx = index
        let extractPDF = extractPDF
        // Reserve cores for the main thread + system: at least 1 worker, leave 2 cores free.
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await idx.open()
            } catch {
                // Nothing is writable, so extracting every PDF in the library would only throw the
                // results away one batch at a time. Report the failure and stop (W23.m9).
                await self?.finish(gen, .couldNotOpen(Self.detail(error)))
                return
            }
            // Pull all stored mtimes in one query to partition work without per-file actor round-trips.
            let existing = await idx.existingMTimes()
            let datalessPaths = files.filter(\.isDataless).map(\.url.path)
            var cacheRowsDropped = 0
            if !datalessPaths.isEmpty {
                // Never let PDFDocument materialise a cloud placeholder. If a previously-local file
                // became dataless, remove only its disposable content row so stale OCR text cannot
                // masquerade as a current searchable result.
                do { try await idx.deletePaths(datalessPaths) }
                catch { cacheRowsDropped = datalessPaths.count }
            }
            let work = files.filter { f in
                guard !f.isDataless else { return false }
                let mtime = f.contentModified?.timeIntervalSince1970 ?? 0
                guard let stored = existing[f.url.path] else { return true }
                return stored != mtime
            }
            let total = files.count
            let skipped = total - work.count
            await self?.report((skipped, total), gen)
            if work.isEmpty {
                await self?.finish(gen, cacheRowsDropped > 0 ? .rowsDropped(cacheRowsDropped) : .ok)
                return
            }

            // Parallel extraction: bounded task group (width = workers). Each child captures
            // primitives only, runs PDFTextExtractor off-actor, returns a Sendable IndexRow.
            // DB writes stay serialized through the ContentIndex actor via batched upserts.
            let batchSize = 500
            var batch: [IndexRow] = []
            batch.reserveCapacity(batchSize)
            var done = skipped
            var rowsIndexed = 0
            /// Extracted rows a failed batch write dropped — surfaced as `.incomplete`, not swallowed.
            var droppedRows = cacheRowsDropped

            await withTaskGroup(of: IndexRow?.self) { group in
                var queued = 0
                var workIter = work.makeIterator()

                // Seed the group with `workers` tasks.
                while queued < workers, let f = workIter.next() {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return nil }
                        return Self.extractRow(f, extractPDF: extractPDF)
                    }
                    queued += 1
                }

                // As each child completes, enqueue the next file and collect rows for batching.
                for await row in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let row {
                        batch.append(row)
                        rowsIndexed += 1
                    }
                    done += 1

                    // Flush the batch when full.
                    if batch.count >= batchSize {
                        do { try await idx.upsertBatch(batch) } catch { droppedRows += batch.count }
                        batch.removeAll(keepingCapacity: true)
                    }

                    // Progress reporting (every 100 files or at the end).
                    if done % 100 == 0 || done == total {
                        await self?.report((done, total), gen)
                    }

                    // Feed the next file into the group.
                    if let f = workIter.next() {
                        group.addTask(priority: .utility) {
                            guard !Task.isCancelled else { return nil }
                            return Self.extractRow(f, extractPDF: extractPDF)
                        }
                    }
                }
            }

            // Flush any remaining rows.
            if !batch.isEmpty {
                do { try await idx.upsertBatch(batch) } catch { droppedRows += batch.count }
            }

            // Post-pass maintenance (actor-isolated): merge FTS segments + truncate WAL.
            await idx.performMaintenance(rowsIndexed: rowsIndexed)

            await self?.finish(gen, droppedRows > 0 ? .rowsDropped(droppedRows) : .ok)
        }
    }

    /// Each extraction worker owns the thread-scoped dataless policy for exactly its synchronous
    /// PDF open. The outer `isDataless` filter is the ordinary path; this guard closes the race where
    /// a local file becomes a placeholder after discovery but before `PDFDocument(url:)`.
    private nonisolated static func extractRow(
        _ file: ArchiveFile,
        extractPDF: @Sendable (URL) -> ExtractedContent?
    ) -> IndexRow {
        CorpusWalker.withDatalessMaterializationDisabled {
            let path = file.url.path
            let mtime = file.contentModified?.timeIntervalSince1970 ?? 0
            if let content = extractPDF(file.url) {
                return IndexRow(path: path, mtime: mtime, name: file.name,
                                classification: content.classification, body: content.fullBody,
                                pageCount: content.pageCount,
                                hasText: !content.fullBody.isEmpty, readable: true)
            }
            return IndexRow(path: path, mtime: mtime, name: file.name,
                            classification: nil, body: "",
                            pageCount: 0, hasText: false, readable: false)
        }
    }

    /// The SQLite message out of a `ContentIndex.IndexError`, for a `Failure`'s detail line.
    private nonisolated static func detail(_ error: Error) -> String {
        switch error {
        case ContentIndex.IndexError.open(let m), ContentIndex.IndexError.sql(let m): return m
        default: return String(describing: error)
        }
    }

    /// Open the index for a query, recording an `unavailable` failure (and returning false) when it
    /// can't be opened — a query over a dead index otherwise degrades to an empty result the user
    /// reads as "no matches" (W23.m9).
    private func openForQuery() async -> Bool {
        do {
            try await index.open()
            if case .unavailable = failure { setFailure(nil) }   // it opened; that claim is now false
            return true
        } catch {
            setFailure(.unavailable(detail: Self.detail(error)))
            return false
        }
    }

    /// Assign `failure` only when it actually changes — `@Published` republishes on every set, and the
    /// query paths run per keystroke.
    private func setFailure(_ new: Failure?) {
        if failure != new { failure = new }
    }

    /// Full-text search → matching file paths in **bm25 relevance order** (best match first).
    func search(_ query: String) async -> [String] {
        guard await openForQuery() else { return [] }
        return await index.search(query)
    }

    /// Full-text search → every matching path (bm25 order) plus bounded keyword-in-context snippets
    /// for the top hits (see `ContentIndex.searchRanked`), so a broad query doesn't compute a fragment
    /// for every match at corpus scale.
    func searchRanked(_ query: String, snippetLimit: Int = 300) async -> ContentIndex.RankedSearch {
        guard await openForQuery() else { return ContentIndex.RankedSearch(paths: [], snippets: [:]) }
        return await index.searchRanked(query, snippetLimit: snippetLimit)
    }

    /// Classification (`Document Start`/`Continuation`/`Box`/`Folder`) per path, where indexed.
    func classifications(for paths: [String]) async -> [String: String] {
        guard await openForQuery() else { return [:] }
        return await index.classifications(for: paths)
    }

    /// Non-standard-PDF status per path (unreadable / no-text-layer / standard), where indexed.
    func formatStatuses(for paths: [String]) async -> [String: PDFFormatStatus] {
        guard await openForQuery() else { return [:] }
        return await index.formatFlags(for: paths)
    }

    /// Count of files that need attention (unreadable or text-less) **among the current library's
    /// paths** — the shared index is never pruned, so a corpus-wide count over-reports after a root
    /// switch. Scoped so the badge matches the path-scoped `needsAttentionOnly` filter.
    func needsAttentionCount(among paths: [String]) async -> Int {
        guard await openForQuery() else { return 0 }
        return await index.needsAttentionCount(among: paths)
    }

    // MARK: - Pruning (gated cache eviction)

    /// Paths that were absent in the *previous* settled emission. A path is only eligible for
    /// deletion after it has been confirmed absent across **two consecutive** settled snapshots.
    ///
    /// ⚠️ **The reason changed with `W26.walk2`; the gate did not.** It was written to close
    /// Spotlight's transient-drop window (a file could momentarily vanish from a `DidUpdate` after a
    /// tag write and reappear on the next one). A deterministic walk has no such drop — but it has its
    /// own transient-absence mode: a file being replaced by an atomic rewrite, or one whose tags could
    /// not be read on that pass. The gate counts **emissions, not time**, so with one emission per
    /// walk it now means "absent from two consecutive complete passes" — strictly stronger than what
    /// it replaced. Re-tuned by re-reading, not removed (`W26.walk2`); deleting it was considered and
    /// rejected, because index rows are the one thing here whose loss the user notices as
    /// silently-missing search results.
    private var pendingPrune: Set<String>?

    /// The in-flight prune task. Serialized: a new call cancels any prior in-flight task so two
    /// overlapping detached tasks cannot race on `pendingPrune` and defeat the two-emission gate.
    private var pruneTask: Task<Void, Never>?

    /// Epoch token for pruning — distinct from the indexing `generation` above. Every emission takes
    /// a fresh one, and a task still holding an older one is *superseded*: all of its writes (the
    /// `pendingPrune` update and the row delete) become no-ops.
    ///
    /// Cancelling the prior task is not enough on its own (W23.l2). Cancellation is cooperative, so a
    /// task already past its last `Task.isCancelled` check runs to completion — and `MainActor.run` is
    /// not cancellation-aware, so its late hops execute too. Verified against the runtime, not assumed:
    /// a superseded task was observed reading a `pendingPrune` a NEWER emission had just written,
    /// treating it as "the previous emission", and deleting after only ONE current absence; and in the
    /// other interleaving, deleting a path the newest snapshot said was present. The source files are
    /// never at risk (this index is a rebuildable cache) but the rows vanish from search until a
    /// reindex.
    private var pruneGeneration = 0

    /// Open a new prune epoch, superseding any task holding an older one.
    ///
    /// Internal rather than private so a test can supersede an emission deterministically, without
    /// having to win a real race against a detached task.
    func beginPruneGeneration() -> Int {
        pruneGeneration += 1
        return pruneGeneration
    }

    /// True while `gen` is still the current prune epoch.
    func isCurrentPruneGeneration(_ gen: Int) -> Bool { gen == pruneGeneration }

    /// The in-flight prune task, so a test can await an emission rather than sleep on it.
    var inFlightPruneTask: Task<Void, Never>? { pruneTask }

    /// Apply one emission's prune decision: read the pending set, decide, and write the new pending
    /// set — **all in one main-actor hop**, and only if `gen` is still current. Returns the rows to
    /// delete (empty when superseded).
    ///
    /// The single hop is load-bearing, not tidiness: the old code read `pendingPrune` in one hop and
    /// wrote it in another, and a newer emission's hop could land in between. The generation check and
    /// the atomic read-decide-write together are what make a superseded task inert.
    func commitPruneDecision(gen: Int,
                             indexedUnderRoot: Set<String>,
                             currentPaths: Set<String>) -> Set<String> {
        guard gen == pruneGeneration else { return [] }
        let decision = Self.pruneDecision(indexedUnderRoot: indexedUnderRoot,
                                          currentPaths: currentPaths,
                                          previousPending: pendingPrune)
        pendingPrune = decision.newPending
        return decision.delete
    }

    /// Pure two-emission prune gate (mirrors `NotesIndexer.pruneDecision`, whose fork this is).
    /// Extracted so the data-safety guarantee is deterministically unit-testable — no async, no
    /// `ContentIndex`, no corpus.
    ///
    /// - `currentPaths` empty → `([], nil)`: an empty snapshot is never a reason to prune (mid-gather
    ///   or scope-cleared). `NavigationModel` already refuses to call with an empty set; holding the
    ///   guarantee here too means it can't be lost to a future caller.
    /// - nothing absent → `([], nil)`.
    /// - first sighting of an absence → stash it, delete nothing.
    /// - an absence confirmed across two consecutive emissions → delete it; carry the rest forward.
    nonisolated static func pruneDecision(
        indexedUnderRoot: Set<String>,
        currentPaths: Set<String>,
        previousPending: Set<String>?
    ) -> (delete: Set<String>, newPending: Set<String>?) {
        guard !currentPaths.isEmpty else { return ([], nil) }
        let absent = indexedUnderRoot.subtracting(currentPaths)
        guard !absent.isEmpty else { return ([], nil) }
        guard let prev = previousPending else { return ([], absent) }   // first sighting: stash
        let confirmed = absent.intersection(prev)
        let remaining = absent.subtracting(confirmed)
        return (confirmed, remaining.isEmpty ? nil : remaining)
    }

    /// Evict index rows for files no longer under `rootPrefix` — but ONLY when the snapshot is
    /// settled and confirmed across two emissions:
    ///   Gate 1: `library.phase.isSettled` (caller ensures) and `!currentPaths.isEmpty` (also enforced
    ///           inside `pruneDecision`, so an empty snapshot can never wipe the index)
    ///   Gate 2: a path must be absent in two consecutive calls (transient-drop guard)
    ///   Gate 3: only paths under `rootPrefix` (component-boundary) are candidates
    ///   Gate 4: the emission must still be the current one — a superseded task writes nothing
    ///           (W23.l2; cancelling it is cooperative and can arrive too late)
    ///
    /// This is a separate call from `startIndexing` — a destructive delete must never ride the
    /// harmless-on-empty indexing emission.
    func pruneIfSettled(currentPaths: Set<String>, rootPrefix: String) {
        pruneTask?.cancel()
        // Gate 4 (W23.l2): cancellation alone is cooperative and can arrive too late, so stamp this
        // emission. Everything the task writes below is a no-op once the stamp goes stale.
        let gen = beginPruneGeneration()
        let idx = index
        pruneTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            // A failed open needs no `Failure` here (unlike the query paths): `allPaths()` then reads
            // empty, `absent` is empty, and the prune deletes nothing — it degrades to a no-op, and
            // the indexing/query paths are what report the failure to the user.
            try? await idx.open()
            let indexed = await idx.allPaths()
            guard !Task.isCancelled else { return }

            // Scope to the current root using a component-boundary test (not substring LIKE).
            // A root "/Archive" must not match "/ArchiveBox/file.pdf".
            let normalizedRoot = rootPrefix.hasSuffix("/") ? String(rootPrefix.dropLast()) : rootPrefix
            let indexedUnderRoot = indexed.filter { path in
                path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
            }

            // Gates 2+4, atomically: diff against the current library set, confirm across two
            // emissions, and carry the remainder forward — in one main-actor hop, and only if this
            // emission is still the current one.
            let toDelete = await MainActor.run { [weak self] () -> Set<String> in
                self?.commitPruneDecision(gen: gen,
                                          indexedUnderRoot: indexedUnderRoot,
                                          currentPaths: currentPaths) ?? []
            }
            guard !toDelete.isEmpty else { return }

            // The decision was current when it was taken, but the delete is another suspension away.
            // Re-check rather than evict rows a newer snapshot may already have said are present:
            // skipping costs only that the rows survive one more two-emission cycle, while deleting
            // them wrongly costs search hits until a reindex.
            let stillCurrent = await MainActor.run { [weak self] in
                self?.isCurrentPruneGeneration(gen) ?? false
            }
            guard stillCurrent else { return }

            try? await idx.deletePaths(Array(toDelete))
            await idx.performMaintenance(rowsIndexed: 0) // checkpoint only
            try? await idx.open() // ensure WAL checkpoint worked; harmless if already open
        }
    }

    /// Immediately prune index rows whose path falls under any of the given absolute prefixes.
    /// Called when the user excludes a folder, so search results stop matching immediately
    /// (not gated by the two-emission window).
    func pruneExcluded(prefixes: [String]) {
        guard !prefixes.isEmpty else { return }
        let idx = index
        Task.detached(priority: .utility) {
            try? await idx.open()
            let all = await idx.allPaths()
            let toDelete = all.filter { path in
                prefixes.contains { prefix in
                    path == prefix || path.hasPrefix(prefix + "/")
                }
            }
            if !toDelete.isEmpty {
                try? await idx.deletePaths(Array(toDelete))
                await idx.performMaintenance(rowsIndexed: 0)
            }
        }
    }

    /// Reset the pending-prune state (e.g. on a scope/root change that invalidates the snapshot).
    ///
    /// Bumps the epoch as well as cancelling: an in-flight task from the OLD root can be past its last
    /// cancellation check, and without the bump its late hop would re-stash that root's absences over
    /// the state this call just cleared.
    func resetPruneState() {
        pruneTask?.cancel(); pruneTask = nil; pendingPrune = nil
        _ = beginPruneGeneration()
    }

    /// Publish progress only for the current pass (a superseded/cancelled pass is ignored).
    private func report(_ p: (Int, Int)?, _ gen: Int) { guard gen == generation else { return } ; progress = p }

    /// How a pass ended, from the pass's own point of view. `finish` maps this to the published
    /// `failure`, so health is decided in exactly one place — and the mapping is a pure function the
    /// tests can check without having to make SQLite fail a write on demand.
    enum Outcome: Equatable, Sendable {
        /// Every extracted row was written (or there was no work).
        case ok
        /// The pass ran but `Int` cache rows couldn't be updated or removed.
        case rowsDropped(Int)
        /// The index never opened, so nothing was attempted.
        case couldNotOpen(String)

        /// The state a pass ending this way leaves behind. `.ok` clears any earlier failure: a pass
        /// that wrote everything it extracted is the strongest evidence the index is healthy.
        var failure: Failure? {
            switch self {
            case .ok:                  return nil
            case .rowsDropped(let n):  return .incomplete(rows: n)
            case .couldNotOpen(let d): return .unavailable(detail: d)
            }
        }
    }

    /// Called when a pass ends. If it's still the current pass, record what it achieved, clear the
    /// slot and drain any coalesced request; a superseded pass (cancelled or replaced) is ignored so
    /// it can't clobber newer state.
    private func finish(_ gen: Int, _ outcome: Outcome = .ok) {
        guard gen == generation else { return }
#if DEBUG
        completedPassesForTesting += 1
#endif
        // A completed pass is the authority on health: it either wrote everything it extracted
        // (so any earlier failure is stale) or it says what it couldn't write.
        setFailure(outcome.failure)
        task = nil
        if let next = pending { pending = nil; launch(next) }
        else { progress = nil }
    }
}
