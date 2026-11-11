import XCTest
import AppKit
import Combine
import PDFKit
import ArchiveCore
@testable import ArchiveReader

/// W40.reader-scale-measure — the whole chain one change sets off, at corpus size, and what grows over a
/// session.
///
/// `ReaderAtSizeTests` times stages one at a time. The stalls the owner sees are the chain behind one
/// change (`execution-plans/reader-owner-notes-2026-11-10.md`, cause A), so this drives the real
/// `NavigationModel` over a live library: an APFS clone of the 150k synthetic tree (115,999 listed rows),
/// its real FSEvents `CorpusWatcher`, a scratch content index, and 10 saved smart folders, two with
/// OCR-text rules. For each change it reports main-thread busy time (a background thread sends one main-queue
/// ping at a time; every ping held over 4 ms is summed, so blocking I/O counts as well as CPU), the longest
/// stall, the time until the list shows the change and until the chain goes quiet, and the `ReaderStages`
/// totals per stage. Main-thread CPU time is not used: XCTest's waiter spins the main run loop while an
/// async test awaits, which measured 990 ms of main-thread CPU per idle second.
///
/// **Views are emulated, and said to be.** The unit host draws nothing, so what a mounted view would run
/// is run by the lane at the moment SwiftUI would run it (once per main-queue turn after a publish): the
/// inspector's `libraryFiles(atPaths:)` (library window and document window), the table's
/// `showRows`/`syncSelection`, and the document panes' page copy and render. Those stages are named
/// `view.… (emulated)`.
///
/// **Env-gated.** Driven by `ops/scale/run-reader-at-size.sh --only chain`, which clones the tree, writes the
/// handshake, runs `footprint`/`heap`/`leaks` on request from outside (a process cannot vouch for its own
/// heap), and greps the `CH ` lines. Results: `verification/evidence/reader/W40.reader-scale-measure.md`.
///
/// **Nothing here touches the app's stores or the corpus.** The root is a clone named `scale-corpus*-chain`,
/// deleted by the harness after the run; the defaults domain, ledger and content index are throwaway.
@MainActor
final class ReaderChainAtSizeTests: XCTestCase {

    nonisolated(unsafe) private var scratch: URL!
    nonisolated(unsafe) private var savedLedgerURL: URL?

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReaderChainAtSizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ReaderStages.recorder.reset(recording: false)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Handshake

    private var handshakeFile: String {
        "/Users/\(NSUserName())/Library/Caches/ArchiveSuiteScale/reader-at-size.txt"
    }

