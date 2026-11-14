import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-scope-exit-main. Choosing a folder or All Files, opening a smart folder and a chip's ✕ built
/// the whole list on the main thread: at 115,999 rows, leaving a smart folder by its chip held it 1.16 s in Debug
/// (`ReaderChainAtSizeTests` §2b). At corpus size these now build off the main actor, as deleting the open smart
/// folder does; the list shows the old rows until the new ones are presented, and Back's selection waits for the
/// list it returns to. Rows are made in memory under a path that does not exist; nothing is read or written but a
/// scratch content index.
@MainActor
final class ScopeExitBackgroundTests: XCTestCase {
    private let base = "/private/tmp/W40-scope-exit-\(UUID().uuidString)"
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopeExitBackground-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ReaderStages.recorder.reset(recording: false)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// 1,500 rows, over the size the model builds off the main actor: seven folders, every third row in "Box 12",
    /// every other one read.
    private func rows() -> [ArchiveFile] {
        (0..<1_500).map { i in
            let tags = [i % 2 == 0 ? "Read" : "Unread"] + (i % 3 == 0 ? ["Box 12"] : [])
            let entry = CorpusEntry(url: URL(fileURLWithPath: "\(base)/Box \(i % 7)/doc \(i).pdf"),
                                    tagNames: tags, labelNumber: nil,
                                    contentModified: Date(timeIntervalSince1970: 1_000),
                                    contentTypeIdentifier: "com.adobe.pdf", isDataless: false)
            return ArchiveLibrary.row(entry, tagNames: tags, labelNumber: nil)
        }.sorted { ArchiveLibrary.listedBefore($0.path, $1.path) }
    }

