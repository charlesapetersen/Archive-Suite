import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.idx end-to-end warm-start contract: cache rows are useful immediately, visibly marked as
/// cached, and never outrank a fresh stat/tag read. Scratch roots and scratch SQLite files only.
@MainActor
final class LibraryWarmStartTests: XCTestCase {
    func testColdQuitWarmPublishesCacheBeforeWalkThenCorrectsAClosedAppTagChange() async throws {
        XCTAssertNil(UserDefaults.standard.string(forKey: "ARUITestRootPath"),
                     "warm-start tests must exercise the production asynchronous path")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryWarmStartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        let database = scratch.appendingPathComponent("library-index.sqlite3")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let file = corpus.appendingPathComponent("report.pdf")
        try Data("PDF fixture bytes".utf8).write(to: file)
        try setTags(["Unread", "Subject/Before"], on: file)
        let marker = UUID()

        let cold = ArchiveLibrary(libraryIndexURL: database,
                                  watcherFactory: { _, _ in SilentWarmStartWatcher() })
        cold.start(scope: corpus, markerGUID: marker)
        try await wait("the cold pass and its SQLite commit") { cold.phase.isSettled }
        XCTAssertEqual(cold.files.first?.tags.raw, ["Unread", "Subject/Before"])
        XCTAssertFalse(try XCTUnwrap(cold.files.first).provenance.isCache)

        // Model the app closing, then a Finder edit while Reader is absent. The xattr write changes
        // ctime but not mtime; this is the exact stale-cache hole the fingerprint tuple must close.
        cold.start(scope: nil)
        try setTags(["Read", "Subject/After"], on: file)

        let paused = PausedIndexedScan()
        let warm = ArchiveLibrary(libraryIndexURL: database,
                                  watcherFactory: { _, _ in SilentWarmStartWatcher() },
                                  indexedScanStarter: { paused.request = $0 })
        warm.start(scope: corpus, markerGUID: marker)
        try await wait("the cache to publish before revalidation") { paused.request != nil }

        guard case let .revalidating(asOf) = warm.phase else {
            return XCTFail("warm rows must remain explicitly revalidating, got \(warm.phase)")
        }
        XCTAssertNotNil(asOf, "the preceding clean scan supplies the cache's honest as-of date")
        XCTAssertEqual(warm.files.first?.tags.raw, ["Unread", "Subject/Before"],
                       "the old row is useful immediately, before the held filesystem pass")
        guard case let .cache(rowAsOf) = try XCTUnwrap(warm.files.first).provenance else {
            return XCTFail("a pre-walk row must say it came from cache")
        }
        XCTAssertEqual(rowAsOf, asOf)

        // Release the exact production revalidation algorithm. Deliver on the main actor, matching
        // the production thread wrapper's callback contract.
        let request = try XCTUnwrap(paused.request)
        let pass = LibraryScan.revalidatedPass(root: request.root, cached: request.cached,
                                               isCancelled: request.isCancelled,
                                               onBatch: request.onBatch)
        request.completion(pass)
        try await wait("revalidation and its SQLite commit") { warm.phase.isSettled }

        XCTAssertEqual(warm.files.first?.tags.raw, ["Read", "Subject/After"],
                       "fresh ctime forces a disk read that corrects the warm row")
        guard case .disk = try XCTUnwrap(warm.files.first).provenance else {
            return XCTFail("the corrected row must be disk-verified")
        }
        await cold.closeLibraryIndexForTesting()
        await warm.closeLibraryIndexForTesting()
    }

    func testOldIndexedCompletionCannotPublishAcrossRootSwitchPreparationGap() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let database = scratch.appendingPathComponent("library-index.sqlite3")
        let rootA = try makeCorpus(named: "A", file: "a.pdf", tags: ["Unread"], under: scratch)
        let rootB = try makeCorpus(named: "B", file: "b.pdf", tags: ["Read"], under: scratch)
        let markerA = UUID()
        let markerB = UUID()

        let seed = ArchiveLibrary(libraryIndexURL: database,
                                  watcherFactory: { _, _ in SilentWarmStartWatcher() })
        seed.start(scope: rootA, markerGUID: markerA)
        try await wait("root A to seed its cache") { seed.phase.isSettled }
        seed.start(scope: nil)

