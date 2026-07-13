import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

/// W6-S5: the pure drag-payload codec + MOVE/REPLICATE resolution. The drag carries **ids only**
/// (no file bytes), and a malformed/foreign payload must decode to `[]` so a stray drop is inert.
@Suite("NotesItemDrag — id-only pasteboard codec")
struct NotesItemDragTests {

    @Test func roundTripsIDsInOrder() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(NotesItemDrag.decode(NotesItemDrag.encode(ids)) == ids)
    }

    @Test func stringRoundTrips() {
        let ids = [UUID(), UUID()]
        #expect(NotesItemDrag.decode(string: NotesItemDrag.encodedString(ids)) == ids)
    }

    @Test func emptyEncodesToEmptyJSON() {
        #expect(NotesItemDrag.encodedString([]) == "[]")
        #expect(NotesItemDrag.decode(NotesItemDrag.encode([])) == [])
    }

    @Test func malformedDataDecodesToEmpty() {
        #expect(NotesItemDrag.decode(Data("not json".utf8)) == [])
        #expect(NotesItemDrag.decode(Data()) == [])
    }

    @Test func foreignJSONDropsNonUUIDStrings() {
        // A JSON array of strings where only some are UUIDs → keep only the valid UUIDs, drop the rest.
        let good = UUID()
        let json = "[\"\(good.uuidString)\",\"hello\",\"\"]"
        #expect(NotesItemDrag.decode(string: json) == [good])
    }

    @Test func optionModifierPicksReplicateElseMove() {
        #expect(NotesItemDrag.operation(optionHeld: true) == .copy)   // ⌥ = replicate
        #expect(NotesItemDrag.operation(optionHeld: false) == .move)  // plain = move
    }
}
