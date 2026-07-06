import Foundation
import AppKit

/// Owns a live-capture session: the incoming folder, the pairing token, the received photos
/// (grouped as the phone marked them), and the receiver server lifecycle. The `CaptureServer`
/// calls `ingest(...)` for each photo; the UI observes the published state and hands the
/// grouped result off to the OCR pipeline.
@MainActor
final class CaptureSession: ObservableObject {
    @Published private(set) var photos: [CapturedPhoto] = []      // ordered by seq
    @Published private(set) var serverRunning = false
    @Published private(set) var listenPort: UInt16 = 0
    @Published private(set) var lastActivity: Date?
    @Published var statusMessage = "Idle"
    @Published private(set) var connectedDeviceName: String?

    /// Mac operator's per-segment tags entered during capture (groupId → tags), plus the set of
    /// document groups already tagged or skipped on the Mac (drives the auto-advancing card).
    @Published private(set) var macTags: [String: MacSegmentTags] = [:]
    @Published private(set) var resolvedGroupIds: Set<String> = []
    /// Document groups the phone has signalled complete (via `POST /segment/complete` at End segment).
    /// Photos now stream to the Mac page-by-page as they are shot, so a document group exists mid-segment;
    /// its tag card must appear only once the segment is complete — this gates `pendingTagGroup`.
    @Published private(set) var completedDocGroups: Set<String> = []

    // MARK: - Live processing mode (streaming vs. batch handoff)

    /// How this session's captures are processed. Resolved on first activity from the app-wide
    /// **Settings** choice (`liveProcessingMode`), then fixed for the session.
    enum LiveProcessingMode: String { case undecided, stageForLater, live }
    @Published private(set) var processingMode: LiveProcessingMode = .undecided
    /// The snapshotted processing settings for a `.live` session (nil until activated).
    @Published private(set) var config: SessionProcessingConfig?
    /// Set once the first segment begins processing (the config is already snapshotted).
    @Published private(set) var settingsLocked = false
    /// True once a phone has paired (pinged) or sent a photo — used to hide the QR.
    @Published private(set) var paired = false

    /// Streaming coordinator (created on first use). Processes each segment during a `.live` session.
    private(set) lazy var liveProcessor = LiveCaptureProcessor(session: self)

    /// The user's app-wide choice (Settings ⌘,): stream each segment live, or stage for a later batch run.
    private var liveModeEnabled: Bool { UserDefaults.standard.string(forKey: DefaultsKeys.liveProcessingMode) == "live" }

    /// On first activity, fix the session's processing mode from Settings and — for live — snapshot
    /// the config so mid-session Settings changes don't affect the running session.
    func activateProcessingIfNeeded() {
        guard processingMode == .undecided else { return }
        if liveModeEnabled {
            let cfg = SessionProcessingConfig.fromDefaults()
            config = cfg
            processingMode = .live
            liveProcessor.activate(config: cfg)
        } else {
            processingMode = .stageForLater
        }
    }

    func markPaired() { paired = true }
    /// Re-show the pairing QR (e.g. to pair a different phone); doesn't disconnect the current one.
    func unpairDisplay() { paired = false }

    /// Start a live session with an explicit config (used by the headless test driver).
    func beginLiveSession(config: SessionProcessingConfig) {
        self.config = config
        processingMode = .live
        liveProcessor.activate(config: config)
    }

    /// Called by the streaming coordinator when the first segment begins processing.
    func lockSettings() { if config != nil { settingsLocked = true } }

    /// Short, easy-to-type bearer token the phone presents (shown in the pairing QR, and typeable
    /// for USB/manual pairing). **Stable across launches** (persisted) so a paired phone keeps
    /// working without re-pairing. LAN/USB-local transport only, so a short code is fine.
    let token = CaptureSession.loadOrCreateToken()

