import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-change-incremental: a tag change patches the rows it touches. Each patch is held to the
/// whole rebuild it replaces, on the same inputs: the library's row patch to its whole-library merge, the
/// list's patch to `recompute()`, the smart-folder counts' differences to a fresh count, and
/// `LibrarySort.before` to `LibrarySort.sorted`. Rows are made in memory under a path that does not exist;
/// nothing is read from or written to disk except a scratch content index.
@MainActor
final class LibraryRowPatchTests: XCTestCase {

    private var rng = RowPatchGenerator(seed: 0x5EED_2026_1111)
    private let base = "/private/tmp/W40-row-patch-\(UUID().uuidString)"

    // MARK: - Rows

    private let subjectPool = ["Press", "Treasury", "Budget", "Memoranda", "Box 12", "Lincoln", "lincoln"]
    private let yearPool = ["1950", "1962", "1975", "1975", "1981", "1970s"]

    private func randomTags() -> [String] {
        var tags = [Bool.random(using: &rng) ? "Read" : "Unread"]
        for s in subjectPool where Int.random(in: 0..<4, using: &rng) == 0 { tags.append(s) }
        if Int.random(in: 0..<3, using: &rng) > 0 { tags.append(yearPool.randomElement(using: &rng)!) }
        if Int.random(in: 0..<8, using: &rng) == 0 { tags.append(yearPool.randomElement(using: &rng)!) }  // ambiguous
        if Int.random(in: 0..<3, using: &rng) == 0 { tags.append("Q\(Int.random(in: 1...3, using: &rng))") }
        return tags
    }

    private func url(_ folder: Int, _ file: Int) -> URL {
        // Names repeat across folders, so duplicated names are exercised; some folders are spelled composed
        // and some decomposed (é), as an APFS volume may hold either.
        let cafe = folder % 2 == 0 ? "Caf\u{E9}" : "Cafe\u{301}"
        return URL(fileURLWithPath: "\(base)/Box \(folder)/\(cafe) \(folder % 3)/doc \(file).pdf")
    }

    private func entry(_ url: URL, _ tags: [String], mtime: TimeInterval = 1_000) -> CorpusEntry {
        CorpusEntry(url: url, tagNames: tags, labelNumber: nil,
                    contentModified: Date(timeIntervalSince1970: mtime),
                    contentTypeIdentifier: "com.adobe.pdf", isDataless: false)
    }

    private func makeRows(_ count: Int) -> [ArchiveFile] {
        var seen = Set<String>(), rows: [ArchiveFile] = []
        while rows.count < count {
            let u = url(Int.random(in: 1...12, using: &rng), Int.random(in: 0..<400, using: &rng))
            guard seen.insert(u.path).inserted else { continue }
            let tags = randomTags()
            rows.append(ArchiveLibrary.row(entry(u, tags), tagNames: tags, labelNumber: nil))
        }
        return rows.sorted { ArchiveLibrary.listedBefore($0.path, $1.path) }
    }

    /// What a row shows and is matched on; provenance (its read time) is left out.
    private struct Shown: Equatable, CustomStringConvertible {
        let path: String, tags: [String], mtime: Date?, type: String
        init(_ f: ArchiveFile) { path = f.path; tags = f.tags.raw.sorted(); mtime = f.contentModified; type = f.fileType }
        var description: String { "\(path.dropFirst(60)) \(tags)" }
    }

    // MARK: - LibrarySort.before against LibrarySort.sorted

    func testBeforeAgreesWithSorted() {
        let rows = makeRows(300)
        let sorts: [[ARSortDescriptor]] = [
            LibrarySort.default,
            [ARSortDescriptor(field: .readState, ascending: false), ARSortDescriptor(field: .name)],
            [ARSortDescriptor(field: .subjects)],
            [ARSortDescriptor(field: .quality, ascending: false), ARSortDescriptor(field: .date, ascending: false)],
            [ARSortDescriptor(field: .flag), ARSortDescriptor(field: .fileType)],
            [ARSortDescriptor(field: .relevance)],
            [],
        ]
        var marks = SortMarks()
        marks.flagged = Set(rows.prefix(40).map(\.path))
        for sort in sorts {
            // With no keys `sorted` keeps its input's order, which in the app is always the library's.
            let sorted = LibrarySort.sorted(sort.isEmpty ? rows : rows.shuffled(using: &rng), by: sort, marks: marks)
            for i in sorted.indices.dropLast() {
                XCTAssertFalse(LibrarySort.before(sorted[i + 1], sorted[i], by: sort, marks: marks),
                               "\(sort.map(\.field)): \(Shown(sorted[i + 1])) must not come before \(Shown(sorted[i]))")
            }
            for _ in 0..<500 {
                let a = rows.randomElement(using: &rng)!, b = rows.randomElement(using: &rng)!
                guard a.path != b.path else { continue }
                XCTAssertNotEqual(LibrarySort.before(a, b, by: sort, marks: marks),
                                  LibrarySort.before(b, a, by: sort, marks: marks),
                                  "distinct paths are ordered one way: \(Shown(a)) / \(Shown(b))")
            }
        }
    }

