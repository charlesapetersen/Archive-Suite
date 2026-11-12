import Foundation

/// Title case for text written wholly in capitals — a typed heading, a box label, a telegram — so it reads
/// as "Managing Director Qualifications" rather than "MANAGING DIRECTOR QUALIFICATIONS". One rule for the
/// suite: the Reader's Copy Cleaned for Prose (W40.reader-prose-structure) and the label values W47.ct-normalise
/// shows both use it.
///
/// Only text with no lowercase letter at all is changed; capitals inside mixed-case text are the writer's and
/// are left. What stays in capitals: initials and dotted abbreviations (J. W., U.S.A.), slash forms of short parts
/// (M/D, A/C), words with no vowel (NBC, HBS, JFK), Roman numerals (II, XIV), a short list of acronyms that have
/// vowels (UCLA, NATO, …) and whatever the caller adds. Small words (of, the, and, …) are lower case inside a
/// title, capitalised first, last and after a colon. Ordinal and decade suffixes after digits are lowered
/// (12TH → 12th, 1960S → 1960s). Only letter case changes: no character is added, removed or moved.
public enum TitleCase {

    /// Acronyms with a vowel, which the no-vowel rule cannot recognise. Deliberately short: a word here stays
    /// in capitals even where it is an ordinary word, so "US" (the pronoun) is not in it.
    public static let knownAcronyms: Set<String> = [
        "UCLA", "USA", "USSR", "UN", "UK", "EU", "NATO", "NASA", "FBI", "CIA", "IBM", "NAACP", "YMCA", "YWCA",
        "AFL", "CIO", "HEW", "HUD", "OMB", "GOP", "MIT", "CEO", "MBA", "IRS", "SEC", "OSS", "UNESCO", "UNICEF",
        "OPEC", "UPI", "AEC", "TVA", "WPA", "ICC", "FAA", "EEOC", "ABC", "ACLU", "UAW", "OEO", "USIA", "AMA",
        "OPA", "ROTC", "SEATO", "UNRRA", "USAF", "USIS", "NEA", "AARP", "AFSCME", "OAS", "IMF", "AEF",
        "USO", "NAFTA", "UCSF", "USC", "NYU", "CUNY", "SUNY", "EPA", "OSHA", "FEMA", "NOAA",
    ]

    /// Abbreviated titles, which have no vowel but are words: MR. → Mr.
    private static let titles: Set<String> = ["MR", "MRS", "MS", "DR", "ST", "JR", "SR", "LT", "SGT", "PVT",
                                              "CPL", "FT", "MT", "BLDG", "MGR", "BRIG", "BROS", "WM", "CHAS"]