    private func handshake(_ key: String) -> String? {
        let lines = (try? String(contentsOfFile: handshakeFile, encoding: .utf8))?.split(separator: "\n") ?? []
        return lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    private var optimized: Bool { handshake("optimized") == "1" }

    // MARK: - Measuring

    private func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func seconds(since start: UInt64) -> Double { Double(now() - start) / 1e9 }

    /// Poll with `Task.sleep`, so the main queue drains between polls (`ReaderAtSizeTests.waitUntil`).
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    // MARK: - The chain

    private struct Chain {
        var visible: Double?       // trigger → the list (or viewer) shows the change
        var settled: Double        // trigger → the last stage of the chain ended
        var busy: Double           // main-queue ping time over 4 ms, summed
        var longest: Double        // the longest main-queue ping
        var stages: [StageRecorder.Key: StageRecorder.Total]
    }

    private var meter: MainThreadMeter!
    private var indexer: ContentIndexer!

    /// Run `trigger`, wait for `visible`, then for the chain to go quiet: the index idle and no stage ending
    /// for `quiet` seconds.
    private func measureChain(_ label: String, quiet: Double = 3.0, timeout: Double = 180,
                              trigger: () -> Void, visible: () -> Bool) async -> Chain {
        _ = await waitUntil(timeout: 600) { indexer.progress == nil }
        await pause(0.5)
        ReaderStages.recorder.reset(recording: true)
        meter.resetPings()
        let start = now()
        trigger()
        var visibleAt: Double?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if visibleAt == nil, visible() { visibleAt = seconds(since: start) }
            let snap = ReaderStages.recorder.snapshot()
            let lastEnd = max(snap.lastEnd, start)
            if visibleAt != nil, indexer.progress == nil, Double(now() - lastEnd) / 1e9 >= quiet { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let pings = meter.pings()
        let snap = ReaderStages.recorder.snapshot()
        ReaderStages.recorder.reset(recording: false)
        let chain = Chain(visible: visibleAt, settled: Double(max(snap.lastEnd, start) - start) / 1e9,
                          busy: pings.stalled, longest: pings.longest, stages: snap.totals)
        print("CH chain \(label): visible \(visibleAt.map(ms) ?? "NEVER") settled \(ms(chain.settled)) "
              + "main-busy \(ms(chain.busy)) longest-stall \(ms(chain.longest))")
        return chain
    }

    private func printStages(_ label: String, _ chain: Chain) {
        for (key, total) in chain.stages.sorted(by: { $0.value.nanoseconds > $1.value.nanoseconds }) {
            print("CH stage \(label) | \(key.stage)\(key.onMain ? "" : " [off-main]") | n=\(total.count) "
                  + "total \(ms(Double(total.nanoseconds) / 1e9)) max \(ms(Double(total.maxNanoseconds) / 1e9))")
        }
    }

    private func summarize(_ label: String, _ runs: [Chain]) {
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        print("CH summary \(label) runs=\(runs.count): visible median \(ms(median(runs.map { $0.visible ?? .infinity }))) "
              + "settled median \(ms(median(runs.map(\.settled)))) main-busy median \(ms(median(runs.map(\.busy)))) "
              + "longest-stall median \(ms(median(runs.map(\.longest)))) max \(ms(runs.map(\.longest).max() ?? 0))")
        printStages(label, runs.sorted { $0.busy < $1.busy }[runs.count / 2])
    }

    // MARK: - Budgets (W40.fix-reader-change-incremental), asserted on the -O run

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    /// Main-thread time spent in `stage`, summed.
    private func onMain(_ stage: String, _ chain: Chain) -> Double {
        chain.stages.filter { $0.key.stage == stage && $0.key.onMain }.values
            .reduce(0) { $0 + Double($1.nanoseconds) / 1e9 }
    }

    /// The tag-change budgets W40.reader-scale-measure set: main-busy (less TagWriter's own write, verify and
    /// fsync, which stay), visible, the longest stall, and no row count on the main thread.
    private func assertChangeBudget(_ label: String, _ runs: [Chain], busy: Double, visible: Double,
                                    excludingWriter: Bool) {
        guard optimized else { return }
        let busyLessWriter = runs.map { $0.busy - (excludingWriter ? onMain("tagWriter.writes", $0) : 0) }
        print("CH budget \(label): main-busy\(excludingWriter ? " after TagWriter" : "") median \(ms(median(busyLessWriter))) "
              + "(budget \(ms(busy))), visible median \(ms(median(runs.map { $0.visible ?? .infinity }))) "
              + "(budget \(ms(visible))), longest stall max \(ms(runs.map(\.longest).max() ?? 0))")
        XCTAssertLessThanOrEqual(median(busyLessWriter), busy, "\(label): main-busy")
        XCTAssertLessThanOrEqual(median(runs.map { $0.visible ?? .infinity }), visible, "\(label): visible")
        for (k, run) in runs.enumerated() {
            let writer = excludingWriter ? (run.stages.first { $0.key.stage == "tagWriter.writes" && $0.key.onMain }?
                .value.maxNanoseconds).map { Double($0) / 1e9 } ?? 0 : 0
            XCTAssertLessThanOrEqual(run.longest - writer, 0.100, "\(label) run \(k + 1): a stall over 100 ms")
            XCTAssertEqual(onMain("model.countMatches.rows", run), 0, "\(label) run \(k + 1): rows counted on main")
        }
    }

    /// The file-switch budget W40.reader-scale-measure set (W40.fix-reader-viewer-switch): the next file within
    /// 100 ms main-busy with 5 open.
    private func assertViewerBudget(_ label: String, _ runs: [Chain]) {
        guard optimized else { return }
        print("CH budget \(label): main-busy median \(ms(median(runs.map(\.busy)))) (budget 100.0 ms), "
              + "visible median \(ms(median(runs.map { $0.visible ?? .infinity }))), "
              + "longest stall max \(ms(runs.map(\.longest).max() ?? 0))")
        XCTAssertLessThanOrEqual(median(runs.map(\.busy)), 0.100, "\(label): main-busy")
    }

    // MARK: - Outside measurements (footprint, heap, leaks), run by the harness

    /// The selection budget W40.reader-scale-measure set (W40.fix-reader-selection-at-size): at most 16 ms main-busy,
    /// the inspector and the table included, and so no stall over one frame either.
    private func assertSelectionBudget(_ label: String, _ runs: [Chain]) {
        guard optimized else { return }
        print("CH budget \(label): main-busy median \(ms(median(runs.map(\.busy)))) (budget 16.0 ms), "
              + "longest stall max \(ms(runs.map(\.longest).max() ?? 0))")
        XCTAssertLessThanOrEqual(median(runs.map(\.busy)), 0.016, "\(label): main-busy")
        XCTAssertLessThanOrEqual(runs.map(\.longest).max() ?? 0, 0.016, "\(label): a stall over 16 ms")
    }

    /// Ask the harness to run `kind` (footprint | heap | leaks) on this process; wait for it.
    private func outside(_ kind: String, _ label: String, timeout: Double = 900) async {
        guard let dir = handshake("requests") else { print("CH outside \(kind) \(label): no requests dir"); return }
        let base = URL(fileURLWithPath: dir).appendingPathComponent("\(label)-\(kind)")
        let done = base.appendingPathExtension("done")
        try? "\(kind) \(label) \(getpid())\n".write(to: base.appendingPathExtension("tmp"), atomically: true, encoding: .utf8)
        try? FileManager.default.moveItem(at: base.appendingPathExtension("tmp"), to: base.appendingPathExtension("req"))
        let start = now()
        let ok = await waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: done.path) }
        print("CH outside \(kind) \(label): \(ok ? "done" : "TIMED OUT") in \(ms(seconds(since: start)))")
    }