    // MARK: - The library's row patch against its whole-library merge

    private func library(_ rows: [ArchiveFile], whole: Bool) -> ArchiveLibrary {
        // Never started, so no walk or watcher runs; the rows are the test's.
        let library = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil, defaults: fixtureDefaults())
        library.replaceFilesForTesting(rows)
        library.forceWholeMergeForTesting = whole
        _ = library.takeChange()
        return library
    }

    func testRowPatchMatchesTheWholeMerge() {
        var patchedRounds = 0
        for round in 0..<40 {
            // Over 1,000 rows, so the library also builds its row index in the background.
            let rows = makeRows(round % 4 == 0 ? 1_200 : 200)
            let patched = library(rows, whole: false), merged = library(rows, whole: true)

            // A verified write newer than the read, on some rows, in both.
            var writes: [TagWriteResult] = []
            for f in rows.shuffled(using: &rng).prefix(Int.random(in: 0...3, using: &rng)) {
                let after = Bool.random(using: &rng) ? randomTags() : ["Subject only"]
                writes.append(TagWriteResult(url: f.url, before: f.tags.raw, after: after, beforeLabel: nil,
                                             afterLabel: nil, inverse: TagDelta(add: [], remove: [])))
            }
            let readGeneration = patched.beginWatchReadForTesting()
            XCTAssertEqual(merged.beginWatchReadForTesting(), readGeneration)
            patched.applyVerifiedWrites(writes)
            merged.applyVerifiedWrites(writes)
            XCTAssertEqual(patched.files.map(Shown.init), merged.files.map(Shown.init), "round \(round): the writes")

            // A batch: tag changes, removals, new files, unreadable and folder paths, repeats, and now and then
            // a path some rows lie under (the patch must give way to the merge there).
            var changes: [CorpusPathChange] = []
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                let pick = rows.randomElement(using: &rng)!.url
                switch Int.random(in: 0..<10, using: &rng) {
                case 0...3: changes.append(CorpusPathChange(url: pick, inspection: .tracked(entry(pick, randomTags()))))
                case 4: changes.append(CorpusPathChange(url: pick, inspection: .untracked))
                case 5: changes.append(CorpusPathChange(url: pick, inspection: .vanished))
                case 6:
                    let fresh = url(Int.random(in: 1...14, using: &rng), Int.random(in: 400..<800, using: &rng))
                    changes.append(CorpusPathChange(url: fresh, inspection: .tracked(entry(fresh, randomTags()))))
                case 7: changes.append(CorpusPathChange(url: pick, inspection: .tracked(entry(pick, randomTags(),
                                                                                              mtime: 2_000))))
                case 8: changes.append(CorpusPathChange(url: pick, inspection: .unreadable(
                    CorpusReadFailure(url: pick, reason: "test"))))
                default:
                    // A folder of rows read as a directory, or as a file that replaced it.
                    let folder = URL(fileURLWithPath: pick.deletingLastPathComponent().path)
                    changes.append(CorpusPathChange(url: folder, inspection: Bool.random(using: &rng) ? .directory
                                                        : .tracked(entry(folder, randomTags()))))
                }
            }
            let batch = CorpusWatchChangeSet(paths: changes, subtrees: [])
            let before = patched.files
            _ = patched.takeChange()
            patched.finishWatchReadForTesting(batch, readGeneration: readGeneration)
            merged.finishWatchReadForTesting(batch, readGeneration: readGeneration)
            let p = patched.files.map(Shown.init), m = merged.files.map(Shown.init)
            XCTAssertEqual(p, m, "round \(round): only patched \(p.filter { !m.contains($0) }), only merged "
                           + "\(m.filter { !p.contains($0) }); batch \(changes.map { "\($0.url.absoluteString.suffix(30)) \($0.inspection)" })")
            XCTAssertEqual(patched.phase, merged.phase, "round \(round)")
            XCTAssertEqual(patched.verifiedWriteCountForTesting, merged.verifiedWriteCountForTesting)

            // The change set names exactly the rows that changed, before and after.
            let change = patched.takeChange()
            if let changed = change.rows {
                patchedRounds += 1
                let old = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) })
                let new = Dictionary(uniqueKeysWithValues: patched.files.map { ($0.path, $0) })
                for (path, row) in changed {
                    XCTAssertEqual(row.old.map(Shown.init), old[path.string].map(Shown.init))
                    XCTAssertEqual(row.new.map(Shown.init), new[path.string].map(Shown.init))
                }
                for path in Set(old.keys).union(new.keys) where old[path] != new[path] {
                    XCTAssertNotNil(changed[UTF8Key(path)], "round \(round): \(path) changed but is not in the set")
                }
            }
            // And the index the patch found rows by still finds them.
            for f in patched.files.shuffled(using: &rng).prefix(10) {
                XCTAssertEqual(patched.files(atPaths: [f.path]).first?.path, f.path)
            }
        }
        XCTAssertGreaterThan(patchedRounds, 20, "most batches took the patch, not the merge")
    }

    // MARK: - The list's patch against recompute()

    private struct ListState: Equatable {
        let displayed: [Shown]
        let selected: [Shown]
        let ambiguous: Int
        let duplicated: Set<String>
    }

    private func state(_ model: NavigationModel) -> ListState {
        ListState(displayed: model.displayed.map(Shown.init), selected: model.selectedFilesCache.map(Shown.init),
                  ambiguous: model.ambiguousDateCount, duplicated: model.duplicatedNames)
    }

    private func settle(_ model: NavigationModel, _ indexer: ContentIndexer) async {
        for _ in 0..<3 {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, indexer.progress != nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func testListPatchMatchesRecompute() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRowPatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let indexer = ContentIndexer(url: scratch.appendingPathComponent("content.sqlite3"),
                                     extractPDFForTesting: { _ in
            ExtractedContent(fullBody: "", strippedBody: "", classification: nil, pageCount: 2)
        })
        let model = NavigationModel(defaults: fixtureDefaults(), indexer: indexer)
        var rows = makeRows(1_500)            // over the size the model prepares off the main actor
        model.library.replaceFilesForTesting(rows)
        await settle(model, indexer)

        func rule(_ field: RuleField, _ op: RuleOperator? = nil, _ edit: (inout SearchRule) -> Void) -> SearchRule {
            var r = SearchRule(field: field, op: op); edit(&r); return r
        }
        let folders: [(String, AdvancedSearch)] = [
            ("Unread", AdvancedSearch(rules: [rule(.readState) { $0.read = .unread }])),
            ("Press", AdvancedSearch(rules: [rule(.tags, .hasAny) { $0.tags = ["Press"] }])),
            ("Treasury read", AdvancedSearch(rules: [rule(.tags, .hasAll) { $0.tags = ["Treasury"] },
                                                    rule(.readState) { $0.read = .read }])),
            ("1970s", AdvancedSearch(rules: [rule(.date, .between) { $0.text = "1970"; $0.text2 = "1979" }])),
            ("Undated", AdvancedSearch(rules: [rule(.date, .undated) { _ in }])),
            ("Quality 3", AdvancedSearch(rules: [rule(.quality) { $0.qualities = [3] }])),
        ]
        for (name, search) in folders { model.savedSearches.add(name: name, search: search) }
        await settle(model, indexer)
        XCTAssertEqual(model.smartFolderCounts.count, folders.count, "precondition: the counts arrived")

        let views: [(String, (NavigationModel) -> Void)] = [
            ("all, default sort", { $0.clearUserFilters() }),
            ("unread only", { $0.clearUserFilters(); $0.filter.read = .unread; $0.recompute() }),
            ("Press, by read state", { m in
                m.clearUserFilters(); m.filter.subjects = ["Press"]
                m.sort = [ARSortDescriptor(field: .readState, ascending: false), ARSortDescriptor(field: .name)]
                m.recompute() }),
            ("by tags", { m in m.clearUserFilters(); m.sort = [ARSortDescriptor(field: .subjects)]; m.recompute() }),
            ("smart folder Treasury read, by date", { m in
                m.clearUserFilters(); m.sort = LibrarySort.default
                m.applyScope(m.savedSearches.searches.first { $0.name == "Treasury read" }!) }),
        ]
        var patches = 0
        for (label, setUp) in views {
            setUp(model)
            await settle(model, indexer)
            for step in 0..<25 {
                // Select a few shown rows, then write tags to some rows, shown or not, selected or not.
                let shown = model.displayed
                if !shown.isEmpty {
                    model.selection = Set(shown.shuffled(using: &rng).prefix(Int.random(in: 0...4, using: &rng)).map(\.id))
                }
                let targets = (shown.shuffled(using: &rng).prefix(2) + rows.shuffled(using: &rng).prefix(2))
                    .prefix(Int.random(in: 1...4, using: &rng))
                let writes = targets.map { f in
                    TagWriteResult(url: f.url, before: f.tags.raw, after: randomTags(), beforeLabel: nil,
                                   afterLabel: nil, inverse: TagDelta(add: [], remove: []))
                }
                let patchesBefore = model.rowPatchesForTesting
                model.library.applyVerifiedWrites(writes)
                await settle(model, indexer)
                rows = model.library.files
                let afterPatch = state(model)
                let countsAfterPatch = model.smartFolderCounts
                if model.rowPatchesForTesting > patchesBefore { patches += 1 }

                model.recompute()
                model.selection = model.selection          // the cache rebuilt from every displayed row
                XCTAssertEqual(afterPatch, state(model), "\(label), step \(step): the patch differs from recompute()")
                for search in model.savedSearches.searches {
                    let fresh = await model.countMatches(search.search)
                    XCTAssertEqual(countsAfterPatch[search.id], fresh, "\(label), step \(step): \(search.name)'s count")
                }
            }
        }
        XCTAssertGreaterThan(patches, 100, "the patch, not the rebuild, handled the tag changes")
        await indexer.closeForTesting()
    }
}

/// A small deterministic generator (SplitMix64), so a failure replays.
private struct RowPatchGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
