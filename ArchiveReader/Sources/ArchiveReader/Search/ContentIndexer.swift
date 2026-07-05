import Foundation
import Combine

/// Drives the background content-indexing of the library into `ContentIndex`, and answers full-text
/// queries. Indexing runs off the main actor (detached); @Published progress drives the UI.
@MainActor
final class ContentIndexer: ObservableObject {
    /// (done, total) while indexing; nil when idle.
    @Published private(set) var progress: (done: Int, total: Int)?

    private let index: ContentIndex
    private var running = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveReader", isDirectory: true)
        index = ContentIndex(url: dir.appendingPathComponent("content-index.sqlite3"))
    }

    /// Incrementally index the given files (skips unchanged). No-op if an index pass is already running.
    func startIndexing(_ files: [ArchiveFile]) {
        guard !running, !files.isEmpty else { return }
        running = true
        let idx = index
        Task.detached(priority: .utility) { [weak self] in
            try? await idx.open()
            let total = files.count
            await self?.setProgress((0, total))
            var done = 0
            for f in files {
                if Task.isCancelled { break }
                let path = f.url.path
                let mtime = f.contentModified?.timeIntervalSince1970 ?? 0
                if await idx.needsIndex(path: path, mtime: mtime),
                   let content = PDFTextExtractor.extract(f.url) {
                    try? await idx.upsert(path: path, mtime: mtime, name: f.name,
                                          classification: content.classification, body: content.body)
                }
                done += 1
                if done % 100 == 0 || done == total { await self?.setProgress((done, total)) }
            }
            await self?.finish()
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

    private func setProgress(_ p: (Int, Int)?) { progress = p }
    private func finish() { progress = nil; running = false }
}
