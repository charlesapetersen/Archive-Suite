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
        /// The pass ran, but `rows` extracted rows could not be written — results are incomplete.
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
                return "\(n) file\(n == 1 ? "" : "s") couldn't be written to the index, so search may "
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
    /// the current pass finishes, so a live/incremental Spotlight update is never silently dropped.
    private var pending: [ArchiveFile]?
    /// Epoch token: each launch/cancel bumps it so a superseded pass's async progress/finish callbacks
    /// can't clobber the current pass's state (same pattern as NavigationModel.ftsGeneration).
    private var generation = 0

    /// Point the driver at a specific index file. The app path uses `init()`; tests pass a scratch
    /// (or deliberately corrupt) URL so the `Failure` paths are exercisable headlessly.
    init(url: URL) { index = ContentIndex(url: url) }

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
            let work = files.filter { f in
                let mtime = f.contentModified?.timeIntervalSince1970 ?? 0
                guard let stored = existing[f.url.path] else { return true }
                return stored != mtime
            }
            let total = files.count
            let skipped = total - work.count
            await self?.report((skipped, total), gen)
            if work.isEmpty {
                await self?.finish(gen)
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
            var droppedRows = 0

            await withTaskGroup(of: IndexRow?.self) { group in
                var queued = 0
                var workIter = work.makeIterator()

                // Seed the group with `workers` tasks.
                while queued < workers, let f = workIter.next() {
                    let url = f.url
                    let path = f.url.path
                    let mtime = f.contentModified?.timeIntervalSince1970 ?? 0
                    let name = f.name
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return nil }
                        if let content = PDFTextExtractor.extract(url) {
                            return IndexRow(path: path, mtime: mtime, name: name,
                                            classification: content.classification, body: content.fullBody,
                                            pageCount: content.pageCount,
                                            hasText: !content.fullBody.isEmpty, readable: true)
                        } else {
                            return IndexRow(path: path, mtime: mtime, name: name,
                                            classification: nil, body: "",
                                            pageCount: 0, hasText: false, readable: false)
                        }
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
                        let url = f.url
                        let path = f.url.path
                        let mtime = f.contentModified?.timeIntervalSince1970 ?? 0
                        let name = f.name
                        group.addTask(priority: .utility) {
                            guard !Task.isCancelled else { return nil }
                            if let content = PDFTextExtractor.extract(url) {
                                return IndexRow(path: path, mtime: mtime, name: name,
                                                classification: content.classification, body: content.fullBody,
                                                pageCount: content.pageCount,
                                                hasText: !content.fullBody.isEmpty, readable: true)
                            } else {
                                return IndexRow(path: path, mtime: mtime, name: name,
                                                classification: nil, body: "",
                                                pageCount: 0, hasText: false, readable: false)
                            }
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
    /// deletion after it has been confirmed absent across **two consecutive** post-gather snapshots
    /// — this closes Spotlight's transient-drop window (a file can momentarily vanish from
    /// `NSMetadataQueryDidUpdate` after a tag write and reappear on the next update).
    private var pendingPrune: Set<String>?

    /// The in-flight prune task. Serialized: a new call cancels any prior in-flight task so two
    /// overlapping detached tasks cannot race on `pendingPrune` and defeat the two-emission gate.
    private var pruneTask: Task<Void, Never>?

    /// Evict index rows for files no longer under `rootPrefix` — but ONLY when the snapshot is
    /// settled and confirmed across two emissions:
    ///   Gate 1: `isGathering == false && !currentPaths.isEmpty`  (caller ensures)
    ///   Gate 2: a path must be absent in two consecutive calls (transient-drop guard)
    ///   Gate 3: only paths under `rootPrefix` (component-boundary) are candidates
    ///
    /// This is a separate call from `startIndexing` — a destructive delete must never ride the
    /// harmless-on-empty indexing emission.
    func pruneIfSettled(currentPaths: Set<String>, rootPrefix: String) {
        pruneTask?.cancel()
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

            // Diff: indexed-under-root paths NOT in the current library set.
            let absent = indexedUnderRoot.subtracting(currentPaths)
            guard !absent.isEmpty else {
                await MainActor.run { [weak self] in self?.pendingPrune = nil }
                return
            }

            // Gate 2: confirm across two emissions.
            let previousPending: Set<String>? = await MainActor.run { [weak self] in self?.pendingPrune }
            if let prev = previousPending {
                // Only delete paths that were absent in BOTH this and the previous snapshot.
                let confirmed = absent.intersection(prev)
                if !confirmed.isEmpty {
                    try? await idx.deletePaths(Array(confirmed))
                    await idx.performMaintenance(rowsIndexed: 0) // checkpoint only
                    try? await idx.open() // ensure WAL checkpoint worked; harmless if already open
                }
                await MainActor.run { [weak self] in
                    // If there are still-pending paths (absent this time but not last time), keep them.
                    let remaining = absent.subtracting(confirmed)
                    self?.pendingPrune = remaining.isEmpty ? nil : remaining
                }
            } else {
                // First sighting — stash for confirmation on the next emission.
                await MainActor.run { [weak self] in self?.pendingPrune = absent }
            }
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
    func resetPruneState() { pruneTask?.cancel(); pruneTask = nil; pendingPrune = nil }

    /// Publish progress only for the current pass (a superseded/cancelled pass is ignored).
    private func report(_ p: (Int, Int)?, _ gen: Int) { guard gen == generation else { return } ; progress = p }

    /// How a pass ended, from the pass's own point of view. `finish` maps this to the published
    /// `failure`, so health is decided in exactly one place — and the mapping is a pure function the
    /// tests can check without having to make SQLite fail a write on demand.
    enum Outcome: Equatable, Sendable {
        /// Every extracted row was written (or there was no work).
        case ok
        /// The pass ran but `Int` extracted rows couldn't be written.
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
        // A completed pass is the authority on health: it either wrote everything it extracted
        // (so any earlier failure is stale) or it says what it couldn't write.
        setFailure(outcome.failure)
        task = nil
        if let next = pending { pending = nil; launch(next) }
        else { progress = nil }
    }
}