    /// 6 chars from an unambiguous alphabet (no 0/O/1/I/L), persisted in UserDefaults.
    private static func loadOrCreateToken() -> String {
        let key = "LiveCaptureToken"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count == 6 { return existing }
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let t = String((0..<6).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    /// Session id + this session's incoming folder (a per-run subfolder of `backupRoot`). Every photo
    /// received from the phone is written here and kept until the run's output is fully finalized — a
    /// user-visible backup so the originals can be recovered even if the app fails catastrophically.
    let sessionId: String
    let incomingFolder: URL

    /// Durable, user-VISIBLE parent for all Live Capture session folders: `~/Pictures/Archive Processor
    /// Live Capture/`. Kept in Pictures (not the hidden Application Support container) so the operator can
    /// find and copy the raw photos in Finder — including if the app won't launch. Falls back to
    /// Application Support only if the Pictures directory is somehow unavailable.
    static var backupRoot: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Archive Processor Live Capture", isDirectory: true)
    }

    /// Pre-visible-backup location (older builds stored sessions here). Any session left here is
    /// migrated into the visible backupRoot on launch (see migrateLegacySessions) so it's never orphaned
    /// and — critically — so its further photos also land in the Finder-discoverable folder.
    private static var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveProcessor/LiveCapture", isDirectory: true)
    }

    private lazy var server = CaptureServer(session: self)

    init() {
        let root = Self.backupRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Move any in-flight session left by an older build into the VISIBLE root, so its photos are
        // Finder-discoverable and every further ingest for it lands there too (not the hidden container).
        Self.migrateLegacySessions(into: root)
        // Drop leftover empty session folders (their photos were already cleared at a successful finalize)
        // so the visible backup root doesn't accumulate clutter that buries the run that still has photos.
        // Runs before recovery, so it can never touch the active session (which has photos, or is fresh).
        Self.pruneEmptySessions(under: root)

        // Crash recovery: reload the newest session that still has received-but-unprocessed photos (a
        // manifest + files on disk) so a Mac crash never orphans received data; else start fresh.
        if let restored = Self.latestUnprocessedSession(under: root) {
            sessionId = restored.folder.lastPathComponent
            incomingFolder = restored.folder
            photos = restored.photos
        } else {
            sessionId = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            incomingFolder = root.appendingPathComponent(sessionId, isDirectory: true)
            try? FileManager.default.createDirectory(at: incomingFolder, withIntermediateDirectories: true)
        }
    }

    // MARK: - Server lifecycle

    func start() {
        guard !serverRunning else { return }
        server.start()
    }

    func stop() {
        server.stop()
    }

    /// Called by the server (already hopped to the main actor) when it binds/unbinds.
    func serverDidStart(port: UInt16) {
        listenPort = port
        serverRunning = true
        statusMessage = "Listening on port \(port). Scan the QR on the phone to connect."
        if ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" {
            let line = "LIVECAPTURE_READY port=\(port) token=\(token) folder=\(incomingFolder.path)\n"
            if let path = ProcessInfo.processInfo.environment["LIVECAPTURE_READYFILE"] {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            FileHandle.standardError.write(Data(line.utf8))
        }
        // Keep the USB reverse tunnel asserted (re-asserted on a timer so a replug self-heals).
        USBBridge.startReverse(port: port)
    }

    func serverDidStop() {
        serverRunning = false
        statusMessage = "Stopped."
        USBBridge.stopReverse()
    }

    func serverDidFail(_ message: String) {
        serverRunning = false
        statusMessage = "Server error: \(message)"
    }

    // MARK: - Ingestion

