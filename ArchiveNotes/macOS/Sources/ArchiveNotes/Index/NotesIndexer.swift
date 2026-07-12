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

    private let index: NotesIndex
    private var task: Task<Void, Never>?
    private var pending: [ItemRef]?
    private var generation = 0

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
        index = NotesIndex(url: dir.appendingPathComponent("notes-index-v1.sqlite3"))
    }

    /// Incrementally index the given items (skips unchanged via mtime).
    ///
    /// - Empty set: cancel any in-flight pass (scope cleared / no items).
    /// - If a pass is running, coalesces into `pending` (newest wins).
    func startIndexing(_ refs: [ItemRef]) {
        guard !refs.isEmpty else {
            generation += 1
            task?.cancel(); task = nil; pending = nil; progress = nil
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
    ///   Gate 1: caller ensures snapshot is settled and non-empty.
    ///   Gate 2: UUID must be absent in two consecutive calls (transient-drop guard).
    func pruneIfSettled(currentIDs: Set<UUID>) {
        pruneTask?.cancel()
        let idx = index
        pruneTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            try? await idx.open()
            let indexed = await idx.allIndexedIDs()
            guard !Task.isCancelled else { return }

            let absent = indexed.subtracting(currentIDs)
            guard !absent.isEmpty else {
                await MainActor.run { [weak self] in self?.pendingPrune = nil }
                return
            }

            let previousPending: Set<UUID>? = await MainActor.run { [weak self] in self?.pendingPrune }
            if let prev = previousPending {
                let confirmed = absent.intersection(prev)
                if !confirmed.isEmpty {
                    try? await idx.deleteItems(Array(confirmed))
                    await idx.performMaintenance(rowsIndexed: 0)
                }
                await MainActor.run { [weak self] in
                    let remaining = absent.subtracting(confirmed)
                    self?.pendingPrune = remaining.isEmpty ? nil : remaining
                }
            } else {
                await MainActor.run { [weak self] in self?.pendingPrune = absent }
            }
        }
    }

    func resetPruneState() { pruneTask?.cancel(); pruneTask = nil; pendingPrune = nil }

    // MARK: - Extraction

    /// Read a .md file and extract an index row. Runs off the main actor (Sendable inputs only).
    private nonisolated static func extractRow(from ref: ItemRef) -> NoteIndexRow? {
        guard let data = try? Data(contentsOf: ref.url),
              let text = String(data: data, encoding: .utf8),
              let item = try? FrontMatterCodec.decode(text) else { return nil }

        let bodyText = item.blocks.map(\.markdown).joined(separator: "\n")
        let fullBody: String
        if let leading = item.trailingBodyRaw {
            fullBody = leading + "\n" + bodyText
        } else {
            fullBody = bodyText
        }

        let encoder = JSONEncoder()
        let tagsJSON = (try? encoder.encode(item.tags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let authorsJSON = (try? encoder.encode(item.authors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return NoteIndexRow(
            id: ref.id,
            mtime: ref.mtime,
            title: item.title,
            kind: item.kind,
            tags: item.tags.joined(separator: " "),
            authors: item.authors.joined(separator: " "),
            authorsJSON: authorsJSON,
            body: fullBody,
            date: item.date,
            datePrecision: item.datePrecision,
            dateUncertain: item.dateUncertain,
            sortDate: item.sortDate,
            quality: item.quality,
            created: item.created,
            modified: item.modified,
            managedTags: tagsJSON
        )
    }

    // MARK: - Internal

    private func report(_ p: (Int, Int)?, _ gen: Int) { guard gen == generation else { return }; progress = p }

    private func finish(_ gen: Int) {
        guard gen == generation else { return }
        task = nil
        if let next = pending { pending = nil; launch(next) }
        else { progress = nil }
    }
}
