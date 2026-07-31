import Testing
import Foundation
@testable import ArchiveNotes

/// W23.l2 — a cancelled prune task must not be able to defeat the two-emission absence gate.
///
/// `pruneIfSettled` starts by cancelling the prior prune task, but **cancellation is cooperative**:
/// once a task is past its last `Task.isCancelled` check it runs to completion, and `MainActor.run`
/// is not cancellation-aware, so its late hops execute too. Before this fix those hops read
/// `pendingPrune` in one hop and wrote it in another, with nothing tying either to the emission they
/// belonged to. Two interleavings then bite:
///
///   (a) a superseded task reads the pending set a NEWER emission just wrote, mistakes it for "the
///       previous emission", and deletes after only ONE current consecutive absence;
///   (b) a superseded task deletes a row the NEWEST snapshot already says is present.
///
/// Both were reproduced against the real concurrency runtime on the Reader's copy of this code
/// (`ContentIndexerPruneRaceTests`); this driver is a fork of it and carried the identical shape.
/// Notes' own `pruneIfSettled` has **no production caller yet** — `NotesModel` builds and re-indexes
/// but never prunes — so here the fix is preventive: the day a caller is wired up it inherits the
/// gate rather than the race. The FTS half is a rebuildable cache either way, so the cost of the bug
/// is notes missing from search until a reindex, never a note file.
///
/// These tests drive the interleavings **deterministically**, through the generation seam
/// (`beginPruneGeneration` / `commitPruneDecision`) rather than by trying to win a real race against
/// a detached task. Each race test also re-implements the PRE-FIX ungated logic against the same
/// fixture and asserts it produced the harmful outcome, so neither can pass vacuously. The pure
/// `pruneDecision` properties are covered in `NotesIndexTests` and not repeated here.
/// Scratch store + scratch index only; never the real store.
@Suite("Prune race (W23.l2)")
@MainActor
struct NotesIndexerPruneRaceTests {

    // MARK: Scratch helpers

    private func makeScratchIndex() async throws -> (NotesIndex, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesPruneRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let index = NotesIndex(url: tmp.appendingPathComponent("index.sqlite3"))
        try await index.open()
        return (index, tmp)
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// The pre-fix state machine, verbatim in shape: read the pending set, decide, write it back,
    /// with no generation check. Used only to prove a fixture is not vacuous.
    private struct PreFixGate {
        var pendingPrune: Set<UUID>?
        var deleted: Set<UUID> = []

        mutating func commit(indexed: Set<UUID>, currentIDs: Set<UUID>) {
            let decision = NotesIndexer.pruneDecision(indexed: indexed, currentIDs: currentIDs,
                                                      previousPending: pendingPrune)
            deleted.formUnion(decision.delete)
            pendingPrune = decision.newPending
        }
    }

    // MARK: The race

    /// Interleaving (a): E1 sees a transient drop and stalls; E2 sees the note back and clears the
    /// pending set; the stale E1 task then lands and re-stashes the absence. A third emission with
    /// another transient drop would then delete on what is only its FIRST current absence.
    @Test("a superseded emission cannot re-stash a stale absence")
    func supersededTaskCannotReStashAStaleAbsence() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let ix = NotesIndexer(index: index)
        let keep = UUID(), gone = UUID()
        let indexed: Set<UUID> = [keep, gone]

        // E1 — transient drop of `gone`. Task A gets its stamp, then stalls mid-flight.
        let genA = ix.beginPruneGeneration()

        // E2 — `gone` is back. This supersedes A and runs to completion.
        let genB = ix.beginPruneGeneration()
        #expect(ix.commitPruneDecision(gen: genB, indexed: indexed, currentIDs: [keep, gone]).isEmpty)

        // A finally lands, cancelled and superseded. Its write must be a no-op.
        #expect(ix.commitPruneDecision(gen: genA, indexed: indexed, currentIDs: [keep]).isEmpty,
                "a superseded emission must not delete")

