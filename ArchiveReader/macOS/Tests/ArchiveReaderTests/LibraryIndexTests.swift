import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.idx — the durable discovery cache. Every fixture is a disposable SQLite file under /tmp;
/// these tests never point the index or the walker at the owner's corpus.
final class LibraryIndexTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeIndex(_ name: String = "index.sqlite3") -> LibraryIndex {
        LibraryIndex(url: scratch.appendingPathComponent(name))
    }

    private func root(path: String? = nil, guid: UUID = UUID()) -> LibraryIndexRoot {
        LibraryIndexRoot(path: path ?? scratch.appendingPathComponent("corpus").path,
                         markerGUID: guid)
    }

    private func entry(path: String, tags: [String], label: Int? = nil,
                       mtime: TimeInterval = 10, ctime: TimeInterval = 20,
                       size: Int64 = 30, inode: UInt64 = 40,
                       isDataless: Bool = false) -> CorpusEntry {
        let fingerprint = CorpusFileFingerprint(mtime: mtime, ctime: ctime, size: size,
                                                inode: inode, isDataless: isDataless)
        let url = path.withCString {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
        }
        return CorpusEntry(url: url, tagNames: tags, labelNumber: label,
                           contentModified: Date(timeIntervalSince1970: mtime),
                           contentTypeIdentifier: "com.adobe.pdf", isDataless: isDataless,
                           fingerprint: fingerprint)
    }

    private func completeVerdict(at date: Date = Date(timeIntervalSince1970: 1_000),
                                 filesSeen: Int) -> LibraryIndexScanVerdict {
        LibraryIndexScanVerdict(finishedAt: date, filesSeen: filesSeen, directoryErrors: 0,
                                outcome: "complete", absenceIsAuthoritative: true)
    }

    func testCleanScanRoundTripsEveryRegularFileAndRawMetadata() async throws {
        let index = makeIndex()
        let identity = root()
        let composed = identity.path + "/caf\u{e9}.pdf"
        let decomposed = identity.path + "/cafe\u{301}.pdf"
        XCTAssertEqual(composed, decomposed, "precondition: Swift String uses canonical equality")
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8),
                          "precondition: the filesystem spellings are byte-distinct")

        let scan = try await index.beginScan(root: identity)
        let rows = [
            entry(path: composed, tags: ["Unread", "Subject/Z", "P2"], label: 6,
                  mtime: 11, ctime: 12, size: 13, inode: 14),
            entry(path: decomposed, tags: [], mtime: 21, ctime: 22, size: 23, inode: 24,
                  isDataless: true),
        ]
        let finished = Date(timeIntervalSince1970: 2_000)
        try await index.completeScan(scan, entries: rows,
                                     verdict: completeVerdict(at: finished, filesSeen: rows.count))

        let snapshot = try await index.snapshot(for: identity)
        XCTAssertEqual(snapshot.entries.count, 2,
                       "canonically equivalent but byte-distinct paths must not collapse in memory")
        XCTAssertEqual(Set(snapshot.entries.values.map { $0.corpusEntry().url }).count, 2,
                       "reconstructed warm URLs must retain the two filesystem spellings")
        XCTAssertEqual(snapshot.asOf, finished)

        let tagged = try XCTUnwrap(snapshot.entries[LibraryIndexPath(composed)])
        XCTAssertEqual(tagged.tagNames, ["Unread", "Subject/Z", "P2"],
                       "the cache stores raw tag order, never parsed facets")
        XCTAssertEqual(tagged.labelNumber, 6)
        XCTAssertTrue(tagged.tracked)
        XCTAssertTrue(tagged.verified)
        XCTAssertEqual(tagged.fingerprint,
                       CorpusFileFingerprint(mtime: 11, ctime: 12, size: 13, inode: 14,
                                             isDataless: false))

        let untagged = try XCTUnwrap(snapshot.entries[LibraryIndexPath(decomposed)])
        XCTAssertEqual(untagged.tagNames, [])
        XCTAssertFalse(untagged.tracked, "all regular files are persisted, not only visible rows")
        XCTAssertTrue(untagged.fingerprint.isDataless)
        await index.close()
    }

    func testStartedOrPartialScanKeepsRowsButRevokesCurrencyAndVerification() async throws {
        let index = makeIndex()
        let identity = root()
        let kept = identity.path + "/kept.pdf"
        let unseen = identity.path + "/unseen.pdf"

        let first = try await index.beginScan(root: identity)
        try await index.completeScan(first,
                                     entries: [entry(path: kept, tags: ["Unread"]),
                                               entry(path: unseen, tags: ["Read"])],
                                     verdict: completeVerdict(filesSeen: 2))

        let interrupted = try await index.beginScan(root: identity)
        var snapshot = try await index.snapshot(for: identity)
        XCTAssertNil(snapshot.asOf, "an unfinished newest scan cannot claim a settled timestamp")
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertTrue(snapshot.entries.values.allSatisfy { !$0.verified },
                      "carried rows become unverified before filesystem work begins")

        let partial = LibraryIndexScanVerdict(finishedAt: Date(), filesSeen: 1, directoryErrors: 1,
                                              outcome: "partial", absenceIsAuthoritative: false)
        try await index.completeScan(interrupted,
                                     entries: [entry(path: kept, tags: ["Read"], ctime: 99)],
                                     verdict: partial)
        snapshot = try await index.snapshot(for: identity)
        XCTAssertNil(snapshot.asOf)
        XCTAssertEqual(Set(snapshot.entries.values.map(\.path)), Set([kept, unseen]),
                       "absence from a partial scan is never a deletion")
        XCTAssertEqual(snapshot.entries[LibraryIndexPath(kept)]?.tagNames, ["Read"])
        XCTAssertTrue(snapshot.entries.values.allSatisfy { !$0.verified })
        await index.close()
    }

    func testNextCleanScanMakesAbsenceAuthoritativeAndVerifiesSurvivors() async throws {
        let index = makeIndex()
        let identity = root()
        let survivor = identity.path + "/survivor.pdf"
        let removed = identity.path + "/removed.pdf"

        let first = try await index.beginScan(root: identity)
        try await index.completeScan(first,
                                     entries: [entry(path: survivor, tags: ["Unread"]),
                                               entry(path: removed, tags: ["Read"])],
                                     verdict: completeVerdict(filesSeen: 2))

        let second = try await index.beginScan(root: identity)
        try await index.completeScan(second,
                                     entries: [entry(path: survivor, tags: ["Read"], ctime: 90)],
                                     verdict: completeVerdict(filesSeen: 1))

        let snapshot = try await index.snapshot(for: identity)
        XCTAssertEqual(Array(snapshot.entries.values.map(\.path)), [survivor])
        XCTAssertEqual(snapshot.entries[LibraryIndexPath(survivor)]?.tagNames, ["Read"])
        XCTAssertEqual(snapshot.entries[LibraryIndexPath(survivor)]?.verified, true)
        XCTAssertNotNil(snapshot.asOf)
        await index.close()
    }

    func testPathAndMarkerGUIDTogetherDefineRootIdentity() async throws {
        let index = makeIndex()
        let sharedPath = scratch.appendingPathComponent("mounted-here").path
        let firstRoot = root(path: sharedPath, guid: UUID())
        let replacementRoot = root(path: sharedPath, guid: UUID())

        let first = try await index.beginScan(root: firstRoot)
        try await index.completeScan(first,
                                     entries: [entry(path: sharedPath + "/first.pdf", tags: ["Read"])],
                                     verdict: completeVerdict(filesSeen: 1))
        let replacement = try await index.beginScan(root: replacementRoot)
        try await index.completeScan(replacement,
                                     entries: [entry(path: sharedPath + "/replacement.pdf",
                                                     tags: ["Unread"])],
                                     verdict: completeVerdict(filesSeen: 1))

        let firstSnapshot = try await index.snapshot(for: firstRoot)
        let replacementSnapshot = try await index.snapshot(for: replacementRoot)
        XCTAssertEqual(firstSnapshot.entries.values.map(\.name), ["first.pdf"])
        XCTAssertEqual(replacementSnapshot.entries.values.map(\.name), ["replacement.pdf"])
        await index.close()
    }

    func testParentAndNestedRootsPersistTheSameAbsoluteFileIndependently() async throws {
        let index = makeIndex()
        let parent = root(path: scratch.appendingPathComponent("corpus").path, guid: UUID())
        let nested = root(path: parent.path + "/Nested", guid: UUID())
        let sharedFile = nested.path + "/shared.pdf"

        let parentScan = try await index.beginScan(root: parent)
        try await index.completeScan(parentScan,
                                     entries: [entry(path: sharedFile, tags: ["Read"], ctime: 41)],
                                     verdict: completeVerdict(filesSeen: 1))
        let nestedScan = try await index.beginScan(root: nested)
        try await index.completeScan(nestedScan,
                                     entries: [entry(path: sharedFile, tags: ["Unread"], ctime: 42)],
                                     verdict: completeVerdict(filesSeen: 1))

        let parentSnapshot = try await index.snapshot(for: parent)
        let nestedSnapshot = try await index.snapshot(for: nested)
        XCTAssertEqual(parentSnapshot.entries[LibraryIndexPath(sharedFile)]?.tagNames, ["Read"])
        XCTAssertEqual(parentSnapshot.entries[LibraryIndexPath(sharedFile)]?.fingerprint.ctime, 41)
        XCTAssertEqual(nestedSnapshot.entries[LibraryIndexPath(sharedFile)]?.tagNames, ["Unread"])
        XCTAssertEqual(nestedSnapshot.entries[LibraryIndexPath(sharedFile)]?.fingerprint.ctime, 42)
        await index.close()
    }

    func testByteExactContainmentRejectsSiblingsAndTraversal() {
        let root = LibraryIndexPath("/archive/root")
        XCTAssertTrue(LibraryIndexPath("/archive/root/report.pdf").isContained(in: root))
        XCTAssertTrue(LibraryIndexPath("/archive/root").isContained(in: root))
        XCTAssertFalse(LibraryIndexPath("/archive/rootbox/report.pdf").isContained(in: root))
        XCTAssertFalse(LibraryIndexPath("/archive/root/../outside.pdf").isContained(in: root))
        XCTAssertFalse(LibraryIndexPath("archive/root/report.pdf").isContained(in: root))

        let composedRoot = LibraryIndexPath("/archive/caf\u{e9}")
        let decomposedChild = LibraryIndexPath("/archive/cafe\u{301}/report.pdf")
        XCTAssertFalse(decomposedChild.isContained(in: composedRoot),
                       "canonical Unicode equivalence must not cross a cache trust boundary")
    }

    func testSnapshotThrowsRatherThanPresentingRowsBeforeASQLiteStepErrorAsClean() async throws {
        let index = makeIndex()
        let identity = root()
        let scan = try await index.beginScan(root: identity)
        let oversizedTag = String(repeating: "x", count: 4_096)
        try await index.completeScan(
            scan,
            entries: [entry(path: identity.path + "/large.pdf", tags: ["Unread", oversizedTag])],
            verdict: completeVerdict(filesSeen: 1)
        )

        let oldLimit = try await index.setLengthLimitForTesting(512)
        do {
            _ = try await index.snapshot(for: identity)
            XCTFail("a failed entry step must not return a partial/current snapshot")
        } catch {
            XCTAssertTrue(error is LibraryIndex.IndexError)
        }
        _ = try await index.setLengthLimitForTesting(oldLimit)
        await index.close()
    }

    func testCancellationStopsAtBatchBoundaryAndLeavesAnHonestUnfinishedScan() async throws {
        let firstBatchCommitted = DispatchSemaphore(value: 0)
        let letActorContinue = DispatchSemaphore(value: 0)
        let index = LibraryIndex(
            url: scratch.appendingPathComponent("cancel.sqlite3"),
            batchDidCommitForTesting: { batch in
                guard batch == 0 else { return }
                firstBatchCommitted.signal()
                _ = letActorContinue.wait(timeout: .now() + 10)
            }
        )
        let identity = root()
        let scan = try await index.beginScan(root: identity)
        let rows = (0..<1_001).map { number in
            entry(path: identity.path + "/\(number).pdf", tags: ["Unread"], inode: UInt64(number + 1))
        }
        let verdict = completeVerdict(filesSeen: rows.count)

        let commit = Task {
            try await index.completeScan(scan, entries: rows, verdict: verdict)
        }
        XCTAssertEqual(firstBatchCommitted.wait(timeout: .now() + 10), .success,
                       "the test must cancel while a corpus-scale commit is between batches")
        commit.cancel()
        letActorContinue.signal()

        do {
            try await commit.value
            XCTFail("the superseded commit must observe cancellation before another batch")
        } catch is CancellationError {
            // Required result.
        }

        let snapshot = try await index.snapshot(for: identity)
        XCTAssertEqual(snapshot.entries.count, 500,
                       "at most the already-committed batch may remain in the disposable cache")
        XCTAssertNil(snapshot.asOf, "a canceled rewrite must never claim a settled timestamp")
        XCTAssertTrue(snapshot.entries.values.allSatisfy { !$0.verified },
                      "partial rows remain cache hints, never authoritative filesystem truth")
        await index.close()
    }
}
