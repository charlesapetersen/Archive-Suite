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

    /// Session id + incoming folder under Application Support.
    let sessionId: String
    let incomingFolder: URL

    private lazy var server = CaptureServer(session: self)

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveProcessor/LiveCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Crash recovery: reload the newest session that still has received-but-unprocessed photos
        // (a manifest + files on disk), so a Mac crash never orphans received data. Else start fresh.
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
        writeManifest()
        return finalURL
    }

    func removePhoto(_ photo: CapturedPhoto) {
        try? FileManager.default.removeItem(at: photo.url)
        photos.removeAll { $0.id == photo.id }
        writeManifest()
    }

    func clear() {
        for p in photos { try? FileManager.default.removeItem(at: p.url) }
        photos = []
        writeManifest()
        statusMessage = serverRunning ? "Listening on port \(listenPort)." : "Idle"
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

    /// Ordered file URLs + per-group boundary/type info for the OCR pre-grouped handoff.
    func orderedFilesAndGroups() -> (files: [URL], boundaries: [Bool], types: [CaptureGroupType],
                                     priorities: [String?], years: [Int?], months: [Int?]) {
        var files: [URL] = []
        var boundaries: [Bool] = []
        var types: [CaptureGroupType] = []
        var priorities: [String?] = []
        var years: [Int?] = []
        var months: [Int?] = []
        for group in groups {
            for (i, photo) in group.photos.enumerated() {
                files.append(photo.url)
                boundaries.append(i == 0)          // first photo of a group starts a segment
                types.append(group.type)
                priorities.append(photo.priority)  // per-photo (page P10 override)
                years.append(group.year)           // group date, repeated per photo
                months.append(group.month)
            }
        }
        return (files, boundaries, types, priorities, years, months)
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
    private func writeManifest() {
        let entries = photos.map {
            ManifestEntry(name: $0.url.lastPathComponent, groupId: $0.groupId, seq: $0.seq,
                          type: $0.type.rawValue, priority: $0.priority, year: $0.year, month: $0.month)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
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
}
