import Foundation

// MARK: - Facet types
//
// This file classifies a file's macOS Finder tag array into facets for DISPLAY / SORT / FILTER only.
// Parsing NEVER mutates a file and its result must NEVER drive a destructive write — TagWriter always
// operates on the verbatim raw array, not on these interpreted facets. (See CLAUDE.md → Safety.)
//
// Shared contract: lives in ArchiveCore so all Suite apps interpret tags identically.
// See SPEC/tag-format.md for the authoritative tag vocabulary.

/// The read-state facet — the token the fast-path triage toggles.
public enum ReadState: String, Sendable, CaseIterable {
    case read = "Read"
    case unread = "Unread"

    public var opposite: ReadState { self == .read ? .unread : .read }
}

/// Finder color-label meanings assigned by Archive Processor.
public enum ArchiveColor: Sendable, Equatable {
    case box     // Red,    Finder labelNumber 6
    case folder  // Purple, Finder labelNumber 3

    public init?(labelNumber: Int) {
        switch labelNumber {
        case 6: self = .box
        case 3: self = .folder
        default: return nil
        }
    }

    /// The color-name token Archive Processor also stores in the tag array.
    public var tokenName: String { self == .box ? "Red" : "Purple" }

    /// The Finder label number for this color (box = Red = 6, folder = Purple = 3).
    public var labelNumber: Int { self == .box ? 6 : 3 }
}

/// A file's tags parsed into facets. `raw` is preserved verbatim and is the source of truth.
public struct DocumentTags: Sendable, Equatable {
    public struct Month: Sendable, Equatable {
        public var number: Int
        public var name: String
        public init(number: Int, name: String) { self.number = number; self.name = name }
    }

    public let raw: [String]          // verbatim tag names, original order — never mutated here
    public let labelNumber: Int?

    public var year: Int?
    public var month: Month?
    public var day: Int?
    public var dateUncertain: Bool
    public var decade: Int?           // decade START year, e.g. 1970 (from "1970s"); nil when absent
    public var quality: Int?          // 1...3; nil = unrated (the wire never carries Q0)
    public var readState: ReadState?
    public var color: ArchiveColor?
    public var subjects: [String]     // everything not claimed by another facet, verbatim

    // The EXACT verbatim raw token that was consumed for each single-valued date/quality facet
    // (the "last one wins" winner). These — never a facet PREDICATE over all tokens — are what a
    // facet-replacing edit removes, so a subject that merely parses as a facet is never destroyed.
    // `nil` when the facet is absent. (See CORE DIRECTIVE: classification must not drive a write.)
    public var yearToken: String?
    public var monthToken: String?
    public var dayToken: String?
    public var decadeToken: String?   // the verbatim raw token consumed for the decade facet ("1970s")
    public var qualityToken: String?  // canonical Q1...Q3 or a retired P7...P10 alias

    // MARK: Transitional Priority surface (DERIVED — retired by W19.q3)
    //
    // Priority is retired: Quality is the only rating facet, and `quality`/`qualityToken` above are the
    // only stored state for it. These two are computed VIEWS of that one facet, kept solely so the
    // pre-W19 Reader surfaces (column, filter, sort, inline edit) keep compiling until W19.q3 renames
    // them. Deriving rather than mirroring is deliberate: a stored second copy can disagree with the
    // facet depending on which initializer built it, and a rating that reads two different ways is
    // exactly how a facet edit removes the wrong token.

    /// The rating on the retired 8...10 Priority scale, for the pre-W19 Reader surfaces only.
    ///
    /// A **legacy `P` token reports its own literal value**, so a `P7`-tagged file still reads `7` exactly as it
    /// did before Quality existed. A **canonical `Q` token maps onto the scale** (`Q1` → 8, `Q2` → 9, `Q3` → 10).
    /// The first clause is load-bearing and was missing in the first version of this: deriving purely from
    /// `quality` made `P7` unrepresentable (`parseQuality("P7")` is nil by contract), which silently broke the
    /// Reader's `P7` filter chip, its column value, and any saved smart folder selecting P7 — a control that
    /// matches nothing is worse than one that is absent, and removing the control is W19.q3's job, not q2's.
    public var priority: Int? {
        if let t = priorityToken, let legacy = DocumentTags.parsePriority(t) { return legacy }
        return quality.map { $0 + 7 }
    }

