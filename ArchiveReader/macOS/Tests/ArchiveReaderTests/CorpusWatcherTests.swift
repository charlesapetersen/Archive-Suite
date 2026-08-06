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
        library.setRootResolver { resolutions += 1; return rootB }
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
        // guaranteed to arrive while the launch walk is in flight.
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        library.receiveWatchRequestForTesting(CorpusWatchRequest(fullRescan: true))
        XCTAssertEqual(library.rootScanStartsForTesting, 1)

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
