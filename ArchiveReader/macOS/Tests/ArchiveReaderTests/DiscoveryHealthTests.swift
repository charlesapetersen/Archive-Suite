import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.walk2 — **the one place that decides whether the app may claim the corpus is empty.**
///
/// The 2026-08-04 incident was not a walker bug; it was a *health* bug. Discovery returned nothing,
/// nothing recorded that it had been unable to look, and the view stated `"No Read/Unread-tagged PDFs
/// were found in this folder"` as a fact about 1,849 correctly-tagged files. So the mapping from a
/// scan outcome to a phase is pure and lives alone, and every branch of it is pinned here.
///
/// No filesystem, no threads: `CorpusScanResult` is constructed directly so outcomes that are awkward
/// to stage (an ejected volume, a cancelled pass) are as testable as the happy path.
final class DiscoveryHealthTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func result(entries: Int = 0,
                        unreadable: Int = 0,
                        directoryErrors: Int = 0,
                        filesSeen: Int = 0,
                        vanished: Int = 0,
                        rootUnreadable: Bool = false,
                        cancelled: Bool = false) -> CorpusScanResult {
        func failures(_ n: Int, _ tag: String) -> [CorpusReadFailure] {
            (0..<n).map { CorpusReadFailure(url: URL(fileURLWithPath: "/tmp/\(tag)-\($0)"), reason: tag) }
        }
        let rows = (0..<entries).map {
            CorpusEntry(url: URL(fileURLWithPath: "/tmp/row-\($0).pdf"), tagNames: ["Unread"],
                        labelNumber: nil, contentModified: nil, contentTypeIdentifier: "com.adobe.pdf",
                        isDataless: false)
        }
        return CorpusScanResult(entries: rows,
                                unreadable: failures(unreadable, "unreadable"),
                                directoryErrors: failures(directoryErrors, "dir"),
                                filesSeen: filesSeen, vanishedMidScan: vanished,
                                rootUnreadable: rootUnreadable, cancelled: cancelled)
    }

    // MARK: - Healthy

    func testACleanCompletePassOnAStableRootIsAuthoritative() {
        let r = result(entries: 1_849, filesSeen: 1_849)

        XCTAssertNil(DiscoveryHealth.failure(for: r, rootHeldStill: true))
        XCTAssertEqual(DiscoveryHealth.phase(after: r, rootHeldStill: true, finishedAt: t0, lastSettled: nil),
                       .settled(asOf: t0, scanned: 1_849))
    }

    /// The empty-but-readable case: genuinely nothing tagged. Allowed — and it carries the
    /// denominator, so the copy cannot be written without one.
    func testAGenuinelyEmptyReadableFolderSettlesWithItsDenominator() {
        let r = result(entries: 0, filesSeen: 312)
        let phase = DiscoveryHealth.phase(after: r, rootHeldStill: true, finishedAt: t0, lastSettled: nil)

        XCTAssertEqual(phase, .settled(asOf: t0, scanned: 312))
        guard case let .settled(_, scanned) = phase else { return XCTFail("expected .settled") }
        XCTAssertEqual(scanned, 312, "\"none of them are tagged\" is only sayable about a count")
    }

    /// A mid-scan disappearance is churn, not a denial (plan §7a.12) — it must not cost the pass its
    /// authority, or a rename during a walk over a live corpus would degrade every pass.
    func testVanishedEntriesDoNotDegradeAPass() {
        let r = result(entries: 20, filesSeen: 24, vanished: 4)

        XCTAssertNil(DiscoveryHealth.failure(for: r, rootHeldStill: true))
    }

    // MARK: - Every way a pass loses its authority

    func testAnUnreadableRootIsReportedAsSuch() {
        let r = result(rootUnreadable: true)

        XCTAssertEqual(DiscoveryHealth.failure(for: r, rootHeldStill: false), .rootUnreadable)
    }

    func testACancelledPassIsIncompleteNotEmpty() {
        let r = result(entries: 5, filesSeen: 5, cancelled: true)

        XCTAssertEqual(DiscoveryHealth.failure(for: r, rootHeldStill: true), .incomplete)
    }

    /// §7a.11 — the case the counters cannot see. Everything about this pass looks perfect: it ended
    /// on its own, read everything it saw, no errors. It is still a truncated walk of an ejected
    /// volume, and `.settled` would authorise pruning ~110,000 rows for files that are fine.
    func testATruncatedWalkThatLooksPerfectIsStillDegraded() {
        let r = result(entries: 40_000, filesSeen: 40_000)
        XCTAssertTrue(r.isClean, "the premise: every counter the walker has says this pass was clean")

        XCTAssertEqual(DiscoveryHealth.failure(for: r, rootHeldStill: false), .rootChangedMidScan)
        let phase = DiscoveryHealth.phase(after: r, rootHeldStill: false, finishedAt: t0, lastSettled: nil)
        XCTAssertFalse(phase.isSettled, "a truncated walk must never authorise treating a file as gone")
    }

    func testUnreadableFilesAndFoldersAreCountedSeparately() {
        XCTAssertEqual(DiscoveryHealth.failure(for: result(unreadable: 3, filesSeen: 10), rootHeldStill: true),
                       .partiallyUnreadable(files: 3, folders: 0))
        XCTAssertEqual(DiscoveryHealth.failure(for: result(directoryErrors: 2, filesSeen: 10), rootHeldStill: true),
                       .partiallyUnreadable(files: 0, folders: 2))
        XCTAssertEqual(DiscoveryHealth.failure(for: result(unreadable: 1, directoryErrors: 1, filesSeen: 9),
                                              rootHeldStill: true),
                       .partiallyUnreadable(files: 1, folders: 1))
    }

    /// A degraded pass dates itself against the last good one, so the UI can say what it knew and
    /// when instead of an undated wrong claim.
    func testADegradedPassCarriesTheLastSettledTime() {
        let earlier = t0.addingTimeInterval(-3_600)
        let phase = DiscoveryHealth.phase(after: result(unreadable: 1, filesSeen: 5),
                                          rootHeldStill: true, finishedAt: t0, lastSettled: earlier)

        XCTAssertEqual(phase, .degraded(.partiallyUnreadable(files: 1, folders: 0), asOf: earlier))
    }

    /// Precedence: the *most fundamental* reason wins, so the message names the thing to fix.
    func testTheMostFundamentalFailureWins() {
        let everything = result(unreadable: 3, directoryErrors: 2, rootUnreadable: true, cancelled: true)

        XCTAssertEqual(DiscoveryHealth.failure(for: everything, rootHeldStill: false), .rootUnreadable)
        XCTAssertEqual(DiscoveryHealth.failure(for: result(unreadable: 3, cancelled: true),
                                              rootHeldStill: false),
                       .incomplete, "cancelled outranks a partial read: we stopped looking on purpose")
    }

    // MARK: - The gates the phase exposes

    /// §7a.4 — `isSettled` gates *deletion* of content-index rows. Only a settled pass may authorise
    /// it; `.revalidating` and `.degraded` both hand over snapshots that omit files they never reached.
    func testOnlySettledAuthorisesPruning() {
        XCTAssertTrue(LibraryPhase.settled(asOf: t0, scanned: 10).isSettled)

        for phase: LibraryPhase in [.noRoot,
                                    .firstScan(done: 0, seen: 0),
                                    .revalidating(asOf: t0),
                                    .degraded(.rootUnreadable, asOf: t0),
                                    .degraded(.partiallyUnreadable(files: 1, folders: 0), asOf: nil)] {
            XCTAssertFalse(phase.isSettled, "\(phase) must not authorise deleting index rows")
        }
    }

    /// The list-blanking full-screen spinner is honest in exactly one phase — the one with no rows to
    /// blank. `.revalidating` showing it would hide real rows behind a spinner on every rescan.
    func testOnlyTheFirstScanMayBlankTheList() {
        XCTAssertTrue(LibraryPhase.firstScan(done: 3, seen: 90).isFirstScan)

        for phase: LibraryPhase in [.noRoot, .revalidating(asOf: t0),
                                    .settled(asOf: t0, scanned: 1), .degraded(.incomplete, asOf: nil)] {
            XCTAssertFalse(phase.isFirstScan)
        }
    }

    func testScanningCoversBothPassKinds() {
        XCTAssertTrue(LibraryPhase.firstScan(done: 0, seen: 0).isScanning)
        XCTAssertTrue(LibraryPhase.revalidating(asOf: t0).isScanning)
        XCTAssertFalse(LibraryPhase.noRoot.isScanning)
        XCTAssertFalse(LibraryPhase.settled(asOf: t0, scanned: 1).isScanning)
        XCTAssertFalse(LibraryPhase.degraded(.incomplete, asOf: nil).isScanning)
    }

    /// Every failure must produce non-empty, distinct user-facing text: a status bar that renders an
    /// empty string is the silent failure this type exists to end.
    func testEveryFailureSaysSomethingSpecific() {
        let all: [DiscoveryFailure] = [.rootUnreadable, .rootChangedMidScan, .incomplete,
                                       .partiallyUnreadable(files: 1, folders: 0),
                                       .partiallyUnreadable(files: 0, folders: 1),
                                       .partiallyUnreadable(files: 2, folders: 3)]
        for f in all {
            XCTAssertFalse(f.message.isEmpty, "\(f) has no status-bar line")
            XCTAssertFalse(f.detail.isEmpty, "\(f) has no explanation")
        }
        XCTAssertEqual(Set(all.map(\.message)).count, all.count, "messages must not collapse")
        XCTAssertEqual(DiscoveryFailure.partiallyUnreadable(files: 1, folders: 0).message,
                       "Could not read 1 file")
        XCTAssertEqual(DiscoveryFailure.partiallyUnreadable(files: 2, folders: 3).message,
                       "Could not read 2 files and 3 folders")
    }
}
