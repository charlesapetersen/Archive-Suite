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
    /// Cloud: the Google sign-in sheet is up.
    case signingIn
    /// Cloud: the scanned QR has no relay code (the Mac isn't signed into Drive).
    case noRelay
    /// Wi-Fi: the scanned QR is a cloud-only code, with no host to dial.
    case cloudOnlyQR
    /// Cloud: sign-in failed or this build can't sign in; the message names why.
    case cloudFailed(String)
    /// Wi-Fi: the QR has no network address (the Mac is on no network, S-037); Cable or Cloud can still use it.
    case noWiFiHost
    /// Cable (W40.i-usb-app): the QR decoded and the phone is waiting for its Mac on the cable.
    case cableConnecting
    /// Cable: no verified tunnel answered (not plugged in, not trusted, or Live Capture not started).
    case cableUnreachable
    /// Cable: the relay's tunnel port is taken on this phone, so the cable route cannot start.
    case cableUnavailable
}

/// Owns the capture session: the paired endpoint, the current group, captured items, minimal on-phone
/// tagging (quality + date), and the durable upload of each item. Mirrors the Android CaptureViewModel,
/// including the segment-transfer UX (photos leave the phone once the Mac confirms them).
@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var endpoint: MacEndpoint?
    /// Abstracted behind `SegmentTransport` so a second transport (Google Drive cloud relay) can be
    /// dropped in without touching the durable queue/retry/dedup below. Today's only impl is `MacClient`.
    private var client: (any SegmentTransport)?

    /// The queue and session bookkeeping, UI-free so the host tests can run it (`CaptureQueue.swift`).
    @Published private var queue = CaptureQueue()
    var items: [CapturedItem] { queue.items }
    var currentGroupId: String { queue.currentGroupId }
    var pendingTagGroupId: String? { queue.pendingTagGroupId }
    #if DEBUG
    /// The E2E driver's "everything reached the Mac": no page left on the phone and no ended segment still
    /// waiting for the Mac's acknowledgement (Debug/E2EHarness.swift).
    var e2eSettled: Bool { queue.items.isEmpty && queue.endedSegments.entries.isEmpty }
    #endif
    /// Recovered pages held until reviewed (W40.i-fix-ios-session-durability): their box/folder was never saved.
    var heldForReviewCount: Int { queue.heldForReviewCount }
    @Published private(set) var statusMessage = ""
    @Published private(set) var selectedItemId: Int64?
    @Published private(set) var armed = false
    @Published private(set) var sentCount = 0
    @Published private(set) var transferFlash: String?
    @Published var captureError: String?   // set when a capture couldn't be written to disk (blocking alert)
    @Published var restoreWarning: String? // set when a restored session lists photos no longer on disk (alert)
    /// W23.m8's port: the latest session snapshot did not reach phone storage. Its own line, not the status line,
    /// because the status line is overwritten by the next capture and this lasts until a later save lands.
    @Published private(set) var sessionNotSaved = false
    @Published var pendingDeleteId: Int64? // set when deleting an un-uploaded item (confirmation dialog)
    @Published private(set) var connectPhase: ConnectPhase = .idle   // drives the pairing screen (P1)
    /// The cable relay's state (W40.i-usb-app): the Connect screen pre-selects Cable while a tunnel is open.
    @Published private(set) var cableStatus = USBRelay.Status()

    // Document segments the operator has ended whose segment-complete signal the Mac hasn't acked yet live in
    // `queue.endedSegments`, PERSISTED so an app-kill between End segment and the ack can't strand the document
    // (the Mac's own "Finish session" is a further backstop — it force-completes any still-open group). A
    // group's signal is emitted only once ALL its pages are confirmed uploaded (see `trySendSegmentComplete`) so
    // the Mac can never complete a partial segment, and is retried until acked. Mirrors Android.

    private var flashTask: Task<Void, Never>?
    /// The running photo and segment sends, so Clear, unpair and re-pair can cancel them. Cancelling only stops them
    /// sooner: the generation and pairing checks after each send are what keep a reply that outlives them from
    /// recording anything.
    private var uploadTasks: [Int64: Task<Void, Never>] = [:]
    private var segmentTasks: [String: Task<Void, Never>] = [:]
    private let store = SessionStore()
    /// Unsent photos live in the store's Application Support directory, never Caches (W40.i-fix-ios-photo-storage).
    private var sessionDir: URL { store.photoDirectory }
    let deviceName = UIDevice.current.name
    let driveAuth = DriveAuth()

    private static let endpointKey = "macEndpoint"

    init() {
        endpoint = Self.loadEndpoint()
        // A saved Cloud pairing only stands while the phone is signed in: without a token (signed out, or a build
        // with no OAuth client, W40.i-fix-ios-drive-oauth-client) every upload would fail, so return to the
        // pairing screen instead. The queue is kept and uploads once the phone pairs again.
        if endpoint?.isCloud == true && !driveAuth.isSignedIn {
            endpoint = nil
            UserDefaults.standard.removeObject(forKey: Self.endpointKey)
        }
        client = endpoint.map { Self.makeTransport(endpoint: $0, driveAuth: driveAuth) }
        // The cable relay runs whatever the mode, so the Connect screen can see a Mac on the cable; it is given a
        // token, and so verifies tunnels and carries requests, only for a Cable pairing.
        USBRelay.shared.onStatus { [weak self] in self?.cableStatus = $0 }
        USBRelay.shared.setToken(endpoint?.isCable == true ? endpoint?.token : nil)
        USBRelay.shared.start()
        // W23.m8's port: read this BEFORE anything can save. restore() persists, and the first save that lands
        // clears the flag; read later, recovered pages would be adopted as if their classification were known.
        let manifestWasStale = store.manifestIsStale()
        restore(manifestWasStale: manifestWasStale)
        startAutoRetry()
    }

    /// The transport the pairing chose: Wi-Fi → `MacClient` (HTTP), Cloud → `DriveRelayTransport` (Google Drive).
    private static func makeTransport(endpoint: MacEndpoint, driveAuth: DriveAuth) -> any SegmentTransport {
        if endpoint.isCloud {
            return DriveRelayTransport(client: DriveClient(token: { try driveAuth.accessTokenBlocking() }),
                                       token: endpoint.token)
        }
        return MacClient(endpoint: endpoint)
    }

    // MARK: - Pairing

    /// Clear any prior failure so re-opening the scanner / manual entry starts from a clean slate.
    func resetConnectPhase() { connectPhase = .idle }

    func connect(host: String, port: Int, token: String, name: String = "Mac") async {
        await attemptConnect(MacEndpoint(host: host, port: port, token: token, name: name))
    }

    /// Wi-Fi pairing from a scanned QR. A cloud-only code has no host to dial, so it is named, not dialled.
    func connectFromQR(_ payload: String) async {
        guard let ep = MacEndpoint.fromQRPayload(payload) else { connectPhase = .badQR; return }
        if ep.isCloud { connectPhase = .cloudOnlyQR; return }
        await attemptConnect(ep)
    }

    /// Cable pairing from a scanned QR: its token and name, through the local relay. A no-address QR is fine here.
    func connectCableFromQR(_ payload: String) async {
        guard let ep = MacEndpoint.fromQRPayload(payload) else { connectPhase = .badQR; return }
        if ep.isCloud { connectPhase = .cloudOnlyQR; return }
        await attemptCableConnect(ep.asCable())
    }

    /// Cable pairing from a typed pairing code (the QR's token).
    func connectCable(token: String) async {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await attemptCableConnect(MacEndpoint(host: "", port: 0, token: t, name: "Mac", isCable: true))
    }

    /// Give the relay the token, so it challenges the tunnels it holds, then probe `/ping` through it. The probe
    /// waits longer than Wi-Fi's: a tunnel may need one turn of the Mac's 2 s top-up to arrive and verify. It is
    /// tried twice, because a tunnel taken just as the Mac expires it fails once (REFERENCE.md §Live Capture, USB local relay). A Mac that
    /// answered the challenge wrongly holds another token, so that reads as a stale code, not an absent Mac.
    private func attemptCableConnect(_ ep: MacEndpoint) async {
        if connectPhase == .cableConnecting { return }
        guard cableStatus.tunnelListening else { connectPhase = .cableUnavailable; return }
        connectPhase = .cableConnecting
        USBRelay.shared.setToken(ep.token)
        var result = await MacClient(endpoint: ep).reachability(timeout: 8)
        if result == .unreachable && USBRelay.shared.status.rejectedAnswers == 0 {
            result = await MacClient(endpoint: ep).reachability(timeout: 8)
        }
        if result == .unreachable && USBRelay.shared.status.rejectedAnswers > 0 { result = .unauthorized }
        switch result {
        case .ok:
            pair(ep, status: "Connected over the cable")
            return
        case .unauthorized: connectPhase = .unauthorized(host: "", port: 0)
        case .unreachable, .refused: connectPhase = .cableUnreachable
        }
        // Not paired: the relay holds no token, as before the attempt (the Connect screen shows only when unpaired).
        USBRelay.shared.setToken(endpoint?.isCable == true ? endpoint?.token : nil)
    }

    /// The app is back from the background: a suspended app's sockets are defunct and never say so, so the relay
    /// tears down and listens again (REFERENCE.md §Live Capture, USB local relay). Not on a return from `.inactive`, which suspends nothing and
    /// would only cut a request in flight.
    func returnedFromBackground() { USBRelay.shared.restart() }

    /// Wi-Fi only: preflight the endpoint with a short-timeout reachability probe, then pair on success or name
    /// the cause on failure. Sets `.connecting` first so the UI shows "connecting to <ip>:<port>…" immediately.
    /// It never switches to Drive by itself: the operator chooses Cloud on the pairing screen (as on Android).
    private func attemptConnect(_ ep: MacEndpoint) async {
        guard ep.hasHost else { connectPhase = .noWiFiHost; return }
        connectPhase = .connecting(host: ep.host, port: ep.port)
        switch await MacClient(endpoint: ep).reachability() {
        case .ok:
            pair(ep, status: "")
        case .unreachable:  connectPhase = .unreachable(host: ep.host, port: ep.port)
        case .refused:      connectPhase = .refused(host: ep.host, port: ep.port)
        case .unauthorized: connectPhase = .unauthorized(host: ep.host, port: ep.port)
        }
    }

    /// Cloud pairing from a scanned QR: the combined QR's `relay` code, or a cloud QR's own token. The QR's
    /// `account` becomes the sign-in hint. The Wi-Fi part of a combined QR is ignored: the operator chose Cloud.
    func connectCloudFromQR(_ payload: String) async {
        guard let ep = MacEndpoint.fromQRPayload(payload) else { connectPhase = .badQR; return }
        guard let relay = ep.relayToken else { connectPhase = .noRelay; return }
        await connectCloud(.cloud(relayToken: relay, name: ep.name, account: ep.account))
    }

    /// Cloud pairing from a typed relay token.
    func connectCloud(relayToken: String) async {
        let t = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await connectCloud(.cloud(relayToken: t))
    }

    /// Sign in to Google if the phone isn't already, then pair through the Drive relay. No reachability probe,
    /// as on Android: the first upload finds the Mac's folder, and if the Mac's cloud session isn't up yet the
    /// page stays queued and retries, so nothing is lost waiting for it.
    private func connectCloud(_ ep: MacEndpoint) async {
        if case .signingIn = connectPhase { return }
        guard DriveAuth.isConfigured else { connectPhase = .cloudFailed(DriveOAuthConfig.unconfiguredMessage); return }
        if !driveAuth.isSignedIn {
            connectPhase = .signingIn
            let r = await driveAuth.signIn(loginHint: ep.account)
            guard r.success else { connectPhase = .cloudFailed(r.error ?? "Google sign-in failed"); return }
        }
        pair(ep, status: "Cloud relay ready — uploading to Google Drive")
    }

    /// Make `ep` the pairing: the Mac paired before owns nothing from here on.
    private func pair(_ ep: MacEndpoint, status: String) {
        retirePreviousPairing()
        endpoint = ep
        client = Self.makeTransport(endpoint: ep, driveAuth: driveAuth)
        USBRelay.shared.setToken(ep.isCable ? ep.token : nil)
        Self.saveEndpoint(ep)
        statusMessage = status
        connectPhase = .idle
        resumeUploads()
    }

    func disconnect() {
        // Best-effort: tell the Mac we're re-pairing so it re-shows the QR (there's no persistent
        // connection for it to notice the drop). Fire before clearing the client; ignore failure.
        let c = client
        if let c { Task { _ = await c.sessionDisconnect() } }
        retirePreviousPairing()
        UserDefaults.standard.removeObject(forKey: Self.endpointKey)
        endpoint = nil
        client = nil
        USBRelay.shared.setToken(nil)
        connectPhase = .idle
    }

    /// Hand the queue to the next endpoint (W40.i-fix-ios-pairing-generation, Android's W23.m1). Moving the pairing
    /// on means a reply arriving afterwards can no longer confirm a page, so it can never let the phone delete its
    /// only copy, and each such send returns its page to the queue as it unwinds. Cancelling only stops those sends
    /// sooner: a request already on the wire may still land on the old Mac, which is why the pairing check, not the
    /// cancel, is what makes this safe. Everything here is on the main actor, so a send the new pairing starts
    /// can't be caught by it.
    private func retirePreviousPairing() {
        queue.rotatePairing()
        uploadTasks.values.forEach { $0.cancel() }
        segmentTasks.values.forEach { $0.cancel() }
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
    /// recreate the session directory and retry; if that fails too we surface a blocking alert (captureError)
    /// and return nil — never silently dropping the photo. There is no temp-directory fallback: the session
    /// stores file NAMES resolved against `sessionDir`, so a photo written elsewhere could not be restored, and
    /// the temp directory sits on the same full volume anyway. Returns the URL the bytes were written to.
    func persistCapturedJPEG(_ data: Data) -> URL? {
        let primary = newCaptureFileURL()
        if (try? data.write(to: primary, options: .atomic)) != nil { return primary }
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        if (try? data.write(to: primary, options: .atomic)) != nil { return primary }
        captureError = "Couldn't save the last photo (is storage full?). It was NOT captured — free up space and retake it before moving the document."
        return nil
    }

    /// Main shutter: add a page to the current document segment and stream it to the Mac immediately.
    func addDocumentPhoto(_ fileURL: URL) {
        clearSelection()
        let item = queue.addDocument(fileURL: fileURL)
        let n = queue.documentPageCount(group: currentGroupId)
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
        let item = queue.addMarker(fileURL: fileURL, type: type)
        statusMessage = (type == .box) ? "Box captured" : "Folder captured"
        persist()
        enqueueUpload(item)
        flash(type == .box ? "Box → Mac" : "Folder → Mac")
    }

    /// Long-press a page thumbnail to toggle a per-page Q3 override.
    func toggleQ3(_ id: Int64) {
        guard let updated = queue.toggleQ3(id) else { return }
        persist()
        // The page may already be on the Mac (pages stream as shot) — re-send it so the Q3 override lands
        // (idempotent group+seq replace). The segment-complete signal carries only the group's quality, so
        // a per-page Q3 must ride the photo itself. If it's still uploading, defer via needsResend so the
        // toggle isn't dropped (the completion handler re-sends with the current value).
        resendOrEnqueue(updated)
    }

    /// Re-send a just-changed item: enqueue now if it's idle, else flag it to be re-sent when its in-flight
    /// upload settles. This is the fix for a per-page Q3 toggle / reclassify racing an in-flight upload —
    /// the `inFlightUploads` guard would otherwise suppress the re-enqueue and silently drop the change.
    /// A page being deleted is flagged too: its send is refused until the delete ends, and a kept delete re-sends it.
    private func resendOrEnqueue(_ item: CapturedItem) {
        if queue.isUploading(item.id) || queue.isDeleting(item.id) { markNeedsResend(item.id) } else { enqueueUpload(item) }
    }

    private func markNeedsResend(_ id: Int64) { if queue.markNeedsResend(id) { persist() } }

    private func clearSelection() { selectedItemId = nil; armed = false }

    /// Tap cycle on a thumbnail: select → arm (show X) → delete.
    func tapItem(_ id: Int64) {
        if selectedItemId != id { selectedItemId = id; armed = false }
        else if !armed { armed = true }
        else { deleteItem(id) }
    }

    /// Third tap on an armed thumbnail. A page the Mac has confirmed, with no resend pending, goes at once: its bytes
    /// are durably on the Mac. Anything else exists only here, so it stops for a confirmation (W40.i-fix-ios-delete-confirm).
    func deleteItem(_ id: Int64) {
        guard let item = queue.item(id) else { clearSelection(); return }
        // Its delete is already running: asking again would offer a choice that is then ignored.
        if queue.isDeleting(id) { clearSelection(); statusMessage = "Already deleting this photo…"; return }
        if CaptureQueue.requiresDeleteConfirmation(item) { pendingDeleteId = id; return }
        performDelete(id, saveToPhotos: false)
    }

    /// The confirmation's actions. `saveToPhotos` copies the photo into the Photos library first and removes it only
    /// once that copy is written; false is the operator choosing Delete permanently.
    func confirmDelete(saveToPhotos: Bool) {
        guard let id = pendingDeleteId else { return }
        pendingDeleteId = nil
        performDelete(id, saveToPhotos: saveToPhotos)
    }

    /// Delete one page safely: its upload is cancelled and awaited before anything decides the photo's fate
    /// (`stopUploadThenRetire`), and while that runs the page can be neither re-sent nor removed by a late
    /// confirmation. A failed Photos copy keeps the photo and puts it back in the queue. Android's `performDelete`.
    private func performDelete(_ id: Int64, saveToPhotos: Bool) {
        guard let target = queue.item(id) else { clearSelection(); return }
        guard queue.beginDelete(id) else { return }   // a delete of this page is already running
        let upload = uploadTasks[id], generation = queue.generation
        clearSelection()   // un-arm now: the X must not stay tappable while the upload is stopped
        // A Drive send can take a while to stop (each request runs to its own timeout), so say that first.
        if upload != nil { statusMessage = "Stopping the transfer…" }
        else if saveToPhotos { statusMessage = "Saving a copy to Photos…" }
        let copy: (() async -> Bool)? = saveToPhotos ? { @MainActor [weak self] in
            self?.statusMessage = "Saving a copy to Photos…"
            return await Self.addToPhotos(target.fileURL)
        } : nil
        Task {
            let outcome = await stopUploadThenRetire(upload, copy: copy)
            guard queue.generation == generation else { return }   // Clear took the session, and the file, meanwhile
            queue.endDelete(id)
            switch outcome {
            case .keptCopyFailed:
                if let again = queue.requeueAfterKeptDelete(id) {
                    persist()
                    enqueueUpload(again)
                    statusMessage = "Couldn't save a copy to Photos, so the photo was kept. Check Photos access in Settings, then delete again."
                } else {
                    // The upload landed before the cancel did: the Mac has it, so it leaves the phone as any confirmed page does.
                    if let latest = queue.item(id) { removeConfirmed(latest) }
                    statusMessage = "Couldn't save a copy to Photos. The Mac already has this photo."
                }
            case .savedToPhotos, .deleted:
                if let removed = queue.removeDeleted(target) {
                    try? FileManager.default.removeItem(at: removed.fileURL)
                    if selectedItemId == id { clearSelection() }
                    persist()
                    sendStatusReport()   // the Mac's "phone still has N to send" must stop counting a deleted page
                }
                statusMessage = outcome == .savedToPhotos ? "Copied to Photos and removed" : queue.uploadSummary
            }
        }
    }

    /// Reclassify the selected photo as a single-image box/folder marker (own group) and upload it.
    func reclassifySelected(_ type: GroupType) {
        // The core builds the full reclassify chain (SPEC A3): G→H→I carries "G,H".
        guard let id = selectedItemId, let updated = queue.reclassify(id, to: type) else { return }
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
        if hasDocs { queue.pendingTagGroupId = currentGroupId; persist() }
        else {
            // Tapping End segment with nothing captured was silent and looked broken: say so (Android's wording).
            statusMessage = "No pages in this segment yet — capture a page first."
            startNewGroup()
        }
    }

    /// Tag sheet → "Apply & continue" or "Skip" (Skip passes nils): apply the optional pre-fill tags and
    /// end the current document segment.
    func applyTagsAndContinue(quality: String?, year: Int?, month: Int?) {
        finalizeSegment(quality: quality, year: year, month: month)
    }

    /// Tag sheet → "Cancel — keep shooting": the operator tapped End segment by mistake. Close the sheet
    /// WITHOUT ending the segment, so the current group stays open and further pages keep accumulating in
    /// the same document (nothing is sent, nothing is stranded). Gesture-dismiss of the sheet is disabled
    /// (see CaptureScreen), so this is only reached deliberately.
    func cancelTagSheet() { queue.pendingTagGroupId = nil; persist() }

    /// Review: the ordinary tag sheet on the held recovery segment, so the operator supplies the classification the
    /// failed save lost. Apply or Skip releases those pages to the Mac; Cancel leaves them held.
    func reviewRecoveredPhotos() { if queue.beginReview() { persist() } }

    /// End the current document segment. Its pages already streamed to the Mac; stamp the optional pre-fill
    /// tags (so any not-yet-uploaded page carries them), open the next segment, and record the segment as
    /// "ended, awaiting Mac ack". The completion signal — which is what makes the Mac present this segment's
    /// tag card — is then emitted once ALL its pages are confirmed uploaded (never for a partial segment),
    /// and retried until acked.
    private func finalizeSegment(quality: String?, year: Int?, month: Int?) {
        // The core consumes pendingTagGroupId FIRST: the sheet's dismiss-binding re-fires cancelTagSheet on
        // nil, so the group must be consumed before that (a nil pendingTagGroupId then no-ops this).
        guard let end = queue.endSegment(quality: quality, year: year, month: month) else { return }
        let gid = end.group, pages = end.pages
        if let y = year { noteYear(y) }
        // Pages not yet uploaded (captured offline) now carry the segment's tags; send them.
        for item in end.toUpload { enqueueUpload(item) }
        persist()
        // Already-uploaded pages are done (bytes on the Mac; tags via the signal) → they leave the strip now.
        for item in end.confirmed { removeConfirmed(item) }
        trySendSegmentComplete(group: gid)   // sends now iff all pages already uploaded; else deferred to upload/retry
        // Display only, so ending a segment is never silent; what End segment sends is unchanged.
        statusMessage = "Segment ended · \(pages) page\(pages == 1 ? "" : "s")"
        if pages > 0 { flash("Segment → Mac · \(pages) page\(pages == 1 ? "" : "s")") }
    }

    /// Emit a group's segment-complete signal — but ONLY once every page of that group is confirmed
    /// uploaded, so the Mac never completes a partial segment (a late page would otherwise be dropped from
    /// the segment's live output). If pages are still in flight this is a no-op; the upload-success path
    /// and the auto-retry loop call it again. Dropped from `endedSegments` only on a true ack.
    private func trySendSegmentComplete(group: String) {
        // Gate: any page of this group not yet UPLOADED (pending/uploading/failed) → wait for it.
        guard let tags = queue.readySegment(group), let c = client else { return }
        guard queue.beginSegmentSend(group) else { return }   // a send for this group is already running
        let generation = queue.generation, pairing = queue.pairing
        segmentTasks[group] = Task {
            defer {
                let end = queue.finishSegmentSend(group, generation: generation, pairing: pairing)
                if end.released { segmentTasks[group] = nil }
                // Unpaired or re-paired while this ran: the segment stays ended, so send it to the Mac paired now (on
                // a fresh Task, after this one is gone; a no-op while unpaired).
                if end.requeued { Task { @MainActor in trySendSegmentComplete(group: group) } }
            }
            var ok = false, attempt = 0
            while !ok && attempt < 3 && !Task.isCancelled {
                ok = await c.segmentComplete(group: group, quality: tags.quality, year: tags.year, month: tags.month, seqs: tags.seqs)
                attempt += 1
            }
            // Nothing if Clear took the session while this ran; an ack from a Mac since unpaired from must not drop
            // the segment either, since the Mac paired now never heard of it.
            if queue.ackForReply(ok: ok, generation: generation, pairing: pairing) == .confirm {
                queue.acknowledgeSegment(group); persist()
            }
        }
    }

    /// Retry every ended-but-unacked segment (each still gated on all its pages being uploaded).
    private func resendEndedSegments() {
        guard client != nil else { return }
        for group in queue.endedSegments.keys { trySendSegmentComplete(group: group) }
    }

    /// Heartbeat the count of photos the Mac must still receive so it can surface "phone still has N photos to
    /// send" and hold Finish until they arrive — reaching 0 once every page is confirmed. What it counts is
    /// `CaptureQueue.heartbeatCount`. Reports go through one writer, newest first, so an older count can never
    /// land after a newer one (`HeartbeatMailbox`). The writer runs on the main actor, as does every offer, so the
    /// mailbox needs no lock.
    private func sendStatusReport() {
        guard let c = client else { return }
        guard heartbeat.offer(StatusReport(client: c, pending: queue.heartbeatCount)) else { return }
        Task {
            while let next = heartbeat.take() { _ = await next.client.reportStatus(pending: next.pending) }
        }
    }

    private struct StatusReport { let client: any SegmentTransport; let pending: Int }
    private var heartbeat = HeartbeatMailbox<StatusReport>()

    private func startNewGroup() { queue.startNewGroup(); persist() }

    // MARK: - Recent years (for the tag sheet's quick chips)

    private static let recentYearsKey = "recentYears"
    var recentYears: [Int] { (UserDefaults.standard.array(forKey: Self.recentYearsKey) as? [Int]) ?? [] }
    private func noteYear(_ y: Int) {
        var ys = recentYears.filter { $0 != y }
        ys.insert(y, at: 0)
        // Recent-years cap: 5 (owner decision 2026-07-15; kept in sync with the Android companion).
        UserDefaults.standard.set(Array(ys.prefix(5)), forKey: Self.recentYearsKey)
    }

    // MARK: - Upload

    /// `queue.inFlightUploads` holds the ids currently uploading, so the auto-retry loop, `resumeUploads`, and a
    /// manual Retry can't fire the same item concurrently (double bandwidth + a racing ingest of the same
    /// filename on the Mac). This guard is what lets `resumeUploads` safely re-enqueue everything not yet
    /// UPLOADED. Mirrors Android.
    private func enqueueUpload(_ item: CapturedItem) {
        guard let c = client else { return }
        // W23.m8's port: the one choke point every send passes through. A page recovered against a session file
        // that never reached disk carries a group nobody chose, and the Mac's half of filing it has no undo. It
        // waits on the phone, visible and counted as unsent, until the operator classifies it.
        guard CaptureQueue.isSendable(item) else { return }
        guard !queue.isDeleting(item.id) else { return }   // its delete re-queues it if the photo is kept
        guard queue.beginUpload(item.id) else { return }   // already uploading this id
        setState(item.id, .uploading)
        sendStatusReport()   // reflect a just-captured/enqueued page on the Mac immediately (not only every 8s)
        let fileURL = item.fileURL
        let replaces = item.replacesGroupId   // durable on the item, so retries keep sending X-Replaces
        let generation = queue.generation      // a reply after Clear records nothing (W40.i-fix-ios-clear-generation)
        let pairing = queue.pairing            // a reply from a Mac since unpaired confirms nothing (W40.i-fix-ios-pairing-generation)
        uploadTasks[item.id] = Task {
            defer {
                // Releases only OUR claim: a retired send must never free the guard of the current Mac's send.
                let end = queue.finishUpload(item.id, generation: generation, pairing: pairing)
                if end.released { uploadTasks[item.id] = nil }
                // The pairing outlived this send (a stale reply, or one the re-pair cancelled), which left the page
                // UPLOADING: it is pending again, so send it to the Mac paired now, on a fresh Task so it runs after
                // this one is gone (a no-op while unpaired; the next pairing's resume sends it).
                if end.requeued {
                    persist()
                    statusMessage = queue.uploadSummary
                    Task { @MainActor in
                        if let latest = queue.item(item.id), latest.state == .pending { enqueueUpload(latest) }
                        sendStatusReport()   // the Mac paired now has to count this page again
                    }
                }
            }
            // Read the multi-MB JPEG off the main actor so the live camera UI doesn't hitch on
            // upload/retry bursts (enqueueUpload runs on the @MainActor view model).
            let data = await Task.detached { try? Data(contentsOf: fileURL) }.value
            var ok = false
            if let data {
                var attempt = 0
                while !ok && attempt < 3 && !Task.isCancelled {
                    ok = await c.postPhoto(jpeg: data, group: item.groupId, seq: item.seq, type: item.type.rawValue,
                                           quality: item.quality, year: item.year, month: item.month, device: deviceName,
                                           replaces: replaces)
                    attempt += 1
                }
            }
            // Clear took the session while this upload ran (nil): its photo is gone, and the reply must not mark,
            // count or report anything in the new one. Unpaired or re-paired (requeueStale): whichever Mac answered
            // is not the destination now, and recording the page uploaded would hide it from the new Mac and delete
            // the phone's only copy; the defer above puts it back in the queue instead. Android's W23.m1.
            guard let ack = queue.ackForReply(ok: ok, generation: generation, pairing: pairing),
                  ack != .requeueStale else { return }
            if ack == .confirm {
                sentCount += 1
                // A field changed while this upload was in flight (per-page Q3 / reclassify): the bytes just
                // sent are stale. Re-send with the CURRENT fields instead of confirming — do NOT
                // removeConfirmed (that would drop the photo having sent only the old value). The page goes
                // straight back to pending, never through a moment as uploaded-and-current, so neither the
                // heartbeat nor a lost re-enqueue can treat it as delivered. The re-enqueue is scheduled on a
                // fresh Task so it runs after this one's `defer` releases the in-flight guard.
                if queue.item(item.id)?.needsResend == true {
                    if queue.prepareDeferredResend(item.id) != nil { persist() }
                    Task { @MainActor in
                        if let latest = queue.item(item.id), latest.state == .pending { enqueueUpload(latest) }
                    }
                } else {
                    setState(item.id, .uploaded)
                    // Confirmed durably on the Mac → drop it from the phone shortly after (lets the strip
                    // animate it out), so photos transfer in segments instead of piling up.
                    Task { try? await Task.sleep(nanoseconds: 650_000_000); removeConfirmed(item) }
                    // If this was the last outstanding page of an ended segment, its completion signal was
                    // gated waiting for this upload — try it now (no-op if other pages are still in flight).
                    if queue.endedSegments[item.groupId] != nil { trySendSegmentComplete(group: item.groupId) }
                }
            } else {
                setState(item.id, .failed)
            }
            statusMessage = queue.uploadSummary
            sendStatusReport()   // reflect the new un-sent count promptly (this upload just settled)
        }
    }

    func retryFailed() { queue.failedItems.forEach { enqueueUpload($0) } }

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
            var savedIds = Set<Int64>()
            for item in toSave {
                // Guard the source exists (a concurrent upload-confirmation may have removed it) so a missing
                // file can't be silently counted as a saved backup — over-reporting a backup that isn't there.
                if await Self.writeToPhotos(item.fileURL) { savedIds.insert(item.id) }
            }
            let saved = savedIds.count
            // Display only: the saved thumbnails read as safe on the phone, not failed. Upload state is untouched.
            if queue.markSavedToPhone(savedIds) { persist() }
            statusMessage = saved == toSave.count
                ? "Saved \(saved) photo(s) to Photos"
                : "Saved \(saved) of \(toSave.count) — some couldn't be added to Photos"
            flash("Saved \(saved) to Photos")
        }
    }

    /// One photo into the Photos library, true only once the library reports it written. A missing source file is a
    /// failure, never a saved backup.
    private static func writeToPhotos(_ fileURL: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            }, completionHandler: { success, _ in cont.resume(returning: success) })
        }
    }

    /// The copy behind Save to Photos & delete: asks for add-only access first (a no-op once answered).
    private static func addToPhotos(_ fileURL: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await writeToPhotos(fileURL)
    }

    /// Re-send anything the Mac must still receive (in-flight/failed, still-PENDING, or a resend pending). Document pages now
    /// stream as shot, so a PENDING doc is simply one captured while unpaired/offline — send it too.
    /// Idempotent on the Mac (same group+seq → replace); the inFlightUploads guard prevents double-sends.
    private func resumeUploads() {
        guard client != nil else { return }
        queue.resumeCandidates.forEach { enqueueUpload($0) }
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
                // Flush anything not confirmed on the Mac — failed uploads, any still-PENDING page
                // (document pages now stream as shot, so a PENDING doc just hasn't reached the Mac yet),
                // and any page with a resend pending.
                let needs = self.queue.autoRetryCandidates
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

    /// A photo confirmed by the Mac is durably safe there, so remove it from the phone. The core guards it by
    /// identity + state, and keeps document pages of the current, un-ended segment in the strip until "End
    /// segment" so the operator sees the segment growing; markers leave as soon as they're confirmed.
    private func removeConfirmed(_ item: CapturedItem) {
        guard let removed = queue.removeConfirmed(item) else { return }
        try? FileManager.default.removeItem(at: removed.fileURL)
        if selectedItemId == item.id { clearSelection() }
        persist()
    }

    /// Delete every captured photo (files + persisted session) and start clean.
    /// Clear moves the queue's generation on and never reuses an id, so a send still running records nothing when
    /// it returns (W40.i-fix-ios-clear-generation). The sends are cancelled but not awaited before the files go:
    /// everything here runs on the main actor, so no stale reply can interleave with this method, and one that
    /// lands later is dropped by its generation check. An upload that already read its photo may still deliver
    /// it to the Mac, under the cleared session's group, as it could before; the Mac's Finish closes that group.
    func clearSession() {
        let removed = queue.clear()
        uploadTasks.values.forEach { $0.cancel() }
        segmentTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        segmentTasks.removeAll()
        for item in removed { try? FileManager.default.removeItem(at: item.fileURL) }
        clearSelection()
        sentCount = 0
        transferFlash = nil
        statusMessage = ""
        // Through the writer, so a save from before Clear still running can't land after it and bring the session
        // back (Android's StoreOperation.Clear). Nothing is left to have failed to save.
        if sessionWrites.offerClear() { startSessionWriter() }
        sessionNotSaved = false
        sendStatusReport()   // a 0 for the cleared session, ordered after any report from before Clear
    }

    // MARK: - Persistence / helpers

    private func restore(manifestWasStale: Bool) {
        let loaded = store.loadSession()
        var dropped: Set<String> = []
        if let snap = loaded.snapshot {
            // The core restores ended-but-unacked segments (their signal is re-sent below, still gated on all
            // their pages being uploaded), drops items already confirmed on the Mac except the current segment's
            // untagged document pages, and re-opens the tag card only if the app stopped mid-tagging. A listed photo
            // whose file is gone is skipped and reported: it never reached the Mac and has to be retaken.
            let restored = queue.restore(snap) { FileManager.default.fileExists(atPath: $0.fileURL.path) }
            for item in restored.dropped { try? FileManager.default.removeItem(at: item.fileURL) }
            dropped = Set(restored.dropped.map(\.fileURL.lastPathComponent))
            if !restored.missing.isEmpty || !restored.dropped.isEmpty { persist() }
            if !items.isEmpty { statusMessage = "Restored \(items.count) photo(s) from last session" }
            if !restored.missing.isEmpty {
                let n = restored.missing.count
                restoreWarning = "\(n) photo\(n == 1 ? "" : "s") from the last session \(n == 1 ? "is" : "are") no longer on this phone and never reached the Mac. Retake \(n == 1 ? "it" : "them") if the document is still at hand."
            }
        }
        // Self-heal orphans: photos on disk the session doesn't list (a crash between writing a photo and saving the
        // session, or a session file that could not be read) would otherwise never be shown, sent or cleaned up.
        // Against a stale or unreadable session file their classification is unknown, so they are held for review.
        let onDisk = ((try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("img_") }
        let held = manifestWasStale || loaded.unreadable
        if held { queue.skipSeqsAfterStaleRestore() }
        let adopted = queue.adoptOrphans(onDisk, known: dropped, manifestStale: held)
        if !adopted.isEmpty {
            statusMessage = held
                ? "Recovered \(adopted.count) photo(s) whose box/folder wasn't saved — tap Review to tag and send."
                : "Recovered \(adopted.count) untracked photo(s)"
            persist()
        }
        resumeUploads()
    }

    /// Hand the snapshot to the session writer: it never blocks, and only the newest waiting snapshot is written.
    private func persist() { if sessionWrites.offerSave(queue.snapshot()) { startSessionWriter() } }

    private var sessionWrites = SessionWriteMailbox<SessionStore.Snapshot>()

    /// The one session writer, draining the mailbox (W40.i-fix-ios-session-durability). It runs on the main actor, as
    /// every offer does, so the mailbox needs no lock; each file operation runs on a detached task so the camera UI
    /// never waits on storage. One writer at a time keeps the writes in order. It is the only place that can tell a
    /// snapshot that reached disk from one that didn't, so it alone sets `sessionNotSaved`; a later save that lands
    /// clears what an earlier failure raised.
    private func startSessionWriter() {
        let store = store
        // Ask iOS for time to finish if the app is backgrounded mid-drain, so a queued snapshot still lands. Without
        // it a suspension before the write starts leaves an older file with no stale flag (the write sets it).
        let background = UIApplication.shared.beginBackgroundTask(withName: "session-save")
        Task {
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            while let operation = sessionWrites.take() {
                switch operation {
                case .save(let snapshot):
                    let saved = await Task.detached { store.save(snapshot) }.value
                    if sessionNotSaved == saved { sessionNotSaved = !saved }
                case .clear:
                    await Task.detached { store.clear() }.value
                    sessionNotSaved = false
                }
            }
        }
    }

    private func setState(_ id: Int64, _ state: UploadState) {
        if queue.setState(id, state) { persist() }
    }

    private func flash(_ message: String) {
        transferFlash = message
        flashTask?.cancel()
        flashTask = Task { try? await Task.sleep(nanoseconds: 2_500_000_000); transferFlash = nil }
    }
}
