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

    @Test func folderDragAlwaysMoves() {
        #expect(NotesItemDrag.operation(isFolder: true, optionHeld: true) == .move)
        #expect(NotesItemDrag.operation(isFolder: true, optionHeld: false) == .move)
        #expect(NotesItemDrag.operation(isFolder: false, optionHeld: true) == .copy)
        #expect(NotesItemDrag.operation(isFolder: false, optionHeld: false) == .move)
    }

    // W40.fix-notes-folder-drag: the row's highlight and its drop both come from these two.

    @Test func folderDropZoneSplitsTheRowIntoEdgesAndMiddle() {
        #expect(NotesItemDrag.dropZone(y: 0, rowHeight: 24, isFolder: true) == .before)
        #expect(NotesItemDrag.dropZone(y: 6, rowHeight: 24, isFolder: true) == .before)
        #expect(NotesItemDrag.dropZone(y: 7, rowHeight: 24, isFolder: true) == .into)
        #expect(NotesItemDrag.dropZone(y: 12, rowHeight: 24, isFolder: true) == .into)
        #expect(NotesItemDrag.dropZone(y: 17, rowHeight: 24, isFolder: true) == .into)
        #expect(NotesItemDrag.dropZone(y: 18, rowHeight: 24, isFolder: true) == .after)
        #expect(NotesItemDrag.dropZone(y: 24, rowHeight: 24, isFolder: true) == .after)
    }

    @Test func notesAndUnmeasuredRowsAlwaysDropInto() {
        for y in [0.0, 12, 24] {
            #expect(NotesItemDrag.dropZone(y: y, rowHeight: 24, isFolder: false) == .into)
        }
        #expect(NotesItemDrag.dropZone(y: 0, rowHeight: 0, isFolder: true) == .into)
    }

    @Test func dragKindReadsTheDragPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("an.test.drag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        // Note rows from the table: the ids type wins even though `.string` holds JSON too.
        let note = UUID()
        let item = NSPasteboardItem()
        item.setData(NotesItemDrag.encode([note]), forType: NotesItemDrag.pasteboardType)
        item.setString(NotesItemDrag.encodedString([note]), forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(NotesItemDrag.dragKind(on: pasteboard) == .items)

        // A folder row's drag: its id as text.
        let folder = UUID()
        pasteboard.clearContents()
        pasteboard.setString(folder.uuidString, forType: .string)
        #expect(NotesItemDrag.dragKind(on: pasteboard) == .folder(folder))

        // The folder type, when it is there, is read first.
        let other = UUID()
        let folderType = NSPasteboard.PasteboardType(NotesItemDrag.folderTypeIdentifier)
        pasteboard.declareTypes([folderType, .string], owner: nil)
        pasteboard.setData(Data(other.uuidString.utf8), forType: folderType)
        pasteboard.setString("not an id", forType: .string)
        #expect(NotesItemDrag.dragKind(on: pasteboard) == .folder(other))

        // Text from another app, and nothing at all.
        pasteboard.clearContents()
        pasteboard.setString("some dragged words", forType: .string)
        #expect(NotesItemDrag.dragKind(on: pasteboard) == .other)
        pasteboard.clearContents()
        #expect(NotesItemDrag.dragKind(on: pasteboard) == .other)
    }
}
