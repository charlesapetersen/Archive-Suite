import Foundation

/// A `RelayObjectStore` backed by Google Drive — the production cloud relay. Maps each relay object NAME
/// (e.g. `g1__7.json`, `g1__7.jpg`, `_epoch.json`) to a Drive file in a per-session folder, carrying the
/// name in `appProperties.relayName` for querying. It slots into the SAME `FileRelayReceiver` loop the
/// FileRelay already proved — Drive is only the storage swap, so the never-lose contract is inherited.
///
/// Blocking (the receiver runs it off the main actor); `drive.file`-scoped, per-project (spike PASSED).
/// Live use is owner-gated (OAuth); unit-tested via a mock `HTTPExecuting` behind `DriveClient`.
/// `@unchecked Sendable`: the name→file cache is guarded by a lock (methods are also only ever called from
/// the receiver's single-flight `scanOnce`). Network calls are made OUTSIDE the lock to avoid blocking
/// other accessors during slow HTTP round-trips.
final class DriveObjectStore: RelayObjectStore, @unchecked Sendable {
    private let client: DriveClient
    private let token: String
    private let folderName: String
    private var folderId: String?
    private var cache: [String: (id: String, modified: Date?)] = [:]   // relayName → (fileId, modifiedTime)
    private let lock = NSLock()

    init(client: DriveClient, token: String) {
        self.client = client
        self.token = token
        self.folderName = "Archive Processor Live Capture \(token)"
    }

    // MARK: RelayObjectStore

    func ensureSessionFolder() throws {
        // Check cache under lock first.
        lock.lock()
        if folderId != nil { lock.unlock(); return }
        lock.unlock()
        // Network call (unlocked) + cache update.
        let id = try _ensureFolderUnlocked()
        lock.lock(); folderId = id; lock.unlock()
    }

    func publishEpoch(_ data: Data) { writeAtomic(RelayObjectFormat.epochMarkerName, data) }

    func listNames() -> [String] {
        do { try _refreshCacheUnlocked() } catch { return [] }
        lock.lock(); defer { lock.unlock() }
        return Array(cache.keys)
    }

    func readData(_ name: String) -> Data? {
        // Resolve the file ID under lock, then download without the lock held.
        guard let id = _resolveLocked(name) else { return nil }
        return try? client.getMedia(fileId: id)
    }

    func exists(_ name: String) -> Bool {
        return _resolveLocked(name) != nil
    }

    func modificationDate(_ name: String) -> Date? {
        lock.lock()
        if cache[name] == nil {
            lock.unlock()
            try? _refreshCacheUnlocked()
            lock.lock()
        }
        let result = cache[name]?.modified
        lock.unlock()
        return result
    }

    func writeAtomic(_ name: String, _ data: Data) {
        do {
            let fid = try _ensureFolderUnlocked()
            lock.lock(); folderId = fid; lock.unlock()

            let mime = name.hasSuffix(".jpg") ? "image/jpeg" : "application/json"
            let existing = _resolveLocked(name)

            // Network call (unlocked).
            if let existing {
                try client.updateMedia(fileId: existing, media: data, mimeType: mime)
            } else {
                let id = try client.createFile(name: name, parents: [fid],
                                               appProperties: ["relayName": name, "relayToken": token],
                                               media: data, mimeType: mime)
                lock.lock(); cache[name] = (id, nil); lock.unlock()
            }
        } catch {
            // Best-effort: a failed write leaves no receipt, so the phone's receipt-wait times out and
            // retries — never a loss. (Mirrors the local store's silent-fail-then-retry.)
        }
    }

    func delete(_ name: String) {
        guard let id = _resolveLocked(name) else { return }
        try? client.delete(fileId: id)
        lock.lock(); cache[name] = nil; lock.unlock()
    }

    func quarantine(_ name: String) {
        // Drive has no folders-as-move here; flag it out of listing instead (kept for debugging, excluded
        // from processing by _refreshCache's relayRejected filter).
        guard let id = _resolveLocked(name) else { return }
        try? client.updateAppProperties(fileId: id, appProperties: ["relayName": name, "relayToken": token, "relayRejected": "1"])
        lock.lock(); cache[name] = nil; lock.unlock()
    }

    // MARK: Lock-aware helpers

    /// Resolve a relay name → fileId. Acquires/releases the lock internally; network calls (cache refresh)
    /// happen outside the lock.
    private func _resolveLocked(_ name: String) -> String? {
        lock.lock()
        if let e = cache[name] { lock.unlock(); return e.id }
        lock.unlock()
        // Cache miss — refresh (unlocked network) then re-check.
        try? _refreshCacheUnlocked()
        lock.lock()
        let result = cache[name]?.id
        lock.unlock()
        return result
    }

    /// Ensure the session folder exists on Drive. Does NOT hold the lock during network calls.
    /// Returns the folder ID; caller should store it under lock.
    private func _ensureFolderUnlocked() throws -> String {
        lock.lock()
        if let f = folderId { lock.unlock(); return f }
        lock.unlock()

        let existing = try client.listFiles(
            query: "mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='relayToken' and value='\(esc(token))' } and trashed = false")
        if let f = existing.first {
            lock.lock(); folderId = f.id; lock.unlock()
            return f.id
        }
        let id = try client.createMetadata(name: folderName, parents: [],
                                           appProperties: ["relayToken": token, "relayFolder": "1"],
                                           mimeType: "application/vnd.google-apps.folder")
        lock.lock(); folderId = id; lock.unlock()
        return id
    }

    /// Refresh the name→fileId cache from Drive. Network calls happen outside the lock; the cache is
    /// replaced atomically under lock once the listing completes.
    private func _refreshCacheUnlocked() throws {
        let fid = try _ensureFolderUnlocked()
        let files = try client.listFiles(query: "'\(esc(fid))' in parents and trashed = false")
        // Drive has NO name uniqueness: a fileId-loss re-create (phone recovery path) can leave two files
        // with the same relayName. Keep only the NEWEST per name (by monotone `rev`, then modifiedTime, then
        // fileId for determinism) and REAP the older duplicates in this one pass — so a stale-metadata version
        // can never be re-ingested by the receiver after a newer one (the "revert Q3/date tags" hazard).
        var best: [String: (rev: Int, mod: Date?, id: String)] = [:]
        var reap: [String] = []
        for f in files {
            guard let name = f.appProperties?["relayName"], f.appProperties?["relayRejected"] != "1" else { continue }
            let cand = (rev: Int(f.appProperties?["rev"] ?? "") ?? -1, mod: parseTime(f.modifiedTime), id: f.id)
            if let cur = best[name] {
                if (cand.rev, cand.mod ?? .distantPast, cand.id) > (cur.rev, cur.mod ?? .distantPast, cur.id) {
                    reap.append(cur.id); best[name] = cand
                } else { reap.append(f.id) }
            } else { best[name] = cand }
        }
        lock.lock()
        cache = best.mapValues { (id: $0.id, modified: $0.mod) }
        lock.unlock()
        // Reap duplicates (unlocked — these are fire-and-forget deletes).
        for id in reap { try? client.delete(fileId: id) }
    }

    private func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "\\'") }

    private func parseTime(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? {
            let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]; return g.date(from: s)
        }()
    }
}
