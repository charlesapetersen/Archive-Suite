import XCTest
@testable import ArchiveReader

/// Regression tests for the Spotlight-lag display reconciliation (`ArchiveLibrary.overrideDecision`).
///
/// Context: after a verified `TagWriter` write, Spotlight fires `NSMetadataQueryDidUpdate` but often
/// re-emits the OLD `kMDItemUserTags` until it re-indexes — which used to clobber the correct row back
/// to its pre-write value (e.g. "Read" flashing back to "Unread") with no guaranteed self-heal. The fix
/// overlays `TagWriter`'s verified `.after` for that URL until Spotlight *value-converges* to it, or a
/// TTL leak-guard elapses. `overrideDecision` is the pure heart of that logic; these tests pin its
/// invariants (never backslide within TTL; converge on value-equality incl. case/reorder; bound masking
/// by TTL). It performs no I/O — this is a display reconciliation, never a disk read or write.
@MainActor
final class ArchiveLibraryOverrideTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func pending(after: [String], label: Int? = nil, ttl: TimeInterval = 600) -> ArchiveLibrary.PendingWrite {
        ArchiveLibrary.PendingWrite(after: after, afterLabel: label, deadline: t0.addingTimeInterval(ttl))
    }

    // MARK: Convergence → drop, trust Spotlight

    func testConvergedExactMatchDropsOverride() {
        let p = pending(after: ["Read", "Jerry Brown", "1980"])
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["Read", "Jerry Brown", "1980"],
                                                spotlightLabel: nil, pending: p, now: t0)
        XCTAssertFalse(d.keep)                                  // Spotlight caught up → stop overriding
        XCTAssertEqual(Set(d.tags), ["Read", "Jerry Brown", "1980"])
    }

    func testConvergedIgnoresTagOrderAndCase() {
        // macOS may reorder tags and APIs can differ in case; convergence must still fire so an override
        // is never pinned until the TTL over a mere cosmetic difference.
        let p = pending(after: ["Read", "Jerry Brown"])
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["jerry brown", "READ"],
                                                spotlightLabel: nil, pending: p, now: t0)
        XCTAssertFalse(d.keep)
    }

    func testLabelDifferenceIsNotConverged() {
        // Same tags but a different color label (e.g. a box/folder marker change still indexing) → keep.
        let p = pending(after: ["DP chapters"], label: 6)      // Red
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["DP chapters"],
                                                spotlightLabel: 0, pending: p, now: t0)   // Spotlight: no label yet
        XCTAssertTrue(d.keep)
        XCTAssertEqual(d.label, 6)                              // keep showing the verified color
    }

    func testNilLabelEqualsZeroLabel() {
        let p = pending(after: ["Read"], label: nil)
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["Read"],
                                                spotlightLabel: 0, pending: p, now: t0)
        XCTAssertFalse(d.keep)                                  // nil and 0 both mean "no label" → converged
    }

    // MARK: Stale / not-yet-converged within TTL → keep showing verified `.after` (never backslide)

    func testStaleEchoKeepsShowingVerifiedValue() {
        // The exact reported bug: Spotlight re-emits the pre-write value ("Unread") after we wrote "Read".
        let p = pending(after: ["Read", "Jerry Brown"])
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["Unread", "Jerry Brown"],
                                                spotlightLabel: nil, pending: p, now: t0.addingTimeInterval(5))
        XCTAssertTrue(d.keep)
        XCTAssertEqual(Set(d.tags), ["Read", "Jerry Brown"])    // shows verified truth, not the stale echo
    }

    func testDoublyStaleValueStillDoesNotBackslide() {
        // Two heterogeneous edits to one file: Unread→Read, then +subject. A doubly-stale echo of the
        // ORIGINAL value (neither the last write's before nor after) must NOT drop the override — this is
        // the backslide that a before/after "vocabulary" test would cause; value-equality+TTL never does.
        let p = pending(after: ["Read", "Foo"])
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["Unread"],          // ancient echo
                                                spotlightLabel: nil, pending: p, now: t0.addingTimeInterval(30))
        XCTAssertTrue(d.keep)
        XCTAssertEqual(Set(d.tags), ["Read", "Foo"])
    }

    // MARK: TTL leak-guard → drop, bound masking of a genuine external change

    func testExpiredOverrideYieldsToSpotlight() {
        let p = pending(after: ["Read"], ttl: 600)
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["Unread"],
                                                spotlightLabel: nil, pending: p, now: t0.addingTimeInterval(601))
        XCTAssertFalse(d.keep)                                  // past TTL → trust Spotlight even if it differs
        XCTAssertEqual(Set(d.tags), ["Unread"])
    }

    func testAtExactDeadlineExpires() {
        let p = pending(after: ["Read"], ttl: 600)
        let d = ArchiveLibrary.overrideDecision(spotlightTags: ["Unread"],
                                                spotlightLabel: nil, pending: p, now: t0.addingTimeInterval(600))
        XCTAssertFalse(d.keep)                                  // now >= deadline
    }
}
