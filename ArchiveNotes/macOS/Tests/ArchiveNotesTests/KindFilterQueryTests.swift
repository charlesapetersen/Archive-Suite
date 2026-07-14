import Testing
import Foundation
@testable import ArchiveNotes

// W7-S4 — extract-viewer featuring. Two pure, window-server-free concerns:
//   1. the `NotesFilter` KIND predicate over `ItemSummary` (`.notes` / `.extracts` / `.both`), the
//      basis of each window featuring its kind (the in-memory equivalent of the plan's `WHERE kind IN`);
//   2. the distinct-SOURCE-NOTE count that feeds the extract-only "Sources" column — derived from an
//      item's `.notePassage` block anchors, projected through the index (`NoteIndexRow`) and rendered
//      by `ItemSummary.sourcesText`.
@Suite struct KindFilterQueryTests {

    // MARK: Fixtures

    private func summary(kind: Item.Kind, sources: Int = 0) -> ItemSummary {
        ItemSummary(id: UUID(), title: "t", kind: kind, date: nil, datePrecision: nil,
                    dateUncertain: false, authors: [], sortDate: nil, quality: nil,
                    created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
                    mtime: 0, managedTags: [], sourceNoteCount: sources)
    }

    /// A `.notePassage` block whose provenance points at `sourceNoteId` (canonical §8.2 URL in noteRef).
    private func passageBlock(from sourceNoteId: UUID, block: Int = 0) -> Block {
        Block(kind: .notePassage,
              source: .notePassage(sourceNoteId: sourceNoteId, sourceBlockIndex: block,
                                   sourceTitle: "Src", sourceDateDisplay: ""),
              markdown: "Passage body.\n", unknownHeaderFields: [])
    }

    private func item(kind: Item.Kind, blocks: [Block]) -> Item {
        Item(id: UUID(), kind: kind, title: "", authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
             schema: 1, blocks: blocks, unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    // MARK: - Kind predicate (NotesFilter.matches)

    @Test("kind .notes admits notes, rejects extracts")
    func kindNotes() {
        let f = NotesFilter(kind: .notes)
        #expect(f.matches(summary(kind: .note), folderItemIDs: nil))
        #expect(!f.matches(summary(kind: .extract), folderItemIDs: nil))
    }

    @Test("kind .extracts admits extracts, rejects notes")
    func kindExtracts() {
        let f = NotesFilter(kind: .extracts)
        #expect(f.matches(summary(kind: .extract), folderItemIDs: nil))
        #expect(!f.matches(summary(kind: .note), folderItemIDs: nil))
    }

    @Test("kind .both admits every kind")
    func kindBoth() {
        let f = NotesFilter(kind: .both)
        #expect(f.matches(summary(kind: .note), folderItemIDs: nil))
        #expect(f.matches(summary(kind: .extract), folderItemIDs: nil))
    }

    @Test("the window default filters to the window's own kind")
    func windowDefaults() {
        // Note window defaults to .notes, Extract window to .extracts (07-extracts §4).
        #expect(NotesFilter(kind: .notes).matches(summary(kind: .note), folderItemIDs: nil))
        #expect(!NotesFilter(kind: .notes).matches(summary(kind: .extract), folderItemIDs: nil))
        #expect(NotesFilter(kind: .extracts).matches(summary(kind: .extract), folderItemIDs: nil))
        #expect(!NotesFilter(kind: .extracts).matches(summary(kind: .note), folderItemIDs: nil))
    }

    // MARK: - Distinct-source-note count ([Block].distinctSourceNoteCount)

    @Test("no blocks / freeform blocks → 0 sources")
    func countZero() {
        #expect([Block]().distinctSourceNoteCount == 0)
        let freeform = Block(kind: .freeform, source: nil, markdown: "plain", unknownHeaderFields: [])
        #expect([freeform].distinctSourceNoteCount == 0)
    }

    @Test("a single note-passage → 1 source")
    func countOne() {
        #expect([passageBlock(from: UUID())].distinctSourceNoteCount == 1)
    }

    @Test("two passages from the SAME note → 1 distinct source")
    func countSameNoteDeduped() {
        let n = UUID()
        let blocks = [passageBlock(from: n, block: 0), passageBlock(from: n, block: 4)]
        #expect(blocks.distinctSourceNoteCount == 1)
    }

    @Test("a segmented extract from TWO notes → 2 distinct sources")
    func countSegmented() {
        let blocks = [passageBlock(from: UUID()), passageBlock(from: UUID())]
        #expect(blocks.distinctSourceNoteCount == 2)
    }

    @Test("non-passage blocks are ignored in the count")
    func countIgnoresNonPassage() {
        let reader = Block(kind: .readerPage,
                           source: SourceAnchor(link: "archivereader://reveal?rootGUID=x&path=y"),
                           markdown: "quote", unknownHeaderFields: [])
        let blocks = [reader, passageBlock(from: UUID())]
        #expect(blocks.distinctSourceNoteCount == 1)
    }

    // MARK: - Index projection + display

    @Test("NoteIndexRow projects the distinct-source count from an item's blocks")
    func rowProjectsCount() {
        let extract = item(kind: .extract,
                           blocks: [passageBlock(from: UUID()), passageBlock(from: UUID())])
        #expect(NoteIndexRow(item: extract, mtime: 0).sourceCount == 2)

        // A plain note (no passages) projects 0.
        let note = item(kind: .note, blocks: [])
        #expect(NoteIndexRow(item: note, mtime: 0).sourceCount == 0)
    }

    @Test("sourcesText renders the count for extracts, blank for none")
    func sourcesTextRendering() {
        #expect(summary(kind: .extract, sources: 3).sourcesText == "3")
        #expect(summary(kind: .extract, sources: 1).sourcesText == "1")
        #expect(summary(kind: .extract, sources: 0).sourcesText == "")   // source-less extract → blank
        #expect(summary(kind: .note, sources: 0).sourcesText == "")      // notes never carry passages
    }
}
