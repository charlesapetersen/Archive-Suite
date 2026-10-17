import Testing
import Foundation
@testable import ArchiveNotes

// W7-S1a — the autosave-safe body editor controller. These drive `NoteBodyEditorModel` with injected
// load/save seams (no NoteStore, no live NSTextView — GUI is paused this run) and assert the two Tier-2
// hazards can't happen: a pending edit never lands on the wrong item across a fast selection switch, and
// a superseded (slow) load never overwrites a newer selection. Body writes are Notes' own store, never a
// Finder tag or the archival corpus — but a mis-targeted note edit is still data loss, hence Tier-2.

/// Records every save and serves loads; supports a per-id load delay to simulate a slow read.
@MainActor
private final class Recorder {
    var bodies: [UUID: String]
    var saves: [(id: UUID, body: String)] = []
    var loadDelays: [UUID: Duration] = [:]
    var loadCount = 0

    init(_ bodies: [UUID: String] = [:]) { self.bodies = bodies }

    func load(_ id: UUID) async -> String? {
        loadCount += 1
        if let d = loadDelays[id] { try? await Task.sleep(for: d) }
        return bodies[id]
    }
    func save(_ id: UUID, _ body: String) async {
        saves.append((id, body))
        bodies[id] = body
    }
}

@MainActor
private func makeModel(_ rec: Recorder, debounce: Duration = .milliseconds(40)) -> NoteBodyEditorModel {
    let m = NoteBodyEditorModel()
    m.load = { await rec.load($0) }
    m.save = { await rec.save($0, $1) }
    m.saveDebounce = debounce
    return m
}

@Suite("NoteBodyEditorModel — autosave safety across selection switches")
@MainActor
struct NoteBodyEditorModelTests {

    @Test("conflict completion flushes TextKit and preserves keystrokes received during the save")
    func lateTextKitEditSurvivesConflict() async {
        let id = UUID()
        let model = NoteBodyEditorModel()
        model.load = { _ in "initial" }
        model.saveDebounce = .seconds(60)
        var lateText: String?
        var drafts: [String] = []
        var baselines: [String] = []
        model.checkedSave = { _, draft, baseline in
            drafts.append(draft)
            baselines.append(baseline)
            if drafts.count == 1 { lateText = "draft with last keystroke" }
            return "outside body"
        }
        model.flushEditor = { [weak model] in   // weak: a strong capture is a retain cycle (W40.e2 leaks)
            if let text = lateText { lateText = nil; model?.markdown = text }
        }
        await model.select(id)
        model.markdown = "draft"
        await model.flushPending()
        #expect(drafts == ["draft", "draft with last keystroke"])
        #expect(baselines == ["initial", "initial"])
        #expect(model.markdown == "outside body")
        await model.flushPending()
        #expect(drafts.count == 2, "no stale debounced save may follow the flush")
        model.acceptEditorMarkdown("retired TextKit serialization", for: id, generation: 0)
        #expect(model.markdown == "outside body", "same-ID reloads retire the old binding generation")
    }

    @Test("refresh rechecks TextKit after its disk read before replacing a clean buffer")
    func refreshDoesNotDropLateKeystrokes() async {
        let id = UUID()
        let model = NoteBodyEditorModel()
        var reads = 0
        var textKitPending: String?
        model.load = { _ in
            reads += 1
            if reads == 1 { return "initial" }
            textKitPending = "latest keystroke"
            return "outside"
        }
        model.checkedSave = { _, _, _ in "outside" }
        model.saveDebounce = .seconds(60)
        model.flushEditor = { [weak model] in   // weak: a strong capture is a retain cycle (W40.e2 leaks)
            if let text = textKitPending { textKitPending = nil; model?.markdown = text }
        }
        await model.select(id)
        await model.refreshFromDisk()
        #expect(model.markdown == "latest keystroke")
        #expect(model.reloadGeneration == 0)
        await model.flushPending()
    }

    @Test("overlapping forced flushes share the in-flight save instead of saving concurrently")
    func forcedFlushesSerialize() async {
        let model = NoteBodyEditorModel()
        let id = UUID()
        model.saveDebounce = .seconds(60)
        model.load = { _ in "initial" }
        var began: AsyncStream<Void>.Continuation!
        let started = AsyncStream<Void> { began = $0 }
        var events = started.makeAsyncIterator()
        var release: CheckedContinuation<Void, Never>?
        var active = 0
        var calls = 0
        model.checkedSave = { _, body, _ in
            active += 1
            calls += 1
            #expect(active == 1)
            if calls == 1 {
                _ = began.yield(())
                await withCheckedContinuation { release = $0 }
            }
            active -= 1
            return body
        }
        await model.select(id)
        model.markdown = "draft"
        let first = Task { await model.flushPending() }
        _ = await events.next()
        let second = Task { await model.flushPending() }
        for _ in 0..<10 { await Task.yield() }
        #expect(calls == 1)
        release?.resume()
        _ = await first.value
        _ = await second.value
        #expect(calls == 1)
    }

