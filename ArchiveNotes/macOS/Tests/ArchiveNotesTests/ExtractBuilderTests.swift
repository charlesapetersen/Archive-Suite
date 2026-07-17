import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

// W7-S1 — Extract data model + ExtractBuilder snapshot core. Pure/model tests + scratch-store
// persistence tests (never the real store or corpus — Prime Directive #1).

// MARK: - Fake selection seam (no live NSTextView, per plan §S1)

@MainActor
final class FakeSelectionSource: PassageSelectionSource {
    var sourceNoteId: UUID
    var sourceTitle: String
    var sourceDateDisplay: String
    var selectedRanges: [NSRange]
    var blockRanges: [(blockIndex: Int, range: NSRange)]
    private let fullText: NSString
    private let assetsForBlock: [Int: [String: Data]]

    init(sourceNoteId: UUID = UUID(),
         sourceTitle: String = "Source Note",
         sourceDateDisplay: String = "1968",
         fullText: String,
         selectedRanges: [NSRange],
         blockRanges: [(blockIndex: Int, range: NSRange)],
         assetsForBlock: [Int: [String: Data]] = [:]) {
        self.sourceNoteId = sourceNoteId
        self.sourceTitle = sourceTitle
        self.sourceDateDisplay = sourceDateDisplay
        self.fullText = fullText as NSString
        self.selectedRanges = selectedRanges
        self.blockRanges = blockRanges
        self.assetsForBlock = assetsForBlock
    }

    func snapshotMarkdown(in range: NSRange) -> (markdown: String, assets: [String: Data]) {
        let md = fullText.substring(with: range)
        let bi = blockRanges.first { NSLocationInRange(range.location, $0.range) }?.blockIndex
        return (md, bi.flatMap { assetsForBlock[$0] } ?? [:])
    }
}

// MARK: - SourceAnchor note-passage helpers

@Suite("SourceAnchor — note-passage helpers (W7-S1)")
struct SourceAnchorNotePassageTests {

    @Test("notePassage builds the canonical §8.2 URL in noteRef + a labelled display")
    func buildsCanonical() {
        let id = UUID()
        let a = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 2,
                                         sourceTitle: "Moore on Intel", sourceDateDisplay: "1968")
        #expect(a.link == nil)
        #expect(a.display == "Moore on Intel — 1968")
        #expect(a.noteRef == DurableLink.notesOpen(id: id, block: 2).url.absoluteString)
        #expect(a.noteRef?.contains("#block-2") == true)
    }

    @Test("empty date ⟹ label is just the title")
    func emptyDateLabel() {
        let a = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 0,
                                         sourceTitle: "Just Title", sourceDateDisplay: "  ")
        #expect(a.display == "Just Title")
    }

    @Test("notePassageTarget parses the canonical form")
    func parsesCanonical() throws {
        let id = UUID()
        let a = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 3,
                                         sourceTitle: "T", sourceDateDisplay: "1970")
        let target = try #require(a.notePassageTarget)
        #expect(target.id == id)
        #expect(target.block == 3)
    }

    @Test("notePassageTarget tolerates the legacy note/UUID spelling (read-only)")
    func parsesLegacy() throws {
        let id = UUID()
        let a = SourceAnchor(link: nil, display: "x", page: nil, thumbRef: nil, zoteroSelect: nil,
                             noteRef: "archivenotes://note/\(id.uuidString)#block-1")
        let target = try #require(a.notePassageTarget)
        #expect(target.id == id)
        #expect(target.block == 1)
    }

    @Test("notePassageTarget rejects non-passage / malformed anchors")
    func rejectsOthers() {
        #expect(SourceAnchor(link: nil, display: nil, page: nil, thumbRef: nil, zoteroSelect: nil,
                             noteRef: "archivereader://reveal?rootGUID=x&path=y").notePassageTarget == nil)
        #expect(SourceAnchor(link: "x", display: nil, page: 1, thumbRef: nil, zoteroSelect: nil,
                             noteRef: nil).notePassageTarget == nil)
        #expect(SourceAnchor(link: nil, display: nil, page: nil, thumbRef: nil, zoteroSelect: nil,
                             noteRef: "not a url at all ::::").notePassageTarget == nil)
    }

    @Test("on-disk header round-trips the note-passage block + preserves unknown fields")
    func onDiskRoundTrip() throws {
        let id = UUID()
        let anchor = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 2,
                                              sourceTitle: "Moore", sourceDateDisplay: "1968")
        let block = Block(kind: .notePassage, source: anchor, markdown: "Body text here.\n",
                          unknownHeaderFields: [("custom", "keepme")])
        let serialized = BlockParser.serialize(leadingText: nil, blocks: [block])
        #expect(serialized.contains("<!-- block: note-passage"))
        #expect(serialized.contains("note: \(anchor.noteRef!)"))

        let (_, parsed) = BlockParser.parse(serialized)
        let rt = try #require(parsed.first)
        #expect(rt.kind == .notePassage)
        #expect(rt.source?.noteRef == anchor.noteRef)
        #expect(rt.source?.display == "Moore — 1968")
        #expect(rt.markdown == "Body text here.\n")
        #expect(rt.unknownHeaderFields.first?.0 == "custom")
        #expect(rt.unknownHeaderFields.first?.1 == "keepme")
        #expect(rt.source?.notePassageTarget?.id == id)
    }
}