        // E3 — another transient drop. Had A re-stashed, this would confirm-and-delete on its first
        // current absence; it must still be only a first sighting.
        let genC = ix.beginPruneGeneration()
        #expect(ix.commitPruneDecision(gen: genC, indexed: indexed, currentIDs: [keep]).isEmpty,
                "the two-emission gate must still require a SECOND current absence")

        // And the gate is intact rather than merely stuck: a fourth emission does prune.
        let genD = ix.beginPruneGeneration()
        #expect(ix.commitPruneDecision(gen: genD, indexed: indexed, currentIDs: [keep]) == [gone],
                "two consecutive current absences must still prune")

        // Non-vacuity: the pre-fix logic, same fixture, same order → deletes one emission early.
        var pre = PreFixGate()
        pre.commit(indexed: indexed, currentIDs: [keep, gone])   // E2
        pre.commit(indexed: indexed, currentIDs: [keep])         // stale A
        pre.commit(indexed: indexed, currentIDs: [keep])         // E3
        #expect(pre.deleted == [gone],
                "fixture check: the pre-fix logic must delete at E3, or this test proves nothing")
    }

    /// Interleaving (b): a pending absence is already on the books, E1 confirms it and stalls, E2
    /// sees the note back — and the stale E1 task lands first, deleting a row the newest snapshot
    /// says is present.
    @Test("a superseded emission cannot delete a row the newest snapshot has")
    func supersededTaskCannotDeleteAPresentRow() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let ix = NotesIndexer(index: index)
        let keep = UUID(), gone = UUID()
        let indexed: Set<UUID> = [keep, gone]

        // E0 — first sighting of the absence, stashed.
        let gen0 = ix.beginPruneGeneration()
        #expect(ix.commitPruneDecision(gen: gen0, indexed: indexed, currentIDs: [keep]).isEmpty)

        // E1 — still absent; task A takes its stamp and stalls before its decision hop.
        let genA = ix.beginPruneGeneration()
        // E2 — `gone` is back. Creating it supersedes A; its own hops have not landed yet.
        let genB = ix.beginPruneGeneration()

        // A lands first, still holding a snapshot in which `gone` was absent.
        #expect(ix.commitPruneDecision(gen: genA, indexed: indexed, currentIDs: [keep]).isEmpty,
                "a superseded emission must not delete a now-present row")
        // B then lands and clears the stale pending set.
        #expect(ix.commitPruneDecision(gen: genB, indexed: indexed, currentIDs: [keep, gone]).isEmpty)

        // Non-vacuity: pre-fix, the same order deletes a present row.
        var pre = PreFixGate()
        pre.commit(indexed: indexed, currentIDs: [keep])   // E0
        pre.commit(indexed: indexed, currentIDs: [keep])   // stale A
        #expect(pre.deleted == [gone],
                "fixture check: the pre-fix logic must delete here, or this test proves nothing")
    }

    /// The seam is only worth anything if the production entry point actually opens a new epoch.
    /// Guards against a future edit dropping `beginPruneGeneration()` from `pruneIfSettled`.
    @Test("pruneIfSettled opens a new epoch")
    func pruneIfSettledOpensANewEpoch() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let ix = NotesIndexer(index: index)

        let stale = ix.beginPruneGeneration()
        ix.pruneIfSettled(currentIDs: [UUID()])
        #expect(ix.isCurrentPruneGeneration(stale) == false,
                "pruneIfSettled must supersede the previous emission")
        await ix.inFlightPruneTask?.value
    }

    /// A scope change invalidates the stashed absences, so an in-flight task must not be able to
    /// re-stash them afterwards.
    @Test("resetPruneState supersedes an in-flight emission")
    func resetPruneStateSupersedesInFlight() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let ix = NotesIndexer(index: index)
        let keep = UUID(), gone = UUID()

        let genA = ix.beginPruneGeneration()
        ix.resetPruneState()
        #expect(ix.isCurrentPruneGeneration(genA) == false)
        #expect(ix.commitPruneDecision(gen: genA, indexed: [keep, gone], currentIDs: [keep]).isEmpty,
                "a task from the old scope must write nothing after a reset")

        // And the reset really cleared the pending set: the next emission is a first sighting.
        let genB = ix.beginPruneGeneration()
        #expect(ix.commitPruneDecision(gen: genB, indexed: [keep, gone], currentIDs: [keep]).isEmpty)
    }

    // MARK: End to end, over a real (scratch) store + index

    /// The refactor moved the row delete to AFTER the pending-state write, so prove the observable
    /// contract over the real driver, a real scratch store and a real sqlite index is unchanged: one
    /// absence does not prune, two consecutive absences do. Deterministic — each emission is
    /// awaited, not slept on.
    @Test("two consecutive absences prune; one does not (end to end)")
    func twoEmissionGateEndToEnd() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let store = NoteStore(root: tmp)
        let keepRef = try await store.create(makeItem("Kept"))
        let goneRef = try await store.create(makeItem("Gone"))

        let ix = NotesIndexer(index: index)
        ix.startIndexing([keepRef, goneRef])
        await ix.awaitSettled()
        var ids = await index.allIndexedIDs()
        #expect(ids == [keepRef.id, goneRef.id], "both notes must be indexed before pruning means anything")

        // Emission 1: `gone` is absent for the first time — stash only.
        ix.pruneIfSettled(currentIDs: [keepRef.id])
        await ix.inFlightPruneTask?.value
        ids = await index.allIndexedIDs()
        #expect(ids == [keepRef.id, goneRef.id], "one absence must not prune")

        // Emission 2: same absence, now confirmed — prune.
        ix.pruneIfSettled(currentIDs: [keepRef.id])
        await ix.inFlightPruneTask?.value
        ids = await index.allIndexedIDs()
        #expect(ids == [keepRef.id], "two consecutive absences must prune exactly the absent row")
    }

    /// The transient-drop guard, end to end: a note that reappears between emissions keeps its row,
    /// and its stashed absence is discarded rather than counting toward the next drop.
    @Test("a reappearance resets the two-emission count (end to end)")
    func transientDropKeepsItsRowEndToEnd() async throws {
        let (index, tmp) = try await makeScratchIndex()
        defer { Task { await index.close() }; try? FileManager.default.removeItem(at: tmp) }
        let store = NoteStore(root: tmp)
        let keepRef = try await store.create(makeItem("Kept"))
        let goneRef = try await store.create(makeItem("Flickers"))

        let ix = NotesIndexer(index: index)
        ix.startIndexing([keepRef, goneRef])
        await ix.awaitSettled()

        ix.pruneIfSettled(currentIDs: [keepRef.id])                 // drop
        await ix.inFlightPruneTask?.value
        ix.pruneIfSettled(currentIDs: [keepRef.id, goneRef.id])     // back
        await ix.inFlightPruneTask?.value
        var ids = await index.allIndexedIDs()
        #expect(ids == [keepRef.id, goneRef.id])

        // The stash was cleared, so the next drop is a first sighting again — not a confirmation.
        ix.pruneIfSettled(currentIDs: [keepRef.id])
        await ix.inFlightPruneTask?.value
        ids = await index.allIndexedIDs()
        #expect(ids == [keepRef.id, goneRef.id],
                "a reappearance must reset the two-emission count, not shorten it")
    }
}
