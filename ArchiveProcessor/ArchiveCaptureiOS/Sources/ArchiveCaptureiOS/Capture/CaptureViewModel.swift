import SwiftUI
import UIKit

/// Explicit connect phase so the pairing UI gives immediate, honest feedback: it names what it's dialing
/// the instant the QR decodes, and on failure names the cause + the fix (instead of a dead spinner). A
/// successful connect flips `endpoint` non-nil, so `ContentView` swaps to the capture screen — no
/// `.connected` case is needed here. Mirrors the plan's P1 `ConnectPhase`.
enum ConnectPhase: Equatable {
    case idle
    case connecting(host: String, port: Int)
    case unreachable(host: String, port: Int)
    case refused(host: String, port: Int)
    case unauthorized(host: String, port: Int)
    case badQR
}

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
    @Published var captureError: String?   // set when a capture couldn't be written to disk (blocking alert)
    @Published private(set) var connectPhase: ConnectPhase = .idle   // drives the pairing screen (P1)

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

    /// Clear any prior failure so re-opening the scanner / manual entry starts from a clean slate.
    func resetConnectPhase() { connectPhase = .idle }

    func connect(host: String, port: Int, token: String, name: String = "Mac") async {
        await attemptConnect(MacEndpoint(host: host, port: port, token: token, name: name))
    }

    func connectFromQR(_ payload: String) async {
        guard let ep = MacEndpoint.fromQRPayload(payload) else { connectPhase = .badQR; return }
        await attemptConnect(ep)
    }

    /// Preflight the endpoint with a short-timeout reachability probe, then pair on success or name the
    /// cause on failure. Sets `.connecting` first so the UI shows "connecting to <ip>:<port>…" immediately.
    private func attemptConnect(_ ep: MacEndpoint) async {
        connectPhase = .connecting(host: ep.host, port: ep.port)
        switch await MacClient(endpoint: ep).reachability() {
        case .ok:
            endpoint = ep
            client = MacClient(endpoint: ep)
            Self.saveEndpoint(ep)
            statusMessage = "Connected to \(ep.name)"
            connectPhase = .idle
            resumeUploads()
        case .unreachable:  connectPhase = .unreachable(host: ep.host, port: ep.port)
        case .refused:      connectPhase = .refused(host: ep.host, port: ep.port)
        case .unauthorized: connectPhase = .unauthorized(host: ep.host, port: ep.port)
        }
    }

    func disconnect() {
        // Best-effort: tell the Mac we're re-pairing so it re-shows the QR (there's no persistent
        // connection for it to notice the drop). Fire before clearing the client; ignore failure.
        let c = client
        if let c { Task { _ = await c.sessionDisconnect() } }
        UserDefaults.standard.removeObject(forKey: Self.endpointKey)
        endpoint = nil
        client = nil
        connectPhase = .idle
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

    /// Durably write a freshly captured JPEG. A capture can't be re-taken, so on a write failure we
    /// recreate the session directory and retry, then fall back to the temp directory; only if all of
    /// that fails do we surface a blocking alert (captureError) and return nil — never silently dropping
    /// the photo. Returns the URL the bytes were written to.
    func persistCapturedJPEG(_ data: Data) -> URL? {
        let primary = newCaptureFileURL()
        if (try? data.write(to: primary, options: .atomic)) != nil { return primary }
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        if (try? data.write(to: primary, options: .atomic)) != nil { return primary }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(primary.lastPathComponent)
        if (try? data.write(to: fallback, options: .atomic)) != nil { return fallback }
        captureError = "Couldn't save the last photo (is storage full?). It was NOT captured — free up space and retake it before moving the document."
        return nil
    }

    /// Main shutter: add a page to the current document segment and stream it to the Mac immediately.
    func addDocumentPhoto(_ fileURL: URL) {
        clearSelection()
        seqCounter += 1
        let item = CapturedItem(id: nextId, fileURL: fileURL, groupId: currentGroupId, seq: seqCounter, type: .document)
        items.append(item)
        nextId += 1
        let n = items.filter { $0.groupId == currentGroupId && $0.type == .document }.count
        statusMessage = "Document · \(n) page\(n == 1 ? "" : "s")"
        persist()
        // Stream the page to the Mac immediately (DATA SAFETY: a segment can be hundreds of photos, so no
        // page waits for "End segment" — a crash/drop before then must never lose an already-shot page).
        // The icon stays in the strip until End segment (removeConfirmed keeps current-group docs) so the
        // operator watches the segment grow; End segment then sends the segment-complete signal + tags.
        enqueueUpload(item)
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
        // The page may already be on the Mac (pages stream as shot) — re-send it so the P10 override lands
        // (idempotent group+seq replace). The segment-complete signal carries only the group's priority,
        // so a per-page P10 must ride the photo itself.
        if items[i].state == .uploaded { enqueueUpload(items[i]) }
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
        let oldGroupId = items[i].groupId
        items[i].type = type
        items[i].groupId = Self.newGroupId()
        items[i].priority = nil
        items[i].state = .pending
        // Persist the drop-old-copy target on the item so retry/resume/autoRetry all keep sending it.
        items[i].replacesGroupId = oldGroupId
        let updated = items[i]
        clearSelection()
        persist()
        // Tell the Mac to drop the old (oldGroupId, seq) copy if it already has it (idempotent no-op otherwise).
        enqueueUpload(updated)
    }

    // MARK: - Grouping / finalize

    func finishDocumentSegment() {
        // A segment's pages now stream as shot (so they're UPLOADED/UPLOADING by End segment, not PENDING);
        // gate the tag sheet on "the current group has any document page," regardless of upload state, so
        // an empty segment just starts a new group but a real one always gets tagged + a completion signal.
        let hasDocs = items.contains { $0.groupId == currentGroupId && $0.type == .document }
        if hasDocs { pendingTagGroupId = currentGroupId; persist() } else { startNewGroup() }
    }

    /// End segment: pages already streamed to the Mac; stamp the tags locally (so any not-yet-uploaded page
    /// carries them), open the next segment, then send the tiny segment-complete signal (which is what makes
    /// the Mac show this segment's tag card), and drop the already-uploaded pages from the strip.
    func applyTagsAndContinue(priority: String?, year: Int?, month: Int?) {
        guard let gid = pendingTagGroupId else { return }
        if let y = year { noteYear(y) }
        let pages = items.filter { $0.groupId == gid && $0.type == .document }.count
        for i in items.indices where items[i].groupId == gid && items[i].type == .document {
            // Stamp the segment's tags so any page not yet uploaded (captured offline) carries them when it
            // uploads; already-uploaded pages get the tags via the segment-complete signal.
            items[i].priority = items[i].priority ?? priority
            items[i].year = year
            items[i].month = month
            if items[i].state != .uploaded { enqueueUpload(items[i]) }
        }
        pendingTagGroupId = nil
        startNewGroup()                                    // gid is now finalized (differs from currentGroupId)
        sendSegmentComplete(group: gid, priority: priority, year: year, month: month)
        // Already-uploaded pages are done (bytes on the Mac; tags via the signal) → they leave the strip now.
        for item in items.filter({ $0.groupId == gid && $0.type == .document && $0.state == .uploaded }) {
            removeConfirmed(item)
        }
        if pages > 0 { flash("Segment → Mac · \(pages) page\(pages == 1 ? "" : "s")") }
        persist()
    }

    /// Tell the Mac a document segment is complete + its tags (End segment). Pages already streamed, so
    /// this is a tiny no-bytes signal that makes the Mac present the segment's tag card. Retried a few
    /// times; if it never lands, the phone's "Finish" (session/complete) flushes any still-open segment.
    private func sendSegmentComplete(group: String, priority: String?, year: Int?, month: Int?) {
        guard let c = client else { return }
        Task {
            var ok = false, attempt = 0
            while !ok && attempt < 3 {
                ok = await c.segmentComplete(group: group, priority: priority, year: year, month: month)
                attempt += 1
            }
        }
    }

    func cancelTagSheet() { pendingTagGroupId = nil; persist() }

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

    /// Ids currently uploading, so the auto-retry loop, `resumeUploads`, and a manual Retry can't fire the
    /// same item concurrently (double bandwidth + a racing ingest of the same filename on the Mac). This
    /// guard is what lets `resumeUploads` safely re-enqueue everything not yet UPLOADED. Mirrors Android.
    private var inFlightUploads = Set<Int64>()

    private func enqueueUpload(_ item: CapturedItem) {
        guard let c = client else { return }
        guard inFlightUploads.insert(item.id).inserted else { return }   // already uploading this id
        setState(item.id, .uploading)
        let fileURL = item.fileURL
        let replaces = item.replacesGroupId   // durable on the item, so retries keep sending X-Replaces
        Task {
            defer { inFlightUploads.remove(item.id) }
            // Read the multi-MB JPEG off the main actor so the live camera UI doesn't hitch on
            // upload/retry bursts (enqueueUpload runs on the @MainActor view model).
            let data = await Task.detached { try? Data(contentsOf: fileURL) }.value
            var ok = false
            if let data {
                var attempt = 0
                while !ok && attempt < 3 {
                    ok = await c.postPhoto(jpeg: data, group: item.groupId, seq: item.seq, type: item.type.rawValue,
                                           priority: item.priority, year: item.year, month: item.month, device: deviceName,
                                           replaces: replaces)
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

    /// Re-send anything not confirmed on the Mac (in-flight/failed, or still-PENDING). Document pages now
    /// stream as shot, so a PENDING doc is simply one captured while unpaired/offline — send it too.
    /// Idempotent on the Mac (same group+seq → replace); the inFlightUploads guard prevents double-sends.
    private func resumeUploads() {
        guard client != nil else { return }
        items.filter { $0.state != .uploaded }.forEach { enqueueUpload($0) }
    }

    private func startAutoRetry() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                guard self.client != nil else { continue }
                // Flush anything not confirmed on the Mac — failed uploads and any still-PENDING page
                // (document pages now stream as shot, so a PENDING doc just hasn't reached the Mac yet).
                let needs = self.items.filter { $0.state == .failed || $0.state == .pending }
                needs.forEach { self.enqueueUpload($0) }
            }
        }
    }

    /// A photo confirmed by the Mac is durably safe there, so remove it from the phone. Guarded by
    /// identity + state so a stale timer can't delete a newer photo that reused an id after Clear.
    private func removeConfirmed(_ item: CapturedItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id && $0.fileURL == item.fileURL }),
              items[i].state == .uploaded else { return }
        // Document pages stream to the Mac as shot, but their icons stay in the strip until "End segment"
        // (while they're still in the current, un-ended group) so the operator sees the segment growing.
        // Markers (complete 1-photo segments) leave as soon as they're confirmed.
        if items[i].type == .document && items[i].groupId == currentGroupId { return }
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
        inFlightUploads.removeAll()   // ids reset below; don't let a stale in-flight id block a reused id
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
        // Items confirmed on the Mac before a crash are durably safe there — drop them so the phone shows
        // only what still needs sending. EXCEPT document pages still in the current (un-ended) segment:
        // those streamed as shot but aren't tagged yet (tags apply at End segment), so keep them so the
        // operator can finish + tag the recovered segment.
        let confirmed = items.filter { $0.state == .uploaded && !($0.type == .document && $0.groupId == currentGroupId) }
        for item in confirmed { try? FileManager.default.removeItem(at: item.fileURL) }
        items.removeAll { $0.state == .uploaded && !($0.type == .document && $0.groupId == currentGroupId) }
        if !items.isEmpty { statusMessage = "Restored \(items.count) photo(s) from last session" }
        resumeUploads()
        // Recovered document pages stay in the current in-progress segment (currentGroupId was restored
        // above), so the operator just keeps shooting and taps End segment when ready — we do NOT assume
        // the segment is finished. Re-open the tag card ONLY if the app stopped while the user was actually
        // mid-tagging a segment (pendingTagGroupId persisted) and that group still has document pages (any
        // upload state — they streamed, so they'll be UPLOADED, not PENDING).
        if let taggingGroup = snap.pendingTagGroupId,
           items.contains(where: { $0.groupId == taggingGroup && $0.type == .document }) {
            currentGroupId = taggingGroup
            pendingTagGroupId = taggingGroup
        }
    }

    private func persist() {
        store.save(.init(items: items, seq: seqCounter, nextId: nextId, groupId: currentGroupId,
                         pendingTagGroupId: pendingTagGroupId))
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
        var parts: [String] = []
        if inflight > 0 { parts.append("\(inflight) queued") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}
