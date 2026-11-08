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
                !excludedPrefixes.contains { file.path == $0 || file.path.hasPrefix($0 + "/") }
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
