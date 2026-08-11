import XCTest
import AppKit
@testable import ArchiveNotes

/// W7-S2 (b) — the read side of Extracts: the block-ordinal map + the live-editor
/// `PassageSelectionSource`. Fixtures build a rendered note via `MarkdownBridge.parse` (chips come
/// from `BlockParser.serialize`, so every header round-trips) and drive the shipped
/// `ExtractBuilder.passageBlocks(fromSelectionIn:)` (W7-S1) through the real source.
@MainActor
final class NotePassageSourceTests: XCTestCase {

    private let noteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // MARK: Fixtures

    private func readerPageAnchor(_ n: Int) -> SourceAnchor {
        SourceAnchor(link: "archivereader://reveal?x=\(n)", display: "Doc\(n)", page: n,
                     thumbRef: nil, zoteroSelect: nil, noteRef: nil)
    }

    /// Rendered note = leading prose + one reader-page source block (chip + body). The leading text
    /// ends in `\n` because `BlockParser` only recognizes a `<!-- block:` marker at a line start —
    /// exactly how real `trailingBodyRaw` is sliced (right before a line-start marker).
    private func renderedProsePlusChip() -> NSAttributedString {
        let block = Block(kind: .readerPage, source: readerPageAnchor(1), markdown: "Quoted body.",
                          unknownHeaderFields: [])
        return MarkdownBridge.parse(markdown: BlockParser.serialize(leadingText: "Intro prose.\n",
                                                                    blocks: [block]))
    }

    /// Location of the first source-block chip, or `NSNotFound`.
    private func chipLocation(in s: NSAttributedString) -> Int {
        var loc = NSNotFound
        s.enumerateAttribute(.noteBlockSource, in: NSRange(location: 0, length: s.length)) { v, r, stop in
            if v != nil { loc = r.location; stop.pointee = true }
        }
        return loc
    }

    private func source(_ rendered: NSAttributedString, ranges: [NSRange],
                        assetBytes: @escaping @MainActor (String) -> Data? = { _ in nil })
        -> EditorPassageSource {
        EditorPassageSource(sourceNoteId: noteID, sourceTitle: "My Note", sourceDateDisplay: "1970",
                            rendered: rendered, selectedRanges: ranges, assetBytes: assetBytes)
    }

    /// Assert the block ranges are disjoint, ordered, and exactly cover `[0, length)`.
    private func assertDisjointCovering(_ blocks: [(blockIndex: Int, range: NSRange)],
                                        length: Int, file: StaticString = #filePath, line: UInt = #line) {
        var cursor = 0
        for (i, blk) in blocks.enumerated() {
            XCTAssertEqual(blk.blockIndex, i, "ordinal", file: file, line: line)
            XCTAssertEqual(blk.range.location, cursor, "gap/overlap at block \(i)", file: file, line: line)
            cursor = NSMaxRange(blk.range)
        }
        XCTAssertEqual(cursor, length, "coverage", file: file, line: line)
    }

    // MARK: blockRanges

    func testBlockRanges_emptyText_isEmpty() {
        XCTAssertTrue(NotePassageBlockMap.blockRanges(in: NSAttributedString(string: "")).isEmpty)
    }

