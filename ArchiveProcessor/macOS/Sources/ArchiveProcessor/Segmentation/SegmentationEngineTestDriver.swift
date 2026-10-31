#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
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
///   3. Every prompt (w1, g1, c1) renders byte for byte as the bench renders it.
///   4. The parser takes the bench's replies and refuses the malformed ones it refuses.
///   5. Reproducing the bench: on the recorded development box, every approach's decision, flag, agreement
///      and confidence match `ensemble.judge` gap for gap.
///   6. The rules: one voter's min and mean agree; min breaks a tie to the first most confident voter; mean
///      can accept a confident disagreement; min never does.
///   7. Failure: a window that fails once is retried; one that fails twice leaves the gaps only it covered
///      flagged with confidence 0, and its neighbours' gaps still judged; a reply that does not parse counts.
///   8. A usage limit stops the run, keeps what was answered, and a resume does not ask those windows again.
///   9. The transports send what the bench sent (labelled images, then the prompt; Gemini's schema, temperature 0
///      and thinking level; the key in a header, never the URL), read the reply as the bench did, map a 429 or a
///      plan limit to a usage-limit stop, and run `claude` in a temp dir holding the window's page files. A whole
///      Gemini run through the HTTP seam matches the recorded verdict.
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
        struct Prompts: Decodable { let texts: [String]; let w1: String; let g1: String; let c1: String }
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
            check("mix: Claude then ChatGPT, rule read from the file",
                  mix?.voters.map(\.provider) == [.anthropic, .openai]
                  && mix?.rule.rawValue == options.approach(.mix)?.rule)
            let openai = try? options.spec(for: .openai)
            check("openai: gpt-6.1-sol at thinking low, prompt c1, level 0.99",
                  openai?.voters.map(\.name) == ["window-openai"] && openai?.voters.first?.modelID == "gpt-6.1-sol"
                  && openai?.voters.first?.thinkingLevel == "low" && openai?.voters.first?.prompt == .c1
                  && openai?.level == 0.99)
            check("manual proposes nothing", (Result { try options.spec(for: .manual) }).failureError == .manual)
        }
        check("a prompt id that differs from the app's is refused",
              (try? WindowVoter.resolve("window-claude (Claude Sonnet 5.5, prompt w2)").get()) == nil)
        check("an unknown voter is refused",
              (try? WindowVoter.resolve("window-llama (prompt w1)").get()) == nil)
        let suite = "seg-engine-test-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            let unset = SegmentationApproach.stored(d)
            d.set("gemini", forKey: DefaultsKeys.segmentationApproach)
            let set = SegmentationApproach.stored(d)
            d.set("per-page", forKey: DefaultsKeys.segmentationApproach)
            let junk = SegmentationApproach.stored(d)
            d.removePersistentDomain(forName: suite)
            check("the stored approach: manual when unset or unknown, the stored case otherwise",
                  unset == .manual && set == .gemini && junk == .manual)
        }

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
        let c1 = WindowPromptRenderer.render(.c1, pageNumbers: nums, texts: fx.prompts.texts, maxText: 2500)
        check("prompt c1 renders as the bench's", c1 == fx.prompts.c1)
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
        let codes = ["C": "window-claude", "G": "window-gemini-3.8-flash-low", "O": "window-openai"]
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
                guard let out = try? await WindowSegmenter.instant(fake).segment(
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
            let clean = try? await WindowSegmenter.instant(FakeTransport(replies: replies))
                .segment(pages: pages, photoKinds: photo, approach: spec)

            let once = FakeTransport(replies: replies, script: [k5: [WindowTransportError.failed("HTTP 503")]])
            let r1 = try? await WindowSegmenter.instant(once).segment(pages: pages, photoKinds: photo, approach: spec)
            check("a window that fails once is retried and the result is unchanged",
                  once.calls[k5] == 2 && r1?.proposals == clean?.proposals && r1?.failed.isEmpty == true)

            var oneMissing = replies
            oneMissing[k5] = "not json"
            let proofMeter = SegmentationProofDriver.Meter()
            let recorded = SegmentationProofDriver.RecordingTransport(base: FakeTransport(replies: oneMissing), meter: proofMeter)
            let masked = try? await WindowSegmenter.instant(recorded).segment(pages: pages, photoKinds: photo, approach: spec)
            check("proof: overlapping answers cannot hide a failed window",
                  masked?.failed.count == 1 && masked?.proposals.allSatisfy { $0.confidence > 0 } == true
                  && proofMeter.answeredWindows.count == ws.count - 1
                  && proofMeter.answeredWindows.keys.allSatisfy { $0.start != w5.start || $0.end != w5.end })

            // Every gap is judged by two windows, so two overlapping windows must fail to leave a gap unanswered.
            let k6 = FakeTransport.key(vname, ws[6].start, ws[6].end)
            var garbled = replies
            garbled[k5] = "not json"
            garbled[k6] = "{}"
            let twice = FakeTransport(replies: garbled)
            let r2 = try? await WindowSegmenter.instant(twice).segment(pages: pages, photoKinds: photo, approach: spec)
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
            var seg = WindowSegmenter.instant(limited)
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
            let r3 = try? await WindowSegmenter.instant(resume)
                .segment(pages: pages, photoKinds: photo, approach: spec, answered: kept)
            check("a resume asks only the windows not yet answered, and matches a clean run",
                  resume.totalCalls == ws.count - 20 && resume.calls.keys.allSatisfy { kept[keyOf($0)] == nil }
                  && r3?.proposals == clean?.proposals)
        }
        // 9. Transports
        if let options {
            for (name, ok) in await transportChecks(options: options, fx: fx, replies: replies, photo: photo, pages: pages) {
                check(name, ok)
            }
        }

        // 10. The corpus-trained 2B on this Mac (W41.app-local-seg).
        if let options {
            for (name, ok) in await localChecks(options: options) { check(name, ok) }
        }

        // Fatal: the run stops at once and no window is retried.
        if let options, let spec = try? options.spec(for: .claude) {
            final class Refusing: WindowTransport, @unchecked Sendable {
                let lock = NSLock(); var n = 0
                func send(_ r: WindowRequest) async throws -> String {
                    lock.withLock { n += 1 }
                    throw WindowTransportError.fatal("401")
                }
            }
            let refusing = Refusing()
            var seg = WindowSegmenter.instant(refusing)
            seg.maxConcurrent = 1
            var stopped = false
            do { _ = try await seg.segment(pages: pages, photoKinds: photo, approach: spec) }
            catch WindowSegmenterError.fatal { stopped = true } catch {}
            check("a fatal transport error stops the run after one call, not every gap flagged at 0",
                  stopped && refusing.lock.withLock { refusing.n } == 1)

            // Answers kept from a run of other pages are not reused.
            let all = FakeTransport(replies: replies)
            let full = try? await WindowSegmenter.instant(all).segment(pages: pages, photoKinds: photo, approach: spec)
            let shorter = FakeTransport(replies: [:])
            _ = try? await WindowSegmenter.instant(shorter).segment(
                pages: Array(pages.dropLast()), photoKinds: Array(photo.dropLast()), approach: spec,
                answered: full?.answered ?? [:])
            check("answers from a run with another page count are not reused",
                  full != nil && shorter.totalCalls >= WindowLayout.windows(pageCount: fx.pages - 1, pages: 7, stride: 3).count)
        }
        let oneMissing = WindowCombiner.proposals(photoKinds: [nil, nil],
            voters: [[VoterGapVerdict(pNew: 0.1, decision: .continue, confidence: 0.9, cue: "")], [nil]],
            rule: .min, level: 0.5)
        check("mix: a gap one voter did not answer is flagged at 0, decided by the voter that did",
              oneMissing.first.map { $0.flagged && $0.confidence == 0 && $0.decision == .continue && !$0.agreed } ?? false)

        var mismatchRefused = false
        do {
            _ = try await WindowSegmenter.instant(FakeTransport(replies: [:])).segment(
                pages: [PageInput(jpeg: Data(), text: "")], photoKinds: [], approach: ApproachSpec(
                    voters: [WindowVoter.catalog[0]], rule: .min, level: 0.85,
                    windowPages: 7, windowStride: 3, thumbnailLongEdgePx: 1600, ocrTextChars: 2500))
        } catch WindowSegmenterError.pageCountMismatch {
            mismatchRefused = true
        } catch {}
        check("page and photo counts must match", mismatchRefused)

        finish(results)
    }

    /// The `local` approach: its spec, the request the model was trained on, the reply guards, the keyless route, and
    /// a stopped server stopping the run at once rather than holding every window to its timeout.
    private static func localChecks(options: SegmentationOptions) async -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        let spec = try? options.spec(for: .local)
        let voter = spec?.voters.first
        check("local: one voter, window-local-seg-2b on this Mac, prompt c1, 1,024 px pages, level from the file",
              spec?.voters.count == 1 && voter?.name == "window-local-seg-2b" && voter?.provider == .local
              && voter?.prompt == .c1 && spec?.thumbnailLongEdgePx == 1024
              && spec?.level == options.approach(.local)?.level)
        check("local: no other approach changes image size",
              SegmentationApproach.allCases.filter { $0 != .local && $0.proposesBoundaries }
                .allSatisfy { (try? options.spec(for: $0))?.thumbnailLongEdgePx == options.window.thumbnailLongEdgePx })
        check("local: costs nothing and carries its Mac figures",
              options.approach(.local)?.cost?.total.listUSDPer1000Pages == 0
              && options.approach(.local)?.mac?.peakMemoryGB == 4.4)
        guard let voter else { return out }

        // The request: the images alone in page order, then the prompt (no "Page n:" lines, as trained); temperature
        // 0; thinking off under every spelling; the placeholder bearer, never a key; the user's model and server.
        let r = WindowRequest(voter: voter, prompt: "PROMPT", images: [Data([1]), Data([2]), Data([3])],
                              pageNumbers: [4, 5, 6])
        if let q = try? LocalWindowTransport.request(r, baseURL: "http://127.0.0.1:9999/v1/", modelID: "me/seg") {
            let b = (q.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let content = ((b["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            check("local request: the user's server and model, chat completions",
                  q.url?.absoluteString == "http://127.0.0.1:9999/v1/chat/completions" && b["model"] as? String == "me/seg")
            check("local request: three images then the prompt, no page labels",
                  content.count == 4 && content.prefix(3).allSatisfy { $0["type"] as? String == "image_url" }
                  && content.last?["text"] as? String == "PROMPT")
            check("local request: temperature 0, thinking off, the bench's budget",
                  (b["temperature"] as? NSNumber)?.intValue == 0 && b["enable_thinking"] as? Bool == false
                  && (b["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false
                  && b["max_tokens"] as? Int == LocalSegmenter.maxTokens)
            check("local request: the placeholder bearer only",
                  q.value(forHTTPHeaderField: "Authorization") == "Bearer \(LocalModelRoute.placeholderKey)")
        } else {
            check("local request builds", false)
        }

        // Replies.
        func text(_ status: Int, _ obj: Any) -> Result<String, Error> {
            let (d, _) = Self.localReply(status, obj)
            return Result { try LocalWindowTransport.replyText(data: d, status: status) }
        }
        func isFatal(_ r: Result<String, Error>) -> Bool {
            if case .failure(WindowTransportError.fatal) = r { return true } else { return false }
        }
        func isFailed(_ r: Result<String, Error>) -> Bool {
            if case .failure(WindowTransportError.failed) = r { return true } else { return false }
        }
        check("local reply: the answer is read", (try? text(200, Self.localChat(#"{"pages":[]}"#)).get()) == #"{"pages":[]}"#)
        check("local reply: a reasoning block is stripped",
              (try? text(200, Self.localChat("<think>hm</think>\n{\"pages\":[]}")).get()) == #"{"pages":[]}"#)
        check("local reply: cut at the budget is this window's failure", isFailed(text(200, Self.localChat("{\"pa", finish: "length"))))
        check("local reply: all reasoning is this window's failure", isFailed(text(200, Self.localChat("<think>still going"))))
        check("local reply: an unknown model (404) stops the run", isFatal(text(404, ["error": "model not found"])))
        check("local reply: a server error is this window's failure", isFailed(text(500, ["detail": "boom"])))

        // The route: no key needed, and the user's server and model reach the transport.
        if let spec {
            switch WindowStageTransport.make(spec, keys: [:], claudeBinary: nil,
                                             local: ("http://127.0.0.1:9999/v1", "me/seg")) {
            case .success(let t):
                let local = (t as? RoutingWindowTransport)?.routes[.local] as? LocalWindowTransport
                check("local: routed with no key, to the user's server and model",
                      local?.baseURL == "http://127.0.0.1:9999/v1" && local?.modelID == "me/seg")
            case .failure(let m):
                check("local: routed with no key (\(m.description))", false)
            }

            // The model's manifest (W46.kit-gate): the shipped build runs; any other model must be a folder whose
            // manifest names prompt c1 and carries an anchor score. Read through the seam: no file is touched.
            func manifest(_ json: String?) -> (URL) -> Data? {
                { url in url.lastPathComponent == LocalSegmenter.manifestName ? json.map { Data($0.utf8) } : nil }
            }
            func refused(_ json: String?, _ modelID: String = "/models/mine") -> String {
                LocalSegmenter.refusal(modelID: modelID, read: manifest(json)) ?? ""
            }
            let good = #"{"kit_version":"seg-kit-1","prompt_id":"c1","anchor":{"box":"Lincoln","pages_exact":34.87}}"#
            check("manifest: the shipped model needs none",
                  LocalSegmenter.refusal(modelID: LocalSegmenter.defaultModelID, read: manifest(nil)) == nil)
            check("manifest: a folder with an anchor score and prompt c1 runs",
                  LocalSegmenter.refusal(modelID: "/models/mine", read: manifest(good)) == nil)
            check("manifest: a repository other than the shipped one is refused",
                  refused(good, "me/seg").contains("not the shipped model"))
            check("manifest: a folder without one is refused", refused(nil).contains("has no"))
            check("manifest: no anchor score is refused",
                  refused(#"{"kit_version":"seg-kit-1","prompt_id":"c1","anchor":null}"#).contains("no anchor score")
                  && refused(#"{"kit_version":"seg-kit-1","prompt_id":"c1","anchor":{"box":"Lincoln"}}"#)
                    .contains("no anchor score"))
            check("manifest: another prompt, another kit version, or unreadable is refused",
                  refused(#"{"kit_version":"seg-kit-1","prompt_id":"w1","anchor":{"box":"L","pages_exact":50}}"#)
                    .contains("prompt w1")
                  && refused(#"{"kit_version":"seg-kit-0","prompt_id":"c1","anchor":{"box":"L","pages_exact":50}}"#)
                    .contains("another version")
                  && refused("not json").contains("could not be read"))

            // A stopped server: the run stops after the one check, with how to start it; no window is sent.
            final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
            let sent = Counter(), probed = Counter()
            var down = LocalWindowTransport(baseURL: "http://127.0.0.1:9999/v1", modelID: "me/seg")
            down.http = { req in sent.lock.withLock { sent.n += 1 }; return Self.localReply(200, Self.localChat("{}")) }
            down.probe = { _ in probed.lock.withLock { probed.n += 1 }; throw URLError(.cannotConnectToHost) }
            let six = (0..<6).map { _ in PageInput(jpeg: Data([1]), text: "") }
            var seg = WindowSegmenter.instant(down)
            seg.maxConcurrent = 1
            var message = ""
            do { _ = try await seg.segment(pages: six, photoKinds: Array(repeating: nil, count: 6), approach: spec) }
            catch WindowSegmenterError.fatal(let m, _) { message = m } catch {}
            check("local: a stopped server stops the run once, with how to start it, and sends no window",
                  message.contains("mlx_vlm.server") && sent.n == 0 && probed.n == 1)

            // A run through the HTTP seam: one three-page window, its answer judged at the file's level.
            var up = LocalWindowTransport(baseURL: "http://127.0.0.1:9999/v1", modelID: "me/seg")
            up.probe = { _ in [] }
            let answer = #"{"pages":[{"page":1,"kind":"document"},{"page":2,"kind":"document"},{"page":3,"kind":"document"}],"boundaries":[{"between":[1,2],"decision":"new","cue":"letterhead","confidence":0.999},{"between":[2,3],"decision":"continue","cue":"same letter","confidence":0.9}]}"#
            up.http = { _ in Self.localReply(200, Self.localChat(answer)) }
            let three = (0..<3).map { _ in PageInput(jpeg: Data([1]), text: "") }
            let res = try? await WindowSegmenter.instant(up).segment(pages: three, photoKinds: [nil, nil, nil],
                                                                       approach: spec)
            let p = res?.proposals ?? []
            check("local: a run through the seam reads the answer and flags at the file's level",
                  p.count == 2 && p[0].decision == .new && !p[0].flagged && p[1].decision == .continue && p[1].flagged)

            // Runs that must stop with a reason rather than finish with every gap at confidence 0. Ten pages are two
            // windows, so four failures in a row are both windows failing twice.
            let ten = (0..<10).map { _ in PageInput(jpeg: Data([1]), text: "") }
            func stops(_ http: @escaping APIWindowTransport.HTTP) async -> (message: String, calls: Int) {
                let calls = Counter()
                var t = LocalWindowTransport(baseURL: "http://127.0.0.1:9999/v1", modelID: "me/seg")
                t.probe = { _ in [] }
                t.http = { req in
                    calls.lock.withLock { calls.n += 1 }
                    return try await http(req)
                }
                var s = WindowSegmenter.instant(t)
                s.maxConcurrent = 1
                do { _ = try await s.segment(pages: ten, photoKinds: Array(repeating: nil, count: 10), approach: spec) }
                catch WindowSegmenterError.fatal(let m, _) { return (m, calls.lock.withLock { calls.n }) } catch {}
                return ("did not stop", calls.lock.withLock { calls.n })
            }
            let isWarmUp: @Sendable (URLRequest) -> Bool = { req in
                let b = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                return b?["max_tokens"] as? Int == 1
            }
            let unloadable = await stops { _ in
                Self.localReply(404, ["error": ["message": "Repository not found"]])
            }
            check("local: a model the server cannot load stops the run at the warm-up, naming it and the reason",
                  unloadable.message.contains("me/seg") && unloadable.message.contains("Repository not found")
                  && unloadable.calls == 1)
            let warmCalls = Counter()
            let died = await stops { req in
                if isWarmUp(req) {
                    warmCalls.lock.withLock { warmCalls.n += 1 }
                    return Self.localReply(200, Self.localChat("OK"))
                }
                throw URLError(.cannotConnectToHost)
            }
            check("local: a server that stops mid-run stops the run at the first window, with how to start it",
                  died.message.contains("stopped answering") && died.message.contains("mlx_vlm.server")
                  && died.calls == 2 && warmCalls.n == 1)
            let failing = await stops { req in
                isWarmUp(req) ? Self.localReply(200, Self.localChat("OK")) : Self.localReply(500, ["detail": "boom"])
            }
            check("local: \(LocalSegmenter.maxFailuresInARow) failures in a row stop the run with the last reason",
                  failing.message.contains("\(LocalSegmenter.maxFailuresInARow) windows in a row")
                  && failing.message.contains("boom") && failing.calls == 1 + LocalSegmenter.maxFailuresInARow)
            let slow = await stops { req in
                if isWarmUp(req) { return Self.localReply(200, Self.localChat("OK")) }
                throw URLError(.timedOut)
            }
            check("local: a slow window is this window's failure, not a stopped server",
                  slow.message.contains("windows in a row") && slow.message.contains("did not answer in time"))
            let dropped = await stops { req in
                if isWarmUp(req) { return Self.localReply(200, Self.localChat("OK")) }
                throw URLError(.networkConnectionLost)
            }
            check("local: a dropped connection is this window's failure, retried, not a stopped server",
                  dropped.message.contains("windows in a row")
                  && dropped.calls == 1 + LocalSegmenter.maxFailuresInARow)
            let prose = await stops { req in
                Self.localReply(200, Self.localChat(isWarmUp(req) ? "OK" : "These pages look like one letter."))
            }
            check("local: replies that never parse stop the run too",
                  prose.message.contains("windows in a row") && prose.message.contains("did not parse"))
        }
        return out
    }

    nonisolated private static func localReply(_ status: Int, _ obj: Any) -> (Data, URLResponse) {
        ((try? JSONSerialization.data(withJSONObject: obj)) ?? Data(),
         HTTPURLResponse(url: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!)
    }

    nonisolated private static func localChat(_ content: String, finish: String = "stop") -> [String: Any] {
        ["choices": [["message": ["content": content], "finish_reason": finish]]]
    }

    private static func transportChecks(options: SegmentationOptions, fx: Fixture, replies: [String: String],
                                        photo: [PhotoKind?], pages: [PageInput]) async -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append((name, ok)) }
        func body(_ r: URLRequest) -> [String: Any] {
            (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        let claude = WindowVoter.catalog[0], gemini = WindowVoter.catalog[1]
        let imgs = [Data([1, 2]), Data([3]), Data([4])]
        func req(_ v: WindowVoter) -> WindowRequest {
            WindowRequest(voter: v, prompt: "PROMPT", images: imgs, pageNumbers: [8, 9, 10])
        }
        let openaiVoter = WindowVoter.catalog[2]
        check("the openai voter is window-openai on gpt-6.1-sol at reasoning low, prompt c1",
              openaiVoter.name == "window-openai" && openaiVoter.modelID == "gpt-6.1-sol"
              && openaiVoter.thinkingLevel == "low" && openaiVoter.prompt == .c1)

        // Request shapes
        if let a = try? APIWindowTransport.request(req(claude), key: "K-A") {
            let b = body(a)
            let content = ((b["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            check("anthropic: Messages, key and version headers, model, labelled images then the prompt",
                  a.url?.absoluteString == "https://api.anthropic.com/v1/messages"
                  && a.value(forHTTPHeaderField: "x-api-key") == "K-A"
                  && a.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
                  && b["model"] as? String == "claude-sonnet-5-5" && content.count == 7
                  && content[0]["text"] as? String == "Page 8:"
                  && (content[1]["source"] as? [String: Any])?["data"] as? String == imgs[0].base64EncodedString()
                  && content[6]["text"] as? String == "PROMPT")
        } else { check("anthropic request builds", false) }
        if let g = try? APIWindowTransport.request(req(gemini), key: "K-G") {
            let b = body(g)
            let cfg = b["generationConfig"] as? [String: Any] ?? [:]
            let parts = ((b["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
            let schema = (try? JSONSerialization.data(withJSONObject: cfg["responseSchema"] ?? [:], options: .sortedKeys))
            let want = try? JSONSerialization.data(withJSONObject: APIWindowTransport.geminiResponseSchema, options: .sortedKeys)
            check("gemini: generateContent on gemini-3.8-flash, the key in a header and not the URL",
                  g.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent"
                  && g.value(forHTTPHeaderField: "x-goog-api-key") == "K-G" && !(g.url?.absoluteString.contains("K-G") ?? true))
            check("gemini: temperature 0, JSON, thinking low, the bench's schema, labelled images then the prompt",
                  (cfg["temperature"] as? NSNumber)?.doubleValue == 0
                  && cfg["responseMimeType"] as? String == "application/json"
                  && (cfg["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low"
                  && schema != nil && schema == want && parts.count == 7 && parts[2]["text"] as? String == "Page 9:"
                  && parts[6]["text"] as? String == "PROMPT")
        } else { check("gemini request builds", false) }
        if let o = try? APIWindowTransport.request(req(openaiVoter), key: "K-O") {
            let b = body(o)
            let content = ((b["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            check("openai: chat completions, bearer key, gpt-6.1-sol at reasoning low, images as data URLs",
                  o.url?.absoluteString == "https://api.openai.com/v1/chat/completions"
                  && o.value(forHTTPHeaderField: "Authorization") == "Bearer K-O" && content.count == 7
                  && b["model"] as? String == "gpt-6.1-sol" && b["reasoning_effort"] as? String == "low"
                  && ((content[1]["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        } else { check("openai request builds", false) }

        // Replies and errors
        func reply(_ p: WindowProvider, _ obj: Any, _ status: Int = 200, headers: [String: String] = [:]) -> Result<String, Error> {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            let resp = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: headers)
            return Result { try APIWindowTransport.replyText(p, data: data, status: status, response: resp) }
        }
        check("anthropic reply: the text blocks joined",
              (try? reply(.anthropic, ["content": [["type": "thinking", "thinking": "x"], ["type": "text", "text": "{a}"]]]).get()) == "{a}")
        check("gemini reply: thought parts skipped",
              (try? reply(.gemini, ["candidates": [["finishReason": "STOP", "content": ["parts": [
                  ["text": "hmm", "thought": true], ["text": "{g}"]]]]]]).get()) == "{g}")
        check("gemini reply: a non-STOP finish is a failure",
              (try? reply(.gemini, ["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["text": "{"]]]]]]).get()) == nil)
        check("openai reply: the message content",
              (try? reply(.openai, ["choices": [["message": ["content": "{o}"]]]]).get()) == "{o}")
        if case .failure(WindowTransportError.usageLimit(let reset, _)) = reply(
            .gemini, ["error": ["status": "RESOURCE_EXHAUSTED", "message": "quota"]], 429, headers: ["Retry-After": "120"]) {
            check("a 429 is a usage-limit stop, with Retry-After as the reset", reset.map { $0.timeIntervalSinceNow > 100 } ?? false)
        } else { check("a 429 is a usage-limit stop", false) }
        if case .failure(WindowTransportError.failed) = reply(.anthropic, ["error": ["type": "api_error", "message": "boom"]], 500) {
            check("a 500 is a plain failure (retried once by the engine)", true)
        } else { check("a 500 is a plain failure", false) }
        check("an empty answer is a failure", (try? reply(.anthropic, ["content": []]).get()) == nil)
        let noKey = APIWindowTransport(keys: [:], http: { _ in throw URLError(.badURL) })
        check("no key for the provider is fatal, and nothing is sent",
              await { () async -> Bool in
                  do { _ = try await noKey.send(req(claude)); return false }
                  catch WindowTransportError.fatal { return true } catch { return false }
              }())
        if case .failure(WindowTransportError.fatal) = reply(.anthropic, ["error": ["type": "authentication_error", "message": "invalid x-api-key"]], 401) {
            check("a refused key (401) is fatal", true)
        } else { check("a refused key (401) is fatal", false) }

        // A whole Gemini run through the HTTP seam.
        let geminiHTTP: APIWindowTransport.HTTP = { request in
            let b = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let parts = ((b["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
            let nums = parts.compactMap { ($0["text"] as? String).flatMap { t in
                t.hasPrefix("Page ") && t.hasSuffix(":") ? Int(t.dropFirst(5).dropLast()) : nil } }
            let text = replies[FakeTransport.key("window-gemini-3.8-flash-low", (nums.first ?? 1) - 1, nums.last ?? 0)] ?? ""
            let obj: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]]
            return (try JSONSerialization.data(withJSONObject: obj),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if let spec = try? options.spec(for: .gemini), let expected = fx.expected["gemini"] {
            let api = APIWindowTransport(keys: [.gemini: "K"], http: geminiHTTP)
            let r = try? await WindowSegmenter.instant(api).segment(pages: pages, photoKinds: photo, approach: spec)
            let flagged = r?.proposals.filter { !$0.fixed && $0.flagged }.map(\.gap)
            check("a Gemini run through the HTTP seam flags the bench's \(expected.filter(\.flagged).count) gaps",
                  flagged == expected.filter(\.flagged).map(\.gap) && r?.failed.isEmpty == true)
        }
        // The mix's ChatGPT voter through the same seam, as chat completions.
        let openaiHTTP: APIWindowTransport.HTTP = { request in
            let b = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let parts = ((b["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            let nums = parts.compactMap { ($0["text"] as? String).flatMap { t in
                t.hasPrefix("Page ") && t.hasSuffix(":") ? Int(t.dropFirst(5).dropLast()) : nil } }
            let text = replies[FakeTransport.key("window-openai", (nums.first ?? 1) - 1, nums.last ?? 0)] ?? ""
            let obj: [String: Any] = ["choices": [["message": ["content": text]]]]
            return (try JSONSerialization.data(withJSONObject: obj),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if let spec = try? options.spec(for: .mix), let expected = fx.expected["mix"] {
            let routed = RoutingWindowTransport(routes: [
                .anthropic: FakeTransport(replies: replies),
                .openai: APIWindowTransport(keys: [.openai: "K"], http: openaiHTTP)])
            let r = try? await WindowSegmenter.instant(routed).segment(pages: pages, photoKinds: photo, approach: spec)
            check("the mix routes each voter to its own transport",
                  r?.proposals.filter { !$0.fixed && $0.flagged }.map(\.gap) == expected.filter(\.flagged).map(\.gap))
        }

        // claude -p
        func run(_ code: Int32, _ out: String, _ err: String = "", timedOut: Bool = false) -> LocalAgentClient.CLIRun {
            LocalAgentClient.CLIRun(exitCode: code, stdout: out, stderr: err, timedOut: timedOut, spawnFailed: false)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check("claude: the envelope's result on success",
              (try? LocalAgentWindowTransport.classify(run(0, #"{"type":"result","subtype":"success","is_error":false,"result":"{c}"}"#), now: now)) == "{c}")
        do {
            _ = try LocalAgentWindowTransport.classify(
                run(1, #"{"subtype":"success","is_error":true,"result":"Claude usage limit reached. Your limit will reset at 3pm."}"#), now: now)
            check("claude: a plan limit stops the run", false)
        } catch WindowTransportError.usageLimit(let reset, _) {
            check("claude: a plan limit stops the run, with the printed reset time", reset != nil)
        } catch { check("claude: a plan limit stops the run", false) }
        do {
            _ = try LocalAgentWindowTransport.classify(
                run(1, #"{"subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#), now: now)
            check("claude: signed out is fatal", false)
        } catch WindowTransportError.fatal { check("claude: signed out is fatal", true) }
        catch { check("claude: signed out is fatal", false) }
        do {
            _ = try LocalAgentWindowTransport.classify(
                run(1, #"{"subtype":"error_during_execution","is_error":true,"result":"boom"}"#, "retrying after rate limit"), now: now)
            check("claude: a parsed error envelope is judged by its result, not stderr", false)
        } catch WindowTransportError.failed {
            check("claude: a parsed error envelope is judged by its result, not stderr", true)
        } catch { check("claude: a parsed error envelope is judged by its result, not stderr", false) }
        check("claude: garbage output is a failure",
              (try? LocalAgentWindowTransport.classify(run(1, "segfault"), now: now)) == nil)
        check("claude: a timeout is a failure",
              (try? LocalAgentWindowTransport.classify(run(-2, "", timedOut: true), now: now)) == nil)

        // A fake claude: proves the working directory holds the window's files and the prompt arrives on stdin.
        let fm = FileManager.default
        let fake = fm.temporaryDirectory.appendingPathComponent("APSegFakeClaude-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        n=$(ls page-0008.jpg page-0009.jpg page-0010.jpg 2>/dev/null | wc -l | tr -d ' ')
        first=$(head -c 6)
        model=""; for a in "$@"; do [ "$prev" = "--model" ] && model="$a"; prev="$a"; done
        printf '{"type":"result","subtype":"success","is_error":false,"result":"%s %s %s"}' "$n" "$first" "$model"
        """
        try? Data(script.utf8).write(to: fake)
        _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let cli = LocalAgentWindowTransport(binaryPath: fake.path, timeout: 30)
        let got = try? await cli.send(req(claude))
        check("claude: run in a temp dir holding page-0008…0010.jpg, prompt on stdin, the voter's model (got \(got ?? "nil"))",
              got == "3 PROMPT claude-sonnet-5-5")
        try? fm.removeItem(at: fake)
        return out
    }

    private static func keyOf(_ s: String) -> WindowKey {
        let p = s.split(separator: "|")
        return WindowKey(voter: String(p[0]), pages: 149, start: Int(p[1])!, end: Int(p[2])!)
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

private extension WindowSegmenter {
    /// No pause before a retry: the tests' failures are scripted, not overload.
    static func instant(_ t: any WindowTransport) -> WindowSegmenter {
        var s = WindowSegmenter(transport: t)
        s.retryDelay = .zero
        return s
    }
}

private extension Result where Failure == Error {
    var failureError: SegmentationOptionsError? {
        if case .failure(let e) = self { return e as? SegmentationOptionsError }
        return nil
    }
}

#endif