    /// The verbatim raw token consumed for the rating facet, but **only when it is a legacy `P` token**.
    /// `nil` for a canonical `Q1`–`Q3`, so the retired `.setPriority` edit can never remove a canonical
    /// Quality token — it stays exactly as narrow as it was before Quality existed.
    public var priorityToken: String? {
        guard let t = qualityToken, let first = t.first, first == "P" || first == "p" else { return nil }
        return t
    }

    public init(
        raw: [String], labelNumber: Int?,
        year: Int?, month: Month?, day: Int?, dateUncertain: Bool, decade: Int?,
        quality: Int?, readState: ReadState?, color: ArchiveColor?, subjects: [String],
        yearToken: String?, monthToken: String?, dayToken: String?, decadeToken: String?,
        qualityToken: String?
    ) {
        self.raw = raw; self.labelNumber = labelNumber
        self.year = year; self.month = month; self.day = day
        self.dateUncertain = dateUncertain; self.decade = decade
        // Normalize off-scale values to unrated so `Q0` — which the wire never carries — cannot enter
        // the model through a hand-built value either.
        self.quality = quality.flatMap { (1...3).contains($0) ? $0 : nil }
        self.readState = readState; self.color = color
        self.subjects = subjects
        self.yearToken = yearToken; self.monthToken = monthToken; self.dayToken = dayToken
        self.decadeToken = decadeToken
        self.qualityToken = qualityToken
    }

    /// Chronological sort key derived from the date tags. **No epoch limit** (medieval-safe).
    /// `nil` when there is no year → the caller sorts undated rows to the end.
    /// Month/day absent count as 0, so a year-only doc sorts just before its January.
    public var sortDate: Int? {
        DocumentTags.sortDateKey(year: year, month: month?.number, day: day, decade: decade)
    }

    /// The canonical chronological sort key from already-parsed numeric date components — the single
    /// source of truth for the SPEC sort formula (`year * 10_000 + month * 100 + day`), shared by every
    /// Suite app so a sort key never drifts between them: Reader via `sortDate` (typed facets), Notes via
    /// `Item.sortDate` (a `date:String?` + precision it parses into these components). **No epoch limit**
    /// (medieval-safe). Year wins over decade; absent month/day count as `0` so a year-only doc sorts just
    /// before its January. Returns `nil` when neither a year nor a decade is known → the caller sorts
    /// undated rows to the end. Sort-only (display, never a corpus write) → no file-safety stakes.
    public static func sortDateKey(year: Int?, month: Int?, day: Int?, decade: Int?) -> Int? {
        if let year { return year * 10_000 + (month ?? 0) * 100 + (day ?? 0) }
        if let decade { return decade * 10_000 }
        return nil
    }

    /// When true, the derived date is speculative and should be shown in italics.
    /// (`Date Uncertain` flags a speculative year; the file usually still carries a Year tag.)
    public var dateIsSpeculative: Bool { dateUncertain || (year == nil && decade != nil) }

    /// Tokens for the "File tags" column and the tag cloud: the raw tags minus the WINNING date facets
    /// (yearToken / monthToken / dayToken / `Date Uncertain`) and read-state (`Read`/`Unread`), since
    /// those have their own columns. Demoted same-facet tokens (e.g. "1984" when year=1980) stay visible.
    public var topicalTags: [String] {
        let excluded: Set<String> = {
            var s = Set<String>()
            if let t = yearToken { s.insert(t) }
            if let t = monthToken { s.insert(t) }
            if let t = dayToken { s.insert(t) }
            if let t = decadeToken { s.insert(t) }
            return s
        }()
        return raw.filter { token in
            let s = token.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return false }
            if ReadState.allCases.contains(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) { return false }
            if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame { return false }
            if excluded.contains(token) { return false }
            return true
        }
    }

    /// Human-readable date for the "Document date" column. `nil` when undated.
    /// Year only → "1980"; +month → "Mar 1980"; +day → "Mar 25, 1980".
    public var displayDate: String? {
        guard let year else { return decadeToken }
        guard let month else { return String(year) }
        let mon = DocumentTags.monthNames[month.number - 1].prefix(3)
        if let day { return "\(mon) \(day), \(year)" }
        return "\(mon) \(year)"
    }
}

// MARK: - Parsing

