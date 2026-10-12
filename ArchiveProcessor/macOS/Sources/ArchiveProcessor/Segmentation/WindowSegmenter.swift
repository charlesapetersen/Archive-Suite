import Foundation

// MARK: - The provider-neutral window segmenter (W36.seg-opt-engine)
//
// A port of the bench's window method (`scripts/segbench/method_window.py` `windows`/`combine`/`assemble`,
// `ensemble.py` `judge`, `options.py` `mean_judge`), contract in
// execution-plans/segmentation/04-options-build.md Part 3 §2. It is pure apart from the transport calls and
// writes nothing to disk: its output only proposes the run's boundaries, and the user reviews those before
// anything is written.

/// One page of the run as a voter sees it: the thumbnail (JPEG, long edge at the approach's
/// `thumbnailLongEdgePx`) and the page's OCR text, untruncated (the prompt truncates it as the bench did).
struct PageInput: Sendable {
    let jpeg: Data
    let text: String
}

/// A box or folder label photo, known before segmentation (BoxFolderConfirmSheet). Every gap beside one is a
/// boundary by construction and is never sent to a voter's verdict.
enum PhotoKind: String, Sendable, Codable {
    case box, folder
}

enum GapDecision: String, Sendable, Codable {
    case new
    case `continue`
}

/// The engine's proposal for the gap between page `gap` and page `gap + 1` (0-based page indices).
struct GapProposal: Sendable, Equatable, Codable {
    let gap: Int
    let decision: GapDecision
    /// The approach's confidence that `decision` is right: one voter's `max(p, 1 − p)`; for a mix, the lowest
    /// voter confidence (rule min) or the combined `max(m, 1 − m)` (rule mean). 0 when a voter gave no answer.
    let confidence: Double
    /// Every voter took the same decision (always true for one voter that answered).
    let agreed: Bool
    /// The user must check this gap.
    let flagged: Bool
    /// The models' cues, `decision:cue` per window, joined; for the review sheet.
    let cue: String
    /// Beside a box or folder photo: a boundary by construction, never flagged.
    let fixed: Bool
}

// MARK: - Window layout

enum WindowLayout {
    /// `[start, end)` page-index windows: `pages` long, `stride` apart, the first starting `stride` before the
    /// stream, so with the bench's 7/3 every gap is judged by two windows. `method_window.py` `windows`.
    static func windows(pageCount n: Int, pages: Int, stride: Int) -> [Range<Int>] {
        guard pages >= 2, stride >= 1 else { return [] }
        var out: [Range<Int>] = []
        var s = -stride
        while true {
            let a = max(0, s), b = min(n, s + pages)
            if b - a >= 2, out.last != a..<b { out.append(a..<b) }
            if s + pages >= n + stride { break }
            s += stride
        }
        return out
    }

    /// How many windows contain each gap `i | i+1`.
    static func coverage(pageCount n: Int, pages: Int, stride: Int) -> [Int] {
        var cov = Array(repeating: 0, count: max(0, n - 1))
        for w in windows(pageCount: n, pages: pages, stride: stride) {
            for i in w.lowerBound..<(w.upperBound - 1) { cov[i] += 1 }
        }
        return cov
    }
}

// MARK: - Prompt

enum WindowPromptRenderer {
    /// The prompt for one window. `pageNumbers` are the run's page numbers (1-based), `texts` their OCR text.
    static func render(_ id: WindowPromptID, pageNumbers nums: [Int], texts: [String], maxText: Int) -> String {
        let textBlock = zip(nums, texts).map { "--- page \($0) ---\n\(pageText($1, maxText: maxText))" }
            .joined(separator: "\n")
        let gaps = nums.dropLast().map { "[\($0), \($0 + 1)]" }.joined(separator: ", ")
        var values: [String: String] = ["k": "\(nums.count)", "texts": textBlock, "gaps": gaps,
                                        "max_text": "\(maxText)"]
        switch id {
        case .w1:
            values["files"] = nums.map { "- \(fileName($0))  (page \($0))" }.joined(separator: "\n")
        case .g1:
            values["pages"] = nums.map(String.init).joined(separator: ", ")
        case .c1:
            values["files"] = nums.map { "- \(fileName($0))  (page \($0))" }.joined(separator: "\n")
            values["pages"] = nums.map(String.init).joined(separator: ", ")
        }
        return format(id.template, values)
    }

