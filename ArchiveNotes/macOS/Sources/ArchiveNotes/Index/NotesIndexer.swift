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
    @Published private(set) var isIndexReady = false

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
            try? await idx.open()
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
                        try? await idx.upsertBatch(batch)
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
                try? await idx.upsertBatch(batch)
            }

            await idx.performMaintenance(rowsIndexed: rowsIndexed)
            await self?.finish(gen)
        }
    }

    /// Full-text search -> matching item UUIDs in **bm25 relevance order**.
    func search(_ query: String) async -> [UUID] {
        try? await index.open()
        return await index.search(query)
    }

    /// Load an ItemSummary by UUID from the index (no .md read needed).
    func summary(for id: UUID) async -> ItemSummary? {
        try? await index.open()
        return await index.summary(for: id)
    }

    // MARK: - Pruning (gated cache eviction)

    /// UUIDs absent in the previous settled emission. A UUID is only eligible for deletion
    /// after confirmed absent across **two consecutive** post-gather snapshots — same
    /// transient-drop guard as Reader's ContentIndexer.
    private var pendingPrune: Set<UUID>?
    private var pruneTask: Task<Void, Never>?

    /// Evict index rows for items no longer present:
    ///   Gate 0 (empty-snapshot): an empty `currentIDs` is treated as "no reliable snapshot"
    ///     (mid-build / scope-cleared) and NEVER prunes, so a persistent empty snapshot can't wipe
    ///     the index. Enforced inside `pruneDecision`, so the guarantee holds without a caller check.
    ///   Gate 1: caller should still only call this on a settled, boundary-scoped snapshot.
    ///   Gate 2: a UUID must be absent in two consecutive calls (transient-drop guard).
    /// The pure decision lives in `pruneDecision` (unit-tested; no async, no index, no real store).
    func pruneIfSettled(currentIDs: Set<UUID>) {
        pruneTask?.cancel()
        let idx = index
        pruneTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            try? await idx.open()
            let indexed = await idx.allIndexedIDs()
            guard !Task.isCancelled else { return }

            let previousPending: Set<UUID>? = await MainActor.run { [weak self] in self?.pendingPrune }
            let decision = Self.pruneDecision(indexed: indexed,
                                              currentIDs: currentIDs,
                                              previousPending: previousPending)
            if !decision.delete.isEmpty {
                try? await idx.deleteItems(Array(decision.delete))
                await idx.performMaintenance(rowsIndexed: 0)
            }
            await MainActor.run { [weak self] in self?.pendingPrune = decision.newPending }
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

    func resetPruneState() { pruneTask?.cancel(); pruneTask = nil; pendingPrune = nil }

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

    private func finish(_ gen: Int) {
        guard gen == generation else { return }
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