    // MARK: - Foreign writes

    /// Finder's on-disk tag form, written by another process (`/usr/bin/xattr`), so the change reaches the
    /// library through FSEvents: the watcher drops this process's own events (`OwnEvent`).
    private nonisolated static func writeTagsElsewhere(_ tags: [String], to path: String) -> Bool {
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        else { return false }
        let hex = plist.map { String(format: "%02x", $0) }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-wx", "com.apple.metadata:_kMDItemUserTags", hex, path]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func flipped(_ tags: [String]) -> [String] {
        tags.map { $0 == "Unread" ? "Read" : ($0 == "Read" ? "Unread" : $0) }
    }

    // MARK: - The test

    func testChainAtCorpusSize() async throws {
        guard let rootPath = handshake("chain") else {
            throw XCTSkip("no chain root — run ops/scale/run-reader-at-size.sh --only chain (\(handshakeFile))")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard !rootPath.contains("Google Drive"), root.lastPathComponent.hasPrefix("scale-corpus"),
              root.lastPathComponent.hasSuffix("-chain"), FileManager.default.fileExists(atPath: rootPath) else {
            throw XCTSkip("the chain root must be an existing scale-corpus*-chain clone: \(rootPath)")
        }
        print("CH build=\(optimized ? "-O" : "Debug(-Onone)") root=\(rootPath)")
        let ledger = scratch.appendingPathComponent("audit-ledger.jsonl")
        savedLedgerURL = AuditLedger.shared.fileURL
        AuditLedger.shared.fileURL = ledger
        defer { if let saved = savedLedgerURL { AuditLedger.shared.fileURL = saved } }

        meter = MainThreadMeter()
        meter.start()
        defer { meter.stop() }
        let footprintStart = footprintMiB()

        // ── The library, live: the real walk and the real FSEvents watcher on the clone.
        indexer = ContentIndexer(url: scratch.appendingPathComponent("content-index.sqlite3"))
        let start = now()
        let navigation = NavigationModel(defaults: fixtureDefaults(pinnedTo: root), indexer: indexer)
        let listed = await waitUntil(timeout: 600) {
            navigation.library.phase.isSettled && navigation.library.files.count >= 100_000
        }
        XCTAssertTrue(listed, "the library did not list the clone")
        print("CH library listed rows=\(navigation.library.files.count) in \(ms(seconds(since: start)))")
        let indexed = await waitUntil(timeout: 1_800) {
            indexer.progress == nil && indexer.completedPassesForTesting >= 1
        }
        XCTAssertTrue(indexed, "the first index pass did not finish")
        print("CH first index pass done at \(ms(seconds(since: start))) footprint \(Int(footprintMiB())) MiB")

        // ── Ten smart folders, two with OCR-text rules (the synthetic PDFs have no text, so those two
        // measure the query and row test, not FTS posting-list cost; W40.d7's search@102k has that).
        func rule(_ field: RuleField, _ op: RuleOperator? = nil, _ edit: (inout SearchRule) -> Void) -> SearchRule {
            var r = SearchRule(field: field, op: op); edit(&r); return r
        }
        let folders: [(String, AdvancedSearch)] = [
            ("Unread", AdvancedSearch(rules: [rule(.readState) { $0.read = .unread }])),
            ("Box 12", AdvancedSearch(rules: [rule(.tags, .hasAny) { $0.tags = ["Box 12"] }])),
            ("Correspondence read", AdvancedSearch(rules: [rule(.tags, .hasAll) { $0.tags = ["Correspondence"] },
                                                          rule(.readState) { $0.read = .read }])),
            ("Memoranda", AdvancedSearch(rules: [rule(.tags, .hasAny) { $0.tags = ["Memoranda"] }])),
            ("1970s", AdvancedSearch(rules: [rule(.date, .between) { $0.text = "1970"; $0.text2 = "1979" }])),
            ("Undated", AdvancedSearch(rules: [rule(.date, .undated) { _ in }])),
            ("Quality 3", AdvancedSearch(rules: [rule(.quality) { $0.qualities = [3] }])),
            ("Name has 1", AdvancedSearch(rules: [rule(.fileName, .contains) { $0.text = "1" }])),
            ("OCR budget", AdvancedSearch(rules: [rule(.ocrText, .allWords) { $0.text = "budget" }])),
            ("OCR memo unread", AdvancedSearch(combine: .all, rules: [rule(.ocrText, .anyWords) { $0.text = "memorandum Treasury" },
                                                                     rule(.readState) { $0.read = .unread }])),
        ]
        for (name, search) in folders { navigation.savedSearches.add(name: name, search: search) }
        let counted = await waitUntil(timeout: 300) { navigation.smartFolderCounts.count == folders.count }
        XCTAssertTrue(counted, "the smart-folder counts did not arrive")
        print("CH smart folders \(folders.count): " + navigation.savedSearches.searches
            .map { "\($0.name)=\(navigation.smartFolderCounts[$0.id] ?? -1)" }.joined(separator: ", "))
        XCTAssertEqual(navigation.savedSearches.searches.filter { $0.search.hasTextRules }.count, 2)

        navigation.filter = LibraryFilter()      // All: every row listed
        navigation.recompute()
        XCTAssertEqual(navigation.displayed.count, navigation.library.files.count)
        print("CH list rows=\(navigation.displayed.count) footprint \(Int(footprintMiB())) MiB (start \(Int(footprintStart)))")

        // ── Emulated views: the inspector (library window) and the table.
        let views = ViewEmulation(navigation)
        views.attach()

        // The meter's floor: what an idle main thread reads.
        _ = await waitUntil(timeout: 600) { indexer.progress == nil }
        await pause(1)
        meter.resetPings()
        await pause(3)
        let idle = meter.pings()
        print("CH idle 3 s: main-busy \(ms(idle.stalled)) longest-stall \(ms(idle.longest))")

        // ── 1. One foreign tag change: another process flips Read/Unread on one listed file.
        var foreign: [Chain] = []
        for k in 0..<3 {
            let file = navigation.displayed[(navigation.displayed.count / 4) * (k + 1)]
            let tags = Self.flipped(file.tags.raw)
            let generation = navigation.displayedGeneration
            let path = file.path
            let chain = await measureChain("foreign tag change, 1 file (run \(k + 1))", trigger: {
                Task.detached { _ = Self.writeTagsElsewhere(tags, to: path) }
            }, visible: { navigation.displayedGeneration != generation })
            foreign.append(chain)
            let row = navigation.library.files.first { $0.path == path }
            XCTAssertEqual(row?.tags.raw.sorted(), tags.sorted(), "the foreign write reached the library")
        }
        summarize("foreign-1", foreign)
        assertChangeBudget("foreign-1", foreign, busy: 0.050, visible: 0.500, excludingWriter: false)

        // ── 2. A Reader write (Mark Read / Unread) on 1 and on 20 files, inside a smart folder.
        let box12 = try XCTUnwrap(navigation.savedSearches.searches.first { $0.name == "Box 12" })
        navigation.applyScope(box12)
        _ = await waitUntil(timeout: 30) { navigation.displayed.count < navigation.library.files.count }
        print("CH scope Box 12 rows=\(navigation.displayed.count)")
        for count in [1, 20] {
            var runs: [Chain] = []
            for k in 0..<4 {
                let first = (navigation.displayed.count / 5) * (k % 4 + 1)
                let targets = Array(navigation.displayed[first..<(first + count)])
                navigation.selection = Set(targets.map(\.id))
                await pause(0.3)
                let target: ReadState = targets[0].readState == .read ? .unread : .read
                let generation = navigation.displayedGeneration
                runs.append(await measureChain("Reader write \(target.rawValue), \(count) file(s) in a smart folder (run \(k + 1))",
                                               trigger: { navigation.mark(target) },
                                               visible: { navigation.displayedGeneration != generation }))
            }
            summarize("reader-write-\(count)", runs)
            assertChangeBudget("reader-write-\(count)", runs, busy: 0.150, visible: 0.250, excludingWriter: true)
        }
        navigation.removeFilter(.smartFolder)
        _ = await waitUntil(timeout: 30) { navigation.displayed.count == navigation.library.files.count }

        // ── 3. Selection: an arrow key with 1 and with 500 selected, ⇧-extending by one row. Edit Info is shown,
        // the costlier case: a hidden inspector follows nothing (W40.fix-reader-selection-at-size).
        navigation.showingEditor = true
        let ids = navigation.displayed.map(\.id)
        let base = ids.count / 2
        func selectionChain(_ label: String, setup: Set<URL>, change: Set<URL>) async -> Chain {
            navigation.selection = setup
            await pause(0.3)
            return await measureChain(label, quiet: 1.0, trigger: { navigation.selection = change },
                                      visible: { navigation.selectedFilesCache.count == change.count })
        }
        var arrow1: [Chain] = [], arrow500: [Chain] = [], shift1: [Chain] = [], shift500: [Chain] = []
        for k in 0..<3 {
            let a = base + k * 1_000
            arrow1.append(await selectionChain("arrow, 1 selected (run \(k + 1))", setup: [ids[a]], change: [ids[a + 1]]))
            arrow500.append(await selectionChain("arrow, 500 selected (run \(k + 1))",
                                                 setup: Set(ids[a..<(a + 500)]), change: [ids[a + 500]]))
            shift1.append(await selectionChain("shift-extend, 1 to 2 (run \(k + 1))", setup: [ids[a]],
                                               change: [ids[a], ids[a + 1]]))
            shift500.append(await selectionChain("shift-extend, 500 to 501 (run \(k + 1))",
                                                 setup: Set(ids[a..<(a + 500)]), change: Set(ids[a...(a + 500)])))
        }
        summarize("arrow-1", arrow1)
        summarize("arrow-500", arrow500)
        summarize("shift-extend-1", shift1)
        summarize("shift-extend-500", shift500)
        var preview: [Chain] = []
        for k in 0..<3 {
            navigation.selection = [ids[base + k * 1_000]]
            await pause(0.3)
            let before = navigation.selection
            preview.append(await measureChain("preview arrow (moveSelectionInList), 1 selected (run \(k + 1))", quiet: 1.0,
                                              trigger: { navigation.moveSelectionInList(1) },
                                              visible: { navigation.selection != before }))
        }
        summarize("preview-arrow-1", preview)
        navigation.showingEditor = false
        for (label, runs) in [("arrow-1", arrow1), ("arrow-500", arrow500), ("shift-extend-1", shift1),
                              ("shift-extend-500", shift500), ("preview-arrow-1", preview)] {
            assertSelectionBudget(label, runs)
        }

        // ── 4. A document window with 5 files open, switching file. Real PDFs from the W40.c2 sample when
        // the harness names it (scratch clones, read only), else synthetic ones from the clone.
        let samplePaths = handshake("viewer-files")?.split(separator: "|").map(String.init) ?? []
        let viewerPaths = samplePaths.count >= 5 ? Array(samplePaths.prefix(5))
            : ids[base..<(base + 5)].map(\.path)
        print("CH viewer files: \(samplePaths.count >= 5 ? "5 real sample PDFs" : "5 synthetic PDFs (tiny, no text)")")
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: viewerPaths))
        let window = DocumentWindowEmulation(viewer, navigation)
        window.attach()
        await pause(1)
        var switches: [Chain] = []
        for k in 0..<8 {
            let before = viewer.current
            let target = (viewer.index + 1) % viewerPaths.count
            switches.append(await measureChain("document window file switch, 5 open (run \(k + 1))", quiet: 1.0,
                                               trigger: { viewer.index = target },
                                               visible: { viewer.current !== before && window.renderedIndex == target }))
        }
        summarize("viewer-switch-5", switches)
        assertViewerBudget("viewer-switch-5", switches)