        let paused = PausedIndexedScan()
        let library = ArchiveLibrary(libraryIndexURL: database,
                                     watcherFactory: { _, _ in SilentWarmStartWatcher() },
                                     indexedScanStarter: { paused.request = $0 })
        library.start(scope: rootA, markerGUID: markerA)
        try await wait("root A warm request") { paused.request?.root == rootA }
        let oldRequest = try XCTUnwrap(paused.request)
        let oldPass = LibraryScan.revalidatedPass(root: rootA, cached: oldRequest.cached,
                                                  isCancelled: { false })

        library.start(scope: rootB, markerGUID: markerB)
        oldRequest.completion(oldPass) // deliberately late, before B's async index prepare can finish

        XCTAssertTrue(library.files.isEmpty,
                      "the old root must publish nothing during the new root's preparation gap")
        XCTAssertEqual(library.scopeDescription, rootB.lastPathComponent)
        try await wait("root B indexed request") { paused.request?.root == rootB }
        let newRequest = try XCTUnwrap(paused.request)
        let newPass = LibraryScan.revalidatedPass(root: rootB, cached: newRequest.cached,
                                                  isCancelled: newRequest.isCancelled)
        newRequest.completion(newPass)
        try await wait("root B to settle") { library.phase.isSettled }

        XCTAssertEqual(library.files.map(\.name), ["b.pdf"])
        await seed.closeLibraryIndexForTesting()
        await library.closeLibraryIndexForTesting()
    }

    func testVerifiedWriteDuringIndexCommitOutranksTheEarlierScan() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let database = scratch.appendingPathComponent("library-index.sqlite3")
        let corpus = try makeCorpus(named: "corpus", file: "target.pdf", tags: ["Unread"],
                                    under: scratch)
        let file = corpus.appendingPathComponent("target.pdf")
        let marker = UUID()

        let seed = ArchiveLibrary(libraryIndexURL: database,
                                  watcherFactory: { _, _ in SilentWarmStartWatcher() })
        seed.start(scope: corpus, markerGUID: marker)
        try await wait("the seed pass") { seed.phase.isSettled }
        seed.start(scope: nil)

        let paused = PausedIndexedScan()
        let library = ArchiveLibrary(libraryIndexURL: database,
                                     watcherFactory: { _, _ in SilentWarmStartWatcher() },
                                     indexedScanStarter: { paused.request = $0 })
        library.start(scope: corpus, markerGUID: marker)
        try await wait("the held revalidation") { paused.request != nil }
        let request = try XCTUnwrap(paused.request)
        let pass = LibraryScan.revalidatedPass(root: corpus, cached: request.cached,
                                               isCancelled: request.isCancelled)

        request.completion(pass) // creates the SQLite commit task, but this actor has not yielded
        let write = try TagWriter.setReadState(.read, on: file)
        library.applyVerifiedWrites([write])
        XCTAssertEqual(library.files.first?.readState, .read)

        try await wait("the commit to publish") { library.phase.isSettled }
        XCTAssertEqual(library.files.first?.readState, .read,
                       "a pre-write scan cannot overwrite a verified write while its DB commit waits")
        await seed.closeLibraryIndexForTesting()
        await library.closeLibraryIndexForTesting()
    }

    func testCorruptOutOfRootCacheRowIsNeverPublishedAsAWriteTarget() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let outside = scratch.appendingPathComponent("outside.pdf")
        try Data("outside fixture".utf8).write(to: outside)
        try setTags(["Unread", "Subject/Outside"], on: outside)
        guard case let .tracked(outsideEntry) = CorpusWalker.inspect(outside) else {
            return XCTFail("precondition: the outside scratch file is readable and tagged")
        }

        let database = scratch.appendingPathComponent("library-index.sqlite3")
        let marker = UUID()
        let direct = LibraryIndex(url: database)
        let identity = LibraryIndexRoot(path: LibraryIndexPath(corpus).value, markerGUID: marker)
        let scan = try await direct.beginScan(root: identity)
        try await direct.completeScan(
            scan, entries: [outsideEntry],
            verdict: LibraryIndexScanVerdict(finishedAt: Date(), filesSeen: 1, directoryErrors: 0,
                                             outcome: "complete", absenceIsAuthoritative: true)
        )
        await direct.close()

        let paused = PausedIndexedScan()
        let library = ArchiveLibrary(libraryIndexURL: database,
                                     watcherFactory: { _, _ in SilentWarmStartWatcher() },
                                     indexedScanStarter: { paused.request = $0 })
        library.start(scope: corpus, markerGUID: marker)
        try await wait("the corrupt cache to load") { paused.request != nil }

        XCTAssertEqual(paused.request?.cached.count, 1,
                       "precondition: the malformed row really came out of SQLite")
        XCTAssertTrue(library.files.isEmpty,
                      "a cache path outside the granted root must never become selectable or writable")

        let request = try XCTUnwrap(paused.request)
        let pass = LibraryScan.revalidatedPass(root: corpus, cached: request.cached,
                                               isCancelled: request.isCancelled)
        request.completion(pass)
        try await wait("the clean root to evict the malformed row") { library.phase.isSettled }
        XCTAssertTrue(library.files.isEmpty)
        await library.closeLibraryIndexForTesting()
    }

    func testBulkMarkReverifiesCachedRowsAndStillUpdatesValidDiskNeighbours() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        UserDefaults.standard.set(scratch.path, forKey: "ARUITestRootPath")
        UserDefaults.standard.removeObject(forKey: "lastSelectionFileURLs")
        defer {
            UserDefaults.standard.removeObject(forKey: "ARUITestRootPath")
            UserDefaults.standard.removeObject(forKey: "lastSelectionFileURLs")
        }

        let staleURL = scratch.appendingPathComponent("stale.pdf")
        let validURL = scratch.appendingPathComponent("valid.pdf")
        try Data("stale scratch PDF".utf8).write(to: staleURL)
        try Data("valid scratch PDF".utf8).write(to: validURL)
        try setTags(["Unread", "Subject/WasTracked"], on: staleURL)
        try setTags(["Unread", "Subject/Valid"], on: validURL)

        let model = NavigationModel()
        let staleDiskRow = try XCTUnwrap(model.library.files.first { $0.url == staleURL })
        let validDiskRow = try XCTUnwrap(model.library.files.first { $0.url == validURL })
        let staleCacheRow = ArchiveFile(
            url: staleDiskRow.url, name: staleDiskRow.name, fileType: staleDiskRow.fileType,
            tags: staleDiskRow.tags, contentModified: staleDiskRow.contentModified,
            provenance: .cache(asOf: Date())
        )
        model.library.replaceFilesForTesting([staleCacheRow, validDiskRow])

        // Finder changed the formerly cached row while Reader was closed. It is no longer a Reader
        // member, so the stale selection must not add a Read tag and resurrect it into the archive.
        try setTags([], on: staleURL)
        model.selection = [staleURL, validURL]
        XCTAssertEqual(model.selectedFiles.count, 2, "precondition: the mixed selection is active")

        model.mark(.read)

        XCTAssertEqual(try tags(on: staleURL), [],
                       "an untracked cached path is rejected before any delta is derived")
        XCTAssertEqual(Set(try tags(on: validURL)), Set(["Subject/Valid", "Read"]),
                       "a rejected cached neighbour must not abort valid disk-provenance writes")
        XCTAssertEqual(model.statusMessage, "Marked 1; 1 could not update.")
    }

    func testColdIndexedFingerprintPhaseReportsProgressBeforeTagReads() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for number in 0..<3 {
            try Data("fixture \(number)".utf8)
                .write(to: scratch.appendingPathComponent("\(number).pdf"))
        }
        let batches = ScanBatchProbe()

        _ = LibraryScan.revalidatedPass(
            root: scratch, cached: [:], options: CorpusWalker.Options(batchSize: 2),
            onBatch: { batches.record($0) }
        )

        XCTAssertEqual(batches.values.map(\.filesSeen), [2, 3, 3, 3],
                       "cold discovery must visibly advance during the first traversal and never reset")
        XCTAssertEqual(batches.values.map { $0.entries.count }, [0, 0, 2, 1],
                       "fingerprint progress precedes the second phase's tag-verified row batches")
    }

    private func setTags(_ tags: [String], on url: URL) throws {
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    private func tags(on url: URL) throws -> [String] {
        (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    private func makeScratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryWarmStartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCorpus(named name: String, file: String, tags: [String], under scratch: URL) throws -> URL {
        let root = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(file)
        try Data("PDF fixture bytes".utf8).write(to: url)
        try setTags(tags, on: url)
        return root
    }

    private func wait(_ description: String, timeout: TimeInterval = 10,
                      until condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }
}

@MainActor
private final class PausedIndexedScan {
    var request: IndexedLibraryScanRequest?
}

private final class SilentWarmStartWatcher: CorpusWatching {
    func start() -> CorpusWatcherStartResult { .started }
    func stop() {}
    func flushSync() -> Bool { true }
}

private final class ScanBatchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [CorpusScanBatch] = []

    func record(_ batch: CorpusScanBatch) { lock.withLock { batches.append(batch) } }
    var values: [CorpusScanBatch] { lock.withLock { batches } }
}
