import Foundation
import AppKit

/// Headless, key-free, $0 invariant test for the FileRelay receiver, gated by `FILERELAY_TESTMODE=1`
/// (does nothing in normal use). Drives `FileRelayReceiver.scanOnce()` DIRECTLY (no timer, no sleeps) in
/// stage-for-later mode (so `ingest` never triggers OCR) against a temp relay dir, asserting the
/// never-lose-a-photo contract + the v2 amendments (LIVE_CAPTURE_FILERELAY_SPEC.md). Writes results.json
/// + DONE.txt for the Tier-2 harness. Test-only scaffolding.
@MainActor
enum FileRelayTestDriver {
    private static var didRun = false

    static func runIfRequested(session: CaptureSession) {
        guard !didRun, ProcessInfo.processInfo.environment["FILERELAY_TESTMODE"] == "1" else { return }
        didRun = true
        Task { await run(session: session) }
    }

    private struct CaseResult: Codable { let name: String; let pass: Bool; let detail: String }
    private struct Results: Codable { let allPass: Bool; let cases: [CaseResult] }

    static func run(session: CaptureSession) async {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["FILERELAY_RELAYROOT"]
                       ?? (NSTemporaryDirectory() + "filerelay-test-\(UUID().uuidString)"), isDirectory: true)
        let outDir = URL(fileURLWithPath: env["FILERELAY_TESTOUT"] ?? root.appendingPathComponent("out").path, isDirectory: true)
        let donePath = env["FILERELAY_TESTDONE"] ?? outDir.appendingPathComponent("DONE.txt").path
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        session.beginStageSessionForTest()
        let token = session.token
        let epoch = "EP1"
        let fm = FileManager.default
        var results: [CaseResult] = []
        func rec(_ name: String, _ pass: Bool, _ detail: String = "") {
            results.append(CaseResult(name: name, pass: pass, detail: detail))
            NSLog("FILERELAY[\(pass ? "PASS" : "FAIL")] \(name) — \(detail)")
        }

