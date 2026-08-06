import XCTest
import CoreServices
import ArchiveCore
@testable import ArchiveReader

final class CorpusWatchRequestTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/fsev-root", isDirectory: true)
    private func flag(_ value: Int) -> FSEventStreamEventFlags { FSEventStreamEventFlags(value) }

    func testSemanticItemFlagsNeverDecideWhatHappened() {
        let path = root.appendingPathComponent("changed.pdf").path
        let lied = flag(kFSEventStreamEventFlagItemRenamed)
            | flag(kFSEventStreamEventFlagItemModified)
            | flag(kFSEventStreamEventFlagItemXattrMod)

        let request = CorpusWatchRequest.reduce(root: root, paths: [path], flags: [lied])

        XCTAssertEqual(request.paths, [path], "unioned flags mean only: re-stat and re-read this path")
        XCTAssertFalse(request.fullRescan)
    }

    func testOwnEventsAndMeasuredAtomicSiblingsAreSkippedPrecisely() {
        let own = root.appendingPathComponent("ours.pdf").path
        let temp = root.appendingPathComponent("a.txt.sb-858602c2-RXb79N").path
        let ordinary = root.appendingPathComponent("research.sb-notes.pdf").path
        let request = CorpusWatchRequest.reduce(
            root: root,
            paths: [own, temp, ordinary],
            flags: [flag(kFSEventStreamEventFlagOwnEvent), 0, 0]
        )

        XCTAssertEqual(request.paths, [ordinary])
        XCTAssertTrue(CorpusWatchRequest.isAtomicWriteTemporarySibling(temp))
        XCTAssertFalse(CorpusWatchRequest.isAtomicWriteTemporarySibling(ordinary),
                       "a broad `.sb-` substring test would hide a legitimate corpus filename")
    }

    func testMustScanSubDirsCompactsDescendantsAndSupersedesExactPaths() {
        let box = root.appendingPathComponent("Box").path
        let child = root.appendingPathComponent("Box/Nested").path
        let leaf = root.appendingPathComponent("Box/Nested/leaf.pdf").path
        let request = CorpusWatchRequest.reduce(
            root: root,
            paths: [box, child, leaf],
            flags: [flag(kFSEventStreamEventFlagMustScanSubDirs),
                    flag(kFSEventStreamEventFlagMustScanSubDirs), 0]
        )

        XCTAssertEqual(request.subtrees, [box])
        XCTAssertTrue(request.paths.isEmpty)
    }

    func testRecoveryFlagsOverrideOwnEventSuppression() {
        let own = flag(kFSEventStreamEventFlagOwnEvent)
        let subtree = CorpusWatchRequest.reduce(
            root: root, paths: [root.appendingPathComponent("Box").path],
            flags: [own | flag(kFSEventStreamEventFlagMustScanSubDirs)]
        )
        XCTAssertEqual(subtree.subtrees, [root.appendingPathComponent("Box").path],
                       "a dropped/coalesced range can contain external work even if OwnEvent is unioned")

        let wrapped = CorpusWatchRequest.reduce(
            root: root, paths: [root.path],
            flags: [own | flag(kFSEventStreamEventFlagEventIdsWrapped)]
        )
        XCTAssertTrue(wrapped.fullRescan)

        let moved = CorpusWatchRequest.reduce(
            root: root, paths: [root.path],
            flags: [own | flag(kFSEventStreamEventFlagRootChanged)]
        )
        XCTAssertTrue(moved.reResolveRoot)

        let movedAndDropped = CorpusWatchRequest.reduce(
            root: root, paths: ["/"],
            flags: [flag(kFSEventStreamEventFlagRootChanged)
                    | flag(kFSEventStreamEventFlagUserDropped)]
        )
        XCTAssertEqual(movedAndDropped, CorpusWatchRequest(reResolveRoot: true),
                       "bookmark re-resolution must outrank a recovery walk of the obsolete path")
    }

    func testDroppedAndHistorySentinelsIgnoreTheirPathAndRecoverTheWholeRoot() {
        let own = flag(kFSEventStreamEventFlagOwnEvent)
        let dropped = CorpusWatchRequest.reduce(
            root: root,
            paths: ["/"],
            flags: [own | flag(kFSEventStreamEventFlagUserDropped)]
        )
        XCTAssertTrue(dropped.fullRescan,
                      "the SDK permits `/` for a dropped-event sentinel and requires every watched directory")

        let history = CorpusWatchRequest.reduce(
            root: root,
            paths: ["/this/path/is/documented-as-meaningless"],
            flags: [flag(kFSEventStreamEventFlagHistoryDone)]
        )
        XCTAssertTrue(history.fullRescan,
                      "HistoryDone explicitly has no meaningful path; containment must not discard it")
    }

    func testOutsideRootPathsAreNeverRead() {
        let request = CorpusWatchRequest.reduce(root: root,
                                                paths: ["/tmp/not-the-granted-root/private.pdf"],
                                                flags: [0])
        XCTAssertTrue(request.isEmpty)
    }

    func testCanonicalEquivalentEventPathsRemainByteDistinct() {
        let composed = root.path + "/caf\u{e9}.pdf"
        let decomposed = root.path + "/cafe\u{301}.pdf"
        XCTAssertEqual(composed, decomposed, "precondition: ordinary Swift equality collapses them")

        let request = CorpusWatchRequest.reduce(root: root, paths: [composed, decomposed], flags: [0, 0])

        XCTAssertEqual(request.paths.count, 2,
                       "coalescing must retain both filesystem spellings for independent re-reads")
        XCTAssertTrue(request.paths.contains(composed))
        XCTAssertTrue(request.paths.contains(decomposed))
        XCTAssertFalse(CorpusWatchRequest.contains(
            root.path + "/cafe\u{301}/child.pdf", under: root.path + "/caf\u{e9}"
        ), "canonical-equivalent directory names are not the same containment boundary")
        XCTAssertTrue(CorpusWatchRequest.contains("/tmp/archive/file.pdf", under: "/"),
                      "selecting the filesystem root must retain every absolute descendant event")
        // Every component visible: the cursor arithmetic must reconstruct `/Users`, then
        // `/Users/Shared` — a dropped or doubled first separator resolves neither.
        XCTAssertTrue(CorpusWatchEligibility.includes(
            ExactFileURL.make("/Users/Shared/archive-fixture.pdf"),
            under: ExactFileURL.make("/", isDirectory: true)
        ), "root eligibility must not drop or double the first path separator")
        // And the launch walk's `.skipsHiddenFiles` universe still applies to the FIRST component.
        // macOS marks `/tmp` hidden, so an event under it is not eligible even when the root is `/`.
        XCTAssertFalse(CorpusWatchEligibility.includes(
            ExactFileURL.make("/tmp/archive/file.pdf"),
            under: ExactFileURL.make("/", isDirectory: true)
        ), "a hidden first component stays outside the walk's universe, root or not")
    }
}

