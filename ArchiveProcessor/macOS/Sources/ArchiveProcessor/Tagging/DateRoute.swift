import Foundation

/// W46.date-route — the dating route of `13-stage-rules/08-dating.md` §3, as `segbench/date_route_pipeline.py` measured
/// it (`segbench-results/date-route-pipeline.md`), one dedicated call after the tagging call:
///
///   1. *explicit, from the text*: the trace prompt with the neighbours' dates on the app's own text; the year is
///      explicit when a rule candidate in the document's own text carries it, no `Date Uncertain`;
///   2. *explicit, from the image*: only where the own text has no year candidate (call 7.3), the image pass on the first
///      two pages; its document date counts when that year is written in a date it quoted;
///   3. *inherited*: an established enclosure takes its cover's year with `Date Uncertain` when it has no explicit date
///      of its own (applied by `OCRProcessor.applyGeneratedTags`, beside `Sent With`); the dated folder is
///      `W47.ct-folder-date`'s;
///   4. *estimated from neighbours*: the same trace reply, written only when its evidence passes `evidenceCheck`, always
///      with `Date Uncertain`; a reply whose evidence fails writes no year and is not shown (owner call 9).
///
/// `Date Uncertain` is set by the step. The one use of the model's own flag (owner, 2026-11-12,
/// `W46.date-route-owner-ok` (a)): it may ADD `Date Uncertain` to a year step 1 made explicit, never remove it, the year
/// kept. Everything here mirrors the bench byte for byte (`date_traceable.candidates`, `rule_pick`, `TRACE` "neigh",
/// `parse_trace`, `context_of`; `date_scorers.evidence_check`; `date_image.PROMPT`, `read`; `date_undated.own_date`;
/// `date_route_pipeline.route`), checked by `DateRouteTestDriver` on cases the bench writes
/// (`segbench/date_route_cases.py`).
enum DateRoute {
    /// What the app sends of a document (`date_traceable.TEXT_CHARS`), of each neighbour (`NEAR_CHARS`), and how many
    /// pages of each are read (`date_undated.DOC_PAGES`, `NEAR_PAGES`); neighbours each side (`NEAR`).
    static let textChars = 3000
    static let nearChars = 600
    static let docPages = 4
    static let nearPages = 2
    static let nearCount = 3
    /// The years a rule candidate or a reply may carry (`date_traceable.LO`, `HI`).
    static let yearRange = 1800...2030
    /// The pages the image pass sends and their long side (`date_image.PAGES`, `LONG_SIDE`).
    static let imagePages = 2
    static let imageLongSide = 2400
    /// The measured route on a remote gateway (W46.date-route-pipeline): Gemini 3.7 Flash, temperature 0, reasoning
    /// low, 4,096 tokens (3.7 reasons first).
    static let gatewayModel = "gemini-3.7-flash"
    static let maxTokens = 4096
    static let timeout: TimeInterval = 120

    // MARK: Python-compatible text helpers

