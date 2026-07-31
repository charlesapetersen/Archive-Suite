import XCTest
@testable import ArchiveReader
@testable import ArchiveCore

/// W23.l2 — a cancelled prune task must not be able to defeat the two-emission absence gate.
///
/// `pruneIfSettled` starts by cancelling the prior prune task, but **cancellation is cooperative**:
/// once a task is past its last `Task.isCancelled` check it runs to completion, and `MainActor.run`
/// is not cancellation-aware, so its late hops execute too. Before this fix those hops read
/// `pendingPrune` in one hop and wrote it in another, with no check that the emission they belonged
/// to was still the current one. Two interleavings then bite:
///
///   (a) a superseded task reads the pending set a NEWER emission just wrote, mistakes it for "the
///       previous emission", and deletes after only ONE current consecutive absence;
///   (b) a superseded task deletes a path the NEWEST snapshot already says is present.
///
/// Both were reproduced against the real concurrency runtime before the fix. The source files are
/// never at risk — the content index is an explicitly rebuildable cache — but rows vanish from search
/// until a reindex.
///
/// These tests drive the same interleavings **deterministically**, through the generation seam
/// (`beginPruneGeneration` / `commitPruneDecision`) rather than by trying to win a real race against
/// a detached task. Every race test also re-implements the PRE-FIX ungated logic against the same
/// fixture and asserts it produced the harmful outcome, so none of them can pass vacuously.
/// No index, no disk, no corpus.
@MainActor
final class ContentIndexerPruneRaceTests: XCTestCase {

    private let root = "/scratch/root"
    private var keep: String { "\(root)/keep.pdf" }
    private var gone: String { "\(root)/gone.pdf" }
    private var indexed: Set<String> { [keep, gone] }

