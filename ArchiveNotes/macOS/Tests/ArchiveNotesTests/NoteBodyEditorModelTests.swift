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
