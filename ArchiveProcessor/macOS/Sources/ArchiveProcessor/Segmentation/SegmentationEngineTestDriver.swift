import Foundation

/// Headless, $0 self-test of the window segmenter (W36.seg-opt-engine), gated by `SEGMENTATION_ENGINE_TEST=1`
/// (does nothing in normal use). Recorded answers only: no model call, no network, no key, no GUI, no file
/// written except the report. Run by `scripts/test-segmentation-engine.sh`, which passes the recorded box as
/// `SEGMENTATION_ENGINE_FIXTURE` (`scripts/segbench/engine-fixture-deaver.json`).
///
/// What has to be true:
///   1. The bundled options.json decodes and is fit to ship; every approach id has a case and back; each
///      approach resolves to its voters, rule and level, and the prompt ids the file names are the app's.
///   2. The window layout is the bench's (7 pages, stride 3, every gap judged twice from 5 pages up).
///   3. Both prompts render byte for byte as the bench renders them.
///   4. The parser takes the bench's replies and refuses the malformed ones it refuses.
///   5. Reproducing the bench: on the recorded development box, every approach's decision, flag, agreement
///      and confidence match `ensemble.judge` gap for gap.
///   6. The rules: one voter's min and mean agree; min breaks a tie to the first most confident voter; mean
///      can accept a confident disagreement; min never does.
///   7. Failure: a window that fails once is retried; one that fails twice leaves the gaps only it covered
///      flagged with confidence 0, and its neighbours' gaps still judged; a reply that does not parse counts.
///   8. A usage limit stops the run, keeps what was answered, and a resume does not ask those windows again.
@MainActor
enum SegmentationEngineTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENTATION_ENGINE_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    // MARK: Fixture

    struct Fixture: Decodable {
        struct Window: Decodable { let start: Int; let end: Int; let reply: String }
        struct Expected: Decodable {
            let gap: Int; let decision: String; let flagged: Bool; let confidence: Double; let agreed: Bool
        }
        struct Prompts: Decodable { let texts: [String]; let w1: String; let g1: String }
        let box: String
        let pages: Int
        let photo_kinds: [String?]
        let voters: [String: String]
        let windows: [String: [Window]]
        let expected: [String: [Expected]]
        let prompts: Prompts
    }

    /// Replies keyed by voter name and window; counts every call.
    final class FakeTransport: WindowTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: String]
        private var _calls: [String: Int] = [:]
        /// Per key, the errors to throw before answering (consumed in order).
        private var script: [String: [Error]]

        init(replies: [String: String], script: [String: [Error]] = [:]) {
            self.replies = replies
            self.script = script
        }

        static func key(_ voter: String, _ start: Int, _ end: Int) -> String { "\(voter)|\(start)|\(end)" }

        var calls: [String: Int] { lock.withLock { _calls } }
        var totalCalls: Int { calls.values.reduce(0, +) }

        func send(_ r: WindowRequest) async throws -> String {
            let k = Self.key(r.voter.name, r.pageNumbers.first! - 1, r.pageNumbers.last!)
            let (err, reply): (Error?, String?) = lock.withLock {
                _calls[k, default: 0] += 1
                var err: Error?
                if var s = script[k], !s.isEmpty { err = s.removeFirst(); script[k] = s }
                return (err, replies[k])
            }
            if let err { throw err }
            guard let reply else { throw WindowTransportError.failed("no recorded reply for \(k)") }
            return reply
        }
    }

    // MARK: Run

    static func run() async {
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("SEGENGINE \(ok ? "PASS" : "FAIL"): \(name)")
        }
        let env = ProcessInfo.processInfo.environment

        // 1. options.json
        var options: SegmentationOptions?
        do { options = try SegmentationOptions.loadBundled() } catch { check("options.json loads: \(error)", false) }
        if let options {
            let problems = options.problems()
            check("options.json is fit to ship\(problems.isEmpty ? "" : ": " + problems.joined(separator: "; "))",
                  problems.isEmpty)
            check("every approach in the file has a case, and every case an approach",
                  Set(options.approaches.map(\.id)) == Set(SegmentationApproach.allCases.map(\.rawValue)))
            check("window shape is the bench's 7 / 3 / 1600 px / 2500 chars",
                  (options.window.pages, options.window.stride, options.window.thumbnailLongEdgePx,
                   options.window.ocrTextCharsPerPage) == (7, 3, 1600, 2500))
            let claude = try? options.spec(for: .claude)
            check("claude: one voter, window-claude on claude-sonnet-5-5, prompt w1, level 0.85",
                  claude?.voters.map(\.name) == ["window-claude"] && claude?.voters.first?.modelID == "claude-sonnet-5-5"
                  && claude?.voters.first?.prompt == .w1 && claude?.level == 0.85)
            let gemini = try? options.spec(for: .gemini)
            check("gemini: gemini-3.8-flash at thinking low, prompt g1, level 0.965",
                  gemini?.voters.first?.modelID == "gemini-3.8-flash" && gemini?.voters.first?.thinkingLevel == "low"
                  && gemini?.voters.first?.prompt == .g1 && gemini?.level == 0.965)
            let mix = try? options.spec(for: .mix)
            check("mix: Claude then Gemini, rule read from the file",
                  mix?.voters.map(\.provider) == [.anthropic, .gemini]
                  && mix?.rule.rawValue == options.approach(.mix)?.rule)
            check("openai is unavailable with the file's reason", {
                if case .unavailable(let id, let why)? = (Result { try options.spec(for: .openai) }).failureError,
                   id == "openai", !why.isEmpty { return true }
                return false
            }())
            check("manual proposes nothing", (Result { try options.spec(for: .manual) }).failureError == .manual)
        }
        check("a prompt id that differs from the app's is refused",
              (try? WindowVoter.resolve("window-claude (Claude Sonnet 5.5, prompt w2)").get()) == nil)
        check("an unknown voter is refused",
              (try? WindowVoter.resolve("window-llama (prompt w1)").get()) == nil)
        check("the stored approach defaults to manual",
              SegmentationApproach.stored(UserDefaults(suiteName: "seg-engine-test-\(UUID().uuidString)")!) == .manual)

        // 2. Layout
        check("layout of 7 pages: [0,4) [0,7) [3,7)",
              WindowLayout.windows(pageCount: 7, pages: 7, stride: 3) == [0..<4, 0..<7, 3..<7])
        check("every gap judged twice for 5…400 pages, once for 2…4 (one window, as in the bench)",
              (5...400).allSatisfy { WindowLayout.coverage(pageCount: $0, pages: 7, stride: 3).allSatisfy { $0 == 2 } }
              && (2...4).allSatisfy { WindowLayout.coverage(pageCount: $0, pages: 7, stride: 3).allSatisfy { $0 == 1 } })
        check("no windows for 0 or 1 page",
              WindowLayout.windows(pageCount: 0, pages: 7, stride: 3).isEmpty
              && WindowLayout.windows(pageCount: 1, pages: 7, stride: 3).isEmpty)

        // 3–5 need the recorded box.
        guard let path = env["SEGMENTATION_ENGINE_FIXTURE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let fx = try? JSONDecoder().decode(Fixture.self, from: data) else {
            check("the recorded box loads (SEGMENTATION_ENGINE_FIXTURE)", false)
            return finish(results)
        }
        check("recorded windows are the engine's layout (\(fx.box), \(fx.pages) pages)",
              fx.windows.values.allSatisfy {
                  $0.map { $0.start..<$0.end } == WindowLayout.windows(pageCount: fx.pages, pages: 7, stride: 3)
              })

        // 3. Prompts
        let nums = Array(1...7)
        let w1 = WindowPromptRenderer.render(.w1, pageNumbers: nums, texts: fx.prompts.texts, maxText: 2500)
        let g1 = WindowPromptRenderer.render(.g1, pageNumbers: nums, texts: fx.prompts.texts, maxText: 2500)
        check("prompt w1 renders as the bench's", w1 == fx.prompts.w1)
        check("prompt g1 renders as the bench's", g1 == fx.prompts.g1)
        check("format: literal braces, one pass",
              WindowPromptRenderer.format("{{x}} {a} {b}", ["a": "{b}", "b": "B"]) == "{x} {b} B")

        // 4. Parser
        let good = #"{"pages":[{"page":4,"kind":"document"},{"page":5,"kind":"box"}],"boundaries":[{"between":[4,5],"decision":"new","cue":"label","confidence":0.9}]}"#
        let parsed = try? WindowAnswerParser.parse("```json\n\(good)\n```", pageNumbers: [4, 5])
        check("parser: fenced reply", parsed?.votes[4] == WindowVote(decision: .new, confidence: 0.9, cue: "label")
              && parsed?.kinds[5] == "box")
        func refuses(_ s: String, _ n: [Int] = [4, 5]) -> Bool {
            (try? WindowAnswerParser.parse(s, pageNumbers: n)) == nil
        }
        check("parser refuses prose", refuses("I think page 5 is new."))
        check("parser refuses a missing page", refuses(good.replacingOccurrences(of: #"{"page":5,"kind":"box"}"#, with: "")
            .replacingOccurrences(of: ",]", with: "]")))
        check("parser refuses a gap outside the window", refuses(good, [4, 5, 6]))
        check("parser refuses a bad kind", refuses(good.replacingOccurrences(of: "\"box\"", with: "\"label\"")))
        check("parser refuses a confidence above 1", refuses(good.replacingOccurrences(of: "0.9", with: "1.2")))
        check("parser refuses a bad decision", refuses(good.replacingOccurrences(of: "\"new\"", with: "\"split\"")))

        // 5. Reproduce the bench on the recorded box.
        let codes = ["C": "window-claude", "G": "window-gemini-3.8-flash-low"]
        var replies: [String: String] = [:]
        for (code, ws) in fx.windows {
            for w in ws { replies[FakeTransport.key(codes[code]!, w.start, w.end)] = w.reply }
        }
        let photo = fx.photo_kinds.map { $0.flatMap { PhotoKind(rawValue: $0.lowercased()) } }
        let pages = (0..<fx.pages).map { PageInput(jpeg: Data(), text: "page \($0 + 1)") }
        if let options {
            for (id, expected) in fx.expected.sorted(by: { $0.key < $1.key }) {
                guard let approach = SegmentationApproach(rawValue: id), let spec = try? options.spec(for: approach) else {
                    check("\(id): resolves", false); continue
                }
                let fake = FakeTransport(replies: replies)
                guard let out = try? await WindowSegmenter(transport: fake).segment(
                    pages: pages, photoKinds: photo, approach: spec) else {
                    check("\(id): segments the recorded box", false); continue
                }
                let doc = out.proposals.filter { !$0.fixed }
                let byGap = Dictionary(uniqueKeysWithValues: doc.map { ($0.gap, $0) })
                let mismatches = expected.filter { e in
                    guard let p = byGap[e.gap] else { return true }
                    return p.decision.rawValue != e.decision || p.flagged != e.flagged || p.agreed != e.agreed
                        || abs(p.confidence - e.confidence) > 1e-12
                }
                check("\(id): \(expected.filter(\.flagged).count) of \(expected.count) document gaps flagged, every gap "
                      + "as the bench judged it\(mismatches.isEmpty ? "" : " — differs at \(mismatches.prefix(5).map(\.gap))")",
                      mismatches.isEmpty && doc.count == expected.count)
                check("\(id): one call per window, none failed",
                      fake.totalCalls == spec.voters.count * WindowLayout.windows(pageCount: fx.pages, pages: 7, stride: 3).count
                      && out.failed.isEmpty)
                check("\(id): gaps beside a label photo are fixed boundaries",
                      out.proposals.filter(\.fixed).allSatisfy { $0.decision == .new && !$0.flagged }
                      && out.proposals.filter(\.fixed).count == fx.pages - 1 - expected.count)
            }
        }

        // 6. Rules
        func v(_ d: GapDecision, _ c: Double) -> VoterGapVerdict {
            VoterGapVerdict(pNew: d == .new ? c : 1 - c, decision: d, confidence: c, cue: "")
        }
        let one = [v(.new, 0.7)]
        check("one voter: min and mean agree at every level", [-1, 0.5, 0.6, 0.7, 0.8, 0.95].allSatisfy { lv in
            let a = WindowCombiner.judge(one, rule: .min, level: lv), b = WindowCombiner.judge(one, rule: .mean, level: lv)
            return a.decision == b.decision && a.flagged == b.flagged
        })
        check("one voter: flagged at or below the level, not above",
              WindowCombiner.judge(one, rule: .min, level: 0.7).flagged && !WindowCombiner.judge(one, rule: .min, level: 0.69).flagged)
        check("min: a tie goes to the first most confident voter",
              WindowCombiner.judge([v(.continue, 0.8), v(.new, 0.8)], rule: .min, level: 0).decision == .continue
              && WindowCombiner.judge([v(.continue, 0.7), v(.new, 0.8)], rule: .min, level: 0).decision == .new)
        let split = [v(.new, 0.9), v(.continue, 0.6)]
        let mean = WindowCombiner.judge(split, rule: .mean, level: 0.6)
        check("mean: a confident disagreement can be accepted",
              mean.decision == .new && !mean.flagged && !mean.agreed && WindowCombiner.judge(split, rule: .mean, level: 0.7).flagged)
        check("min: a disagreement is always flagged", WindowCombiner.judge(split, rule: .min, level: -1).flagged)

        // 7–8. Failure and the usage limit, on the recorded box with the Claude voter.
        if let options, let spec = try? options.spec(for: .claude), let ws = fx.windows["C"] {
            let w5 = ws[5], vname = "window-claude"
            let k5 = FakeTransport.key(vname, w5.start, w5.end)
            let clean = try? await WindowSegmenter(transport: FakeTransport(replies: replies))
                .segment(pages: pages, photoKinds: photo, approach: spec)

            let once = FakeTransport(replies: replies, script: [k5: [WindowTransportError.failed("HTTP 503")]])
            let r1 = try? await WindowSegmenter(transport: once).segment(pages: pages, photoKinds: photo, approach: spec)
            check("a window that fails once is retried and the result is unchanged",
                  once.calls[k5] == 2 && r1?.proposals == clean?.proposals && r1?.failed.isEmpty == true)

            // Every gap is judged by two windows, so two overlapping windows must fail to leave a gap unanswered.
            let k6 = FakeTransport.key(vname, ws[6].start, ws[6].end)
            var garbled = replies
            garbled[k5] = "not json"
            garbled[k6] = "{}"
            let twice = FakeTransport(replies: garbled)
            let r2 = try? await WindowSegmenter(transport: twice).segment(pages: pages, photoKinds: photo, approach: spec)
            func gaps(_ w: Fixture.Window) -> Set<Int> { Set(w.start..<(w.end - 1)) }
            let others = gaps(ws[4]).union(gaps(ws[7]))
            let only = gaps(w5).union(gaps(ws[6])).subtracting(others)
            let docOnly = only.filter { photo[$0] == nil && photo[$0 + 1] == nil }
            let shared = gaps(w5).union(gaps(ws[6])).intersection(others).filter { photo[$0] == nil && photo[$0 + 1] == nil }
            check("an unparseable window is asked twice, then recorded as failed",
                  twice.calls[k5] == 2 && twice.calls[k6] == 2 && r2?.failed.count == 2)
            check("gaps only the failed windows covered are flagged with confidence 0 (\(docOnly.count) document gaps)",
                  !docOnly.isEmpty
                  && (r2.map { r in docOnly.allSatisfy { r.proposals[$0].flagged && r.proposals[$0].confidence == 0 } } ?? false))
            check("gaps another window covered keep a real verdict (\(shared.count) document gaps)",
                  !shared.isEmpty && (r2.map { r in shared.allSatisfy { r.proposals[$0].confidence > 0 } } ?? false))

            let reset = Date(timeIntervalSince1970: 2_000_000_000)
            let k20 = FakeTransport.key(vname, ws[20].start, ws[20].end)
            let limited = FakeTransport(replies: replies, script: [
                k20: [WindowTransportError.usageLimit(reset: reset, message: "limit")]])
            var seg = WindowSegmenter(transport: limited)
            seg.maxConcurrent = 1
            var kept: [WindowKey: WindowAnswer] = [:]
            do {
                _ = try await seg.segment(pages: pages, photoKinds: photo, approach: spec)
                check("a usage limit stops the run", false)
            } catch WindowSegmenterError.usageLimit(let r, _, let answered) {
                kept = answered
                check("a usage limit stops the run with its reset time and the 20 windows already answered",
                      r == reset && answered.count == 20 && limited.calls[k20] == 1 && limited.totalCalls == 21)
            } catch {
                check("a usage limit stops the run (\(error))", false)
            }
            let resume = FakeTransport(replies: replies)
            let r3 = try? await WindowSegmenter(transport: resume)
                .segment(pages: pages, photoKinds: photo, approach: spec, answered: kept)
            check("a resume asks only the windows not yet answered, and matches a clean run",
                  resume.totalCalls == ws.count - 20 && resume.calls.keys.allSatisfy { kept[keyOf($0)] == nil }
                  && r3?.proposals == clean?.proposals)
        }
        var mismatchRefused = false
        do {
            _ = try await WindowSegmenter(transport: FakeTransport(replies: [:])).segment(
                pages: [PageInput(jpeg: Data(), text: "")], photoKinds: [], approach: ApproachSpec(
                    approach: .claude, voters: [WindowVoter.catalog[0]], rule: .min, level: 0.85,
                    windowPages: 7, windowStride: 3, thumbnailLongEdgePx: 1600, ocrTextChars: 2500))
        } catch WindowSegmenterError.pageCountMismatch {
            mismatchRefused = true
        } catch {}
        check("page and photo counts must match", mismatchRefused)

        finish(results)
    }

    private static func keyOf(_ s: String) -> WindowKey {
        let p = s.split(separator: "|")
        return WindowKey(voter: String(p[0]), start: Int(p[1])!, end: Int(p[2])!)
    }

    private static func finish(_ results: [String]) {
        let passed = !results.isEmpty && results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["SEGMENTATION_ENGINE_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-segengine-result.txt")
        try? Data(report.utf8).write(to: outPath, options: .atomic)
        NSLog("SEGENGINE DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath.path)")
        exit(passed ? 0 : 1)
    }
}

private extension Result where Failure == Error {
    var failureError: SegmentationOptionsError? {
        if case .failure(let e) = self { return e as? SegmentationOptionsError }
        return nil
    }
}
