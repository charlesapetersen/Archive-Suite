import SwiftUI
import UIKit

/// Owns the capture session: the paired endpoint, the current group, captured items, minimal on-phone
/// tagging (priority + date), and the durable upload of each item. Mirrors the Android CaptureViewModel,
/// including the segment-transfer UX (photos leave the phone once the Mac confirms them).
@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var endpoint: MacEndpoint?
    private var client: MacClient?

    @Published var items: [CapturedItem] = []
    @Published private(set) var currentGroupId = CaptureViewModel.newGroupId()
    @Published private(set) var statusMessage = ""
    @Published private(set) var pendingTagGroupId: String?
    @Published private(set) var selectedItemId: Int64?
    @Published private(set) var armed = false
    @Published private(set) var sentCount = 0
    @Published private(set) var transferFlash: String?

    private var seqCounter = 0
    private var nextId: Int64 = 1
    private var flashTask: Task<Void, Never>?
    private let store = SessionStore()
    private let sessionDir: URL
    let deviceName = UIDevice.current.name

    private static let endpointKey = "macEndpoint"

    init() {
        sessionDir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                      ?? FileManager.default.temporaryDirectory).appendingPathComponent("capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        endpoint = Self.loadEndpoint()
        client = endpoint.map { MacClient(endpoint: $0) }
        restore()
        startAutoRetry()
    }

    private static func newGroupId() -> String { "g" + UUID().uuidString.prefix(8) }

    // MARK: - Pairing

    func connect(host: String, port: Int, token: String, name: String = "Mac") async -> Bool {
        let ep = MacEndpoint(host: host, port: port, token: token, name: name)
        let ok = await MacClient(endpoint: ep).ping()
        if ok {
            endpoint = ep
            client = MacClient(endpoint: ep)
            Self.saveEndpoint(ep)
            statusMessage = "Connected to \(ep.name)"
            resumeUploads()
        } else {
            statusMessage = "Could not reach \(host):\(port)"
        }
        return ok
    }

    func connectFromQR(_ payload: String) async -> Bool {
        guard let ep = MacEndpoint.fromQRPayload(payload) else { return false }
        return await connect(host: ep.host, port: ep.port, token: ep.token, name: ep.name)
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.endpointKey)
        endpoint = nil
        client = nil
    }

    private static func loadEndpoint() -> MacEndpoint? {
        guard let d = UserDefaults.standard.data(forKey: endpointKey) else { return nil }
        return try? JSONDecoder().decode(MacEndpoint.self, from: d)
    }
    private static func saveEndpoint(_ ep: MacEndpoint) {
        if let d = try? JSONEncoder().encode(ep) { UserDefaults.standard.set(d, forKey: endpointKey) }
    }

    // MARK: - Capture

    func newCaptureFileURL() -> URL { sessionDir.appendingPathComponent("img_\(UUID().uuidString).jpg") }

    /// Main shutter: add a page to the current document segment (buffered until "End segment").
    func addDocumentPhoto(_ fileURL: URL) {
        clearSelection()
        seqCounter += 1
        items.append(CapturedItem(id: nextId, fileURL: fileURL, groupId: currentGroupId, seq: seqCounter, type: .document))
        nextId += 1
        let n = items.filter { $0.groupId == currentGroupId && $0.type == .document }.count
        statusMessage = "Document · \(n) page\(n == 1 ? "" : "s")"
        persist()
    }

    /// Box/Folder: a single-image marker (its own group) that uploads immediately.
    func captureMarker(_ fileURL: URL, type: GroupType) {
        clearSelection()
        seqCounter += 1
        let item = CapturedItem(id: nextId, fileURL: fileURL, groupId: Self.newGroupId(), seq: seqCounter, type: type)
        nextId += 1
        items.append(item)
        statusMessage = (type == .box) ? "Box captured" : "Folder captured"
        persist()
        enqueueUpload(item)
        flash(type == .box ? "Box → Mac" : "Folder → Mac")
    }

    /// Long-press a page thumbnail to toggle a per-page P10 override.
    func toggleP10(_ id: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].priority = (items[i].priority == "P10") ? nil : "P10"
        persist()
    }

    private func clearSelection() { selectedItemId = nil; armed = false }

    /// Tap cycle on a thumbnail: select → arm (show X) → delete.
    func tapItem(_ id: Int64) {
        if selectedItemId != id { selectedItemId = id; armed = false }
        else if !armed { armed = true }
        else { deleteItem(id) }
    }

    func deleteItem(_ id: Int64) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: items[i].fileURL)
            items.remove(at: i)
        }
        clearSelection()
        persist()
    }

    /// Reclassify the selected photo as a single-image box/folder marker (own group) and upload it.
    func reclassifySelected(_ type: GroupType) {
        guard let id = selectedItemId, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].type = type
        items[i].groupId = Self.newGroupId()
        items[i].priority = nil
        items[i].state = .pending
        let updated = items[i]
        clearSelection()
        persist()
        enqueueUpload(updated)
    }

    // MARK: - Grouping / finalize

    func finishDocumentSegment() {
        let hasDocs = items.contains { $0.groupId == currentGroupId && $0.type == .document && $0.state == .pending }
        if hasDocs { pendingTagGroupId = currentGroupId } else { startNewGroup() }
    }

    func applyTagsAndContinue(priority: String?, year: Int?, month: Int?) {
        guard let gid = pendingTagGroupId else { return }
        if let y = year { noteYear(y) }
        var n = 0
        for i in items.indices where items[i].groupId == gid && items[i].type == .document && items[i].state == .pending {
            items[i].priority = items[i].priority ?? priority
            items[i].year = year
            items[i].month = month
            enqueueUpload(items[i])
            n += 1
        }
        if n > 0 { flash("Segment → Mac · \(n) page\(n == 1 ? "" : "s")") }
        pendingTagGroupId = nil
        startNewGroup()
        persist()
    }

    func cancelTagSheet() { pendingTagGroupId = nil }

    private func startNewGroup() { currentGroupId = Self.newGroupId(); persist() }

    // MARK: - Recent years (for the tag sheet's quick chips)

    private static let recentYearsKey = "recentYears"
    var recentYears: [Int] { (UserDefaults.standard.array(forKey: Self.recentYearsKey) as? [Int]) ?? [] }
    private func noteYear(_ y: Int) {
        var ys = recentYears.filter { $0 != y }
        ys.insert(y, at: 0)
        UserDefaults.standard.set(Array(ys.prefix(5)), forKey: Self.recentYearsKey)
    }

    // MARK: - Upload

    private func enqueueUpload(_ item: CapturedItem) {
        guard let c = client else { return }
        setState(item.id, .uploading)
        Task {
            let data = try? Data(contentsOf: item.fileURL)
            var ok = false
            if let data {
                var attempt = 0
                while !ok && attempt < 3 {
                    ok = await c.postPhoto(jpeg: data, group: item.groupId, seq: item.seq, type: item.type.rawValue,
                                           priority: item.priority, year: item.year, month: item.month, device: deviceName)
                    attempt += 1
                }
            }
            if ok {
                sentCount += 1
                setState(item.id, .uploaded)
                // Confirmed durably on the Mac → drop it from the phone shortly after (lets the strip
                // animate it out), so photos transfer in segments instead of piling up.
                Task { try? await Task.sleep(nanoseconds: 650_000_000); removeConfirmed(item) }
            } else {
                setState(item.id, .failed)
            }
            statusMessage = uploadSummary()
        }
    }

    func retryFailed() { items.filter { $0.state == .failed }.forEach { enqueueUpload($0) } }

    /// Re-send anything not yet on the Mac: in-flight/failed of any kind, plus a stuck PENDING marker
    /// (captured while unpaired). Buffered PENDING document pages wait for "End segment" (to be tagged).
    private func resumeUploads() {
        guard client != nil else { return }
        items.filter { $0.state == .uploading || $0.state == .failed || ($0.state == .pending && $0.type != .document) }
            .forEach { enqueueUpload($0) }
    }

    private func startAutoRetry() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                guard self.client != nil else { continue }
                let needs = self.items.filter { $0.state == .failed || ($0.state == .pending && $0.type != .document) }
                needs.forEach { self.enqueueUpload($0) }
            }
        }
    }

    /// A photo confirmed by the Mac is durably safe there, so remove it from the phone. Guarded by
    /// identity + state so a stale timer can't delete a newer photo that reused an id after Clear.
    private func removeConfirmed(_ item: CapturedItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id && $0.fileURL == item.fileURL }),
              items[i].state == .uploaded else { return }
        try? FileManager.default.removeItem(at: items[i].fileURL)
        items.remove(at: i)
        if selectedItemId == item.id { clearSelection() }
        persist()
    }

    func finishSession() { Task { _ = await client?.sessionComplete() } }

    /// Delete every captured photo (files + persisted session) and start clean.
    func clearSession() {
        for item in items { try? FileManager.default.removeItem(at: item.fileURL) }
        items.removeAll()
        seqCounter = 0
        nextId = 1
        currentGroupId = Self.newGroupId()
        pendingTagGroupId = nil
        clearSelection()
        sentCount = 0
        transferFlash = nil
        statusMessage = ""
        store.clear()
    }

    // MARK: - Persistence / helpers

    private func restore() {
        guard let snap = store.load() else { return }
        items = snap.items
        seqCounter = snap.seq
        nextId = snap.nextId
        if let g = snap.groupId { currentGroupId = g }
        // Items already confirmed on the Mac before a crash are safe there — drop them.
        for item in items where item.state == .uploaded { try? FileManager.default.removeItem(at: item.fileURL) }
        items.removeAll { $0.state == .uploaded }
        if !items.isEmpty { statusMessage = "Restored \(items.count) photo(s) from last session" }
        resumeUploads()
    }

    private func persist() {
        store.save(.init(items: items, seq: seqCounter, nextId: nextId, groupId: currentGroupId))
    }

    private func setState(_ id: Int64, _ state: UploadState) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state
        persist()
    }

    private func flash(_ message: String) {
        transferFlash = message
        flashTask?.cancel()
        flashTask = Task { try? await Task.sleep(nanoseconds: 2_500_000_000); transferFlash = nil }
    }

    private func uploadSummary() -> String {
        let failed = items.filter { $0.state == .failed }.count
        let inflight = items.filter { $0.state == .pending || $0.state == .uploading }.count
        var s = "\(sentCount) sent to Mac"
        if inflight > 0 { s += " · \(inflight) queued" }
        if failed > 0 { s += " · \(failed) failed" }
        return s
    }
}
