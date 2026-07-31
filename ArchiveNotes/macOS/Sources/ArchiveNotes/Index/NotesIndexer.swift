import Foundation

/// Drives the background content-indexing of Archive Notes items into `NotesIndex`, and
/// answers full-text queries. Forked from Reader's `ContentIndexer`, adapted for UUID-keyed
/// items with `FrontMatterCodec` extraction instead of PDF extraction.
///
/// Indexing runs off the main actor (detached); @Published progress drives the UI.
@MainActor
final class NotesIndexer: ObservableObject {
    /// (done, total) while indexing; nil when idle.
    @Published private(set) var progress: (done: Int, total: Int)?

    /// Monotonic **completion** token — bumped by one each time the driver settles to idle (a build
    /// pass finished with no coalesced successor, or an empty / no-work scope cleared it). Distinct
    /// from the private launch-epoch `generation` below (which only discards stale reports). XCUITest
    /// polls the hidden `an.status.indexReady` element for a change in this token to know a build
    /// settled, instead of racing the async build (08-testing §3.4).
    @Published private(set) var indexGeneration = 0
    /// `true` once the driver has settled at least once — i.e. the initial build has completed. Tests
    /// (and the hidden probe) await this deterministic state before asserting FTS / relevance results.
    ///
    /// **Settled, not healthy.** It must flip even when the build failed, or `awaitSettled()` would
    /// never resume and `bootstrap()` would hang before first paint. Whether the settled index is any
    /// good is `failure`, below (W23.m9).
    @Published private(set) var isIndexReady = false

    /// Why the index is degraded, when it is (`nil` = healthy).
    ///
    /// The FTS half is a disposable cache, so this is never data loss — but without it the failure was
    /// silent (W23.m9): a failed `open()` or a failed batch write was swallowed by `try?`, the driver
    /// settled like any other pass, and `NotesModel` reloaded the partial index and marked it Ready.
    /// A note missing from search is then indistinguishable from a note that doesn't match.
    ///
    /// Deliberately NOT shared with Reader's `ContentIndexer.Failure`: this driver is a fork, the
    /// wording differs (notes vs files), and a shared type in ArchiveCore would couple both apps'
    /// UI copy to a third module.
    enum Failure: Equatable, Sendable {
        /// The index could not be opened — nothing is searchable until it can be.
        case unavailable(detail: String)
        /// The pass ran, but `rows` extracted notes could not be written — results are incomplete.
        case incomplete(rows: Int)

        /// One line for the sidebar status banner.
        var message: String {
            switch self {
            case .unavailable(let d):
                return "Search index unavailable (\(d)) — search and the note list may be incomplete. "
                     + "Your notes on disk are unaffected."
            case .incomplete(let n):
                return "Search index incomplete — \(n) note\(n == 1 ? "" : "s") couldn't be indexed, so "
                     + "search may miss \(n == 1 ? "it" : "them")."
            }
        }
    }

    /// Published so `NotesModel` can surface a degraded index instead of a clean "Ready".
    @Published private(set) var failure: Failure?

    private let index: NotesIndex
    private var task: Task<Void, Never>?
    private var pending: [ItemRef]?
    private var generation = 0
    /// Continuations parked in `awaitSettled()`, resumed together the next time the driver settles.
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []

    /// Inject the shared `NotesIndex` (app path) so this driver and `NotesModel` use **one** sqlite
    /// handle to the same file rather than two independent connections.
    init(index: NotesIndex) { self.index = index }

