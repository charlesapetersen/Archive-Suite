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

/// The quality levels a document can carry: `SPEC/tag-format.md` writes only `Q1`–`Q3`, and unrated is no tag.
/// The filter bar, the Inspector, the list's Quality pop-up and the Advanced Search form all offer this list, so
/// they cannot drift apart again (W40.reader-quality-levels: the form offered 1–5).
enum QualityLevels {
    static let all = [1, 2, 3]
}

/// The active filter state of the navigation window.
struct LibraryFilter: Sendable, Equatable, Codable {
    /// The tag filter: a file must carry every one of them. Matching any of several tags is an Advanced Search
    /// rule, not a filter-bar choice (owner, walkthrough 2026-11-13, W40.reader-tag-any-drop, as for Notes).
    var subjects: Set<String> = []
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
    /// W37: whole-year date range. A file matches when one of the dates `dateRangeRoles` names lies inside, each
    /// tested on its own (`ArchiveCore.DateRangeFilter`); undated files never match an active range. Optional so a
    /// smart folder saved before this field still decodes.
    var dateFromYear: Int? = nil
    var dateToYear: Int? = nil
    /// Which date the year range tests (W40.suite-date-design): the document's own date unless the user also asks
    /// for the sent-with date. `nil` is a filter saved before this field, when the range tested either date, so a
    /// smart folder keeps what it meant. Use `dateRangeRoles`.
    var dateRangeRole: DateRoleChoice? = .own
    var dateRangeRoles: DateRoleChoice {
        get { dateRangeRole ?? .either }
        set { dateRangeRole = newValue }
    }
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
    /// W44.reocr-reader: only files flagged `OCR Poor` (`DocumentTags.hasPoorOCR`), to deal with them in a batch.
    /// Optional for the same reason as `ambiguousDates`. Use `poorOCROnly`.
    var poorOCR: Bool? = nil
    var poorOCROnly: Bool {
        get { poorOCR ?? false }
        set { poorOCR = newValue ? true : nil }
    }

    var dateRange: DateRangeFilter? {
        dateFromYear == nil && dateToYear == nil ? nil : DateRangeFilter(fromYear: dateFromYear, toYear: dateToYear)
    }

    /// The tag filter by tag identity (W40.fix-tags-case-insensitive): tags that differ only in case are one
    /// tag, so "Lincoln" is in a filter holding "lincoln", and adding or removing one takes every case of it.
    func hasSubject(_ tag: String) -> Bool { subjects.contains { isSameTag($0, tag) } }
    mutating func insertSubject(_ tag: String) { if !hasSubject(tag) { subjects.insert(tag) } }
    mutating func removeSubject(_ tag: String) { subjects = subjects.filter { !isSameTag($0, tag) } }

    var isActive: Bool {
        !subjects.isEmpty || !qualities.isEmpty || read != .all || dateRange != nil
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || (pathPrefix?.isEmpty == false)
            || needsAttentionOnly || ambiguousDatesOnly || poorOCROnly
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
        // Subjects, every one of them, by tag identity: "lincoln" in the filter matches a file's "Lincoln".
        if !subjects.allSatisfy(file.hasSubject) { return false }
        if ambiguousDatesOnly, !file.dateIsAmbiguous { return false }
        if poorOCROnly, !file.tags.hasPoorOCR { return false }
        // Date range — the chosen roles, the same value meeting both bounds.
        if let dateRange, !dateRange.matchingRoles(file.tags.dateKeysByRole).contains(where: dateRangeRoles.roles.contains) {
            return false
        }
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
}

// MARK: - Sorting

enum SortField: String, Sendable, CaseIterable, Codable {
    case date, name, quality, readState, fileType, subjects, relevance
    /// The ⚑ and ⚠︎ columns (W40.fix-reader-columns). Neither is on the file: they come from `SortMarks`.
    case flag, attention
}

/// The two sort keys the rows do not carry: which paths are flagged (`FlagStore`) and which need attention
/// (the content index's format status). Ascending puts the marked rows first.
struct SortMarks: Sendable {
    var flagged: Set<String> = []
    var needsAttention: Set<String> = []
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
    static func sorted(_ files: [ArchiveFile], by descriptors: [ARSortDescriptor],
                       marks: SortMarks = SortMarks()) -> [ArchiveFile] {
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
            // 0 or 1, never `Int.max`: an unmarked row is a value, so descending puts it first.
            case .flag:      columns[c] = files.map { marks.flagged.contains($0.path) ? 0 : 1 }
            case .attention: columns[c] = files.map { marks.needsAttention.contains($0.path) ? 0 : 1 }
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

    /// Whether `sorted(_:by:marks:)` puts `a` before `b`, worked out from the two rows alone: the same keys in
    /// the same order, strings by `localizedStandardCompare` (which is the order of their collation ranks),
    /// a missing key last in either direction, then the paths. Rows it calls equal (paths that collate equal)
    /// may stand either way round. For placing a few changed rows without sorting every row again
    /// (W40.fix-reader-change-incremental); `LibrarySortTests` holds it to `sorted`.
    static func before(_ a: ArchiveFile, _ b: ArchiveFile, by descriptors: [ARSortDescriptor],
                       marks: SortMarks = SortMarks()) -> Bool {
        enum Key { case int(Int), string(String), missing }
        func key(_ f: ArchiveFile, _ field: SortField) -> Key {
            func int(_ v: Int?) -> Key { v.map(Key.int) ?? .missing }
            func string(_ v: String?) -> Key { v.map(Key.string) ?? .missing }
            switch field {
            case .date:      return int(f.sortDate)
            case .quality:   return int(f.quality)
            case .name:      return string(f.name)
            case .fileType:  return string(f.fileType)
            case .readState: return string(f.readState?.rawValue)
            case .subjects:  return string(subjectsKey(f))
            case .flag:      return .int(marks.flagged.contains(f.path) ? 0 : 1)
            case .attention: return .int(marks.needsAttention.contains(f.path) ? 0 : 1)
            case .relevance: return .missing
            }
        }
        for d in descriptors where d.field != .relevance {
            let order: ComparisonResult
            switch (key(a, d.field), key(b, d.field)) {
            case (.missing, .missing): continue
            case (.missing, _): return false
            case (_, .missing): return true
            case let (.int(x), .int(y)): order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case let (.string(x), .string(y)): order = x.localizedStandardCompare(y)
            default: continue
            }
            if order == .orderedSame { continue }
            return d.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        // With no keys `sorted` keeps the input order, which is the library's: the paths, as here.
        return a.path.localizedStandardCompare(b.path) == .orderedAscending
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
