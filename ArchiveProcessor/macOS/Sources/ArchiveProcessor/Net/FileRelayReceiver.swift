import Foundation

/// Observable outcome of one `scanOnce()` pass — the deterministic unit the offline test asserts on
/// (all counts are OCR-free, so the driver needs no API key).
struct ScanReport: Sendable {
    var ingested: [String] = []
    var skippedUnchanged: [String] = []
    var receiptsWritten: [String] = []
    var sourcesDeleted: [String] = []
    var tombstoned: [String] = []
    var segmentsApplied: [String] = []
    var segmentsDeferred: [String] = []
    var rejectedUnsafe: [String] = []
    var ingestFailedLeftForRetry: [String] = []
    var sessionCompleted = false
}

/// Storage backend the receiver drains — a seam so the Google Drive backend reuses `FileRelayReceiver`'s
/// loop verbatim (`DriveObjectStore` over `changes.list`/`files.get`/`files.delete`/`appProperties`).
protocol RelayObjectStore: Sendable {
    func ensureSessionFolder() throws
    func publishEpoch(_ data: Data)                 // atomic write of _epoch.json (A2)
    func listNames() -> [String]                    // entries in the session folder (dotfiles/.part excluded)
    func readData(_ name: String) -> Data?
    func exists(_ name: String) -> Bool
    func modificationDate(_ name: String) -> Date?
    func writeAtomic(_ name: String, _ data: Data)  // temp→rename
    func delete(_ name: String)
    func quarantine(_ name: String)                 // move to .rejected/
}

/// A `CaptureReceiver` that drains a shared directory the phone writes into and funnels each page through
/// `CaptureSession.ingest` — acking (a receipt) and deleting a source object ONLY after `ingest` returned
/// non-nil. The local stand-in for the Google Drive relay; proves the never-lose-a-photo contract offline.
/// See `SPEC/relay-object-format.md` (v2 amendments bind). `@unchecked Sendable` + a serial queue for
/// lifecycle, mirroring `CaptureServer`; `processed` is mutated only inside single-flight `scanOnce`.
final class FileRelayReceiver: @unchecked Sendable, CaptureReceiver {
    private weak var session: CaptureSession?
    private let token: String
    private let epoch: String
    private let store: RelayObjectStore
    private let processedURL: URL
    private let queue = DispatchQueue(label: "capture.filerelay")
    private var timer: DispatchSourceTimer?
    private var processed: [String: Entry] = [:]
    private var running = false
    private var scanning = false
    private var scanCount = 0

    let pollInterval: TimeInterval
    /// Age gate for the orphan sweep. Coupling invariant (spec §7 #2): ≥ receiptWaitTimeout*3 + autoRetryGap.
    let sweepRetention: TimeInterval = 10 * 60
    // Test injection points (production defaults).
    var deleteSourceAfterReceipt = true
    var persistProcessedSet = true

    struct Entry: Codable { var fp: String; var tombstoned: Bool }