    /// Standalone convenience — owns its own default-location index. Retained for isolated use.
    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
        self.init(index: NotesIndex(url: dir.appendingPathComponent("notes-index-v1.sqlite3")))
    }

    /// Incrementally index the given items (skips unchanged via mtime).
    ///
    /// - Empty set: cancel any in-flight pass (scope cleared / no items).
    /// - If a pass is running, coalesces into `pending` (newest wins).
    func startIndexing(_ refs: [ItemRef]) {
        guard !refs.isEmpty else {
            generation += 1
            task?.cancel(); task = nil; pending = nil; progress = nil
            markSettled()   // reached idle (empty scope / no items) — the probe reads "ready"
            return
        }
        if task != nil { pending = refs; return }
        launch(refs)
    }

    private func launch(_ refs: [ItemRef]) {
        generation += 1
        let gen = generation
        let idx = index
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await idx.open()
            } catch {
                // Nothing is writable, so reading + decoding every .md would only throw the results
                // away one batch at a time. Report it and stop — but STILL through `finish`, so the
                // driver settles and `awaitSettled()`'s waiters (bootstrap included) resume (W23.m9).
                await self?.finish(gen, .couldNotOpen(Self.detail(error)))
                return
            }
            let existing = await idx.existingMTimes()
            let work = refs.filter { ref in
                guard let stored = existing[ref.id.uuidString] else { return true }
                return stored != ref.mtime
            }
            let total = refs.count
            let skipped = total - work.count
            await self?.report((skipped, total), gen)
            if work.isEmpty {
                await self?.finish(gen)
                return
            }

            let batchSize = 500
            var batch: [NoteIndexRow] = []
            batch.reserveCapacity(batchSize)
            var done = skipped
            var rowsIndexed = 0
            /// Extracted rows a failed batch write dropped — surfaced as `.incomplete`, not swallowed.
            var droppedRows = 0

            await withTaskGroup(of: NoteIndexRow?.self) { group in
                var queued = 0
                var workIter = work.makeIterator()

                while queued < workers, let ref = workIter.next() {
                    let capturedRef = ref
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return nil }
                        return Self.extractRow(from: capturedRef)
                    }
                    queued += 1
                }

                for await row in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let row {
                        batch.append(row)
                        rowsIndexed += 1
                    }
                    done += 1

                    if batch.count >= batchSize {
                        do { try await idx.upsertBatch(batch) } catch { droppedRows += batch.count }
                        batch.removeAll(keepingCapacity: true)
                    }

                    if done % 100 == 0 || done == total {
                        await self?.report((done, total), gen)
                    }

                    if let ref = workIter.next() {
                        let capturedRef = ref
                        group.addTask(priority: .utility) {
                            guard !Task.isCancelled else { return nil }
                            return Self.extractRow(from: capturedRef)
                        }
                    }
                }
            }

            if !batch.isEmpty {
                do { try await idx.upsertBatch(batch) } catch { droppedRows += batch.count }
            }

            await idx.performMaintenance(rowsIndexed: rowsIndexed)
            await self?.finish(gen, droppedRows > 0 ? .rowsDropped(droppedRows) : .ok)
        }
    }

    /// Full-text search -> matching item UUIDs in **bm25 relevance order**.
    func search(_ query: String) async -> [UUID] {
        guard await openForQuery() else { return [] }
        return await index.search(query)
    }

    /// Load an ItemSummary by UUID from the index (no .md read needed).
    func summary(for id: UUID) async -> ItemSummary? {
        guard await openForQuery() else { return nil }
        return await index.summary(for: id)
    }

    /// The SQLite message out of a `NotesIndex.IndexError`, for a `Failure`'s detail.
    private nonisolated static func detail(_ error: Error) -> String {
        switch error {
        case NotesIndex.IndexError.open(let m), NotesIndex.IndexError.sql(let m): return m
        default: return String(describing: error)
        }
    }

    /// Open the index for a query, recording an `unavailable` failure (and returning false) when it
    /// can't be opened — a query over a dead index otherwise degrades to an empty result the user
    /// reads as "nothing matches" (W23.m9).
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

    // MARK: - Pruning (gated cache eviction)

    /// UUIDs absent in the previous settled emission. A UUID is only eligible for deletion
    /// after confirmed absent across **two consecutive** post-gather snapshots — same
    /// transient-drop guard as Reader's ContentIndexer.
    private var pendingPrune: Set<UUID>?
    private var pruneTask: Task<Void, Never>?

    /// Epoch token for pruning — distinct from the launch-epoch `generation` above. Every emission
    /// takes a fresh one, and a task still holding an older one is *superseded*: both of its writes
    /// (the `pendingPrune` update and the row delete) become no-ops.
    ///
    /// Cancelling the prior task is not enough on its own (W23.l2). Cancellation is cooperative, so a
    /// task already past its last `Task.isCancelled` check runs to completion — and `MainActor.run` is
    /// not cancellation-aware, so its late hops execute too. Confirmed against the runtime on the
    /// Reader's copy of this code, where a superseded task was observed reading a `pendingPrune` a
    /// NEWER emission had just written, treating it as "the previous emission", and deleting after
    /// only ONE current absence — and, in the other interleaving, deleting a row the newest snapshot
    /// said was present.
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
    func commitPruneDecision(gen: Int, indexed: Set<UUID>, currentIDs: Set<UUID>) -> Set<UUID> {
        guard gen == pruneGeneration else { return [] }
        let decision = Self.pruneDecision(indexed: indexed,
                                          currentIDs: currentIDs,
                                          previousPending: pendingPrune)
        pendingPrune = decision.newPending
        return decision.delete
    }

    /// Evict index rows for items no longer present:
    ///   Gate 0 (empty-snapshot): an empty `currentIDs` is treated as "no reliable snapshot"
    ///     (mid-build / scope-cleared) and NEVER prunes, so a persistent empty snapshot can't wipe
    ///     the index. Enforced inside `pruneDecision`, so the guarantee holds without a caller check.
    ///   Gate 1: caller should still only call this on a settled, boundary-scoped snapshot.
    ///   Gate 2: a UUID must be absent in two consecutive calls (transient-drop guard).
    ///   Gate 3: the emission must still be the current one — a superseded task writes nothing
    ///     (W23.l2; cancelling it is cooperative and can arrive too late).
    /// The pure decision lives in `pruneDecision` (unit-tested; no async, no index, no real store).
    func pruneIfSettled(currentIDs: Set<UUID>) {
        pruneTask?.cancel()
        // Gate 3 (W23.l2): cancellation alone is cooperative and can arrive too late, so stamp this
        // emission. Everything the task writes below is a no-op once the stamp goes stale.
        let gen = beginPruneGeneration()
        let idx = index
        pruneTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            // A failed open needs no `Failure` here (unlike the query paths): `allIndexedIDs()` then
            // reads empty, so `pruneDecision` finds nothing absent and deletes nothing — it degrades
            // to a no-op, and the build/query paths are what report the failure to the user.
            try? await idx.open()
            let indexed = await idx.allIndexedIDs()
            guard !Task.isCancelled else { return }

            // Gates 0+2+3, atomically: decide and carry the pending set forward in one main-actor
            // hop, and only if this emission is still the current one.
            let toDelete = await MainActor.run { [weak self] () -> Set<UUID> in
                self?.commitPruneDecision(gen: gen, indexed: indexed, currentIDs: currentIDs) ?? []
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

            try? await idx.deleteItems(Array(toDelete))
            await idx.performMaintenance(rowsIndexed: 0)
        }
    }

    /// Pure two-emission prune gate (extracted so the data-safety guarantee is deterministically
    /// unit-testable — no async, no `NotesIndex`, no real store). Returns which indexed rows to
    /// delete now and the pending-absence set to carry into the next emission.
    ///
    /// - `currentIDs` empty → `([], nil)`: an empty snapshot is never a reason to prune (mid-build or
    ///   scope-cleared). This is the "empty-snapshot can't wipe the index" guarantee — the index is a
    ///   rebuildable cache, so refusing to prune is always the safe choice.
    /// - nothing absent → `([], nil)`.
    /// - first emission of an absence (no prior pending) → stash it, delete nothing.
    /// - an absence confirmed across two consecutive emissions → delete it; carry any not-yet-confirmed
    ///   absences forward.
    nonisolated static func pruneDecision(
        indexed: Set<UUID>,
        currentIDs: Set<UUID>,
        previousPending: Set<UUID>?
    ) -> (delete: Set<UUID>, newPending: Set<UUID>?) {
        guard !currentIDs.isEmpty else { return ([], nil) }
        let absent = indexed.subtracting(currentIDs)
        guard !absent.isEmpty else { return ([], nil) }
        guard let prev = previousPending else { return ([], absent) }   // first emission: stash
        let confirmed = absent.intersection(prev)
        let remaining = absent.subtracting(confirmed)
        return (confirmed, remaining.isEmpty ? nil : remaining)
    }

    /// Bumps the epoch as well as cancelling: an in-flight task can be past its last cancellation
    /// check, and without the bump its late hop would re-stash the absences this call just cleared.
    func resetPruneState() {
        pruneTask?.cancel(); pruneTask = nil; pendingPrune = nil
        _ = beginPruneGeneration()
    }

    // MARK: - Extraction

    /// Read a .md file and extract an index row. Runs off the main actor (Sendable inputs only).
    private nonisolated static func extractRow(from ref: ItemRef) -> NoteIndexRow? {
        guard let data = try? Data(contentsOf: ref.url),
              let text = String(data: data, encoding: .utf8),
              let item = try? FrontMatterCodec.decode(text) else { return nil }
        // The Item→row mapping lives on NoteIndexRow so the edit-path re-index (W6-S7) matches exactly.
        return NoteIndexRow(item: item, mtime: ref.mtime)
    }

    // MARK: - Internal

    private func report(_ p: (Int, Int)?, _ gen: Int) { guard gen == generation else { return }; progress = p }

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

    private func finish(_ gen: Int, _ outcome: Outcome = .ok) {
        guard gen == generation else { return }
        // A completed pass is the authority on health: it either wrote everything it extracted
        // (so any earlier failure is stale) or it says what it couldn't write.
        setFailure(outcome.failure)
        task = nil
        if let next = pending { pending = nil; launch(next) }
        else { progress = nil; markSettled() }
    }

    /// Suspend until the driver is idle — no running pass and nothing coalesced-pending. Returns
    /// immediately if already idle. The app path awaits this after kicking the initial disk build so
    /// `isIndexReady` / `indexGeneration` reflect a **settled** index (08-testing §3.4).
    func awaitSettled() async {
        if task == nil && pending == nil { return }
        await withCheckedContinuation { settledWaiters.append($0) }
    }

    /// The driver reached idle: advance the completion token, mark ready, and resume every parked
    /// `awaitSettled()` waiter. A coalesced chain (`pending` re-launched) settles only once, at the end.
    private func markSettled() {
        indexGeneration += 1
        isIndexReady = true
        let waiters = settledWaiters
        settledWaiters = []
        for w in waiters { w.resume() }
    }
}