        // ── 5. Memory over a session: 200 tag edits and 200 file switches, footprint every 20 steps.
        print(String(format: "CH memory start footprint %.0f MiB collation-strings %d", footprintMiB(),
                     LibrarySort.collation.count))
        await outside("footprint", "start")
        await outside("heap", "start")
        let memoryStart = footprintMiB()
        let editIDs = stride(from: 0, to: ids.count, by: ids.count / 200).prefix(200).map { ids[$0] }
        let editsStart = now()
        for step in 1...200 {
            let id = editIDs[step - 1]
            navigation.selection = [id]
            let file = navigation.selectedFiles.first
            let generation = navigation.displayedGeneration
            navigation.mark(file?.readState == .read ? .unread : .read)
            _ = await waitUntil(timeout: 60) { navigation.displayedGeneration != generation }
            let current = viewer.current
            viewer.index = (viewer.index + 1) % viewerPaths.count
            _ = await waitUntil(timeout: 10) { viewer.current !== current && window.renderedIndex == viewer.index }
            if step % 20 == 0 {
                _ = await waitUntil(timeout: 600) { indexer.progress == nil }
                print(String(format: "CH memory step %d footprint %.0f MiB (%+.0f) collation-strings %d elapsed %.0f s",
                             step, footprintMiB(), footprintMiB() - memoryStart, LibrarySort.collation.count,
                             seconds(since: editsStart)))
            }
        }
        _ = await waitUntil(timeout: 600) { indexer.progress == nil }
        await pause(3)
        let busyEnd = footprintMiB()
        print(String(format: "CH memory after 200+200 footprint %.0f MiB (%+.0f)", busyEnd, busyEnd - memoryStart))
        await outside("footprint", "end-busy")
        await outside("heap", "end-busy")
        await pause(60)                                   // the quiet minute
        let quietEnd = footprintMiB()
        print(String(format: "CH memory after a quiet minute footprint %.0f MiB (%+.0f from start, %+.0f from busy end)",
                     quietEnd, quietEnd - memoryStart, quietEnd - busyEnd))
        if optimized {
            XCTAssertLessThanOrEqual(quietEnd - memoryStart, 100, "200 edits plateau within 100 MB of the start")
        }
        await outside("footprint", "end-quiet")
        await outside("heap", "end-quiet")
        await outside("leaks", "end-quiet", timeout: 1_200)