    func testBlockRanges_plainProse_singleBlockCoversAll() {
        let r = MarkdownBridge.parse(markdown: "Hello world.")
        let blocks = NotePassageBlockMap.blockRanges(in: r)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].range, NSRange(location: 0, length: r.length))
    }

    func testBlockRanges_leadingProseThenChip_twoDisjointCoveringBlocks() {
        let r = renderedProsePlusChip()
        let blocks = NotePassageBlockMap.blockRanges(in: r)
        guard blocks.count == 2 else { return XCTFail("expected 2 blocks, got \(blocks.count)") }
        let chip = chipLocation(in: r)
        XCTAssertNotEqual(chip, NSNotFound)
        XCTAssertEqual(blocks[1].range.location, chip, "block 1 begins at the chip")
        assertDisjointCovering(blocks, length: r.length)
    }

    func testBlockRanges_startsWithChip_noEmptyLeadingBlock() {
        let block = Block(kind: .readerPage, source: readerPageAnchor(1), markdown: "Body.",
                          unknownHeaderFields: [])
        let r = MarkdownBridge.parse(markdown: BlockParser.serialize(leadingText: nil, blocks: [block]))
        let blocks = NotePassageBlockMap.blockRanges(in: r)
        XCTAssertEqual(blocks.count, 1)             // no zero-length leading prose block
        XCTAssertEqual(blocks[0].range.location, 0)
        XCTAssertEqual(chipLocation(in: r), 0)
    }

    func testBlockRanges_twoChips_threeBlocksDisjointCovering() {
        // A non-terminal block's markdown ends in `\n` (real block bodies do — the next block's
        // marker must land at a line start), so the second chip is recognized on re-parse.
        let b1 = Block(kind: .readerPage, source: readerPageAnchor(1), markdown: "One.\n",
                       unknownHeaderFields: [])
        let b2 = Block(kind: .readerPage, source: readerPageAnchor(2), markdown: "Two.",
                       unknownHeaderFields: [])
        let r = MarkdownBridge.parse(markdown: BlockParser.serialize(leadingText: "Lead.\n",
                                                                     blocks: [b1, b2]))
        let blocks = NotePassageBlockMap.blockRanges(in: r)
        XCTAssertEqual(blocks.count, 3)
        assertDisjointCovering(blocks, length: r.length)
    }

    // MARK: selection → passage blocks (via ExtractBuilder, W7-S1)

    func testSelectionWithinOneBlock_oneAnchoredPassage() {
        let r = MarkdownBridge.parse(markdown: "Hello world.")
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn:
            source(r, ranges: [NSRange(location: 0, length: 5)]))
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].block.kind, .notePassage)
        let target = passages[0].block.source?.notePassageTarget
        XCTAssertEqual(target?.id, noteID)
        XCTAssertEqual(target?.block, 0)
    }

    func testSelectionSpanningTwoBlocks_twoPassagesInDocOrder() {
        let r = renderedProsePlusChip()
        let chip = chipLocation(in: r)
        let sel = NSRange(location: 2, length: (chip + 3) - 2)   // mid-prose → into block 1
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn: source(r, ranges: [sel]))
        XCTAssertEqual(passages.count, 2)
        XCTAssertEqual(passages.compactMap { $0.block.source?.notePassageTarget?.block }, [0, 1])
    }

    func testEmptySelection_noPassages() {
        let r = MarkdownBridge.parse(markdown: "Hello world.")
        XCTAssertTrue(ExtractBuilder.passageBlocks(fromSelectionIn:
            source(r, ranges: [NSRange(location: 3, length: 0)])).isEmpty)
    }

    func testDiscontiguousSelection_concatenatesInDocOrder() {
        let r = renderedProsePlusChip()
        let chip = chipLocation(in: r)
        // ranges given block-1-first: the result must still be document-ordered [0, 1].
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn:
            source(r, ranges: [NSRange(location: chip, length: 2), NSRange(location: 0, length: 3)]))
        XCTAssertEqual(passages.compactMap { $0.block.source?.notePassageTarget?.block }, [0, 1])
    }

    // MARK: snapshotMarkdown

    func testSnapshotMarkdown_serializesCoveredRange() {
        let r = MarkdownBridge.parse(markdown: "**bold** and plain.")
        let (md, assets) = source(r, ranges: []).snapshotMarkdown(in: NSRange(location: 0, length: r.length))
        XCTAssertTrue(md.contains("**bold**"), "got: \(md)")
        XCTAssertTrue(assets.isEmpty)
    }

    func testSnapshotMarkdown_collectsInlineImageBytesByBareName() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let r = MarkdownBridge.parse(markdown: "See ![alt](assets/img.png) here.")
        let src = source(r, ranges: [], assetBytes: { $0 == "assets/img.png" ? bytes : nil })
        let (md, assets) = src.snapshotMarkdown(in: NSRange(location: 0, length: r.length))
        XCTAssertTrue(md.contains("assets/img.png"), "got: \(md)")
        XCTAssertEqual(assets["img.png"], bytes)                 // keyed by BARE filename
    }

    func testSnapshotMarkdown_emptyRange_returnsEmpty() {
        let r = MarkdownBridge.parse(markdown: "Hello.")
        let (md, assets) = source(r, ranges: []).snapshotMarkdown(in: NSRange(location: 3, length: 0))
        XCTAssertEqual(md, "")
        XCTAssertTrue(assets.isEmpty)
    }

    // MARK: W3.notes-extract-smuggles-a-source-header — a snapshot never re-emits the source's chip

    /// A selection that covers a whole block starts AT that block's chip (`blockRanges` is
    /// chip-delimited), so the snapshot must NOT serialize the chip back into the passage body: the
    /// whole snapshot becomes ONE `note-passage` block's markdown, and a `<!-- block: reader-page -->`
    /// nested inside it re-parses as a second, non-note block *inside the extract* (00-overview §D7).
    func testSnapshotMarkdown_leadingChip_isNotSerializedIntoTheBody() {
        let r = renderedProsePlusChip()
        let chip = chipLocation(in: r)
        XCTAssertNotEqual(chip, NSNotFound)
        let whole = NSRange(location: chip, length: r.length - chip)
        let (md, _) = source(r, ranges: []).snapshotMarkdown(in: whole)
        // Exact, not `contains`: the chip's own trailing newline goes with it, so the passage body
        // does not open on a blank line.
        XCTAssertEqual(md, "Quoted body.")
    }

    /// A range spanning prose + a chip: both bodies survive, on their own lines, with no header
    /// between them. (`passageBlocks` never asks for a multi-segment range — it intersects the
    /// selection with one block at a time — but the stripper is not allowed to fuse two lines.)
    func testSnapshotMarkdown_interiorChip_isNotSerializedIntoTheBody() {
        let r = renderedProsePlusChip()
        let (md, _) = source(r, ranges: []).snapshotMarkdown(in: NSRange(location: 0, length: r.length))
        XCTAssertEqual(md, "Intro prose.\nQuoted body.")
    }

    /// End to end through the shipped builder: the passage block a whole-block selection produces
    /// carries no nested header at all.
    func testPassageBlocks_wholeBlockSelection_carriesNoNestedHeader() {
        let r = renderedProsePlusChip()
        let chip = chipLocation(in: r)
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn:
            source(r, ranges: [NSRange(location: chip, length: r.length - chip)]))
        XCTAssertEqual(passages.count, 1)
        XCTAssertFalse(passages[0].block.markdown.contains("<!-- block:"),
                       "got: \(passages[0].block.markdown)")
    }

    // MARK: live-view snapshot independence (D7 value copy)

    func testLiveInit_snapshotsByValue_independentOfLaterEdits() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.textStorage?.setAttributedString(MarkdownBridge.parse(markdown: "Original text."))
        tv.setSelectedRange(NSRange(location: 0, length: 8))
        let src = EditorPassageSource(textView: tv, sourceNoteId: noteID, sourceTitle: "N",
                                      sourceDateDisplay: "1970", assetStore: nil)
        let before = src.rendered.string
        tv.textStorage?.setAttributedString(MarkdownBridge.parse(markdown: "Completely different."))
        XCTAssertEqual(src.rendered.string, before)              // snapshot unaffected by later edits
        XCTAssertEqual(src.selectedRanges, [NSRange(location: 0, length: 8)])
    }
}
