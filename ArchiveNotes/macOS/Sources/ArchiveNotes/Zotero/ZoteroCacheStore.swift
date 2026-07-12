import Foundation

/// Disposable on-disk cache for Zotero CSL metadata and formatted citations.
/// The authoritative survivor is `ZoteroRef.citation` in front-matter (00-overview §D.6).
/// This cache accelerates repeated lookups within and across sessions.
actor ZoteroCacheStore {

    struct Entry: Codable, Sendable {
        var csl: ZoteroCSLItem
        var citation: String?
        var styleID: String?
        var fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("zotero-cache-v1.json")
    }

    // MARK: - Load / save

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        entries = decoded
    }

    func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Accessors

    func get(_ key: String) -> Entry? {
        entries[key]
    }

    func set(_ key: String, entry: Entry) {
        entries[key] = entry
    }

    func removeAll() {
        entries.removeAll()
    }

    var count: Int { entries.count }

    /// Build a cache key from a ZoteroRef: "<libToken>/<itemKey>".
    static func cacheKey(for ref: ZoteroRef) -> String {
        let libToken: String
        switch ref.library {
        case .user: libToken = "library"
        case .group(let gid): libToken = String(gid)
        }
        return "\(libToken)/\(ref.itemKey)"
    }
}