    /// `s[:n]` in Python: the first `n` code points.
    static func scalarPrefix(_ s: String, _ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.unicodeScalars.prefix(n))
        return String(v)
    }

    /// Python's `str.splitlines()`: every line boundary it knows, `\r\n` as one, no trailing empty line.
    static func splitLines(_ s: String) -> [String] {
        let breaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]
        var lines: [String] = []
        var cur = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if breaks.contains(c.value) {
                lines.append(String(cur))
                cur = String.UnicodeScalarView()
                if c.value == 0x0D, i + 1 < scalars.count, scalars[i + 1].value == 0x0A { i += 1 }
            } else {
                cur.append(c)
            }
            i += 1
        }
        if !cur.isEmpty { lines.append(String(cur)) }
        return lines
    }

    /// Python's `str.strip()` (whitespace by Unicode's definition).
    static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rx(_ pattern: String, _ caseless: Bool = false) -> NSRegularExpression {
        // The patterns are literals; a bad one is a programming error the test driver reports at once.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : [])
    }

    private static func matches(_ r: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        r.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    // MARK: Stage 1, rule candidates (date_traceable.candidates, rule_pick)

    struct Candidate: Equatable, Sendable {
        let year: Int
        let month: Int?
        let kind: String
        let lineNo: Int
        let line: String
        let pos: Int
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                 "october", "november", "december"]
    private static let mon = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#
    private static let y = #"(1[89]\d\d|20[0-3]\d)"#
    private static let forms: [(String, NSRegularExpression)] = [
        ("full", rx(#"\b"# + mon + #"\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*"# + y + #"\b"#, true)),
        ("full", rx(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + mon + #",?\s*"# + y + #"\b"#, true)),
        ("numeric", rx(#"\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})\b"#)),
        ("month", rx(#"\b"# + mon + #",?\s+"# + y + #"\b"#, true)),
        ("year", rx(#"\b"# + y + #"\b"#)),
    ]
    private static let weight = ["full": 3, "numeric": 2, "month": 2, "year": 1]

    private static func monthOf(_ word: String) -> Int? {
        var w = word.lowercased()
        while w.hasSuffix(".") { w.removeLast() }
        let head = String(w.prefix(3))
        return months.firstIndex { $0.hasPrefix(head) }.map { $0 + 1 }
    }

    /// Every date printed in the first `limit` characters, in text order. A two-digit numeric year is read as 19YY;
    /// years outside 1800-2030 are dropped.
    static func candidates(_ text: String, limit: Int = textChars) -> [Candidate] {
        var out: [Candidate] = []
        for (n, line) in splitLines(scalarPrefix(text, limit)).enumerated() {
            var taken: [(Int, Int)] = []
            for (kind, r) in forms {
                for m in matches(r, line) {
                    let a0 = m.range.location, b0 = m.range.location + m.range.length
                    if taken.contains(where: { a0 < $0.1 && $0.0 < b0 }) { continue }
                    let g = (1..<m.numberOfRanges).map { group(m, $0, in: line) }
                    var month: Int? = nil
                    let year: Int
                    switch kind {
                    case "full":
                        let day: Int
                        if let d = Int(g[0]) {
                            guard let mo = monthOf(g[1]), let yy = Int(g[2]) else { continue }
                            day = d; month = mo; year = yy
                        } else {
                            guard let d = Int(g[1]), let yy = Int(g[2]) else { continue }
                            month = monthOf(g[0]); day = d; year = yy
                        }
                        if !(1...31).contains(day) { continue }
                    case "numeric":
                        guard let a = Int(g[0]), let b = Int(g[1]), let yv = Int(g[2]) else { continue }
                        year = g[2].unicodeScalars.count == 4 ? yv : 1900 + yv
                        if !((1...12).contains(a) && (1...31).contains(b) || (1...12).contains(b) && (1...31).contains(a)) {
                            continue
                        }
                        month = (1...12).contains(a) ? a : b
                    case "month":
                        guard let yy = Int(g[1]) else { continue }
                        month = monthOf(g[0]); year = yy
                    default:
                        guard let yy = Int(g[0]) else { continue }
                        year = yy
                    }
                    if !yearRange.contains(year) { continue }
                    taken.append((a0, b0))
                    out.append(Candidate(year: year, month: month, kind: kind, lineNo: n,
                                         line: scalarPrefix(strip(line), 200), pos: a0))
                }
            }
        }
        // Python's sort is stable; so is this one, by index.
        return out.enumerated().sorted { l, r in
            (l.element.lineNo, l.element.pos, l.offset) < (r.element.lineNo, r.element.pos, r.offset)
        }.map(\.element)
    }

    /// The rule's pick: the first dated form in the first 15 lines, else the year with the highest weighted count
    /// (earliest on a tie, its dated form if any). `nil` with no candidate.
    static func rulePick(_ cands: [Candidate], headLines: Int = 15) -> Candidate? {
        guard !cands.isEmpty else { return nil }
        let dated = cands.filter { $0.kind != "year" }
        if let first = dated.first(where: { $0.lineNo < headLines }) { return first }
        var w: [Int: Int] = [:]
        for c in cands { w[c.year, default: 0] += weight[c.kind] ?? 0 }
        let top = w.values.max() ?? 0
        guard let best = cands.first(where: { w[$0.year] == top }) else { return nil }
        return cands.first { $0.year == best.year && $0.kind != "year" } ?? best
    }

    /// `rule_pick`'s month: only from a dated form.
    static func pickMonth(_ c: Candidate?) -> Int? {
        guard let c, c.kind != "year" else { return nil }
        return c.month
    }

    // MARK: The trace prompt ("neigh")

    struct Neighbour: Equatable, Sendable {
        /// P1 is the document just before, N1 just after.
        let label: String
        let dist: Int
        /// Its first `nearPages` pages, joined as `DocumentSegment.combinedText` joins them.
        let text: String
        /// The output file name of its first page: what the sidecar names as the evidence's source.
        let file: String?
        var pick: Candidate? { DateRoute.rulePick(DateRoute.candidates(text)) }
    }

    /// Up to three documents either side of segment `i`, box and folder labels skipped (`date_route_pipeline.neighbours`).
    static func neighbours(of i: Int, in segments: [DocumentSegment], file: (DocumentSegment) -> String?) -> [Neighbour] {
        func isDoc(_ s: DocumentSegment) -> Bool { !s.isBox && !s.isFolder }
        let before = Array(stride(from: i - 1, through: 0, by: -1).lazy.filter { isDoc(segments[$0]) }.prefix(nearCount))
        let after = Array((i + 1..<max(i + 1, segments.count)).lazy.filter { isDoc(segments[$0]) }.prefix(nearCount))
        func text(_ s: DocumentSegment) -> String { s.texts.prefix(nearPages).joined(separator: "\n\n") }
        return before.enumerated().map { Neighbour(label: "P\($0.offset + 1)", dist: $0.offset + 1,
                                                   text: text(segments[$0.element]), file: file(segments[$0.element])) }
            + after.enumerated().map { Neighbour(label: "N\($0.offset + 1)", dist: -($0.offset + 1),
                                                 text: text(segments[$0.element]), file: file(segments[$0.element])) }
    }

    /// The document's own text as the route reads it: its first `docPages` pages.
    static func ownText(_ segment: DocumentSegment) -> String {
        segment.texts.prefix(docPages).joined(separator: "\n\n")
    }

    /// `date_traceable.TRACE`, byte for byte.
    static let traceTemplate = """
    You are dating a document from a historical archive for a scholar who will check your evidence.

    The document's OCR text (id "self"):
    ---
    {text}
    ---

    Nearby documents from the same folder, in folder order (P1 is just before this document, N1 just after), each headed by its id:
    {near}
    {extra}
    Give the year this document was written.
    - If the document prints its own date, use that year and quote the date from "self".
    - Otherwise estimate it from the nearby documents: quote the nearby text that carries the year and give that document's id.
    - Give an interval lo to hi that you are 90% sure contains the year (lo = hi when the document prints its date).
    - date_uncertain is true when this document does not print its own year.
    - A quote must be copied exactly from the document you cite and must contain the year. If nothing supports any year, give "year": null.

    Respond with ONLY a JSON object, for example:
    {"year": 1947, "lo": 1946, "hi": 1948, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "March 3, 1947"}}
    """

    private static func ordered(_ near: [Neighbour]) -> [Neighbour] {
        near.enumerated().sorted { (-$0.element.dist, $0.offset) < (-$1.element.dist, $1.offset) }.map(\.element)
    }

    static func tracePrompt(text: String, near: [Neighbour]) -> String {
        let block = near.isEmpty ? "(none)\n"
            : ordered(near).map { "[\($0.label)]\n\(scalarPrefix($0.text, nearChars))\n---\n" }.joined()
        let lines = ordered(near).compactMap { n -> String? in
            guard let p = n.pick else { return nil }
            return "[\(n.label)] \(p.year) (\"\(p.line)\")"
        }
        let extra = "\nDates a rule found printed in the nearby documents (id, year, the line):\n"
            + (lines.isEmpty ? "(none found)" : lines.joined(separator: "\n")) + "\n"
        // One pass over the template, so text that happens to contain "{near}" is never substituted again.
        var out = ""
        var rest = Substring(traceTemplate)
        let slots = ["{text}": scalarPrefix(text, textChars), "{near}": block, "{extra}": extra]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            if let (key, value) = slots.first(where: { rest[open...].hasPrefix($0.key) }) {
                out += value
                rest = rest[rest.index(open, offsetBy: key.count)...]
            } else {
                out.append("{")
                rest = rest[rest.index(after: open)...]
            }
        }
        return out + rest
    }

    /// What the trace prompt gave the model, by the ids it may cite (`context_of(doc, "neigh")`).
    static func context(text: String, near: [Neighbour]) -> [String: String] {
        var ctx = ["self": scalarPrefix(text, textChars)]
        for n in near {
            ctx[n.label] = scalarPrefix(n.text, nearChars) + (n.pick.map { "\n" + $0.line } ?? "")
        }
        return ctx
    }

    // MARK: The trace reply (parse_trace)

    struct Trace: Equatable, Sendable {
        var parsed = false
        var year: Int? = nil
        var lo: Int? = nil
        var hi: Int? = nil
        /// The model's own flag: `date_uncertain is not False` (missing reads as true).
        var uncertain = true
        /// `{"neighbour": id, "quote": …}` or `{"region": …}`, as given; nil when the reply cites nothing.
        var evidence: [String: String]? = nil
    }

    /// `date_tagging.strip_reasoning`: every closed `<think>` block, then text up to a stray `</think>`.
    static func stripReasoning(_ raw: String) -> String {
        var s = raw
        while let i = s.range(of: "<think>"), let j = s.range(of: "</think>", range: i.lowerBound..<s.endIndex) {
            s.removeSubrange(i.lowerBound..<j.upperBound)
        }
        if s.range(of: "<think>") == nil, let j = s.range(of: "</think>") { s = String(s[j.upperBound...]) }
        return strip(s)
    }

    static func replyJSON(_ raw: String?) -> [String: Any]? {
        var s = strip(stripReasoning(raw ?? ""))
        if s.hasPrefix("```") {
            let parts = s.components(separatedBy: "\n")
            s = parts.count > 2 ? parts[1..<(parts.count - 1)].joined(separator: "\n") : ""
        }
        guard let i = s.firstIndex(of: "{"), let j = s.lastIndex(of: "}"), i <= j,
              let data = String(s[i...j]).data(using: .utf8),
              let js = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return js
    }

    private static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// `date_traceable._int`: a number (truncated) or a four-digit string; never a boolean.
    static func intValue(_ v: Any?) -> Int? {
        if v == nil || v is NSNull || isBool(v) { return nil }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d.isFinite && abs(d) < 1e15 ? Int(d) : nil
        }
        if let s = v as? String {
            let t = strip(s)
            if t.unicodeScalars.count == 4, t.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) { return Int(t) }
        }
        return nil
    }

    private static let shortKey = rx(#"^(?:self|[PN]\d)$"#)

    static func parseTrace(_ raw: String?) -> Trace {
        guard let js = replyJSON(raw) else { return Trace() }
        var t = Trace(parsed: true)
        var yv = intValue(js["year"])
        if let v = yv, !yearRange.contains(v) { yv = nil }
        t.year = yv
        var lo = intValue(js["lo"]), hi = intValue(js["hi"])
        if let v = yv, lo == nil || hi == nil || !(lo! <= v && v <= hi!) { lo = v; hi = v }
        if yv == nil { lo = nil; hi = nil }
        t.lo = lo; t.hi = hi
        t.uncertain = !(isBool(js["date_uncertain"]) && (js["date_uncertain"] as? Bool) == false)
        if let ev = js["evidence"] as? [String: Any] {
            if ev["quote"] == nil, ev.count == 1, let (k, v) = ev.first, let q = v as? String,
               !matches(shortKey, k).isEmpty {
                t.evidence = ["neighbour": k, "quote": q]   // {"P1": "May 2, 1947"}: the same citation, shortened
            } else {
                // Every key, as a string; a JSON null reads as "" (the checker then finds no quote or no such id).
                var e: [String: String] = [:]
                for (k, v) in ev { e[k] = v is NSNull ? "" : str(v) }
                t.evidence = e.isEmpty ? nil : e
            }
        }
        return t
    }

    // MARK: The evidence check (date_scorers.evidence_check)

    private static let ws = rx(#"\s+"#)

    private static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    static func norm(_ s: String) -> String { replace(ws, in: s, with: "").lowercased() }

    static func normText(_ s: String) -> String {
        String(String.UnicodeScalarView(norm(s).unicodeScalars.filter {
            ![0x2D, 0xAD, 0x2010, 0x2011].contains($0.value)
        }))
    }

    private static let elision = rx(#"\.\.\.|…"#)

    static func quoteIn(_ quote: String, _ text: String) -> Bool {
        let t = Array(normText(text).unicodeScalars)
        var at = 0
        let ns = quote as NSString
        var pieces: [String] = []
        var last = 0
        for m in matches(elision, quote) {
            pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: last))
        for part in pieces.map(normText).filter({ !$0.isEmpty }) {
            let p = Array(part.unicodeScalars)
            guard let hit = find(p, in: t, from: at) else { return false }
            at = hit + p.count
        }
        return true
    }

    private static func find(_ p: [Unicode.Scalar], in t: [Unicode.Scalar], from: Int) -> Int? {
        guard !p.isEmpty else { return from <= t.count ? from : nil }
        guard p.count <= t.count else { return nil }
        var i = from
        while i + p.count <= t.count {
            if t[i] == p[0], Array(t[i..<(i + p.count)]) == p { return i }
            i += 1
        }
        return nil
    }

    /// Letters OCR puts for a digit, after lowercasing (`date_scorers.OCR_DIGIT`).
    private static let ocrDigit: [Character: String] = ["0": "o", "1": "il|!]", "2": "z", "5": "s$", "6": "gb", "8": "b",
                                                        "9": "gq"]
    private static let monthRx = #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|"#
        + #"oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?"#
    private static let monthNotMay = monthRx.replacingOccurrences(of: "may|", with: "")
    private static let yyEnd = #"(?! ?\d|[\d'’]|s\b)"#

    /// Python's `str.isdigit` on one code point: a decimal or other digit.
    private static func isDigit(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let t = c.unicodeScalars.first?.properties.numericType else { return false }
        return t == .decimal || t == .digit
    }

    static func damaged(_ ys: String, _ s: String) -> Bool {
        let a = Array(s.unicodeScalars).map(Character.init), y = Array(ys)
        guard a.count >= 4 else { return false }
        for i in 0..<(a.count - 3) {
            if (i > 0 && isDigit(a[i - 1])) || (i + 4 < a.count && isDigit(a[i + 4])) { continue }
            let w = Array(a[i..<(i + 4)])
            let subs = (0..<4).filter { w[$0] != y[$0] }
            if !subs.isEmpty, subs.allSatisfy({ (ocrDigit[y[$0]] ?? "").contains(w[$0]) }),
               subs.count == 1 || (subs.count == 2 && w[0] == y[0] && w[1] == y[1]) {
                return true
            }
        }
        return false
    }

    /// How a quote carries the year: "four digits", "two digits" (inside a date form), "ocr damage", or nil.
    static func yearInQuote(_ year: Int, _ quote: String) -> String? {
        let ys = String(year), s = norm(quote)
        if s.contains(ys) { return "four digits" }
        let q = replace(ws, in: quote, with: " ").lowercased()
        let yy = String(ys.suffix(2)), y2 = String(ys.prefix(2))
        var forms = [#"(?<!\d)\d{1,2} ?[/.-] ?\d{1,2} ?[/.-] ?'?"# + yy + yyEnd,
                     #"(?<!\d)\d{1,2}(?:st|nd|rd|th)? ?"# + monthRx + #",? ?['’]?"# + yy + yyEnd,
                     monthRx + #" ?\d{1,2}(?:st|nd|rd|th)?, ?['’]?"# + yy + yyEnd,
                     #"(?<![\d'’])['’‘]"# + yy + yyEnd,
                     #"(?<!\d)"# + y2 + #"\d\d ?[-–/] ?"# + yy + yyEnd]
        if (Int(yy) ?? 0) > 31 { forms.append(monthNotMay + #",? ?"# + yy + yyEnd) }
        if forms.contains(where: { !matches(rx($0), q).isEmpty }) { return "two digits" }
        if damaged(ys, s) { return "ocr damage" }
        return nil
    }

    private static let dateRx = rx(#"\b(1[5-9]\d\d|20\d\d)\b|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|"#
                                   + #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.? \d{1,2}\b"#, true)

    struct Check: Equatable, Sendable {
        /// "valid", "unsupported" or "none".
        let verdict: String
        let reason: String
    }

    static func evidenceCheck(year: Int?, evidence: [String: String]?, context: [String: String]) -> Check {
        guard let evidence, !evidence.isEmpty else { return Check(verdict: "none", reason: "no evidence cited") }
        guard let year else { return Check(verdict: "unsupported", reason: "no year to support") }
        if let reg = evidence["region"], evidence["quote"] == nil {
            let how = yearInQuote(year, reg)
            if matches(dateRx, reg).isEmpty && how == nil {
                return Check(verdict: "unsupported", reason: "cited region has no date string")
            }
            guard let how else { return Check(verdict: "unsupported", reason: "cited region's date is not the year given") }
            return Check(verdict: "valid", reason: "cited region carries the year" + (how == "four digits" ? "" : " (\(how))"))
        }
        let nb = evidence["neighbour"] ?? "self"
        guard let cited = context[nb] else {
            return Check(verdict: "unsupported", reason: "cited document is not in the context given")
        }
        let quote = evidence["quote"] ?? ""
        if strip(quote).isEmpty { return Check(verdict: "unsupported", reason: "no quote") }
        if !quoteIn(quote, cited) {
            return Check(verdict: "unsupported", reason: "quote is not in the cited document's text")
        }
        guard let how = yearInQuote(year, quote) else {
            return Check(verdict: "unsupported", reason: "quote does not carry the year given")
        }
        return Check(verdict: "valid", reason: "quote found in the cited document and carries the year"
                     + (how == "four digits" ? "" : " (\(how))"))
    }

    // MARK: The image pass (date_image.PROMPT, read; date_undated.own_date)

    /// `date_image.PROMPT`, byte for byte.
    static let imagePrompt = "These are the first pages of one archival document, in order (page 1, then page 2 if given). Find every date "
        + "written on them: full dates, a month and year, or a year alone, wherever it is (letterhead, dateline, body, "
        + "signature, stamp, handwriting in a margin). Copy each exactly as it appears, and say where it is. Then give the "
        + "date the document itself was written or sent, if the pages show it; a date merely mentioned in the text is not it.\n"
        + "Respond with ONLY a JSON object:\n"
        + #"{"dates": [{"quote": "<exactly as on the page>", "page": 1, "where": "letterhead|dateline|body|signature|stamp|"#
        + #"margin|other", "kind": "printed|typed|handwritten|stamped", "year": 1968, "month": 3}], "#
        + #""document_date": {"year": 1968, "month": 3, "quote": "<the quote it comes from>"}}"# + "\n"
        + "Use null for an unknown month or year, and \"document_date\": null if the pages do not show the document's own date."

    struct PageDate: Equatable, Sendable {
        let quote: String
        let page: Int?
        let place: String
        let kind: String
        let year: Int?
        /// The year is written in the quote (a year the model supplied from elsewhere is not).
        let written: Bool
    }

    struct ImageReading: Equatable, Sendable {
        var ok = false
        var docYear: Int? = nil
        var docMonth: Int? = nil
        var docQuote = ""
        var dates: [PageDate] = []

        /// The document's own year when the reply gives one AND it is written in one of the dates it quoted.
        var ownYear: Int? {
            guard let y = docYear, dates.contains(where: { $0.written && $0.year == y }) else { return nil }
            return y
        }

        /// The quoted date the own year rests on: the document date's quote when it is among them, else the first
        /// written date of that year.
        var ownEvidence: PageDate? {
            guard let y = ownYear else { return nil }
            let mine = dates.filter { $0.written && $0.year == y }
            return mine.first { DateRoute.strip($0.quote) == DateRoute.strip(docQuote) } ?? mine.first
        }

        /// Second-role dates for the sidecar (owner call 9): received stamps, postmarks and other stamped dates, each
        /// with its quote and place, never a second bare year. The bench counts them so (`date_route_pipeline`).
        var secondRole: [PageDate] {
            dates.filter { $0.written && ($0.place == "stamp" || $0.kind == "stamped") }
        }
    }

    private static let fence = rx(#"```(?:json)?"#)
    private static let braces = rx(#"\{.*\}"#)
    private static let anyYear = rx(#"(?<![0-9])(1[89][0-9][0-9]|20[0-3][0-9])(?![0-9])"#)
    private static let numericYY = rx(#"(?<![0-9])[0-9]{1,2}[/.-][0-9]{1,2}[/.-]([0-9]{2})(?![0-9])"#)

    /// `date_image._year`: the first four characters of the value as Python's `str()` writes it, 1500-2030.
    static func imageYear(_ v: Any?) -> Int? {
        guard let v, !(v is NSNull), !isBool(v) else { return nil }
        let s: String
        if let n = v as? NSNumber {
            let d = n.doubleValue
            s = d == d.rounded() && abs(d) < 1e15 && !"\(n)".contains(".") ? String(Int(d)) : "\(d)"
        } else if let t = v as? String {
            s = t
        } else {
            return nil
        }
        let head = strip(scalarPrefix(s, 4))
        guard let y = Int(head), head.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "-" || $0 == "+" })
        else { return nil }
        return (1500...2030).contains(y) ? y : nil
    }

    /// `date_image.quoted_year`.
    static func quotedYear(_ quote: String) -> Int? {
        if let m = matches(anyYear, quote).first { return Int(group(m, 1, in: quote)) }
        if let m = matches(numericYY, quote).first, let yy = Int(group(m, 1, in: quote)) { return 1900 + yy }
        return nil
    }

    /// `date_image.year_in_quote` (not the checker's): the year in full, or as '58 / 58.
    static func imageYearInQuote(_ year: Int, _ quote: String) -> Bool {
        let ys = String(year)
        if quote.contains(ys) { return true }
        return !matches(rx(#"(?<![0-9])'?"# + String(ys.suffix(2)) + #"(?![0-9])"#), quote).isEmpty
    }

    /// Python's `str(v or "")`: every falsy JSON value (null, false, 0, "", [], {}) reads as "".
    private static func str(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if let n = v as? NSNumber, n.doubleValue == 0 { return "" }
        if let a = v as? [Any], a.isEmpty { return "" }
        if let o = v as? [String: Any], o.isEmpty { return "" }
        if let s = v as? String { return s }
        if isBool(v) { return (v as? Bool) == true ? "True" : "False" }
        return "\(v)"
    }

    static func readImage(_ raw: String?) -> ImageReading {
        let s = replace(fence, in: raw ?? "", with: "")
        let dotAll = try? NSRegularExpression(pattern: #"\{.*\}"#, options: [.dotMatchesLineSeparators])
        guard let m = (dotAll ?? braces).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s), let data = String(s[r]).data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ImageReading() }
        var out = ImageReading(ok: true)
        for x in (d["dates"] as? [Any]) ?? [] {
            guard let x = x as? [String: Any] else { continue }
            let quote = str(x["quote"])
            let yv = imageYear(x["year"]) ?? quotedYear(quote)
            let place = str(x["where"]).isEmpty ? "other" : str(x["where"])
            let kind = str(x["kind"]).isEmpty ? "?" : str(x["kind"])
            out.dates.append(PageDate(quote: quote, page: intValue(x["page"]), place: place, kind: kind, year: yv,
                                      written: yv.map { imageYearInQuote($0, quote) } ?? false))
        }
        if let dd = d["document_date"] as? [String: Any] {
            out.docYear = imageYear(dd["year"])
            if let mo = intValue(dd["month"]), (1...12).contains(mo) { out.docMonth = mo }
            out.docQuote = str(dd["quote"])
        }
        return out
    }

    // MARK: The decision (date_route_pipeline.route)

    enum EvidenceClass: String, Sendable, Codable {
        case text, image, estimate, inherited, none
    }

    struct Decision: Equatable, Sendable {
        var year: Int?
        var month: Int?
        var dateUncertain: Bool
        var evidenceClass: EvidenceClass
        var step: Int?
        var trace: Trace
        var check: Check
        /// The id the reply cited ("self", "P1", …) when it cited one.
        var cited: String?
        /// The quote the year rests on and where it is: for the text, its line; for an estimate, the neighbour's file.
        var quote: String?
        var line: Int?
        var sourceFile: String?
        var page: Int?
        var place: String?
        /// Owner call (a): the model's own flag added `Date Uncertain` to an explicit text year.
        var modelFlagAdded = false
        var image: ImageReading?
        var imageNote: String
        /// The route that answered the trace call, and whether it is the measured one (the interval is shown only then).
        var route = ""
        var measured = false
    }

    /// One document's route. `traceRaw` is nil when the call failed; `image` nil when the pass was not sent.
    static func decide(text: String, near: [Neighbour], traceRaw: String?, image: ImageReading?,
                       imageNote: String) -> Decision {
        let cands = candidates(text)
        let own = Set(cands.map(\.year))
        let tr = parseTrace(traceRaw)
        let check = tr.parsed ? evidenceCheck(year: tr.year, evidence: tr.evidence, context: context(text: text, near: near))
            : Check(verdict: "none", reason: "unparsed")
        let cited: String? = tr.evidence.map { $0["neighbour"] ?? "self" }
        var d = Decision(year: nil, month: nil, dateUncertain: true, evidenceClass: .none, step: nil, trace: tr,
                         check: check, cited: cited, image: image, imageNote: imageNote)
        let selfText = scalarPrefix(text, textChars)

        func explicitText(_ y: Int) {
            d.year = y; d.dateUncertain = false; d.evidenceClass = .text; d.step = 1
            // The quoted string and its line: the reply's own quote when it cites the document, else the rule's.
            let pick = rulePick(cands.filter { $0.year == y })
            if cited == "self", check.verdict == "valid", let q = tr.evidence?["quote"] {
                d.quote = q
                d.line = lineOf(q, in: selfText) ?? pick.map { $0.lineNo + 1 }
            } else if let p = pick {
                d.quote = p.line; d.line = p.lineNo + 1
            }
            d.month = pickMonth(pick)
            // Owner, 2026-11-12 (a): the model's flag may add Date Uncertain to an explicit text year, never remove it.
            if tr.parsed, tr.uncertain { d.dateUncertain = true; d.modelFlagAdded = true }
        }
        func estimate(_ y: Int) {
            d.year = y; d.dateUncertain = true; d.evidenceClass = .estimate; d.step = 4
            d.quote = tr.evidence?["quote"] ?? tr.evidence?["region"]
            d.sourceFile = near.first { $0.label == cited }?.file
            if cited == "self" { d.line = d.quote.flatMap { lineOf($0, in: selfText) } }
        }

        if let y = tr.year, own.contains(y) || check.verdict == "valid", cited == "self" || own.contains(y) {
            explicitText(y)
            return d
        }
        if !cands.isEmpty {
            if let y = tr.year, check.verdict == "valid" { estimate(y); return d }
            // An unparsed or unchecked reply: the rule stage's explicit year stands (08-dating.md, "Fallback").
            if let p = rulePick(cands) {
                d.year = p.year; d.dateUncertain = false; d.evidenceClass = .text; d.step = 1
                d.quote = p.line; d.line = p.lineNo + 1; d.month = pickMonth(p)
                if tr.parsed, tr.uncertain { d.dateUncertain = true; d.modelFlagAdded = true }
            }
            return d
        }
        if let image, let y = image.ownYear {
            d.year = y; d.dateUncertain = false; d.evidenceClass = .image; d.step = 2
            let ev = image.ownEvidence
            d.quote = ev?.quote; d.page = ev?.page; d.place = ev?.place
            if let mo = image.docMonth, let q = ev?.quote, pickMonth(rulePick(candidates(q))) == mo { d.month = mo }
            return d
        }
        if let y = tr.year, check.verdict == "valid" { estimate(y) }
        return d
    }

    /// The 1-based line of the own text that holds the quote (spacing- and case-tolerant), if one does.
    static func lineOf(_ quote: String, in text: String) -> Int? {
        let q = normText(quote)
        guard !q.isEmpty else { return nil }
        for (n, line) in splitLines(text).enumerated() where normText(line).contains(q) { return n + 1 }
        return nil
    }
}
