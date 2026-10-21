import AppKit
import PDFKit
import XCTest
@testable import ArchiveCore

/// W40.e6 — parser robustness. Seeded fuzz loops (truncate, flip bytes, insert, nest) over the tag format,
/// the sent-with date and the page-2 header, and property tests for tag write-then-read round trips through
/// a real file's xattrs. The bar (phase rule): a crash or a silent wrong value is a bug, a clean refusal is
/// a pass. "Wrong value" is judged against the SPEC/tag-format.md grammar, restated here independently of
/// the parser so the test does not just mirror the code it checks.
///
/// Every loop is seeded, so a failure names its seed and iteration and reproduces exactly.
final class ParserFuzzTests: XCTestCase {

    // MARK: - Tag tokens: fuzz

    /// Each token `DocumentTags.parse` consumes for a facet must be in the SPEC's grammar for that facet,
    /// and the facet value must be what the token spells. Anything outside the grammar has to stay a
    /// subject, verbatim — that is what keeps a facet edit from removing a real subject.
    func testFuzzedTagTokensOnlyFillFacetsTheSpecAllows() {
        var rng = FuzzRNG(seed: 0xE6_7A65)
        for i in 0..<20_000 {
            let raw = (0..<rng.int(1...6)).map { _ in FuzzTokens.token(&rng) }
            let label = rng.chance(0.3) ? [0, 3, 6, rng.int(-3...12)][rng.int(0...3)] : nil
            let t = DocumentTags.parse(raw: raw, labelNumber: label)
            let ctx = "iteration \(i), raw \(raw.debugDescription)"

            if let tok = t.yearToken {
                let s = tok.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(SpecGrammar.isYear(s), "year consumed a non-year token — \(ctx)")
                XCTAssertEqual(t.year, Int(s), ctx)
            }
            if let tok = t.decadeToken {
                let s = tok.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(SpecGrammar.isDecade(s), "decade consumed a non-decade token — \(ctx)")
                XCTAssertEqual(t.decade, Int(s.dropLast()), ctx)
            }
            if let tok = t.monthToken {
                let s = tok.trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(SpecGrammar.month(s), t.month?.number, "month consumed a non-month token — \(ctx)")
            }
            if let tok = t.dayToken {
                let s = tok.trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(SpecGrammar.day(s), t.day, "day consumed a non-day token — \(ctx)")
            }
            if let tok = t.qualityToken {
                let s = tok.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(SpecGrammar.ratingTokens.keys.contains(s), "rating consumed \(s.debugDescription) — \(ctx)")
                XCTAssertEqual(t.quality, SpecGrammar.ratingTokens[s] ?? nil, ctx)
            }
            if let tok = t.sentWithToken {
                // A consumed sent-with token re-spells to exactly itself: the parser accepted only canonical form.
                XCTAssertEqual(t.sentWith.map(SentWithTag.token(for:)), tok.trimmingCharacters(in: .whitespaces), ctx)
            }
            if let c = t.color { XCTAssertEqual(c.labelNumber, label, ctx) }

            // Nothing invented: every subject and every winner is a token the file really carries.
            var pool = raw
            for s in t.subjects {
                guard let at = pool.firstIndex(of: s) else { return XCTFail("subject \(s.debugDescription) not in raw — \(ctx)") }
                pool.remove(at: at)
            }
            for w in [t.yearToken, t.monthToken, t.dayToken, t.decadeToken, t.qualityToken, t.sentWithToken].compactMap({ $0 }) {
                XCTAssertTrue(raw.contains(w), "winner \(w.debugDescription) not in raw — \(ctx)")
            }
        }
    }

    /// The cases the loop above found (W40.e6): `Int(_:)` took a sign and any run of leading zeros, so these
    /// filled a facet, and a facet edit removes the token it consumed. Each must stay a subject, verbatim.
    func testSignedAndOverPaddedNumbersStaySubjects() {
        for s in ["-170s", "+540s", "+00s", "+12 December", "+6 June", "0007 July", "002 February", "011 November",
                  "Day 013", "day  009", "Day +5", "Day -1"] {
            XCTAssertEqual(DocumentTags.parse(raw: [s], labelNumber: nil).subjects, [s], s)
            XCTAssertFalse(DocumentTags.isDateFacetLike(s), s)
        }
        // The spellings the SPEC and the writers use still fill their facets.
        let t = DocumentTags.parse(raw: ["1970s", "03 March", "3 March", "Day 5", "Day 05"], labelNumber: nil)
        XCTAssertEqual(t.decade, 1970); XCTAssertEqual(t.month?.number, 3); XCTAssertEqual(t.day, 5)
        XCTAssertEqual(DocumentTags.parseDecade("970s"), 970)
        XCTAssertEqual(DocumentTags.parseMonth("12 december")?.number, 12)
    }

