import Foundation
import ArchiveCore

/// Preserves an unrecognized YAML key and its raw text for round-trip fidelity.
struct UnknownKey: Sendable, Equatable {
    let key: String
    let rawLines: [String]
}

/// The domain model for a note or extract (00-overview §3.1, §5).
/// Serialized to/from Markdown with YAML front-matter via `FrontMatterCodec`.
struct Item: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Codable { case note, extract }
    enum DatePrecision: String, Sendable, Codable { case decade, year, month, day }

    var id: UUID
    var kind: Kind
    var title: String
    var authors: [String]
    var date: String?
    var datePrecision: DatePrecision?
    var dateUncertain: Bool
    var quality: Int?
    var tags: [String]
    var zotero: [ZoteroRef]
    var roundup: Bool
    var created: Date
    var modified: Date
    var schema: Int

    var blocks: [Block]

    var unknownFrontMatter: [UnknownKey]
    /// Raw body text between the front-matter closing `---` and the first block header.
    /// nil when the body starts directly with a `<!-- block:` header (or is empty).
    var trailingBodyRaw: String?

    /// W37.dual-date: the covering letter's date (front-matter `additional_dates`, role `sent_with`).
    /// `date`/`datePrecision`/`dateUncertain` stay the item's OWN date; this is a second, separately
    /// labelled whole value, so its precision can never cross-pair with the own date's components.
    var sentWith: ArchiveDate? = nil
    /// Speculative sent-with date — independent of `dateUncertain`. Meaningless without `sentWith`.
    var sentWithUncertain: Bool = false
    /// `additional_dates` entries this build does not understand (another role, a second `sent_with`,
    /// an invalid value), kept verbatim so a save never silently drops owner-written YAML.
    var unparsedAdditionalDates: [UnknownKey] = []

    /// Chronological sort key: the item's OWN date, falling back to the sent-with date when it has none
    /// (owner, 2026-10-05; `sortsBySentWith` labels the fallback). nil when neither exists.
    var sortDate: Int? { ownSortDate ?? sentWith?.sortKey }

    /// The own date's sort key alone (no sent-with fallback).
    var ownSortDate: Int? { Self.sortKey(date: date, precision: datePrecision) }

    /// True when `sortDate` comes from the sent-with fallback.
    var sortsBySentWith: Bool { ownSortDate == nil && sentWith != nil }

    /// Each role's sort key, for a date filter that matches either date (`DateRangeFilter`).
    var dateKeysByRole: [DateRole: Int] {
        Self.dateKeysByRole(own: ownSortDate, sentWith: sentWith)
    }

    static func dateKeysByRole(own: Int?, sentWith: ArchiveDate?) -> [DateRole: Int] {
        var keys: [DateRole: Int] = [:]
        if let own { keys[.own] = own }
        if let sentWith { keys[.sentWith] = sentWith.sortKey }
        return keys
    }

    /// Chronological sort key of a front-matter `(date, precision)` pair. Parses the string to the
    /// precision it claims, then defers the SPEC arithmetic to the shared
    /// `ArchiveCore.DocumentTags.sortDateKey` so Notes' key can never drift from the Reader's
    /// (`year * 10_000 + month * 100 + day`; decade → `decade * 10_000`; nil if no usable date). The
    /// string-parsing/guards below are Notes-specific input handling — a component too coarse for its
    /// precision yields nil, matching the prior behavior exactly.
    static func sortKey(date: String?, precision datePrecision: DatePrecision?) -> Int? {
        guard let date else { return nil }
        switch datePrecision {
        case .decade:
            return DocumentTags.sortDateKey(year: nil, month: nil, day: nil, decade: Int(date))
        case .year, .none:
            return DocumentTags.sortDateKey(year: Int(date), month: nil, day: nil, decade: nil)
        case .month:
            let parts = date.split(separator: "-")
            guard parts.count >= 2,
                  let yr = Int(parts[0]), let mo = Int(parts[1]) else { return nil }
            return DocumentTags.sortDateKey(year: yr, month: mo, day: nil, decade: nil)
        case .day:
            let parts = date.split(separator: "-")
            guard parts.count >= 3,
                  let yr = Int(parts[0]), let mo = Int(parts[1]), let dy = Int(parts[2]) else { return nil }
            return DocumentTags.sortDateKey(year: yr, month: mo, day: dy, decade: nil)
        }
    }
}

