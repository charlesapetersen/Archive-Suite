import Testing
import AppKit
import Foundation
@testable import ArchiveNotes

/// W7-S3 — jump-to-source resolution + provenance-chip labeling. Pure logic over an in-memory
/// `[ItemSummary]` (the shared `NotesModel.allItems`), plus the ordinal→range wrapper for scroll and
/// the `NotesModel.openItem` cross-window channel. No window server / no store needed for the pure
/// cases; the scroll + openItem cases run on the main actor.
@MainActor
struct NotePassageResolveTests {

    // MARK: Fixtures

    private let sourceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func passageAnchor(id: UUID? = nil, block: Int, title: String = "Moore on Intel",
                               date: String = "1968") -> SourceAnchor {
        .notePassage(sourceNoteId: id ?? sourceID, sourceBlockIndex: block,
                     sourceTitle: title, sourceDateDisplay: date)
    }

    private func summary(_ id: UUID, title: String, kind: Item.Kind = .note,
                         date: String? = nil, precision: Item.DatePrecision? = nil) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: id, title: title, kind: kind, date: date, datePrecision: precision,
                           dateUncertain: false, authors: [], sortDate: nil, quality: nil,
                           created: t, modified: t, mtime: 0, managedTags: [])
    }

    // MARK: resolve

    @Test func resolveResolvedNoteCarriesBlockAndLiveTitle() {
        let anchor = passageAnchor(block: 2)
        let items = [summary(sourceID, title: "Renamed note", date: "1970", precision: .year)]
        #expect(NotePassageResolve.resolve(anchor: anchor, among: items)
                == .resolved(id: sourceID, block: 2, liveTitle: "Renamed note", dateDisplay: "1970"))
    }

    @Test func resolveOutOfRangeBlockStillResolvesNote() {
        // resolve() carries the snapshot ordinal verbatim; range-validity is the scroll side's job.
        let anchor = passageAnchor(block: 99)
        let items = [summary(sourceID, title: "Note", date: nil)]
        #expect(NotePassageResolve.resolve(anchor: anchor, among: items)
                == .resolved(id: sourceID, block: 99, liveTitle: "Note", dateDisplay: ""))
    }

    @Test func resolveDeletedSourceWhenIdAbsent() {
        let anchor = passageAnchor(block: 0)
        let items = [summary(UUID(), title: "Some other note")]   // target id not present
        #expect(NotePassageResolve.resolve(anchor: anchor, among: items) == .sourceDeleted(id: sourceID))
    }

    @Test func resolveWrongKindWhenTargetIsExtract() {
        let anchor = passageAnchor(block: 0)
        let items = [summary(sourceID, title: "An extract", kind: .extract)]
        #expect(NotePassageResolve.resolve(anchor: anchor, among: items) == .wrongKind(id: sourceID))
    }

    @Test func resolveMalformedWhenNotANotePassageAnchor() {
        // A reader-page anchor (link, no noteRef) is not a note-passage anchor.
        let reader = SourceAnchor(link: "archivereader://reveal?x=1", display: "Doc", page: 1,
                                  thumbRef: nil, zoteroSelect: nil, noteRef: nil)
        #expect(NotePassageResolve.resolve(anchor: reader, among: []) == .malformed)
        #expect(NotePassageResolve.resolve(anchor: SourceAnchor(), among: []) == .malformed)
    }

    // MARK: chipLabel — live title with snapshot fallback

    @Test func chipLabelPrefersLiveTitleOverSnapshot() {
        // Snapshot display was "Moore on Intel — 1968"; the note has since been renamed + re-dated.
        let anchor = passageAnchor(block: 1, title: "Moore on Intel", date: "1968")
        let items = [summary(sourceID, title: "Egalitarian culture", date: "1970", precision: .year)]
        #expect(NotePassageResolve.chipLabel(anchor: anchor, among: items) == "Egalitarian culture — 1970")
    }

    @Test func chipLabelLiveTitleOnlyWhenNoDate() {
        let anchor = passageAnchor(block: 0)
        let items = [summary(sourceID, title: "Undated note", date: nil)]
        #expect(NotePassageResolve.chipLabel(anchor: anchor, among: items) == "Undated note")
    }

    @Test func chipLabelFallsBackToSnapshotWhenDeleted() {
        let anchor = passageAnchor(block: 0, title: "Moore on Intel", date: "1968")
        #expect(NotePassageResolve.chipLabel(anchor: anchor, among: []) == "Moore on Intel — 1968")
    }

    @Test func chipLabelNeutralFallbackWhenSnapshotEmpty() {
        // Malformed anchor with no display → non-empty neutral label (never a blank chip).
        #expect(NotePassageResolve.chipLabel(anchor: SourceAnchor(), among: []) == "Source note")
    }

    // MARK: isSourceMissing

    @Test func isSourceMissingReflectsResolution() {
        let anchor = passageAnchor(block: 0)
        #expect(NotePassageResolve.isSourceMissing(anchor: anchor, among: []) == true)                  // deleted
        #expect(NotePassageResolve.isSourceMissing(anchor: anchor,
                among: [summary(sourceID, title: "n")]) == false)                                       // present note
        #expect(NotePassageResolve.isSourceMissing(anchor: anchor,
                among: [summary(sourceID, title: "e", kind: .extract)]) == true)                        // wrong kind
    }

    // MARK: scrollRange — ordinal → rendered range wrapper

    /// Rendered note = leading prose (block 0) + one source-block chip+body (block 1).
    private func prosePlusChip() -> NSAttributedString {
        let block = Block(kind: .notePassage, source: passageAnchor(block: 0),
                          markdown: "Quoted body.", unknownHeaderFields: [])
        return MarkdownBridge.parse(markdown: BlockParser.serialize(leadingText: "Intro prose.\n",
                                                                    blocks: [block]))
    }

    @Test func scrollRangeMatchesBlockMapForInRangeOrdinals() {
        let rendered = prosePlusChip()
        let ranges = NotePassageBlockMap.blockRanges(in: rendered)
        #expect(ranges.count == 2)
        #expect(NotePassageResolve.scrollRange(forBlock: 0, in: rendered) == ranges[0].range)
        #expect(NotePassageResolve.scrollRange(forBlock: 1, in: rendered) == ranges[1].range)
    }

    @Test func scrollRangeNilForOutOfRangeStaleOrdinal() {
        let rendered = prosePlusChip()   // 2 blocks
        #expect(NotePassageResolve.scrollRange(forBlock: 2, in: rendered) == nil)
        #expect(NotePassageResolve.scrollRange(forBlock: 99, in: rendered) == nil)
    }

    @Test func scrollRangeNilForNilBlockOrNegativeOrEmptyText() {
        let rendered = prosePlusChip()
        #expect(NotePassageResolve.scrollRange(forBlock: nil, in: rendered) == nil)
        #expect(NotePassageResolve.scrollRange(forBlock: -1, in: rendered) == nil)
        #expect(NotePassageResolve.scrollRange(forBlock: 0, in: NSAttributedString(string: "")) == nil)
    }

    // MARK: NotesModel.openItem — the cross-window navigation channel

    private func makeModel() async throws -> (NotesModel, NotesIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-resolve-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (NotesModel(organization: store), index, root)
    }
    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close(); try? FileManager.default.removeItem(at: root)
    }

    @Test func openItemPublishesRequestAndReFiresForSameTargetViaToken() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }

        #expect(model.pendingOpen == nil)

        model.openItem(id: sourceID, block: 2)
        let first = model.pendingOpen
        #expect(first?.id == sourceID)
        #expect(first?.block == 2)

        // Re-jumping to the SAME (id, block) must produce a NEW token so the observer re-scrolls.
        model.openItem(id: sourceID, block: 2)
        #expect(model.pendingOpen?.token != first?.token)
        #expect(model.pendingOpen?.id == sourceID)

        model.consumeOpen()
        #expect(model.pendingOpen == nil)
    }

    @Test func resolvePassageUsesModelAllItems() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        model.replaceItems([summary(sourceID, title: "Live title", date: "1970", precision: .year)])
        #expect(model.resolvePassage(passageAnchor(block: 1))
                == .resolved(id: sourceID, block: 1, liveTitle: "Live title", dateDisplay: "1970"))
    }
}
