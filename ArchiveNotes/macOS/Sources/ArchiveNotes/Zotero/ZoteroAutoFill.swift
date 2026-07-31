import Foundation

// MARK: - CSL → front-matter mapping (00-overview §D.4)

extension ZoteroCSLItem {

    /// Authors mapped to the front-matter `authors` list: literal name when present,
    /// else "given family". Whitespace-trimmed; fully-empty names dropped.
    var mappedAuthors: [String] {
        (author ?? [])
            .map { $0.displayName.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Title mapped to the front-matter `title` (trimmed); nil when absent/empty.
    var mappedTitle: String? {
        guard let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    /// Date mapped to the SPEC-shaped front-matter `date` + `date_precision`
    /// (00-overview §7). Year is emitted verbatim (so 3-digit years like `842`
    /// survive); month/day are zero-padded — matching `GeneratedTags.machineDate`.
    ///
    /// CSL `date-parts` drive precision: `[y]`→`.year`, `[y,m]`→`.month`,
    /// `[y,m,d]`→`.day`. CSL never yields a decade, so `.decade` is never emitted.
    /// If only `issued.raw` is present, a leading 4-digit run is taken as `.year`;
    /// otherwise `(nil, nil)` (leave the note's date untouched).
    ///
    /// A day is kept only if it **exists in that month** (`GregorianDay`): this is
    /// foreign data, and `date-parts: [[1968, 2, 31]]` used to arrive here as a
    /// day-precision `1968-02-31` — the plan below writes `date`/`date_precision`
    /// straight onto the item, so `Item.normalizedDate` never sees it (W23.l4).
    /// An impossible day drops the precision to `.month`, keeping what is real.
    func mappedDate() -> (date: String?, precision: Item.DatePrecision?) {
        if let parts = issued?.dateParts?.first, let year = parts.first, year > 0 {
            var s = "\(year)"
            var precision: Item.DatePrecision = .year
            if parts.count >= 2, (1...12).contains(parts[1]) {
                s += String(format: "-%02d", parts[1])
                precision = .month
                if parts.count >= 3,
                   GregorianDay.isValidDay(year: year, month: parts[1], day: parts[2]) {
                    s += String(format: "-%02d", parts[2])
                    precision = .day
                }
            }
            return (s, precision)
        }
        // Fall back to a raw string: take the first 4-digit run as a year.
        if let raw = issued?.raw,
           let match = raw.range(of: "\\d{4}", options: .regularExpression) {
            return (String(raw[match]), .year)
        }
        return (nil, nil)
    }
}

// MARK: - Auto-fill plan

/// A front-matter field the auto-fill action can populate from Zotero.
enum AutoFillField: String, CaseIterable, Sendable, Hashable {
    case title, authors, date
}

/// The set of proposed front-matter changes from a fetched Zotero CSL item,
/// diffed against the note's current values (00-overview §D.5).
///
/// Only fields whose proposed value is non-empty **and** differs from the note's
/// current value appear in `changes`. The default selection policy is
/// **fill-empty**: empty fields are pre-selected; replacements of a non-empty
/// value are left for the user to confirm.
struct AutoFillPlan: Equatable, Sendable {

    /// One diffed field: what to show in the confirmation sheet + default state.
    struct FieldChange: Equatable, Sendable {
        let field: AutoFillField
        let currentDisplay: String
        let proposedDisplay: String
        /// True when the note already has a non-empty value for this field.
        let isReplacement: Bool
        /// Fill empty fields by default; ask before replacing a non-empty value.
        var defaultSelected: Bool { !isReplacement }
    }

    var proposedTitle: String?
    var proposedAuthors: [String]?
    var proposedDate: String?
    var proposedDatePrecision: Item.DatePrecision?
    var changes: [FieldChange]

    var isEmpty: Bool { changes.isEmpty }

    /// The fields pre-selected under the fill-empty default policy.
    var defaultSelection: Set<AutoFillField> {
        Set(changes.filter(\.defaultSelected).map(\.field))
    }

    /// Build a plan by diffing a fetched CSL item against the note's current values.
    static func make(from csl: ZoteroCSLItem, item: Item) -> AutoFillPlan {
        var changes: [FieldChange] = []

        let title = csl.mappedTitle
        if let title, title != item.title {
            changes.append(FieldChange(
                field: .title,
                currentDisplay: item.title,
                proposedDisplay: title,
                isReplacement: !item.title.isEmpty))
        }

        let authors = csl.mappedAuthors
        if !authors.isEmpty, authors != item.authors {
            changes.append(FieldChange(
                field: .authors,
                currentDisplay: item.authors.joined(separator: ", "),
                proposedDisplay: authors.joined(separator: ", "),
                isReplacement: !item.authors.isEmpty))
        }

        let (date, precision) = csl.mappedDate()
        if let date, date != item.date {
            changes.append(FieldChange(
                field: .date,
                currentDisplay: item.date ?? "",
                proposedDisplay: date,
                isReplacement: item.date != nil))
        }

        return AutoFillPlan(
            proposedTitle: title,
            proposedAuthors: authors.isEmpty ? nil : authors,
            proposedDate: date,
            proposedDatePrecision: precision,
            changes: changes)
    }

    /// Apply the selected fields to a copy of `item`. Unselected fields are
    /// untouched; `date` carries its precision. Fields absent from `changes`
    /// can never be selected, so this only ever writes genuine changes.
    func apply(selected: Set<AutoFillField>, to item: Item) -> Item {
        var out = item
        if selected.contains(.title), let title = proposedTitle {
            out.title = title
        }
        if selected.contains(.authors), let authors = proposedAuthors {
            out.authors = authors
        }
        if selected.contains(.date), let date = proposedDate {
            out.date = date
            out.datePrecision = proposedDatePrecision
        }
        return out
    }
}