    /// The strict wire parsers accept only canonical spellings: whatever they accept re-spells byte for byte.
    func testFuzzedWireDatesAreAcceptedOnlyInCanonicalForm() {
        var rng = FuzzRNG(seed: 0xDA7E)
        for i in 0..<30_000 {
            let s = FuzzTokens.mutate(FuzzTokens.wireDate(&rng), &rng)
            if let d = ArchiveDate.parse(wireValue: s) {
                XCTAssertEqual(d.wireValue, s, "iteration \(i): accepted a non-canonical wire date")
                XCTAssertNotNil(DocumentTags.sortDateKey(year: d.year, month: d.month, day: d.day, decade: nil))
            }
            let tok = SentWithTag.prefix + s
            if let d = SentWithTag.parse(tok) { XCTAssertEqual(SentWithTag.token(for: d), tok, "iteration \(i)") }
            // Codable goes through the same strict parser: decode either fails cleanly or re-encodes identically.
            let json = Data(("[" + jsonString(s) + "]").utf8)
            if let decoded = try? JSONDecoder().decode([ArchiveDate].self, from: json) {
                XCTAssertEqual(decoded.first?.wireValue, s, "iteration \(i)")
            }
        }
    }

    // MARK: - Tag tokens: round trips

    func testEveryValidArchiveDateRoundTrips() throws {
        var rng = FuzzRNG(seed: 0x5E47)
        for _ in 0..<5_000 {
            let d = FuzzTokens.archiveDate(&rng)
            XCTAssertEqual(ArchiveDate.parse(wireValue: d.wireValue), d)
            XCTAssertEqual(SentWithTag.parse(SentWithTag.token(for: d)), d)
            let t = DocumentTags.parse(raw: [SentWithTag.token(for: d)], labelNumber: nil)
            XCTAssertEqual(t.sentWith, d); XCTAssertEqual(t.subjects, [])
            let back = try JSONDecoder().decode([ArchiveDate].self, from: JSONEncoder().encode([d]))
            XCTAssertEqual(back, [d])
        }
    }

    /// A full facet state spelled by the writers (`TagEditing.monthToken`, `qualityTag`, `SentWithTag`, …),
    /// shuffled among subjects, parses back to exactly that state with every subject untouched.
    func testWrittenFacetSetsParseBackExactly() {
        var rng = FuzzRNG(seed: 0xFACE7)
        for i in 0..<5_000 {
            let state = FacetState.random(&rng)
            let raw = state.tokens().shuffled(using: &rng)
            XCTAssertEqual(FacetState(parsing: DocumentTags.parse(raw: raw, labelNumber: state.color?.labelNumber)),
                           state, "iteration \(i), raw \(raw.debugDescription)")
        }
    }

