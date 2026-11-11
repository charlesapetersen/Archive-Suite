import Foundation
import ArchiveCore

/// Immutable, display-only work. It never reads disk, chooses write targets, or changes Finder tags.
struct LibraryPresentation: Sendable {
    let universe: [ArchiveFile]
    let displayed: [ArchiveFile]
    let ambiguousCount: Int
    let duplicatedNames: Set<String>

    struct Input: Sendable {
        let files: [ArchiveFile]
        let excludedPrefixes: [String]
        let matches: @Sendable (ArchiveFile) -> Bool
        let sort: [ARSortDescriptor]
        let marks: SortMarks
        let rank: [String: Int]?

        func build() -> LibraryPresentation {
            let universe = excludedPrefixes.isEmpty ? files : files.filter { file in
                !LibraryPresentation.isExcluded(file.path, by: excludedPrefixes)
            }
            let base = universe.filter(matches)
            let rows: [ArchiveFile]
            if let rank, sort.first?.field == .relevance {
                rows = base.sorted { (rank[$0.path] ?? Int.max) < (rank[$1.path] ?? Int.max) }
            } else { rows = LibrarySort.sorted(base, by: sort, marks: marks) }
            return LibraryPresentation(universe: universe, displayed: rows,
                ambiguousCount: universe.reduce(0) { $0 + ($1.dateIsAmbiguous ? 1 : 0) },
                duplicatedNames: DuplicateNames.duplicatedNames(in: rows))
        }
    }

    /// Whether `path` is in one of the excluded folders (absolute prefixes).
    static func isExcluded(_ path: String, by prefixes: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Whether `build()` lists `a` before `b`: the relevance rank when the list sorts by it, else
    /// `LibrarySort.before`. A patched row goes where this puts it (W40.fix-reader-change-incremental).
    static func listedBefore(_ a: ArchiveFile, _ b: ArchiveFile, sort: [ARSortDescriptor], marks: SortMarks,
                             rank: [String: Int]?) -> Bool {
        if let rank, sort.first?.field == .relevance {
            return (rank[a.path] ?? Int.max) < (rank[b.path] ?? Int.max)
        }
        return LibrarySort.before(a, b, by: sort, marks: marks)
    }

    static func subjectSpellings(_ files: [ArchiveFile]) -> [String] {
        tagCounts(files.lazy.map(\.subjects)).map(\.tag)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    struct Refresh: Sendable {
        let presentation: LibraryPresentation
        let subjectsSignature: Int
        let matchSignature: Int
        let spellings: [String]?

        static func prepare(_ input: Input, previousSubjects: Int) -> Refresh? {
            guard !Task.isCancelled else { return nil }
            let ss = LibraryChangeSignature.subjects(input.files)
            let ms = LibraryChangeSignature.matchFacets(input.files)
            guard !Task.isCancelled else { return nil }
            let spellings = ss == previousSubjects ? nil : subjectSpellings(input.files)
            guard !Task.isCancelled else { return nil }
            let presentation = input.build()
            guard !Task.isCancelled else { return nil }
            return Refresh(presentation: presentation, subjectsSignature: ss, matchSignature: ms, spellings: spellings)
        }
    }
}