    init(session: CaptureSession, token: String, epoch: String, store: RelayObjectStore,
         processedURL: URL, pollInterval: TimeInterval = 1.0) {
        self.session = session
        self.token = token
        self.epoch = epoch
        self.store = store
        self.processedURL = processedURL
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() { queue.async { self.startOnQueue() } }

    func stop() {
        queue.async {
            self.timer?.cancel(); self.timer = nil; self.running = false
            let s = self.session
            Task { @MainActor in s?.relayReceiverDidStop() }
        }
    }

    private func startOnQueue() {
        guard !running else { return }
        running = true
        do { try store.ensureSessionFolder() }
        catch {
            let s = session; let msg = error.localizedDescription
            Task { @MainActor in s?.relayReceiverDidFail(msg) }
            running = false; return
        }
        store.publishEpoch(RelayObjectFormat.encodeEpochMarker(token: token, epoch: epoch))   // A2
        loadProcessed()
        let s = session; let dir = processedURL.deletingLastPathComponent().path
        Task { @MainActor in s?.relayReceiverDidStart(relayDir: dir) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !scanning else { return }   // single-flight
        scanning = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.scanOnce()
            self.queue.async { self.scanning = false }
        }
    }

    /// Test-only: run start-of-session setup (ensure folder, publish epoch, load the processed set) WITHOUT
    /// starting the poll timer, so a test can drive `scanOnce()` deterministically (incl. simulating a Mac
    /// restart by rebuilding the receiver against the same `processedURL`).
    func prepareForTest() {
        try? store.ensureSessionFolder()
        store.publishEpoch(RelayObjectFormat.encodeEpochMarker(token: token, epoch: epoch))
        loadProcessed()
    }

    // MARK: - The scan (deterministic; the test drives this directly)

    private func key(_ group: String, _ seq: Int) -> String { "\(group)\u{1}\(seq)" }

    @discardableResult
    func scanOnce() async -> ScanReport {
        var report = ScanReport()
        let names = store.listNames()
        var sidecars: [String] = [], segments: [String] = [], sessionCompletes: [String] = []
        for n in names {
            switch RelayObjectFormat.classify(n) {
            case .photo: sidecars.append(n)
            case .segmentComplete: segments.append(n)
            case .sessionComplete: sessionCompletes.append(n)
            default: break   // media drained via its sidecar; receipts/epoch/ignored skipped
            }
        }

        // ---- PHOTOS FIRST ----
        for sidecar in sidecars {
            guard let data = store.readData(sidecar), let meta = RelayObjectFormat.parse(data),
                  let group = meta["group"], let seqStr = meta["seq"], let seq = Int(seqStr) else { continue }
            let jpg = RelayObjectFormat.jpegName(group: group, seq: seq)
            guard store.exists(jpg) else { continue }   // media not yet committed (jpeg-then-sidecar): wait

            let type = meta["type"] ?? "document"
            let replaces = (meta["replaces"]?.isEmpty == false) ? meta["replaces"] : nil
            let chain = replaces?.split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? []
            let nameId = RelayObjectFormat.identityFromName(sidecar)
            let safe = CaptureValidation.isSafeGroupId(group) && seq >= 0
                && chain.allSatisfy { CaptureValidation.isSafeGroupId($0) }
                && CaptureValidation.isWireQuality(meta["quality"])
                && (nameId == nil || (nameId!.group == group && nameId!.seq == seq))   // A10
            let mine = meta["token"] == token && meta["epoch"] == epoch
            guard mine else { continue }   // other run's epoch/token → ignore (never destroy), let sweep age it out
            guard safe else {              // our run but unsafe (traversal/mismatch) → quarantine, never ingest
                store.quarantine(sidecar); store.quarantine(jpg); report.rejectedUnsafe.append(sidecar); continue
            }

            let k = key(group, seq)
            let fp = RelayObjectFormat.fingerprint(type: type, quality: meta["quality"],
                                                   year: meta["year"], month: meta["month"], replaces: replaces)
            if let e = processed[k], e.tombstoned {          // reclassified-away → drop the stale object
                store.delete(sidecar); store.delete(jpg); report.sourcesDeleted.append(k); continue
            }
            if let e = processed[k], e.fp == fp {            // durable + unchanged → no re-ingest/re-OCR
                ensureReceipt(group: group, seq: seq, fp: fp, report: &report)
                if deleteSourceAfterReceipt { store.delete(sidecar); store.delete(jpg); report.sourcesDeleted.append(k) }
                report.skippedUnchanged.append(k); continue
            }
            guard let jpeg = store.readData(jpg), !jpeg.isEmpty else { continue }   // unreadable → phone still holds it

            let ctype = CaptureGroupType(rawValue: type) ?? .document
            let s = session
            let url = await MainActor.run { () -> URL? in
                s?.ingest(jpeg: jpeg, groupId: group, seq: seq, type: ctype, quality: meta["quality"],
                          year: meta["year"].flatMap { Int($0) }, month: meta["month"].flatMap { Int($0) },
                          deviceName: meta["device"])
            }
            guard url != nil else { report.ingestFailedLeftForRetry.append(k); continue }   // invariant hinge

            processed[k] = Entry(fp: fp, tombstoned: false)
            if persistProcessedSet && !persistProcessed() {    // persist BEFORE deleting the source
                processed.removeValue(forKey: k)               // revert — not durable, leave source for retry
                report.ingestFailedLeftForRetry.append(k); continue
            }
            report.ingested.append(k)

            if !chain.isEmpty {                                // A3/A4 reclassify chain
                var tombKeys: [String] = []
                for prior in chain where prior != group {
                    await MainActor.run { s?.removePhotoIfSafe(groupId: prior, seq: seq) }
                    let tk = key(prior, seq)
                    processed[tk] = Entry(fp: "", tombstoned: true)
                    tombKeys.append(tk)
                    report.tombstoned.append(tk)
                }
                if persistProcessedSet && !persistProcessed() {  // A4: tombstones durable before their objects are dropped
                    for tk in tombKeys {
                        processed.removeValue(forKey: tk)           // revert tombstones
                        report.tombstoned.removeAll { $0 == tk }
                    }
                    // Don't delete source — next scan will re-ingest + re-tombstone
                    continue
                }
            }
            writeReceipt(group: group, seq: seq, fp: fp, report: &report)   // == HTTP "200"
            if deleteSourceAfterReceipt { store.delete(sidecar); store.delete(jpg); report.sourcesDeleted.append(k) }
        }

        // ---- CONTROLS (after photos) ----
        for seg in segments {
            guard let data = store.readData(seg), let meta = RelayObjectFormat.parse(data),
                  let group = meta["group"], meta["token"] == token, meta["epoch"] == epoch else { continue }
            guard CaptureValidation.isSafeGroupId(group), CaptureValidation.isWireQuality(meta["quality"]) else {
                store.quarantine(seg); report.rejectedUnsafe.append(seg); continue
            }
            let seqs = meta["seqs"]?.split(separator: ",").compactMap { Int($0) } ?? []
            let deferIt: Bool
            if !seqs.isEmpty {
                deferIt = seqs.contains { processed[key(group, $0)] == nil }   // any listed page never seen (A5/D6)
            } else {                                                            // fallback: any unprocessed photo remains
                deferIt = sidecars.contains { n in
                    guard let id = RelayObjectFormat.identityFromName(n), id.group == group else { return false }
                    return processed[key(group, id.seq)] == nil
                }
            }
            if deferIt { report.segmentsDeferred.append(group); continue }
            let s = session
            let durable = await MainActor.run {
                s?.markSegmentComplete(groupId: group, quality: meta["quality"],
                                       year: meta["year"].flatMap { Int($0) },
                                       month: meta["month"].flatMap { Int($0) }) ?? false
            }
            if !durable { report.segmentsDeferred.append(group); continue }
            store.delete(seg); report.segmentsApplied.append(group)
        }

        // A session-complete marker force-completes the whole session (completeAllOpenDocGroups → tag
        // cards), so it must be gated on token+epoch EXACTLY like the photo/segment branches — the fixed
        // filename `_session.complete.json` alone is not proof of ownership. Parse each marker's body and
        // keep only those matching THIS run; a stale marker from a prior run (foreign epoch/token) is left
        // untouched — not acted on, not deleted (the sweep ages foreign objects out).
        let mySessionCompletes = sessionCompletes.filter { n in
            guard let data = store.readData(n), let meta = RelayObjectFormat.parse(data) else { return false }
            return meta["token"] == token && meta["epoch"] == epoch
        }
        if !mySessionCompletes.isEmpty {
            let anyUnprocessed = sidecars.contains { n in
                guard let id = RelayObjectFormat.identityFromName(n) else { return false }
                return processed[key(id.group, id.seq)] == nil
            }
            if !anyUnprocessed && report.segmentsDeferred.isEmpty {
                let s = session
                let durable = await MainActor.run {
                    let durable = s?.completeAllOpenDocGroups() ?? false
                    if durable {
                        s?.statusMessage = "Phone finished capturing — review any remaining tag cards, then Finish session."
                    }
                    return durable
                }
                if durable {
                    for n in mySessionCompletes { store.delete(n) }
                    report.sessionCompleted = true
                }
            }
        }

        scanCount += 1
        if scanCount % 30 == 0 {
            // Re-assert the epoch marker (idempotent) so a transient start-time publish failure — e.g. a Drive
            // 5xx/rate-limit when the DriveObjectStore first wrote _epoch.json — self-heals instead of leaving
            // the phone polling forever for an epoch that never appeared (a silent dead session).
            store.publishEpoch(RelayObjectFormat.encodeEpochMarker(token: token, epoch: epoch))
            sweep()
        }
        return report
    }

    // MARK: - Receipts

    private func writeReceipt(group: String, seq: Int, fp: String, report: inout ScanReport) {
        store.writeAtomic(RelayObjectFormat.receiptName(group: group, seq: seq),
                          RelayObjectFormat.encodeReceipt(token: token, epoch: epoch, group: group, seq: seq, fp: fp))
        report.receiptsWritten.append(key(group, seq))
    }
    private func ensureReceipt(group: String, seq: Int, fp: String, report: inout ScanReport) {
        if !store.exists(RelayObjectFormat.receiptName(group: group, seq: seq)) {
            writeReceipt(group: group, seq: seq, fp: fp, report: &report)
        }
    }

    // MARK: - Orphan sweep (age-gated, A9)

    private func sweep() {
        let now = Date()
        let names = store.listNames()
        let mediaPresent = Set(names.filter { $0.hasSuffix(".jpg") })
        let sidecarJpgs = Set(names.filter { RelayObjectFormat.classify($0) == .photo }
            .compactMap { RelayObjectFormat.identityFromName($0).map { RelayObjectFormat.jpegName(group: $0.group, seq: $0.seq) } })
        for n in names {
            guard let m = store.modificationDate(n), now.timeIntervalSince(m) > sweepRetention else { continue }
            switch RelayObjectFormat.classify(n) {
            case .media:
                if !sidecarJpgs.contains(n) { store.delete(n); continue }            // sidecar-less media (aged)
                if let id = RelayObjectFormat.identityFromName(n), processed[key(id.group, id.seq)] != nil { store.delete(n) }
            case .photo:
                guard let id = RelayObjectFormat.identityFromName(n) else { continue }
                if !mediaPresent.contains(RelayObjectFormat.jpegName(group: id.group, seq: id.seq)) { store.delete(n); continue }
                if processed[key(id.group, id.seq)] != nil { store.delete(n) }         // drained
            case .receipt:
                guard let id = RelayObjectFormat.identityFromName(n) else { continue }
                if processed[key(id.group, id.seq)] != nil { store.delete(n) }         // receipt cleanup after drained
            default: break
            }
        }
    }

    // MARK: - Processed-set persistence (epoch-scoped, in the Mac's private incomingFolder)

    private struct PersistedEntry: Codable { let group: String; let seq: Int; let fp: String; let tombstoned: Bool }
    private struct ProcessedFile: Codable { let version: Int; let token: String; let epoch: String; let entries: [PersistedEntry] }

    private func loadProcessed() {
        processed = [:]
        guard let data = try? Data(contentsOf: processedURL),
              let file = try? JSONDecoder().decode(ProcessedFile.self, from: data),
              file.token == token, file.epoch == epoch else { return }   // epoch-scoped (A2/D10)
        for e in file.entries { processed[key(e.group, e.seq)] = Entry(fp: e.fp, tombstoned: e.tombstoned) }
    }

    @discardableResult
    private func persistProcessed() -> Bool {
        var entries: [PersistedEntry] = []
        for (k, v) in processed {
            let parts = k.split(separator: "\u{1}", maxSplits: 1)
            guard parts.count == 2, let seq = Int(parts[1]) else { continue }
            entries.append(PersistedEntry(group: String(parts[0]), seq: seq, fp: v.fp, tombstoned: v.tombstoned))
        }
        let file = ProcessedFile(version: 1, token: token, epoch: epoch, entries: entries)
        guard let data = try? JSONEncoder().encode(file) else { return false }
        let tmp = processedURL.deletingLastPathComponent().appendingPathComponent(".relay-processed.\(UUID().uuidString).part")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: processedURL)
            try FileManager.default.moveItem(at: tmp, to: processedURL)
            return true
        } catch { try? FileManager.default.removeItem(at: tmp); return false }
    }
}

/// The local-filesystem `RelayObjectStore` used for the FileRelay (offline stand-in for Drive).
final class LocalDirectoryStore: RelayObjectStore, @unchecked Sendable {
    private let dir: URL
    init(dir: URL) { self.dir = dir }

    func ensureSessionFolder() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func publishEpoch(_ data: Data) { writeAtomic(RelayObjectFormat.epochMarkerName, data) }

    func listNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".part") }
    }
    func readData(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
    func modificationDate(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.modificationDate]) as? Date
    }
    func writeAtomic(_ name: String, _ data: Data) {
        let final = dir.appendingPathComponent(name)
        let tmp = dir.appendingPathComponent("." + name + ".\(UUID().uuidString).part")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: tmp, to: final)
        } catch { try? FileManager.default.removeItem(at: tmp) }
    }
    func delete(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    func quarantine(_ name: String) {
        let rejected = dir.appendingPathComponent(".rejected", isDirectory: true)
        try? FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: dir.appendingPathComponent(name),
                                          to: rejected.appendingPathComponent(name))
    }
}