    /// Write-then-read through a real file: the coordinated writer puts the tag array into the xattr, the
    /// reader takes it back out, and the parse is the state that was written — with a random edit applied
    /// in between through `TagEditing.delta`, the same delta the apps write.
    func testTagWriteThenReadRoundTripsThroughAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParserFuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scratch.pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: url)

        var rng = FuzzRNG(seed: 0xF11E)
        for i in 0..<150 {
            var state = FacetState.random(&rng)
            let first = state.tokens().shuffled(using: &rng)
            _ = try CoordinatedTagWriter.write(url) { _, _ in (first, state.color?.labelNumber) }
            XCTAssertEqual(try readBack(url), state, "iteration \(i): written \(first.debugDescription)")

            let op = state.randomEdit(&rng)
            let before = DocumentTags.parse(raw: first, labelNumber: state.color?.labelNumber)
            let delta = TagEditing.delta(for: op, given: before)
            _ = try CoordinatedTagWriter.write(url) { tags, label in Self.apply(delta, to: tags, label: label) }
            state.apply(op)
            XCTAssertEqual(try readBack(url), state, "iteration \(i): \(op) on \(first.debugDescription)")
        }
    }

    // MARK: - Page-2 header

    /// Header lines exactly as `PDFGenerator.makeTextPage` lays them out, with fuzzed field values: the
    /// classification reads back, and the stripped body is the body that was written.
    func testPageTwoHeaderRoundTrips() {
        var rng = FuzzRNG(seed: 0x9A6E2)
        for i in 0..<10_000 {
            let page = PageTwo.random(&rng, classificationLookalikes: false)
            let text = page.text
            XCTAssertEqual(PDFHeaderParser.stripHeader(from: text), page.expectedBody, "iteration \(i): \(text.debugDescription)")
            XCTAssertEqual(PDFHeaderParser.parseClassification(from: text), page.classification, "iteration \(i)")
        }
    }

    /// The stripped body survives lookalike lines in the file name and the body.
    func testPageTwoBodySurvivesLookalikeLines() {
        var rng = FuzzRNG(seed: 0x9A6E3)
        for i in 0..<10_000 {
            let page = PageTwo.random(&rng, classificationLookalikes: true)
            XCTAssertEqual(PDFHeaderParser.stripHeader(from: page.text), page.expectedBody, "iteration \(i): \(page.text.debugDescription)")
        }
    }

    /// KNOWN ISSUE `W40.fix-core-classification-from-body`: `parseClassification` takes the first
    /// `Classification:` line anywhere on the page, so a header without one borrows the body's (an OCR'd
    /// security marking), and a file name that starts with the word wins over the real header line.
    /// Delete the expectation when the fix lands; `strict` makes this test fail the day it is fixed.
    func testClassificationIsReadOnlyFromTheHeaderKnownIssue() {
        let noHeaderClass = PageTwo(fileName: "IMG_0001.jpg", metaLine: "Anthropic \u{00B7} Claude \u{00B7} Oct 20, 2026",
                                    classification: nil, dateLines: [], body: "Memo\nClassification: Top Secret")
        let lookalikeName = PageTwo(fileName: "Classification: notes.jpg", metaLine: "Anthropic \u{00B7} Claude \u{00B7} Oct 20, 2026",
                                    classification: "Continuation", dateLines: [], body: "Page two of the letter.")
        XCTExpectFailure("W40.fix-core-classification-from-body", strict: true) {
            XCTAssertNil(PDFHeaderParser.parseClassification(from: noHeaderClass.text))
            XCTAssertEqual(PDFHeaderParser.parseClassification(from: lookalikeName.text), "Continuation")
        }
    }

    /// Mutated header text never crashes, and the stripped body is always a trailing run of the page's lines:
    /// stripping removes header lines, it never rewrites or invents text.
    func testFuzzedPageTwoTextStripsToATrailingRunOfLines() {
        var rng = FuzzRNG(seed: 0x57819)
        for i in 0..<10_000 {
            let text = FuzzTokens.mutateText(PageTwo.random(&rng).text, &rng)
            let out = PDFHeaderParser.stripHeader(from: text)
            let lines = text.components(separatedBy: .newlines)
            let tails = (0...lines.count).map {
                lines.dropFirst($0).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            XCTAssertTrue(tails.contains(out), "iteration \(i): \(text.debugDescription) → \(out.debugDescription)")
            if let c = PDFHeaderParser.parseClassification(from: text) {
                XCTAssertFalse(c.isEmpty); XCTAssertFalse(c.contains("\n"))
            }
        }
    }

    /// A real two-page app-format PDF, then byte-level damage: truncation, flipped bytes, spliced runs.
    /// `extract` must either refuse (nil) or return content — never crash or hang.
    func testDamagedPDFBytesNeverCrashExtract() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParserFuzzPDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.pdf")
        try PageTwo.writePDF(text: "Extracted text.\nIMG_0001.jpg\nAnthropic \u{00B7} Claude \u{00B7} Oct 20, 2026\n"
                             + "Classification: Document Start\n\nDear Sir, the box is in the annex.", to: good)
        let original = try Data(contentsOf: good)
        let clean = try XCTUnwrap(PDFHeaderParser.extract(good), "the undamaged PDF must extract")
        XCTAssertEqual(clean.classification, "Document Start")
        XCTAssertEqual(clean.strippedBody, "Dear Sir, the box is in the annex.")

        var rng = FuzzRNG(seed: 0xBAD9DF)
        var refused = 0
        let url = dir.appendingPathComponent("damaged.pdf")
        for _ in 0..<300 {
            try FuzzTokens.mutateBytes(original, &rng).write(to: url)
            if let c = PDFHeaderParser.extract(url) {
                XCTAssertGreaterThanOrEqual(c.pageCount, 0)
                XCTAssertTrue(c.fullBody.contains(c.strippedBody) || c.strippedBody.isEmpty || c.pageCount >= 2)
            } else {
                refused += 1
            }
        }
        // Not a pass condition, just proof the damage reached the parser rather than being a no-op.
        print("W40.e6 damaged-PDF loop: \(refused)/300 refused cleanly, the rest extracted")
    }

    // MARK: - Helpers

    private func readBack(_ url: URL) throws -> FacetState {
        guard case let .success(names, label) = TagReading.read(url) else { throw XCTSkip("unreadable") }
        return FacetState(parsing: DocumentTags.parse(raw: names, labelNumber: label))
    }

    /// The documented delta semantics (`TagDelta`): adds skipped when already present, removes are exact
    /// (Read/Unread case-insensitive), color keeps the token and the label number together.
    static func apply(_ d: TagDelta, to tags: [String], label: Int?) -> ([String], Int?) {
        var out = tags.filter { t in !d.remove.contains { shouldRemoveTag(t, matching: $0) } }
        for a in d.add where !out.contains(where: { isSameTag($0, a) }) { out.append(a) }
        var newLabel = label
        switch d.color {
        case .set(let c)?:
            out.removeAll { $0 == "Red" || $0 == "Purple" }
            out.append(c.tokenName); newLabel = c.labelNumber
        case .clear?:
            if let cur = label.flatMap(ArchiveColor.init(labelNumber:)) { out.removeAll { $0 == cur.tokenName } }
            newLabel = 0
        case .restoreLabel(let l)?: newLabel = l
        case nil: break
        }
        return (out, newLabel)
    }

    private func jsonString(_ s: String) -> String {
        String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
    }
}

