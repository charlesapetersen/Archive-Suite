import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// W40.d7 — the Reader at corpus size.
///
/// Measures what the W40 phase found unmeasured (`execution-plans/verification-phase/01-daemon-plan.md` §D):
/// FTS index build time, search latency, the list's per-row and per-change cost, the health popover's cost,
/// and memory. Two trees, because neither alone answers everything:
///
///   * **the `W40.c2` sample** — 5,000 real corpus PDFs (APFS clones, never the corpus itself). Real OCR
///     text, so it is the only honest place to time the content index and search;
///   * **the 150k synthetic tree** (`ops/scale/scale-corpus.swift`) — for list length. Its PDFs are a few
///     hundred bytes with no text, so it says nothing about the index, and the sample says nothing about
///     116k rows.
///
/// **Env-gated, skips by default.** Driven by `ops/scale/run-reader-at-size.sh`, which writes the handshake
/// file below (a file, not an environment variable — `LibraryIndexScaleTests.handshakeFile` says why) and
/// greps the `D7 ` lines. Results: `verification/evidence/reader/W40.d7-at-size.md`.
///
/// **Nothing here touches the app's own stores.** The content index is a scratch `ContentIndexer(url:)`,
/// the model gets a throwaway defaults domain (`fixtureDefaults`), and the walk is `LibraryScan` with no
/// `RootFolderStore`, so no root marker is written into either tree.
///
/// **What the list numbers are and are not.** The table is the real `AppKitTableView.Coordinator` and its
/// real diffable data source, driven without a window (the unit host draws nothing, by design). So the cost
/// of making each row's cells, of applying a snapshot, and of the per-change work `updateNSView` does is
/// real; the frame rate of actual scrolling, which includes drawing, is not measured here.
@MainActor
final class ReaderAtSizeTests: XCTestCase {

    // Set up and torn down by the nonisolated XCTest hooks; read only by the tests, one at a time.
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReaderAtSizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Roots

    /// `sample=<path>`, `synthetic=<path>` and `optimized=0|1` lines, written by the harness and removed
    /// after it.
    private var handshakeFile: String {
        "/Users/\(NSUserName())/Library/Caches/ArchiveSuiteScale/reader-at-size.txt"
    }

