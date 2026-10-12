import AppKit
import Foundation

/// Headless, $0 self-test of the review of flagged boundaries and the window stage in the pipeline
/// (W36.seg-opt-review), gated by `SEGMENTATION_REVIEW_TEST=1` (does nothing in normal use). No model call, no
/// network, no Keychain read (a recorded transport is injected), no window, and no write outside its own temp
/// directory: the run's manifest save is redirected to memory. Run by `scripts/test-segmentation-review.sh`.
///
/// What has to be true:
///   1. Who segments: every tagging mode × approach resolves to the plan Part 3 §1 (as decided here) names.
///   2. Keep / Split / Join → the gap's decision; the classifications a run's proposals and answers make (a
///      label photo stays a label, the first page starts a document); the flagged items, "Done" only when every
///      gap is answered, the recorded answers keyed by page, the count line and the skim note from the figures.
///   3. A run whose model stopped part-way: the gaps no window answered are flagged with confidence 0.
///   4. The run's manifest keeps the approach, the window answers and the gap answers through JSON, and adding
///      them leaves the run's fingerprint unchanged.
///   5. The stage, driven end to end on six synthetic pages: box/folder confirmation, the windows (three, as
///      the bench's 7/3 layout gives six pages), the one flagged gap answered Split, the skim with its note and
///      the checked page, then the classifications in the jobs and the count line.
///   6. A resume with the manifest's answers asks the model nothing and offers the gap already answered.
///   7. A usage limit asks; "check the rest myself" flags every gap the model did not answer.
@MainActor
enum SegmentationReviewTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENTATION_REVIEW_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in
            await run()
            finish()
        }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    /// A value a spawned stage task sets and the driver polls, both on the main actor.
    @MainActor final class Box<T> { var value: T? }

    // MARK: - The recorded transport

    /// Answers every window from a fixed verdict per gap (keyed by the 1-based page before it), page 1 a folder.
    final class FakeTransport: WindowTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[Int]] = []
        var calls: [[Int]] { lock.withLock { _calls } }
        let verdicts: [Int: (String, Double)]
        let failWith: WindowTransportError?

        init(verdicts: [Int: (String, Double)], failWith: WindowTransportError? = nil) {
            self.verdicts = verdicts
            self.failWith = failWith
        }

        func send(_ r: WindowRequest) async throws -> String {
            lock.withLock { _calls.append(r.pageNumbers) }
            if let failWith { throw failWith }
            let pages = r.pageNumbers.map { ["page": $0, "kind": $0 == 1 ? "folder" : "document"] as [String: Any] }
            let gaps = r.pageNumbers.dropLast().map { n -> [String: Any] in
                let (d, c) = verdicts[n] ?? ("new", 0.99)
                return ["between": [n, n + 1], "decision": d, "confidence": c, "cue": "cue \(n)"]
            }
            let data = try JSONSerialization.data(withJSONObject: ["pages": pages, "boundaries": gaps])
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Run

    static func run() async {
        // 1. Who segments.
        let manual = SegmentationApproach.manual
        eq("1 automatic + manual → per-page review", SegmentationPlan.resolve(tagging: .automatic, approach: manual),
           .perPageReview)
        eq("1 autoDate + manual → the combined window, auto date",
           SegmentationPlan.resolve(tagging: .autoDate, approach: manual), .manualWindow(autoDate: true))
        eq("1 human + manual → the combined window", SegmentationPlan.resolve(tagging: .human, approach: manual),
           .manualWindow(autoDate: false))
        for t in [TaggingMode.automatic, .autoDate, .human] {
            for a in [SegmentationApproach.claude, .gemini, .openai, .mix] {
                eq("1 \(t.rawValue) + \(a.rawValue) → windows", SegmentationPlan.resolve(tagging: t, approach: a),
                   .windows(a))
            }
        }
        for t in [TaggingMode.none, .copySource] {
            eq("1 \(t.rawValue) + claude → no tagging", SegmentationPlan.resolve(tagging: t, approach: .claude),
               .noTagging)
        }
        check("1 only automatic + manual uses the per-page classifier",
              SegmentationPlan.perPageReview.usesPerPageClassifier
                && !SegmentationPlan.windows(.claude).usesPerPageClassifier
                && !SegmentationPlan.manualWindow(autoDate: true).usesPerPageClassifier)
        eq("1 TaggingMode has no autoDateManualSeg", TaggingMode(rawValue: "autoDateManualSeg"), nil)
        let human = SegmentationPlan.resolve(tagging: .human, approach: .claude)
        eq("1 pre-grouped human keeps the combined window whatever the approach",
           human.combinedWindow(tagging: .human, preGrouped: true), false)
        eq("1 pre-grouped autoDate tags the phone's groups",
           SegmentationPlan.manualWindow(autoDate: true).combinedWindow(tagging: .autoDate, preGrouped: true), nil)
        eq("1 autoDate + manual → combined window with dates",
           SegmentationPlan.manualWindow(autoDate: true).combinedWindow(tagging: .autoDate, preGrouped: false), true)
        eq("1 windows → the per-document tagging sheet", human.combinedWindow(tagging: .human, preGrouped: false), nil)
        let batch = OCRProcessor().makePendingBatchResumeConfig(
            OCRProcessor.PendingBatch(batchId: "b", provider: .gemini, model: LLMProvider.gemini.models[0],
                                      thinkingLevel: nil, fileURLs: [], outputDirectory: URL(fileURLWithPath: "/tmp"),
                                      enableTagging: true, enableCollectionSegmentation: false,
                                      sendPreviousImage: false, submittedAt: Date(), enableSegmentJSON: false,
                                      confirmCollectionIDs: false, reviewDocumentSegmentation: false,
                                      customPrompt: nil, taggingMode: .automatic, fingerprintVersion: nil,
                                      runFingerprint: nil),
            apiKey: "")
        eq("1 a resumed batch segments as Manual", batch.segmentationApproach, .manual)

        // 2. The pure half.
        eq("2 keep follows the proposal", FlaggedGapAnswer.keep.decision(proposed: .continue), .continue)
        eq("2 split starts a document", FlaggedGapAnswer.split.decision(proposed: .continue), .new)
        eq("2 join continues", FlaggedGapAnswer.join.decision(proposed: .new), .continue)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("APSegReviewTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (1...6).map { dir.appendingPathComponent("page-\($0).jpg") }
        for u in urls { try? syntheticJPEG().write(to: u) }

        let kinds: [PhotoKind?] = [.folder, nil, nil, nil, nil, nil]
        let pages = WindowStagePages(fileIndices: Array(0..<6), urls: urls, photoKinds: kinds)
        func gp(_ g: Int, _ d: GapDecision, _ c: Double, flagged: Bool, fixed: Bool = false) -> GapProposal {
            GapProposal(gap: g, decision: d, confidence: c, agreed: true, flagged: flagged, cue: "c\(g)", fixed: fixed)
        }
        let proposals = [gp(0, .new, 1, flagged: false, fixed: true), gp(1, .new, 0.99, flagged: false),
                         gp(2, .continue, 0.6, flagged: true), gp(3, .continue, 0.8, flagged: true),
                         gp(4, .continue, 0.99, flagged: false)]
        var items = FlaggedReview.items(proposals: proposals, pages: pages, rotations: [0, 0, 90, 0, 0, 0])
        eq("2 the flagged gaps, in order", items.map(\.id), [2, 3])
        eq("2 page n beside page n+1", items.first.map { [$0.leftURL, $0.rightURL] } ?? [], [urls[2], urls[3]])
        eq("2 rotation carried", items.first?.leftRotation, 90)
        eq("2 confidence in words", items.map(\.confidenceText), ["very low confidence", "low confidence"])
        check("2 not done with an unanswered gap", !FlaggedReview.isComplete(items))
        items[0].answer = .split
        items[1].answer = .keep
        check("2 done once every gap is answered", FlaggedReview.isComplete(items))
        eq("2 classifications", FlaggedReview.classifications(proposals: proposals, photoKinds: kinds, answers: items),
           [.folderLabel, .documentStart, .documentStart, .documentStart, .documentContinuation, .documentContinuation])
        eq("2 answers keyed by the page after the gap", FlaggedReview.answersByPage(items),
           [urls[3].path: .split, urls[4].path: .keep])
        let again = FlaggedReview.items(proposals: proposals, pages: pages, rotations: [],
                                        prior: FlaggedReview.answersByPage(items))
        eq("2 a recorded answer is offered again", again.map(\.answer), [.split, .keep])
        eq("2 count line", FlaggedReview.summary(items), "2 boundaries checked, 1 changed")
        eq("2 no count line without flagged gaps", FlaggedReview.summary([]), nil)

        let options = SegmentationOptionsStore.shared
        check("2 bundled options.json decodes", options != nil)
        if let f = options?.approach(.claude)?.figures?.test {
            let want = f.unflaggedErrorsPer500Pages > 0
                ? "About 1 in \(SegmentationRow.twoSignificant(500 / f.unflaggedErrorsPer500Pages)) pages may still be wrong without having been flagged; a skim catches them."
                : "No unflagged errors were found in \(f.pages) test pages, but your material may differ; a skim catches them."
            eq("2 skim note from the figures", FlaggedReview.skimNote(.claude, options: options), want)
        } else {
            check("2 claude has test figures", false)
        }

        // 3. Partial answers.
        guard let spec = try? options?.spec(for: .claude) else {
            check("3 claude spec resolves", false)
            return
        }
        let w = WindowLayout.windows(pageCount: 6, pages: spec.windowPages, stride: spec.windowStride)
        eq("3 six pages make three windows", w, [0..<4, 0..<6, 3..<6])
        let full = try? await WindowSegmenter(transport: FakeTransport(verdicts: [:]), retryDelay: .zero)
            .segment(pages: urls.map { _ in PageInput(jpeg: Data([0]), text: "") }, photoKinds: kinds,
                     approach: spec)
        let firstOnly = (full?.answered ?? [:]).filter { $0.key.start == 0 && $0.key.end == 4 }
        let partial = OCRProcessor.partialProposals(pages: pages, spec: spec, answered: firstOnly)
        eq("3 gaps the answered window covered are not flagged", partial.prefix(3).map(\.flagged), [false, false, false])
        eq("3 gaps no window answered are flagged at confidence 0",
           partial.suffix(2).map { "\($0.flagged) \($0.confidence)" }, ["true 0.0", "true 0.0"])
        eq("3 no figures: every document gap flagged",
           OCRProcessor.partialProposals(pages: pages, spec: nil, answered: [:]).map(\.flagged),
           [false, true, true, true, true])

        // 4. The manifest.
        var runtime = OCRProcessor().makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil)
        runtime.segmentationApproach = .claude
        var pending = OCRProcessor.PendingRun(
            provider: .gemini, model: LLMProvider.gemini.models[0], thinkingLevel: nil,
            fileURLs: urls, outputDirectory: dir, enableTagging: true, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            gatewayConfig: nil, completedResults: [:], runtimeConfig: runtime)
        let print0 = OCRProcessor.pendingRunFingerprintV2(pending)
        pending.segmentationWindows = full?.answered
        pending.segmentationAnswers = FlaggedReview.answersByPage(items)
        eq("4 the progress fields leave the fingerprint alone", OCRProcessor.pendingRunFingerprintV2(pending), print0)
        let decoded = (try? JSONEncoder().encode(pending))
            .flatMap { try? JSONDecoder().decode(OCRProcessor.PendingRun.self, from: $0) }
        eq("4 the approach survives JSON", decoded?.runtimeConfig?.segmentationApproach, .claude)
        eq("4 the window answers survive JSON", decoded?.segmentationWindows, full?.answered)
        eq("4 the gap answers survive JSON", decoded?.segmentationAnswers, pending.segmentationAnswers)
        if let data = try? JSONEncoder().encode(runtime),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj.removeValue(forKey: "segmentationApproach")
            let old = (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { try? JSONDecoder().decode(OCRProcessor.PendingRunRuntimeConfig.self, from: $0) }
            check("4 a snapshot without the approach decodes, as manual", old != nil && old?.segmentationApproach == nil)
        }

        // 5. The stage, end to end.
        let verdicts: [Int: (String, Double)] = [2: ("new", 0.99), 3: ("continue", 0.6), 4: ("new", 0.99),
                                                5: ("continue", 0.99)]
        let fake = FakeTransport(verdicts: verdicts)
        let p = makeProcessor(urls: urls)
        p.taggingMode = .human   // with the stored approach manual, only the stage itself can turn the classes on
        p.windowTransportOverride = fake
        let savedBox = Box<[OCRProcessor.PendingRun]>()
        savedBox.value = []
        p.pendingRunSaveOverride = { savedBox.value?.append($0) }
        var saved: [OCRProcessor.PendingRun] { savedBox.value ?? [] }
        p.activePendingRun = pending.withoutProgress()
        let outcome = Box<WindowStageOutcome>()
        Task { outcome.value = await p.runWindowSegmentationStage(files: urls, approach: .claude, runConfig: nil) }

        check("5 box/folder confirmation first", await waitFor { p.awaitingBoxFolderConfirmation })
        eq("5 the folder photo is confirmed", p.boxFolderConfirmItems.map(\.fileIndex), [0])
        p.confirmBoxFolderReview()
        check("5 the flagged pass opens", await waitFor { p.awaitingFlaggedReview })
        eq("5 three windows asked", Set(fake.calls), [[1, 2, 3, 4], [1, 2, 3, 4, 5, 6], [4, 5, 6]])
        eq("5 one flagged gap, pages 3 and 4", p.flaggedGapItems.map { [$0.id, $0.answer == nil ? 0 : 1] }, [[2, 0]])
        eq("5 its proposal", p.flaggedGapItems.first?.proposalText, "Same document continues")
        eq("5 the window answers were saved", saved.last?.segmentationWindows?.count, 3)
        p.confirmFlaggedReview()
        check("5 Done refused while a gap is unanswered", p.awaitingFlaggedReview)
        p.flaggedGapItems[0].answer = .split
        p.confirmFlaggedReview()
        check("5 the skim opens", await waitFor { p.awaitingDocumentReview })
        check("5 the skim carries the note", p.reviewSkimNote?.contains("a skim catches them") == true)
        eq("5 the checked page is page 4", p.reviewCheckedFileIndices, [3])
        check("5 the skim offers New document / Continuation", p.reviewShowsDocumentClasses)
        eq("5 the skim shows the applied boundaries", p.documentReviewItems.map(\.classification),
           [.folderLabel, .documentStart, .documentStart, .documentStart, .documentStart, .documentContinuation])
        eq("5 the gap answer was saved", saved.last?.segmentationAnswers, [urls[3].path: .split])
        p.confirmDocumentReview()
        check("5 the stage finishes", await waitFor { outcome.value != nil })
        check("5 done", outcome.value == .done)
        eq("5 the jobs carry the boundaries", p.jobs.map(\.classification),
           [.folderLabel, .documentStart, .documentStart, .documentStart, .documentStart, .documentContinuation])
        eq("5 four documents and the folder", p.segments.count, 5)
        eq("5 the count line", p.segmentationCheckSummary, "1 boundary checked, 1 changed")
        check("5 the note is cleared after the skim", p.reviewSkimNote == nil && p.reviewCheckedFileIndices.isEmpty)

        // 6. Resume.
        let silent = FakeTransport(verdicts: [:], failWith: .fatal("must not be called"))
        let r = makeProcessor(urls: urls)
        r.windowTransportOverride = silent
        r.pendingRunSaveOverride = { _ in }
        r.activePendingRun = saved.last
        let resumed = Box<WindowStageOutcome>()
        Task { resumed.value = await r.runWindowSegmentationStage(files: urls, approach: .claude, runConfig: nil) }
        if await waitFor({ r.awaitingBoxFolderConfirmation }) { r.confirmBoxFolderReview() }
        check("6 the flagged pass opens on resume", await waitFor { r.awaitingFlaggedReview })
        eq("6 the model was not asked again", silent.calls.count, 0)
        eq("6 the gap comes back answered", r.flaggedGapItems.map(\.answer), [.split])
        r.confirmFlaggedReview()
        if await waitFor({ r.awaitingDocumentReview }) { r.confirmDocumentReview() }
        check("6 the resumed stage finishes", await waitFor { resumed.value == .done })

        // 7. A usage limit.
        let limited = FakeTransport(verdicts: [:], failWith: .usageLimit(reset: nil, message: "hit your limit"))
        let u = makeProcessor(urls: urls)
        u.windowTransportOverride = limited
        u.pendingRunSaveOverride = { _ in }
        let limitedOutcome = Box<WindowStageOutcome>()
        Task { limitedOutcome.value = await u.runWindowSegmentationStage(files: urls, approach: .claude, runConfig: nil) }
        if await waitFor({ u.awaitingBoxFolderConfirmation }) { u.confirmBoxFolderReview() }
        check("7 the limit asks", await waitFor { u.windowStopPrompt != nil })
        check("7 the message says why", u.windowStopPrompt?.message.contains("usage limit") == true)
        check("7 no manifest: not resumable", u.windowStopPrompt?.canResumeLater == false)
        u.answerWindowStop(.checkMyself)
        check("7 the flagged pass opens", await waitFor { u.awaitingFlaggedReview })
        eq("7 every document gap is flagged", u.flaggedGapItems.map(\.id), [1, 2, 3, 4])
        eq("7 at confidence 0", Set(u.flaggedGapItems.map(\.confidence)), [0])
        u.cancel()
        check("7 cancel ends the stage", await waitFor { limitedOutcome.value == .stopped })
        check("7 cancel closes the pass", !u.awaitingFlaggedReview && u.flaggedReviewContinuation == nil)

        // 7b. Stop with a manifest: resumable, the run ends, the answers so far are kept.
        let s2 = makeProcessor(urls: urls)
        s2.windowTransportOverride = limited
        let keptBox = Box<OCRProcessor.PendingRun>()
        s2.pendingRunSaveOverride = { keptBox.value = $0 }
        s2.activePendingRun = pending.withoutProgress()
        s2.isProcessing = true
        let stopped = Box<WindowStageOutcome>()
        Task { stopped.value = await s2.runWindowSegmentationStage(files: urls, approach: .claude, runConfig: nil) }
        if await waitFor({ s2.awaitingBoxFolderConfirmation }) { s2.confirmBoxFolderReview() }
        check("7b the limit asks, resumable", await waitFor { s2.windowStopPrompt?.canResumeLater == true })
        s2.answerWindowStop(.stop)
        check("7b stop ends the stage", await waitFor { stopped.value == .stopped })
        check("7b the run is no longer processing", !s2.isProcessing)
        check("7b the status says so", s2.statusMessage.hasPrefix("Stopped before segmentation"), s2.statusMessage)
        check("7b the manifest was saved before stopping", keptBox.value != nil)
        check("7b the prompt is gone", s2.windowStopPrompt == nil && s2.windowStopContinuation == nil)
    }

    private static func makeProcessor(urls: [URL]) -> OCRProcessor {
        let p = OCRProcessor()
        p.taggingMode = .automatic
        p.jobs = urls.enumerated().map { i, u in
            var j = OCRJob(sourceURL: u)
            let cls: DocumentClassification = i == 0 ? .folderLabel : .documentStart
            j.status = .succeeded
            j.classification = cls
            j.result = OCRResult(text: "page \(i + 1) text", classification: cls, rotationDegrees: 0,
                                 errorMessage: nil, errorCode: nil)
            return j
        }
        return p
    }

    /// Poll the main actor until `condition` holds (up to 10 s).
    private static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func syntheticJPEG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 60, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .jpeg, properties: [:]) ?? Data()
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SEGMENTATION_REVIEW_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}

private extension OCRProcessor.PendingRun {
    func withoutProgress() -> Self {
        var r = self
        r.segmentationWindows = nil
        r.segmentationAnswers = nil
        return r
    }
}