    private func makeModel() async -> (NavigationModel, ContentIndexer) {
        let indexer = ContentIndexer(url: scratch.appendingPathComponent("content.sqlite3"), extractPDFForTesting: { _ in
            ExtractedContent(fullBody: "", strippedBody: "", classification: nil, pageCount: 2)
        })
        let model = NavigationModel(defaults: fixtureDefaults(), indexer: indexer)
        model.library.replaceFilesForTesting(rows())
        _ = await waitUntil { model.displayed.count == 1_500 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return (model, indexer)
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    private func folder(_ n: Int) -> String { "\(base)/Box \(n)" }

    private func box12() -> AdvancedSearch {
        var rule = SearchRule(field: .tags, op: .hasAny)
        rule.tags = ["Box 12"]
        return AdvancedSearch(rules: [rule])
    }

    private func stage(_ name: String, onMain: Bool) -> Int {
        ReaderStages.recorder.snapshot().totals.filter { $0.key.stage == name && $0.key.onMain == onMain }
            .values.reduce(0) { $0 + $1.count }
    }

    /// Run `change`, check the old rows stand until the list is presented, and that the one build was off main.
    private func assertBuiltOffMain(_ model: NavigationModel, _ label: String, _ change: () -> Void) async {
        let before = model.displayed.map(\.id)
        ReaderStages.recorder.reset(recording: true)
        change()
        XCTAssertEqual(model.displayed.map(\.id), before, "\(label): the old rows stand until the new list arrives")
        await model.listPresented()
        XCTAssertEqual(stage("presentation.build", onMain: true), 0, "\(label): no whole-list build on the main thread")
        XCTAssertEqual(stage("presentation.build (background)", onMain: false), 1, "\(label): one, off it")
        ReaderStages.recorder.reset(recording: false)
    }

    func testChoosingAFolderAndAllFilesBuildOffTheMainThread() async {
        let (model, indexer) = await makeModel()
        await assertBuiltOffMain(model, "a folder") { model.setFolderScope(folder(3)) }
        XCTAssertEqual(model.displayed.count, 214)
        XCTAssertTrue(model.displayed.allSatisfy { $0.path.hasPrefix(folder(3) + "/") })

        await assertBuiltOffMain(model, "All Files") { model.setFolderScope(nil) }
        XCTAssertEqual(model.displayed.count, 1_500)
        await indexer.closeForTesting()
    }

    func testOpeningASmartFolderAndItsChipBuildOffTheMainThread() async throws {
        let (model, indexer) = await makeModel()
        let id = try XCTUnwrap(model.savedSearches.add(name: "Box 12", search: box12()))
        let saved = try XCTUnwrap(model.savedSearches.searches.first { $0.id == id })
        _ = await waitUntil { model.smartFolderCounts[id] != nil }

        await assertBuiltOffMain(model, "open a smart folder") { model.applyScope(saved) }
        XCTAssertEqual(model.scope?.id, id)
        XCTAssertEqual(model.displayed.count, 500)

        await assertBuiltOffMain(model, "the chip's ✕") { model.removeFilter(.smartFolder) }
        XCTAssertNil(model.scope)
        XCTAssertEqual(model.displayed.count, 1_500)

        model.filter.read = .unread
        model.recompute()
        XCTAssertEqual(model.displayed.count, 750)
        await assertBuiltOffMain(model, "a filter chip's ✕") { model.removeFilter(.read) }
        XCTAssertEqual(model.displayed.count, 1_500)
        await indexer.closeForTesting()
    }

    func testBackPutsTheSelectionBackWhenTheListArrives() async throws {
        let (model, indexer) = await makeModel()
        model.setFolderScope(folder(1))
        await model.listPresented()
        let picked = model.displayed[3].id
        model.selection = [picked]
        model.setFolderScope(folder(2))
        await model.listPresented()
        XCTAssertTrue(model.selection.isEmpty, "the selection left with its folder")
        model.selection = [model.displayed[0].id]

        model.goBack()
        XCTAssertEqual(model.filter.pathPrefix, folder(1))
        await model.listPresented()
        XCTAssertTrue(model.displayed.allSatisfy { $0.path.hasPrefix(folder(1) + "/") })
        XCTAssertEqual(model.selection, [picked], "the selection is put back once its rows are listed")

        model.goForward()
        await model.listPresented()
        XCTAssertEqual(model.selection.count, 1)
        XCTAssertTrue(model.displayed.contains { model.selection.contains($0.id) }, "only a listed row is selected")
        await indexer.closeForTesting()
    }

    /// The OCR search's ✕ reset the search through a task whose recompute rebuilt the list on main, after the
    /// background build had started (found by the adversarial review).
    func testTheOCRSearchChipBuildsOffTheMainThread() async {
        let (model, indexer) = await makeModel()
        model.fullTextQuery = "nothing here"
        model.runFullTextSearch()
        _ = await waitUntil { model.ftsPaths != nil }
        XCTAssertEqual(model.displayed.count, 0, "precondition: the search hides every row")

        ReaderStages.recorder.reset(recording: true)
        model.removeFilter(.text)
        await model.listPresented()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(stage("presentation.build", onMain: true), 0, "no whole-list build on the main thread")
        XCTAssertEqual(stage("presentation.build (background)", onMain: false), 1)
        XCTAssertEqual(model.displayed.count, 1_500)
        XCTAssertNil(model.ftsPaths)
        XCTAssertNotEqual(model.sort.first?.field, .relevance, "the sort is put back")
        await indexer.closeForTesting()
    }

    /// Back's restore survives the prune of the list it waited for, and no later one: a row a filter then hides
    /// is not selected again (found by the adversarial review; W40.fix-reader-phantom-selection).
    func testAFilterAfterBackEndsTheRestore() async throws {
        let (model, indexer) = await makeModel()
        model.setFolderScope(folder(1))
        await model.listPresented()
        let unread = try XCTUnwrap(model.displayed.first { $0.readState == .unread }).id
        let read = try XCTUnwrap(model.displayed.first { $0.readState == .read }).id
        model.selection = [unread, read]
        model.setFolderScope(folder(2))
        await model.listPresented()
        model.filter.read = .unread
        model.recompute()

        model.goBack()
        await model.listPresented()
        XCTAssertEqual(model.selection, [unread], "the listed half of the selection is put back")
        model.filter.read = .read   // hides the restored row, lists the other
        model.recompute()
        XCTAssertFalse(model.selection.contains(read), "a row the restore never selected is not selected now")
        model.filter.read = .all
        model.recompute()
        XCTAssertTrue(model.selection.isEmpty, "the restore ended when the filter changed the selection")
        await indexer.closeForTesting()
    }

    func testAChangeDuringTheBuildWins() async {
        let (model, indexer) = await makeModel()
        model.setFolderScope(folder(1))
        model.filter.read = .unread
        model.recompute()   // a filter change before the background list arrives
        let shown = model.displayed.map(\.id)
        XCTAssertTrue(model.displayed.allSatisfy { $0.readState == .unread && $0.path.hasPrefix(folder(1) + "/") })
        await model.listPresented()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.displayed.map(\.id), shown, "the superseded background list is dropped")

        model.setFolderScope(folder(2))
        model.setFolderScope(folder(4))   // a second click before the first list arrives
        await model.listPresented()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.displayed.allSatisfy { $0.path.hasPrefix(folder(4) + "/") }, "the last click's list stands")
        XCTAssertFalse(model.displayed.isEmpty)
        await indexer.closeForTesting()
    }
}
