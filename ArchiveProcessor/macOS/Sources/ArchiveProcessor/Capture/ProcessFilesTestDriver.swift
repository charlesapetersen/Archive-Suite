#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import ImageIO
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
/// driver deliberately does NOT read Finder tags or build JSON in-process — an in-process
/// `JSONSerialization` of the result set wedges in this post-pipeline main-actor context — so all
/// PDF/tag/sidecar verification is done by the external asserter (`scripts/tier2_assert.py`) reading
/// the run dir after the app exits.
///
/// ⚠️ **The tag half of that rationale is UNVERIFIED and is not a reason to keep this shape.** It used
/// to read "reading `.tagNamesKey` contends with Spotlight". Nobody measured that, and `W26.oracle`
/// showed the adjacent Spotlight claim about this lane was simply wrong (TESTOUT lives under `/tmp`,
/// which Spotlight never indexes). Recorded as `execution-plans/despotlight.md` §"Site 8" and
/// `ArchiveProcessor/TESTING.md` — flagged, **not acted on**: the external-asserter split is right for
/// the `JSONSerialization` reason alone, so nothing here changes on the strength of the tag claim.
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
    /// Set when the driven run's `startProcessing` returns, so the batch watcher knows the run is over.
    private static var runFinished = false
    private static let imageExts = Set(ImageEncoding.acceptedImageExtensions)
    /// The review gates the autopilot answered, in order (gates.tsv).
    @MainActor private final class GateLog { var lines: [String] = [] }

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

        // The key comes from PROCESSFILES_TESTKEY or, so it never sits on a command line, a file named by
        // PROCESSFILES_TESTKEYFILE (W40.d1: the VM journey writes one in the guest and deletes it after).
        // Apple Vision needs none.
        let provider = LLMProvider(rawValue: env["PROCESSFILES_PROVIDER"] ?? "Gemini") ?? .gemini
        let fileKey = env["PROCESSFILES_TESTKEYFILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = env["PROCESSFILES_TESTKEY"] ?? fileKey ?? (provider == .appleVision ? "" : nil)
        guard let key,
              let inPath = env["PROCESSFILES_TESTIN"],
              let outPath = env["PROCESSFILES_TESTOUT"] else {
            return fail("missing required env (PROCESSFILES_TESTKEY or TESTKEYFILE, TESTIN, TESTOUT)", marker: safeFallbackMarker)
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
        // W49.proc-s044-reproduce: PROCESSFILES_PRIORITIES (comma-separated `SettingsPriority` names, most important
        // first) gives the run's output folder a collection layer ranking them, as the collection interview writes it
        // before a run, so the run resolves them like any collection's settings.
        if let ranked = env["PROCESSFILES_PRIORITIES"] {
            var doc = CollectionSettingsDocument(name: runDir.lastPathComponent)
            doc.collection.set(.priorities, .strings(ranked.split(separator: ",").map(String.init)), source: .setByUser(Date()))
            do { try CollectionSettingsFile.write(doc, in: runDir) }
            catch { return fail("cannot write the collection's settings: \(error)", marker: donePath) }
        }
        // --- inputs: top-level images, plus PDFs only for the mixed-route regression ---
        let cap = max(1, Int(env["PROCESSFILES_MAXIMAGES"] ?? "") ?? 8)
        let mixedRoute = env["PROCESSFILES_TEST_MIXED"] == "1"
        // W49.proc-suspects-filing: PROCESSFILES_PREOCRED=1 takes TESTIN's PDFs as Pre-OCRed input, which the app
        // tags IN PLACE (`outputURLMap[url] = url`), so the harness must hand over a scratch copy.
        let preOCRed = env["PROCESSFILES_PREOCRED"] == "1"
        let all = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []
        var inputs = all
            .filter { preOCRed ? $0.pathExtension.lowercased() == "pdf"
                : imageExts.contains($0.pathExtension.lowercased())
                || (mixedRoute && $0.pathExtension.lowercased() == "pdf") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(cap)
            .map { $0 }
        // W47.ct-processor-intake: PROCESSFILES_TREE=1 takes TESTIN as a folder dropped on Process Files, read as a
        // tree (`ProcessFilesTree.collect`), so each output is filed in its folders below the run dir.
        if env["PROCESSFILES_TREE"] == "1" {
            let intake = ProcessFilesTree.collect([inDir], accept: { imageExts.contains($0.pathExtension.lowercased()) },
                                                  sortAll: true)
            inputs = Array(intake.files.prefix(cap))
            processor.plannedOutputSubfolders = intake.subfolders
        }
        // W49.proc-suspects-money: PROCESSFILES_STAGED=1 takes the inputs from a Live Capture session in Stage for
        // later, as "Process N →" hands them over (`LiveCaptureView.stageForProcessing` → `orderedFilesAndGroups`, and
        // OCRView's `preGrouped*`). The session lives under ARCHIVEPROC_TEST_BACKUP_ROOT; a launch whose `CaptureSession`
        // restores one (a relaunch) hands that over, otherwise TESTIN's images are received into it as two documents.
        let staged = env["PROCESSFILES_STAGED"] == "1"
        var stageSession: CaptureSession?
        var handoffLines: [String] = []
        if staged {
            // Never the user's own backup folder: the session must live in the caller's scratch root.
            guard env["ARCHIVEPROC_TEST_BACKUP_ROOT"] != nil else {
                return fail("PROCESSFILES_STAGED needs ARCHIVEPROC_TEST_BACKUP_ROOT", marker: donePath)
            }
            let session = CaptureSession()
            let restored = session.photos.count
            if restored == 0 {
                session.beginStageSessionForTest()
                for (i, url) in inputs.enumerated() {
                    guard let jpeg = try? Data(contentsOf: url) else { continue }
                    _ = session.ingest(jpeg: jpeg, groupId: i < inputs.count / 2 ? "G1" : "G2", seq: i + 1,
                                       type: .document, quality: nil, year: nil, month: nil, deviceName: "stand-in")
                }
            }
            let handoff = session.orderedFilesAndGroups()
            handoffLines.append("handoff\tsession=\(session.sessionId)\trestored=\(restored)\tfiles=\(handoff.files.count)")
            inputs = handoff.files
            processor.preGroupedBoundaries = handoff.boundaries
            processor.preGroupedTypes = handoff.types
            processor.preGroupedQualities = handoff.qualities
            processor.preGroupedYears = handoff.years
            processor.preGroupedMonths = handoff.months
            processor.preGroupedSubjects = handoff.subjects
            stageSession = session
        }
        guard !inputs.isEmpty else { return fail("no accepted inputs in \(inDir.path)", marker: donePath) }

        // --- config (rejecting modes that need real human input) ---
        let modelId = env["PROCESSFILES_MODEL"] ?? "gemini-2.5-flash-lite"
        let mode = TaggingMode(rawValue: env["PROCESSFILES_TAGGING"] ?? "automatic") ?? .automatic
        guard mode == .automatic || mode == .none || mode == .copySource else {
            return fail("tagging mode '\(mode.rawValue)' needs human input; unsupported headless", marker: donePath)
        }
        // W40.d1: the gateway route, as Process Files builds it with Use gateway on (`OCRView.startProcessing`):
        // the configured provider stays, the model is the gateway's (`asLLMModel`), and the config goes in whole.
        var gateway: GatewayConfig?
        if let url = env["PROCESSFILES_GATEWAY_URL"], let gwModel = env["PROCESSFILES_GATEWAY_MODEL"] {
            gateway = GatewayConfig(
                baseURL: GatewayConfig.normalizedBaseURL(url), modelID: gwModel, displayName: "API Gateway",
                inputCostPer1M: env["PROCESSFILES_GATEWAY_IN_PER_1M"].flatMap(Double.init),
                outputCostPer1M: env["PROCESSFILES_GATEWAY_OUT_PER_1M"].flatMap(Double.init))
        }
        // W49.proc-suspects-messages (S-025): PROCESSFILES_GATEWAY_PRESET=openai fills the gateway's fields as Settings'
        // "Fill in OpenAI preset" does (`SettingsReadingPanel.applyOpenAIGatewayPreset`); send it to the stand-in with
        // PROCESSFILES_REDIRECT_URL.
        if env["PROCESSFILES_GATEWAY_PRESET"] == "openai" {
            guard let m = SettingsReadingPanel.openAIGatewayPresetModel else { return fail("no OpenAI preset model", marker: donePath) }
            gateway = GatewayConfig(baseURL: GatewayConfig.normalizedBaseURL("https://api.openai.com/v1"), modelID: m.id,
                                    displayName: "OpenAI", inputCostPer1M: m.inputCostPer1M, outputCostPer1M: m.outputCostPer1M)
        }
        // W49.proc-suspects-messages (S-018): PROCESSFILES_LOCALAGENT=<tool>:<absolute CLI path> reads with the Local
        // Agent, as Process Files does with that backend chosen in Settings (`LocalAgentConfig.fromDefaults`).
        var localAgent: LocalAgentConfig?
        if let spec = env["PROCESSFILES_LOCALAGENT"] {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let tool = LocalAgentTool(rawValue: parts[0]) else {
                return fail("PROCESSFILES_LOCALAGENT is <tool>:<path>", marker: donePath)
            }
            localAgent = LocalAgentConfig(tool: tool, binaryPath: parts[1], modelOverride: nil)
        }
        let model = gateway?.asLLMModel() ?? provider.models.first { $0.id == modelId } ?? provider.models[0]

        // W40.d4: the provider's batch path (submit, poll, collect), as Process Files takes it with Batch mode on;
        // PROCESSFILES_BATCH_CANCEL=1 presses Stop once the submission is journaled, which cancels it server-side.
        let batch = env["PROCESSFILES_BATCH"] == "1"
        let cancelAfterSubmit = env["PROCESSFILES_BATCH_CANCEL"] == "1"
        if batch && (gateway != nil || !provider.supportsBatch) {
            return fail("\(provider.rawValue) has no batch path here (gateway or provider without batch)", marker: donePath)
        }
        // W49.proc-suspects-money: PROCESSFILES_BATCH_STORED=1 passes the stored Batch mode flag on as Process Files
        // does (`OCRView.startProcessing` sends it unless the gateway, the Local Agent or Apple Vision is on), with
        // no check of the provider, and without the batch watcher below.
        let storedBatchFlag = env["PROCESSFILES_BATCH_STORED"] == "1"
        if storedBatchFlag && (batch || gateway != nil) {
            return fail("PROCESSFILES_BATCH_STORED is for a direct provider without PROCESSFILES_BATCH", marker: donePath)
        }
        if cancelAfterSubmit && !batch { return fail("PROCESSFILES_BATCH_CANCEL needs PROCESSFILES_BATCH=1", marker: donePath) }

        // State the cost first, with the app's own estimator and the same inputs the Cost Estimate box uses, and
        // refuse a run whose estimate is over the spend cap. A metered run (PROCESSFILES_METER=1) must name its cap.
        let estimate = CostEstimator.estimate(
            fileCount: inputs.count, model: model, enableTagging: mode.llmTags,
            sendPreviousImage: false, contextCharCount: 0, imageScale: 1.0, rotationMode: .off,
            useGateway: gateway != nil || provider == .appleVision,
            imageTokenProvider: gateway != nil ? (LLMProvider(rawValue: env["PROCESSFILES_GATEWAY_UPSTREAM"] ?? "") ?? .gemini) : nil,
            measuredRoute: DateRoute.measuredRoute(gateway: gateway, usesLocalAgent: false),
            dateImageEveryDocument: DateRoute.imageEveryDocument(SettingsLayerStore.shared.resolver(for: nil)),
            sidecars: true)
        let metered = env[Self.meterEnvKey] == "1"
        let capUSD = env["PROCESSFILES_CAP_USD"].flatMap(Double.init)
        writeMarker(runDir.appendingPathComponent("estimate.txt").path,
                    "files=\(inputs.count)\tmodel=\(model.id)\tocr=\(estimate.ocrFormatted)\tclassification=\(estimate.classificationFormatted)"
                    + "\ttagging=\(estimate.taggingFormatted)\tdating=\(estimate.datingFormatted)"
                    + "\titemFields=\(estimate.itemFieldFormatted)\ttotal=\(estimate.totalStandardFormatted)"
                    + (batch || storedBatchFlag ? "\tbatch=\(CostEstimate.money(estimate.totalBatch))" : "")
                    + "\tcap=\(capUSD.map(CostEstimate.money) ?? "none")\n")
        if gateway != nil && !metered {
            return fail("a gateway run must be metered (\(Self.meterEnvKey)=1 with PROCESSFILES_CAP_USD)", marker: donePath)
        }
        if metered {
            guard let capUSD, capUSD > 0 else { return fail("\(Self.meterEnvKey)=1 needs PROCESSFILES_CAP_USD", marker: donePath) }
            guard estimate.totalStandard <= capUSD else {
                return fail("estimate \(estimate.totalStandardFormatted) is over the cap \(CostEstimate.money(capUSD))", marker: donePath)
            }
        }

        // Set pipeline config on the instance (no UserDefaults/Keychain writes). `taggingMode` is the
        // whole input: each tag write reads `stampsUnread` off it (or off the run's retained config) as
        // an explicit per-call argument — W16.cfg6-fu deleted the global its `didSet` used to arm.
        processor.taggingMode = mode
        processor.passSourceTags = (mode == .copySource)
        processor.rotationMode = .off          // macOS Vision rotation hangs without a window server
        // W49.proc-suspects-messages (S-029): PROCESSFILES_ROTATION names the rotation mode Settings holds.
        if let raw = env["PROCESSFILES_ROTATION"] {
            guard let rotation = RotationMode(rawValue: raw) else { return fail("unknown rotation mode \(raw)", marker: donePath) }
            processor.rotationMode = rotation
        }
        processor.reviewRotation = false
        processor.mergeDocuments = false       // 1 source image → 1 two-page PDF (stable paths)
        processor.exportOriginals = env["PROCESSFILES_EXPORTORIGINALS"] == "1"
        if !staged { processor.preGroupedBoundaries = [] }   // force the LLM segmentation path
        processor.segmentationApproach = .manual   // never a window model's call, whatever Settings holds
        // W49.proc-suspects-money: PROCESSFILES_SEGAPPROACH names the approach the Segmentation chooser holds, its
        // windows routed by the production `WindowStageTransport.make` with no window key (never the Keychain).
        if let raw = env["PROCESSFILES_SEGAPPROACH"] {
            guard let approach = SegmentationApproach(rawValue: raw) else {
                return fail("unknown segmentation approach \(raw)", marker: donePath)
            }
            processor.segmentationApproach = approach
            processor.windowTransportFactory = { spec, gate in
                WindowStageTransport.make(spec, keys: [:], claudeBinary: nil, gate: gate)
            }
        }
        // W49.proc-suspects-money: PROCESSFILES_READER_MODEL gives every input a page reader on that model of the run's
        // provider (the user's own choice, `.override`), as the page-kind guide's plan reaches `startProcessing`.
        if let readerModel = env["PROCESSFILES_READER_MODEL"] {
            var plan = PageReaderPlan()
            for url in inputs {
                plan.pages[PageReaderPlan.key(url)] = .init(
                    kind: nil, choice: .init(provider: provider, modelID: readerModel, reason: .override))
            }
            processor.pageReaders = plan
        }

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
        // W49.proc-suspects-filing: the collection switches Process Files' settings give (Collection ID, Confirm
        // collection names, Review document segmentation), each gate the autopilot answered in gates.tsv (a
        // document review with the collection it was raised for, empty for the whole-run review), and
        // PROCESSFILES_COLLNAME — a name typed into every box row of the collection sheet before Confirm is pressed,
        // without Return, as `CollectionReviewRow`'s binding stores it.
        let collectionSegmentation = env["PROCESSFILES_COLLSEG"] == "1"
        let confirmCollections = env["PROCESSFILES_CONFIRMCOLL"] == "1"
        let reviewDocSegmentation = env["PROCESSFILES_REVIEWDOCSEG"] == "1"
        let typedCollectionName = env["PROCESSFILES_COLLNAME"]
        let gates = GateLog()
        let autopilot = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if processor.awaitingRetryDecision { gates.lines.append("retry"); processor.continueWithoutRetry() }
                else if processor.awaitingDocumentReview {
                    gates.lines.append("documentReview\t\(processor.currentReviewCollectionName)")
                    processor.confirmDocumentReview()
                }
                else if processor.awaitingBoxFolderConfirmation {
                    gates.lines.append("boxFolderConfirmation"); processor.confirmBoxFolderReview()
                }
                else if processor.awaitingCollectionConfirmation {
                    gates.lines.append("collectionConfirmation")
                    if let typedCollectionName {
                        for i in processor.collectionReviewItems.indices {
                            processor.collectionReviewItems[i].collectionName = typedCollectionName
                        }
                        processor.noBoxCollectionName = typedCollectionName
                    }
                    processor.confirmCollectionReview()
                }
                else if processor.awaitingFinalReview { gates.lines.append("finalReview"); processor.confirmFinalReview() }
                else if let prompt = processor.windowStopPrompt {
                    // W49.proc-suspects-money: the pages already read when the window stage asks, then Stop.
                    let read = processor.jobs.filter { $0.result != nil }.count
                    gates.lines.append("windowStop\tpagesRead=\(read)/\(processor.jobs.count)\t\(prompt.message)")
                    processor.answerWindowStop(.stop)
                }
            }
        }

        // The meter: every request still goes to the real wire (`NetworkSession.shared`), behind the same limiter
        // and retry code (each attempt passes through here); this only reads each reply's `usage`, and refuses to send
        // a request unless what is spent plus every request in flight, each priced at the dearest call so far, stays
        // inside the cap.
        let meter = SpendMeter(inPer1M: model.inputCostPer1M, outPer1M: model.outputCostPer1M, cap: capUSD ?? 0)
        // W49.proc-suspects-money: PROCESSFILES_REDIRECT_URL (a metered run only) sends every request to that address
        // instead of its provider's, and requests.tsv records each one as it left the app: where it was going, its
        // body's bytes, each image in it (bytes and pixels), and the `model` its body names.
        let redirect = metered ? env["PROCESSFILES_REDIRECT_URL"].flatMap(URL.init(string:)) : nil
        let requests = RequestLog()
        if metered {
            NetworkSession.testTransport = { request in
                try meter.admit()
                var request = request
                if let redirect {
                    requests.record(request)
                    request.url = redirect
                }
                do {
                    let (data, response) = try await NetworkSession.shared.data(for: request)
                    meter.record(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                    return (data, response)
                } catch {
                    meter.record(nil, status: 0)
                    throw error
                }
            }
        }
        defer { if metered { NetworkSession.testTransport = nil } }
        // Every gateway call takes its key from `GatewayConfig.apiKey`, not from `apiKey:` below.
        if gateway != nil { GatewayConfig.testKeyOverride = key }
        defer { GatewayConfig.testKeyOverride = nil }

        NSLog("PFDRIVER: start \(inputs.count) files, \(provider.rawValue)/\(model.id), mode=\(mode.rawValue), out=\(runDir.path)")

        // The run is held in `processingTask`, as `OCRView` holds it, so a Stop (`cancel()`) reaches it.
        // The run finishing is the authoritative completion signal (isProcessing briefly
        // lies mid-run because tagging clears it before suspending on the final-review gate).
        let run = Task { @MainActor in await processor.startProcessing(
            files: inputs,
            provider: provider,
            model: model,
            thinkingLevel: nil,
            apiKey: key,
            outputDirectory: runDir,
            batchMode: batch || storedBatchFlag,
            enableTagging: mode.enablesTagging,
            enableSegmentJSON: true,
            enableCollectionSegmentation: collectionSegmentation,
            confirmCollectionIDs: confirmCollections,
            reviewDocumentSegmentation: reviewDocSegmentation,
            preOCRedInput: preOCRed,
            segmentationContext: SegmentationContext(
                previousTextCharCount: 0, sendPreviousImage: false, customPrompt: nil, imageScale: 1.0),
            gatewayConfig: gateway,
            localAgent: localAgent)
            runFinished = true }
        processor.processingTask = run

        // W40.d4: the provider's batch IDs, read from the recovery journal once the submission is marked complete,
        // go into batch.tsv so the host can ask the provider what became of the job. With the cancel switch, Stop is
        // pressed at that moment and the outcome the app reached is written beside them.
        if batch {
            var ids: [String] = []
            let watchStart = Date()
            while Date().timeIntervalSince(watchStart) < 600 {
                if let pending = processor.activePendingBatch, pending.submissionComplete {
                    ids = pending.effectiveChunkIds
                    break
                }
                if runFinished { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            var lines = ["provider=\(provider.rawValue)\tmodel=\(model.id)\tids=\(ids.joined(separator: ","))"
                         + "\tsubmitted_after_s=\(Int(Date().timeIntervalSince(watchStart)))"]
            if cancelAfterSubmit && !ids.isEmpty {
                processor.cancel()
                await processor.batchCancellationTask?.value
                let journalKept = FileManager.default.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
                lines.append("cancel=pressed\tjournal_kept=\(journalKept)\tstatus=\(processor.statusMessage)")
            }
            writeMarker(runDir.appendingPathComponent("batch.tsv").path, lines.joined(separator: "\n") + "\n")
        }
        await run.value

        autopilot.cancel()
        if metered {
            writeMarker(runDir.appendingPathComponent("spend.tsv").path, meter.summary + "\n")
        }
        if redirect != nil {
            writeMarker(runDir.appendingPathComponent("requests.tsv").path,
                        "# standardImageMB=\(SessionProcessingConfig.runSizing().standardImageMB)\n" + requests.summary)
        }
        if let stageSession {
            // The pane's "Process N →" again after the run, and after a relaunch (a fresh session object).
            handoffLines.append("after-run\tfiles=\(stageSession.orderedFilesAndGroups().files.count)")
            let relaunched = CaptureSession()
            handoffLines.append("after-relaunch\tsession=\(relaunched.sessionId)\tfiles=\(relaunched.orderedFilesAndGroups().files.count)")
            writeMarker(runDir.appendingPathComponent("handoff.tsv").path, handoffLines.map { $0 + "\n" }.joined())
        }

        // Write the completion marker FIRST (a plain String write, which the pipeline's own file
        // writes just proved works on this actor), so the harness always sees completion. Then a
        // tiny TSV manifest of per-file classification + status from in-memory job state. All PDF /
        // Finder-tag / sidecar verification is done by the EXTERNAL asserter reading the run dir —
        // the driver deliberately does NOT read tags or build JSON here (see the type doc — the
        // JSON reason is measured; the "contends with Spotlight" one was never verified).
        let succeeded = processor.jobs.filter { "\($0.status)" == "succeeded" }.count
        let failed = processor.jobs.filter { "\($0.status)" == "failed" }.count
        writeMarker(donePath, processor.statusMessage.isEmpty ? "DONE" : processor.statusMessage)
        // W49.proc-fix-s042: the status line and the failed tagging calls, in the run folder the journey brings back,
        // so the checker can hold every untagged document to being named.
        writeMarker(runDir.appendingPathComponent("status.txt").path, processor.statusMessage + "\n")
        writeMarker(runDir.appendingPathComponent("gates.tsv").path, gates.lines.map { $0 + "\n" }.joined())
        if env["PROCESSFILES_ROTATION"] != nil {
            writeMarker(runDir.appendingPathComponent("rotation.tsv").path, processor.jobs.map {
                "\($0.sourceURL.lastPathComponent)\trotation=\($0.result.map { String($0.rotationDegrees) } ?? "none")"
                    + "\tunsure=\($0.result?.rotationUnsure == true)\n"
            }.joined())
        }
        writeMarker(runDir.appendingPathComponent("tagging-failures.tsv").path,
                    processor.taggingFailureNames.map { "\($0.name)\t\($0.reason)\n" }.joined())

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

    /// The flag that lets this driver's meter use `NetworkSession`'s seam (`activeTestTransport`).
    nonisolated static let meterEnvKey = "PROCESSFILES_METER"
}

/// W49.proc-suspects-money: each request a redirected run sent, as the app built it (requests.tsv).
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Data()
        // The base64 runs over 10,000 characters are the page images (a prompt never has one this long). JSON may
        // write each `/` as `\/`, so a backslash continues a run without counting.
        // Each image as bytes and pixels (long edge), the measure a provider prices it by.
        var images: [String] = [], run = Data()
        for byte in body + [0] {
            if byte == 92 { continue }
            let isBase64 = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == 43 || byte == 47 || byte == 61
            if isBase64 { run.append(byte); continue }
            if run.count > 10_000, let image = Data(base64Encoded: run) {
                let props = CGImageSourceCreateWithData(image as CFData, nil)
                    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
                let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
                images.append("\(image.count):\(w)x\(h)")
            }
            run.removeAll(keepingCapacity: true)
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let model = json?["model"] as? String ?? ""
        // W49.proc-suspects-messages: the token-limit and reasoning parameters the body carries.
        let params = ["max_tokens", "max_completion_tokens", "reasoning_effort"].compactMap { k in json?[k].map { "\(k):\($0)" } }
        let line = "\(request.url?.host ?? "")\(request.url?.path ?? "")\tbody_bytes=\(body.count)"
            + "\timages=\(images.joined(separator: ","))\tmodel=\(model)\tparams=\(params.joined(separator: ","))"
        lock.lock(); lines.append(line); lock.unlock()
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return lines.map { $0 + "\n" }.joined()
    }
}

/// W40.d1: what a metered run spent, priced from each reply's OpenAI-shaped `usage` at the model's rates. A 2xx
/// reply without `usage` is counted as unmetered, so the journey's checker can refuse a run it cannot price; a
/// non-2xx reply or a transport error is counted as rejected (a provider does not bill a 429 or a 5xx it refused).
final class SpendMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let inPer1M: Double, outPer1M: Double, cap: Double
    private var calls = 0, unmetered = 0, rejected = 0, refused = 0, inputTokens = 0, outputTokens = 0
    private var inFlight = 0, dearest = 0.0, blind = false

    init(inPer1M: Double, outPer1M: Double, cap: Double) {
        self.inPer1M = inPer1M; self.outPer1M = outPer1M; self.cap = cap
    }

    private func cost(_ input: Int, _ output: Int) -> Double {
        Double(input) * inPer1M / 1_000_000 + Double(output) * outPer1M / 1_000_000
    }

    func admit() throws {
        lock.lock(); defer { lock.unlock() }
        // After a reply it could not price, the meter cannot keep the cap, so it sends nothing more.
        guard !blind, cost(inputTokens, outputTokens) + Double(inFlight + 1) * dearest < cap else {
            refused += 1
            throw URLError(.cancelled)
        }
        inFlight += 1
    }

    func record(_ data: Data?, status: Int) {
        let usage = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["usage"] as? [String: Any]
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
        calls += 1
        guard (200..<300).contains(status) else { rejected += 1; return }
        if let p = usage?["prompt_tokens"] as? Int, let c = usage?["completion_tokens"] as? Int {
            // A proxy may report thinking outside completion_tokens; total_tokens then says so.
            let out = max(c, (usage?["total_tokens"] as? Int ?? 0) - p)
            inputTokens += p; outputTokens += out
            dearest = max(dearest, cost(p, out))
        } else {
            unmetered += 1
            blind = true
        }
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "calls=\(calls)\tunmetered=\(unmetered)\trejected=\(rejected)\trefused=\(refused)\tinput_tokens=\(inputTokens)"
            + "\toutput_tokens=\(outputTokens)\tdearest_call_usd=\(String(format: "%.4f", dearest))"
            + "\tspent_usd=\(String(format: "%.4f", cost(inputTokens, outputTokens)))\tcap_usd=\(cap)"
    }
}

#endif
