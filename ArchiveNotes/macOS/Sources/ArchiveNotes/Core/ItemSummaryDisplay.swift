// ItemSummaryDisplay.swift — pure, deterministic rendering helpers for the item-list cells (W6-S3).
// Kept out of the view so the formatting is unit-testable without a window server. All formatting is
// locale-independent (fixed English month abbreviations), matching the app's en_US_POSIX date
// convention (SPEC; Reader W3.f6 pinned the same locale for PDF dates).

import Foundation

extension ItemSummary {
    /// Human-readable date for the Date column, derived from `date` + `datePrecision` per the SPEC
    /// facets (decade / year / month / day). `nil` when the item has no date (cell shows "—").
    var displayDate: String? {
        guard let date, !date.isEmpty else { return nil }
        switch datePrecision {
        case .decade:
            return "\(date)s"                                  // "1970" → "1970s"
        case .year, .none:
            return date                                        // "1970"
        case .month:
            let p = date.split(separator: "-")
            guard p.count >= 2, let m = Int(p[1]), let name = Self.monthName(m) else { return date }
            return "\(name) \(p[0])"                            // "1970-03" → "Mar 1970"
        case .day:
            let p = date.split(separator: "-")
            guard p.count >= 3, let m = Int(p[1]), let name = Self.monthName(m), let d = Int(p[2])
            else { return date }
            return "\(name) \(d), \(p[0])"                      // "1970-03-05" → "Mar 5, 1970"
        }
    }

    /// Quality rendered as filled/empty stars (quality of 5 max), or "—" when unrated.
    var qualityStars: String {
        guard let q = quality, q >= 1 else { return "—" }
        let filled = min(q, 5)
        return String(repeating: "★", count: filled) + String(repeating: "☆", count: 5 - filled)
    }

    /// Comma-joined subjects for the Tags column (read-only here).
    var displayTags: String {
        managedTags
            .joined(separator: ", ")
    }

    /// Distinct-source-note count for the "Sources" column (W7-S4), rendered as a plain integer for a
    /// segmented extract and **blank** when there are no note-passage sources — so a plain note or a
    /// source-less extract shows nothing rather than a distracting "0". Extracts feature this column;
    /// in a notes list every cell is naturally blank.
    var sourcesText: String { sourceNoteCount > 0 ? String(sourceNoteCount) : "" }

    /// Fixed English month abbreviations (1...12); nil for out-of-range so the caller degrades to the
    /// raw stored date rather than crashing on corrupt front-matter.
    private static func monthName(_ m: Int) -> String? {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard (1...12).contains(m) else { return nil }
        return names[m - 1]
    }
}
