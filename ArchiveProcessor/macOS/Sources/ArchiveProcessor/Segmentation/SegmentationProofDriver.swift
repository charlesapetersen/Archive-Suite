import Foundation

/// Headless proof of the segmentation build on one small real folder, through real models (W36.seg-opt-proof),
/// gated by `SEGMENTATION_PROOF=1` (does nothing in normal use). PAID: each API-key run costs cents, and the plan
/// run uses the signed-in `claude`'s plan. Run only by `scripts/test-segmentation-proof.sh`, which states the cost
/// first, copies the folder's pages to a temp directory and hands over the keys it read; this driver reads no
/// Keychain item, draws no window, saves no run manifest (redirected to memory) and puts back the plan
/// calibration the stage records.
///
/// Each run goes through `runWindowSegmentationStage` as Process Files does, with only the transport's keys handed
/// in (`windowTransportFactory`, the production `WindowStageTransport.make` and the stage's own plan gate). The
/// driver plays a careful user: confirms the folder photo, answers every flagged gap from the folder's truth
/// (Keep when the proposal is right, else Split or Join), accepts the skim unchanged, and scores the result.
///
/// What has to be true, per run: the stage ends `.done`; every window got an answer (no gap at confidence 0); the
/// tokens went to the route's own transport (API tokens metered on the key routes, plan meter readings on the
/// plan route, none crossing over); and every answered gap landed in the jobs. The figures (pages in an exactly
/// right document before and after the review, flagged and unflagged-wrong gaps) are reported, not asserted: one
/// folder is too small to test the shipped figures.
@MainActor
enum SegmentationProofDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENTATION_PROOF"] == "1" else { return }
        didRun = true
        Task { @MainActor in
            await run()
            finish()
        }
    }

    private static var lines: [String] = []
    private static var results: [[String: Any]] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    // MARK: - The folder

    struct Page: Decodable {
        let image: String
        let text: String
        /// The ground truth: Box, Folder, New or Cont.
        let label: String
    }

    struct Manifest: Decodable {
        let folder: String
        let pages: [Page]
    }

    /// Whether the gap before page `i` (1-based in `labels`' order, i ≥ 1) is a boundary in the truth.
    static func truthNew(_ labels: [String], gap g: Int) -> Bool { labels[g + 1] != "Cont" }

    /// Pages that land in an exactly right document, given each gap's "starts a document" decision.
    static func exactPages(predicted: [Bool], truth: [Bool]) -> Int {
        func spans(_ starts: [Bool]) -> [ClosedRange<Int>] {
            var out: [ClosedRange<Int>] = []
            var a = 0
            for (g, s) in starts.enumerated() where s {
                out.append(a...g)
                a = g + 1
            }
            out.append(a...starts.count)
            return out
        }
        let right = Set(spans(truth))
        return spans(predicted).filter { right.contains($0) }.reduce(0) { $0 + $1.count }
    }

    // MARK: - Metering the API route

    /// Sums each provider's billed tokens from the replies, then hands the reply on unchanged.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String: (input: Int, output: Int, calls: Int)] = [:]

        func add(_ provider: String, input: Int, output: Int) {
            lock.withLock {
                let t = tokens[provider] ?? (0, 0, 0)
                tokens[provider] = (t.input + input, t.output + output, t.calls + 1)
            }
        }

        var snapshot: [String: (input: Int, output: Int, calls: Int)] { lock.withLock { tokens } }

        var http: APIWindowTransport.HTTP {
            { [self] request in
                let (data, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
                switch request.url?.host ?? "" {
                case "api.anthropic.com":
                    let u = obj?["usage"] as? [String: Any]
                    add("anthropic", input: int(u?["input_tokens"]), output: int(u?["output_tokens"]))
                case let h where h.contains("googleapis.com"):
                    let u = obj?["usageMetadata"] as? [String: Any]
                    add("gemini", input: int(u?["promptTokenCount"]),
                        output: int(u?["candidatesTokenCount"]) + int(u?["thoughtsTokenCount"]))
                default:
                    add(request.url?.host ?? "?", input: 0, output: 0)
                }
                return (data, response)
            }
        }
    }

    // MARK: - Run

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SEGMENTATION_PROOF_MANIFEST"],
              let data = FileManager.default.contents(atPath: path),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.pages.count > 1 else {
            check("0 the folder manifest reads", false, env["SEGMENTATION_PROOF_MANIFEST"] ?? "unset")
            return
        }
        check("0 bundled options.json decodes", SegmentationOptionsStore.shared != nil)
        let runs = (env["SEGMENTATION_PROOF_RUNS"] ?? "").split(separator: ",").map(String.init)
        var keys: [WindowProvider: String] = [:]
        if let k = env["SEGMENTATION_PROOF_ANTHROPIC_KEY"], !k.isEmpty { keys[.anthropic] = k }
        if let k = env["SEGMENTATION_PROOF_GEMINI_KEY"], !k.isEmpty { keys[.gemini] = k }
        let claude = LocalAgentClient.resolveBinaryPath(tool: .claude, override: env["SEGMENTATION_PROOF_CLAUDE"] ?? "")

        // The stage records each plan run's ratio into the app's own defaults; this is a test, so put it back.
        let calibrationKey = DefaultsKeys.segmentationPlanCalibration
        let savedCalibration = UserDefaults.standard.object(forKey: calibrationKey)

        for run in runs {
            let parts = run.split(separator: ":").map(String.init)
            guard parts.count == 2, let approach = SegmentationApproach(rawValue: parts[0]),
                  let route = ClaudeRoute(rawValue: parts[1] == "plan" ? "plan" : "apiKey") else {
                check("\(run) is a known run", false)
                continue
            }
            await prove(manifest: manifest, approach: approach, route: route, name: run, keys: keys, claude: claude)
        }
        // The stage records its ratio from a task it starts as it ends; let that land before putting it back.
        try? await Task.sleep(for: .seconds(3))
        if let savedCalibration { UserDefaults.standard.set(savedCalibration, forKey: calibrationKey) }
        else { UserDefaults.standard.removeObject(forKey: calibrationKey) }
    }

    private static func prove(manifest: Manifest, approach: SegmentationApproach, route: ClaudeRoute, name: String,
                              keys allKeys: [WindowProvider: String], claude: String?) async {
        let labels = manifest.pages.map(\.label)
        let urls = manifest.pages.map { URL(fileURLWithPath: $0.image) }
        guard let spec = try? SegmentationOptionsStore.shared?.spec(for: approach) else {
            check("\(name) spec resolves", false)
            return
        }
        let providers = Set(spec.voters.map(\.provider))
        // The plan route has no Anthropic key, so `make` can only send Claude through `claude`; a key route has no
        // `claude`, so it can only send by key. Either way a wrong route fails rather than passing quietly.
        var keys = allKeys.filter { providers.contains($0.key) }
        if route == .plan { keys[.anthropic] = nil }
        let planBinary = route == .plan ? claude : nil
        if route == .plan && claude == nil {
            check("\(name) finds a signed-in claude", false)
            return
        }

        let meter = Meter()
        let gateBox = SegmentationReviewTestDriver.Box<PlanRunGate>()
        let p = OCRProcessor()
        p.taggingMode = .human
        p.jobs = manifest.pages.enumerated().map { i, page in
            var j = OCRJob(sourceURL: urls[i])
            let cls: DocumentClassification = page.label == "Folder" ? .folderLabel
                : page.label == "Box" ? .boxLabel : .documentStart
            j.status = .succeeded
            j.classification = cls
            j.result = OCRResult(text: page.text, classification: cls, rotationDegrees: 0,
                                 errorMessage: nil, errorCode: nil)
            return j
        }
        p.pendingRunSaveOverride = { _ in }
        p.windowTransportFactory = { spec, gate in
            gateBox.value = gate
            return WindowStageTransport.make(spec, keys: keys, claudeBinary: planBinary, route: route, gate: gate,
                                             http: meter.http)
        }

        let started = Date()
        let outcome = SegmentationReviewTestDriver.Box<WindowStageOutcome>()
        Task { outcome.value = await p.runWindowSegmentationStage(files: urls, approach: approach, runConfig: nil) }

        var flagged: [FlaggedGapItem] = []
        var stopMessage: String?
        var planChecks = 0
        let deadline = Date().addingTimeInterval(45 * 60)
        while outcome.value == nil && Date() < deadline {
            if p.awaitingBoxFolderConfirmation { p.confirmBoxFolderReview() }
            if p.planCheckPrompt != nil {
                planChecks += 1
                p.answerPlanCheck(goOn: true)
            }
            if let stop = p.windowStopPrompt {
                stopMessage = stop.message
                p.answerWindowStop(.stop)
            }
            if p.awaitingFlaggedReview {
                for k in p.flaggedGapItems.indices {
                    let item = p.flaggedGapItems[k]
                    let want: GapDecision = truthNew(labels, gap: item.id) ? .new : .continue
                    p.flaggedGapItems[k].answer = item.proposal == want ? .keep : (want == .new ? .split : .join)
                }
                flagged = p.flaggedGapItems
                p.confirmFlaggedReview()
            }
            if p.awaitingDocumentReview { p.confirmDocumentReview() }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let seconds = Int(Date().timeIntervalSince(started))
        check("\(name) the stage finishes", outcome.value == .done,
              "outcome \(String(describing: outcome.value)) stop: \(stopMessage ?? "none") after \(seconds) s")
        guard outcome.value == .done else {
            p.cancel()
            return
        }

        // Score it.
        let gaps = labels.count - 1
        let truth = (0..<gaps).map { truthNew(labels, gap: $0) }
        let final = (1..<labels.count).map { p.jobs[$0].classification != .documentContinuation }
        var before = final
        for item in flagged { before[item.id] = item.proposal == .new }
        let flaggedIDs = Set(flagged.map(\.id))
        let unflaggedWrong = (0..<gaps).filter { !flaggedIDs.contains($0) && before[$0] != truth[$0] }.count
        let noAnswer = flagged.filter { $0.confidence <= 0 }.count
        let changed = flagged.filter { $0.answer != .keep }.count
        check("\(name) every window answered", noAnswer == 0, "\(noAnswer) gaps had no answer")
        check("\(name) every answered gap landed in the jobs",
              flagged.allSatisfy { final[$0.id] == truth[$0.id] })
        check("\(name) the folder photo stays a label", p.jobs[0].classification == .folderLabel || labels[0] != "Folder")

        // The route.
        let tokens = meter.snapshot
        let records = await gateBox.value?.records ?? []
        let usesClaude = providers.contains(.anthropic)
        if route == .plan && usesClaude {
            check("\(name) Claude went by the plan", !records.isEmpty && tokens["anthropic"] == nil,
                  "\(records.count) plan calls, anthropic API calls \(tokens["anthropic"]?.calls ?? 0)")
            check("\(name) the plan meter was read", records.contains { $0.meter?.fiveHour != nil })
        } else if usesClaude {
            check("\(name) Claude went by key", (tokens["anthropic"]?.calls ?? 0) > 0 && records.isEmpty)
        }
        if providers.contains(.gemini) {
            check("\(name) Gemini went by key", (tokens["gemini"]?.calls ?? 0) > 0)
        }

        var result: [String: Any] = [
            "run": name, "approach": approach.rawValue, "route": route.rawValue, "folder": manifest.folder,
            "pages": labels.count, "gaps": gaps, "seconds": seconds,
            "flagged": flagged.count, "changed_by_review": changed, "unflagged_wrong": unflaggedWrong,
            "pages_exact_no_review": exactPages(predicted: before, truth: truth),
            "pages_exact_after_review": exactPages(predicted: final, truth: truth),
            "count_line": p.segmentationCheckSummary ?? "", "plan_checks_asked": planChecks,
            "api_tokens": tokens.mapValues { ["input": $0.input, "output": $0.output, "calls": $0.calls] },
        ]
        if !records.isEmpty {
            let fives = records.compactMap { $0.meter?.fiveHour }
            let weeks = records.compactMap { $0.meter?.sevenDay }
            result["plan"] = [
                "calls": records.count,
                "notional_usd": records.reduce(0) { $0 + $1.notionalUSD },
                "five_hour_first": fives.first ?? -1, "five_hour_last": fives.last ?? -1,
                "seven_day_first": weeks.first ?? -1, "seven_day_last": weeks.last ?? -1,
                "measurement": "\(PlanCalibration.measure(records))",
            ]
        }
        results.append(result)
        lines.append("RESULT \(name): \(result["pages_exact_no_review"]!)/\(labels.count) pages exact unchecked, "
            + "\(result["pages_exact_after_review"]!)/\(labels.count) after checking \(flagged.count) of \(gaps) gaps "
            + "(\(changed) changed); \(unflaggedWrong) unflagged wrong; \(seconds) s")
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        let env = ProcessInfo.processInfo.environment
        if let out = env["SEGMENTATION_PROOF_JSON"],
           let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: out))
        }
        if let out = env["SEGMENTATION_PROOF_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
