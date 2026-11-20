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

    /// Whether a document with `tags`, whose date rests on `evidence` (as for `dates`), carries a date a folder gave it
    /// (W49.reader-folder-date-undo): the evidence is a folder's, and the date is neither checked nor carried twice. Such a
    /// date follows the folder's: a later folder date replaces it (`dates`), and one that gives no date takes it away
    /// (`undatingDelta`). A date the user changed or checked since, or one from the file itself, is not the folder's.
    public static func folderGave(_ tags: DocumentTags, evidence: String?) -> Bool {
        guard tags.year != nil || tags.decade != nil, !tags.checkedFields.contains(.date),
              !tags.dateAmbiguities.contains(where: { $0.facet != .sentWith }) else { return false }
        return evidenceClass(evidence) == "folder"
    }

    /// The tag change that takes away a date a folder gave (`folderGave`) when the folder no longer gives one
    /// (W49.reader-folder-date-undo). Where the Reader's `record` still holds, the file goes back to the date it says the
    /// folder replaced, or to none (W49.reader-folder-date-undo-fu: a stamp's date the user had deleted stays deleted).
    /// Otherwise, where page 2's `Date evidence:` is a stamp's, the estimate's or a covering letter's (the kinds a
    /// folder's date replaces) and names the date it gave, the file goes back to that date and its `Date Uncertain`;
    /// otherwise its Year or Decade, Month, Day and `Date Uncertain` are removed. Never a check. A year the file's
    /// covering letter (`Sent With`) also gives is the file's own and stands: empty.
    public static func undatingDelta(given tags: DocumentTags, page: String?, record: FolderDateRecord? = nil) -> TagDelta {
        var restored: (date: ArchiveDate, uncertain: Bool)?
        if let record, record.holds(for: tags) {
            restored = record.replaced.flatMap { r in ArchiveDate.parse(wireValue: r.date).map { ($0, r.uncertain) } }
        } else if let page, ["stamp", "estimate", "inherited"].contains(evidenceClass(page) ?? ""),
           let last = page.components(separatedBy: "; ").last?.trimmingCharacters(in: .whitespaces),
           last.hasPrefix("gave ") {
            let gave = String(last.dropFirst("gave ".count))
            let uncertain = gave.hasSuffix(", Date Uncertain")
            let wire = uncertain ? String(gave.dropLast(", Date Uncertain".count)) : gave
            restored = ArchiveDate.parse(wireValue: wire).map { ($0, uncertain) }
        }
        if restored == nil, let year = tags.year, tags.sentWith?.year == year { return TagDelta() }
        let d = TagEditing.delta(for: .setDate(restored?.date), given: tags)
        let u = TagEditing.delta(for: .setDateUncertain(restored?.uncertain ?? false), given: tags)
        return TagDelta(add: d.add + u.add, remove: d.remove + u.remove)
    }

    /// The date a file with `tags`, whose date rests on `evidence` (as for `dates`), had before a folder dated it, for
    /// its record (W49.reader-folder-date-undo-fu): for a date a folder gave, the one its holding `record` says the
    /// folder replaced (none where Process Files gave it, as its page 2 does not say); otherwise the file's own date and
    /// `Date Uncertain`, or none.
    public static func replacedDate(_ tags: DocumentTags, evidence: String?,
                                    record: FolderDateRecord?) -> FolderDateRecord.Replaced? {
        if evidenceClass(evidence) == "folder" {
            guard let record, record.holds(for: tags), record.evidence == evidence else { return nil }
            return record.replaced
        }
        return FolderDateRecord.ownDate(tags).map { .init(date: $0.wireValue, uncertain: tags.dateUncertain) }
    }

    /// The record the Reader keeps beside a file it dated by this rule.
    public var record: FolderDateRecord? { record(replacing: nil) }

    /// The record for a file whose date before this one was `replaced` (`replacedDate`).
    public func record(replacing replaced: FolderDateRecord.Replaced?) -> FolderDateRecord? {
        inheritedDate.map {
            FolderDateRecord(date: $0.date.wireValue, uncertain: $0.uncertain, evidence: evidence, replaced: replaced)
        }
    }
}