extension Item {
    /// The Core whole-value date a normalized front-matter `(date, precision)` pair names, or nil when
    /// the pair is not self-consistent or outside `ArchiveDate`'s supported 3–4 digit year range.
    /// Notes stores a decade as its start year ("1950", precision `decade`), as for the own date.
    static func archiveDate(_ date: String?, precision: DatePrecision?) -> ArchiveDate? {
        guard let date, let precision,
              normalizedDate(date, precision: precision) == (date, precision) else { return nil }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return nil }
        switch precision {
        case .decade: return ArchiveDate(decade: year)
        case .year:   return parts.count == 1 ? ArchiveDate(year: year) : nil
        case .month:  return parts.count == 2 ? ArchiveDate(year: year, month: parts[1]) : nil
        case .day:    return parts.count == 3 ? ArchiveDate(year: year, month: parts[1], day: parts[2]) : nil
        }
    }

    /// The front-matter `(date, precision)` spelling of a Core date — the inverse of `archiveDate`.
    static func frontMatterDate(_ value: ArchiveDate) -> (date: String, precision: DatePrecision) {
        switch value.precision {
        case .decade: return (String(value.year), .decade)
        case .year:   return (value.wireValue, .year)
        case .month:  return (value.wireValue, .month)
        case .day:    return (value.wireValue, .day)
        }
    }

    /// Normalize a `(date, precision)` pair into a *self-consistent* one before it is written to
    /// front-matter (W6-S7 date UI). The invariant this enforces: the `date` string always carries
    /// exactly the components its `datePrecision` claims, so `sortDate`/`displayDate` never see a
    /// string too coarse for the precision (which would silently nil the sort key or drop the item to
    /// the end of a chronological list). Rules:
    ///   * no usable 4-digit-ish year ⟹ `(nil, nil)` (undated — the cell shows "—");
    ///   * `decade` floors the year to its decade ("1975" ⟹ "1970", rendered "1970s");
    ///   * `month`/`day` **downgrade** to the finest precision the string actually specifies when a
    ///     lower field is missing/out-of-range (e.g. `day` precision with no day ⟹ `month`; no month
    ///     ⟹ `year`). Components are zero-padded ("1970-03-05") to match the SPEC date convention.
    ///   * a day the chosen month cannot have is **impossible, not merely out of range**, and
    ///     downgrades the same way ("2026-02-31" ⟹ "2026-02", month precision) — W23.l4. Coarsening
    ///     rather than clamping is deliberate: clamping to Feb 28 would assert a day the source never
    ///     said, while month precision states exactly what is known.
    /// Pure + locale-independent; the single source of truth for the write path and unit-tested directly.
    static func normalizedDate(_ date: String?,
                               precision: DatePrecision?) -> (date: String?, precision: DatePrecision?) {
        guard let raw = date?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return (nil, nil) }
        let parts = raw.split(separator: "-").map(String.init)
        guard let year = parts.first.flatMap({ Int($0) }), year > 0 else { return (nil, nil) }
        let yr = String(year)
        let month = parts.count >= 2 ? Int(parts[1]) : nil
        let day = parts.count >= 3 ? Int(parts[2]) : nil
        let validMonth = month.flatMap { (1...12).contains($0) ? $0 : nil }
        // The day is judged against the (year, month) it sits in — never independently as 1…31, which
        // is what let `2026-02-31` through as a day-precision date (W23.l4). No month ⟹ no day.
        let validDay: Int? = day.flatMap { d in
            guard let m = validMonth,
                  GregorianDay.isValidDay(year: year, month: m, day: d) else { return nil }
            return d
        }

        switch precision ?? .year {
        case .decade:
            return (String((year / 10) * 10), .decade)
        case .year:
            return (yr, .year)
        case .month:
            if let m = validMonth { return ("\(yr)-\(pad2(m))", .month) }
            return (yr, .year)
        case .day:
            if let m = validMonth, let d = validDay { return ("\(yr)-\(pad2(m))-\(pad2(d))", .day) }
            if let m = validMonth { return ("\(yr)-\(pad2(m))", .month) }
            return (yr, .year)
        }
    }

    /// Zero-pad a 1–2 digit component to two digits ("3" → "03"), locale-independent.
    private static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
