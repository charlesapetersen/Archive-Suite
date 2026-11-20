import Foundation

// MARK: - A confirmed folder date dates documents already written (W47.ct-folder-date-reader)
//
// Process Files applies the folder-date rule as it tags (W47.ct-folder-date). The usual way a folder date becomes
// confirmed is the Reader, after the documents are written, so the Reader offers the same rule then. This is the pure
// half: which documents take the date, the tag change, and the evidence line. The Reader cannot rewrite page 2, so the
// evidence is kept beside the files (`UserItemFields.dates`), recorded with the date it gave and trusted only while the
// file still carries that date: undoing the tags, or any later edit of the date, leaves it inert without a second write.
// `SPEC/containers.md` §The folder-date rule.

extension ContainerFolderDate {
    /// The date a document takes, as an `ArchiveDate` (a year with the folder's month, or a decade); nil for 20 years
    /// or more.
    public var inheritedDate: (date: ArchiveDate, uncertain: Bool)? {
        switch inherited {
        case let .year(y, month, uncertain): return ArchiveDate(year: y, month: month).map { ($0, uncertain) }
        case let .decade(d): return ArchiveDate(decade: d).map { ($0, true) }
        case nil: return nil
        }
    }

    /// The `Date evidence:` value Process Files writes for this date (`SPEC/tag-format.md` §Date evidence):
    /// `folder; from <the run's first file>; "<the folder's date>"; gave <date>[, Date Uncertain]`, one line, the quote
    /// cut to 60 characters.
    public var evidence: String {
        var parts = ["folder", "from " + Self.evidenceSafe(start.isEmpty ? "the folder" : start, limit: 80)]
        let quote = Self.evidenceSafe(text, limit: 60)
        if !quote.isEmpty { parts.append("\"" + quote + "\"") }
        if let (date, uncertain) = inheritedDate { parts.append(Self.evidenceGave(date: date, uncertain: uncertain)) }
        return parts.joined(separator: "; ")
    }

    /// The last part of a `Date evidence:` value (W49.reader-finder-year-stands, W49.reader-finder-month-stands): the
    /// date the file was given with the evidence, as its wire value, and whether `Date Uncertain` went with it:
    /// `gave 1958-03-02`, `gave 1960s, Date Uncertain`.
    public static func evidenceGave(date: ArchiveDate, uncertain: Bool) -> String {
        "gave " + date.wireValue + (uncertain ? ", Date Uncertain" : "")
    }

    /// The last part for the date `tags` carry; empty for no date, a date the tags hold ambiguously (two Years, two
    /// Months), or one with a date tag the form cannot name (a Day with no Month, a Decade beside a Year), which no
    /// written line gives, so a Day or Decade added in Finder reads as the user's.
    public static func evidenceGave(_ tags: DocumentTags) -> String {
        guard let own = FolderDateRecord.ownDate(tags),
              !tags.dateAmbiguities.contains(where: { $0.facet != .sentWith }),
              tags.day == nil || tags.month != nil, tags.year == nil || tags.decade == nil else { return "" }
        return evidenceGave(date: own, uncertain: tags.dateUncertain)
    }

    /// Whether a `Date evidence:` value describes the date `tags` carry: its last part names the Year (or Decade),
    /// Month, Day and `Date Uncertain` the file holds. A value without that part, or naming another date, does not: the
    /// date was changed since (in Finder, which records nothing), so it is the user's.
    public static func evidenceDescribes(_ evidence: String?, tags: DocumentTags) -> Bool {
        guard let last = evidence?.components(separatedBy: "; ").last?.trimmingCharacters(in: .whitespaces) else {
            return false
        }
        let gave = evidenceGave(tags)
        return !gave.isEmpty && last == gave
    }

    /// As the dating route's `headerSafe`: control characters and runs of white space become one space, the middle dot
    /// a comma, and a value over `limit` is cut with an ellipsis.
    static func evidenceSafe(_ s: String, limit: Int) -> String {
        let flat = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            ? " " : String($0) }.joined()
            .replacingOccurrences(of: "\u{00B7}", with: ",")
        let one = flat.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return one.count > limit ? String(one.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : one
    }

    /// The class of a `Date evidence:` value: its first `;` part ("image", "stamp", "estimate", "inherited",
    /// "folder"); nil for none.
    public static func evidenceClass(_ evidence: String?) -> String? {
        guard let first = evidence?.split(separator: ";", maxSplits: 1).first else { return nil }
        let c = first.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? nil : c
    }

