import Foundation
import AppKit

/// Headless, $0 self-test of the Live Capture session-manifest persistence (B5-ii), gated by
/// `LIVECAPTURE_MANIFESTTEST=1` (does nothing in normal use). Proves — with synthetic data in a temp dir,
/// no OCR/network/GUI, never touching a real backup folder — that:
///   1. `completedDocGroups` round-trips through the real crash-safe (`.atomic`) write + JSON decode path,
///      so a mid-session Mac restart re-surfaces each completed segment's tag card (the fixed bug).
///   2. The photo entries round-trip alongside it (grouping/tags preserved).
///   3. A LEGACY bare-array manifest (pre-B5 builds) still decodes — entries intact, completion set empty —
///      so recovery of an in-flight legacy session is never broken (the ingest recovery invariant holds).
///   4. Corrupt (non-JSON) bytes decode to nil (ignored, not misapplied).
///
/// Writes a PASS/FAIL report to `LIVECAPTURE_MANIFESTTEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum ManifestPersistenceTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["LIVECAPTURE_MANIFESTTEST"] == "1" else { return }
        didRun = true
        run()
    }

    static func run() {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("MANIFESTTEST \(ok ? "PASS" : "FAIL"): \(name)")
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("APManifestTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("manifest.json")

        typealias Entry = CaptureSession.ManifestEntry
        let entries = [
            Entry(name: "00001-gDoc.jpg", groupId: "gDoc", seq: 1, type: "document", priority: "P8", year: 1968, month: 3),
            Entry(name: "00002-gDoc.jpg", groupId: "gDoc", seq: 2, type: "document", priority: nil, year: 1968, month: 3),
            Entry(name: "00003-gBox.jpg", groupId: "gBox", seq: 3, type: "box", priority: nil, year: nil, month: nil),
        ]
        let completed: Set<String> = ["gDoc"]   // gDoc's segment was signalled complete; gBox is a marker

        // --- 1+2: current object form round-trips (photos AND completedDocGroups). ---
        let manifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: Array(completed))
        let wrote = (try? JSONEncoder().encode(manifest)).map { (try? $0.write(to: file, options: .atomic)) != nil } ?? false
        check("manifest written via atomic (.atomic) path", wrote && fm.fileExists(atPath: file.path))

        let roundTrip = (try? Data(contentsOf: file)).flatMap { CaptureSession.decodeManifest($0) }
        check("manifest round-trips (decodes back)", roundTrip != nil)
        check("completedDocGroups survives the round-trip", roundTrip?.completed == completed)
        check("photo entries survive the round-trip (count + fields)",
              roundTrip?.entries.count == 3
              && roundTrip?.entries.first?.groupId == "gDoc"
              && roundTrip?.entries.first?.priority == "P8"
              && roundTrip?.entries.first?.year == 1968
              && roundTrip?.entries.last?.type == "box")

        // --- 3: a legacy bare-array manifest (pre-B5) still decodes — entries intact, completion empty. ---
        let legacyData = (try? JSONEncoder().encode(entries)) ?? Data()
        let legacy = CaptureSession.decodeManifest(legacyData)
        check("legacy bare-array manifest still decodes (recovery unbroken)", legacy != nil)
        check("legacy manifest keeps all photo entries", legacy?.entries.count == 3)
        check("legacy manifest completion set is empty (unchanged pre-B5 behavior)", legacy?.completed.isEmpty == true)

        // --- object form with an EMPTY completion set decodes fine (no false positives). ---
        let emptyManifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: [])
        let emptyDecoded = (try? JSONEncoder().encode(emptyManifest)).flatMap { CaptureSession.decodeManifest($0) }
        check("object manifest with empty completion set decodes with no completed groups",
              emptyDecoded != nil && emptyDecoded?.completed.isEmpty == true && emptyDecoded?.entries.count == 3)

        // --- 4: corrupt bytes decode to nil (ignored). ---
        check("corrupt (non-JSON) manifest bytes decode to nil (ignored)",
              CaptureSession.decodeManifest(Data("not json {".utf8)) == nil)

        // --- B9: resolvedGroupIds + macTags round-trip so a mid-session Mac restart does NOT re-surface an
        //         already-resolved tag card (nor drop its Mac-entered tags). Optional keys => pre-B9
        //         manifests still decode, to empty (back-compat). ---
        let b9File = tmp.appendingPathComponent("b9.json")
        let macTags: [String: MacSegmentTags] = [
            "gDoc": MacSegmentTags(subjects: ["elections", "1968 campaign"], priority: "P8", year: 1968, month: 3)
        ]
        let b9Manifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: Array(completed),
                                                        resolvedGroupIds: ["gDoc"], macTags: macTags)
        let b9Wrote = (try? JSONEncoder().encode(b9Manifest)).map { (try? $0.write(to: b9File, options: .atomic)) != nil } ?? false
        let b9 = (try? Data(contentsOf: b9File)).flatMap { CaptureSession.decodeManifest($0) }
        check("B9: manifest with resolved/macTags written + decodes", b9Wrote && b9 != nil)
        check("B9: resolvedGroupIds survives the round-trip", b9?.resolved == ["gDoc"])
        check("B9: macTags survives the round-trip (subjects + date + priority)",
              b9?.macTags["gDoc"]?.subjects == ["elections", "1968 campaign"]
              && b9?.macTags["gDoc"]?.year == 1968 && b9?.macTags["gDoc"]?.priority == "P8")
        check("B9 back-compat: pre-B9 manifest (no resolved/macTags keys) decodes to empty",
              legacy?.resolved.isEmpty == true && legacy?.macTags.isEmpty == true
              && emptyDecoded?.resolved.isEmpty == true && emptyDecoded?.macTags.isEmpty == true)

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["LIVECAPTURE_MANIFESTTEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APManifestTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("MANIFESTTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