        // Helpers
        func caseDir(_ n: String) -> URL {
            let d = root.appendingPathComponent(n, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true); return d
        }
        func makeRcv(_ dir: URL) -> FileRelayReceiver {
            let r = FileRelayReceiver(session: session, token: token, epoch: epoch,
                                      store: LocalDirectoryStore(dir: dir),
                                      processedURL: dir.appendingPathComponent("processed.json"), pollInterval: 999)
            r.prepareForTest(); return r
        }
        func writePhoto(_ dir: URL, _ g: String, _ s: Int, _ type: String, priority: String? = nil,
                        year: String? = nil, month: String? = nil, replaces: String? = nil, ep: String? = nil) {
            // jpeg first, sidecar last (commit-marker order)
            try? Data("jpeg-\(g)-\(s)".utf8).write(to: dir.appendingPathComponent(RelayObjectFormat.jpegName(group: g, seq: s)))
            let side = RelayObjectFormat.encodeSidecar(token: token, epoch: ep ?? epoch, group: g, seq: s, type: type,
                                                       priority: priority, year: year, month: month, replaces: replaces)
            try? side.write(to: dir.appendingPathComponent(RelayObjectFormat.sidecarName(group: g, seq: s)))
        }
        func has(_ dir: URL, _ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func photoCount(_ g: String) -> Int { session.photos.filter { $0.groupId == g }.count }
        func priorityOf(_ g: String, _ s: Int) -> String? { session.photos.first { $0.groupId == g && $0.seq == s }?.priority }

        // ── Case 1: happy path + (group,seq) idempotency ──
        do {
            let d = caseDir("c1"); let r = makeRcv(d)
            writePhoto(d, "c1g0", 0, "document"); writePhoto(d, "c1g0", 1, "document")
            let a = await r.scanOnce()
            var pass = a.ingested.count == 2 && photoCount("c1g0") == 2
                && has(d, RelayObjectFormat.receiptName(group: "c1g0", seq: 0))
                && !has(d, RelayObjectFormat.jpegName(group: "c1g0", seq: 0))   // source deleted
            writePhoto(d, "c1g0", 0, "document")                                // identical re-send
            let b = await r.scanOnce()
            pass = pass && b.skippedUnchanged.contains("c1g0\u{1}0") && b.ingested.isEmpty && photoCount("c1g0") == 2
            rec("happy+idempotency", pass, "ingested=\(a.ingested.count) reSkip=\(b.skippedUnchanged) photos=\(photoCount("c1g0"))")
        }

        // ── Case 2: metadata fingerprint (A1) — a P10 change re-ingests; identical does not ──
        do {
            let d = caseDir("c2"); let r = makeRcv(d)
            writePhoto(d, "c2g0", 0, "document"); _ = await r.scanOnce()
            writePhoto(d, "c2g0", 0, "document", priority: "P10")              // fp differs
            let b = await r.scanOnce()
            let pass = b.ingested.contains("c2g0\u{1}0") && priorityOf("c2g0", 0) == "P10"
            rec("fingerprint-metadata-change(A1)", pass, "reIngested=\(b.ingested) priority=\(priorityOf("c2g0",0) ?? "nil")")
        }

        // ── Case 3: nil ingest → NO receipt, source NOT deleted (never-lose hinge) ──
        do {
            let d = caseDir("c3"); let r = makeRcv(d)
            writePhoto(d, "c3g0", 0, "document")
            session.testForceIngestFailure = true
            let a = await r.scanOnce()
            let leftAfterFail = a.ingestFailedLeftForRetry.contains("c3g0\u{1}0")
                && !has(d, RelayObjectFormat.receiptName(group: "c3g0", seq: 0))
                && has(d, RelayObjectFormat.jpegName(group: "c3g0", seq: 0))
            let b = await r.scanOnce()                                          // now succeeds
            let recovered = b.ingested.contains("c3g0\u{1}0")
                && has(d, RelayObjectFormat.receiptName(group: "c3g0", seq: 0))
                && !has(d, RelayObjectFormat.jpegName(group: "c3g0", seq: 0))
            rec("nil-ingest-receipt-before-delete", leftAfterFail && recovered, "leftAfterFail=\(leftAfterFail) recovered=\(recovered)")
        }

        // ── Case 4: no double-ingest across a Mac restart (ingest-before-delete) ──
        do {
            let d = caseDir("c4")
            let r1 = makeRcv(d); r1.deleteSourceAfterReceipt = false
            writePhoto(d, "c4g0", 0, "document")
            let a = await r1.scanOnce()                                         // ingests, persists, receipt, leaves source
            let r2 = makeRcv(d)                                                 // "restart" — reloads processed.json
            let b = await r2.scanOnce()
            let pass = a.ingested.contains("c4g0\u{1}0") && b.ingested.isEmpty
                && b.skippedUnchanged.contains("c4g0\u{1}0") && !has(d, RelayObjectFormat.jpegName(group: "c4g0", seq: 0))
            rec("no-double-ingest-across-restart", pass, "pass1=\(a.ingested) pass2ingested=\(b.ingested) pass2skip=\(b.skippedUnchanged)")
        }

        // ── Case 5: backstop when processed-set is lost → re-ingest, still exactly one photo ──
        do {
            let d = caseDir("c5")
            let r1 = makeRcv(d); r1.deleteSourceAfterReceipt = false; r1.persistProcessedSet = false
            writePhoto(d, "c5g0", 0, "document"); _ = await r1.scanOnce()       // ingests, does NOT persist set, leaves source
            let r2 = makeRcv(d)                                                 // reload → empty set
            let b = await r2.scanOnce()
            let pass = b.ingested.contains("c5g0\u{1}0") && photoCount("c5g0") == 1   // idempotent (group,seq) replace
            rec("processed-set-lost-backstop", pass, "reIngested=\(b.ingested) photos=\(photoCount("c5g0"))")
        }

        // ── Case 6: reclassify replaces-chain (A3) — no resurrection, full chain tombstoned ──
        do {
            let d = caseDir("c6"); let r = makeRcv(d)
            writePhoto(d, "c6g0", 5, "document"); _ = await r.scanOnce()
            writePhoto(d, "c6g1", 5, "box", replaces: "c6g0"); _ = await r.scanOnce()
            let afterReclass = photoCount("c6g1") == 1 && photoCount("c6g0") == 0
            writePhoto(d, "c6g0", 5, "document")                               // lingering old object re-appears
            _ = await r.scanOnce()                                             // must be dropped (tombstoned), not resurrected
            let noResurrect = photoCount("c6g0") == 0 && photoCount("c6g1") == 1
            writePhoto(d, "c6g2", 5, "folder", replaces: "c6g0,c6g1"); _ = await r.scanOnce()   // full chain
            let seq5Groups = Set(session.photos.filter { $0.seq == 5 }.map { $0.groupId })
            let chainOK = seq5Groups == ["c6g2"]
            rec("reclassify-chain(A3)", afterReclass && noResurrect && chainOK, "afterReclass=\(afterReclass) noResurrect=\(noResurrect) seq5=\(seq5Groups)")
        }

        // ── Case 7: segment-complete deferral until all seqs processed (A5/D6) ──
        do {
            let d = caseDir("c7"); let r = makeRcv(d)
            writePhoto(d, "c7g2", 0, "document")
            try? RelayObjectFormat.encodeSegment(token: token, epoch: epoch, group: "c7g2", priority: nil,
                                                 year: "1968", month: "3", seqs: "0,1")
                .write(to: d.appendingPathComponent(RelayObjectFormat.segmentName(group: "c7g2")))
            let a = await r.scanOnce()                                          // seq 1 missing → defer
            let deferred = a.segmentsDeferred.contains("c7g2") && !session.completedDocGroups.contains("c7g2")
            writePhoto(d, "c7g2", 1, "document")
            let b = await r.scanOnce()                                          // now complete → apply
            let applied = b.segmentsApplied.contains("c7g2") && session.completedDocGroups.contains("c7g2")
                && !has(d, RelayObjectFormat.segmentName(group: "c7g2"))
            rec("segment-deferral(A5/D6)", deferred && applied, "deferred=\(deferred) applied=\(applied)")
        }

        // ── Case 8: traversal + epoch guards (A2 publish, A10 filename==body, wrong-epoch ignored) ──
        do {
            let d = caseDir("c8"); let r = makeRcv(d)
            let epochPublished = has(d, RelayObjectFormat.epochMarkerName)      // A2
            // A10: filename c8ok__0 but body group c8bad (paired jpg matches the BODY group so it's "ready")
            try? Data("j".utf8).write(to: d.appendingPathComponent("c8bad__0.jpg"))
            try? RelayObjectFormat.encodeSidecar(token: token, epoch: epoch, group: "c8bad", seq: 0, type: "document",
                                                 priority: nil, year: nil, month: nil, replaces: nil)
                .write(to: d.appendingPathComponent("c8ok__0.json"))
            // wrong-epoch object → ignored (never ingested, never destroyed)
            writePhoto(d, "c8ep", 0, "document", ep: "OLD-EPOCH")
            let a = await r.scanOnce()
            let a10 = a.rejectedUnsafe.contains("c8ok__0.json") && photoCount("c8bad") == 0
            let wrongEpochIgnored = !a.ingested.contains("c8ep\u{1}0") && photoCount("c8ep") == 0
                && has(d, RelayObjectFormat.jpegName(group: "c8ep", seq: 0))   // left in place
            rec("traversal+epoch-guards(A2/A10)", epochPublished && a10 && wrongEpochIgnored,
                "epochPublished=\(epochPublished) a10rejected=\(a10) wrongEpochIgnored=\(wrongEpochIgnored)")
        }

        session.clear()   // tidy the test session folder

        let allPass = results.allSatisfy { $0.pass }
        if let data = try? JSONEncoder().encode(Results(allPass: allPass, cases: results)) {
            try? data.write(to: outDir.appendingPathComponent("results.json"), options: .atomic)
        }
        try? "\(allPass ? "PASS" : "FAIL") \(results.filter { $0.pass }.count)/\(results.count)\n"
            .write(toFile: donePath, atomically: true, encoding: .utf8)
        NSLog("FILERELAY: DONE allPass=\(allPass) \(results.filter { $0.pass }.count)/\(results.count)")
    }
}