    /// `method_window.py` `fname`: the file name w1 tells `claude -p` to read.
    static func fileName(_ n: Int) -> String {
        let digits = String(n)
        return "page-\(String(repeating: "0", count: max(0, 4 - digits.count)))\(digits).jpg"
    }

    /// `method_window.py` `page_text`: trimmed, "(no text found)" when empty, cut at `maxText` code points.
    static func pageText(_ raw: String, maxText: Int) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "(no text found)" }
        let scalars = t.unicodeScalars
        guard scalars.count > maxText else { return t }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: scalars.prefix(maxText))
        return String(cut) + " [...]"
    }

    /// Python `str.format` for named fields: `{{` and `}}` are literal braces, `{name}` is replaced. One pass,
    /// so a page text that contains `{k}` is never itself substituted.
    static func format(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if c == "{" || c == "}", next < template.endIndex, template[next] == c {
                out.append(c)
                i = template.index(after: next)
            } else if c == "{", let close = template[next...].firstIndex(of: "}"),
                      let value = values[String(template[next..<close])] {
                out += value
                i = template.index(after: close)
            } else {
                out.append(c)
                i = next
            }
        }
        return out
    }
}

// MARK: - Answer

/// One voter's vote on one gap, from one window.
struct WindowVote: Sendable, Equatable, Codable {
    let decision: GapDecision
    let confidence: Double
    let cue: String
}

/// A window's parsed answer, keyed by the run's page numbers (1-based): each page's kind, and each gap's vote
/// keyed by the page before it.
struct WindowAnswer: Sendable, Equatable, Codable {
    let kinds: [Int: String]
    let votes: [Int: WindowVote]
}

struct WindowParseError: Error, CustomStringConvertible, Equatable {
    let description: String
}

enum WindowAnswerParser {
    private static let kinds: Set<String> = ["box", "folder", "document"]

    /// `method_window.py` `parse_answer`: the first `{` to the last `}`, code fences allowed; one kind per
    /// page and one vote per gap of the window, nothing outside it, confidence in [0, 1].
    static func parse(_ text: String, pageNumbers nums: [Int]) throws -> WindowAnswer {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        guard let i = s.firstIndex(of: "{"), let j = s.lastIndex(of: "}"), i <= j else {
            throw WindowParseError(description: "no JSON object in the reply")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s[i...j].utf8))) as? [String: Any] else {
            throw WindowParseError(description: "bad JSON")
        }
        var kinds: [Int: String] = [:]
        for p in obj["pages"] as? [[String: Any]] ?? [] {
            let k = p["kind"] as? String ?? ""
            guard Self.kinds.contains(k), let n = integer(p["page"]) else {
                throw WindowParseError(description: "page \(p["page"] ?? "?"): kind \(k)")
            }
            kinds[n] = k
        }
        guard kinds.keys.sorted() == nums else {
            throw WindowParseError(description: "pages \(kinds.keys.sorted()) for \(nums)")
        }
        let gaps = Array(nums.dropLast())
        var votes: [Int: WindowVote] = [:]
        for b in obj["boundaries"] as? [[String: Any]] ?? [] {
            let raw = b["between"] as? [Any] ?? []
            let pair = raw.compactMap(integer)
            guard raw.count == 2, pair.count == 2, pair[1] == pair[0] + 1, gaps.contains(pair[0]) else {
                throw WindowParseError(description: "boundary \(pair) not in the window")
            }
            guard let d = GapDecision(rawValue: b["decision"] as? String ?? "") else {
                throw WindowParseError(description: "boundary \(pair[0]): decision")
            }
            guard let c = number(b["confidence"]), c >= 0, c <= 1 else {
                throw WindowParseError(description: "boundary \(pair[0]): confidence")
            }
            let cue = b["cue"].map { "\($0)" } ?? ""
            votes[pair[0]] = WindowVote(decision: d, confidence: c, cue: String(cue.prefix(200)))
        }
        guard votes.keys.sorted() == gaps else {
            throw WindowParseError(description: "boundaries for \(votes.keys.sorted()), wanted \(gaps)")
        }
        return WindowAnswer(kinds: kinds, votes: votes)
    }

    /// Python `int(x)`: an integral number or a numeric string.
    private static func integer(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.rounded(.towardZero) == d ? Int(exactly: d) : Int(d)
        }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Python `float(x)`: a number or a numeric string.
    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