// MARK: - The SPEC grammar, restated

/// SPEC/tag-format.md, §Facets — written from the SPEC table, not from the parser.
enum SpecGrammar {
    static func asciiDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) } }

    /// Year: bare digits, 3–4 of them.
    static func isYear(_ s: String) -> Bool { (3...4).contains(s.count) && asciiDigits(Substring(s)) }

    /// Decade: a 3–4 digit run whose last digit is 0, then a lowercase `s`.
    static func isDecade(_ s: String) -> Bool {
        guard s.hasSuffix("s") else { return false }
        let d = s.dropLast()
        return (3...4).contains(d.count) && asciiDigits(d) && d.last == "0"
    }

    /// Month: `MM Month`, MM = 1–12 and the name of that month, case-insensitive.
    static func month(_ s: String) -> Int? {
        let p = s.split(separator: " ", maxSplits: 1)
        guard p.count == 2, p[0].count <= 2, asciiDigits(p[0]), let n = Int(p[0]), (1...12).contains(n),
              DocumentTags.monthNames[n - 1].caseInsensitiveCompare(p[1]) == .orderedSame else { return nil }
        return n
    }

    /// Day: `Day N`, N = 1–31.
    static func day(_ s: String) -> Int? {
        let p = s.split(separator: " ")
        guard p.count == 2, p[0].caseInsensitiveCompare("Day") == .orderedSame, p[1].count <= 2,
              asciiDigits(p[1]), let n = Int(p[1]), (1...31).contains(n) else { return nil }
        return n
    }

    /// Rating tokens and what they mean (`P7` occupies the facet but means unrated).
    static let ratingTokens: [String: Int?] = [
        "Q1": 1, "Q2": 2, "Q3": 3,
        "P7": nil, "p7": nil, "P8": 1, "p8": 1, "P9": 2, "p9": 2, "P10": 3, "p10": 3,
    ]
}

// MARK: - Facet state for round trips

struct FacetState: Equatable, CustomStringConvertible {
    var year: Int?, month: Int?, day: Int?, decade: Int?
    var dateUncertain = false
    var quality: Int?
    var readState: ReadState?
    var color: ArchiveColor?
    var sentWith: ArchiveDate?
    var subjects: [String] = []

    var description: String {
        "y\(year as Any) m\(month as Any) d\(day as Any) dec\(decade as Any) u\(dateUncertain) q\(quality as Any) "
            + "r\(readState?.rawValue as Any) c\(color as Any) sw\(sentWith?.wireValue as Any) s\(subjects.sorted())"
    }

