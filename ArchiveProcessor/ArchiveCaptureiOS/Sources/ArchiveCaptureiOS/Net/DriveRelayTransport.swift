import Foundation

/// A `SegmentTransport` that uploads to Google Drive (the production cloud relay) — the same
/// receipt-wait contract as `FileRelayTransport`, but over Drive REST via `DriveClient`. `postPhoto`
/// returns `true` ONLY after the Mac's matching-`(token,epoch,group,seq,fp)` receipt appears, never on a
/// write alone (never-lose). Adopts the Mac-published epoch from `_epoch.json` in the shared Drive folder.
///
/// Uses **query-or-update** (find the file by `appProperties.relayName`, then update it, else create) — so
/// it never stores a fileId to lose, side-stepping the coexisting-duplicate hazard at the source (the Mac's
/// reap is the backstop). `client`'s token provider is a Google OAuth access token for the SAME account as
/// the Mac; the on-device sign-in that supplies it is the device-session follow-up. Tests inject a mock
/// `DriveClient`.
struct DriveRelayTransport: SegmentTransport {
    let client: DriveClient
    let token: String
    var receiptWaitTimeout: TimeInterval = 20
    var receiptPollInterval: TimeInterval = 0.5

    private func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "\\'") }

    /// The Mac creates the session folder + publishes `_epoch.json` on relay start; the phone only finds it.
    private func folderId() -> String? {
        (try? client.listFiles(query: "mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='relayToken' and value='\(esc(token))' } and trashed = false"))?.first?.id
    }
    private func fileId(_ folder: String, _ name: String) -> String? {
        (try? client.listFiles(query: "'\(esc(folder))' in parents and appProperties has { key='relayName' and value='\(esc(name))' } and trashed = false"))?.first?.id
    }
    private func upsert(_ folder: String, _ name: String, _ data: Data, _ mime: String) throws {
        if let id = fileId(folder, name) { try client.updateMedia(fileId: id, media: data, mimeType: mime) }
        else { _ = try client.createFile(name: name, parents: [folder], appProperties: ["relayName": name, "relayToken": token], media: data, mimeType: mime) }
    }
    private func read(_ folder: String, _ name: String) -> Data? {
        guard let id = fileId(folder, name) else { return nil }
        return try? client.getMedia(fileId: id)
    }
    private func epoch(_ folder: String) -> String? {
        guard let d = read(folder, RelayObjectFormat.epochMarkerName), let m = RelayObjectFormat.parse(d), m["token"] == token else { return nil }
        return m["epoch"]
    }
    private func validReceipt(_ folder: String, group: String, seq: Int, epoch: String, fp: String) -> Bool {
        guard let d = read(folder, RelayObjectFormat.receiptName(group: group, seq: seq)), let m = RelayObjectFormat.parse(d) else { return false }
        return m["kind"] == "receipt" && m["token"] == token && m["epoch"] == epoch
            && m["group"] == group && m["seq"] == String(seq) && m["fp"] == fp
    }

    func postPhoto(jpeg: Data, group: String, seq: Int, type: String, quality: String?,
                   year: Int?, month: Int?, device: String, replaces: String?) async -> Bool {
        let yearS = year.map(String.init), monthS = month.map(String.init)
        let repl = (replaces?.isEmpty == false) ? replaces : nil
        let fp = RelayObjectFormat.fingerprint(type: type, quality: quality, year: yearS, month: monthS, replaces: repl)
        let deadline = Date().addingTimeInterval(receiptWaitTimeout)
        var folder: String?, wroteForEpoch: String?
        repeat {
            if folder == nil { folder = folderId() }                       // resolve once (Mac's folder)
            guard let f = folder else { try? await Task.sleep(nanoseconds: 1_000_000_000); continue }  // Mac relay not up
            guard let e = epoch(f) else { try? await Task.sleep(nanoseconds: 1_000_000_000); continue } // re-read each iteration (epoch may change on Mac restart)
            if validReceipt(f, group: group, seq: seq, epoch: e, fp: fp) { return true }                // receipt-first
            if wroteForEpoch != e {                                         // write-once per epoch (re-write if epoch changes)
                try? upsert(f, RelayObjectFormat.jpegName(group: group, seq: seq), jpeg, "image/jpeg")
                try? upsert(f, RelayObjectFormat.sidecarName(group: group, seq: seq),
                       RelayObjectFormat.encodeSidecar(token: token, epoch: e, group: group, seq: seq, type: type,
                           quality: quality, year: yearS, month: monthS, replaces: repl, device: device), "application/json")
                wroteForEpoch = e
            }
            try? await Task.sleep(nanoseconds: UInt64(receiptPollInterval * 1_000_000_000))
        } while Date() < deadline
        return false   // timeout → .failed → auto-retry re-enters (re-resolves epoch); local copy retained
    }

    func segmentComplete(group: String, quality: String?, year: Int?, month: Int?, seqs: String?) async -> Bool {
        guard let f = folderId(), let e = epoch(f) else { return false }
        do {
            try upsert(f, RelayObjectFormat.segmentName(group: group),
                   RelayObjectFormat.encodeSegment(token: token, epoch: e, group: group,
                       quality: quality, year: year.map(String.init), month: month.map(String.init), seqs: seqs), "application/json")
            return true
        } catch { return false }
    }
    func sessionComplete() async -> Bool {
        guard let f = folderId(), let e = epoch(f) else { return false }
        do {
            try upsert(f, RelayObjectFormat.sessionCompleteName, RelayObjectFormat.encodeSessionComplete(token: token, epoch: e), "application/json")
            return true
        } catch { return false }
    }
    func sessionDisconnect() async -> Bool { true }
}