        window.detach()
        views.detach()
        await indexer.closeForTesting()
        print(String(format: "CH footprint %.0f -> %.0f MiB", footprintStart, footprintMiB()))
    }
}

// MARK: - Main-thread meter

/// Main-thread stalls: a background thread sends one main-queue ping at a time and times its return, so
/// blocking I/O on main counts as well as CPU.
final class MainThreadMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var stalled: UInt64 = 0
    private var longest: UInt64 = 0

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sent = DispatchTime.now().uptimeNanoseconds
                let back = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { back.signal() }
                back.wait()
                let latency = DispatchTime.now().uptimeNanoseconds - sent
                lock.withLock {
                    if latency > 4_000_000 { stalled += latency }
                    longest = max(longest, latency)
                }
                usleep(1_000)
            }
        }
        thread.name = "W40.reader-scale-measure.ping"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { running = false } }
    func resetPings() { lock.withLock { stalled = 0; longest = 0 } }
    func pings() -> (stalled: Double, longest: Double) {
        lock.withLock { (Double(stalled) / 1e9, Double(longest) / 1e9) }
    }
}

// MARK: - Emulated views

/// What the library window's mounted views run after a publish, once per main-queue turn as SwiftUI would:
/// the inspector's `libraryFiles(atPaths:)` over the selection (`TagEditorView`), the table's `showRows` on a
/// new `displayed` and `syncSelection` on a new selection.
@MainActor
final class ViewEmulation {
    private let navigation: NavigationModel
    private var cancellable: AnyCancellable?
    private var pending = false
    private let coordinator: AppKitTableView.Coordinator
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
    private var shownGeneration = -1
    private var shownSelection = Set<URL>()

