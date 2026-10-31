import XCTest
@testable import ArchiveReader
import ArchiveCore

/// `LibrarySort.sorted` is decorated with cached collation ranks (W40.fix-reader-list-recompute-at-size).
/// These pin it to the comparator it replaced: the same order for every field, direction and missing
/// facet, across repeated calls that grow, reuse and reset the rank cache.
final class LibrarySortDecoratedTests: XCTestCase {

    // Names chosen to collate equal in pairs (case, zero padding, width) and to need numeric order.
    private let names = ["file1.pdf", "file01.pdf", "File1.pdf", "file2.pdf", "file10.pdf", "file9.pdf",
                         "Émile.pdf", "emile.pdf", "zeta.pdf", "Alpha.pdf", "alpha.pdf", "beta 3.pdf",
                         "beta 20.pdf", "１file.pdf", "1file.pdf", "_x.pdf", "x.pdf"]
    private let tagPool = ["Correspondence", "Budget", "Treasury", "budget", "Memo 2", "Memo 10"]

    private func randomFiles(_ n: Int, seed: UInt64) -> [ArchiveFile] {
        var rng = SeededGenerator(seed: seed)
        return (0..<n).map { i in
            let name = names.randomElement(using: &rng)!
            var raw: [String] = []
            if Bool.random(using: &rng) { raw.append(["Read", "Unread"].randomElement(using: &rng)!) }
            if Int.random(in: 0..<3, using: &rng) > 0 { raw.append(String(Int.random(in: 1950...1953, using: &rng))) }
            if Bool.random(using: &rng) { raw.append("Q\(Int.random(in: 1...3, using: &rng))") }
            for t in tagPool where Int.random(in: 0..<4, using: &rng) == 0 { raw.append(t) }
            // A distinct folder per row keeps paths from collating equal, which the old comparator left
            // to an unstable sort and so has no reference order.
            return ArchiveFile(url: URL(fileURLWithPath: "/corpus/f\(i)/\(name)"), name: name,
                               fileType: ["PDF", "pdf", "JPEG"].randomElement(using: &rng)!,
                               tags: DocumentTags.parse(raw: raw, labelNumber: nil), contentModified: nil)
        }
    }

    func testMatchesTheComparatorItReplaced() {
        let fields: [SortField] = [.date, .name, .quality, .readState, .fileType, .subjects, .relevance]
        var rng = SeededGenerator(seed: 7)
        for round in 0..<60 {
            let files = randomFiles(Int.random(in: 0...300, using: &rng), seed: UInt64(round))
            let depth = Int.random(in: 1...3, using: &rng)
            let descriptors = (0..<depth).map { _ in
                ARSortDescriptor(field: fields.randomElement(using: &rng)!, ascending: Bool.random(using: &rng))
            }
            XCTAssertEqual(LibrarySort.sorted(files, by: descriptors).map(\.url.path),
                           Self.reference(files, by: descriptors).map(\.url.path),
                           "round \(round): \(descriptors)")
        }
    }

    func testDefaultSortAfterASingleTagEditAndARename() {
        var files = randomFiles(500, seed: 99)
        XCTAssertEqual(LibrarySort.sorted(files, by: LibrarySort.default).map(\.url.path),
                       Self.reference(files, by: LibrarySort.default).map(\.url.path))
        let f = files[17]
        files[17] = ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                                tags: DocumentTags.parse(raw: ["1949", "Read"], labelNumber: nil), contentModified: nil)
        files[18] = ArchiveFile(url: URL(fileURLWithPath: "/corpus/renamed/a brand new name.pdf"),
                                name: "a brand new name.pdf", fileType: "PDF", tags: files[18].tags, contentModified: nil)
        for d in [LibrarySort.default, [ARSortDescriptor(field: .name, ascending: false)]] {
            XCTAssertEqual(LibrarySort.sorted(files, by: d).map(\.url.path), Self.reference(files, by: d).map(\.url.path))
        }
    }

    func testRanksFollowLocalizedStandardCompareAcrossCallsAndAReset() {
        let ranks = CollationRanks(limit: 40)
        var seen: [String] = []
        var rng = SeededGenerator(seed: 3)
        // Small batches take the binary-search path, the large one the merge; the limit forces a reset.
        for batch in [3, 1, 2, 80, 1, 5, 30, 2] {
            let strings = (0..<batch).map { _ in names.randomElement(using: &rng)! + String(Int.random(in: 0..<30, using: &rng)) }
            seen += strings
            let all = Array(Set(seen))
            let r = ranks.ranks(for: [all])[0]
            for a in all.indices { for b in all.indices {
                let expected = all[a].localizedStandardCompare(all[b])
                let got: ComparisonResult = r[a] < r[b] ? .orderedAscending : (r[a] > r[b] ? .orderedDescending : .orderedSame)
                XCTAssertEqual(got, expected, "\(all[a]) vs \(all[b]) after a batch of \(batch)")
            } }
            XCTAssertLessThanOrEqual(ranks.count, max(40, all.count))
        }
        XCTAssertEqual(ranks.ranks(for: [[nil, "a"]])[0][0], Int.max, "a missing value ranks last")
    }

    // MARK: - The comparator `sorted` used before the decoration, kept as the reference

    private static func reference(_ files: [ArchiveFile], by descriptors: [ARSortDescriptor]) -> [ArchiveFile] {
        guard !descriptors.isEmpty else { return files }
        func nilLast<T>(_ x: T?, _ y: T?, _ c: (T, T) -> ComparisonResult) -> ComparisonResult {
            switch (x, y) {
            case let (xv?, yv?): return c(xv, yv)
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            }
        }
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        func dir(_ r: ComparisonResult, _ asc: Bool) -> ComparisonResult {
            if asc || r == .orderedSame { return r }
            return r == .orderedAscending ? .orderedDescending : .orderedAscending
        }
        func subjects(_ f: ArchiveFile) -> String? {
            let s = f.tags.topicalTags.joined(separator: ", "); return s.isEmpty ? nil : s
        }
        return files.sorted { a, b in
            for d in descriptors {
                let r: ComparisonResult
                switch d.field {
                case .date: r = nilLast(a.sortDate, b.sortDate) { dir(cmp($0, $1), d.ascending) }
                case .quality: r = nilLast(a.quality, b.quality) { dir(cmp($0, $1), d.ascending) }
                case .name: r = dir(a.name.localizedStandardCompare(b.name), d.ascending)
                case .fileType: r = dir(a.fileType.localizedStandardCompare(b.fileType), d.ascending)
                case .readState: r = nilLast(a.readState?.rawValue, b.readState?.rawValue) { dir($0.localizedStandardCompare($1), d.ascending) }
                case .subjects: r = nilLast(subjects(a), subjects(b)) { dir($0.localizedStandardCompare($1), d.ascending) }
                case .relevance: r = .orderedSame
                }
                if r != .orderedSame { return r == .orderedAscending }
            }
            return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
        }
    }
}

/// SplitMix64, so a failing round reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
