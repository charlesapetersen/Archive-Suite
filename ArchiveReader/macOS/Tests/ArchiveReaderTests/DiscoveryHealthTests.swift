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

        XCTAssertNil(DiscoveryHealth.failure(for: r, root: .heldStill))
        XCTAssertEqual(DiscoveryHealth.phase(after: r, root: .heldStill, finishedAt: t0, lastSettled: nil),
                       .settled(asOf: t0, scanned: 1_849))
    }

    /// The empty-but-readable case: genuinely nothing tagged. Allowed — and it carries the
    /// denominator, so the copy cannot be written without one.
    func testAGenuinelyEmptyReadableFolderSettlesWithItsDenominator() {
        let r = result(entries: 0, filesSeen: 312)
        let phase = DiscoveryHealth.phase(after: r, root: .heldStill, finishedAt: t0, lastSettled: nil)

        XCTAssertEqual(phase, .settled(asOf: t0, scanned: 312))
        guard case let .settled(_, scanned) = phase else { return XCTFail("expected .settled") }
        XCTAssertEqual(scanned, 312, "\"none of them are tagged\" is only sayable about a count")
    }

    /// A mid-scan disappearance is churn, not a denial (plan §7a.12) — it must not cost the pass its
    /// authority, or a rename during a walk over a live corpus would degrade every pass.
    func testVanishedEntriesDoNotDegradeAPass() {
        let r = result(entries: 20, filesSeen: 24, vanished: 4)

        XCTAssertNil(DiscoveryHealth.failure(for: r, root: .heldStill))
    }

    // MARK: - Every way a pass loses its authority

    func testAnUnreadableRootIsReportedAsSuch() {
        let r = result(rootUnreadable: true)

        XCTAssertEqual(DiscoveryHealth.failure(for: r, root: .changedMidScan), .rootUnreadable)
    }

    /// A root that was never identifiable is UNREADABLE, not "changed while scanning". Found reviewing
    /// my own first cut, which had two root states and therefore gave a sealed folder — the commonest
    /// case there is — a confident, specific, wrong diagnosis. The walker's own `rootUnreadable` does
    /// not cover it: `FileManager` still hands back an enumerator for a sealed directory.
    func testARootThatWasNeverIdentifiableIsUnreadableNotChanged() {
        let r = result(directoryErrors: 1)
        XCTAssertFalse(r.rootUnreadable, "the premise: the walker got an enumerator and an error, not nil")

        XCTAssertEqual(DiscoveryHealth.failure(for: r, root: .neverIdentified), .rootUnreadable)
        XCTAssertEqual(DiscoveryHealth.failure(for: r, root: .changedMidScan), .rootChangedMidScan)
    }

    func testRootStabilityDistinguishesNeverIdentifiedFromChanged() {
        let a = CorpusRootFingerprint(filesystemID: 1, deviceID: 2, inode: 3)
        let b = CorpusRootFingerprint(filesystemID: 1, deviceID: 2, inode: 4)

        XCTAssertEqual(RootStability.between(a, a), .heldStill)
        XCTAssertEqual(RootStability.between(a, b), .changedMidScan)
        XCTAssertEqual(RootStability.between(a, nil), .changedMidScan, "readable at the start, gone by the end")
        XCTAssertEqual(RootStability.between(nil, a), .neverIdentified)
        XCTAssertEqual(RootStability.between(nil, nil), .neverIdentified)
    }

    func testACancelledPassIsIncompleteNotEmpty() {
        let r = result(entries: 5, filesSeen: 5, cancelled: true)

        XCTAssertEqual(DiscoveryHealth.failure(for: r, root: .heldStill), .incomplete)
    }

    /// §7a.11 — the case the counters cannot see. Everything about this pass looks perfect: it ended
    /// on its own, read everything it saw, no errors. It is still a truncated walk of an ejected
    /// volume, and `.settled` would authorise pruning ~110,000 rows for files that are fine.
    func testATruncatedWalkThatLooksPerfectIsStillDegraded() {
        let r = result(entries: 40_000, filesSeen: 40_000)
        XCTAssertTrue(r.isClean, "the premise: every counter the walker has says this pass was clean")

        XCTAssertEqual(DiscoveryHealth.failure(for: r, root: .changedMidScan), .rootChangedMidScan)
        let phase = DiscoveryHealth.phase(after: r, root: .changedMidScan, finishedAt: t0, lastSettled: nil)
        XCTAssertFalse(phase.isSettled, "a truncated walk must never authorise treating a file as gone")
    }

    func testUnreadableFilesAndFoldersAreCountedSeparately() {
        XCTAssertEqual(DiscoveryHealth.failure(for: result(unreadable: 3, filesSeen: 10), root: .heldStill),
                       .partiallyUnreadable(files: 3, folders: 0))
        XCTAssertEqual(DiscoveryHealth.failure(for: result(directoryErrors: 2, filesSeen: 10), root: .heldStill),
                       .partiallyUnreadable(files: 0, folders: 2))
        XCTAssertEqual(DiscoveryHealth.failure(for: result(unreadable: 1, directoryErrors: 1, filesSeen: 9),
                                              root: .heldStill),
                       .partiallyUnreadable(files: 1, folders: 1))
    }

    /// A degraded pass dates itself against the last good one, so the UI can say what it knew and
    /// when instead of an undated wrong claim.
    func testADegradedPassCarriesTheLastSettledTime() {
        let earlier = t0.addingTimeInterval(-3_600)
        let phase = DiscoveryHealth.phase(after: result(unreadable: 1, filesSeen: 5),
                                          root: .heldStill, finishedAt: t0, lastSettled: earlier)

        XCTAssertEqual(phase, .degraded(.partiallyUnreadable(files: 1, folders: 0), asOf: earlier))
    }

    /// Precedence: the *most fundamental* reason wins, so the message names the thing to fix.
    func testTheMostFundamentalFailureWins() {
        let everything = result(unreadable: 3, directoryErrors: 2, rootUnreadable: true, cancelled: true)

        XCTAssertEqual(DiscoveryHealth.failure(for: everything, root: .changedMidScan), .rootUnreadable)
        XCTAssertEqual(DiscoveryHealth.failure(for: result(unreadable: 3, cancelled: true),
                                              root: .changedMidScan),
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

/// W26.walk2 — **the guard on the actual sentence the incident rendered.**
///
/// `"No Read/Unread-tagged PDFs were found in this folder"` is a claim about the corpus. The Reader
/// made it on 2026-08-04 about 1,849 correctly-tagged files, because the only condition on it was
/// "the list is empty and discovery is not gathering". These cases pin that the wording is now
/// reachable from exactly one outcome — and that every other emptiness has its own honest answer.
final class LibraryEmptyStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(_ phase: LibraryPhase, rows: Int = 0, displayed: Int = 0) -> LibraryEmptyState? {
        LibraryEmptyState.forPhase(phase, rowCount: rows, displayedCount: displayed)
    }

    /// The whole point: the ONLY phase that may say "nothing here is tagged" is a pass that completed,
    /// read everything it saw, held its root still, and counted at least one file.
    func testNothingTaggedIsReachableFromExactlyOnePhase() {
        XCTAssertEqual(state(.settled(asOf: t0, scanned: 1_849)), .nothingTagged(scanned: 1_849))

        let everyOtherPhase: [LibraryPhase] = [
            .firstScan(done: 0, seen: 0),
            .firstScan(done: 0, seen: 40_000),
            .revalidating(asOf: t0),
            .revalidating(asOf: nil),
            .degraded(.rootUnreadable, asOf: nil),
            .degraded(.rootChangedMidScan, asOf: t0),
            .degraded(.incomplete, asOf: nil),
            .degraded(.partiallyUnreadable(files: 1, folders: 0), asOf: t0),
            .settled(asOf: t0, scanned: 0),
        ]
        for phase in everyOtherPhase {
            let s = state(phase)
            XCTAssertNotEqual(s, .nothingTagged(scanned: 0), "\(phase) may not blame the folder")
            if case .nothingTagged = s { XCTFail("\(phase) reached the incident's wording") }
        }
    }

    /// The 2026-08-04 shape, exactly: discovery could not look, the list is empty. It must explain
    /// itself, not describe the folder.
    func testTheIncidentShapeSaysWeCouldNotLook() {
        XCTAssertEqual(state(.degraded(.rootUnreadable, asOf: nil)), .couldNotLook(.rootUnreadable))
        XCTAssertEqual(state(.degraded(.partiallyUnreadable(files: 3, folders: 1), asOf: t0)),
                       .couldNotLook(.partiallyUnreadable(files: 3, folders: 1)))
    }

    /// A settled pass that saw no files at all is not the same claim — there is nothing to be tagged.
    func testAnEmptyFolderIsItsOwnAnswer() {
        XCTAssertEqual(state(.settled(asOf: t0, scanned: 0)), .folderIsEmpty)
    }

    func testAPassStillRunningSaysSo() {
        XCTAssertEqual(state(.firstScan(done: 0, seen: 12)), .scanning)
        XCTAssertEqual(state(.revalidating(asOf: t0)), .scanning)
    }

    func testNoRootOutranksEverythingIncludingRowsLeftOnScreen() {
        XCTAssertEqual(state(.noRoot), .noRoot)
        XCTAssertEqual(state(.noRoot, rows: 5, displayed: 5), .noRoot)
    }

    /// Rows exist and the user's own filters hide them — never a statement about the folder, and it
    /// must win over the phase (a filtered-out list during a rescan is not "scanning").
    func testFiltersHidingRowsIsAboutTheFiltersNotTheFolder() {
        XCTAssertEqual(state(.settled(asOf: t0, scanned: 40), rows: 40, displayed: 0), .filteredOut)
        XCTAssertEqual(state(.revalidating(asOf: t0), rows: 40, displayed: 0), .filteredOut)
        XCTAssertEqual(state(.degraded(.incomplete, asOf: t0), rows: 40, displayed: 0), .filteredOut)
    }

    /// With rows on screen there is nothing to say — including during a degraded revalidation, where
    /// the status bar carries the warning instead of an overlay covering the rows.
    func testRowsOnScreenMeanNoOverlay() {
        XCTAssertNil(state(.settled(asOf: t0, scanned: 40), rows: 40, displayed: 40))
        XCTAssertNil(state(.degraded(.partiallyUnreadable(files: 1, folders: 0), asOf: t0),
                           rows: 40, displayed: 40))
    }
}