    init(parsing t: DocumentTags) {
        year = t.year; month = t.month?.number; day = t.day; decade = t.decade
        dateUncertain = t.dateUncertain; quality = t.quality; readState = t.readState
        color = t.color; sentWith = t.sentWith; subjects = t.subjects.sorted()
    }

    private init() {}

    static func random(_ rng: inout FuzzRNG) -> FacetState {
        var s = FacetState()
        if rng.chance(0.6) { s.year = rng.int(100...2099) } else if rng.chance(0.4) { s.decade = rng.int(10...209) * 10 }
        if rng.chance(0.5) { s.month = rng.int(1...12) }
        if rng.chance(0.4) { s.day = rng.int(1...31) }
        s.dateUncertain = rng.chance(0.2)
        if rng.chance(0.5) { s.quality = rng.int(1...3) }
        if rng.chance(0.6) { s.readState = rng.chance(0.5) ? .read : .unread }
        if rng.chance(0.3) { s.color = rng.chance(0.5) ? .box : .folder }
        if rng.chance(0.3) { s.sentWith = FuzzTokens.archiveDate(&rng) }
        var subjects = Set<String>()
        for _ in 0..<rng.int(0...4) {
            let c = FuzzTokens.subject(&rng)
            // A subject is anything the parser leaves as a subject on its own and that a color token can't claim.
            if DocumentTags.parse(raw: [c], labelNumber: 6).subjects == [c],
               DocumentTags.parse(raw: [c], labelNumber: 3).subjects == [c] { subjects.insert(c) }
        }
        s.subjects = subjects.sorted()
        return s
    }

    /// The tag array the apps write for this state.
    func tokens() -> [String] {
        var t: [String] = subjects
        if let year { t.append(String(year)) }
        if let decade { t.append("\(decade)s") }
        if let month { t.append(TagEditing.monthToken(month)) }
        if let day { t.append("Day \(day)") }
        if dateUncertain { t.append("Date Uncertain") }
        if let q = DocumentTags.qualityTag(for: quality) { t.append(q) }
        if let readState { t.append(readState.rawValue) }
        if let color { t.append(color.tokenName) }
        if let sentWith { t.append(SentWithTag.token(for: sentWith)) }
        return t
    }

    func randomEdit(_ rng: inout FuzzRNG) -> TagEditOp {
        switch rng.int(0...8) {
        case 0: return .setYear(rng.chance(0.8) ? rng.int(100...2099) : nil)
        case 1: return .setMonth(rng.chance(0.8) ? rng.int(1...12) : nil)
        case 2: return .setDay(rng.chance(0.8) ? rng.int(1...31) : nil)
        case 3: return .setQuality(rng.chance(0.8) ? rng.int(1...3) : nil)
        case 4: return .setDateUncertain(rng.chance(0.5))
        case 5: return .setColor(rng.chance(0.3) ? nil : (rng.chance(0.5) ? .box : .folder))
        case 6: return .setSentWith(rng.chance(0.8) ? FuzzTokens.archiveDate(&rng) : nil)
        case 7:
            let c = FuzzTokens.subject(&rng)
            return DocumentTags.parse(raw: [c], labelNumber: 6).subjects == [c]
                && DocumentTags.parse(raw: [c], labelNumber: 3).subjects == [c] ? .addSubject(c) : .setYear(nil)
        default: return subjects.isEmpty ? .setDay(nil) : .removeSubject(subjects[rng.int(0...(subjects.count - 1))])
        }
    }

    /// What the op means for the state, written from `TagEditOp`'s documentation.
    mutating func apply(_ op: TagEditOp) {
        switch op {
        case .setYear(let y): year = y; decade = nil   // Year supersedes Decade
        case .setMonth(let m): month = m
        case .setDay(let d): day = d
        case .setQuality(let q): quality = q
        case .setDateUncertain(let on): dateUncertain = on
        case .setColor(let c): color = c
        case .setSentWith(let d): sentWith = d
        case .setSentWithUncertain: break
        case .addSubject(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !subjects.contains(t) { subjects = (subjects + [t]).sorted() }
        case .removeSubject(let s): subjects.removeAll { $0 == s }
        }
    }
}

// MARK: - Page-2 text

struct PageTwo {
    var fileName: String?
    var metaLine: String
    var classification: String?
    var dateLines: [String]
    var body: String

