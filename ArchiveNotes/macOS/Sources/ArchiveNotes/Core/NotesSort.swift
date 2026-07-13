// NotesSort.swift — multi-level, deterministic sort for the item list (W6-S3).
// Adapted from ArchiveReader's `LibrarySort`/`ARSortDescriptor`/`SortField`
// (Core/LibraryFilter.swift:113-213), replacing the field set with the Notes columns
// (title, date, kind, quality) + relevance, and operating over `ItemSummary` (UUID identity,
// front-matter fields) instead of `ArchiveFile` (path identity, Finder tags). Per 06-viewers §4.

import Foundation

/// Sortable item-list columns. `relevance` ordering is injected at `recompute()` time (from the
/// FTS bm25 rank, W6-S4), never via the comparator — matching Reader's `SortField.relevance`.
enum NoteSortField: String, Sendable, CaseIterable, Codable {
    case title, date, kind, quality, relevance
}

/// One level of a multi-level sort (field + direction).
struct NoteSortDescriptor: Sendable, Equatable, Codable {
    var field: NoteSortField
    var ascending: Bool = true
}

/// Deterministic, nil-last, multi-level sort over `ItemSummary`. Missing keys (undated, no quality)
/// always sort LAST regardless of direction; a final title/UUID tiebreak makes the order stable.
enum NotesSort {
    /// Default: chronological, then title (mirrors `LibrarySort.default`, L124-128).
    static let `default`: [NoteSortDescriptor] = [
        NoteSortDescriptor(field: .date, ascending: true),
        NoteSortDescriptor(field: .title, ascending: true),
    ]

    static func sorted(_ items: [ItemSummary], by descriptors: [NoteSortDescriptor]) -> [ItemSummary] {
        guard !descriptors.isEmpty else { return items }
        return items.sorted { a, b in
            for d in descriptors {
                switch rank(a, b, d) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            // Stable final tiebreak: title, then UUID (total order, never `.orderedSame`).
            let t = a.title.localizedStandardCompare(b.title)
            if t != .orderedSame { return t == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func rank(_ a: ItemSummary, _ b: ItemSummary, _ d: NoteSortDescriptor) -> ComparisonResult {
        switch d.field {
        case .date:
            return nilLast(a.sortDate, b.sortDate) { dir(cmp($0, $1), d.ascending) }
        case .quality:
            return nilLast(a.quality, b.quality) { dir(cmp($0, $1), d.ascending) }
        case .kind:
            return dir(cmp(a.kind.rawValue, b.kind.rawValue), d.ascending)
        case .title:
            return dir(a.title.localizedStandardCompare(b.title), d.ascending)
        case .relevance:
            return .orderedSame   // rank ordering is injected at recompute(), not via the comparator
        }
    }

    // Apply direction only to the *value* comparison; presence (nil-last) is direction-independent.
    private static func nilLast<T>(_ x: T?, _ y: T?, _ valueCompare: (T, T) -> ComparisonResult) -> ComparisonResult {
        switch (x, y) {
        case let (xv?, yv?): return valueCompare(xv, yv)
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending   // x missing → x after y (last)
        case (_, nil): return .orderedAscending
        }
    }

    private static func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
        x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
    }

    private static func dir(_ r: ComparisonResult, _ ascending: Bool) -> ComparisonResult {
        if ascending || r == .orderedSame { return r }
        return r == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}