@MainActor
final class CorpusWatcherLibraryTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusWatcherLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func makeFile(_ relative: String, tags: [String], root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return url
    }

    private func waitUntil(timeout: TimeInterval = 10,
                           _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true within \(timeout)s")
    }

    func testAThirdPartyPathReadUpdatesTheRowWithoutAFullWalk() async throws {
        let root = try makeRoot()
        let file = try makeFile("changed.pdf", tags: ["Unread"], root: root)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }
        let scansBefore = library.rootScanStartsForTesting

        // A fresh URL simulates Finder/Processor changing only the tag xattr.
        try (URL(fileURLWithPath: file.path) as NSURL)
            .setResourceValue(["Read", "Subject/External"], forKey: .tagNamesKey)
        capture.latest?.emit(CorpusWatchRequest(paths: [file.path]))

        try await waitUntil {
            library.files.first?.readState == .read
                && library.files.first?.subjects == ["Subject/External"]
        }
        XCTAssertEqual(library.rootScanStartsForTesting, scansBefore,
                       "an ordinary file event is one stat/tag read, not a full-corpus walk")
    }

    func testComposedFilenameEventKeepsItsExactFilesystemSpellingThroughLiveRead() async throws {
        let root = try makeRoot()
        // Create with the COMPOSED spelling, then adopt whatever the volume actually stored — this
        // boot volume writes the decomposed form. Emitting the test's own composed spelling instead
        // would feed the library an event FSEvents can never deliver (both the walk and the callback
        // report the same on-disk bytes), and the row it added would be a SECOND row for one file.
        try Data("fixture".utf8).write(to: ExactFileURL.make(root.path + "/caf\u{e9}.pdf"))
        let onDisk = try XCTUnwrap(FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let path = fileSystemPath(onDisk)
        let file = ExactFileURL.make(path)
        try (file as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0, libraryIndexURL: nil) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }
        // BYTES, not `String ==`. Swift string equality is canonical, so comparing the spellings as
        // strings passes for an NFC/NFD mismatch — the exact failure this test exists to catch.
        XCTAssertEqual(library.files.first.map { Array(fileSystemPath($0.url).utf8) },
                       Array(path.utf8),
                       "precondition: launch discovery retained the on-disk spelling byte-for-byte")

        try (ExactFileURL.make(path) as NSURL).setResourceValue(["Read", "Subject/Exact"],
                                                                forKey: .tagNamesKey)
        let request = CorpusWatchRequest.reduce(root: root, paths: [path], flags: [0])
        XCTAssertTrue(request.paths.contains(path), "the exact callback path survives reduction")
        capture.latest?.emit(request)

        try await waitUntil {
            library.files.first?.readState == .read
                && library.files.first?.subjects == ["Subject/Exact"]
        }
        XCTAssertEqual(library.files.count, 1,
                       "the live read must UPDATE the discovered row, never add a lookalike beside it")
        XCTAssertEqual(library.files.first.map { Array(fileSystemPath($0.url).utf8) },
                       Array(path.utf8),
                       "live inspection must update the exact row, not an NFC/NFD lookalike")
    }

    private func fileSystemPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) ?? url.path }
    }

    func testMustScanSubDirsReplacesOnlyThatSubtree() async throws {
        let root = try makeRoot()
        try makeFile("outside.pdf", tags: ["Read"], root: root)
        let old = try makeFile("Box/old.pdf", tags: ["Unread"], root: root)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        try FileManager.default.removeItem(at: old)
        try makeFile("Box/new.pdf", tags: ["Read", "Subject/New"], root: root)
        capture.latest?.emit(CorpusWatchRequest(subtrees: [root.appendingPathComponent("Box").path]))

        try await waitUntil {
            Set(library.files.map(\.url.lastPathComponent)) == ["new.pdf", "outside.pdf"]
        }
        XCTAssertTrue(library.phase.isSettled, "a clean subtree replacement preserves full-scan authority")
    }

    func testDirectoryReplacedByTrackedFileRemovesPhantomDescendants() async throws {
        let root = try makeRoot()
        try makeFile("outside.pdf", tags: ["Read"], root: root)
        let old = try makeFile("Box/old.pdf", tags: ["Unread"], root: root)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        try FileManager.default.removeItem(at: old.deletingLastPathComponent())
        let replacement = try makeFile("Box", tags: ["Read", "Subject/Replacement"], root: root)
        capture.latest?.emit(CorpusWatchRequest(paths: [replacement.path]))

        try await waitUntil {
            Set(library.files.map(\.url.lastPathComponent)) == ["Box", "outside.pdf"]
        }
        XCTAssertFalse(library.files.contains { $0.name == "old.pdf" },
                       "a positive non-directory re-stat authoritatively clears the old subtree")
    }

    func testDirectEventsCannotAddHiddenOrPackageDescendantRows() async throws {
        let root = try makeRoot()
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        let hidden = try makeFile(".hidden.pdf", tags: ["Unread"], root: root)
        let packaged = try makeFile("Bundle.rtfd/inside.pdf", tags: ["Read"], root: root)
        capture.latest?.emit(CorpusWatchRequest(paths: [hidden.path, packaged.path]))

        try await waitUntil { library.phase.isSettled && library.rootScanStartsForTesting >= 2 }
        XCTAssertTrue(library.files.isEmpty,
                      "live path reads must preserve skipsHiddenFiles/skipsPackageDescendants")
    }

    func testDirectEventCannotExpandADirectorySymlinkOutsideTheRoot() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try makeFile("secret.pdf", tags: ["Unread", "Subject/Outside"], root: outside)
        let link = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }
        XCTAssertTrue(library.files.isEmpty, "the launch walk must not descend a directory symlink")

        capture.latest?.emit(CorpusWatchRequest(paths: [link.path]))
        try await waitUntil {
            !library.files.isEmpty || library.rootScanStartsForTesting == 2
        }

        XCTAssertTrue(library.files.isEmpty,
                      "a direct event must preserve the launch walk's no-directory-symlink universe")
        XCTAssertEqual(library.rootScanStartsForTesting, 2,
                       "the empty-denominator proof rewalks root instead of following the link")
    }

    func testAnEmptyLiveResultRewalksBeforePublishingAnEmptyDenominator() async throws {
        let root = try makeRoot()
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }
        guard case .settled(_, scanned: 0) = library.phase else {
            return XCTFail("fixture starts genuinely empty")
        }

        let untracked = try makeFile("ordinary.pdf", tags: ["Subject/Only"], root: root)
        capture.latest?.emit(CorpusWatchRequest(paths: [untracked.path]))

        try await waitUntil { library.phase.isSettled && library.rootScanStartsForTesting == 2 }
        guard case let .settled(_, scanned) = library.phase else { return XCTFail("expected settled") }
        XCTAssertEqual(scanned, 1,
                       "path-local changes must not leave the UI claiming a now-nonempty folder is empty")
    }

    func testRootRecoveryFlagsReResolveTheBookmarkOwnerBeforeWalking() async throws {
        let rootA = try makeRoot()
        let rootB = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: rootA)
        try makeFile("b.pdf", tags: ["Read"], root: rootB)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        var resolutions = 0
        library.setRootResolver {
            resolutions += 1
            return ResolvedLibraryRoot(url: rootB, markerGUID: nil)
        }
        library.start(scope: rootA)
        try await waitUntil { library.phase.isSettled }

        library.receiveWatchRequestForTesting(CorpusWatchRequest(reResolveRoot: true))
        try await waitUntil { library.phase.isSettled && library.files.first?.name == "b.pdf" }

        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(library.scopeDescription, rootB.lastPathComponent)
    }

    func testQueuedCallbackFromOldRootCannotAffectReplacementRoot() async throws {
        let rootA = try makeRoot()
        let rootB = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: rootA)
        try makeFile("b.pdf", tags: ["Read"], root: rootB)
        let capture = MockWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = MockCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        library.start(scope: rootA)
        try await waitUntil { library.phase.isSettled }
        let oldWatcher = try XCTUnwrap(capture.latest)

        library.start(scope: rootB)
        try await waitUntil { library.phase.isSettled && library.files.first?.name == "b.pdf" }
        let scansBefore = library.rootScanStartsForTesting
        oldWatcher.emit(CorpusWatchRequest(fullRescan: true))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(library.rootScanStartsForTesting, scansBefore)
        XCTAssertEqual(library.files.map(\.name), ["b.pdf"])
    }

    func testWatchReadStartedBeforeVerifiedWriteCannotOverwriteIt() async throws {
        let root = try makeRoot()
        let file = try makeFile("changed.pdf", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            MockCorpusWatcher(handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        let readGeneration = library.beginWatchReadForTesting()
        let staleInspection = CorpusWalker.inspect(file)
        try (URL(fileURLWithPath: file.path) as NSURL)
            .setResourceValue(["Read", "Subject/User"], forKey: .tagNamesKey)
        library.applyVerifiedWrites([
            TagWriteResult(url: file, before: ["Unread"], after: ["Read", "Subject/User"],
                           beforeLabel: nil, afterLabel: nil,
                           inverse: TagDelta(add: ["Unread"], remove: ["Read", "Subject/User"]))
        ])

        library.finishWatchReadForTesting(
            CorpusWatchChangeSet(paths: [CorpusPathChange(url: file, inspection: staleInspection)],
                                 subtrees: []),
            readGeneration: readGeneration
        )

        XCTAssertEqual(library.files.first?.readState, .read)
        XCTAssertEqual(library.files.first?.subjects, ["Subject/User"],
                       "an older external re-read must yield to the newer verified Reader edit")
    }

    func testVerifiedWritePrecedenceStillKeepsFreshExternalContentMetadata() async throws {
        let root = try makeRoot()
        let file = try makeFile("changed.bin", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            MockCorpusWatcher(handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        let readGeneration = library.beginWatchReadForTesting()
        let freshDate = Date(timeIntervalSince1970: 2_000_000_000)
        let freshEntry = CorpusEntry(url: file, tagNames: ["Unread"], labelNumber: nil,
                                     contentModified: freshDate,
                                     contentTypeIdentifier: "com.adobe.pdf", isDataless: false)
        library.applyVerifiedWrites([
            TagWriteResult(url: file, before: ["Unread"], after: ["Read", "Subject/User"],
                           beforeLabel: nil, afterLabel: nil,
                           inverse: TagDelta(add: ["Unread"], remove: ["Read", "Subject/User"]))
        ])

        library.finishWatchReadForTesting(
            CorpusWatchChangeSet(paths: [CorpusPathChange(url: file,
                                                          inspection: .tracked(freshEntry))],
                                 subtrees: []),
            readGeneration: readGeneration
        )

        XCTAssertEqual(library.files.first?.readState, .read)
        XCTAssertEqual(library.files.first?.subjects, ["Subject/User"])
        XCTAssertEqual(library.files.first?.contentModified, freshDate,
                       "the content index must see the external edit's fresh mtime")
        XCTAssertEqual(library.files.first?.fileType, "PDF",
                       "verified tag precedence must not restore stale content metadata")
    }

    func testSubtreeReadStartedBeforeVerifiedWriteCannotOverwriteIt() async throws {
        let root = try makeRoot()
        let file = try makeFile("Box/changed.pdf", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            MockCorpusWatcher(handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        let readGeneration = library.beginWatchReadForTesting()
        let box = file.deletingLastPathComponent()
        let stalePass = LibraryScan.pass(root: box)
        try (URL(fileURLWithPath: file.path) as NSURL)
            .setResourceValue(["Read", "Subject/User"], forKey: .tagNamesKey)
        library.applyVerifiedWrites([
            TagWriteResult(url: file, before: ["Unread"], after: ["Read", "Subject/User"],
                           beforeLabel: nil, afterLabel: nil,
                           inverse: TagDelta(add: ["Unread"], remove: ["Read", "Subject/User"]))
        ])

        library.finishWatchReadForTesting(
            CorpusWatchChangeSet(paths: [],
                                 subtrees: [CorpusSubtreeChange(url: box, pass: stalePass)]),
            readGeneration: readGeneration
        )

        XCTAssertEqual(library.files.first?.readState, .read)
        XCTAssertEqual(library.files.first?.subjects, ["Subject/User"])
    }

    func testWatchReadCannotResurrectAVerifiedMembershipRemoval() async throws {
        let root = try makeRoot()
        let file = try makeFile("changed.pdf", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            MockCorpusWatcher(handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        let readGeneration = library.beginWatchReadForTesting()
        let staleInspection = CorpusWalker.inspect(file)
        try (URL(fileURLWithPath: file.path) as NSURL).setResourceValue([], forKey: .tagNamesKey)
        library.applyVerifiedWrites([
            TagWriteResult(url: file, before: ["Unread"], after: [],
                           beforeLabel: nil, afterLabel: nil,
                           inverse: TagDelta(add: ["Unread"]))
        ])
        XCTAssertTrue(library.files.isEmpty)

        library.finishWatchReadForTesting(
            CorpusWatchChangeSet(paths: [CorpusPathChange(url: file, inspection: staleInspection)],
                                 subtrees: []),
            readGeneration: readGeneration
        )

        XCTAssertTrue(library.files.isEmpty,
                      "an older live read must not resurrect a row the verified write removed")
    }

    func testNewerSerializedLiveReadRetiresVerifiedWriteGuard() async throws {
        let root = try makeRoot()
        let file = try makeFile("changed.pdf", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            MockCorpusWatcher(handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        try (URL(fileURLWithPath: file.path) as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)
        library.applyVerifiedWrites([
            TagWriteResult(url: file, before: ["Unread"], after: ["Read"],
                           beforeLabel: nil, afterLabel: nil,
                           inverse: TagDelta(add: ["Unread"], remove: ["Read"]))
        ])
        XCTAssertEqual(library.verifiedWriteCountForTesting, 1)

        let newerRead = library.beginWatchReadForTesting()
        library.finishWatchReadForTesting(
            CorpusWatchChangeSet(paths: [CorpusPathChange(url: file,
                                                          inspection: CorpusWalker.inspect(file))],
                                 subtrees: []),
            readGeneration: newerRead
        )

        XCTAssertEqual(library.files.first?.readState, .read)
        XCTAssertEqual(library.verifiedWriteCountForTesting, 0,
                       "a converged live stream must not retain every Reader edit forever")
    }

    func testBurstQueuesAtMostOneMoreRootWalk() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            MockCorpusWatcher(handler: handler)
        }

        library.start(scope: root)
        // The completion cannot reach this MainActor until the first await, so all three requests are
        // guaranteed to arrive before the launch walk has started — since `W26.fsev-fu1` that walk is
        // waiting for the stream's off-thread `open(2)`, which is why this count is 0 rather than 1.
        // The invariant under test is unchanged: three requests still collapse into ONE queued bit, so
        // the totals below are the launch walk plus exactly one more, never four.
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        XCTAssertEqual(library.rootScanStartsForTesting, 0,
                       "the launch walk waits for the stream, so the burst coalesces before it starts")

        try await waitUntil { library.phase.isSettled && library.rootScanStartsForTesting == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(library.rootScanStartsForTesting, 2,
                       "one active + one queued bit; a burst cannot create an unbounded scan train")
    }

    func testQueuedRecoveryNeverPublishesSettledBeforeItsDelayedWalkStarts() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let library = ArchiveLibrary(minimumRootRescanInterval: 5) { _, handler in
            MockCorpusWatcher(handler: handler)
        }

        library.start(scope: root)
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        try await waitUntil {
            library.files.count == 1 && library.rootScanStartsForTesting == 1
        }

        XCTAssertTrue(library.phase.isScanning)
        XCTAssertFalse(library.phase.isSettled,
                       "absence and content-index pruning stay disabled while recovery is queued")
    }

    func testJournalFailureIsVisibleAndActivationUsesTheStaleFallback() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let attempts = CounterBox()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            attempts.increment()
            return MockCorpusWatcher(startResult: .journalUnavailable, handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }

        XCTAssertEqual(library.liveUpdateFailure, .liveUpdatesUnavailable)
        XCTAssertTrue(library.phase.isSettled,
                      "the just-completed walk is authoritative even though continuous refresh is not")
        XCTAssertTrue(library.discoveryFailure?.detail.contains("five minutes") == true)
        let scansBefore = library.rootScanStartsForTesting

        library.revalidateOnActivation(now: Date.distantFuture, staleAfter: 0)
        try await waitUntil { library.phase.isSettled && library.rootScanStartsForTesting == scansBefore + 1 }
        XCTAssertGreaterThanOrEqual(attempts.value, 2, "activation retries the event channel before falling back")
    }

    func testRecoveredSinceNowStreamStillRunsACatchUpWalkForItsOutage() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let attempts = CounterBox()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let attempt = attempts.increment()
            return MockCorpusWatcher(startResult: attempt == 1 ? .journalUnavailable : .started,
                                     handler: handler)
        }
        library.start(scope: root)
        try await waitUntil { library.phase.isSettled }
        let scansBefore = library.rootScanStartsForTesting

        library.revalidateOnActivation(now: Date(), staleAfter: .infinity)
        try await waitUntil {
            library.phase.isSettled && library.rootScanStartsForTesting == scansBefore + 1
        }

        XCTAssertNil(library.liveUpdateFailure)
        XCTAssertEqual(attempts.value, 2)
    }

    // MARK: - W26.fsev-fu1 — the stream's `open(2)` is not allowed to hold the main thread

    /// The bug itself, pinned at its narrowest: `FSEventStreamCreate` opens the watched root, and until
    /// `W26.fsev-fu1` it did so on the main thread inside `NavigationModel.init()`. A stack sample of a
    /// 9-minute 0%-CPU hang is what found it. Nothing about a *result* is asserted here — only where the
    /// syscall runs, because that is the whole defect.
    func testTheStreamsOpenIsNotPerformedOnTheMainThread() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let capture = BlockingWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = BlockingCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        defer { capture.latest?.release() }

        library.start(scope: root)
        try XCTUnwrap(capture.latest).waitUntilStarting()

        XCTAssertEqual(try XCTUnwrap(capture.latest).startedOnMainThread, false,
                       "FSEventStreamCreate open(2)s the root; on the main thread that is the hang")
    }

    /// The ordering guarantee `W26.fsev` exists for, kept while the main thread stays free.
    ///
    /// Both halves matter and they pull against each other: the walk must not read anything before the
    /// stream is watching (or a change in between is lost for good), yet the main thread must not wait
    /// for the stream's `open`. So the walk is *deferred*, not *waited on* — and because the ordering
    /// held, no catch-up pass is owed.
    func testTheLaunchWalkWaitsForTheStreamWhileTheMainThreadDoesNot() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let capture = BlockingWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { _, handler in
            let watcher = BlockingCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        defer { capture.latest?.release() }

        let before = Date()
        library.start(scope: root)
        let returned = Date().timeIntervalSince(before)
        let watcher = try XCTUnwrap(capture.latest)
        watcher.waitUntilStarting()

        XCTAssertLessThan(returned, 1.0, "start(scope:) returned without waiting on the stream's open")
        XCTAssertEqual(library.rootScanStartsForTesting, 0,
                       "the walk has NOT started: the stream is not watching yet (W26.fsev ordering)")
        XCTAssertTrue(library.phase.isFirstScan, "and the app already has a phase to draw")
        XCTAssertNil(library.liveUpdateFailure, "nothing has failed yet — the open is merely in progress")

        watcher.release()
        try await waitUntil { library.phase.isSettled }

        XCTAssertEqual(library.files.map(\.url.lastPathComponent), ["a.pdf"])
        XCTAssertNil(library.liveUpdateFailure)
        XCTAssertEqual(library.rootScanStartsForTesting, 1,
                       "the ordering held, so no catch-up pass is owed")
        XCTAssertTrue(library.flushWatcherForTesting(), "and the stream really was installed")
    }

    /// A root whose `open` does not come back — an unanswered permission prompt, a stalled network or
    /// cloud mount, a disconnected volume. The deadline is what turns the old silent stall into a drawn
    /// window: discovery goes ahead without live events, and the reason is stated.
    func testAStalledStreamStartStopsHoldingDiscoveryAndSaysWhy() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let capture = BlockingWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0, watcherStartTimeout: 0.2) { _, handler in
            let watcher = BlockingCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        defer { capture.latest?.release() }

        library.start(scope: root)
        let watcher = try XCTUnwrap(capture.latest)
        watcher.waitUntilStarting()
        try await waitUntil { library.liveUpdateFailure == .liveUpdatesStalled }
        try await waitUntil { library.phase.isSettled }

        XCTAssertEqual(library.files.map(\.url.lastPathComponent), ["a.pdf"],
                       "an unanswerable open must not cost the user the list of what IS readable")
        XCTAssertEqual(library.discoveryFailure?.message, "Archive folder is not responding")
        XCTAssertTrue(library.discoveryFailure?.detail.contains("no answer") == true)
        XCTAssertFalse(library.flushWatcherForTesting(), "no stream is installed while it is stalled")
        XCTAssertEqual(library.rootScanStartsForTesting, 1)

        // The start is not abandoned. When it finally returns, the stream is adopted — and because
        // discovery ran without it, `kFSEventStreamEventIdSinceNow` owes exactly one catch-up pass.
        watcher.release()
        try await waitUntil { library.liveUpdateFailure == nil && library.phase.isSettled }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(library.flushWatcherForTesting())
        XCTAssertEqual(library.rootScanStartsForTesting, 2,
                       "one catch-up pass for the interval nothing was watching — and only one")
    }

    /// The late answer may be a *failure*, and then the stall wording must give way to the finished one:
    /// "not responding" describes not knowing, `liveUpdatesUnavailable` describes knowing. No catch-up
    /// pass is owed either, because there is no stream to have missed anything.
    func testAStalledStartThatEventuallyFailsReportsTheJournalAnswerInstead() async throws {
        let root = try makeRoot()
        try makeFile("a.pdf", tags: ["Unread"], root: root)
        let capture = BlockingWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0, watcherStartTimeout: 0.2) { _, handler in
            let watcher = BlockingCorpusWatcher(result: .journalUnavailable, handler: handler)
            capture.latest = watcher
            return watcher
        }
        defer { capture.latest?.release() }

        library.start(scope: root)
        let watcher = try XCTUnwrap(capture.latest)
        watcher.waitUntilStarting()
        try await waitUntil { library.liveUpdateFailure == .liveUpdatesStalled }
        try await waitUntil { library.phase.isSettled }
        watcher.release()

        try await waitUntil { library.liveUpdateFailure == .liveUpdatesUnavailable }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(library.rootScanStartsForTesting, 1,
                       "no stream came up, so nothing owes a catch-up walk")
        XCTAssertTrue(library.discoveryFailure?.detail.contains("five minutes") == true,
                      "and the stale-activation fallback is the one being advertised")
    }

    /// The adversarial case for making the start async: the owner switches root while the first root's
    /// `open` is still stuck. When it finally returns it must be STOPPED, not installed — otherwise the
    /// Reader ends up with a live stream on a directory nobody is looking at, feeding events into the
    /// new root's library. The new root must also not be held behind the stuck start.
    func testARootSwitchAbandonsAStreamWhoseOpenIsStillStuck() async throws {
        let stuckRoot = try makeRoot()
        try makeFile("stuck.pdf", tags: ["Unread"], root: stuckRoot)
        let nextRoot = try makeRoot()
        try makeFile("next.pdf", tags: ["Read"], root: nextRoot)

        let capture = BlockingWatcherCapture()
        let library = ArchiveLibrary(minimumRootRescanInterval: 0) { root, handler in
            guard root == stuckRoot else { return MockCorpusWatcher(handler: handler) }
            let watcher = BlockingCorpusWatcher(handler: handler)
            capture.latest = watcher
            return watcher
        }
        defer { capture.latest?.release() }

        library.start(scope: stuckRoot)
        let stuck = try XCTUnwrap(capture.latest)
        stuck.waitUntilStarting()
        XCTAssertEqual(library.rootScanStartsForTesting, 0)

        library.start(scope: nextRoot)
        try await waitUntil { library.phase.isSettled }
        XCTAssertEqual(library.files.map(\.url.lastPathComponent), ["next.pdf"],
                       "the new root is not held behind the abandoned root's open")
        let passesBefore = library.rootScanStartsForTesting

        stuck.release()
        try await waitUntil { stuck.stops == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(library.files.map(\.url.lastPathComponent), ["next.pdf"])
        XCTAssertEqual(library.scopeDescription, nextRoot.lastPathComponent)
        XCTAssertEqual(library.rootScanStartsForTesting, passesBefore,
                       "an abandoned stream owes nothing: no catch-up pass for a root nobody watches")
        XCTAssertNil(library.liveUpdateFailure,
                     "and the live root's healthy stream is not blamed for the abandoned one")
    }
}

final class CorpusWatcherStreamTests: XCTestCase {
    func testCancelledReadKeepsItsOwnScopeUntilTheWorkerStops() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("changed.pdf")
        try Data("bytes".utf8).write(to: file)
        let cancellation = CorpusWatchCancellation()
        let starts = CounterBox()
        let stops = CounterBox()
        let emptyResult = CounterBox()
        let enteredStart = expectation(description: "worker acquired its operation scope")
        let releaseStart = DispatchSemaphore(value: 0)
        let completed = expectation(description: "cancelled live read completed")

        CorpusWatchWork.onDedicatedThread(
            root: root,
            request: CorpusWatchRequest(paths: [file.path]),
            cancellation: cancellation,
            startSecurityScope: { _ in
                starts.increment()
                enteredStart.fulfill()
                releaseStart.wait()
                return true
            },
            stopSecurityScope: { _ in stops.increment() }
        ) { changes in
            if changes.paths.isEmpty && changes.subtrees.isEmpty { emptyResult.increment() }
            completed.fulfill()
        }

        wait(for: [enteredStart], timeout: 2)
        cancellation.cancel()       // the root switch happens while the worker owns its operation scope
        releaseStart.signal()
        wait(for: [completed], timeout: 2)

        XCTAssertEqual(starts.value, 1)
        XCTAssertEqual(stops.value, 1, "the operation-lifetime access must balance on cancellation")
        XCTAssertEqual(emptyResult.value, 1, "a cancelled old-root worker must perform no path reads")
    }

    func testSecurityScopeIsHeldUntilStreamTeardownAndReleasedOnEveryExit() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let starts = CounterBox()
        let stops = CounterBox()
        let watcher = CorpusWatcher(root: root,
                                    startSecurityScope: { _ in starts.increment(); return true },
                                    stopSecurityScope: { _ in stops.increment() },
                                    handler: { _ in })

        let result = watcher.start()
        XCTAssertEqual(starts.value, 1)
        if result == .started {
            XCTAssertEqual(stops.value, 0, "the access must span the stream's whole running lifetime")
        } else {
            XCTAssertEqual(stops.value, 1, "a failed stream start must release the access immediately")
        }
        watcher.stop()
        watcher.stop()
        XCTAssertEqual(stops.value, 1, "Stop/Invalidate/Release and scope release are idempotent")
    }

    /// Real APFS journal, real external process, no Spotlight. The mock-backed library tests above pin
    /// merge semantics; this pins that the OS notification channel actually delivers a Finder-tag xattr.
    func testAPFSStreamSeesAThirdPartyFinderTagWriteAndFlushesDeterministically() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("external.pdf")
        try Data("bytes".utf8).write(to: file)

        let delivered = expectation(description: "FSEvents delivered the external tag write")
        let didFulfill = FlagBox()
        let watcher = CorpusWatcher(root: root) { request in
            let covered = request.fullRescan
                || request.paths.contains(file.path)
                || request.subtrees.contains { CorpusWatchRequest.contains(file.path, under: $0) }
            if covered && didFulfill.claim() { delivered.fulfill() }
        }
        XCTAssertEqual(watcher.start(), .started,
                       "the local APFS temp volume must provide the FSEvents journal this feature requires")
        defer { watcher.stop() }

        let plist = try PropertyListSerialization.data(fromPropertyList: ["Unread"],
                                                       format: .binary, options: 0)
        let hex = plist.map { String(format: "%02x", $0) }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-w", "-x", "com.apple.metadata:_kMDItemUserTags", hex, file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        XCTAssertTrue(watcher.flushSync(), "tests need the stream's deterministic kernel flush point")
        wait(for: [delivered], timeout: 5)
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusWatcherStreamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class MockCorpusWatcher: CorpusWatching, @unchecked Sendable {
    let startResult: CorpusWatcherStartResult
    let handler: CorpusWatcher.Handler
    private(set) var stops = 0

    init(startResult: CorpusWatcherStartResult = .started,
         handler: @escaping CorpusWatcher.Handler) {
        self.startResult = startResult
        self.handler = handler
    }
    func start() -> CorpusWatcherStartResult { startResult }
    func stop() { stops += 1 }
    func flushSync() -> Bool { startResult == .started }
    func emit(_ request: CorpusWatchRequest) { handler(request) }
}

private final class MockWatcherCapture: @unchecked Sendable { var latest: MockCorpusWatcher? }

/// A stream whose `start()` blocks exactly where `FSEventStreamCreate`'s `open(2)` blocks on a root
/// behind an unanswered permission prompt, a stalled mount or a disconnected volume (`W26.fsev-fu1`).
/// It also records the thread it was called on, which is the property the fix is *about*.
///
/// Always `release()` it before the test ends — a `DispatchSemaphore` deallocated while a thread waits
/// on it traps inside libdispatch.
private final class BlockingCorpusWatcher: CorpusWatching, @unchecked Sendable {
    private let result: CorpusWatcherStartResult
    private let handler: CorpusWatcher.Handler
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var mainThread: Bool?
    private var stopCount = 0

    init(result: CorpusWatcherStartResult = .started, handler: @escaping CorpusWatcher.Handler) {
        self.result = result
        self.handler = handler
    }

    func start() -> CorpusWatcherStartResult {
        lock.lock(); mainThread = Thread.isMainThread; lock.unlock()
        entered.signal()
        gate.wait()
        return result
    }
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
    func flushSync() -> Bool { result == .started }
    func emit(_ request: CorpusWatchRequest) { handler(request) }

    var startedOnMainThread: Bool? { lock.lock(); defer { lock.unlock() }; return mainThread }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }

    /// Block until `start()` has actually been entered, so a test's "the walk has not begun" assertion
    /// cannot pass merely because the start had not been dispatched yet.
    func waitUntilStarting(timeout: TimeInterval = 5) {
        XCTAssertEqual(entered.wait(timeout: .now() + timeout), .success,
                       "the stream start was never dispatched")
    }
    func release() { gate.signal() }
}

private final class BlockingWatcherCapture: @unchecked Sendable { var latest: BlockingCorpusWatcher? }

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}
