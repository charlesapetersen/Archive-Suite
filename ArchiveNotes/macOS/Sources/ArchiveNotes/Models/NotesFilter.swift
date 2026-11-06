// NotesFilter.swift — the filter bar's state (smart folders store `NotesAdvancedSearch` rules since
// W40.notes-advanced-search; `NotesAdvancedSearch(filter:keyword:)` turns this into them)
// Canonical definition: 00-overview.md §16.3 (Interface Contract)

import Foundation
import ArchiveCore

/// How multiple tag filters combine.
enum TagCombine: String, Codable, Sendable {
    case all
    case any
}

/// Which item kinds to include.
enum KindFilter: String, Codable, Sendable {
    case notes
    case extracts
    case all
}

/// The per-window filter bar's state. A smart folder stores rules instead (`NotesAdvancedSearch`).
/// All fields have sensible defaults so an empty `NotesFilter()` matches everything.
struct NotesFilter: Codable, Equatable, Sendable {
    var searchText: String = ""
    var tags: [String] = []
    var tagCombine: TagCombine = .all
    var kind: KindFilter = .all
    var qualities: Set<Int> = []
    /// Inclusive lower bound for sort-date filtering (Int matching DocumentTags.sortDate convention).
    var dateFrom: Int? = nil
    /// Inclusive upper bound for sort-date filtering.
    var dateTo: Int? = nil
    /// Scope to a specific folder (smart-folder-as-root).
    var folderId: UUID? = nil
    /// nil = any; true = round-up notes; false = other items.
    var roundup: Bool? = nil

    /// The bounds as Core's either-role range predicate (`DateRangeFilter`).
    var dateRange: DateRangeFilter { DateRangeFilter(lower: dateFrom, upper: dateTo) }

    /// Which date roles of `item` lie inside the date bounds — empty when unbounded or none does.
    /// Lets a caller say which date matched (the item is still listed once).
    func matchingDateRoles(_ item: ItemSummary) -> [DateRole] {
        dateRange.isUnbounded ? [] : dateRange.matchingRoles(item.dateKeysByRole)
    }

    /// Whether this filter is effectively empty (matches everything).
    var isEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
            && tags.isEmpty
            && kind == .all
            && qualities.isEmpty
            && dateFrom == nil
            && dateTo == nil
            && folderId == nil
            && roundup == nil
    }

    /// Whether this filter narrows anything (the inverse of `isEmpty`).
    var isActive: Bool { !isEmpty }

    /// Does `item` pass this filter? Mirrors Reader's `LibraryFilter.matches`
    /// (`Core/LibraryFilter.swift:44-72`) over `ItemSummary` + front-matter facets. Folder scope is a
    /// **graph membership** test, not a path prefix: the caller resolves `folderId` → the subtree's
    /// item ids (`OrganizationStore.subtreeItemIDs`) once per recompute and passes it as `folderItemIDs`.
    ///
    /// Pure + `Sendable`-safe (no store access). `searchText` is a **title substring** here; live keyword
    /// search runs through FTS in the navigation model instead (06-viewers §4).
    func matches(_ item: ItemSummary, folderItemIDs: Set<UUID>?) -> Bool {
        if let roundup, item.roundup != roundup { return false }
        // Folder scope — membership in the folder's subtree (graph, not path prefix).
        if folderId != nil {
            guard let folderItemIDs, folderItemIDs.contains(item.id) else { return false }
        }
        // Kind.
        switch kind {
        case .all:     break
        case .notes:    if item.kind != .note    { return false }
        case .extracts: if item.kind != .extract { return false }
        }
        // Quality (empty set = any). Items with no quality are excluded when a level is required.
        if !qualities.isEmpty {
            guard let q = item.quality, qualities.contains(q) else { return false }
        }
        // Date range over the SPEC sort key (year*10000 + month*100 + day), matching EITHER the item's
        // own date or its sent-with date (W37.dual-date, owner 2026-10-05). Each value is tested on its
        // own — both bounds must hold for the SAME value, so own 1950 + sent 1970 never matches
        // 1960–1965. Undated items are excluded whenever any bound is set.
        if !dateRange.isUnbounded, dateRange.matchingRoles(item.dateKeysByRole).isEmpty { return false }
        // Tags (managed tokens) — ALL (subset) or ANY (intersection). Exact-token match, mirroring
        // Reader's subject set logic; the filter bar supplies canonical tokens.
        if !tags.isEmpty {
            let itemTags = Set(item.managedTags)
            let wanted = Set(tags)
            switch tagCombine {
            case .all: if !wanted.isSubset(of: itemTags)   { return false }
            case .any: if wanted.isDisjoint(with: itemTags) { return false }
            }
        }
        // Title substring (durable keyword; case-insensitive).
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, item.title.range(of: q, options: .caseInsensitive) == nil { return false }
        return true
    }
}

extension NotesFilter {
    /// Tolerant decode: every key is optional-with-default, so a smart folder persisted by an older
    /// build (before a field existed) still decodes rather than throwing. In an extension so the
    /// synthesized memberwise initializer is preserved; `encode(to:)` stays synthesized. Mirrors
    /// `LibraryFilter.init(from:)` (`Core/LibraryFilter.swift:80-91`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            searchText:  try c.decodeIfPresent(String.self,      forKey: .searchText)  ?? "",
            tags:        try c.decodeIfPresent([String].self,    forKey: .tags)        ?? [],
            tagCombine:  try c.decodeIfPresent(TagCombine.self,  forKey: .tagCombine)  ?? .all,
            kind:        try c.decodeIfPresent(KindFilter.self,  forKey: .kind)        ?? .all,
            qualities:   try c.decodeIfPresent(Set<Int>.self,    forKey: .qualities)   ?? [],
            dateFrom:    try c.decodeIfPresent(Int.self,         forKey: .dateFrom),
            dateTo:      try c.decodeIfPresent(Int.self,         forKey: .dateTo),
            folderId:    try c.decodeIfPresent(UUID.self,        forKey: .folderId),
            roundup:     try c.decodeIfPresent(Bool.self,        forKey: .roundup)
        )
    }
}