extension DocumentTags {
    /// Classify a raw tag array (+ optional Finder label number) into facets.
    /// Order of checks matters: read-state / quality (including legacy Priority aliases) / month / day
    /// are recognized before the generic bare-number "year" test.
    public static func parse(raw: [String], labelNumber: Int?) -> DocumentTags {
        var year: Int?
        var month: Month?
        var day: Int?
        var dateUncertain = false
        var decade: Int?
        var quality: Int?
        var readState: ReadState?
        var subjects: [String] = []

        // The verbatim raw token consumed for each single-valued date/quality facet ("last one
        // wins"). When a SECOND token also parses as the same facet, the previous winner is demoted
        // back to a subject so it stays visible AND so a facet edit only ever removes this one token.
        var yearToken: String?
        var monthToken: String?
        var dayToken: String?
        var decadeToken: String?
        var qualityToken: String?

        let color = labelNumber.flatMap(ArchiveColor.init(labelNumber:))

        for token in raw {
            let s = token.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }

            // Read state — exact whole-string, case-insensitive (never substring).
            if let rs = ReadState.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) {
                readState = rs
                continue
            }
            // Date Uncertain.
            if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame {
                dateUncertain = true
                continue
            }
            // Quality — canonical `Q1`...`Q3` plus the retired Priority spellings, aliased on read
            // (`P10`→3, `P9`→2, `P8`→1, `P7`→unrated). ONE facet with ONE last-token-wins winner
            // whichever way it is spelled, so a shadowed token is demoted to a subject and stays
            // visible, and a facet edit still only ever removes this single winner.
            if isRatingToken(s) {
                if let prev = qualityToken { subjects.append(prev) }
                quality = parseQuality(s); qualityToken = token
                continue
            }
            // Month "MM Month".
            if let m = parseMonth(s) {
                if let prev = monthToken { subjects.append(prev) }
                month = m; monthToken = token
                continue
            }
            // Day "Day N".
            if let d = parseDay(s) {
                if let prev = dayToken { subjects.append(prev) }
                day = d; dayToken = token
                continue
            }
            // Decade — "NNNNs" (checked before the bare-number Year test; the trailing 's'
            // means it can't collide with parseYear, so relative order is immaterial).
            if let dec = parseDecade(s) {
                if let prev = decadeToken { subjects.append(prev) }
                decade = dec; decadeToken = token
                continue
            }
            // Year — bare 3–4 digit number (medieval-friendly: 800, 1215, 1980).
            if let y = parseYear(s) {
                if let prev = yearToken { subjects.append(prev) }
                year = y; yearToken = token
                continue
            }
            // A color-name token that matches the file's actual Finder label is the marker color,
            // not a subject (a doc about the "Red Scare" with NO red label keeps "Red" as a subject).
            if let color, color.tokenName.caseInsensitiveCompare(s) == .orderedSame {
                continue
            }
            // Everything else is a subject — kept verbatim.
            subjects.append(token)
        }

        return DocumentTags(
            raw: raw, labelNumber: labelNumber,
            year: year, month: month, day: day, dateUncertain: dateUncertain, decade: decade,
            quality: quality, readState: readState, color: color, subjects: subjects,
            yearToken: yearToken, monthToken: monthToken, dayToken: dayToken, decadeToken: decadeToken,
            qualityToken: qualityToken
        )
    }

    public static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// The retired Priority spelling, `P7`...`P10`. Nothing WRITES these any more (W19); this exists so
    /// `parseQuality` can alias them on read, and so the pre-W19 Reader surfaces keep resolving until
    /// W19.q3. Deliberately lenient about a zero-padded `P07`: a lenient read in front of a strict write
    /// **EXACT match only** — `P7`, `P8`, `P9`, `P10`, upper or lower case, and nothing else.
    /// ⚠️ An earlier version of this was deliberately LENIENT about zero-padding, on the reasoning that a token
    /// this parser rejects becomes a SUBJECT and so leaks into the Subjects vocabulary. That reasoning inverted
    /// the SPEC's own ranking of the two risks, and the adversarial pass caught it: `Int("07")`/`Int("+7")` mean
    /// the lenient set included `P07`, `P007`, `P010`, `P+7` — **exactly the shape of an archival box/folder
    /// code**. Any such SUBJECT then won the rating facet, and a rating edit REMOVES the facet's token, so
    /// leniency bought a cosmetic vocabulary annoyance at the price of a **destructive write on a real subject**.
    /// Classification must never drive a write. Strict here; the vocabulary can tolerate a stray suggestion.
    public static func parsePriority(_ s: String) -> Int? {
        guard let first = s.first, first == "P" || first == "p" else { return nil }
        let digits = String(s.dropFirst())
        guard let n = Int(digits), (7...10).contains(n), digits == String(n) else { return nil }
        return n
    }

    /// Canonical rating tokens in ascending order. Absence represents unrated; `Q0` is never a token.
    public static let qualityTokens = ["Q1", "Q2", "Q3"]

    /// The tag to WRITE for a rating, and the single place that spells one. `nil` for unrated and for any
    /// off-scale value, because unrated is written as the ABSENCE of a token — the wire never carries `Q0`.
    public static func qualityTag(for quality: Int?) -> String? {
        guard let q = quality, (1...3).contains(q) else { return nil }
        return qualityTokens[q - 1]
    }

    /// Parse the unified Quality facet, 1...3. Retired Priority values alias on read without rewriting any
    /// bytes: `P8`→1, `P9`→2, `P10`→3, while `P7` is unrated and therefore returns `nil` — as does any
    /// token that is not a rating at all, `Q0` included. Use `isRatingToken` to tell those two apart.
    public static func parseQuality(_ s: String) -> Int? {
        // Case-SENSITIVE and exact: the SPEC's Quality row says "exactly one of `Q1` `Q2` `Q3`", and every
        // token in the contract except Read/Unread is an exact match. Accepting `q2` would consume a
        // fiscal-quarter subject as the rating facet — and a rating edit then removes it from the file.
        if s.count == 2, s.first == "Q", let n = Int(s.dropFirst()), (1...3).contains(n) { return n }
        guard let legacy = parsePriority(s), legacy >= 8 else { return nil }
        return legacy - 7
    }

    /// Whether the token OCCUPIES the rating facet, regardless of what it evaluates to. The retired `P7`
    /// does — it is a recognized rating spelling that happens to mean unrated — which is what keeps it out
    /// of the Subjects vocabulary. A literal `Q0` does NOT, so it stays an ordinary subject.
    public static func isRatingToken(_ s: String) -> Bool {
        parseQuality(s) != nil || parsePriority(s) == 7
    }

    /// "MM Month" where MM is 1...12 and the name matches that month (case-insensitive).
    public static func parseMonth(_ s: String) -> Month? {
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let num = Int(parts[0]), (1...12).contains(num) else { return nil }
        guard monthNames[num - 1].caseInsensitiveCompare(String(parts[1])) == .orderedSame else { return nil }
        return Month(number: num, name: monthNames[num - 1])
    }

    /// "Day N" where N is 1...31 (unpadded).
    public static func parseDay(_ s: String) -> Int? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Day") == .orderedSame,
              let n = Int(parts[1]), (1...31).contains(n) else { return nil }
        return n
    }

    /// Bare integer of 3–4 digits. Display/sort-only; a numeric subject (a box number, a book title
    /// like "1984") can collide here — acceptable because it never affects a write, and the user can
    /// correct a mis-derived facet in the UI.
    public static func parseYear(_ s: String) -> Int? {
        guard (3...4).contains(s.count), s.allSatisfy(\.isNumber), let y = Int(s) else { return nil }
        return y
    }

    /// "1970s"-style decade token (4-digit number + trailing "s").
    /// A decade token "NNNNs": 3–4 digits whose last digit is 0, then a lowercase 's'
    /// (e.g. "1970s", medieval-friendly "970s"). Returns the decade START year (1970).
    public static func parseDecade(_ s: String) -> Int? {
        guard (4...5).contains(s.count), s.hasSuffix("s"),
              let y = Int(s.dropLast()), y % 10 == 0 else { return nil }
        return y
    }

    /// True if the trimmed token looks like ANY date facet (year, month, day, decade, "Date Uncertain").
    /// Used to keep date-like tokens out of display surfaces (tag cloud, tag filter suggestions) even
    /// when they were demoted to `subjects` during a facet collision.
    public static func isDateFacetLike(_ tag: String) -> Bool {
        let s = tag.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame { return true }
        if parseYear(s) != nil { return true }
        if parseMonth(s) != nil { return true }
        if parseDay(s) != nil { return true }
        if parseDecade(s) != nil { return true }
        return false
    }
}
