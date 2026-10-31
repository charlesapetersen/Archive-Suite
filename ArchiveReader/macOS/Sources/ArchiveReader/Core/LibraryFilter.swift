import Foundation
import ArchiveCore

// MARK: - Filtering
//
// Pure, UI-free filter + sort logic for the navigation window. Display/sort/filter only — never
// drives a write (that is TagWriter's exclusive job).

/// Read-state filter — tri-state plus "all" and an explicit "no read-state" (markers / anomalies).
enum ReadFilter: String, Sendable, CaseIterable, Codable {
    case all, read, unread, noReadState
}

/// How multiple selected subject tags combine.
enum SubjectCombine: String, Sendable, CaseIterable, Codable {
    case all   // AND — a file must carry every selected subject
    case any   // OR  — a file must carry at least one
}

/// The active filter state of the navigation window.
struct LibraryFilter: Sendable, Equatable, Codable {
    var subjects: Set<String> = []
    var subjectCombine: SubjectCombine = .all
    var qualities: Set<Int> = []      // empty = any quality
    var read: ReadFilter = .all
    /// Filename substring match (corpus-wide OCR full-text search arrives in M1.5).
    var searchText: String = ""
    /// Scope to a folder subtree (from the sidebar file tree). `nil` = the whole root.
    var pathPrefix: String? = nil
    /// Restrict the list to files whose non-standard-PDF status `.needsAttention` (unreadable or
    /// no-text-layer). The status lives in the async content index, so this dimension is applied by
    /// the model (like full-text search), not inside `matches`.
    var needsAttentionOnly: Bool = false
    /// W37: whole-year date range. A file matches when its own date OR its sent-with (covering letter)
    /// date lies inside, each tested on its own (`ArchiveCore.DateRangeFilter`); undated files never
    /// match an active range. Optional so a smart folder saved before this field still decodes.
    var dateFromYear: Int? = nil
    var dateToYear: Int? = nil
    /// W40.fix-reader-date-ambiguity: only files with two tags for one date facet, to review them. Stored
    /// optional so a smart folder or saved view state written before this field still decodes; a non-optional
    /// field makes the synthesized decoder throw, and `SavedSearchStore` would then load nothing and overwrite
    /// every saved search on its next save. Not `private`: that would make the memberwise init private too.
    /// Use `ambiguousDatesOnly`.
    var ambiguousDates: Bool? = nil
    var ambiguousDatesOnly: Bool {
        get { ambiguousDates ?? false }
        set { ambiguousDates = newValue ? true : nil }
    }

    var dateRange: DateRangeFilter? {
        dateFromYear == nil && dateToYear == nil ? nil : DateRangeFilter(fromYear: dateFromYear, toYear: dateToYear)
    }

    var isActive: Bool {
        !subjects.isEmpty || !qualities.isEmpty || read != .all || dateRange != nil
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || (pathPrefix?.isEmpty == false)
            || needsAttentionOnly || ambiguousDatesOnly
    }

    func matches(_ file: ArchiveFile) -> Bool {
        // Folder scope — match on a path-component boundary so ".../Brown" never matches ".../Brown2".
        if let pathPrefix, !pathPrefix.isEmpty {
            let dir = pathPrefix.hasSuffix("/") ? String(pathPrefix.dropLast()) : pathPrefix
            if file.path != dir, !file.path.hasPrefix(dir + "/") { return false }
        }
        // Read state
        switch read {
        case .all: break
        case .read: if file.readState != .read { return false }
        case .unread: if file.readState != .unread { return false }
        case .noReadState: if file.readState != nil { return false }
        }
        // Quality (empty set = any). Files with no quality are excluded when a level is required.
        if !qualities.isEmpty {
            guard let q = file.quality, qualities.contains(q) else { return false }
        }
        // Subjects
        if !subjects.isEmpty {
            let fileSubjects = Set(file.subjects)
            switch subjectCombine {
            case .all: if !subjects.isSubset(of: fileSubjects) { return false }
            case .any: if subjects.isDisjoint(with: fileSubjects) { return false }
            }
        }
        if ambiguousDatesOnly, !file.dateIsAmbiguous { return false }
        // Date range — either role, the same value meeting both bounds.
        if let dateRange, dateRange.matchingRoles(file.tags.dateKeysByRole).isEmpty { return false }
        // Filename text
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, file.name.range(of: q, options: .caseInsensitive) == nil { return false }
        return true
    }
}

extension LibraryFilter {
    /// "1950–1960", "from 1950", "to 1960", or nil when no date range is set.
    var dateYearsSummary: String? {
        switch (dateFromYear, dateToYear) {
        case let (a?, b?): return a == b ? String(a) : "\(a)\u{2013}\(b)"
        case let (a?, nil): return "from \(a)"
        case let (nil, b?): return "to \(b)"
        case (nil, nil): return nil
        }
    }