    /// Whether a document with `tags`, whose date rests on `evidence` (the Reader's record where it is still the
    /// file's date, else page 2's line), takes this date. As the dating route's step 3b: a document with no date takes
    /// it, a document with no text included; a date from a stamp, the neighbour estimate or a folder gives way to it; a
    /// date with no evidence line (the document's own text, or typed by hand) or read off the page image stands, and
    /// so does a covering letter's year, except where it is the folder's own single year. A checked date is the
    /// user's and is never replaced, nor is a date the file carries twice (which one to replace is unclear).
    public func dates(_ tags: DocumentTags, evidence: String?) -> Bool {
        guard let got = inherited, !tags.checkedFields.contains(.date),
              !tags.dateAmbiguities.contains(where: { $0.facet != .sentWith }) else { return false }
        guard tags.year != nil || tags.decade != nil else { return true }
        switch Self.evidenceClass(evidence) {
        case "stamp", "estimate", "folder": return true
        case "inherited":
            if case .year(let y, _, false) = got, tags.decade == nil, y == tags.year { return true }
            return false
        default: return false
        }
    }

    /// The tag change that gives a document with `tags` this date: its Year (or Decade) and Month, no Day, and
    /// `Date Uncertain` as the rule says. Names only the date tokens the file holds, as the Inspector's date edit does;
    /// never a check (`TagEditing.delta`, not `userDelta`). Empty when the file already reads so; nil for no date.
    public func delta(given tags: DocumentTags) -> TagDelta? {
        guard let (date, uncertain) = inheritedDate else { return nil }
        let d = TagEditing.delta(for: .setDate(date), given: tags)
        let u = TagEditing.delta(for: .setDateUncertain(uncertain), given: tags)
        return TagDelta(add: d.add + u.add, remove: d.remove + u.remove)
    }

    /// The record the Reader keeps beside a file it dated by this rule.
    public var record: FolderDateRecord? {
        inheritedDate.map { FolderDateRecord(date: $0.date.wireValue, uncertain: $0.uncertain, evidence: evidence) }
    }
}

/// What the Reader keeps beside a file it dated by a folder's confirmed date (W47.ct-folder-date-reader): the date it
/// gave (`ArchiveDate.wireValue`, "1966", "1966-03", "1960s"), whether it was uncertain, and the `Date evidence:`
/// value page 2 would carry. In `.archivesuite/item-fields.json` (`UserItemFields.dates`).
public struct FolderDateRecord: Equatable, Sendable, Codable {
    public var date: String
    public var uncertain: Bool
    public var evidence: String

    public init(date: String, uncertain: Bool, evidence: String) {
        self.date = date; self.uncertain = uncertain; self.evidence = evidence
    }

    /// The record still describes the file: its own date and `Date Uncertain` are those it gave. After an undo, or any
    /// later change of the date, it does not, and is ignored.
    public func holds(for tags: DocumentTags) -> Bool {
        guard let own = Self.ownDate(tags), !tags.dateAmbiguities.contains(where: { $0.facet != .sentWith }) else {
            return false
        }
        return own.wireValue == date && tags.dateUncertain == uncertain
    }

    /// The evidence a file's date rests on: this record's where it still holds, else page 2's line where it still
    /// names the file's date and `Date Uncertain` (W49.reader-finder-year-stands, W49.reader-finder-month-stands); nil
    /// otherwise, so a year, month, day or `Date Uncertain` changed in Finder is the user's and stands.
    public static func evidence(_ record: FolderDateRecord?, page: String?, tags: DocumentTags) -> String? {
        if let record, record.holds(for: tags) { return record.evidence }
        return ContainerFolderDate.evidenceDescribes(page, tags: tags) ? page : nil
    }

    /// The item's own date as its tags give it; a Year wins over a Decade.
    static func ownDate(_ tags: DocumentTags) -> ArchiveDate? {
        if let y = tags.year { return ArchiveDate(year: y, month: tags.month?.number, day: tags.month == nil ? nil : tags.day) }
        if let d = tags.decade { return ArchiveDate(decade: d) }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case date, uncertain, evidence }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["date", "uncertain", "evidence"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(date: try c.decode(String.self, forKey: .date), uncertain: try c.decode(Bool.self, forKey: .uncertain),
                  evidence: try c.decode(String.self, forKey: .evidence))
    }
}
