import Foundation

/// Durable session persistence so nothing captured is lost before it reaches the Mac (archival photos
/// can't be re-taken). Mirrors the Android SessionStore.
struct SessionStore {
    /// A document segment the operator has ended whose segment-complete signal the Mac hasn't acked yet.
    /// Persisted so an app-kill between End segment and the ack can't strand the document.
    struct EndedSeg: Codable {
        var group: String
        var quality: String?
        var year: Int?
        var month: Int?
        /// Comma-joined page seqs snapshotted at End-segment (SPEC A5).
        var seqs: String?
    }

    struct Snapshot: Codable {
        var items: [CapturedItem]
        var seq: Int
        var nextId: Int64
        var groupId: String?
        /// Non-nil only if the app was mid-tagging a segment when it stopped — so recovery re-opens the
        /// tag card only in that case, not when the user was still shooting an unfinished segment.
        var pendingTagGroupId: String?
        /// Ended-but-unacked segments.
        var endedSegments: [EndedSeg]?
    }

    private let url: URL
    /// Where unsent photos live: Application Support/capture, which iOS never empties (Caches, where they used to
    /// be, may be emptied when storage runs low). Excluded from backup: a photo leaves the phone once the Mac
    /// confirms it. Items persist their file NAME only and are resolved here on load.
    let photoDirectory: URL

    init() {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("capture-session.json")
        var photos = dir.appendingPathComponent("capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? photos.setResourceValues(values)
        photoDirectory = photos
    }

    /// A store at an explicit file and photo directory, for the host tests (`scripts/test-ios-capture-queue.sh`).
    init(url: URL, photoDirectory: URL) { self.url = url; self.photoDirectory = photoDirectory }

    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.userInfo[CapturedItem.photoDirectoryKey] = photoDirectory
        return try? decoder.decode(Snapshot.self, from: data)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