    var text: String {
        var h = "Extracted text."
        if let fileName { h += "\n\(fileName)" }
        h += "\n\(metaLine)"
        if let classification { h += "\nClassification: \(classification)" }
        for l in dateLines { h += "\n\(l)" }
        return h + "\n\n" + body
    }

    var expectedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `classificationLookalikes` adds file names and body lines that start `Classification:` — the known
    /// issue in `testClassificationIsReadOnlyFromTheHeaderKnownIssue`.
    static func random(_ rng: inout FuzzRNG, classificationLookalikes: Bool = true) -> PageTwo {
        let names = ["IMG_0001.jpg", "scan 12.tiff", "Box 4 · Folder 2.jpg", "Document date: 1958.png",
                     "Extracted text..jpg", "  padded.jpg", "日本語.heic", "P9.jpg"]
            + (classificationLookalikes ? ["Classification: notes.jpg"] : [])
        let providers = ["Anthropic", "Mistral", "OpenAI", "Local", "Gateway · Proxy"]
        let classes = ["Document Start", "Continuation", "Box", "Folder", "Unknown · Type"]
        var dates: [String] = []
        if rng.chance(0.4) { dates.append(PDFHeaderParser.documentDatePrefix + FuzzTokens.archiveDate(&rng).display) }
        if rng.chance(0.3) { dates.append(PDFHeaderParser.sentWithPrefix + FuzzTokens.archiveDate(&rng).display) }
        let lines = ["Dear Sir,", "Document date: never", "Sent with: love", "A · B · C", "Extracted text.", "",
                     "   indented", FuzzTokens.subject(&rng)] + (classificationLookalikes ? ["Classification: secret"] : [])
        let bodyLines = (0..<rng.int(1...5)).map { _ in lines[rng.int(0...(lines.count - 1))] }
        // The body starts with a non-blank line: a page whose OCR text is blank has no body to keep.
        let body = (["The first line of the letter."] + bodyLines).joined(separator: "\n")
        return PageTwo(fileName: rng.chance(0.8) ? names[rng.int(0...(names.count - 1))] : nil,
                       metaLine: "\(providers[rng.int(0...(providers.count - 1))]) \u{00B7} Model X \u{00B7} Oct 20, 2026",
                       classification: rng.chance(0.7) ? classes[rng.int(0...(classes.count - 1))] : nil,
                       dateLines: dates, body: body)
    }