    /// A scratch index path under the test bundle's temp dir. Only `testPruneIfSettledOpensANewEpoch`
    /// ever opens one — the rest exercise the main-actor decision seam and never touch disk.
    private func scratchURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cix-prune-\(UUID().uuidString).sqlite3")
    }

    private func removeDB(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private func indexer() -> ContentIndexer { ContentIndexer(url: scratchURL()) }

    /// The pre-fix state machine, verbatim in shape: read the pending set, decide, write it back,
    /// with no generation check. Used only to prove a fixture is not vacuous.
    private struct PreFixGate {
        var pendingPrune: Set<String>?
        var deleted: Set<String> = []

        mutating func commit(indexedUnderRoot: Set<String>, currentPaths: Set<String>) {
            let absent = indexedUnderRoot.subtracting(currentPaths)
            guard !absent.isEmpty else { pendingPrune = nil; return }
            if let prev = pendingPrune {
                let confirmed = absent.intersection(prev)
                deleted.formUnion(confirmed)
                let remaining = absent.subtracting(confirmed)
                pendingPrune = remaining.isEmpty ? nil : remaining
            } else {
                pendingPrune = absent
            }
        }
    }

    // MARK: - The race

    /// Interleaving (a): E1 sees a transient drop and stalls; E2 sees the file back and clears the
    /// pending set; the stale E1 task then lands and re-stashes the absence. A third emission with
    /// another transient drop now deletes on what is only its FIRST current absence.
    func testSupersededTaskCannotReStashAStaleAbsence() {
        let ix = indexer()

        // E1 — transient drop of `gone`. Task A gets its stamp, then stalls mid-flight.
        let genA = ix.beginPruneGeneration()

        // E2 — `gone` is back. This supersedes A and runs to completion.
        let genB = ix.beginPruneGeneration()
        let deleteB = ix.commitPruneDecision(gen: genB, indexedUnderRoot: indexed,
                                             currentPaths: [keep, gone])
        XCTAssertTrue(deleteB.isEmpty, "nothing is absent in E2 — it must delete nothing")

        // A finally lands, cancelled and superseded. Its write must be a no-op.
        let deleteA = ix.commitPruneDecision(gen: genA, indexedUnderRoot: indexed,
                                             currentPaths: [keep])
        XCTAssertTrue(deleteA.isEmpty, "a superseded emission must not delete")

        // E3 — another transient drop. If A had re-stashed, this would confirm-and-delete on its
        // first current absence. The observable proof is E3's own return value: a first sighting.
        let genC = ix.beginPruneGeneration()
        let deleteC = ix.commitPruneDecision(gen: genC, indexedUnderRoot: indexed,
                                             currentPaths: [keep])
        XCTAssertTrue(deleteC.isEmpty,
                      "the two-emission gate must still require a SECOND current absence")

        // And the gate is intact rather than merely stuck: a fourth emission with the same absence
        // does delete.
        let genD = ix.beginPruneGeneration()
        let deleteD = ix.commitPruneDecision(gen: genD, indexedUnderRoot: indexed,
                                             currentPaths: [keep])
        XCTAssertEqual(deleteD, [gone], "two consecutive current absences must still prune")

        // Non-vacuity: the pre-fix logic, same fixture, same order → deletes one emission early.
        var pre = PreFixGate()
        pre.commit(indexedUnderRoot: indexed, currentPaths: [keep, gone])   // E2
        pre.commit(indexedUnderRoot: indexed, currentPaths: [keep])         // stale A
        pre.commit(indexedUnderRoot: indexed, currentPaths: [keep])         // E3
        XCTAssertEqual(pre.deleted, [gone],
                       "fixture check: the pre-fix logic must delete at E3, or this test proves nothing")
    }

    /// Interleaving (b): a pending absence is already on the books, E1 confirms it and stalls, E2
    /// sees the file back — and the stale E1 task lands first, deleting a path the newest snapshot
    /// says is present.
    func testSupersededTaskCannotDeleteAPathTheNewestSnapshotHas() {
        let ix = indexer()

        // E0 — first sighting of the absence, stashed.
        let gen0 = ix.beginPruneGeneration()
        XCTAssertTrue(ix.commitPruneDecision(gen: gen0, indexedUnderRoot: indexed,
                                             currentPaths: [keep]).isEmpty)

        // E1 — still absent; task A takes its stamp and stalls before its decision hop.
        let genA = ix.beginPruneGeneration()

        // E2 — `gone` is back. Creating it supersedes A; its own hops have not landed yet.
        let genB = ix.beginPruneGeneration()

        // A lands first, still holding a snapshot in which `gone` was absent.
        let deleteA = ix.commitPruneDecision(gen: genA, indexedUnderRoot: indexed,
                                             currentPaths: [keep])
        XCTAssertTrue(deleteA.isEmpty, "a superseded emission must not delete a now-present path")

        // B then lands and clears the stale pending set.
        let deleteB = ix.commitPruneDecision(gen: genB, indexedUnderRoot: indexed,
                                             currentPaths: [keep, gone])
        XCTAssertTrue(deleteB.isEmpty)

        // Non-vacuity: pre-fix, the same order deletes a present path.
        var pre = PreFixGate()
        pre.commit(indexedUnderRoot: indexed, currentPaths: [keep])          // E0
        pre.commit(indexedUnderRoot: indexed, currentPaths: [keep])          // stale A
        XCTAssertEqual(pre.deleted, [gone],
                       "fixture check: the pre-fix logic must delete here, or this test proves nothing")
    }

    /// The seam is only worth anything if the production entry point actually opens a new epoch.
    /// Guards against a future edit dropping `beginPruneGeneration()` from `pruneIfSettled`.
    func testPruneIfSettledOpensANewEpoch() {
        let url = scratchURL(); defer { removeDB(url) }
        let ix = ContentIndexer(url: url)
        let stale = ix.beginPruneGeneration()
        ix.pruneIfSettled(currentPaths: [keep], rootPrefix: root)
        XCTAssertFalse(ix.isCurrentPruneGeneration(stale),
                       "pruneIfSettled must supersede the previous emission")
    }

    /// A root change invalidates the old root's absences, so an in-flight task from that root must
    /// not be able to re-stash them afterwards.
    func testResetPruneStateSupersedesAnInFlightEmission() {
        let ix = indexer()
        let genA = ix.beginPruneGeneration()
        ix.resetPruneState()
        XCTAssertFalse(ix.isCurrentPruneGeneration(genA))
        XCTAssertTrue(ix.commitPruneDecision(gen: genA, indexedUnderRoot: indexed,
                                             currentPaths: [keep]).isEmpty,
                      "a task from the old root must write nothing after a reset")

        // And the reset really cleared the pending set: the next emission is a first sighting.
        let genB = ix.beginPruneGeneration()
        XCTAssertTrue(ix.commitPruneDecision(gen: genB, indexedUnderRoot: indexed,
                                             currentPaths: [keep]).isEmpty)
    }

    // MARK: - End to end, over a real (scratch) index

    /// An `ArchiveFile` for a path that need not exist: an unreadable file is a legitimate row
    /// (`readable = false`), which is all these tests need — no PDF, no corpus.
    private func archiveFile(_ path: String) -> ArchiveFile {
        let url = URL(fileURLWithPath: path)
        return ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                           tags: DocumentTags.parse(raw: [], labelNumber: nil),
                           contentModified: Date(timeIntervalSince1970: 1))
    }

    /// Which of `paths` currently have a row. `formatStatuses` only answers for indexed paths, so
    /// its key set is the presence probe.
    private func indexedPaths(_ ix: ContentIndexer, _ paths: [String]) async -> Set<String> {
        Set(await ix.formatStatuses(for: paths).keys)
    }

    private func waitForRows(_ ix: ContentIndexer, _ paths: [String],
                             timeout: TimeInterval = 10) async -> Set<String> {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: Set<String> = []
        while Date() < deadline {
            seen = await indexedPaths(ix, paths)
            if seen.count == paths.count { return seen }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return seen
    }

    /// The refactor moved the row delete to AFTER the pending-state write, so prove the observable
    /// contract over the real driver and a real sqlite index is unchanged: one absence does not
    /// prune, two consecutive absences do. Deterministic — each emission is awaited, not slept on.
    func testTwoEmissionGateEndToEndOverAScratchIndex() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        let ix = ContentIndexer(url: url)

        ix.startIndexing([archiveFile(keep), archiveFile(gone)])
        let initial = await waitForRows(ix, [keep, gone])
        XCTAssertEqual(initial, [keep, gone], "both files must be indexed before pruning means anything")

        // Emission 1: `gone` is absent for the first time — stash only.
        ix.pruneIfSettled(currentPaths: [keep], rootPrefix: root)
        await ix.inFlightPruneTask?.value
        let afterOne = await indexedPaths(ix, [keep, gone])
        XCTAssertEqual(afterOne, [keep, gone], "one absence must not prune")

        // Emission 2: same absence, now confirmed — prune.
        ix.pruneIfSettled(currentPaths: [keep], rootPrefix: root)
        await ix.inFlightPruneTask?.value
        let afterTwo = await indexedPaths(ix, [keep, gone])
        XCTAssertEqual(afterTwo, [keep], "two consecutive absences must prune exactly the absent path")
    }

    /// The transient-drop guard, end to end: a file that reappears between emissions keeps its row,
    /// and its stashed absence is discarded rather than counting toward the next drop.
    func testTransientDropKeepsItsRowEndToEnd() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        let ix = ContentIndexer(url: url)

        ix.startIndexing([archiveFile(keep), archiveFile(gone)])
        let initial = await waitForRows(ix, [keep, gone])
        XCTAssertEqual(initial, [keep, gone])

        ix.pruneIfSettled(currentPaths: [keep], rootPrefix: root)          // drop
        await ix.inFlightPruneTask?.value
        ix.pruneIfSettled(currentPaths: [keep, gone], rootPrefix: root)    // back
        await ix.inFlightPruneTask?.value
        let afterReappearance = await indexedPaths(ix, [keep, gone])
        XCTAssertEqual(afterReappearance, [keep, gone])

        // The stash was cleared, so the next drop is a first sighting again — not a confirmation.
        ix.pruneIfSettled(currentPaths: [keep], rootPrefix: root)
        await ix.inFlightPruneTask?.value
        let afterNextDrop = await indexedPaths(ix, [keep, gone])
        XCTAssertEqual(afterNextDrop, [keep, gone],
                       "a reappearance must reset the two-emission count, not shorten it")
    }

    // MARK: - The pure gate (mirrors NotesIndexer's pruneDecision tests)

    /// The crown-jewel data-safety property, now held inside the Reader's decision too: an empty
    /// snapshot NEVER prunes — not on the first emission, and not on a repeat.
    func testEmptySnapshotNeverWipesTheIndex() {
        let first = ContentIndexer.pruneDecision(indexedUnderRoot: indexed, currentPaths: [],
                                                 previousPending: nil)
        XCTAssertTrue(first.delete.isEmpty)
        XCTAssertNil(first.newPending)

        let second = ContentIndexer.pruneDecision(indexedUnderRoot: indexed, currentPaths: [],
                                                  previousPending: indexed)
        XCTAssertTrue(second.delete.isEmpty, "a persistent empty snapshot must never wipe the index")
        XCTAssertNil(second.newPending)
    }

    /// Two consecutive absences prune; one does not.
    func testTwoEmissionGate() {
        let e1 = ContentIndexer.pruneDecision(indexedUnderRoot: indexed, currentPaths: [keep],
                                              previousPending: nil)
        XCTAssertTrue(e1.delete.isEmpty)
        XCTAssertEqual(e1.newPending, [gone])

        let e2 = ContentIndexer.pruneDecision(indexedUnderRoot: indexed, currentPaths: [keep],
                                              previousPending: e1.newPending)
        XCTAssertEqual(e2.delete, [gone])
        XCTAssertNil(e2.newPending)
    }

    /// A file that reappears between emissions is not pruned, and its stashed absence is dropped.
    func testTransientDropIsNotPruned() {
        let e1 = ContentIndexer.pruneDecision(indexedUnderRoot: indexed, currentPaths: [keep],
                                              previousPending: nil)
        XCTAssertEqual(e1.newPending, [gone])

        let e2 = ContentIndexer.pruneDecision(indexedUnderRoot: indexed, currentPaths: [keep, gone],
                                              previousPending: e1.newPending)
        XCTAssertTrue(e2.delete.isEmpty, "a reappearing file must not be pruned")
        XCTAssertNil(e2.newPending)
    }

    /// A newly-absent path is stashed in the same emission that confirms an older one.
    func testNewAbsenceIsStashedWhileAnOlderOneIsConfirmed() {
        let other = "\(root)/other.pdf"
        let all: Set<String> = [keep, gone, other]

        let e1 = ContentIndexer.pruneDecision(indexedUnderRoot: all, currentPaths: [keep, other],
                                              previousPending: nil)
        XCTAssertTrue(e1.delete.isEmpty)
        XCTAssertEqual(e1.newPending, [gone])

        let e2 = ContentIndexer.pruneDecision(indexedUnderRoot: all, currentPaths: [keep],
                                              previousPending: e1.newPending)
        XCTAssertEqual(e2.delete, [gone], "the confirmed absence prunes")
        XCTAssertEqual(e2.newPending, [other], "the new one only gets stashed")
    }
}
