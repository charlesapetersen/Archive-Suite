import Foundation
import Testing
@testable import ArchiveNotes

/// Opt-in corpus-scale acceptance check. The runner flag enables a guarded fixture under the test host's
/// temporary directory; ordinary unit runs return immediately.
@Suite("NotesScalePerfTests — 100k notes / 2M words")
@MainActor
struct NotesScalePerfTests {
    private struct Manifest {
        let itemCount: Int
        let wordsPerItem: Int
        let wordCount: Int
        let lastItemID: UUID
        let uniqueQuery: String
    }

    @Test func fullIndexSearchSummariesAndNavigationStayBoundedAtCorpusScale() async throws {
        guard ProcessInfo.processInfo.environment["ARCHIVE_NOTES_SCALE_ACCEPTANCE"] == "1" else {
            return
        }
        let root = try makeScaleFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Manifest(itemCount: 100_000, wordsPerItem: 20, wordCount: 2_000_000,
                                lastItemID: UUID(uuidString: try String(contentsOf: root.appendingPathComponent("scale-manifest-last-id"), encoding: .utf8))!,
                                uniqueQuery: "scaleunique100000")
        #expect(NotesTagProjector.isScratchPath(root.path), "scale fixture must stay under a scratch prefix")
        let realStore = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveNotes/Store", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        #expect(root != realStore && !root.path.hasPrefix(realStore.path + "/"), "fixture must never be the live Notes store")

        #expect(manifest.itemCount == 100_000)
        #expect(manifest.wordsPerItem == 20)
        #expect(manifest.wordCount == 2_000_000)

        let index = NotesIndex(url: root.appendingPathComponent("scale-index.sqlite3"))
        try await index.open()
        let organization = OrganizationStore(index: index)
        try await organization.load(storeRoot: root)
        let noteStore = NoteStore(root: root)
        let indexer = NotesIndexer(index: index)
        let model = NotesModel(organization: organization, index: index, noteStore: noteStore, indexer: indexer)

        let indexStart = CFAbsoluteTimeGetCurrent()
        await model.buildIndexFromDisk()
        let indexSeconds = CFAbsoluteTimeGetCurrent() - indexStart
        #expect(model.isIndexReady)
        #expect(model.indexFailure == nil)
        #expect(model.allItems.count == manifest.itemCount)
        #expect(indexSeconds < 300, "100k-note incremental index build took \(indexSeconds)s (300s limit)")

        let searchStart = CFAbsoluteTimeGetCurrent()
        let matches = await indexer.search(manifest.uniqueQuery)
        let searchSeconds = CFAbsoluteTimeGetCurrent() - searchStart
        #expect(matches == [manifest.lastItemID])
        #expect(searchSeconds < 5, "unique FTS search took \(searchSeconds)s (5s limit)")

        let summariesStart = CFAbsoluteTimeGetCurrent()
        let summaries = await index.allSummaries()
        let summariesSeconds = CFAbsoluteTimeGetCurrent() - summariesStart
        #expect(summaries.count == manifest.itemCount)
        #expect(summariesSeconds < 10, "loading 100k summaries took \(summariesSeconds)s (10s limit)")

        let navigation = NotesNavigationModel(model: model, defaultKind: .note)
        let recomputeStart = CFAbsoluteTimeGetCurrent()
        navigation.recompute(items: summaries)
        let recomputeSchedulingSeconds = navigation.lastRecomputeSchedulingSeconds
        await navigation.waitForPendingRecompute()
        let recomputeSeconds = CFAbsoluteTimeGetCurrent() - recomputeStart
        #expect(navigation.displayed.count == manifest.itemCount)
        #expect(recomputeSeconds < 5, "100k-item filter/sort took \(recomputeSeconds)s (5s limit)")
        #expect(recomputeSchedulingSeconds < 1.0 / 60.0,
                "navigation scheduling blocked the main actor for \(recomputeSchedulingSeconds)s")
        #expect(navigation.lastRecomputeApplySeconds < 1.0 / 60.0,
                "navigation state application blocked the main actor for \(navigation.lastRecomputeApplySeconds)s")

        print(String(format: "SCALE_ACCEPTANCE index=%.3fs search=%.3fs summaries=%.3fs recompute=%.3fs schedule=%.3fms apply=%.3fms",
                     indexSeconds, searchSeconds, summariesSeconds, recomputeSeconds,
                     recomputeSchedulingSeconds * 1_000, navigation.lastRecomputeApplySeconds * 1_000))
        await index.close()
    }

    private func makeScaleFixture() throws -> URL {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = tempRoot.appendingPathComponent("archive-notes-scale-\(UUID().uuidString)", isDirectory: true)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot.path.hasPrefix(tempRoot.path + "/"), NotesTagProjector.isScratchPath(resolvedRoot.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let realStore = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveNotes/Store", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let realCorpus = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Google Drive/Archival Photos", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot != realStore, !resolvedRoot.path.hasPrefix(realStore.path + "/"),
              resolvedRoot != realCorpus, !resolvedRoot.path.hasPrefix(realCorpus.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let itemsDirectory = root.appendingPathComponent("items", isDirectory: true)
        try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: false)

        let timestamp = "2026-01-01T00:00:00Z"
        let commonWords = "scale corpus record entry archive index search note item document durable link metadata authors source page vault specimen"
        var lastID = UUID()
        for number in 1...100_000 {
            let id = UUID()
            let title = "Scale Note \(number)"
            let body = "\(commonWords) scaleunique\(String(format: "%06d", number)) marker"
            let markdown = "---\nschema: 1\nid: \(id.uuidString.lowercased())\nkind: note\ntitle: \(title)\nroundup: false\ncreated: \(timestamp)\nmodified: \(timestamp)\n---\n\(body)\n"
            let itemDirectory = itemsDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: false)
            try Data(markdown.utf8).write(to: itemDirectory.appendingPathComponent("\(title).md"), options: .atomic)
            lastID = id
        }
        try Data(lastID.uuidString.lowercased().utf8).write(to: root.appendingPathComponent("scale-manifest-last-id"), options: .atomic)
        return root
    }
}