    /// Persist a received photo into the session folder and record it. Returns the saved URL,
    /// or nil if the write failed. Uses temp→rename so any folder watcher sees a complete file.
    @discardableResult
    func ingest(jpeg: Data, groupId: String, seq: Int, type: CaptureGroupType,
                priority: String?, year: Int?, month: Int?, deviceName: String?) -> URL? {
        let name = String(format: "%05d-%@.jpg", seq, groupId)
        let finalURL = incomingFolder.appendingPathComponent(name)
        let tempURL = incomingFolder.appendingPathComponent("." + name + ".part")
        do {
            try jpeg.write(to: tempURL, options: .atomic)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        let photo = CapturedPhoto(url: finalURL, groupId: groupId, seq: seq, type: type, receivedAt: Date(),
                                  priority: priority, year: year, month: month)
        // Idempotent re-upload (phone resume after a crash): replace an existing same-group+seq
        // photo instead of duplicating it. Otherwise keep the list ordered by seq.
        if let existing = photos.firstIndex(where: { $0.groupId == groupId && $0.seq == seq }) {
            photos[existing] = photo
        } else if let idx = photos.firstIndex(where: { $0.seq > seq }) {
            photos.insert(photo, at: idx)
        } else {
            photos.append(photo)
        }
        lastActivity = Date()
        connectedDeviceName = deviceName ?? connectedDeviceName
        statusMessage = "Received \(photos.count) photo\(photos.count == 1 ? "" : "s")" + (deviceName.map { " from \($0)" } ?? "")
        // New capture began — drop any prior "Finalized …" summary so the Captured pane shows photos.
        liveProcessor.clearFinalizeSummary()
        paired = true
        // Durability contract: only acknowledge success (→ phone deletes its only copy of an
        // un-retakeable archival photo) once the grouping/tag metadata is durably persisted. If the
        // manifest write fails, return nil → server responds 500 → phone retries. The JPEG is already
        // on disk and idempotent replace makes the retry safe; live processing waits until durable.
        guard writeManifest() else { return nil }
        activateProcessingIfNeeded()   // fix mode from Settings on first photo
        if processingMode == .live { liveProcessor.photoIngested(photo) }   // start OCR on arrival
        return finalURL
    }

    func removePhoto(_ photo: CapturedPhoto) {
        try? FileManager.default.removeItem(at: photo.url)
        photos.removeAll { $0.id == photo.id }
        writeManifest()
    }

    /// Remove a previously-received photo identified by (groupId, seq). Used when the phone reclassifies
    /// an already-uploaded photo into a new group (`X-Replaces`), so the old copy isn't orphaned on the
    /// Mac. Skipped in live mode once that group has been finalized/staged (removing a staged segment's
    /// source would corrupt staging); a no-op if not present.
    func removePhotoIfSafe(groupId: String, seq: Int) {
        if processingMode == .live && liveProcessor.isFinalized(groupId) { return }
        guard let idx = photos.firstIndex(where: { $0.groupId == groupId && $0.seq == seq }) else { return }
        try? FileManager.default.removeItem(at: photos[idx].url)
        photos.remove(at: idx)
        writeManifest()
    }

    func clear() {
        for p in photos { try? FileManager.default.removeItem(at: p.url) }
        photos = []
        completedDocGroups.removeAll()
        writeManifest()
        statusMessage = serverRunning ? "Listening on port \(listenPort)." : "Idle"
    }

    /// Finalize cleanup: delete ONLY the source photos that were actually filed into output (their URLs
    /// in `filed`). Any received-but-unfiled page — e.g. a page that streamed in and arrived after its
    /// segment had already been staged (a straggler) — is KEPT: deleting it would permanently lose an
    /// irreplaceable photo. Kept pages stay in the backup folder + the Captured pane so the operator can
    /// re-Process them. (Data-safety guard for per-capture streaming.)
    func clearFiled(_ filed: Set<URL>) {
        let removed = photos.filter { filed.contains($0.url) }
        for p in removed { try? FileManager.default.removeItem(at: p.url) }
        photos = photos.filter { !filed.contains($0.url) }
        if photos.isEmpty { completedDocGroups.removeAll() }
        writeManifest()
        statusMessage = serverRunning ? "Listening on port \(listenPort)." : "Idle"
    }

    /// Reveal this session's backup folder in Finder. Every photo the phone sends is stored there until
    /// the run's output is fully written, so the operator can recover/copy the originals if anything
    /// fails. Selects the current session folder inside its (visible) parent; if it doesn't exist yet,
    /// opens the parent so the backup location is still discoverable.
    func revealBackupFolder() {
        if FileManager.default.fileExists(atPath: incomingFolder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([incomingFolder])
        } else {
            let root = Self.backupRoot
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    // MARK: - Grouping / handoff

    /// Photos grouped as the phone marked them, in capture order.
    var groups: [CaptureGroup] {
        var byId: [String: CaptureGroup] = [:]
        for p in photos {
            if var g = byId[p.groupId] {
                g.photos.append(p)
                byId[p.groupId] = g
            } else {
                byId[p.groupId] = CaptureGroup(id: p.groupId, type: p.type, photos: [p])
            }
        }
        return byId.values
            .map { var g = $0; g.photos.sort { $0.seq < $1.seq }; return g }
            .sorted { $0.order < $1.order }
    }

    // MARK: - Mac-side tagging (auto-advancing card)

    /// The next document group ready for the Mac tag card: **complete** (the phone signalled End
    /// segment via `markSegmentComplete`) and not yet resolved. Pages stream in as shot, so a group
    /// exists mid-segment — gating on `completedDocGroups` keeps the card from popping before the
    /// segment is finished. Box/folder markers need no card (finalized on arrival).
    var pendingTagGroup: CaptureGroup? {
        groups.first { $0.type == .document && completedDocGroups.contains($0.id) && !resolvedGroupIds.contains($0.id) }
    }

    /// The phone ended a document segment (`POST /segment/complete`): attach the segment's tags to its
    /// already-streamed pages (so the tag card pre-fills), then mark it complete so the card appears.
    /// A per-page `P10` already on a photo (streamed with it) is never downgraded. Idempotent: re-sending
    /// the same signal (retry) just re-applies the same tags + is a no-op on the completed set.
    func markSegmentComplete(groupId: String, priority: String?, year: Int?, month: Int?) {
        var changed = false
        for i in photos.indices where photos[i].groupId == groupId {
            if year != nil { photos[i].year = year }
            if month != nil { photos[i].month = month }
            if photos[i].priority != "P10", let priority, !priority.isEmpty { photos[i].priority = priority }
            changed = true
        }
        completedDocGroups.insert(groupId)
        if changed { _ = writeManifest() }
    }

    /// Finish (`POST /session/complete`): surface the tag card for any document segment still open — e.g.
    /// the last segment if the operator finished without tapping End segment — so nothing is stranded.
    func completeAllOpenDocGroups() {
        for g in groups where g.type == .document && !resolvedGroupIds.contains(g.id) {
            completedDocGroups.insert(g.id)
        }
    }

    func applyMacTags(groupId: String, subjects: [String], priority: String?, year: Int?, month: Int?) {
        macTags[groupId] = MacSegmentTags(subjects: subjects, priority: priority, year: year, month: month)
        resolvedGroupIds.insert(groupId)
        if processingMode == .live { liveProcessor.segmentResolved(groupId: groupId) }
    }

    func skipMacTags(groupId: String) {
        resolvedGroupIds.insert(groupId)
        if processingMode == .live { liveProcessor.segmentResolved(groupId: groupId) }
    }

    /// Ordered file URLs + per-group boundary/type/tag info for the OCR pre-grouped handoff.
    func orderedFilesAndGroups() -> (files: [URL], boundaries: [Bool], types: [CaptureGroupType],
                                     priorities: [String?], years: [Int?], months: [Int?], subjects: [[String]]) {
        var files: [URL] = []
        var boundaries: [Bool] = []
        var types: [CaptureGroupType] = []
        var priorities: [String?] = []
        var years: [Int?] = []
        var months: [Int?] = []
        var subjects: [[String]] = []
        for group in groups {
            let mac = macTags[group.id]
            for (i, photo) in group.photos.enumerated() {
                files.append(photo.url)
                boundaries.append(i == 0)          // first photo of a group starts a segment
                types.append(group.type)
                // Per-page P10 (phone) wins; else the Mac operator's group priority; else phone value.
                priorities.append(photo.priority == "P10" ? "P10" : (mac?.priority ?? photo.priority))
                years.append(mac?.year ?? group.year)     // Mac date override wins over the phone's
                months.append(mac?.month ?? group.month)
                subjects.append(mac?.subjects ?? [])       // Mac-entered subjects (empty if untagged)
            }
        }
        return (files, boundaries, types, priorities, years, months, subjects)
    }

    // MARK: - Durable manifest (crash recovery)

    private struct ManifestEntry: Codable {
        let name: String
        let groupId: String
        let seq: Int
        let type: String
        let priority: String?
        let year: Int?
        let month: Int?
    }

    private var manifestURL: URL { incomingFolder.appendingPathComponent("manifest.json") }

    /// Persist per-photo metadata so a Mac crash doesn't lose grouping/tags (the JPEGs don't carry it).
    /// Returns whether the write succeeded, so `ingest` can withhold the success ack until the
    /// grouping metadata is durably on disk.
    @discardableResult
    private func writeManifest() -> Bool {
        let entries = photos.map {
            ManifestEntry(name: $0.url.lastPathComponent, groupId: $0.groupId, seq: $0.seq,
                          type: $0.type.rawValue, priority: $0.priority, year: $0.year, month: $0.month)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        do { try data.write(to: manifestURL, options: .atomic); return true }
        catch { return false }
    }

    /// Newest session folder that still has photos + a manifest (received but not yet cleared).
    private static func latestUnprocessedSession(under root: URL) -> (folder: URL, photos: [CapturedPhoto])? {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        // ISO-8601 folder names sort lexically = chronologically; check newest first.
        for folder in subdirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data),
                  !entries.isEmpty else { continue }
            var restored: [CapturedPhoto] = []
            for e in entries {
                // Defense-in-depth: never resolve a manifest name that could escape the folder
                // (a tampered/legacy manifest must not become a path-traversal on restore).
                guard !e.name.contains("/"), !e.name.contains("..") else { continue }
                let url = folder.appendingPathComponent(e.name)
                guard fm.fileExists(atPath: url.path) else { continue }
                restored.append(CapturedPhoto(
                    url: url, groupId: e.groupId, seq: e.seq,
                    type: CaptureGroupType(rawValue: e.type) ?? .document,
                    receivedAt: Date(), priority: e.priority, year: e.year, month: e.month))
            }
            if !restored.isEmpty {
                restored.sort { $0.seq < $1.seq }
                return (folder, restored)
            }
        }
        return nil
    }

    /// Move any Live Capture session folders left in the legacy Application Support location into the
    /// visible backup root, so recovery and all further writes use the Finder-discoverable folder.
    /// Best-effort: a name collision (already migrated) is skipped, and any folder that can't be moved
    /// is simply left in place. Moving the whole folder keeps each photo with its manifest, and the
    /// manifest stores bare names, so reloading from the new location rebuilds correct URLs.
    private static func migrateLegacySessions(into root: URL) {
        let fm = FileManager.default
        guard root.standardizedFileURL != legacyRoot.standardizedFileURL,
              let subdirs = try? fm.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil) else { return }
        for folder in subdirs {
            let dest = root.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: folder, to: dest) }
        }
    }

    /// Remove stale session folders under the backup root that no longer hold any photo (their JPEGs
    /// were cleared at a successful finalize), so the visible root doesn't accumulate empty folders that
    /// bury the run still holding photos. NEVER removes a folder that still contains a `.jpg`, so it
    /// cannot lose received data. Called at launch, before recovery, so it can't touch the active session.
    private static func pruneEmptySessions(under root: URL) {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for folder in subdirs {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let hasPhoto = contents.contains { $0.pathExtension.lowercased() == "jpg" }
            if !hasPhoto { try? fm.removeItem(at: folder) }
        }
    }
}
