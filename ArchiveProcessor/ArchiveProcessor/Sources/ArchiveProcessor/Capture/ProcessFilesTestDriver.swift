import Foundation
import PDFKit

/// Headless end-to-end verification of the **Process Files** GUI pipeline
/// (OCR → segmentation → tagging → PDF output), gated by `PROCESSFILES_TESTMODE=1`
/// (does nothing in normal use — inert unless the env var is set, and latched to run once).
///
/// It drives a PRIVATE, unobserved `OCRProcessor.startProcessing(...)` (see `runIfRequested`) and
/// runs a concurrent "auto-pilot" that answers each interactive review the way the UI would (accepting
/// the LLM's proposals verbatim). On completion it writes a `TEST_DONE.txt` marker + a small
/// `manifest.tsv` (per-file classification + status) and returns (no `exit()`, mirroring
/// `LiveCaptureTestDriver`); the external harness detects the marker and tears the app down. The
/// driver deliberately does NOT read Finder tags or build JSON in-process — reading `.tagNamesKey`
/// contends with Spotlight, and an in-process `JSONSerialization` of the result set wedges in this
/// post-pipeline main-actor context — so all PDF/tag/sidecar verification is done by the external
/// asserter (`scripts/tier2_assert.py`) reading the run dir after the app exits.
///
/// Test-only scaffolding. It never mutates UserDefaults/Keychain (the API key is threaded straight
/// through as a parameter), never touches Live Capture, and refuses to write into `Test Files/`.
/// Outputs go only under a fresh `run-<epoch>/` subdir of the caller's output folder. NOTE: the
/// non-batch pipeline it drives writes a `pending_run.json` resume-snapshot into Application Support
/// (crash-recovery state, outside the run dir); this driver clears it on exit (and the harness also
/// deletes it post-teardown) so a test never leaves a stale, paid "Resume Run" prompt for a later
/// normal launch.
@MainActor
enum ProcessFilesTestDriver {
    private static var didRun = false
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]

    static func runIfRequested() {
        guard !didRun,
              ProcessInfo.processInfo.environment["PROCESSFILES_TESTMODE"] == "1" else { return }
        didRun = true
        // Drive a PRIVATE OCRProcessor that NO SwiftUI view observes. Driving ContentView's
        // @StateObject would re-evaluate ContentView.body on every pipeline @Published update, which
        // trips a Swift-6 `swift_task_isCurrentExecutor` crash in the view graph under the rapid
        // churn of automatic-mode tagging. An unobserved instance runs the identical pipeline
        // (OCRProcessor is self-contained) with zero view updates.
        let processor = OCRProcessor()
        Task { await run(processor: processor) }
    }

    /// Marker path used ONLY for failures detected before a proven-safe in-tree path is known —
    /// always outside any user tree, so a misconfigured output never triggers a stray Test Files write.
    private static var safeFallbackMarker: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("archiveproc-test-DONE.txt")
    }
    private static func writeMarker(_ path: String, _ contents: String) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
    private static func inTestFiles(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.caseInsensitiveCompare("Test Files") == .orderedSame }
    }

    static func run(processor: OCRProcessor) async {
        let env = ProcessInfo.processInfo.environment
        func fail(_ msg: String, marker: String) {
            NSLog("PFDRIVER: ERROR \(msg)")
            writeMarker(marker, "ERROR: \(msg)")
        }

        guard let key = env["PROCESSFILES_TESTKEY"],
              let inPath = env["PROCESSFILES_TESTIN"],
              let outPath = env["PROCESSFILES_TESTOUT"] else {
            return fail("missing required env (PROCESSFILES_TESTKEY/TESTIN/TESTOUT)", marker: safeFallbackMarker)
        }

        // --- resolve + safety-guard the locations BEFORE deriving any in-tree marker path ---
        // (so even a failure marker can never land inside Test Files or among the input photos).
        let inDir = URL(fileURLWithPath: inPath).standardizedFileURL.resolvingSymlinksInPath()
        let outRoot = URL(fileURLWithPath: outPath).standardizedFileURL.resolvingSymlinksInPath()
        if inTestFiles(outRoot) {
            return fail("refuses to write into a Test Files directory", marker: safeFallbackMarker)
        }
        if outRoot.path == inDir.path
            || outRoot.path.hasPrefix(inDir.path + "/")
            || inDir.path.hasPrefix(outRoot.path + "/") {
            return fail("output folder overlaps the input folder", marker: safeFallbackMarker)
        }

        // One well-known marker path (outRoot-level, not per-run) used for BOTH success and failure
        // from here on, so the harness always watches a single location. Reject a Test Files override.
        let donePath = env["PROCESSFILES_TESTDONE"] ?? outRoot.appendingPathComponent("TEST_DONE.txt").path
        if inTestFiles(URL(fileURLWithPath: donePath)) {
            return fail("done-marker path is inside Test Files", marker: safeFallbackMarker)
        }

        // --- fresh, non-overwriting run dir ---
        let runDir = outRoot.appendingPathComponent("run-\(Int(Date().timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: runDir.path) {
            return fail("run dir already exists: \(runDir.path)", marker: donePath)
        }
        do {
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        } catch {
            return fail("cannot create run dir: \(error.localizedDescription)", marker: donePath)
        }
        // --- inputs: top-level images, natural-sorted, capped ---
        let cap = max(1, Int(env["PROCESSFILES_MAXIMAGES"] ?? "") ?? 8)
        let all = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []
        let inputs = all
            .filter { imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(cap)
            .map { $0 }
        guard !inputs.isEmpty else { return fail("no input images in \(inDir.path)", marker: donePath) }

        // --- config (rejecting modes that need real human input) ---
        let provider = LLMProvider(rawValue: env["PROCESSFILES_PROVIDER"] ?? "Gemini") ?? .gemini
        let modelId = env["PROCESSFILES_MODEL"] ?? "gemini-2.5-flash-lite"
        let model = provider.models.first { $0.id == modelId } ?? provider.models[0]
        let mode = TaggingMode(rawValue: env["PROCESSFILES_TAGGING"] ?? "automatic") ?? .automatic
        guard mode == .automatic || mode == .none || mode == .copySource else {
            return fail("tagging mode '\(mode.rawValue)' needs human input; unsupported headless", marker: donePath)
        }

        // Set pipeline config on the instance (no UserDefaults/Keychain writes). Setting
        // taggingMode via the property arms MacOSTagger.stampUnread through its didSet.
        processor.taggingMode = mode
        processor.passSourceTags = (mode == .copySource)
        processor.rotationMode = .off          // macOS Vision rotation hangs without a window server
        processor.reviewRotation = false
        processor.mergeDocuments = false       // 1 source image → 1 two-page PDF (stable paths)
        processor.exportOriginals = env["PROCESSFILES_EXPORTORIGINALS"] == "1"
        processor.preGroupedBoundaries = []    // force the LLM segmentation path

        // Clean up the durable resume-state the non-batch pipeline writes to Application Support
        // (pending_run.json) so a test run never leaves a stale, paid "Resume Run" prompt for a
        // later normal launch. Covers every clean return here; the harness also deletes it after
        // teardown to cover a crash/kill (where this defer would not run).
        defer { processor.dismissPendingRun(); processor.dismissPendingBatch() }

        // Auto-pilot: answer each review gate the way the UI would (accept the LLM's proposals). No
        // SwiftUI view observes this processor, so no review sheet ever presents; the pipeline just
        // suspends on each awaiting* continuation and we resume it here. Each confirm* sets its
        // awaiting flag false + nils its continuation synchronously, so no gate is ever
        // double-resumed; the single-branch `else if` keeps it to one confirmation per cycle.
        let autopilot = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if processor.awaitingRetryDecision { processor.continueWithoutRetry() }
                else if processor.awaitingDocumentReview { processor.confirmDocumentReview() }
                else if processor.awaitingBoxFolderConfirmation { processor.confirmBoxFolderReview() }
                else if processor.awaitingCollectionConfirmation { processor.confirmCollectionReview() }
                else if processor.awaitingFinalReview { processor.confirmFinalReview() }
            }
        }

        NSLog("PFDRIVER: start \(inputs.count) files, \(provider.rawValue)/\(model.id), mode=\(mode.rawValue), out=\(runDir.path)")

        // The `await` returning is the authoritative completion signal (isProcessing briefly
        // lies mid-run because tagging clears it before suspending on the final-review gate).
        await processor.startProcessing(
            files: inputs,
            provider: provider,
            model: model,
            thinkingLevel: nil,
            apiKey: key,
            outputDirectory: runDir,
            batchMode: false,
            enableTagging: mode.enablesTagging,
            enableSegmentJSON: true,
            enableCollectionSegmentation: false,
            confirmCollectionIDs: false,
            reviewDocumentSegmentation: false,
            preOCRedInput: false,
            segmentationContext: SegmentationContext(
                previousTextCharCount: 0, sendPreviousImage: false, customPrompt: nil, imageScale: 1.0),
            gatewayConfig: nil)

        autopilot.cancel()

        // Write the completion marker FIRST (a plain String write, which the pipeline's own file
        // writes just proved works on this actor), so the harness always sees completion. Then a
        // tiny TSV manifest of per-file classification + status from in-memory job state. All PDF /
        // Finder-tag / sidecar verification is done by the EXTERNAL asserter reading the run dir —
        // the driver deliberately does NOT read tags (contends with Spotlight) or build JSON here.
        let succeeded = processor.jobs.filter { "\($0.status)" == "succeeded" }.count
        let failed = processor.jobs.filter { "\($0.status)" == "failed" }.count
        writeMarker(donePath, processor.statusMessage.isEmpty ? "DONE" : processor.statusMessage)

        var lines = ["# provider=\(provider.rawValue)\tmodel=\(model.id)\tmode=\(mode.rawValue)\tinputs=\(processor.jobs.count)\tsucceeded=\(succeeded)\tfailed=\(failed)\tsegments=\(processor.segments.count)"]
        lines.append("# pdf\tclassification\tstatus")
        for job in processor.jobs {
            let pdf = processor.outputURLMap[job.sourceURL]?.lastPathComponent ?? ""
            let cls = (job.classification ?? job.result?.classification)?.rawValue ?? ""
            lines.append("\(pdf)\t\(cls)\t\(job.status)")
        }
        try? lines.joined(separator: "\n").write(
            toFile: runDir.appendingPathComponent("manifest.tsv").path, atomically: true, encoding: .utf8)
        NSLog("PFDRIVER: done — \(succeeded) succeeded, \(failed) failed → \(runDir.path)")
    }
}