/// What the Reader keeps beside a file it dated by a folder's confirmed date (W47.ct-folder-date-reader): the date it
/// gave (`ArchiveDate.wireValue`, "1966", "1966-03", "1960s"), whether it was uncertain, and the `Date evidence:`
/// value page 2 would carry. In `.archivesuite/item-fields.json` (`UserItemFields.dates`).
public struct FolderDateRecord: Equatable, Sendable, Codable {
    public var date: String
    public var uncertain: Bool
    public var evidence: String
    /// The date the file had before a folder first dated it, which taking the folder's dates away puts back; nil for
    /// none (W49.reader-folder-date-undo-fu).
    public var replaced: Replaced?
    /// The ledger group (Reader `AuditLedger`) that took the folder's date from the file since: Update N Documents, or
    /// an Undo or Redo Tag Change. The record then speaks for nothing until that group is reversed and the date is back,
    /// so one typed again in Finder, or put back by any other change, is the user's (W49.reader-folder-date-undo-fu).
    public var retiredBy: String?

    /// Retired: `retiredBy` is set.
    public var retired: Bool { retiredBy != nil }

    /// A date as `date` and `uncertain` are written.
    public struct Replaced: Equatable, Sendable, Codable {
        public var date: String
        public var uncertain: Bool

        public init(date: String, uncertain: Bool) { self.date = date; self.uncertain = uncertain }

        private enum CodingKeys: String, CodingKey { case date, uncertain }

        public init(from decoder: Decoder) throws {
            try decoder.refuseUnknownKeys(["date", "uncertain"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(date: try c.decode(String.self, forKey: .date), uncertain: try c.decode(Bool.self, forKey: .uncertain))
        }
    }

    public init(date: String, uncertain: Bool, evidence: String, replaced: Replaced? = nil, retiredBy: String? = nil) {
        self.date = date; self.uncertain = uncertain; self.evidence = evidence
        self.replaced = replaced; self.retiredBy = retiredBy
    }

    /// The record still describes the file: it is not retired, and the file's own date and `Date Uncertain` are those
    /// it gave. After an undo, or any later change of the date, it does not, and is ignored.
    public func holds(for tags: DocumentTags) -> Bool { !retired && carries(tags) }

    /// The file's own date and `Date Uncertain` are those the record gave, retired or not.
    public func carries(_ tags: DocumentTags) -> Bool {
        // A date tag the form cannot name (a Day with no Month, a Month beside a Decade, a Decade beside a Year) was
        // added since, in Finder, so the date is the user's (W49.reader-folder-date-undo).
        guard let own = Self.ownDate(tags), !tags.dateAmbiguities.contains(where: { $0.facet != .sentWith }),
              tags.day == nil || tags.month != nil, tags.year == nil || tags.decade == nil,
              tags.year != nil || tags.month == nil else {
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

    private enum CodingKeys: String, CodingKey { case date, uncertain, evidence, replaced, retiredBy }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["date", "uncertain", "evidence", "replaced", "retiredBy"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(date: try c.decode(String.self, forKey: .date), uncertain: try c.decode(Bool.self, forKey: .uncertain),
                  evidence: try c.decode(String.self, forKey: .evidence),
                  replaced: try c.decodeIfPresent(Replaced.self, forKey: .replaced),
                  retiredBy: try c.decodeIfPresent(String.self, forKey: .retiredBy))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(uncertain, forKey: .uncertain)
        try c.encode(evidence, forKey: .evidence)
        try c.encodeIfPresent(replaced, forKey: .replaced)
        try c.encodeIfPresent(retiredBy, forKey: .retiredBy)
    }
}