    init(_ navigation: NavigationModel) {
        self.navigation = navigation
        let tableView = NSTableView(frame: scrollView.bounds)
        scrollView.documentView = tableView
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = max(20, 13 * 1.8)
        for column in AppKitTableView.columnDefinitions {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tc.width = column.width
            tableView.addTableColumn(tc)
        }
        coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: navigation, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = tableView
        let coordinator = coordinator
        let dataSource = SortableDiffableDataSource(tableView: tableView) { tv, column, _, itemID in
            coordinator.makeCell(tableView: tv, column: column, itemID: itemID)
        }
        coordinator.dataSource = dataSource
        tableView.delegate = coordinator
    }

    func attach() {
        render()
        cancellable = navigation.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated {
            guard let self, !self.pending else { return }
            self.pending = true
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.render() } }
        } }
    }

    func detach() { cancellable = nil }

    private func render() {
        pending = false
        // The inspector's editor runs only while it is shown, on the paths it holds (`inspectorTarget`).
        if navigation.showingEditor {
            let paths = navigation.inspectorTarget.paths
            ReaderStages.measure("view.inspector body (emulated)") { _ = navigation.libraryFiles(atPaths: paths) }
        }
        if navigation.displayedGeneration != shownGeneration {
            shownGeneration = navigation.displayedGeneration
            ReaderStages.measure("view.table showRows (emulated)") { _ = coordinator.showRows(navigation.displayed,
                                                                                    orderGeneration: navigation.displayedOrderGeneration) }
        }
        if navigation.selection != shownSelection {
            shownSelection = navigation.selection
            ReaderStages.measure("view.table syncSelection (emulated)") { coordinator.syncSelection(shownSelection) }
            // The preview's image prefetch asks for the rows around a single selection on each change.
            ReaderStages.measure("view.prefetch paths (emulated)") { _ = navigation.previewPrefetchPaths(neighbours: true) }
        }
    }
}

