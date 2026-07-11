// NotesFilter.swift — shared filter type for live filtering + smart-folder persistence
// Canonical definition: 00-overview.md §16.3 (Interface Contract)

import Foundation

/// How multiple tag filters combine.
enum TagCombine: String, Codable, Sendable {
    case all
    case any
}

/// Which item kinds to include.
enum KindFilter: String, Codable, Sendable {
    case notes
    case extracts
    case both
}

/// A single filter specification used for both live UI filtering and persisted smart-folder queries.
///
/// Smart folders store an encoded `NotesFilter` in `folders.query_json` (W2/W6).
/// All fields have sensible defaults so an empty `NotesFilter()` matches everything.
struct NotesFilter: Codable, Equatable, Sendable {
    var searchText: String = ""
    var tags: [String] = []
    var tagCombine: TagCombine = .all
    var kind: KindFilter = .both
    var qualities: Set<Int> = []
    /// Inclusive lower bound for sort-date filtering (Int matching DocumentTags.sortDate convention).
    var dateFrom: Int? = nil
    /// Inclusive upper bound for sort-date filtering.
    var dateTo: Int? = nil
    /// Scope to a specific folder (smart-folder-as-root).
    var folderId: UUID? = nil

    /// Whether this filter is effectively empty (matches everything).
    var isEmpty: Bool {
        searchText.isEmpty
            && tags.isEmpty
            && kind == .both
            && qualities.isEmpty
            && dateFrom == nil
            && dateTo == nil
            && folderId == nil
    }
}