// MARK: - Combining

/// One voter's verdict on one gap, combined over the windows that covered it and answered.
struct VoterGapVerdict: Sendable, Equatable {
    let pNew: Double
    let decision: GapDecision
    let confidence: Double
    let cue: String
}

enum WindowCombiner {
    /// `method_window.py` `combine`, per gap: `P(new)` is the mean of the windows' votes, in window order; the
    /// decision is new at 0.5 or more; the confidence is `max(p, 1 − p)`. `nil` where no window that covered the
    /// gap answered.
    static func voterVerdicts(pageCount n: Int, windows: [Range<Int>],
                              answers: [Range<Int>: WindowAnswer]) -> [VoterGapVerdict?] {
        guard n >= 2 else { return [] }
        var ps = Array(repeating: [Double](), count: n - 1)
        var cues = Array(repeating: [String](), count: n - 1)
        for w in windows {
            guard let a = answers[w] else { continue }
            for x in a.votes.keys.sorted() {
                let v = a.votes[x]!
                let i = x - 1
                guard i >= 0, i < n - 1 else { continue }
                ps[i].append(v.decision == .new ? v.confidence : 1 - v.confidence)
                cues[i].append("\(v.decision.rawValue):\(v.cue)")
            }
        }
        return (0..<(n - 1)).map { i in
            guard !ps[i].isEmpty else { return nil }
            let p = ps[i].reduce(0, +) / Double(ps[i].count)
            return VoterGapVerdict(pNew: p, decision: p >= 0.5 ? .new : .continue,
                                   confidence: max(p, 1 - p),
                                   cue: String(cues[i].joined(separator: " | ").prefix(300)))
        }
    }

    /// The approach's proposal for every gap: fixed beside a label photo, otherwise the voters' verdicts
    /// combined by `rule` and flagged against `level`.
    static func proposals(photoKinds: [PhotoKind?], voters: [[VoterGapVerdict?]],
                          rule: WindowCombineRule, level: Double) -> [GapProposal] {
        let n = photoKinds.count
        guard n >= 2 else { return [] }
        return (0..<(n - 1)).map { i in
            if photoKinds[i] != nil || photoKinds[i + 1] != nil {
                return GapProposal(gap: i, decision: .new, confidence: 1, agreed: true, flagged: false,
                                   cue: "beside a label photo", fixed: true)
            }
            let all = voters.map { i < $0.count ? $0[i] : nil }
            let got = all.compactMap { $0 }
            let cue = got.map(\.cue).joined(separator: " || ")
            guard got.count == all.count, !got.isEmpty else {
                // A voter gave no answer here: never file a guess unseen.
                let d = got.isEmpty ? GapDecision.new : judge(got, rule: rule, level: level).decision
                return GapProposal(gap: i, decision: d, confidence: 0, agreed: false, flagged: true,
                                   cue: cue.isEmpty ? "no answer from the model" : cue, fixed: false)
            }
            let j = judge(got, rule: rule, level: level)
            return GapProposal(gap: i, decision: j.decision, confidence: j.confidence, agreed: j.agreed,
                               flagged: j.flagged, cue: cue, fixed: false)
        }
    }

    struct Judgement: Equatable {
        let decision: GapDecision
        let flagged: Bool
        let confidence: Double
        let agreed: Bool
    }

    /// One document gap, the voters in the approach's order.
    static func judge(_ js: [VoterGapVerdict], rule: WindowCombineRule, level: Double) -> Judgement {
        let agreed = Set(js.map(\.decision)).count == 1
        switch rule {
        case .min:
            // ensemble.py judge: majority; a tie to the FIRST most confident voter (Python max keeps the first).
            let lo = js.map(\.confidence).min() ?? 0
            let nNew = js.filter { $0.decision == .new }.count
            let decision: GapDecision
            if nNew * 2 != js.count {
                decision = nNew * 2 > js.count ? .new : .continue
            } else {
                var best = js[0]
                for v in js.dropFirst() where v.confidence > best.confidence { best = v }
                decision = best.decision
            }
            return Judgement(decision: decision, flagged: !(agreed && lo > level), confidence: lo, agreed: agreed)
        case .mean:
            // options.py mean_judge.
            let ps = js.map { $0.decision == .new ? $0.confidence : 1 - $0.confidence }
            let m = ps.reduce(0, +) / Double(ps.count)
            let conf = max(m, 1 - m)
            return Judgement(decision: m >= 0.5 ? .new : .continue, flagged: !(conf > level),
                             confidence: conf, agreed: agreed)
        }
    }
}

