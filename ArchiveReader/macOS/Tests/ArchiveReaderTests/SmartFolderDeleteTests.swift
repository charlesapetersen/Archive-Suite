import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-smart-folder-delete (owner, 2026-11-13: "Deleting a smart folder led to beach ball."). At corpus
/// size, deleting the open smart folder rebuilt the whole list on the main thread (1.2 s in Debug, measured by
/// `ReaderChainAtSizeTests`), and deleting any folder recounted every other one over the whole library. Here a
/// deletion that is not open recounts nothing, and the open one's list is built off the main actor, superseded by
/// a recompute or a library change that lands meanwhile. Rows are made in memory under a path that does not exist;
/// nothing is read or written but a scratch content index.
@MainActor
final class SmartFolderDeleteTests: XCTestCase {
    private let base = "/private/tmp/W40-sf-delete-\(UUID().uuidString)"
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartFolderDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ReaderStages.recorder.reset(recording: false)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// `count` rows over the size the model builds off the main actor; every third is in "Box 12", every other read.
    private func rows(_ count: Int, prefix: String = "doc") -> [ArchiveFile] {
        (0..<count).map { i in
            let tags = [i % 2 == 0 ? "Read" : "Unread"] + (i % 3 == 0 ? ["Box 12"] : [])
            let entry = CorpusEntry(url: URL(fileURLWithPath: "\(base)/Box \(i % 7)/\(prefix) \(i).pdf"),
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
        model.library.replaceFilesForTesting(rows(1_500))
        _ = await waitUntil { model.displayed.count == 1_500 }
        return (model, indexer)
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    private func box12() -> AdvancedSearch {
        var rule = SearchRule(field: .tags, op: .hasAny)
        rule.tags = ["Box 12"]
        return AdvancedSearch(rules: [rule])
    }

    private func unread() -> AdvancedSearch {
        var rule = SearchRule(field: .readState)
        rule.read = .unread
        return AdvancedSearch(rules: [rule])
    }

    private func stage(_ name: String, onMain: Bool) -> Int {
        ReaderStages.recorder.snapshot().totals.filter { $0.key.stage == name && $0.key.onMain == onMain }
            .values.reduce(0) { $0 + $1.count }
    }

    func testDeletingAFolderNotOpenRecountsNothing() async throws {
        let (model, indexer) = await makeModel()
        let kept = try XCTUnwrap(model.savedSearches.add(name: "Box 12", search: box12()))
        let gone = try XCTUnwrap(model.savedSearches.add(name: "Unread", search: unread()))
        let counted = await waitUntil { model.smartFolderCounts[kept] == 500 && model.smartFolderCounts[gone] == 750 }
        XCTAssertTrue(counted, "precondition: both counted")
        try? await Task.sleep(nanoseconds: 200_000_000)

        ReaderStages.recorder.reset(recording: true)
        model.deleteSmartFolder(gone)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(stage("model.countMatches.rows", onMain: false), 0, "the remaining folder is not recounted")
        XCTAssertEqual(model.smartFolderCounts, [kept: 500], "its count stands; the deleted one's is gone")
        XCTAssertEqual(model.savedSearches.searches.map(\.id), [kept])
        XCTAssertEqual(model.displayed.count, 1_500, "the list is not touched")

        // The counts are still live: a tag change moves the kept folder's count by its difference.
        let first = try XCTUnwrap(model.library.files.first { !$0.tags.raw.contains("Box 12") })
        var changed = model.library.files
        let i = try XCTUnwrap(changed.firstIndex { $0.path == first.path })
        let tags = first.tags.raw + ["Box 12"]
        changed[i] = ArchiveLibrary.row(CorpusEntry(url: URL(fileURLWithPath: first.path), tagNames: tags,
                                                    labelNumber: nil, contentModified: first.contentModified,
                                                    contentTypeIdentifier: "com.adobe.pdf", isDataless: false),
                                        tagNames: tags, labelNumber: nil)
        model.library.replaceFilesForTesting(changed)
        let arrived1 = await waitUntil { model.smartFolderCounts[kept] == 501 }
        XCTAssertTrue(arrived1, "the count follows a later change")
        await indexer.closeForTesting()
    }

    func testDeletingTheOpenFolderBuildsTheListOffTheMainThread() async throws {
        let (model, indexer) = await makeModel()
        let open = try XCTUnwrap(model.savedSearches.add(name: "Box 12", search: box12()))
        let other = try XCTUnwrap(model.savedSearches.add(name: "Unread", search: unread()))
        _ = await waitUntil { model.smartFolderCounts.count == 2 }
        model.applyScope(try XCTUnwrap(model.savedSearches.searches.first { $0.id == open }))
        XCTAssertEqual(model.displayed.count, 500, "precondition: the folder is open")
        let backBefore = model.placeHistory.back.count
        try? await Task.sleep(nanoseconds: 200_000_000)

        ReaderStages.recorder.reset(recording: true)
        model.deleteSmartFolder(open)
        XCTAssertNil(model.scope, "the deleted folder is left at once")
        let arrived2 = await waitUntil { model.displayed.count == 1_500 }
        XCTAssertTrue(arrived2, "the list shows All Files")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(stage("presentation.build", onMain: true), 0, "no whole-list build on the main thread")
        XCTAssertEqual(stage("presentation.build (background)", onMain: false), 1, "one, off it")
        XCTAssertEqual(stage("model.countMatches.rows", onMain: false), 0, "the other folder is not recounted")
        XCTAssertEqual(model.smartFolderCounts, [other: 750])
        XCTAssertEqual(model.placeHistory.back.count, backBefore, "a deletion is not a move for Back")

        // The store's own change, arriving after, finds the scope already left and builds nothing more.
        XCTAssertEqual(model.displayed.count, 1_500)
        await indexer.closeForTesting()
    }

    func testARecomputeDuringTheBuildWins() async throws {
        let (model, indexer) = await makeModel()
        let open = try XCTUnwrap(model.savedSearches.add(name: "Box 12", search: box12()))
        _ = await waitUntil { model.smartFolderCounts.count == 1 }
        model.applyScope(try XCTUnwrap(model.savedSearches.searches.first { $0.id == open }))

        model.deleteSmartFolder(open)
        model.filter.read = .unread
        model.recompute()   // a filter change before the background list arrives
        XCTAssertEqual(model.displayed.count, 750)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.displayed.count, 750, "the superseded background list is dropped")
        XCTAssertTrue(model.displayed.allSatisfy { $0.readState == .unread })
        await indexer.closeForTesting()
    }

    func testALibraryChangeDuringTheBuildWins() async throws {
        let (model, indexer) = await makeModel()
        let open = try XCTUnwrap(model.savedSearches.add(name: "Box 12", search: box12()))
        _ = await waitUntil { model.smartFolderCounts.count == 1 }
        model.applyScope(try XCTUnwrap(model.savedSearches.searches.first { $0.id == open }))

        model.deleteSmartFolder(open)
        model.library.replaceFilesForTesting(rows(1_200, prefix: "new"))   // rows come and go meanwhile
        let arrived3 = await waitUntil { model.displayed.count == 1_200 }
        XCTAssertTrue(arrived3, "the library's own rebuild presents")
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.displayed.count, 1_200, "the stale background list never replaces it")
        XCTAssertTrue(model.displayed.allSatisfy { $0.path.contains("/new ") })
        await indexer.closeForTesting()
    }
}
