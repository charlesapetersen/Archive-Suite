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

    var isActive: Bool {
        !subjects.isEmpty || !qualities.isEmpty || read != .all
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || (pathPrefix?.isEmpty == false)
            || needsAttentionOnly
    }

    func matches(_ file: ArchiveFile) -> Bool {
        // Folder scope — match on a path-component boundary so ".../Brown" never matches ".../Brown2".
        if let pathPrefix, !pathPrefix.isEmpty {
            let dir = pathPrefix.hasSuffix("/") ? String(pathPrefix.dropLast()) : pathPrefix
            if file.url.path != dir, !file.url.path.hasPrefix(dir + "/") { return false }
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
        // Filename text
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, file.name.range(of: q, options: .caseInsensitive) == nil { return false }
        return true
    }
}

extension LibraryFilter {
    /// Fold a user filter onto a base scope for "Save Current Search" / the status summary.
    /// Per-facet: user wins when set, else inherit the base; subjects = union;
    /// pathPrefix/searchText = user's if non-empty, else base's; needsAttentionOnly = OR.
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
    /// sort LAST regardless of direction; a final filename/path tiebreak makes the order stable.
    static func sorted(_ files: [ArchiveFile], by descriptors: [ARSortDescriptor]) -> [ArchiveFile] {
        guard !descriptors.isEmpty else { return files }

        // Schwartzian: pre-compute expensive subjects sort keys once, not per-comparison.
        var subjectsCache = [URL: String]()
        if descriptors.contains(where: { $0.field == .subjects }) {
            subjectsCache.reserveCapacity(files.count)
            for f in files {
                if let key = subjectsKey(f) { subjectsCache[f.url] = key }
            }
        }

        return files.sorted { a, b in
            for d in descriptors {
                let r: ComparisonResult
                if d.field == .subjects {
                    r = nilLast(subjectsCache[a.url], subjectsCache[b.url]) {
                        dir($0.localizedStandardCompare($1), d.ascending)
                    }
                } else {
                    r = rank(a, b, d)
                }
                switch r {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
        }
    }

    static func rank(_ a: ArchiveFile, _ b: ArchiveFile, _ d: ARSortDescriptor) -> ComparisonResult {
        switch d.field {
        case .date:
            return nilLast(a.sortDate, b.sortDate) { dir(cmp($0, $1), d.ascending) }
        case .quality:
            return nilLast(a.quality, b.quality) { dir(cmp($0, $1), d.ascending) }
        case .name:
            return dir(a.name.localizedStandardCompare(b.name), d.ascending)
        case .fileType:
            return dir(a.fileType.localizedStandardCompare(b.fileType), d.ascending)
        case .readState:
            return nilLast(a.readState?.rawValue, b.readState?.rawValue) {
                dir($0.localizedStandardCompare($1), d.ascending)
            }
        case .subjects:
            return nilLast(subjectsKey(a), subjectsKey(b)) {
                dir($0.localizedStandardCompare($1), d.ascending)
            }
        case .relevance:
            return .orderedSame   // rank ordering is injected at recompute(), not via the comparator
        }
    }

    /// Sort key for the File-tags column: the topical tags joined, or nil when there are none
    /// (so files with no topical tags sort last, like other missing facets).
    private static func subjectsKey(_ f: ArchiveFile) -> String? {
        let s = f.tags.topicalTags.joined(separator: ", ")
        return s.isEmpty ? nil : s
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
