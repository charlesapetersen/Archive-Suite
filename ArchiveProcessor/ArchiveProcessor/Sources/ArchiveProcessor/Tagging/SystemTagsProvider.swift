import Foundation

/// Gathers the Finder tags currently in use anywhere in the user's files (via a Spotlight
/// `NSMetadataQuery`) and offers prefix-based autocomplete suggestions for manual tagging.
/// Warm this up when a tagging UI appears so results are ready by review time.
///
/// The Spotlight gather can enumerate *thousands* of tagged files, so the result iteration runs
/// on a private background operation queue — never the main thread — and only the published `tags`
/// array is updated back on the main actor. (Doing this work on the main actor beachballs the app
/// on a heavily-tagged home folder.)
final class SystemTagsProvider: ObservableObject, @unchecked Sendable {
    static let shared = SystemTagsProvider()

    /// Only ever mutated on the main actor (see `register` and the gather hop below).
    @Published private(set) var tags: [String] = []

    private let query = NSMetadataQuery()
    private let gatherQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    private var started = false          // only touched on the main actor (warmUp)

    private init() {
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "kMDItemUserTags LIKE %@", "*")
        // Gather + notifications happen on this background queue, keeping the main thread free.
        query.operationQueue = gatherQueue
        NotificationCenter.default.addObserver(
            self, selector: #selector(gather(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(
            self, selector: #selector(gather(_:)),
            name: .NSMetadataQueryDidUpdate, object: query)
    }

    /// Kick off the Spotlight query. Safe to call repeatedly — only the first call starts it.
    @MainActor func warmUp() {
        guard !started else { return }
        started = true
        query.start()   // must be started from the main thread; gathering runs on gatherQueue
    }

    /// Runs on `gatherQueue` (background). Iterating the results here keeps the main thread
    /// responsive; the merged set is then published on the main actor.
    @objc private func gather(_ note: Notification) {
        query.disableUpdates()
        var set = Set<String>()
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let itemTags = item.value(forAttribute: "kMDItemUserTags") as? [String] {
                for tag in itemTags {
                    // Finder color tags can carry a "\n<index>" suffix in some sources — strip it.
                    let name = tag.components(separatedBy: "\n").first ?? tag
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { set.insert(trimmed) }
                }
            }
        }
        query.enableUpdates()
        let gathered = set
        // Merge on the main actor so session-registered tags are preserved across updates.
        Task { @MainActor in
            var merged = Set(self.tags)
            merged.formUnion(gathered)
            self.tags = merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    /// Prefix-first, then substring suggestions (case-insensitive), excluding already-chosen tags.
    @MainActor func suggestions(prefix: String, excluding: [String] = [], limit: Int = 8) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let chosen = Set(excluding.map { $0.lowercased() })
        let pool = tags.filter { !chosen.contains($0.lowercased()) }
        guard !p.isEmpty else { return Array(pool.prefix(limit)) }
        let prefixMatches = pool.filter { $0.lowercased().hasPrefix(p) }
        let substringMatches = pool.filter { !$0.lowercased().hasPrefix(p) && $0.lowercased().contains(p) }
        return Array((prefixMatches + substringMatches).prefix(limit))
    }

    /// Register tags the user creates this session so they appear in later suggestions.
    @MainActor func register(_ newTags: [String]) {
        var set = Set(tags)
        for t in newTags {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { set.insert(trimmed) }
        }
        tags = set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