// MARK: - Transport

/// One window for one voter, ready to send: the rendered prompt and the page thumbnails in order.
struct WindowRequest: Sendable {
    let voter: WindowVoter
    let prompt: String
    let images: [Data]
    /// The run's page numbers (1-based) of the window's pages, for labelling the images.
    let pageNumbers: [Int]
}

enum WindowTransportError: Error, Equatable {
    /// The provider's usage window or rate limit: stop the run, keep what was answered.
    case usageLimit(reset: Date?, message: String)
    /// The Claude plan route stopped the run itself (`PlanRunGate`): the five-hour meter at 90%, or the user chose
    /// not to go on after the first measurement. Handled as a usage limit, with its own message.
    case paused(reset: Date?, message: String)
    /// Anything else; the window is retried once, after a pause.
    case failed(String)
    /// No window can succeed (no key, a key refused, an unknown model, the CLI missing or signed out): stop the
    /// run and say why, rather than returning every gap flagged at 0.
    case fatal(String)
}

/// Sends one window to its voter's model and returns the reply text. The engine owns parsing and retries.
protocol WindowTransport: Sendable {
    func send(_ request: WindowRequest) async throws -> String
}

// MARK: - The engine

/// A window of one voter: what is cached across a usage-limit stop so a resumed run does not ask again.
struct WindowKey: Hashable, Sendable, Codable {
    let voter: String
    /// The run's page count: an answer kept from a run with other pages never lands on these.
    let pages: Int
    let start: Int
    let end: Int
}

struct WindowSegmentation: Sendable {
    /// One per gap, `proposals[i].gap == i`.
    let proposals: [GapProposal]
    /// Every window answered, including those passed in.
    let answered: [WindowKey: WindowAnswer]
    /// Windows that failed twice; the gaps only they covered are flagged with confidence 0.
    let failed: [WindowKey]
}

enum WindowSegmenterError: Error {
    /// A voter hit its usage limit. `answered` holds every window answered so far; pass it back as
    /// `answered:` to resume without asking again.
    case usageLimit(reset: Date?, message: String, answered: [WindowKey: WindowAnswer])
    /// The plan route paused the run (`WindowTransportError.paused`); resumable as a usage limit is.
    case paused(reset: Date?, message: String, answered: [WindowKey: WindowAnswer])
    /// A transport cannot work at all (see `WindowTransportError.fatal`).
    case fatal(message: String, answered: [WindowKey: WindowAnswer])
    case pageCountMismatch(pages: Int, photoKinds: Int)
}

struct WindowSegmenter: Sendable {
    let transport: any WindowTransport
    /// Windows in flight at once, per run (the bench ran three Claude and four Gemini calls at a time).
    var maxConcurrent: Int = 3
    /// The pause before a failed window's one retry, so a burst of 5xx or overload does not fail both tries.
    /// The API route's `NetworkSession` call is non-idempotent and does not retry 5xx itself.
    var retryDelay: Duration = .seconds(20)