// MARK: - defaultTitle

@Suite("ExtractBuilder.defaultTitle (W7-S1)")
struct ExtractTitleTests {
    private func passage(_ md: String) -> ExtractPassageBlock {
        ExtractPassageBlock(block: Block(kind: .notePassage, source: nil, markdown: md,
                                         unknownHeaderFields: []))
    }
    private let epoch = Date(timeIntervalSince1970: 0)

    @Test("strips markdown markers")
    func stripsMarkers() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("# Hello **World**\nmore")],
                                            fallbackDate: epoch) == "Hello World")
    }

    @Test("skips leading blank + image-only lines")
    func skipsImageOnly() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("\n![pic](assets/x.png)\nReal Title")],
                                            fallbackDate: epoch) == "Real Title")
    }

    @Test("truncates on a word boundary at 80 chars")
    func truncates() {
        let long = String(repeating: "word ", count: 40) // 200 chars
        let t = ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(long)], fallbackDate: epoch)
        #expect(t.count <= 80)
        #expect(!t.hasSuffix(" "))
        #expect(t.hasPrefix("word word"))
    }

    @Test("falls back to Extract <date> for whitespace/image-only")
    func fallback() {
        let t = ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("   \n![only](assets/a.png)\n   ")],
                                            fallbackDate: epoch)
        #expect(t.hasPrefix("Extract "))
    }
}

// MARK: - Passage building + persistence

