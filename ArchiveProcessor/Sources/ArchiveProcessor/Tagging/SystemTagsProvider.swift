import Foundation

/// Gathers the Finder tags currently in use anywhere in the user's files (via a Spotlight
/// `NSMetadataQuery`) and offers prefix-based autocomplete suggestions for manual tagging.
/// Warm this up when a manual tagging mode is selected so results are ready by review time.
@MainActor
final class SystemTagsProvider: ObservableObject {
    static let shared = SystemTagsProvider()

    @Published private(set) var tags: [String] = []

    private var query: NSMetadataQuery?
    private var started = false

    private init() {}

    /// Kick off the Spotlight query. Safe to call repeatedly — only the first call starts it.
    func warmUp() {
        guard !started else { return }
        started = true

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.predicate = NSPredicate(format: "kMDItemUserTags LIKE %@", "*")
        NotificationCenter.default.addObserver(
            self, selector: #selector(gather(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.addObserver(
            self, selector: #selector(gather(_:)),
            name: .NSMetadataQueryDidUpdate, object: q)
        query = q
        q.start()
    }

    @objc private func gather(_ note: Notification) {
        guard let q = query else { return }
        q.disableUpdates()
        var set = Set(tags)
        for i in 0..<q.resultCount {
            if let item = q.result(at: i) as? NSMetadataItem,
               let itemTags = item.value(forAttribute: "kMDItemUserTags") as? [String] {
                for tag in itemTags {
                    // Finder color tags can carry a "\n<index>" suffix in some sources — strip it.
                    let name = tag.components(separatedBy: "\n").first ?? tag
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { set.insert(trimmed) }
                }
            }
        }
        tags = set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        q.enableUpdates()
    }

    /// Prefix-first, then substring suggestions (case-insensitive), excluding already-chosen tags.
    func suggestions(prefix: String, excluding: [String] = [], limit: Int = 8) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let chosen = Set(excluding.map { $0.lowercased() })
        let pool = tags.filter { !chosen.contains($0.lowercased()) }
        guard !p.isEmpty else { return Array(pool.prefix(limit)) }
        let prefixMatches = pool.filter { $0.lowercased().hasPrefix(p) }
        let substringMatches = pool.filter { !$0.lowercased().hasPrefix(p) && $0.lowercased().contains(p) }
        return Array((prefixMatches + substringMatches).prefix(limit))
    }

    /// Register tags the user creates this session so they appear in later suggestions.
    func register(_ newTags: [String]) {
        var set = Set(tags)
        for t in newTags {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { set.insert(trimmed) }
        }
        tags = set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