    private static let smallWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "for", "of", "in", "on", "at", "to", "by", "as", "via",
        "per", "vs", "from", "with", "into", "upon",
    ]

    /// Whether `s` is written wholly in capitals: at least two capital letters and no lowercase letter.
    public static func isAllCapitals(_ s: String) -> Bool {
        var capitals = 0
        for c in s where c.isLetter {
            if c.isLowercase { return false }
            if c.isUppercase { capitals += 1 }
        }
        return capitals >= 2
    }

    /// `s` in title case when it is wholly in capitals, otherwise `s` unchanged. `keeping` adds acronyms to
    /// keep in capitals (compared in capitals). Whitespace is kept exactly.
    public static func titleCased(_ s: String, keeping: Set<String> = []) -> String {
        guard isAllCapitals(s) else { return s }
        let keep = knownAcronyms.union(keeping.map { $0.uppercased() })
        let ranges = wordRanges(s)
        var out = ""
        var cursor = s.startIndex
        var capitaliseNext = true
        for (n, r) in ranges.enumerated() {
            out += s[cursor..<r.lowerBound]
            let token = String(s[r])
            let last = n == ranges.count - 1
            out += word(token, first: capitaliseNext, last: last, keep: keep)
            capitaliseNext = token.hasSuffix(":") || token.hasSuffix("—") || token.hasSuffix("–")
                || token.hasSuffix("?") || token.hasSuffix("!") || endsSentence(token)
            cursor = r.upperBound
        }
        out += s[cursor...]
        return out
    }

    /// A token ending a sentence with a full stop, not an initial or abbreviated title (J., MR., U.S.).
    private static func endsSentence(_ token: String) -> Bool {
        var t = Substring(token)
        while let c = t.last, "\"”'’)]".contains(c) { t = t.dropLast() }
        guard t.hasSuffix(".") else { return false }
        let core = t.dropLast().filter { $0.isLetter || $0 == "." }
        return core.count > 1 && !core.contains(".") && !titles.contains(String(core))
    }

    private static func wordRanges(_ s: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start: String.Index?
        for i in s.indices {
            if s[i].isWhitespace {
                if let b = start { result.append(b..<i); start = nil }
            } else if start == nil { start = i }
        }
        if let b = start { result.append(b..<s.endIndex) }
        return result
    }

    /// One whitespace-free token: leading and trailing punctuation kept, the core cased.
    private static func word(_ token: String, first: Bool, last: Bool, keep: Set<String>) -> String {
        let chars = Array(token)
        guard let lo = chars.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let hi = chars.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return token }
        let core = String(chars[lo...hi])
        // A bracketed letter is a list label, (A) or a), not the article.
        if core.count == 1, chars[..<lo].contains("(") || chars[(hi + 1)...].contains(")") { return token }
        return String(chars[..<lo]) + cased(core, first: first, last: last, keep: keep) + String(chars[(hi + 1)...])
    }

    private static func cased(_ core: String, first: Bool, last: Bool, keep: Set<String>) -> String {
        if keep.contains(core) || core.contains("&") { return core }   // AT&T, B&O
        // Initials and dotted abbreviations: J., J.W., U.S.A.
        if core.contains("."), core.split(separator: ".").allSatisfy({ $0.count <= 2 }) { return core }
        // Slash forms of short parts (M/D, A/C); longer ones are cased part by part (AND/OR → And/Or).
        if core.contains("/") {
            let parts = core.split(separator: "/", omittingEmptySubsequences: false)
            if parts.allSatisfy({ $0.count <= 2 }) { return core }
            return parts.map { cased(String($0), first: first, last: last, keep: keep) }.joined(separator: "/")
        }
        // Hyphenated words are cased part by part (FIRST-CLASS → First-Class, AFL-CIO kept).
        if core.contains("-") || core.contains("‐") {
            let sep: Character = core.contains("-") ? "-" : "‐"
            let parts = core.split(separator: sep, omittingEmptySubsequences: false)
            // COMMANDER-IN-CHIEF → Commander-in-Chief: a small word inside is lower.
            return parts.enumerated()
                .map { cased(String($1), first: $0 == 0 && first, last: last && $0 == parts.count - 1, keep: keep) }
                .joined(separator: String(sep))
        }
        if core.contains(where: \.isNumber) { return lowerSuffixAfterDigits(core) }
        if let apostrophe = core.firstIndex(where: { $0 == "'" || $0 == "’" }) {
            let head = String(core[..<apostrophe])
            let tail = String(core[core.index(after: apostrophe)...])
            let casedHead = cased(head, first: first, last: last, keep: keep)
            // DON'T, PRESIDENT'S, WE'LL: the contraction is lower; O'BRIEN: a name, capitalised.
            let casedTail = tail.count <= 2 ? tail.lowercased() : capitalised(tail)
            return casedHead + String(core[apostrophe]) + casedTail
        }
        if titles.contains(core) { return capitalised(core) }
        if core.count >= 2, !core.contains(where: { "AEIOUY".contains($0) }), core.allSatisfy(\.isLetter) {
            return core   // no vowel: NBC, HBS, JFK
        }
        if core.count >= 2, isRomanNumeral(core) { return core }
        let lower = core.lowercased()
        if core.count == 1 {
            if core == "A" { return first || last ? "A" : "a" }
            return core   // I, and single letters such as a grade or a plan's letter
        }
        if smallWords.contains(lower), !first, !last { return lower }
        return capitalised(core)
    }

    private static func capitalised(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst().lowercased()
    }

    /// 12TH → 12th, 1960S → 1960s; other letters beside digits (B-52 parts, H.R.1234) are kept.
    private static func lowerSuffixAfterDigits(_ core: String) -> String {
        let suffixes: Set<String> = ["ST", "ND", "RD", "TH", "S"]
        guard let lastDigit = core.lastIndex(where: \.isNumber) else { return core }
        let tail = String(core[core.index(after: lastDigit)...])
        guard suffixes.contains(tail) else { return core }
        return String(core[...lastDigit]) + tail.lowercased()
    }

    private static func isRomanNumeral(_ s: String) -> Bool {
        s.range(of: "^M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$", options: .regularExpression) != nil
    }
}