    @Test("a retired editor cannot save its passage into the newly selected item")
    func rejectsRetiredEditorWriteBack() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        let model = makeModel(rec, debounce: .seconds(60))
        await model.select(a)
        model.acceptEditorMarkdown("A edited", for: a)
        await model.select(b)
        model.acceptEditorMarkdown("late A passage", for: a)
        await model.flush()
        #expect(model.markdown == "B-body")
        #expect(rec.bodies[a] == "A edited")
        #expect(rec.bodies[b] == "B-body")
        #expect(rec.saves.count == 1)
        model.acceptEditorMarkdown("B edited", for: b)
        await model.flush()
        #expect(rec.bodies[b] == "B edited")
    }

    @Test("an in-flight autosave finishes before a newer forced save")
    func forcedSaveWaitsForOlderAutosave() async {
        let id = UUID()
        let model = NoteBodyEditorModel()
        model.load = { _ in "" }
        model.saveDebounce = .milliseconds(1)
        var began: AsyncStream<Void>.Continuation!
        let started = AsyncStream<Void> { began = $0 }
        var events = started.makeAsyncIterator()
        var releaseOld: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        model.save = { _, body in
            if body == "older" {
                _ = began.yield(())
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseOld = continuation
                }
            }
            writes.append(body)
        }
        await model.select(id)
        model.markdown = "older"
        _ = await events.next()
        model.markdown = "newer"
        let forced = Task { await model.flushPending() }
        await Task.yield()
        releaseOld?.resume()
        _ = await forced.value
        #expect(writes == ["older", "newer"])
    }

    @Test("selecting an item loads its body; a pure select writes nothing")
    func loadOnSelectNoSave() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        let m = makeModel(rec)

        await m.select(a)
        #expect(m.markdown == "A-body")
        #expect(m.loadedID == a)

        await m.select(b)                 // switch with no edits in between
        #expect(m.markdown == "B-body")
        #expect(m.loadedID == b)
        #expect(rec.saves.isEmpty)        // loading/selecting must never persist
    }

    @Test("nil selection clears the editor and saves nothing")
    func nilSelectionClears() async {
        let a = UUID()
        let rec = Recorder([a: "A-body"])
        let m = makeModel(rec)
        await m.select(a)
        await m.select(nil)
        #expect(m.markdown == "")
        #expect(m.loadedID == nil)
        #expect(rec.saves.isEmpty)
    }

    @Test("THE RACE: edit A then switch to B → A is saved, B is not clobbered")
    func editThenSwitchSavesOutgoingOnly() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        let m = makeModel(rec)

        await m.select(a)
        m.markdown = "A-body EDITED"      // user edit → dirty + scheduled (debounced) save
        await m.select(b)                 // switch flushes the OUTGOING item synchronously, then loads B

        #expect(m.loadedID == b)
        #expect(m.markdown == "B-body")                       // B loaded fresh, not overwritten by A's edit
        #expect(rec.saves.count == 1)
        #expect(rec.saves.first?.id == a)                     // the save targeted A…
        #expect(rec.saves.first?.body == "A-body EDITED")     // …with A's content
        #expect(!rec.saves.contains { $0.id == b })           // nothing was ever saved onto B
        #expect(rec.bodies[b] == "B-body")                    // B on "disk" untouched
    }

    @Test("explicit flush persists the pending edit for the loaded item")
    func flushPersists() async {
        let a = UUID()
        let rec = Recorder([a: "A-body"])
        let m = makeModel(rec)
        await m.select(a)
        m.markdown = "A-body v2"
        await m.flush()
        #expect(rec.saves.count == 1)
        #expect(rec.saves.first?.id == a)
        #expect(rec.saves.first?.body == "A-body v2")
    }

    @Test("re-selecting the already-loaded id is a no-op (no reload, no lost edit)")
    func reselectSameIdIsNoOp() async {
        let a = UUID()
        let rec = Recorder([a: "A-body"])
        let m = makeModel(rec)
        await m.select(a)
        m.markdown = "A-body EDITED"
        rec.bodies[a] = "A-body CHANGED ON DISK"   // simulate a post-save reload publishing the same id
        await m.select(a)                           // must NOT reload — the guard short-circuits
        #expect(m.markdown == "A-body EDITED")      // in-progress edit preserved
        #expect(m.loadedID == a)
    }

    @Test("superseded slow load is dropped; the newest selection wins")
    func supersededLoadIgnored() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        rec.loadDelays[a] = .milliseconds(80)       // A loads slowly; B is fast
        let m = makeModel(rec)

        // Order the two selections DETERMINISTICALLY: A's slow load must already be in flight when B
        // supersedes it — that's the hazard. Swift does not specify which `async let` child starts
        // first, so the previous `async let first/second` pair could run B→A instead, in which case A
        // legitimately wins as the newest selection and the assertions below fail spuriously (it RED'd
        // the 2026-07-29 health gate, which then passed on retry against the identical commit).
        // `loadCount` ticks at the top of `Recorder.load` BEFORE its sleep, so seeing 1 means A is
        // parked inside its load with generation 1 already captured.
        let slowSelect = Task { await m.select(a) }
        var spins = 0
        while rec.loadCount == 0 && spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(rec.loadCount == 1, "A's load never started — the race was never set up")

        await m.select(b)                           // supersedes the in-flight A (generation 1 → 2)
        await slowSelect.value                      // let A's late load return and be dropped

        #expect(m.loadedID == b)
        #expect(m.markdown == "B-body")             // A's late load must not overwrite B
    }

    /// The mirror image of `supersededLoadIgnored`, and the ordering the old `async let` version of it
    /// hit whenever the scheduler started B first. It is NOT a hazard — the newest selection is meant to
    /// win even when it is the slow one — so pin it explicitly: the generation guard must drop only
    /// *superseded* loads, never merely late ones.
    @Test("a slow load that is NOT superseded still wins")
    func slowUnsupersededLoadStillWins() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        rec.loadDelays[a] = .milliseconds(80)       // the SECOND selection is the slow one
        let m = makeModel(rec)

        await m.select(b)
        #expect(m.loadedID == b)
        await m.select(a)                           // newest selection, slow load, nothing supersedes it

        #expect(m.loadedID == a)
        #expect(m.markdown == "A-body")
    }

    /// W40.fix-notes-inspector-jitter: going back to the loaded note returned early without retiring the load
    /// in flight, so B's late body landed while A was selected again.
    @Test("A → B → A: B's late load does not land over A selected again")
    func reselectingLoadedItemRetiresInFlightLoad() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        rec.loadDelays[b] = .milliseconds(80)
        let m = makeModel(rec)
        await m.select(a)
        let slowSelect = Task { await m.select(b) }
        var spins = 0
        while rec.loadCount < 2 && spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(rec.loadCount == 2, "B's load never started — the race was never set up")

        await m.select(a)
        await slowSelect.value

        #expect(m.loadedID == a)
        #expect(m.markdown == "A-body")
        #expect(m.settledSelection == .init(id: a))
    }

    /// The same race with A's save still running when A is selected again (found in review): B's `select` is then
    /// parked in its flush, not its load, and must still not load B afterwards.
    @Test("A → B → A during A's save: B is not loaded, A's edit is saved")
    func reselectingDuringOutgoingSaveRetiresSwitch() async {
        let a = UUID(), b = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        let m = makeModel(rec, debounce: .seconds(60))
        var saveStarted = false
        m.save = { id, body in
            saveStarted = true
            try? await Task.sleep(for: .milliseconds(80))
            await rec.save(id, body)
        }
        await m.select(a)
        m.markdown = "A edited"
        let switchToB = Task { await m.select(b) }
        var spins = 0
        while !saveStarted && spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(saveStarted, "A's save never started — the race was never set up")

        await m.select(a)
        await switchToB.value

        #expect(m.loadedID == a)
        #expect(m.markdown == "A edited")
        #expect(rec.bodies[a] == "A edited")
        #expect(rec.loadCount == 1, "B's body was never to be read")
        #expect(m.settledSelection == .init(id: a))
    }

    /// W40.fix-notes-inspector-jitter: the detail pane shows the loaded note until the switch settles, so the
    /// settled selection must be reported for every outcome but a superseded one, in the same call as the body.
    @Test("settledSelection follows each switch, also when the load fails")
    func settledSelectionReportsEveryOutcome() async {
        let a = UUID(), b = UUID(), missing = UUID()
        let rec = Recorder([a: "A-body", b: "B-body"])
        let m = makeModel(rec)
        var reports: [(loaded: UUID?, settled: UUID??)] = []
        m.onShownChange = { [weak m] in reports.append((m?.loadedID, m?.settledSelection.map(\.id))) }
        #expect(m.settledSelection == nil)

        await m.select(a)
        #expect(m.loadedID == a && m.settledSelection == .init(id: a))
        #expect(reports.last?.loaded == a && reports.last?.settled == .some(a))

        await m.select(missing)                       // the load fails: the body stays, the switch still settles
        #expect(m.loadedID == a)
        #expect(m.settledSelection == .init(id: missing))

        await m.select(b)
        await m.select(nil)
        #expect(m.loadedID == nil && m.settledSelection == .init(id: nil))
        #expect(reports.last?.loaded == nil && reports.last?.settled == .some(nil))
    }

    @Test("rapid edits coalesce into a single debounced save")
    func debouncedSaveCoalesces() async {
        let a = UUID()
        let rec = Recorder([a: "A-body"])
        let m = makeModel(rec, debounce: .milliseconds(30))
        await m.select(a)
        m.markdown = "x"
        m.markdown = "xy"
        m.markdown = "xyz"
        try? await Task.sleep(for: .milliseconds(120))   // let the debounce fire
        #expect(rec.saves.count == 1)
        #expect(rec.saves.first?.body == "xyz")
    }

    @Test("no autosave scheduled before an item is loaded")
    func noSaveWithoutLoadedItem() async {
        let rec = Recorder()
        let m = makeModel(rec, debounce: .milliseconds(20))
        m.markdown = "typed with nothing selected"   // loadedID == nil → ignored
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rec.saves.isEmpty)
    }
}
