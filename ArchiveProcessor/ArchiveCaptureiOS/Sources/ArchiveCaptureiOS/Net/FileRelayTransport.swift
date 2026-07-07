import Foundation

/// A `SegmentTransport` that writes into a shared directory (the offline stand-in for the Google Drive
/// relay) instead of HTTP. `postPhoto` returns `true` ONLY after the Mac's `FileRelayReceiver` writes a
/// matching receipt — never on write success alone — upholding the never-lose-a-photo contract. Reads the
/// Mac-published epoch from `_epoch.json` (A2). Byte-format via `RelayObjectFormat` (golden-guarded).
///
/// This milestone constructs it DIRECTLY from tests (the on-device pairing/UI wiring lands with the Drive
/// backend, per `LIVE_CAPTURE_FILERELAY_SPEC.md` §8), so the shipped HTTP `MacClient` path is untouched.
struct FileRelayTransport: SegmentTransport {
    let sessionDir: URL          // <relayRoot>/<token>/
    let token: String
    var receiptWaitTimeout: TimeInterval = 20
    var receiptPollInterval: TimeInterval = 0.5

    private func currentEpoch() -> String? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent(RelayObjectFormat.epochMarkerName)),
              let m = RelayObjectFormat.parse(d), m["token"] == token, let e = m["epoch"] else { return nil }
        return e
    }

    private func writeAtomic(_ name: String, _ data: Data) {
        let final = sessionDir.appendingPathComponent(name)
        let tmp = sessionDir.appendingPathComponent("." + name + ".\(UUID().uuidString).part")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: tmp, to: final)
        } catch { try? FileManager.default.removeItem(at: tmp) }
    }

    private func validReceipt(group: String, seq: Int, epoch: String, fp: String) -> Bool {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent(RelayObjectFormat.receiptName(group: group, seq: seq))),
              let m = RelayObjectFormat.parse(d) else { return false }
        // A1: accept ONLY a receipt acking the CURRENT metadata (fp) for THIS run (epoch) — so a stale ack
        // (e.g. before a P10 change, or from a prior run) does not falsely confirm.
        return m["kind"] == "receipt" && m["token"] == token && m["epoch"] == epoch
            && m["group"] == group && m["seq"] == String(seq) && m["fp"] == fp
    }

    func postPhoto(jpeg: Data, group: String, seq: Int, type: String, priority: String?,
                   year: Int?, month: Int?, device: String, replaces: String?) async -> Bool {
        let yearS = year.map(String.init), monthS = month.map(String.init)
        let repl = (replaces?.isEmpty == false) ? replaces : nil
        let fp = RelayObjectFormat.fingerprint(type: type, priority: priority, year: yearS, month: monthS, replaces: repl)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(receiptWaitTimeout)
        var wroteForEpoch: String?
        repeat {
            guard let epoch = currentEpoch() else {   // Mac relay not up yet → can't be acked → retry later (not a loss)
                try? await Task.sleep(nanoseconds: UInt64(receiptPollInterval * 1_000_000_000)); continue
            }
            if validReceipt(group: group, seq: seq, epoch: epoch, fp: fp) { return true }   // (a) receipt-first
            if wroteForEpoch != epoch {                                                     // (b) write-once per epoch
                writeAtomic(RelayObjectFormat.jpegName(group: group, seq: seq), jpeg)       // jpeg FIRST
                writeAtomic(RelayObjectFormat.sidecarName(group: group, seq: seq),          // sidecar LAST = commit marker
                            RelayObjectFormat.encodeSidecar(token: token, epoch: epoch, group: group, seq: seq,
                                type: type, priority: priority, year: yearS, month: monthS, replaces: repl, device: device))
                wroteForEpoch = epoch
            }
            try? await Task.sleep(nanoseconds: UInt64(receiptPollInterval * 1_000_000_000))  // (c) poll
        } while Date() < deadline
        return false   // timeout → item stays .failed → auto-retry re-enters at (a); local copy retained
    }

    func segmentComplete(group: String, priority: String?, year: Int?, month: Int?) async -> Bool {
        guard let epoch = currentEpoch() else { return false }
        writeAtomic(RelayObjectFormat.segmentName(group: group),
                    RelayObjectFormat.encodeSegment(token: token, epoch: epoch, group: group,
                        priority: priority, year: year.map(String.init), month: month.map(String.init), seqs: nil))
        return true
    }

    func sessionComplete() async -> Bool {
        guard let epoch = currentEpoch() else { return false }
        writeAtomic(RelayObjectFormat.sessionCompleteName, RelayObjectFormat.encodeSessionComplete(token: token, epoch: epoch))
        return true
    }

    func sessionDisconnect() async -> Bool { true }   // no persistent connection to drop
}
