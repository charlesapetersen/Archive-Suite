import Foundation
import AppKit

/// Headless end-to-end verification of the Live Capture streaming pipeline, gated by
/// `LIVECAPTURE_TESTMODE=1` (does nothing in normal use). Feeds a fixed set of local images directly
/// into a `.live` session (no phone/network), finalizes into the output folder, and writes a
/// done-marker. Test-only scaffolding.
@MainActor
enum LiveCaptureTestDriver {
    private static var didRun = false

    static func runIfRequested(session: CaptureSession) {
        guard !didRun, ProcessInfo.processInfo.environment["LIVECAPTURE_TESTMODE"] == "1" else { return }
        didRun = true
        Task { await run(session: session) }
    }

    private struct Seg { let type: CaptureGroupType; let paths: [String] }

    static func run(session: CaptureSession) async {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["LIVECAPTURE_TESTKEY"],
              let outPath = env["LIVECAPTURE_TESTOUT"],
              let images = env["LIVECAPTURE_TESTIMAGES"] else { NSLog("TESTDRIVER: missing env"); return }
        let donePath = env["LIVECAPTURE_TESTDONE"] ?? (outPath + "/TEST_DONE.txt")

        // Parse "box:/a.jpg;doc:/b.jpg,/c.jpg;doc:/d.jpg"
        let segs: [Seg] = images.split(separator: ";").compactMap { part in
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            let type: CaptureGroupType = kv[0] == "box" ? .box : (kv[0] == "folder" ? .folder : .document)
            return Seg(type: type, paths: kv[1].split(separator: ",").map(String.init))
        }
        guard !segs.isEmpty else { NSLog("TESTDRIVER: no segments"); return }

        // Build the config directly (no UserDefaults/Keychain mutation, so the user's saved settings
        // are untouched). Cheap model + free local-Vision rotation to keep cost minimal.
        let outDir = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let model = LLMModel.geminiModels.first { $0.id == "gemini-2.5-flash-lite" } ?? LLMModel.geminiModels[0]
        // rotation .off for the headless run: macOS Vision (local-Vision rotation) hangs without a
        // window-server/GUI session. Rotation is a separate, already-working component; not what
        // this streaming verification is exercising.
        let config = SessionProcessingConfig(
            provider: .gemini, model: model, thinkingLevel: .low, apiKey: key,
            taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
            outputDirectory: outDir, contextCharCount: 0, sendPreviousImage: false,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: true, tagVocabulary: [], gateway: nil)
        session.beginLiveSession(config: config)
        NSLog("TESTDRIVER: live session started, model=\(session.config?.model.id ?? "?"), out=\(outDir.path)")

        // Ingest each segment's images directly (bypassing the phone/network), then resolve documents.
        var seq = 0
        for (si, seg) in segs.enumerated() {
            let gid = "testseg-\(si)"
            for path in seg.paths {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { NSLog("TESTDRIVER: missing \(path)"); continue }
                session.ingest(jpeg: data, groupId: gid, seq: seq, type: seg.type,
                               priority: nil, year: nil, month: nil, deviceName: "TestDriver")
                seq += 1
            }
            if seg.type == .document { session.skipMacTags(groupId: gid) }   // resolve card → finalize (LLM tags)
        }

        // Wait for all segments to finalize (staged), up to ~180s.
        for _ in 0..<360 {
            if session.liveProcessor.staged.count >= segs.count { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        NSLog("TESTDRIVER: staged \(session.liveProcessor.staged.count)/\(segs.count)")

        // Finalize: build drafts, name any unfiled collection, then move into place.
        session.liveProcessor.beginFinalize()
        var drafts = session.liveProcessor.drafts
        let appendMode = env["LIVECAPTURE_TESTAPPEND"] == "1"
        for i in drafts.indices {
            if appendMode, let existing = drafts[i].suggestedFolders.first ?? drafts[i].existingFolders.first {
                drafts[i].chosenExisting = existing   // exercise the append-to-existing path
            } else if drafts[i].finalName.trimmingCharacters(in: .whitespaces).isEmpty {
                drafts[i].finalName = "Test Collection \(i + 1)"
            }
            NSLog("TESTDRIVER: draft '\(drafts[i].finalName)' suggested=\(drafts[i].suggestedFolders.map { $0.lastPathComponent }) chosen=\(drafts[i].chosenExisting?.lastPathComponent ?? "NEW")")
        }
        session.liveProcessor.finalize(drafts)

        for _ in 0..<120 {
            if session.liveProcessor.finalizeSummary != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let summary = session.liveProcessor.finalizeSummary ?? "NO SUMMARY (timeout)"
        NSLog("TESTDRIVER: \(summary)")
        try? summary.write(toFile: donePath, atomically: true, encoding: .utf8)
    }
}