    func segment(pages: [PageInput], photoKinds: [PhotoKind?], approach: ApproachSpec,
                 answered prior: [WindowKey: WindowAnswer] = [:]) async throws -> WindowSegmentation {
        guard pages.count == photoKinds.count else {
            throw WindowSegmenterError.pageCountMismatch(pages: pages.count, photoKinds: photoKinds.count)
        }
        let n = pages.count
        let windows = WindowLayout.windows(pageCount: n, pages: approach.windowPages, stride: approach.windowStride)
        var answered = prior
        var failed: [WindowKey] = []

        // Every (voter, window) not already answered, voters in approach order, windows in stream order.
        var jobs: [(WindowVoter, Range<Int>)] = []
        for v in approach.voters {
            for w in windows where answered[key(v, w, n)] == nil { jobs.append((v, w)) }
        }

        var limit: (Date?, String)?
        var pause: (Date?, String)?
        var fatal: String?
        let retryDelay = self.retryDelay
        try await withThrowingTaskGroup(of: (WindowKey, Result<WindowAnswer, Error>).self) { group in
            var next = 0
            func launch() {
                guard next < jobs.count else { return }
                let (v, w) = jobs[next]
                next += 1
                let request = makeRequest(voter: v, window: w, pages: pages, approach: approach)
                let transport = self.transport
                group.addTask {
                    (key(v, w, n), await Self.ask(transport, request, retryDelay: retryDelay))
                }
            }
            for _ in 0..<max(1, maxConcurrent) { launch() }
            while let (k, result) = try await group.next() {
                switch result {
                case .success(let a):
                    answered[k] = a
                case .failure(WindowTransportError.usageLimit(let reset, let message)):
                    if limit == nil { limit = (reset, message) }
                case .failure(WindowTransportError.paused(let reset, let message)):
                    if pause == nil { pause = (reset, message) }
                case .failure(WindowTransportError.fatal(let message)):
                    if fatal == nil { fatal = message }
                case .failure(let e as CancellationError):
                    throw e
                case .failure:
                    failed.append(k)
                }
                if limit == nil && pause == nil && fatal == nil { launch() }
            }
        }
        if let fatal {
            throw WindowSegmenterError.fatal(message: fatal, answered: answered)
        }
        if let (reset, message) = limit {
            throw WindowSegmenterError.usageLimit(reset: reset, message: message, answered: answered)
        }
        if let (reset, message) = pause {
            throw WindowSegmenterError.paused(reset: reset, message: message, answered: answered)
        }
        try Task.checkCancellation()

        let verdicts = approach.voters.map { v in
            WindowCombiner.voterVerdicts(
                pageCount: n, windows: windows,
                answers: Dictionary(uniqueKeysWithValues: windows.compactMap { w in
                    answered[key(v, w, n)].map { (w, $0) }
                }))
        }
        let proposals = WindowCombiner.proposals(photoKinds: photoKinds, voters: verdicts,
                                                 rule: approach.rule, level: approach.level)
        return WindowSegmentation(proposals: proposals, answered: answered,
                                  failed: failed.sorted { ($0.voter, $0.start) < ($1.voter, $1.start) })
    }

    private func key(_ v: WindowVoter, _ w: Range<Int>, _ n: Int) -> WindowKey {
        WindowKey(voter: v.name, pages: n, start: w.lowerBound, end: w.upperBound)
    }

    private func makeRequest(voter: WindowVoter, window w: Range<Int>, pages: [PageInput],
                             approach: ApproachSpec) -> WindowRequest {
        let nums = w.map { $0 + 1 }
        let prompt = WindowPromptRenderer.render(voter.prompt, pageNumbers: nums, texts: w.map { pages[$0].text },
                                                 maxText: approach.ocrTextChars)
        return WindowRequest(voter: voter, prompt: prompt, images: w.map { pages[$0].jpeg }, pageNumbers: nums)
    }

    /// One window: a failure or an unparseable answer is retried once, after `retryDelay`; a usage limit or a
    /// fatal error is not.
    private static func ask(_ transport: any WindowTransport, _ r: WindowRequest,
                            retryDelay: Duration) async -> Result<WindowAnswer, Error> {
        var last: Error = WindowTransportError.failed("not sent")
        for attempt in 0..<2 {
            if attempt > 0, retryDelay > .zero {
                do { try await Task.sleep(for: retryDelay) } catch { return .failure(CancellationError()) }
            }
            if Task.isCancelled { return .failure(CancellationError()) }
            do {
                let text = try await transport.send(r)
                return .success(try WindowAnswerParser.parse(text, pageNumbers: r.pageNumbers))
            } catch let e as WindowTransportError {
                switch e {
                case .usageLimit, .paused, .fatal: return .failure(e)
                case .failed: last = e
                }
            } catch is CancellationError {
                return .failure(CancellationError())
            } catch {
                last = error
            }
        }
        return .failure(last)
    }
}