    private var handshakeLines: [String] {
        (try? String(contentsOfFile: handshakeFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    /// Whether the harness built with `-O`; the time budgets are for that build.
    private var optimized: Bool { handshakeLines.contains("optimized=1") }

    private func root(_ key: String) throws -> URL {
        let lines = handshakeLines
        guard let line = lines.first(where: { $0.hasPrefix(key + "=") }) else {
            throw XCTSkip("no \(key) root — run ops/scale/run-reader-at-size.sh (handshake: \(handshakeFile))")
        }
        let path = String(line.dropFirst(key.count + 1))
        // The real corpus is never walked by a test, even read-only: the sample exists so that it isn't.
        guard !path.contains("Google Drive") else { throw XCTSkip("refusing the real corpus: \(path)") }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        switch key {
        case "sample":
            guard url.pathComponents.contains("ArchiveSuiteRehearsal") else {
                throw XCTSkip("the sample root must be under ArchiveSuiteRehearsal: \(path)")
            }
        default:
            guard url.lastPathComponent.hasPrefix("scale-corpus") else {
                throw XCTSkip("the synthetic root must be a scale-corpus* tree: \(path)")
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(path) does not exist") }
        return url
    }

    // MARK: - Measuring

    private func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func sqliteMiB(_ url: URL) -> Double {
        ["", "-wal", "-shm"].reduce(0.0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix))?[.size] as? NSNumber
            return total + Double(size?.int64Value ?? 0) / 1_048_576
        }
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
    private func s(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }

    /// Wall time of `body`, in seconds.
    private func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    /// Median and maximum of `runs` timings of `body`.
    private func repeated(_ runs: Int = 5, _ body: () -> Void) -> (median: Double, max: Double) {
        let samples = (0..<runs).map { _ in time(body).1 }.sorted()
        return (samples[samples.count / 2], samples.last!)
    }

    /// The walk on a `.utility` thread, the band `LibraryScan.onDedicatedThread` walks in.
    private func walkRows(_ root: URL) -> (rows: [ArchiveFile], filesSeen: Int, seconds: Double) {
        final class Box: @unchecked Sendable { var value: (DiscoveryPass, Double)? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let start = DispatchTime.now().uptimeNanoseconds
            let pass = LibraryScan.pass(root: root)
            box.value = (pass, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            done.signal()
        }
        thread.name = "W40.d7.walk"
        thread.qualityOfService = .utility
        thread.start()
        done.wait()
        let (pass, seconds) = box.value!
        let rows = pass.result.entries.map {
            ArchiveLibrary.row($0, tagNames: $0.tagNames, labelNumber: $0.labelNumber)
        }
        return (rows, pass.result.filesSeen, seconds)
    }

    private func timeAsync<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    /// Every row's index row, extracted the way `ContentIndexer.extractRow` does, in parallel.
    private nonisolated func extractAll(_ rows: [ArchiveFile]) -> [IndexRow] {
        final class Slots: @unchecked Sendable { var rows: [IndexRow?]; init(_ n: Int) { rows = Array(repeating: nil, count: n) } }
        let slots = Slots(rows.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: rows.count) { i in
            let file = rows[i]
            let mtime = file.contentModified?.timeIntervalSince1970 ?? 0
            let row: IndexRow
            if let content = PDFTextExtractor.extract(file.url) {
                row = IndexRow(path: file.url.path, mtime: mtime, name: file.name,
                               classification: content.classification, body: content.fullBody,
                               pageCount: content.pageCount, hasText: !content.fullBody.isEmpty, readable: true)
            } else {
                row = IndexRow(path: file.url.path, mtime: mtime, name: file.name, classification: nil,
                               body: "", pageCount: 0, hasText: false, readable: false)
            }
            lock.lock(); slots.rows[i] = row; lock.unlock()
        }
        return slots.rows.compactMap { $0 }
    }

    /// Poll `condition` until it holds; false on timeout.
    ///
    /// **`Task.sleep`, never a nested run loop.** This class is `@MainActor` and its tests are async, so
    /// the body runs as a job on the main queue; spinning `RunLoop.current` from inside it does not drain
    /// the main queue, and the model's `library.$files` sink (`.receive(on: DispatchQueue.main)`) never
    /// fires. Measured: the first run sat at 2% CPU with no index pass ever started. Suspending lets it run.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func model(_ testName: String = #function) -> (NavigationModel, ContentIndexer, URL) {
        let indexURL = scratch.appendingPathComponent("content-index-\(UUID().uuidString).sqlite3")
        let indexer = ContentIndexer(url: indexURL)
        return (NavigationModel(defaults: fixtureDefaults(testName), indexer: indexer), indexer, indexURL)
    }

    // MARK: - The real sample: index, search, popover, memory

    func testIndexSearchAndHealthOnTheRealSample() async throws {
        let root = try root("sample")
        let footprintStart = footprintMiB()
        print("D7 qos main=\(qos_class_self().rawValue)")

        let walk = walkRows(root)
        print("D7 sample walk filesSeen=\(walk.filesSeen) rows=\(walk.rows.count) \(s(walk.seconds)) (utility thread)")
        XCTAssertGreaterThan(walk.rows.count, 1_000, "the sample should list thousands of Read/Unread files")

        // ── The content index, built the way the app builds it: a `files` publish reaches
        // `libraryDidChange`, which hands every row to the model's ContentIndexer (real PDF text, its own
        // `.utility` workers, 500-row batches). Only the indexer's store is scratch.
        let (navigation, indexer, indexURL) = model()
        // Let the model's own first `library.$files` delivery land while `files` is still empty. The sink
        // is async and reads the CURRENT array, so publishing straight away gives two index passes (the
        // full one, then a coalesced cheap one) and the pass count passes 1 without ever resting on it.
        _ = await waitUntil(timeout: 0.5) { false }
        var peak = footprintMiB()
        let buildStart = DispatchTime.now().uptimeNanoseconds
        navigation.library.replaceFilesForTesting(walk.rows)
        let finished = await waitUntil(timeout: 1_800) {
            peak = max(peak, footprintMiB())
            return indexer.progress == nil && indexer.completedPassesForTesting >= 1
        }
        let buildSeconds = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1e9
        XCTAssertTrue(finished, "the index pass did not finish in 30 minutes")
        XCTAssertNil(indexer.failure, "the index pass failed: \(String(describing: indexer.failure))")
        let perFile = buildSeconds / Double(max(walk.rows.count, 1))
        print("D7 fts build rows=\(walk.rows.count) \(s(buildSeconds)) (\(ms(perFile))/file) "
              + String(format: "db=%.1f MiB footprint %.0f -> peak %.0f MiB", sqliteMiB(indexURL), footprintStart, peak)
              + " passes=\(indexer.completedPassesForTesting)")
        // A straight-line projection to the 102,478-PDF corpus. [I]: extraction is per-file work with no
        // cross-file state, so linear is the natural model; the FTS merge cost is not linear and is not in it.
        print("D7 fts projection 102478 files ≈ " + s(perFile * 102_478) + " (linear in files, not measured)")

        // ── Search latency: the call the app's OCR field makes (`searchRanked`), first query cold.
        let queries = ["memorandum", "Kennedy", "budget", "Treasury", "Vietnam", "confidential",
                       "Bureau of the Budget", "the", "a", "president", "zzqxvnotaword"]
        for (i, query) in queries.enumerated() {
            var hits = 0
            var samples: [Double] = []
            for _ in 0..<(i == 0 ? 1 : 5) {
                let start = DispatchTime.now().uptimeNanoseconds
                hits = await indexer.searchRanked(query).paths.count
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            samples.sort()
            print("D7 search \"\(query)\" hits=\(hits) median \(ms(samples[samples.count / 2])) max \(ms(samples.last!))"
                  + (i == 0 ? " (first query: opens the index)" : ""))
        }
        await indexer.closeForTesting()

        // ── Search at corpus size. The sample is 5% of the corpus and FTS query cost grows with the
        // posting lists, so its latencies are not the corpus's. The sample's own extracted text is
        // replicated under distinct paths to 102,478 rows (the corpus's PDF count) and the same queries
        // run against that. Real words in real proportions; what it cannot reproduce is the corpus's
        // vocabulary beyond the sample's, so rare-word queries are, if anything, flattered.
        let extracted = extractAll(walk.rows)
        let corpusURL = scratch.appendingPathComponent("content-index-corpus-size.sqlite3")
        let corpusIndex = ContentIndex(url: corpusURL)
        try await corpusIndex.open()
        let target = 102_478
        let (_, fillSeconds) = try await timeAsync {
            var batch: [IndexRow] = []
            batch.reserveCapacity(500)
            for n in 0..<target {
                let row = extracted[n % extracted.count]
                batch.append(IndexRow(path: "/replica-\(n / extracted.count)\(row.path)", mtime: row.mtime,
                                      name: row.name, classification: row.classification, body: row.body,
                                      pageCount: row.pageCount, hasText: row.hasText, readable: row.readable))
                if batch.count == 500 { try await corpusIndex.upsertBatch(batch); batch.removeAll(keepingCapacity: true) }
            }
            if !batch.isEmpty { try await corpusIndex.upsertBatch(batch) }
            await corpusIndex.performMaintenance(rowsIndexed: target)
        }
        let corpusRows = await corpusIndex.indexedCount()
        print("D7 fts corpus-size rows=\(corpusRows) (sample text x\(target / extracted.count)+) write+optimize \(s(fillSeconds)) "
              + String(format: "db=%.1f MiB", sqliteMiB(corpusURL)))
        for query in queries {
            var hits = 0
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                hits = await corpusIndex.searchRanked(query).paths.count
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            samples.sort()
            // The same MATCH without snippets, to say which half of `searchRanked` the time is in.
            let pathsOnly = await timeAsync { await corpusIndex.search(query) }.1
            print("D7 search@102k \"\(query)\" hits=\(hits) median \(ms(samples[1])) max \(ms(samples[2])) "
                  + "| paths-only search() \(ms(pathsOnly))")
            // W40.fix-reader-fts-snippet-stall: 41.7 s before the fix. SQLite is optimized either way, so
            // one budget serves both builds: the snippet cap plus the 24 ms match, with room.
            if query == "Bureau of the Budget" {
                XCTAssertLessThan(samples[1], 1.0, "searchRanked(\"\(query)\") at \(corpusRows) rows")
            }
        }
        await corpusIndex.close()

        // ── The health popover: `dataQuality` is recomputed on every access, over every row.
        let health = repeated { _ = navigation.dataQuality }
        let quality = navigation.dataQuality
        print("D7 sample health total=\(quality.total) noDate=\(quality.noDate) noQuality=\(quality.noQuality) "
              + "both=\(quality.bothReadUnread) median \(ms(health.median)) max \(ms(health.max))")
        print(String(format: "D7 sample footprint %.0f -> %.0f MiB (peak during index %.0f)",
                     footprintStart, footprintMiB(), peak))
    }

    // MARK: - Common words in long OCR bodies (runs without the harness)

    /// W40.fix-reader-fts-snippet-stall without the sample: long bodies in which `of` and `the` occur
    /// thousands of times, as they do in the corpus's long OCR text. FTS5's `snippet()` cost grows with the
    /// square of a document's matched-term instances, so before the fix this took about 8 s (about 140 ms
    /// a document, measured on the same shape in SQLite 3.53); the threshold is far below that and every hit
    /// must still have its preview, so a fix that only ran out the snippet clock would fail too.
    func testCommonWordPhraseSnippetsStayFastOnLongBodies() async throws {
        let index = ContentIndex(url: scratch.appendingPathComponent("content-index-long-bodies.sqlite3"))
        try await index.open()
        let fillers = ["memorandum", "president", "treasury", "report", "office", "federal", "program"]
        var rows: [IndexRow] = []
        for doc in 0..<60 {
            var words: [String] = []
            words.reserveCapacity(14_100)
            for i in 0..<2_000 {
                words += ["the", fillers[(i + doc) % fillers.count], "of", "the", fillers[i % 5], "and", "a"]
                if i % 400 == 0 { words += ["Bureau", "of", "the", "Budget"] }
            }
            rows.append(IndexRow(path: "/long-\(doc).pdf", mtime: 1, name: "long \(doc)", classification: nil,
                                 body: words.joined(separator: " "), pageCount: 40, hasText: true, readable: true))
        }
        try await index.upsertBatch(rows)
        _ = await index.searchRanked("Bureau of the Budget")        // warm the page cache
        let (ranked, seconds) = await timeAsync { await index.searchRanked("Bureau of the Budget") }
        print("D7 long-body \"Bureau of the Budget\" hits=\(ranked.paths.count) snippets=\(ranked.snippets.count) \(ms(seconds))")
        XCTAssertEqual(ranked.paths.count, rows.count)
        XCTAssertEqual(ranked.snippets.count, rows.count, "every hit should keep its preview")
        XCTAssertLessThan(seconds, 0.5, "searchRanked(\"Bureau of the Budget\") over \(rows.count) long bodies")
        await index.close()
    }

    // MARK: - The 150k synthetic tree: list length

    func testListAtOneHundredFiftyThousandFiles() async throws {
        let root = try root("synthetic")
        let footprintStart = footprintMiB()
        let walk = walkRows(root)
        let rows = walk.rows
        print("D7 synthetic walk filesSeen=\(walk.filesSeen) rows=\(rows.count) \(s(walk.seconds)) (utility thread)")
        XCTAssertGreaterThanOrEqual(walk.filesSeen, 100_000, "the list-length lane needs the 150k tree")

        // ── Sort and filter: the pure functions `NavigationModel.recompute()` calls.
        // W40.fix-reader-list-recompute-at-size: the budgets below are main-thread time at `-O`; a Debug
        // (-Onone) build, the harness without --optimized, gets three times as long. Before that fix, at
        // `-O`: 0.96 s for the default sort, 4.0–5.5 s by a field, and 1,561 ms for one tag edit.
        let budgetScale = optimized ? 1.0 : 3.0
        let sortBudget = 0.4 * budgetScale
        for field in [SortField.date, .name, .quality, .readState, .fileType, .subjects] {
            // The first sort to see a key ranks its strings (once per session); later sorts reuse them.
            let (_, first) = time { _ = LibrarySort.sorted(rows, by: [ARSortDescriptor(field: field)]) }
            let t = repeated(3) { _ = LibrarySort.sorted(rows, by: [ARSortDescriptor(field: field)]) }
            print("D7 sort \(field.rawValue) rows=\(rows.count) median \(ms(t.median)) max \(ms(t.max)) "
                  + "(first sight of its keys \(ms(first)))")
            XCTAssertLessThan(t.median, sortBudget, "re-sorting by \(field.rawValue) at \(rows.count) rows")
        }
        let defaultSort = repeated(3) { _ = LibrarySort.sorted(rows, by: LibrarySort.default) }
        print("D7 sort default median \(ms(defaultSort.median)) max \(ms(defaultSort.max))")
        XCTAssertLessThan(defaultSort.median, sortBudget, "the default sort at \(rows.count) rows")
        let filters: [(String, LibraryFilter)] = [
            ("unread", LibraryFilter(read: .unread)),
            ("name-text", LibraryFilter(searchText: "box")),
            ("subject", LibraryFilter(subjects: ["Correspondence"])),
            ("year-range", LibraryFilter(dateFromYear: 1960, dateToYear: 1980)),
        ]
        for (label, filter) in filters {
            var kept = 0
            let t = repeated(3) { kept = rows.filter(filter.matches).count }
            print("D7 filter \(label) kept=\(kept) median \(ms(t.median)) max \(ms(t.max))")
        }

        // ── The model at 116k rows: what one `files` publish costs (a scan landing, or any tag edit,
        // republishes the whole array), then `recompute()` alone, then the popover.
        let (navigation, indexer, _) = model()
        navigation.filter = LibraryFilter()   // All, so the list shows every row
        _ = await waitUntil(timeout: 0.5) { false }   // let the filter publish settle
        let generation = navigation.displayedGeneration
        let publishStart = DispatchTime.now().uptimeNanoseconds
        navigation.library.replaceFilesForTesting(rows)
        _ = await waitUntil(timeout: 120) { navigation.displayedGeneration != generation }
        let publishSeconds = Double(DispatchTime.now().uptimeNanoseconds - publishStart) / 1e9
        XCTAssertEqual(navigation.displayed.count, rows.count)
        print("D7 model files-publish -> list rows=\(navigation.displayed.count) \(ms(publishSeconds)) "
              + "(libraryDidChange: signatures, folder tree, recompute)")
        // The publish also starts an index pass over every row; let it finish so it does not load the
        // timings below. Its duration is not a number this lane reports — the synthetic PDFs have no text.
        _ = await waitUntil(timeout: 900) { indexer.progress == nil && indexer.completedPassesForTesting >= 1 }
        let recompute = repeated(3) { navigation.recompute() }
        print("D7 model recompute rows=\(rows.count) median \(ms(recompute.median)) max \(ms(recompute.max))")
        // One tag edit, as `ArchiveLibrary.applyVerifiedWrites` makes it after Mark Read, an inline or
        // group edit, a rename or an undo: the whole `files` array reassigned with one row rebuilt.
        // `libraryDidChange` then runs again in full on the main thread. Paths are unchanged, so the
        // folder tree is not rebuilt, which is what makes this cheaper than the first publish above.
        var editSamples: [Double] = []
        for k in 0..<3 {
            var edited = navigation.library.files
            let i = (edited.count / 3) * k
            let f = edited[i]
            let flipped = f.tags.raw.map { $0 == "Unread" ? "Read" : ($0 == "Read" ? "Unread" : $0) }
            edited[i] = ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                                    tags: DocumentTags.parse(raw: flipped, labelNumber: nil),
                                    contentModified: f.contentModified, isDataless: f.isDataless,
                                    provenance: f.provenance)
            let before = navigation.displayedGeneration
            let start = DispatchTime.now().uptimeNanoseconds
            navigation.library.replaceFilesForTesting(edited)
            _ = await waitUntil(timeout: 60) { navigation.displayedGeneration != before }
            editSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            _ = await waitUntil(timeout: 300) { indexer.progress == nil }
        }
        editSamples.sort()
        print("D7 model one tag edit -> list (files reassigned, libraryDidChange) median \(ms(editSamples[1])) "
              + "max \(ms(editSamples[2]))")
        XCTAssertLessThan(editSamples[1], 0.4 * budgetScale, "one tag edit at \(rows.count) rows")
        // Where a tag edit's time goes, piece by piece.
        let current = navigation.library.files
        for (label, body) in [
            ("signature paths", { _ = LibraryChangeSignature.paths(current) }),
            ("signature subjects", { _ = LibraryChangeSignature.subjects(current) }),
            ("signature match facets", { _ = LibraryChangeSignature.matchFacets(current) }),
            ("filter all", { _ = current.filter(navigation.filter.matches) }),
            ("sort default", { _ = LibrarySort.sorted(current, by: navigation.sort) }),
            ("duplicate names", { _ = DuplicateNames.duplicatedNames(in: current) }),
            ("prune path set (off the main thread since the fix)", { _ = Set(current.map(\.path)) }),
        ] as [(String, () -> Void)] {
            let t = repeated(3, body)
            print("D7 model tag-edit part: \(label) median \(ms(t.median))")
        }

        let health = repeated { _ = navigation.dataQuality }
        print("D7 synthetic health total=\(navigation.dataQuality.total) median \(ms(health.median)) max \(ms(health.max))")

        print(String(format: "D7 synthetic footprint with model %.0f MiB", footprintMiB()))

        // ── The table, as `AppKitTableView.makeNSView` builds it, minus the window.
        // In a scroll view of a window's size, as the app has it: a bare NSTableView grows to fit every
        // row, so applying a snapshot lays out all 116k rows' cells at once (measured: it overflowed
        // SwiftUI's AttributeGraph and aborted the host). The clip view bounds what is laid out.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        let tableView = NSTableView(frame: scrollView.bounds)
        scrollView.documentView = tableView
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = max(20, 13 * 1.8)
        for column in AppKitTableView.columnDefinitions {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tc.width = column.width
            tableView.addTableColumn(tc)
        }
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: navigation, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = tableView
        let dataSource = SortableDiffableDataSource(tableView: tableView) { tv, column, row, itemID in
            coordinator.makeCell(tableView: tv, column: column, itemID: itemID)
        }
        coordinator.dataSource = dataSource
        tableView.delegate = coordinator

        // `updateNSView`'s per-generation work: rebuild the id→row map, map the ids, compare with the
        // current snapshot. It runs on every `displayed` change, tag edits included.
        let ids = navigation.displayed.map(\.id)
        let (_, firstSnapshot) = time { coordinator.showRows(navigation.displayed) }
        print("D7 table first snapshot rows=\(ids.count) \(ms(firstSnapshot))")
        let perChange = repeated(3) { XCTAssertFalse(coordinator.showRows(navigation.displayed)) }
        print("D7 table per-change refresh (ids unchanged, e.g. a tag edit) median \(ms(perChange.median)) max \(ms(perChange.max))")
        let reversed = Array(ids.reversed())
        let (_, resort) = time { coordinator.applySnapshot(reversed, animated: false) }
        print("D7 table re-sorted snapshot (every row moves) \(ms(resort))")
        coordinator.applySnapshot(ids, animated: false)
        let lastID = ids.last!
        let selection = repeated { coordinator.syncSelection([lastID]) }
        print("D7 table syncSelection one row median \(ms(selection.median)) max \(ms(selection.max)) (looks up the selected ids)")
        let scrollLookup = repeated { _ = coordinator.rowByID[lastID] }
        print("D7 table scroll-to-row lookup (last row) median \(ms(scrollLookup.median))")

        // Scrolling: one screen is ~35 rows. At 200 offsets across the whole list, make every visible
        // column's cell for each row and size it, as automatic row heights do. Without a window the
        // table's reuse queue is empty, so each cell is built fresh — an upper bound on cell cost.
        let screenRows = 35
        var screenTimes: [Double] = []
        for step in 0..<200 {
            let top = (ids.count - screenRows) * step / 199
            let (_, t) = time { autoreleasepool {
                for row in top..<(top + screenRows) {
                    for column in tableView.tableColumns {
                        let cell = coordinator.makeCell(tableView: tableView, column: column, itemID: ids[row])
                        _ = cell.fittingSize
                    }
                }
            } }
            screenTimes.append(t)
        }
        screenTimes.sort()
        let p95 = screenTimes[Int(Double(screenTimes.count) * 0.95)]
        print("D7 table screen of \(screenRows) rows x \(tableView.tableColumns.count) columns: median \(ms(screenTimes[100])) "
              + "p95 \(ms(p95)) max \(ms(screenTimes.last!)) — per row \(ms(screenTimes[100] / Double(screenRows)))")

        await indexer.closeForTesting()
        print(String(format: "D7 synthetic footprint %.0f -> %.0f MiB", footprintStart, footprintMiB()))
    }
}