/// A document window: its own inspector on the open file (`DocumentWindowView` mounts one on the navigation
/// model), and the two panes, each showing a copy of its page in a one-page document (`PDFPaneView.show`).
///
/// PDFKit draws a page's tiles on its own `PDFTilePool` queue, not the main thread: sampled in the VM with
/// real PDFViews on the real sample (W40.fix-reader-viewer-switch), PDFKit came to 65 main-thread samples over
/// about 15 switches and image decoding to 1, against 1,778 on the tile queue. So the page's draw is emulated
/// off the main actor, and what the main actor does is the copy and, when the image page's bitmap is drawn
/// ahead (`DocumentWindowView`'s placeholder), drawing that bitmap at pane size. The file is visible when the
/// bitmap is drawn, or else when the off-main draw lands. (W40.reader-scale-measure drew the page on the main
/// actor here, 188 ms a switch, which no real view does.)
@MainActor
final class DocumentWindowEmulation {
    private let viewer: DocumentViewerModel
    private let navigation: NavigationModel
    private var cancellables: Set<AnyCancellable> = []
    private var pending = false
    private(set) var renderedIndex = -1
    private var drawing: Int?

    init(_ viewer: DocumentViewerModel, _ navigation: NavigationModel) {
        self.viewer = viewer
        self.navigation = navigation
    }

