import Foundation

/// A `RelayObjectStore` backed by Google Drive — the production cloud relay. Maps each relay object NAME
/// (e.g. `g1__7.json`, `g1__7.jpg`, `_epoch.json`) to a Drive file in a per-session folder, carrying the
/// name in `appProperties.relayName` for querying. It slots into the SAME `FileRelayReceiver` loop the
/// FileRelay already proved — Drive is only the storage swap, so the never-lose contract is inherited.
///
/// Blocking (the receiver runs it off the main actor); `drive.file`-scoped, per-project (spike PASSED).
/// Live use is owner-gated (OAuth); unit-tested via a mock `HTTPExecuting` behind `DriveClient`.
/// `@unchecked Sendable`: the name→file cache is guarded by a lock (methods are also only ever called from
/// the receiver's single-flight `scanOnce`).
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

    func ensureSessionFolder() throws { lock.lock(); defer { lock.unlock() }; _ = try _ensureFolder() }

    func publishEpoch(_ data: Data) { writeAtomic(RelayObjectFormat.epochMarkerName, data) }

    func listNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        do { try _refreshCache() } catch { return [] }
        return Array(cache.keys)
    }

    func readData(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let id = try? _resolve(name) else { return nil }
        return try? client.getMedia(fileId: id)
    }

    func exists(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? _resolve(name)) != nil
    }

    func modificationDate(_ name: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if cache[name] == nil { try? _refreshCache() }
        return cache[name]?.modified
    }

    func writeAtomic(_ name: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        do {
            let fid = try _ensureFolder()
            let mime = name.hasSuffix(".jpg") ? "image/jpeg" : "application/json"
            if let existing = try _resolve(name) {                       // idempotent overwrite (re-send)
                try client.updateMedia(fileId: existing, media: data, mimeType: mime)
            } else {
                let id = try client.createFile(name: name, parents: [fid],
                                               appProperties: ["relayName": name, "relayToken": token],
                                               media: data, mimeType: mime)
                cache[name] = (id, nil)
            }
        } catch {
            // Best-effort: a failed write leaves no receipt, so the phone's receipt-wait times out and
            // retries — never a loss. (Mirrors the local store's silent-fail-then-retry.)
        }
    }

    func delete(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if let id = try? _resolve(name) { try? client.delete(fileId: id); cache[name] = nil }
    }

    func quarantine(_ name: String) {
        // Drive has no folders-as-move here; flag it out of listing instead (kept for debugging, excluded
        // from processing by _refreshCache's relayRejected filter).
        lock.lock(); defer { lock.unlock() }
        if let id = try? _resolve(name) {
            try? client.updateAppProperties(fileId: id, appProperties: ["relayName": name, "relayToken": token, "relayRejected": "1"])
            cache[name] = nil
        }
    }

    // MARK: Unlocked cores (callers hold `lock`)

    private func _ensureFolder() throws -> String {
        if let f = folderId { return f }
        let existing = try client.listFiles(
            query: "mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='relayToken' and value='\(esc(token))' } and trashed = false")
        if let f = existing.first { folderId = f.id; return f.id }
        let id = try client.createMetadata(name: folderName, parents: [],
                                           appProperties: ["relayToken": token, "relayFolder": "1"],
                                           mimeType: "application/vnd.google-apps.folder")
        folderId = id
        return id
    }

    private func _refreshCache() throws {
        let fid = try _ensureFolder()
        let files = try client.listFiles(query: "'\(esc(fid))' in parents and trashed = false")
        // Drive has NO name uniqueness: a fileId-loss re-create (phone recovery path) can leave two files
        // with the same relayName. Keep only the NEWEST per name (by monotone `rev`, then modifiedTime, then
        // fileId for determinism) and REAP the older duplicates in this one pass — so a stale-metadata version
        // can never be re-ingested by the receiver after a newer one (the "revert P10/date tags" hazard).
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
        cache = best.mapValues { (id: $0.id, modified: $0.mod) }
        for id in reap { try? client.delete(fileId: id) }
    }

    /// Resolve a relay name → fileId, refreshing the cache once on a miss.
    private func _resolve(_ name: String) throws -> String? {
        if let e = cache[name] { return e.id }
        try _refreshCache()
        return cache[name]?.id
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
