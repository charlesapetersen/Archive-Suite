import Foundation

/// Durable session persistence so nothing captured is lost before it reaches the Mac (archival photos
/// can't be re-taken). Mirrors the Android SessionStore.
struct SessionStore {
    struct Snapshot: Codable {
        var items: [CapturedItem]
        var seq: Int
        var nextId: Int64
        var groupId: String?
    }

    private let url: URL

    init() {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("capture-session.json")
    }

    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