@Suite("ExtractBuilder — passage snapshot + persistence (W7-S1)")
@MainActor
struct ExtractBuilderTests {
    private func scratch() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    @Test("payload → one note-passage block per segment, ordinals preserved")
    func payloadBlocks() {
        let nid = UUID()
        let payload = NotesPassagePayload(
            sourceNoteId: nid, sourceTitle: "Src", sourceDateDisplay: "1968",
            segments: [.init(sourceBlockIndex: 2, markdown: "First"),
                       .init(sourceBlockIndex: 5, markdown: "Second")])
        let blocks = ExtractBuilder.passageBlocks(from: payload)
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.block.kind == .notePassage })
        #expect(blocks[0].block.source?.notePassageTarget?.block == 2)
        #expect(blocks[1].block.source?.notePassageTarget?.block == 5)
        #expect(blocks[0].block.source?.notePassageTarget?.id == nid)
        #expect(blocks[0].block.markdown == "First")
    }

    @Test("empty selection → no blocks")
    func emptySelection() {
        let src = FakeSelectionSource(fullText: "abc",
                                      selectedRanges: [NSRange(location: 0, length: 0)],
                                      blockRanges: [(0, NSRange(location: 0, length: 3))])
        #expect(ExtractBuilder.passageBlocks(fromSelectionIn: src).isEmpty)
    }

    @Test("single-block selection → one passage anchored to that block ordinal")
    func singleBlock() {
        let src = FakeSelectionSource(fullText: "Hello World",
                                      selectedRanges: [NSRange(location: 0, length: 5)],
                                      blockRanges: [(7, NSRange(location: 0, length: 11))])
        let blocks = ExtractBuilder.passageBlocks(fromSelectionIn: src)
        #expect(blocks.count == 1)
        #expect(blocks[0].block.markdown == "Hello")
        #expect(blocks[0].block.source?.notePassageTarget?.block == 7)
    }

    @Test("cross-block selection → one passage per covered block, in document order")
    func crossBlock() {
        let src = FakeSelectionSource(fullText: "AAAA\nBBBB\n",
                                      selectedRanges: [NSRange(location: 2, length: 6)],
                                      blockRanges: [(0, NSRange(location: 0, length: 5)),
                                                    (1, NSRange(location: 5, length: 5))])
        let blocks = ExtractBuilder.passageBlocks(fromSelectionIn: src)
        #expect(blocks.count == 2)
        #expect(blocks[0].block.source?.notePassageTarget?.block == 0)
        #expect(blocks[1].block.source?.notePassageTarget?.block == 1)
    }

    @Test("freeform source block still yields a note-passage anchor")
    func freeformStillPassage() {
        let src = FakeSelectionSource(fullText: "plain text",
                                      selectedRanges: [NSRange(location: 0, length: 10)],
                                      blockRanges: [(3, NSRange(location: 0, length: 10))])
        #expect(ExtractBuilder.passageBlocks(fromSelectionIn: src).first?.block.kind == .notePassage)
    }

    @Test("inline-image bytes are snapshotted (copied) into the passage")
    func assetsCarried() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let src = FakeSelectionSource(fullText: "see ![p](assets/p.png)",
                                      selectedRanges: [NSRange(location: 0, length: 22)],
                                      blockRanges: [(0, NSRange(location: 0, length: 22))],
                                      assetsForBlock: [0: ["p.png": bytes]])
        #expect(ExtractBuilder.passageBlocks(fromSelectionIn: src).first?.pendingAssets["p.png"] == bytes)
    }

    @Test("createExtract persists a byte-stable extract that reloads identically")
    func createRoundTrip() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        let builder = ExtractBuilder(store: store, now: { fixed })
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Moore on Intel culture", sourceDateDisplay: "1968",
            segments: [.init(sourceBlockIndex: 2, markdown: "Moore says he and Noyce were responsible…\n")])
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: payload))

        #expect(created.kind == .extract)
        #expect(created.datePrecision == .day)
        #expect(created.title == "Moore says he and Noyce were responsible…")
        #expect(created.blocks.count == 1)

        let reloaded = try await store.load(created.id)
        #expect(reloaded.kind == .extract)
        #expect(reloaded.blocks == created.blocks)
        #expect(reloaded.blocks.first?.source?.notePassageTarget?.block == 2)
        #expect(FrontMatterCodec.encode(reloaded) == FrontMatterCodec.encode(created))
    }

    @Test("createExtract copies inline-image bytes into the new extract's assets/ (independent copy)")
    func createCopiesAssets() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        let builder = ExtractBuilder(store: store, now: { fixed })
        let bytes = Data([1, 2, 3, 4, 5])
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "T", sourceDateDisplay: "",
            segments: [.init(sourceBlockIndex: 0, markdown: "![p](assets/p.png)\n", assetPNGs: ["p.png": bytes])])
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: payload))

        let assetURL = await store.assetsDir(created.id).appendingPathComponent("p.png")
        let onDisk = try #require(FileManager.default.contents(atPath: assetURL.path))
        #expect(onDisk == bytes)
        #expect(created.blocks.first?.markdown.contains("assets/p.png") == true)
    }

    @Test("append adds cross-note segments to an existing extract + bumps modified")
    func appendSegments() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let t0 = Date(timeIntervalSince1970: 1000)
        let created = try await ExtractBuilder(store: store, now: { t0 }).createExtract(
            from: ExtractBuilder.passageBlocks(from: NotesPassagePayload(
                sourceNoteId: UUID(), sourceTitle: "Note A", sourceDateDisplay: "1968",
                segments: [.init(sourceBlockIndex: 0, markdown: "From A\n")])))

        let t1 = Date(timeIntervalSince1970: 2000)
        try await ExtractBuilder(store: store, now: { t1 }).append(
            toExtract: created.id,
            passages: ExtractBuilder.passageBlocks(from: NotesPassagePayload(
                sourceNoteId: UUID(), sourceTitle: "Note B", sourceDateDisplay: "1972",
                segments: [.init(sourceBlockIndex: 3, markdown: "From B\n")])))

        let reloaded = try await store.load(created.id)
        #expect(reloaded.blocks.count == 2)
        #expect(reloaded.blocks[0].markdown == "From A\n")
        #expect(reloaded.blocks[1].markdown == "From B\n")
        #expect(reloaded.modified.timeIntervalSince1970 == 2000)
        #expect(reloaded.blocks[0].source?.notePassageTarget?.id
                != reloaded.blocks[1].source?.notePassageTarget?.id)
    }

    // MARK: - Extract-paste inline-image byte import (W14.3)

    /// The extract host must exist (its assets/ dir is the paste target). Returns a scratch NoteStore, a
    /// created extract Item, and an ItemAssetStore aimed at it — the production paste-import wiring.
    private func pasteFixture() async throws -> (store: NoteStore, tmp: URL, extractID: UUID, assets: ItemAssetStore) {
        let (store, tmp) = try scratch()
        let extract = try await ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1000) })
            .createExtract(from: ExtractBuilder.passageBlocks(from: NotesPassagePayload(
                sourceNoteId: UUID(), sourceTitle: "Host", sourceDateDisplay: "1968",
                segments: [.init(sourceBlockIndex: 0, markdown: "seed\n")])))
        let assets = ItemAssetStore(store: store, root: store.rootURL, itemID: extract.id)
        return (store, tmp, extract.id, assets)
    }

    @Test("extract-paste imports the payload's inline-image bytes into the extract's own assets/ (no collision → ref unchanged)")
    func pasteImportsBytesNoCollision() async throws {
        let f = try await pasteFixture(); defer { cleanup(f.tmp) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 0, markdown: "![q](assets/q.png)\n", assetPNGs: ["q.png": bytes])])

        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { data, bare in
            try? f.assets.addAsset(data, preferredName: bare)
        }
        await f.assets.awaitPendingWrites()

        #expect(markdown.contains("](assets/q.png)"))    // no collision → original ref preserved
        let dir = await f.store.assetsDir(f.extractID)
        #expect(try Data(contentsOf: dir.appendingPathComponent("q.png")) == bytes)  // bytes landed, self-contained
    }

    @Test("extract-paste disambiguates a name collision: bytes land at the new name, ref is rewritten, existing file untouched")
    func pasteRewritesRefOnCollision() async throws {
        let f = try await pasteFixture(); defer { cleanup(f.tmp) }
        // A same-named asset already lives in the extract (an earlier paste) — the new paste MUST NOT clobber it.
        let existing = Data("OLD".utf8)
        _ = try await f.store.importAsset(existing, preferredName: "p.png", into: f.extractID)
        let pasted = Data("NEW".utf8)
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 2, markdown: "see ![p](assets/p.png)\n", assetPNGs: ["p.png": pasted])])

        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { data, bare in
            try? f.assets.addAsset(data, preferredName: bare)
        }
        await f.assets.awaitPendingWrites()

        #expect(markdown.contains("](assets/p-1.png)"))  // rewritten to the disambiguated name
        #expect(!markdown.contains("](assets/p.png)"))
        let dir = await f.store.assetsDir(f.extractID)
        #expect(try Data(contentsOf: dir.appendingPathComponent("p-1.png")) == pasted)   // new bytes at new name
        #expect(try Data(contentsOf: dir.appendingPathComponent("p.png")) == existing)   // pre-existing bytes untouched
    }

    @Test("importingAssetsVia rewrites only collided refs; a nil (failed) import leaves that ref as-is — no crash")
    func pasteRewriteLogicAndNilResilience() {
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 0,
                             markdown: "![a](assets/a.png) then ![b](assets/b.png)\n",
                             assetPNGs: ["a.png": Data([1]), "b.png": Data([2])])])
        // a.png "collides" → stored as a-1.png; b.png import "fails" (nil) → its ref is preserved verbatim.
        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { _, bare in
            bare == "a.png" ? "assets/a-1.png" : nil
        }
        #expect(markdown.contains("](assets/a-1.png)"))  // collided ref rewritten
        #expect(!markdown.contains("](assets/a.png)"))
        #expect(markdown.contains("](assets/b.png)"))    // failed import → original ref left dangling, not dropped
    }
}