    /// Fold a user filter onto a base scope for "Save Current Search" / the status summary.
    /// Per-facet: user wins when set, else inherit the base; subjects = union;
    /// pathPrefix/searchText = user's if non-empty, else base's; needsAttentionOnly, ambiguousDatesOnly = OR.
    static func effective(base: LibraryFilter, user: LibraryFilter) -> LibraryFilter {
        var r = LibraryFilter()
        r.read = user.read != .all ? user.read : base.read
        r.qualities = user.qualities.isEmpty ? base.qualities : user.qualities
        r.subjects = base.subjects.union(user.subjects)
        r.subjectCombine = user.subjects.isEmpty ? base.subjectCombine : user.subjectCombine
        let us = user.searchText.trimmingCharacters(in: .whitespaces)
        r.searchText = us.isEmpty ? base.searchText : user.searchText
        let up = user.pathPrefix
        r.pathPrefix = (up == nil || up?.isEmpty == true) ? base.pathPrefix : up
        r.needsAttentionOnly = base.needsAttentionOnly || user.needsAttentionOnly
        r.ambiguousDatesOnly = base.ambiguousDatesOnly || user.ambiguousDatesOnly
        if user.dateRange != nil {
            r.dateFromYear = user.dateFromYear; r.dateToYear = user.dateToYear
        } else {
            r.dateFromYear = base.dateFromYear; r.dateToYear = base.dateToYear
        }
        return r
    }
}

// MARK: - Sorting

enum SortField: String, Sendable, CaseIterable, Codable {
    case date, name, quality, readState, fileType, subjects, relevance
}

struct ARSortDescriptor: Sendable, Equatable, Codable {
    var field: SortField
    var ascending: Bool = true
}

enum LibrarySort {
    /// Default: chronological, then filename (multi-level).
    static let `default`: [ARSortDescriptor] = [
        ARSortDescriptor(field: .date, ascending: true),
        ARSortDescriptor(field: .name, ascending: true),
    ]

    /// Multi-level, deterministic sort. Missing keys (undated, no quality, no read-state) always
    /// sort LAST regardless of direction; a final path tiebreak makes the order stable.
    ///
    /// Decorated (W40.fix-reader-list-recompute-at-size): every key is computed once per row, and each
    /// string key becomes its `localizedStandardCompare` rank from `collation`, so the n·log n
    /// comparisons compare integers. At 116k rows the comparator form spent 1–5.5 s in
    /// `localizedStandardCompare`, and in rebuilding `url.path` on every comparison that tied on the
    /// keys. The ranks persist across calls, so a tag edit or a sort change, which bring no new names,
    /// compares no strings at all; and paths are ranked only for rows that tie on every key.
    static func sorted(_ files: [ArchiveFile], by descriptors: [ARSortDescriptor]) -> [ArchiveFile] {
        guard !descriptors.isEmpty, files.count > 1 else { return files }
        let keyed = descriptors.filter { $0.field != .relevance }   // rank order is injected at recompute()

        // One Int column per descriptor; a missing facet is `Int.max`, which sorts last in either
        // direction because the direction is applied to present values only.
        var columns = [[Int]](repeating: [], count: keyed.count)
        var stringColumns: [(column: Int, values: [String?])] = []
        for (c, d) in keyed.enumerated() {
            switch d.field {
            case .date:      columns[c] = files.map { $0.sortDate ?? Int.max }
            case .quality:   columns[c] = files.map { $0.quality ?? Int.max }
            case .name:      stringColumns.append((c, files.map { $0.name }))
            case .fileType:  stringColumns.append((c, files.map { $0.fileType }))
            case .readState: stringColumns.append((c, files.map { $0.readState?.rawValue }))
            case .subjects:  stringColumns.append((c, files.map { subjectsKey($0) }))
            case .relevance: break
            }
        }
        if !stringColumns.isEmpty {
            let ranks = collation.ranks(for: stringColumns.map(\.values))
            for (k, sc) in stringColumns.enumerated() { columns[sc.column] = ranks[k] }
        }
        let ascending = keyed.map(\.ascending)
        func keyOrder(_ i: Int, _ j: Int) -> Bool? {
            for c in columns.indices {
                let x = columns[c][i], y = columns[c][j]
                if x == y { continue }
                if x == Int.max { return false }
                if y == Int.max { return true }
                return ascending[c] ? x < y : x > y
            }
            return nil
        }
        var order = Array(files.indices)
        order.sort { keyOrder($0, $1) ?? false }

        // Rows that tie on every key form contiguous runs; only their paths are ranked and compared.
        var runs: [Range<Int>] = []
        var start = 0
        for k in 1...order.count where k == order.count || keyOrder(order[start], order[k]) != nil {
            if k - start > 1 { runs.append(start..<k) }
            start = k
        }
        guard !runs.isEmpty else { return order.map { files[$0] } }
        let tied = runs.flatMap { order[$0] }
        let pathRanks = collation.ranks(for: [tied.map { Optional(files[$0].path) }])[0]
        var pathRank = [Int](repeating: 0, count: files.count)
        for (n, i) in tied.enumerated() { pathRank[i] = pathRanks[n] }
        for run in runs {
            // The row index breaks a tie between paths that collate equal, so the order stays total.
            order[run].sort { (pathRank[$0], $0) < (pathRank[$1], $1) }
        }
        return order.map { files[$0] }
    }

    /// The `localizedStandardCompare` order of every string the list has sorted, kept across sorts.
    static let collation = CollationRanks()

    /// Sort key for the File-tags column: the topical tags joined, or nil when there are none
    /// (so files with no topical tags sort last, like other missing facets).
    private static func subjectsKey(_ f: ArchiveFile) -> String? {
        let s = f.tags.topicalTags.joined(separator: ", ")
        return s.isEmpty ? nil : s
    }
}