    /// A two-page PDF: a blank image page, then `text` drawn as real text so PDFKit extracts it.
    static func writePDF(text: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        ctx.beginPDFPage(nil); ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(in: box.insetBy(dx: 36, dy: 36),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

// MARK: - Fuzz inputs

enum FuzzTokens {
    static let atoms = ["0", "1", "2", "5", "9", "00", "10", "19", "58", "+", "-", " ", "  ", "s", "S", "Q", "P", "p",
                        "Day", "day ", "March", "march", "Sent With ", "Date Uncertain", "Read", "Red", "Purple",
                        "\u{00A0}", "\t", "é", "\u{0663}", "\u{FF11}", "\u{FEFF}", "\u{200B}", "·", "s ", "e", "x", "0x"]

    static func token(_ rng: inout FuzzRNG) -> String {
        switch rng.int(0...3) {
        case 0: return wellFormed(&rng)
        case 1: return mutate(wellFormed(&rng), &rng)
        case 2: return (0..<rng.int(1...4)).map { _ in atoms[rng.int(0...(atoms.count - 1))] }.joined()
        default: return [atoms[rng.int(0...(atoms.count - 1))], wellFormed(&rng)].shuffled(using: &rng).joined()
        }
    }

    static func wellFormed(_ rng: inout FuzzRNG) -> String {
        switch rng.int(0...10) {
        case 0: return String(rng.int(100...2099))
        case 1: return "\(rng.int(10...209) * 10)s"
        case 2: return TagEditing.monthToken(rng.int(1...12))
        case 3: return "Day \(rng.int(1...31))"
        case 4: return ["Q1", "Q2", "Q3", "P7", "P8", "P9", "P10", "Q0", "P07"][rng.int(0...8)]
        case 5: return SentWithTag.token(for: archiveDate(&rng))
        case 6: return ["Read", "Unread", "Date Uncertain", SentWithTag.uncertainToken, "Red", "Purple"][rng.int(0...5)]
        case 7: return wireDate(&rng)
        default: return subject(&rng)
        }
    }

    static func subject(_ rng: inout FuzzRNG) -> String {
        ["Correspondence", "Box 12", "1984", "Red Scare", "Q2 report", "Day trip", "March on Washington",
         "Truman, Harry S.", "P-38", "folder 3/4", "Ünïcödé", "日本", "a", "Budget · FY58"][rng.int(0...13)]
    }

    static func wireDate(_ rng: inout FuzzRNG) -> String {
        rng.chance(0.15) ? "\(rng.int(10...999) * 10)s" : archiveDate(&rng).wireValue
    }

    static func archiveDate(_ rng: inout FuzzRNG) -> ArchiveDate {
        while true {
            let y = rng.int(100...9999)
            let d: ArchiveDate?
            switch rng.int(0...3) {
            case 0: d = ArchiveDate(decade: y / 10 * 10)
            case 1: d = ArchiveDate(year: y)
            case 2: d = ArchiveDate(year: y, month: rng.int(1...12))
            default: d = ArchiveDate(year: y, month: rng.int(1...12), day: rng.int(1...31))
            }
            if let d { return d }
        }
    }

    /// Character-level damage: truncate, drop, duplicate, swap in an atom, or nest the string in itself.
    static func mutate(_ s: String, _ rng: inout FuzzRNG) -> String {
        var c = Array(s)
        for _ in 0..<rng.int(1...3) {
            let n = c.count
            switch rng.int(0...5) {
            case 0: if n > 0 { c = Array(c.prefix(rng.int(0...(n - 1)))) }
            case 1: if n > 0 { c.remove(at: rng.int(0...(n - 1))) }
            case 2: c.insert(contentsOf: Array(atoms[rng.int(0...(atoms.count - 1))]), at: rng.int(0...n))
            case 3: if n > 0 { c[rng.int(0...(n - 1))] = Array(atoms[rng.int(0...(atoms.count - 1))]).first ?? "x" }
            case 4: c.insert(contentsOf: c, at: rng.int(0...n))
            default: if n > 1 { c.swapAt(rng.int(0...(n - 1)), rng.int(0...(n - 1))) }
            }
        }
        return String(c)
    }

    /// Line-level damage for page text, plus character damage inside one line.
    static func mutateText(_ s: String, _ rng: inout FuzzRNG) -> String {
        var lines = s.components(separatedBy: "\n")
        for _ in 0..<rng.int(1...3) {
            let n = lines.count
            switch rng.int(0...5) {
            case 0: lines = Array(lines.prefix(rng.int(0...n)))
            case 1: if n > 0 { lines.remove(at: rng.int(0...(n - 1))) }
            case 2: if n > 0 { let l = lines[rng.int(0...(n - 1))]; lines.insert(l, at: rng.int(0...n)) }
            case 3: if n > 0 { let i = rng.int(0...(n - 1)); lines[i] = mutate(lines[i], &rng) }
            case 4: lines.insert(contentsOf: lines, at: rng.int(0...n))
            default: lines.insert(["", "\r", " ", "Classification:", "x \u{00B7} y", "Sent with: "][rng.int(0...5)], at: rng.int(0...n))
            }
        }
        return lines.joined(separator: rng.chance(0.1) ? "\r\n" : "\n")
    }

    /// Byte-level damage: truncate, flip bits, overwrite a run, splice a copied run, or nest a prefix.
    static func mutateBytes(_ data: Data, _ rng: inout FuzzRNG) -> Data {
        var b = [UInt8](data)
        for _ in 0..<rng.int(1...4) {
            let n = b.count
            guard n > 1 else { break }
            switch rng.int(0...4) {
            case 0: b = Array(b.prefix(rng.int(1...(n - 1))))
            case 1: for _ in 0..<rng.int(1...16) { b[rng.int(0...(b.count - 1))] ^= UInt8(1 << rng.int(0...7)) }
            case 2: let at = rng.int(0...(n - 1)); for i in at..<min(n, at + rng.int(1...64)) { b[i] = UInt8(rng.int(0...255)) }
            case 3: let a = rng.int(0...(n - 1)), len = rng.int(1...min(256, n - a)); b.insert(contentsOf: b[a..<(a + len)], at: rng.int(0...n))
            default: b.insert(contentsOf: b.prefix(rng.int(1...min(n, 512))), at: rng.int(0...n))
            }
        }
        return Data(b)
    }
}

/// SplitMix64 — deterministic, so every fuzz failure reproduces from its seed.
struct FuzzRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}
