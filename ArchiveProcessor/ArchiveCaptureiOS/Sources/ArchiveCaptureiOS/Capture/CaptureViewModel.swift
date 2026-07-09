import SwiftUI
import UIKit
import Photos

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
    /// Abstracted behind `SegmentTransport` so a second transport (Google Drive cloud relay) can be
    /// dropped in without touching the durable queue/retry/dedup below. Today's only impl is `MacClient`.
    private var client: (any SegmentTransport)?

    @Published var items: [CapturedItem] = []
    @Published private(set) var currentGroupId = CaptureViewModel.newGroupId()
    @Published private(set) var statusMessage = ""
    @Published private(set) var pendingTagGroupId: String?
    @Published private(set) var selectedItemId: Int64?
    @Published private(set) var armed = false
    @Published private(set) var sentCount = 0
    @Published private(set) var transferFlash: String?
    @Published var captureError: String?   // set when a capture couldn't be written to disk (blocking alert)
    @Published var pendingDeleteId: Int64? // set when deleting an un-uploaded item (confirmation dialog)
    @Published private(set) var connectPhase: ConnectPhase = .idle   // drives the pairing screen (P1)

    private var seqCounter = 0
    private var nextId: Int64 = 1

    /// Document segments the operator has ended (End segment → Apply/Skip) whose segment-complete signal
    /// the Mac hasn't acked yet, with the tags to send. PERSISTED so an app-kill between End segment and
    /// the ack can't strand the document (the Mac's own "Finish session" is a further backstop — it
    /// force-completes any still-open group). A group's signal is emitted only once ALL its pages are
    /// confirmed uploaded (see `trySendSegmentComplete`) so the Mac can never complete a partial segment,
    /// and is retried until acked. Mirrors Android.
    private struct SegTags { let priority: String?; let year: Int?; let month: Int?; let seqs: String? }
    private var endedSegments: [String: SegTags] = [:]
    /// Group ids whose completion signal is being sent right now, so the auto-retry loop, the
    /// upload-success hook, and resume can't fire the same one concurrently.
    private var inFlightSegments = Set<String>()

    private var flashTask: Task<Void, Never>?
    private let store = SessionStore()
    private let sessionDir: URL
    let deviceName = UIDevice.current.name
    let driveAuth = DriveAuth()

    /// Which transport the phone is using to reach the Mac.
    enum TransportMode: String { case lan, drive }
    @Published private(set) var transportMode: TransportMode = .lan

    private static let endpointKey = "macEndpoint"
    private static let transportModeKey = "transportMode"

    init() {
        sessionDir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                      ?? FileManager.default.temporaryDirectory).appendingPathComponent("capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        endpoint = Self.loadEndpoint()
        transportMode = TransportMode(rawValue: UserDefaults.standard.string(forKey: Self.transportModeKey) ?? "") ?? .lan
        client = endpoint.map { Self.makeTransport(endpoint: $0, mode: transportMode, driveAuth: driveAuth) }
        restore()
        startAutoRetry()
    }

    /// Build the appropriate transport for the current mode.
    private static func makeTransport(endpoint: MacEndpoint, mode: TransportMode, driveAuth: DriveAuth) -> any SegmentTransport {
        if mode == .drive, let relay = endpoint.relay {
            return DriveRelayTransport(client: DriveClient(token: { try driveAuth.accessTokenBlocking() }), token: relay)
        }
        return MacClient(endpoint: endpoint)
    }

    /// Switch transport mode (LAN vs Drive). Persists the choice and re-creates the client.
    func setTransportMode(_ mode: TransportMode) {
        transportMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.transportModeKey)
        if let ep = endpoint {
            client = Self.makeTransport(endpoint: ep, mode: mode, driveAuth: driveAuth)
            resumeUploads()
        }
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
            // Auto-select Drive transport when the QR carries a relay token and the user is signed in.
            if ep.relay != nil && driveAuth.isSignedIn { transportMode = .drive }
            else { transportMode = .lan }
            UserDefaults.standard.set(transportMode.rawValue, forKey: Self.transportModeKey)
            client = Self.makeTransport(endpoint: ep, mode: transportMode, driveAuth: driveAuth)
            Self.saveEndpoint(ep)
            statusMessage = ""
            connectPhase = .idle
            resumeUploads()
        case .unreachable:
            // LAN unreachable but the QR has a relay token + user signed in → try Drive directly.
            if ep.relay != nil && driveAuth.isSignedIn {
                endpoint = ep
                transportMode = .drive
                UserDefaults.standard.set(transportMode.rawValue, forKey: Self.transportModeKey)
                client = Self.makeTransport(endpoint: ep, mode: .drive, driveAuth: driveAuth)
                Self.saveEndpoint(ep)
                statusMessage = "Using Google Drive relay (LAN unreachable)"
                connectPhase = .idle
                resumeUploads()
            } else {
                connectPhase = .unreachable(host: ep.host, port: ep.port)
            }
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
        // (idempotent group+seq replace). The segment-complete signal carries only the group's priority, so
        // a per-page P10 must ride the photo itself. If it's still uploading, defer via needsResend so the
        // toggle isn't dropped (the completion handler re-sends with the current value).
        resendOrEnqueue(items[i])
    }

    /// Re-send a just-changed item: enqueue now if it's idle, else flag it to be re-sent when its in-flight
    /// upload settles. This is the fix for a per-page P10 toggle / reclassify racing an in-flight upload —
    /// the `inFlightUploads` guard would otherwise suppress the re-enqueue and silently drop the change.
    private func resendOrEnqueue(_ item: CapturedItem) {
        if inFlightUploads.contains(item.id) { markNeedsResend(item.id) } else { enqueueUpload(item) }
    }

    private func markNeedsResend(_ id: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].needsResend != true else { return }
        items[i].needsResend = true
        persist()
    }

    private func clearNeedsResend(_ id: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].needsResend == true else { return }
        items[i].needsResend = false
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
        guard let i = items.firstIndex(where: { $0.id == id }) else { clearSelection(); return }
        // If the photo hasn't been confirmed on the Mac, deleting it locally is irrecoverable.
        // Show a destructive confirmation instead of silently discarding.
        if items[i].state != .uploaded {
            pendingDeleteId = id
            return
        }
        removeItem(at: i)
    }

    /// Actually remove an item (file + model). Called after confirmation for un-uploaded items.
    func confirmDelete() {
        guard let id = pendingDeleteId else { return }
        pendingDeleteId = nil
        if let i = items.firstIndex(where: { $0.id == id }) {
            removeItem(at: i)
        }
    }

    private func removeItem(at i: Int) {
        try? FileManager.default.removeItem(at: items[i].fileURL)
        items.remove(at: i)
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
        // Build the full reclassify chain (SPEC A3): G→H→I carries "G,H" so the Mac tombstones every
        // prior group, not just the immediate predecessor. Append the old group to any existing chain.
        if let existing = items[i].replacesGroupId {
            items[i].replacesGroupId = "\(existing),\(oldGroupId)"
        } else {
            items[i].replacesGroupId = oldGroupId
        }
        let updated = items[i]
        clearSelection()
        persist()
        // Tell the Mac to drop the old (oldGroupId, seq) copy if it already has it (idempotent no-op
        // otherwise). If the page's original upload is still in flight, defer via needsResend — the
        // in-flight guard would otherwise swallow this re-enqueue and the reclassify would never send.
        resendOrEnqueue(updated)
    }

    // MARK: - Grouping / finalize

    func finishDocumentSegment() {
        // A segment's pages now stream as shot (so they're UPLOADED/UPLOADING by End segment, not PENDING);
        // gate the tag sheet on "the current group has any document page," regardless of upload state, so
        // an empty segment just starts a new group but a real one always gets tagged + a completion signal.
        let hasDocs = items.contains { $0.groupId == currentGroupId && $0.type == .document }
        if hasDocs { pendingTagGroupId = currentGroupId; persist() } else { startNewGroup() }
    }

    /// Tag sheet → "Apply & continue" or "Skip" (Skip passes nils): apply the optional pre-fill tags and
    /// end the current document segment.
    func applyTagsAndContinue(priority: String?, year: Int?, month: Int?) {
        finalizeSegment(priority: priority, year: year, month: month)
    }

    /// Tag sheet → "Cancel — keep shooting": the operator tapped End segment by mistake. Close the sheet
    /// WITHOUT ending the segment, so the current group stays open and further pages keep accumulating in
    /// the same document (nothing is sent, nothing is stranded). Gesture-dismiss of the sheet is disabled
    /// (see CaptureScreen), so this is only reached deliberately.
    func cancelTagSheet() { pendingTagGroupId = nil; persist() }

    /// End the current document segment. Its pages already streamed to the Mac; stamp the optional pre-fill
    /// tags (so any not-yet-uploaded page carries them), open the next segment, and record the segment as
    /// "ended, awaiting Mac ack". The completion signal — which is what makes the Mac present this segment's
    /// tag card — is then emitted once ALL its pages are confirmed uploaded (never for a partial segment),
    /// and retried until acked.
    private func finalizeSegment(priority: String?, year: Int?, month: Int?) {
        guard let gid = pendingTagGroupId else { return }
        pendingTagGroupId = nil            // FIRST: the sheet's dismiss-binding re-fires cancelTagSheet on nil,
                                           // so gid must be consumed before that (the guard above then no-ops it).
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
        startNewGroup()                                    // gid is now finalized (differs from currentGroupId)
        // SPEC A5: snapshot page seqs at End-segment so the Mac can verify all pages arrived.
        let seqs = items.filter { $0.groupId == gid && $0.type == .document }
            .map { String($0.seq) }.joined(separator: ",")
        endedSegments[gid] = SegTags(priority: priority, year: year, month: month, seqs: seqs.isEmpty ? nil : seqs)
        persist()
        // Already-uploaded pages are done (bytes on the Mac; tags via the signal) → they leave the strip now.
        for item in items.filter({ $0.groupId == gid && $0.type == .document && $0.state == .uploaded }) {
            removeConfirmed(item)
        }
        trySendSegmentComplete(group: gid)   // sends now iff all pages already uploaded; else deferred to upload/retry
        if pages > 0 { flash("Segment → Mac · \(pages) page\(pages == 1 ? "" : "s")") }
    }

    /// Emit a group's segment-complete signal — but ONLY once every page of that group is confirmed
    /// uploaded, so the Mac never completes a partial segment (a late page would otherwise be dropped from
    /// the segment's live output). If pages are still in flight this is a no-op; the upload-success path
    /// and the auto-retry loop call it again. Dropped from `endedSegments` only on a true ack.
    private func trySendSegmentComplete(group: String) {
        guard let tags = endedSegments[group], let c = client else { return }
        // Gate: any page of this group not yet UPLOADED (pending/uploading/failed) → wait for it.
        if items.contains(where: { $0.groupId == group && $0.state != .uploaded }) { return }
        guard inFlightSegments.insert(group).inserted else { return }   // a send for this group is already running
        Task {
            defer { inFlightSegments.remove(group) }
            var ok = false, attempt = 0
            while !ok && attempt < 3 {
                ok = await c.segmentComplete(group: group, priority: tags.priority, year: tags.year, month: tags.month, seqs: tags.seqs)
                attempt += 1
            }
            if ok { endedSegments[group] = nil; persist() }
        }
    }

    /// Retry every ended-but-unacked segment (each still gated on all its pages being uploaded).
    private func resendEndedSegments() {
        guard client != nil else { return }
        for group in endedSegments.keys { trySendSegmentComplete(group: group) }
    }

    /// Heartbeat the count of photos still IN FLIGHT to the Mac (pending/uploading) so the Mac can surface
    /// "phone still has N photos to send" and hold Finish until they arrive — reaching 0 once they settle.
    /// FAILED pages are deliberately EXCLUDED: they need a manual Retry and won't arrive on their own, so
    /// they must not block Finish forever (the operator sees + retries them in the phone's strip).
    private func sendStatusReport() {
        guard let c = client else { return }
        let pending = items.filter { $0.state == .pending || $0.state == .uploading }.count
        Task { _ = await c.reportStatus(pending: pending) }
    }

    private func startNewGroup() { currentGroupId = Self.newGroupId(); persist() }

    // MARK: - Recent years (for the tag sheet's quick chips)

    private static let recentYearsKey = "recentYears"
    var recentYears: [Int] { (UserDefaults.standard.array(forKey: Self.recentYearsKey) as? [Int]) ?? [] }
    private func noteYear(_ y: Int) {
        var ys = recentYears.filter { $0 != y }
        ys.insert(y, at: 0)
        // Recent-years cap reconciled to 6 to match the Android companion (was 5).
        UserDefaults.standard.set(Array(ys.prefix(6)), forKey: Self.recentYearsKey)
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
        sendStatusReport()   // reflect a just-captured/enqueued page on the Mac immediately (not only every 8s)
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
                // A field changed while this upload was in flight (per-page P10 / reclassify): the bytes just
                // sent are stale. Re-send with the CURRENT fields instead of confirming — do NOT
                // removeConfirmed (that would drop the photo having sent only the old value). The re-enqueue
                // is scheduled on a fresh Task so it runs after this one's `defer` releases the in-flight guard.
                if let idx = items.firstIndex(where: { $0.id == item.id }), items[idx].needsResend == true {
                    clearNeedsResend(item.id)
                    Task { @MainActor in if let latest = items.first(where: { $0.id == item.id }) { enqueueUpload(latest) } }
                } else {
                    // Confirmed durably on the Mac → drop it from the phone shortly after (lets the strip
                    // animate it out), so photos transfer in segments instead of piling up.
                    Task { try? await Task.sleep(nanoseconds: 650_000_000); removeConfirmed(item) }
                    // If this was the last outstanding page of an ended segment, its completion signal was
                    // gated waiting for this upload — try it now (no-op if other pages are still in flight).
                    if endedSegments[item.groupId] != nil { trySendSegmentComplete(group: item.groupId) }
                }
            } else {
                setState(item.id, .failed)
            }
            statusMessage = uploadSummary()
            sendStatusReport()   // reflect the new un-sent count promptly (this upload just settled)
        }
    }

    func retryFailed() { items.filter { $0.state == .failed }.forEach { enqueueUpload($0) } }

    /// Backup: save every photo still on the phone into the Photos library, so the operator can retrieve
    /// the originals if they won't transfer to the Mac. Independent of the transfer queue — these copies
    /// survive Clear and a failed session. Add-only Photos permission is requested on first use.
    func saveToPhone() {
        let toSave = items
        guard !toSave.isEmpty else { statusMessage = "No photos to save"; return }
        statusMessage = "Saving \(toSave.count) photo(s) to Photos…"
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                statusMessage = "Photos access is off — enable it in Settings to save a backup."
                return
            }
            var saved = 0
            for item in toSave {
                // Guard the source exists (a concurrent upload-confirmation may have removed it) so a missing
                // file can't be silently counted as a saved backup — over-reporting a backup that isn't there.
                guard FileManager.default.fileExists(atPath: item.fileURL.path) else { continue }
                let ok: Bool = await withCheckedContinuation { cont in
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: item.fileURL)
                    }, completionHandler: { success, _ in cont.resume(returning: success) })
                }
                if ok { saved += 1 }
            }
            statusMessage = saved == toSave.count
                ? "Saved \(saved) photo(s) to Photos"
                : "Saved \(saved) of \(toSave.count) — some couldn't be added to Photos"
            flash("Saved \(saved) to Photos")
        }
    }

    /// Re-send anything not confirmed on the Mac (in-flight/failed, or still-PENDING). Document pages now
    /// stream as shot, so a PENDING doc is simply one captured while unpaired/offline — send it too.
    /// Idempotent on the Mac (same group+seq → replace); the inFlightUploads guard prevents double-sends.
    private func resumeUploads() {
        guard client != nil else { return }
        items.filter { $0.state != .uploaded }.forEach { enqueueUpload($0) }
        // Re-drive any ended segment whose completion signal hasn't been acked (each gated on all its
        // pages being uploaded), so a reconnect flushes them.
        resendEndedSegments()
        sendStatusReport()   // let the Mac know the current un-sent count as soon as we (re)connect
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
                // Retry any ended segment whose completion signal hasn't been acked (gated on all its
                // pages being uploaded), so a transient drop at End segment self-heals.
                self.resendEndedSegments()
                // Heartbeat the un-sent count (incl. 0 when drained) so the Mac's "phone still has N to
                // send" stays fresh even while the phone is idle.
                self.sendStatusReport()
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

    /// Delete every captured photo (files + persisted session) and start clean.
    func clearSession() {
        for item in items { try? FileManager.default.removeItem(at: item.fileURL) }
        items.removeAll()
        inFlightUploads.removeAll()   // ids reset below; don't let a stale in-flight id block a reused id
        endedSegments.removeAll()
        inFlightSegments.removeAll()
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
        // Restore segments ended-but-not-yet-acked so their completion signal is re-sent below (each still
        // gated on all its pages being uploaded), even across an app kill.
        for e in snap.endedSegments ?? [] { endedSegments[e.group] = SegTags(priority: e.priority, year: e.year, month: e.month, seqs: e.seqs) }
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
        let ended = endedSegments.map { SessionStore.EndedSeg(group: $0.key, priority: $0.value.priority,
                                                              year: $0.value.year, month: $0.value.month, seqs: $0.value.seqs) }
        store.save(.init(items: items, seq: seqCounter, nextId: nextId, groupId: currentGroupId,
                         pendingTagGroupId: pendingTagGroupId, endedSegments: ended))
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
