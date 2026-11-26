import ArchiveCore
import Combine
import CoreGraphics
import XCTest
@testable import ArchiveReader

/// W49.reader-catalogue-scale: Catalogue Mode keeps its list current from file-system events without walking
/// and reading the whole root, and starts warm from a saved cache. Every root is a scratch directory.
@MainActor
final class ReaderCatalogueLiveTests: XCTestCase {
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderCatalogueLive-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - The revision, on its own

    func testARevisionAgreesWithAFullPassAfterEditsAddsAndRemovals() throws {
        let root = try makeRoot()
        let a = try item("Box 1/A.pdf", subjects: ["Alpha"], in: root)
        _ = try item("Box 1/B.pdf", subjects: ["Beta"], in: root)
        _ = try item("Box 2/C.pdf", subjects: ["Gamma"], in: root)
        try plainPDF("Box 2/Plain.pdf", in: root)
        let instance = UUID()
        let first = run(root, instance)
        XCTAssertEqual(first.rows.map(\.name), ["A.pdf", "B.pdf", "C.pdf", "Plain.pdf"])

        // An edited companion, a removed PDF, a new PDF in a new folder (named only by its folder), and a
        // rewritten PDF.
        try companion(for: a, subjects: ["Alpha", "Edited"]).write(to: companionURL("Box 1/A.pdf", in: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Box 1/B.pdf"))
        _ = try item("Box 3/D.pdf", subjects: ["Delta"], in: root)
        try plainPDF("Box 2/Plain.pdf", in: root)
        let paths = [companionURL("Box 1/A.pdf", in: root).path, root.appendingPathComponent("Box 1/B.pdf").path,
                     root.appendingPathComponent("Box 2/Plain.pdf").path]
        let revised = try XCTUnwrap(ReaderCatalogueScan.revise(
            first, root: root, paths: paths,
            subtrees: [root.appendingPathComponent("Box 3").path], isCancelled: { false }))
        let full = run(root, instance)
        XCTAssertEqual(revised.rows.map(\.path), full.rows.map(\.path))
        XCTAssertEqual(revised.rows.map(\.subjects), full.rows.map(\.subjects))
        XCTAssertEqual(revised.rows.first?.subjects, ["Alpha", "Edited"])
        XCTAssertEqual(revised.rows.map(\.name), ["A.pdf", "C.pdf", "Plain.pdf", "D.pdf"])
    }

    func testARevisionFollowsAnOwnerThatMovesAndThenLeaves() throws {
        let root = try makeRoot()
        let owner = try item("Owner/Letter.pdf", subjects: ["Owned"], in: root)
        try member("Member/Enclosure.pdf", owner: owner, in: root)
        let first = run(root, UUID())
        let member = try XCTUnwrap(first.rows.first { $0.name == "Enclosure.pdf" })
        XCTAssertEqual(member.subjects, ["Owned"], "precondition: the member reads its owner's fields")

        // The owner and its companion move to another folder: two removals and two additions, by path.
        let moved = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        for name in ["Letter.pdf", "Letter.pdf.archivesuite.json"] {
            try FileManager.default.moveItem(at: root.appendingPathComponent("Owner/\(name)"),
                                             to: moved.appendingPathComponent(name))
        }
        let movedPaths = ["Owner/Letter.pdf", "Owner/Letter.pdf.archivesuite.json",
                          "Elsewhere/Letter.pdf", "Elsewhere/Letter.pdf.archivesuite.json"]
            .map { root.appendingPathComponent($0).path }
        let afterMove = try XCTUnwrap(ReaderCatalogueScan.revise(first, root: root,
                                                                 paths: movedPaths, subtrees: [], isCancelled: { false }))
        XCTAssertEqual(afterMove.rows.first { $0.name == "Enclosure.pdf" }?.subjects, ["Owned"])
        XCTAssertEqual(afterMove.rows.first { $0.name == "Letter.pdf" }?.path,
                       moved.appendingPathComponent("Letter.pdf").path)

        // The owner leaves the root: the member's document is unavailable, as a full pass says.
        try FileManager.default.removeItem(at: moved)
        let afterRemoval = try XCTUnwrap(ReaderCatalogueScan.revise(afterMove, root: root,
                                                                    paths: [moved.path], subtrees: [], isCancelled: { false }))
        let full = run(root, first.snapshot!.rootInstanceID)
        XCTAssertEqual(afterRemoval.rows.map(\.path), full.rows.map(\.path))
        XCTAssertEqual(afterRemoval.rows.first?.subjects, [])
        XCTAssertEqual(afterRemoval.rows.first?.subjects, full.rows.first?.subjects)
    }

    func testARevisionDeclinesWhatOnlyAFullPassCanAnswer() throws {
        let root = try makeRoot()
        _ = try item("A.pdf", subjects: ["Alpha"], in: root)
        let first = run(root, UUID())
        XCTAssertNil(ReaderCatalogueScan.revise(first, root: root, paths: ["/elsewhere/X.pdf"],
                                                subtrees: [], isCancelled: { false }),
                     "a path outside the root")
        XCTAssertNil(ReaderCatalogueScan.revise(first, root: root,
                                                paths: [root.appendingPathComponent("A.pdf").path],
                                                subtrees: [], isCancelled: { true }),
                     "a cancelled revision")
        let unsettled = ReaderCatalogueScan(reader: first.reader, snapshot: nil, rows: first.rows, health: first.health,
                                            rootStability: first.rootStability, rootPath: first.rootPath,
                                            walkIsComplete: true, candidates: first.candidates)
        XCTAssertNil(ReaderCatalogueScan.revise(unsettled, root: root, paths: [], subtrees: [],
                                                isCancelled: { false }),
                     "a pass with no snapshot to carry")
        let incomplete = ReaderCatalogueScan(reader: first.reader, snapshot: first.snapshot, rows: first.rows,
                                             health: first.health, rootStability: first.rootStability,
                                             rootPath: first.rootPath, walkIsComplete: false, candidates: first.candidates)
        XCTAssertNil(ReaderCatalogueScan.revise(incomplete, root: root, paths: [], subtrees: [], isCancelled: { false }),
                     "an incomplete inventory, which only a walk can complete")
        try FileManager.default.linkItem(at: root.appendingPathComponent("A.pdf"), to: root.appendingPathComponent("Link.pdf"))
        XCTAssertNil(ReaderCatalogueScan.revise(first, root: root, paths: [root.appendingPathComponent("Link.pdf").path],
                                                subtrees: [], isCancelled: { false }),
                     "a new hard link, which changes the read of a path no event names")
    }

    func testTheWarmCacheShowsTheRowsBeforeTheWalkOnlyForItsOwnInstance() throws {
        let root = try makeRoot()
        _ = try item("A.pdf", subjects: ["Alpha"], in: root)
        try plainPDF("Plain.pdf", in: root)
        let instance = UUID()
        let first = run(root, instance)
        let saved = try XCTUnwrap(first.cache(instance: instance))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let cache = try PropertyListDecoder().decode(ReaderCatalogueCache.self, from: encoder.encode(saved))

        final class Box: @unchecked Sendable { var rows: [ArchiveFile]? }
        let box = Box()
        let pass = ReaderCatalogueScan.run(root: root, instance: instance, warm: cache, isCancelled: { false },
                                           onWarm: { rows, _ in box.rows = rows }, onProgress: { _ in })
        let warm = try XCTUnwrap(box.rows)
        XCTAssertEqual(warm.map(\.path), pass.rows.map(\.path))
        XCTAssertEqual(warm.map(\.subjects), pass.rows.map(\.subjects))
        XCTAssertTrue(warm.allSatisfy { $0.provenance.isCache })
        XCTAssertFalse(pass.rows.contains { $0.provenance.isCache })

        let other = Box()
        _ = ReaderCatalogueScan.run(root: root, instance: UUID(), warm: cache, isCancelled: { false },
                                    onWarm: { rows, _ in other.rows = rows }, onProgress: { _ in })
        XCTAssertNil(other.rows, "another instance's cache is never shown")

        let elsewhere = ReaderCatalogueCache(instance: instance, rootPath: cache.rootPath + "-moved", savedAt: cache.savedAt,
                                             memory: cache.memory, files: cache.files)
        let moved = Box()
        _ = ReaderCatalogueScan.run(root: root, instance: instance, warm: elsewhere, isCancelled: { false },
                                    onWarm: { rows, _ in moved.rows = rows }, onProgress: { _ in })
        XCTAssertNil(moved.rows, "a cache saved under another root path names files that are not there")
    }

    // MARK: - The library

    func testTheLibraryAppliesCatalogueEventsWithoutAFullWalk() async throws {
        let root = try makeRoot()
        let a = try item("Box/A.pdf", subjects: ["Alpha"], in: root)
        _ = try item("Box/B.pdf", subjects: ["Beta"], in: root)
        let capture = WatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil, catalogueCacheDirectory: nil,
                                     defaults: fixtureDefaults()) { _, handler in
            let watcher = EmittingWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root, markerGUID: UUID(), catalogueInstance: UUID())
        try await waitUntil { library.phase.isSettled && library.files.count == 2 }
        let walks = library.rootScanStartsForTesting

        try companion(for: a, subjects: ["Alpha", "Live"]).write(to: companionURL("Box/A.pdf", in: root))
        capture.latest?.emit(CorpusWatchRequest(paths: [companionURL("Box/A.pdf", in: root).path]))
        try await waitUntil { library.files.first?.subjects == ["Alpha", "Live"] }
        _ = try item("Box/C.pdf", subjects: ["Gamma"], in: root)
        capture.latest?.emit(CorpusWatchRequest(paths: [root.appendingPathComponent("Box/C.pdf").path]))
        try await waitUntil { library.files.count == 3 }
        XCTAssertEqual(library.rootScanStartsForTesting, walks, "a named change is a revision, not a walk")
        XCTAssertTrue(library.phase.isSettled)
        XCTAssertNotNil(try library.catalogueSnapshot?.facts(at: "Box/C.pdf").file.get())

        capture.latest?.emit(CorpusWatchRequest(fullRescan: true))
        try await waitUntil { library.rootScanStartsForTesting == walks + 1 && library.phase.isSettled }
        XCTAssertEqual(library.files.map(\.name), ["A.pdf", "B.pdf", "C.pdf"])
    }

    /// W49.reader-catalogue-edit-revise: FSEvents drops the Reader's own writes, so after each kind of catalogue
    /// write the library is revised for the written companions, and must then match a full pass without one.
    func testTheReadersOwnCatalogueWritesAreRevisedToMatchAFullPass() async throws {
        try await assertOwnWritesAreRevised(root: makeRoot())
    }

    /// The same under a root whose name is decomposed non-ASCII: the revision's paths are spelled from the pass's
    /// own root prefix, so they must still name the rows the walk listed.
    func testOwnWritesAreRevisedUnderADecomposedNonASCIIRoot() async throws {
        let root = scratch.appendingPathComponent("Pa\u{0308}pste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await assertOwnWritesAreRevised(root: root)
    }

    private func assertOwnWritesAreRevised(root: URL) async throws {
        let a = try item("Box/A.pdf", subjects: ["Alpha"], in: root)
        _ = try item("Box/B.pdf", subjects: ["Beta"], in: root)
        let owner = try item("Owner/Letter.pdf", subjects: ["Owned"], in: root)
        try member("Member/Enclosure.pdf", owner: owner, in: root)
        try plainPDF("Box/Plain.pdf", in: root)
        let capture = WatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil, catalogueCacheDirectory: nil,
                                     defaults: fixtureDefaults()) { _, handler in
            let watcher = EmittingWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root, markerGUID: UUID(), catalogueInstance: UUID())
        try await waitUntil { library.phase.isSettled && library.files.count == 5 }
        let walks = library.rootScanStartsForTesting
        let reader = try XCTUnwrap(library.catalogueReader)
        let writer = CatalogueWriter(reader: reader)
        func facts(_ path: String) throws -> ItemFacts.FileFacts {
            try XCTUnwrap(library.catalogueSnapshot).facts(at: path).file.get()
        }
        func subjects(_ name: String) -> [String]? { library.files.first { $0.name == name }?.subjects }
        func setSubjects(_ identity: Identity, _ values: [String], at path: String) throws -> CatalogueWriter.Receipt {
            try writer.save([CatalogueEdit(.document(identity.document, .subjects), .set(.names(values)))],
                            basedOn: facts(path))
        }
        func revise(_ pdfPaths: String...) {
            library.reviseCatalogue(relativePaths: pdfPaths.map { CatalogueRecord.companionFilename(forPDFFilename: $0) })
        }
        func paired(_ rows: [ArchiveFile]) -> [Bool] { rows.map { (try? $0.catalogueFacts?.file.get()) != nil } }
        func assertMatchesAFullPass(_ step: String, line: UInt = #line) async throws {
            try await waitUntil { library.phase.isSettled }
            let full = run(root, reader.rootInstanceID)
            XCTAssertEqual(library.files.map(\.path), full.rows.map(\.path), step, line: line)
            XCTAssertEqual(library.files.map(\.subjects), full.rows.map(\.subjects), step, line: line)
            XCTAssertEqual(library.files.map(\.tags), full.rows.map(\.tags), step, line: line)
            XCTAssertEqual(library.files.map(\.catalogueDocuments.count), full.rows.map(\.catalogueDocuments.count),
                           step, line: line)
            XCTAssertEqual(paired(library.files), paired(full.rows), step, line: line)
            XCTAssertEqual(library.rootScanStartsForTesting, walks, "\(step): a revision, not a walk", line: line)
        }

        // A field edit on a stand-alone record.
        let edit = try setSubjects(a, ["Alpha", "Edited"], at: "Box/A.pdf")
        revise("Box/A.pdf")
        try await waitUntil { subjects("A.pdf") == ["Alpha", "Edited"] }
        try await assertMatchesAFullPass("field edit")

        // An owner's edit reaches its member in another folder.
        _ = try setSubjects(owner, ["Owned", "Again"], at: "Owner/Letter.pdf")
        revise("Owner/Letter.pdf")
        try await waitUntil { subjects("Enclosure.pdf") == ["Owned", "Again"] }
        try await assertMatchesAFullPass("owner edit")

        // Undo of the first edit.
        let inverse = try XCTUnwrap(edit.inverse)
        _ = try writer.reverse(inverse, basedOn: facts("Box/A.pdf"))
        revise("Box/A.pdf")
        try await waitUntil { subjects("A.pdf") == ["Alpha"] }
        try await assertMatchesAFullPass("undo")

        // A companion repair after an outside rename, then its undo.
        let beforeRename = try facts("Box/B.pdf")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Box/B.pdf"),
                                         to: root.appendingPathComponent("Box/B2.pdf"))
        capture.latest?.emit(CorpusWatchRequest(paths: [root.appendingPathComponent("Box/B.pdf").path,
                                                        root.appendingPathComponent("Box/B2.pdf").path]))
        try await waitUntil { library.files.contains { $0.name == "B2.pdf" } }
        let unrepaired = subjects("B2.pdf")
        XCTAssertNotEqual(unrepaired, ["Beta"], "precondition: the renamed PDF has lost its companion")
        let receipt = try writer.reassociateCompanion(
            from: beforeRename, to: .init(rootInstanceID: reader.rootInstanceID, relativePath: "Box/B2.pdf"))
        revise("Box/B.pdf", "Box/B2.pdf")
        try await waitUntil { subjects("B2.pdf") == ["Beta"] }
        try await assertMatchesAFullPass("companion repair")
        _ = try writer.undoReassociation(receipt)
        revise("Box/B.pdf", "Box/B2.pdf")
        try await waitUntil { subjects("B2.pdf") == unrepaired }
        try await assertMatchesAFullPass("repair undo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: companionURL("Box/B.pdf", in: root).path))
    }

    func testTheLibrarySavesItsListAndTheNextStartShowsItWarm() async throws {
        let root = try makeRoot()
        _ = try item("A.pdf", subjects: ["Alpha"], in: root)
        _ = try item("B.pdf", subjects: ["Beta"], in: root)
        let cacheDirectory = scratch.appendingPathComponent("cache", isDirectory: true)
        let instance = UUID()
        let first = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil,
                                   catalogueCacheDirectory: cacheDirectory, defaults: fixtureDefaults()) { _, handler in
            EmittingWatcher(handler: handler)
        }
        first.start(scope: root, markerGUID: UUID(), catalogueInstance: instance)
        try await waitUntil { first.phase.isSettled && first.files.count == 2 }
        first.flushCatalogueCacheForTesting()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ReaderCatalogueCache.url(in: cacheDirectory, instance: instance).path))
        first.start(scope: nil)

        let second = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil,
                                    catalogueCacheDirectory: cacheDirectory, defaults: fixtureDefaults()) { _, handler in
            EmittingWatcher(handler: handler)
        }
        final class Published: @unchecked Sendable { var lists: [[ArchiveFile]] = [] }
        let published = Published()
        let observation = second.$filesRevision.sink { [weak second] _ in
            MainActor.assumeIsolated { published.lists.append(second?.files ?? []) }
        }
        defer { observation.cancel() }
        second.start(scope: root, markerGUID: UUID(), catalogueInstance: instance)
        try await waitUntil { second.phase.isSettled && second.files.count == 2 }
        let warm = try XCTUnwrap(published.lists.first { !$0.isEmpty }, "the saved list was published")
        XCTAssertEqual(warm.map(\.name), ["A.pdf", "B.pdf"])
        XCTAssertTrue(warm.allSatisfy { $0.provenance.isCache }, "before the walk, the rows are the cache's")
        XCTAssertEqual(warm.map(\.subjects), [["Alpha"], ["Beta"]])
        XCTAssertFalse(second.files.contains { $0.provenance.isCache }, "the walk replaces them")
        XCTAssertNotNil(second.catalogueReader)

        // A damaged cache is a cold start, not a failure.
        try Data("not a cache".utf8).write(to: ReaderCatalogueCache.url(in: cacheDirectory, instance: instance))
        let third = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil,
                                   catalogueCacheDirectory: cacheDirectory, defaults: fixtureDefaults()) { _, handler in
            EmittingWatcher(handler: handler)
        }
        third.start(scope: root, markerGUID: UUID(), catalogueInstance: instance)
        try await waitUntil { third.phase.isSettled && third.files.count == 2 }
    }

    // MARK: - At size

    /// A thousand catalogued PDFs: a revision for one changed companion must cost a small part of a pass.
    /// Measured, and asserted only loosely, since unattended sessions run at a throttled priority.
    func testARevisionAtAThousandFilesCostsAFractionOfAPass() throws {
        let root = try makeRoot()
        var items: [Identity] = []
        for index in 0..<1_000 {
            let path = "Box \(index / 100)/Item \(index).pdf"
            items.append(try index.isMultiple(of: 4) ? item(path, subjects: ["S\(index)"], in: root) : plainPDF(path, in: root))
        }
        let instance = UUID()
        let (cold, coldSeconds) = timed { run(root, instance) }
        let (_, warmSeconds) = timed {
            ReaderCatalogueScan.run(root: root, instance: instance, memory: cold.snapshot?.memory,
                                    isCancelled: { false }, onProgress: { _ in })
        }
        try companion(for: items[0], subjects: ["Changed"]).write(to: companionURL("Box 0/Item 0.pdf", in: root))
        let (revised, reviseSeconds) = timed {
            ReaderCatalogueScan.revise(cold, root: root,
                                       paths: [companionURL("Box 0/Item 0.pdf", in: root).path], subtrees: [],
                                       isCancelled: { false })
        }
        print("W49 catalogue rows=\(cold.rows.count) cold pass \(ms(coldSeconds)), pass with memory \(ms(warmSeconds)), "
              + "revision of one companion \(ms(reviseSeconds))")
        XCTAssertEqual(revised?.rows.first { $0.name == "Item 0.pdf" }?.subjects, ["Changed"])
        XCTAssertLessThan(reviseSeconds, coldSeconds, "a one-file revision is cheaper than reading every file")
        XCTAssertLessThan(warmSeconds, coldSeconds, "unchanged files are not parsed again")
    }

    // MARK: - Fixtures

    private struct Identity {
        let pdf: CataloguePDFIdentity
        let document = UUID()
        let page = UUID()
    }

    private func makeRoot() throws -> URL {
        let root = scratch.appendingPathComponent("root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func run(_ root: URL, _ instance: UUID) -> ReaderCatalogueScan {
        ReaderCatalogueScan.run(root: root, instance: instance, isCancelled: { false }, onProgress: { _ in })
    }

    @discardableResult
    private func item(_ path: String, subjects: [String], in root: URL) throws -> Identity {
        let identity = Identity(pdf: CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID()))
        try writePDF(path, identity: identity.pdf, in: root)
        try companion(for: identity, subjects: subjects).write(to: companionURL(path, in: root))
        return identity
    }

    /// A PDF whose single page belongs to `owner`'s document, which holds the fields.
    private func member(_ path: String, owner: Identity, in root: URL) throws {
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        try writePDF(path, identity: identity, in: root)
        try Data("""
            {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)","revision":"\(UUID())",
             "parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(owner.document)","role":"searchable"}],
             "documents":[{"id":"\(owner.document)","ownerFileID":"\(owner.pdf.fileID)"}],"fileFields":{}}
            """.utf8).write(to: companionURL(path, in: root))
    }

    @discardableResult
    private func plainPDF(_ path: String, in root: URL) throws -> Identity {
        try writePDF(path, identity: nil, in: root)
        return Identity(pdf: CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID()))
    }

    private func companion(for identity: Identity, subjects: [String]) throws -> Data {
        let values = try String(decoding: JSONSerialization.data(withJSONObject: subjects), as: UTF8.self)
        return Data("""
            {"schema":1,"fileID":"\(identity.pdf.fileID)","contentRevision":"\(identity.pdf.contentRevision)",
             "revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(identity.page)","physicalIndex":0,"documentID":"\(identity.document)","role":"searchable"}],
             "documents":[{"id":"\(identity.document)","ownerFileID":"\(identity.pdf.fileID)","fields":{
               "subjects":{"state":"value","value":\(values),"fieldRevision":"\(UUID())","origin":"user"}}}],
             "fileFields":{}}
            """.utf8)
    }

    private func companionURL(_ path: String, in root: URL) -> URL {
        root.appendingPathComponent(path + ".archivesuite.json")
    }

    private func writePDF(_ path: String, identity: CataloguePDFIdentity?, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF></x:xmpmeta>
            """.utf8)
        var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        if let identity { pdf.addDocumentMetadata(try XCTUnwrap(identity.adding(to: packet)) as CFData) }
        pdf.beginPDFPage(nil)
        pdf.fill(bounds.insetBy(dx: 10, dy: 10))
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }

    private func waitUntil(timeout: TimeInterval = 20, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true within \(timeout)s")
    }
}

private final class EmittingWatcher: CorpusWatching, @unchecked Sendable {
    let handler: CorpusWatcher.Handler
    init(handler: @escaping CorpusWatcher.Handler) { self.handler = handler }
    func start() -> CorpusWatcherStartResult { .started }
    func stop() {}
    func flushSync() -> Bool { true }
    func emit(_ request: CorpusWatchRequest) { handler(request) }
}

private final class WatcherCapture: @unchecked Sendable { var latest: EmittingWatcher? }