// MARK: - Extract-references-notes-only invariant

@Suite("ExtractBuilder.coercedToNotesOnly — extracts reference notes only (W7-S1)")
struct ExtractRejectsNonNoteAnchorsTests {

    @Test("valid note-passage block is preserved")
    func keepsNotePassage() {
        let a = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 1,
                                         sourceTitle: "T", sourceDateDisplay: "1968")
        let out = ExtractBuilder.coercedToNotesOnly([Block(kind: .notePassage, source: a,
                                                           markdown: "x", unknownHeaderFields: [])])
        #expect(out.first?.kind == .notePassage)
        #expect(out.first?.source != nil)
    }

    @Test("reader-page block coerces to freeform (source dropped, text preserved)")
    func coercesReader() {
        let b = Block(kind: .readerPage,
                      source: SourceAnchor(link: "archivereader://reveal?x=1", display: "Doc", page: 3,
                                           thumbRef: nil, zoteroSelect: nil, noteRef: nil),
                      markdown: "quote", unknownHeaderFields: [])
        let out = ExtractBuilder.coercedToNotesOnly([b])
        #expect(out.first?.kind == .freeform)
        #expect(out.first?.source == nil)
        #expect(out.first?.markdown == "quote")
    }

    @Test("zotero block coerces to freeform")
    func coercesZotero() {
        let b = Block(kind: .zoteroItem,
                      source: SourceAnchor(link: nil, display: "cite", page: nil, thumbRef: nil,
                                           zoteroSelect: "zotero://select/x", noteRef: nil),
                      markdown: "z", unknownHeaderFields: [])
        #expect(ExtractBuilder.coercedToNotesOnly([b]).first?.kind == .freeform)
    }

    @Test("note-passage with a malformed target coerces to freeform")
    func coercesMalformedPassage() {
        let b = Block(kind: .notePassage,
                      source: SourceAnchor(link: nil, display: "x", page: nil, thumbRef: nil,
                                           zoteroSelect: nil, noteRef: "archivereader://reveal?x=1"),
                      markdown: "m", unknownHeaderFields: [])
        #expect(ExtractBuilder.coercedToNotesOnly([b]).first?.kind == .freeform)
    }
}
