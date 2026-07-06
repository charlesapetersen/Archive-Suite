import Foundation
import Combine

/// Drives the background content-indexing of the library into `ContentIndex`, and answers full-text
/// queries. Indexing runs off the main actor (detached); @Published progress drives the UI.
@MainActor
final class ContentIndexer: ObservableObject {
    /// (done, total) while indexing; nil when idle.
    @Published private(set) var progress: (done: Int, total: Int)?

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

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveReader", isDirectory: true)
        // v2: the schema gained non-standard-PDF columns (page_count/has_text/readable). Because
        // unchanged files won't re-index into an old DB, bumping the *filename* makes the new schema a
        // clean full re-index — safe, since the index is an explicitly disposable/rebuildable cache.
        // (The stale content-index.sqlite3 is left in place: the write-surface lint bans file-delete
        // APIs app-wide, and the orphan is a rebuildable cache the user can clear.)
        index = ContentIndex(url: dir.appendingPathComponent("content-index-v2.sqlite3"))
    }

    /// Incrementally index the given files (skips unchanged content via `needsIndex`).
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
        task = Task.detached(priority: .utility) { [weak self] in
            try? await idx.open()
            let total = files.count
            await self?.report((0, total), gen)
            var done = 0
            for f in files {
                if Task.isCancelled { break }
                let path = f.url.path
                let mtime = f.contentModified?.timeIntervalSince1970 ?? 0
                if await idx.needsIndex(path: path, mtime: mtime) {
                    if let content = PDFTextExtractor.extract(f.url) {
                        try? await idx.upsert(path: path, mtime: mtime, name: f.name,
                                              classification: content.classification, body: content.body,
                                              pageCount: content.pageCount, hasText: !content.body.isEmpty, readable: true)
                    } else {
                        // Unreadable (corrupt / encrypted / non-PDF): still record it so it's surfaced as
                        // needing attention, and so we don't retry the failed extraction every pass.
                        try? await idx.upsert(path: path, mtime: mtime, name: f.name,
                                              classification: nil, body: "",
                                              pageCount: 0, hasText: false, readable: false)
                    }
                }
                done += 1
                if done % 100 == 0 || done == total { await self?.report((done, total), gen) }
            }
            await self?.finish(gen)
        }
    }

    /// Full-text search → set of matching file paths.
    func search(_ query: String) async -> Set<String> {
        try? await index.open()
        return Set(await index.search(query))
    }

    /// Classification (`Document Start`/`Continuation`/`Box`/`Folder`) per path, where indexed.
    func classifications(for paths: [String]) async -> [String: String] {
        try? await index.open()
        return await index.classifications(for: paths)
    }

    /// Non-standard-PDF status per path (unreadable / no-text-layer / standard), where indexed.
    func formatStatuses(for paths: [String]) async -> [String: PDFFormatStatus] {
        try? await index.open()
        return await index.formatFlags(for: paths)
    }

    /// Count of indexed files that need attention (unreadable or text-less).
    func needsAttentionCount() async -> Int {
        try? await index.open()
        return await index.needsAttentionCount()
    }

    /// Publish progress only for the current pass (a superseded/cancelled pass is ignored).
    private func report(_ p: (Int, Int)?, _ gen: Int) { guard gen == generation else { return } ; progress = p }

    /// Called when a pass ends. If it's still the current pass, clear the slot and drain any coalesced
    /// request; a superseded pass (cancelled or replaced) is ignored so it can't clobber newer state.
    private func finish(_ gen: Int) {
        guard gen == generation else { return }
        task = nil
        if let next = pending { pending = nil; launch(next) }
        else { progress = nil }
    }
}
