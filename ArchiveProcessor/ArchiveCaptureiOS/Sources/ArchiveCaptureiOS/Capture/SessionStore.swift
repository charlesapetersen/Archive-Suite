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
    /// W23.m8's port (W40.i-fix-ios-session-durability): the publish-in-progress flag. Created BEFORE a snapshot is
    /// written and removed only once that write is on disk, so finding it at launch means the session file about
    /// to be restored is OLDER than the state the app last held. That matters because restore adopts photos the
    /// file doesn't list, and against a stale file those photos are not untracked at all: they are pages whose
    /// box/folder and tags went down with the write. Set before the write rather than on failure, because a kill
    /// during the write leaves the same older file behind and must read the same way. Mirrors Android's
    /// `session.stale`.
    private let staleMarker: URL
    /// Where unsent photos live: Application Support/capture, which iOS never empties (Caches, where they used to
    /// be, may be emptied when storage runs low). Excluded from backup: a photo leaves the phone once the Mac
    /// confirms it. Items persist their file NAME only and are resolved here on load.
    let photoDirectory: URL
    /// How finished snapshot bytes reach disk. Injectable so a host test can fail a write the way a full volume
    /// does, without needing one (Android's `publish`).
    private let publish: (Data, URL) -> Bool

    init() {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var photos = dir.appendingPathComponent("capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? photos.setResourceValues(values)
        self.init(url: dir.appendingPathComponent("capture-session.json"), photoDirectory: photos)
    }

    /// A store at an explicit file and photo directory, for the host tests (`scripts/test-ios-capture-queue.sh`).
    init(url: URL, photoDirectory: URL, publish: @escaping (Data, URL) -> Bool = SessionStore.replaceDurably) {
        self.url = url
        self.photoDirectory = photoDirectory
        self.publish = publish
        staleMarker = url.deletingPathExtension().appendingPathExtension("stale")
    }

    /// Write a snapshot. True only when THIS snapshot is on disk; false means the file still holds an older state,
    /// and the caller must treat what it holds in memory as unsaved and say so. Never throws: a persistence hiccup
    /// must not stop capture, but it must not pass for success either. Blocking file I/O: call it off the main
    /// thread (`CaptureViewModel`'s session writer).
    func save(_ snapshot: Snapshot) -> Bool {
        if !FileManager.default.fileExists(atPath: staleMarker.path) {
            FileManager.default.createFile(atPath: staleMarker.path, contents: nil)
        }
        guard let data = try? JSONEncoder().encode(snapshot), publish(data, url) else { return false }
        try? FileManager.default.removeItem(at: staleMarker)
        return true
    }

    /// True when the session file is known to be older than the state the app last held (a write failed, or the
    /// app died inside one). Read it BEFORE anything can save: the first successful save clears it.
    func manifestIsStale() -> Bool { FileManager.default.fileExists(atPath: staleMarker.path) }

    /// What `loadSession` found.
    struct Loaded {
        /// The restored session, or nil if there was none or it could not be read.
        var snapshot: Snapshot?
        /// A session file existed but could not be read. Its photos are now unlisted and their classification is
        /// unknown, which is the same position as a stale file, so the caller holds them for review.
        var unreadable = false
        /// Where an unreadable file was set aside, if the move worked.
        var setAside: URL?
    }

    /// Read the session file. One that exists but can't be read or decoded is moved aside under a new name rather
    /// than returned as nothing: as nothing, the next save would overwrite the only record of those photos. Moved
    /// aside, the file survives for a person to read and its photos are found by orphan adoption.
    func loadSession() -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded() }
        let decoder = JSONDecoder()
        decoder.userInfo[CapturedItem.photoDirectoryKey] = photoDirectory
        if let data = try? Data(contentsOf: url), let snap = try? decoder.decode(Snapshot.self, from: data) {
            return Loaded(snapshot: snap)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
        return Loaded(snapshot: nil, unreadable: true, setAside: moved ? aside : nil)
    }

    /// `loadSession`'s snapshot alone. Still moves an unreadable file aside.
    func load() -> Snapshot? { loadSession().snapshot }

    /// Remove the session and its stale flag: a session that no longer exists has nothing to be stale about, and a
    /// flag left behind would make the next launch hold a fresh session's own photos.
    func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: staleMarker)
    }

    /// The default write: a temporary file in the same directory, synced to storage, then renamed over the old
    /// file, so a reader sees the old snapshot or the new one and never part of one (Android's
    /// `ManifestFileWriter.replace`). Survives the app being killed; like Android's, not a power cut mid-rename.
    static func replaceDurably(_ data: Data, _ url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmp) else { return false }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        guard rename(tmp.path, url.path) == 0 else { try? FileManager.default.removeItem(at: tmp); return false }
        return true
    }
}
