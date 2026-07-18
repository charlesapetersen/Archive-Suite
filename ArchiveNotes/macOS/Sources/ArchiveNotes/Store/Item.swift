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

    /// Chronological sort key. Parses the `date` string to the precision `datePrecision` claims, then
    /// defers the SPEC arithmetic to the shared `ArchiveCore.DocumentTags.sortDateKey` so Notes' key can
    /// never drift from the Reader's (`year * 10_000 + month * 100 + day`; decade → `decade * 10_000`;
    /// nil if no usable date). The string-parsing/guards below are Notes-specific input handling — a
    /// component too coarse for its precision yields nil, matching the prior behavior exactly.
    var sortDate: Int? {
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
        let validDay = day.flatMap { (1...31).contains($0) ? $0 : nil }

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