    func attach() {
        viewer.imagePrefetcher.setPixelBox(longSide: 1_200)
        render()
        for publisher in [viewer.objectWillChange.eraseToAnyPublisher(),
                          navigation.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self, !self.pending else { return }
                self.pending = true
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.render() } }
            } }.store(in: &cancellables)
        }
    }

    func detach() { cancellables = [] }

    private func render() {
        pending = false
        let index = viewer.index
        guard viewer.urls.indices.contains(index) else { return }
        let path = viewer.urls[index].path
        if viewer.showingTagEditor {   // a hidden inspector observes nothing (W40.fix-reader-selection-at-size)
            ReaderStages.measure("view.document inspector body (emulated)") { _ = navigation.libraryFiles(atPaths: [path]) }
        }
        guard renderedIndex != index, drawing != index, let document = viewer.current else { return }
        ReaderStages.measure("view.document panes copy (emulated)") {
            for pageIndex in 0..<min(2, document.pageCount) {
                guard let page = document.page(at: pageIndex), let copy = page.copy() as? PDFPage else { continue }
                PDFDocument().insert(copy, at: 0)
            }
        }
        let bitmap = viewer.imagePrefetcher.image(path: path, pageIndex: 0)?.image
        viewer.imagePrefetcher.prefetch(paths: viewer.neighbourhoodPaths)
        if let bitmap {
            ReaderStages.measure("view.document placeholder draw (emulated)") {
                guard let ctx = CGContext(data: nil, width: 900, height: 1_200, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.interpolationQuality = .high
                ctx.draw(bitmap, in: CGRect(x: 0, y: 0, width: 900, height: 1_200))
            }
            renderedIndex = index
        } else {
            drawing = index   // PDFKit's tile draw, off the main actor, from its own read of the file
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = PreviewImagePrefetcher.render(path: path, pageIndex: 0, pixelBox: CGSize(width: 900, height: 1_200))
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.drawing == index else { return }
                    self.drawing = nil
                    if self.viewer.index == index { self.renderedIndex = index }
                } }
            }
        }
    }
}
