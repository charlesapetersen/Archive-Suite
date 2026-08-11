import XCTest
@testable import ArchiveNotes

final class BlockParserTests: XCTestCase {

    // MARK: - Parse

    func testEmptyBody() {
        let (leading, blocks) = BlockParser.parse("")
        XCTAssertNil(leading)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testBodyWithNoHeaders() {
        let body = "Just plain text.\n"
        let (leading, blocks) = BlockParser.parse(body)
        XCTAssertEqual(leading, body)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testSingleFreeformBlock() {
        let body = "<!-- block: freeform -->\nSome text here.\n"
        let (leading, blocks) = BlockParser.parse(body)
        XCTAssertNil(leading)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .freeform)
        XCTAssertEqual(blocks[0].markdown, "Some text here.\n")
        XCTAssertNil(blocks[0].source)
    }

    func testReaderPageBlock() {
        let body = """
            <!-- block: reader-page
                 link: archivereader://reveal?root=ABC&rel=doc.pdf&page=5
                 display: "My Document - p. 5"
                 page: 5
                 thumb: assets/p5.png -->
            ![My Document - p. 5](assets/p5.png)

            Some annotation.

            """
        let (leading, blocks) = BlockParser.parse(body)
        XCTAssertNil(leading)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .readerPage)
        XCTAssertEqual(blocks[0].source?.link,
                       "archivereader://reveal?root=ABC&rel=doc.pdf&page=5")
        XCTAssertEqual(blocks[0].source?.display, "My Document - p. 5")
        XCTAssertEqual(blocks[0].source?.page, 5)
        XCTAssertEqual(blocks[0].source?.thumbRef, "assets/p5.png")
    }

    func testMultipleBlocks() {
        let body = """
            <!-- block: reader-page
                 link: archivereader://x
                 display: "Doc p.1" -->
            Page content.

            <!-- block: freeform -->
            My notes.

            """
        let (leading, blocks) = BlockParser.parse(body)
        XCTAssertNil(leading)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .readerPage)
        XCTAssertEqual(blocks[1].kind, .freeform)
        XCTAssertTrue(blocks[1].markdown.contains("My notes."))
    }

    func testLeadingTextBeforeBlocks() {
        let body = "Intro text.\n\n<!-- block: freeform -->\nBlock text.\n"
        let (leading, blocks) = BlockParser.parse(body)
        XCTAssertEqual(leading, "Intro text.\n\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].markdown, "Block text.\n")
    }

    func testUnknownHeaderFieldsPreserved() {
        let body = """
            <!-- block: reader-page
                 link: archivereader://x
                 future_key: future_value -->
            Content.

            """
        let (_, blocks) = BlockParser.parse(body)
        XCTAssertEqual(blocks[0].unknownHeaderFields.count, 1)
        XCTAssertEqual(blocks[0].unknownHeaderFields[0].0, "future_key")
        XCTAssertEqual(blocks[0].unknownHeaderFields[0].1, "future_value")
    }

    func testAllBlockKinds() {
        let kinds: [(String, Block.Kind)] = [
            ("freeform", .freeform),
            ("reader-page", .readerPage),
            ("reader-doc", .readerDoc),
            ("zotero-item", .zoteroItem),
            ("zotero-attachment", .zoteroAttachment),
            ("note-passage", .notePassage),
        ]
        for (raw, expected) in kinds {
            let body = "<!-- block: \(raw) -->\nBody.\n"
            let (_, blocks) = BlockParser.parse(body)
            XCTAssertEqual(blocks[0].kind, expected, "Failed for \(raw)")
        }
    }

    func testNotePassageWithNoteRef() {
        let body = """
            <!-- block: note-passage
                 note: archivenotes://open?id=abc123#block-2
                 display: "Source Note - block 2" -->
            Quoted passage.

            """
        let (_, blocks) = BlockParser.parse(body)
        XCTAssertEqual(blocks[0].kind, .notePassage)
        XCTAssertEqual(blocks[0].source?.noteRef, "archivenotes://open?id=abc123#block-2")
        XCTAssertEqual(blocks[0].source?.display, "Source Note - block 2")
    }

    // MARK: - Serialize

    func testSerializeFreeform() {
        let block = Block(kind: .freeform, source: nil, markdown: "Hello.\n",
                          unknownHeaderFields: [])
        let output = BlockParser.serialize(leadingText: nil, blocks: [block])
        XCTAssertEqual(output, "<!-- block: freeform -->\nHello.\n")
    }

    func testSerializeReaderPage() {
        let block = Block(
            kind: .readerPage,
            source: SourceAnchor(link: "archivereader://x", display: "Doc p.1", page: 1,
                                 thumbRef: "assets/p1.png"),
            markdown: "Content.\n",
            unknownHeaderFields: []
        )
        let output = BlockParser.serialize(leadingText: nil, blocks: [block])
        XCTAssertTrue(output.contains("<!-- block: reader-page"))
        XCTAssertTrue(output.contains("     link: archivereader://x"))
        XCTAssertTrue(output.contains("     display: \"Doc p.1\""))
        XCTAssertTrue(output.contains("     page: 1"))
        XCTAssertTrue(output.contains("     thumb: assets/p1.png -->"))
        XCTAssertTrue(output.contains("Content.\n"))
    }

    func testSerializeWithLeadingText() {
        let block = Block(kind: .freeform, source: nil, markdown: "B.\n",
                          unknownHeaderFields: [])
        let output = BlockParser.serialize(leadingText: "Intro.\n\n", blocks: [block])
        XCTAssertTrue(output.hasPrefix("Intro.\n\n"))
        XCTAssertTrue(output.contains("<!-- block: freeform -->\nB.\n"))
    }

    func testSerializeUnknownFields() {
        let block = Block(kind: .freeform, source: nil, markdown: "X.\n",
                          unknownHeaderFields: [("future", "val")])
        let output = BlockParser.serialize(leadingText: nil, blocks: [block])
        XCTAssertTrue(output.contains("     future: val"))
    }

    // MARK: - Round-trip

    func testRoundTripParse() {
        let body = """
            <!-- block: reader-page
                 link: archivereader://x
                 display: "Doc p.1"
                 page: 1
                 thumb: assets/p1.png -->
            ![Doc p.1](assets/p1.png)

            Content here.

            <!-- block: freeform -->
            My notes.

            """
        let (leading, blocks) = BlockParser.parse(body)
        let serialized = BlockParser.serialize(leadingText: leading, blocks: blocks)
        XCTAssertEqual(serialized, body)
    }

    func testRoundTripWithLeadingText() {
        let body = "Leading.\n\n<!-- block: freeform -->\nText.\n"
        let (leading, blocks) = BlockParser.parse(body)
        let serialized = BlockParser.serialize(leadingText: leading, blocks: blocks)
        XCTAssertEqual(serialized, body)
    }

    /// W7-S2 regression: two blocks whose bodies do NOT end in a newline (a partial-paragraph passage
    /// snapshot) must still serialize so each `<!-- block:` header starts on its own line — otherwise
    /// `parse` (which only recognizes a header at a line start) silently merges them into one block.
    func testSerializeSeparatesNonNewlineTerminatedBlocks() {
        let a = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 0,
                                         sourceTitle: "A", sourceDateDisplay: "1968")
        let b = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 1,
                                         sourceTitle: "B", sourceDateDisplay: "1972")
        let blocks = [Block(kind: .notePassage, source: a, markdown: "First body", unknownHeaderFields: []),
                      Block(kind: .notePassage, source: b, markdown: "Second body", unknownHeaderFields: [])]
        let serialized = BlockParser.serialize(leadingText: nil, blocks: blocks)
        let (_, reparsed) = BlockParser.parse(serialized)
        XCTAssertEqual(reparsed.count, 2)
        XCTAssertEqual(reparsed[0].markdown.trimmingCharacters(in: .newlines), "First body")
        XCTAssertEqual(reparsed[1].markdown.trimmingCharacters(in: .newlines), "Second body")
        XCTAssertEqual(reparsed[0].source?.notePassageTarget?.block, 0)
        XCTAssertEqual(reparsed[1].source?.notePassageTarget?.block, 1)
        // Second serialize is idempotent (bodies now carry the separating newline).
        XCTAssertEqual(BlockParser.serialize(leadingText: nil, blocks: reparsed), serialized)
    }

    /// Leading text lacking a trailing newline must not swallow the first block's header either.
    func testSerializeSeparatesNonNewlineTerminatedLeadingText() {
        let a = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 3,
                                         sourceTitle: "A", sourceDateDisplay: "1968")
        let blocks = [Block(kind: .notePassage, source: a, markdown: "Body\n", unknownHeaderFields: [])]
        let serialized = BlockParser.serialize(leadingText: "Intro prose", blocks: blocks)
        let (leading, reparsed) = BlockParser.parse(serialized)
        XCTAssertEqual(leading?.trimmingCharacters(in: .newlines), "Intro prose")
        XCTAssertEqual(reparsed.count, 1)
        XCTAssertEqual(reparsed[0].source?.notePassageTarget?.block, 3)
    }

    // MARK: - CR line terminators (W3.notes-cr-line-start)
    //
    // Swift merges `CR LF` into ONE `"\r\n"` grapheme, so every `Character`-level comparison against
    // `"\n"` in this file was false for CR-terminated text. Four consequences, all covered below: a
    // header after CR or CRLF was not recognized at all; the terminator closing a header line leaked
    // into the block body; CR-separated header fields did not split; and `serialize`'s separator guard
    // appended a second newline. Those tests compare unicode SCALARS now.
    //
    // Reachable by pasting CR-delimited text into the editor — `FrontMatterCodec.decode` normalizes
    // `\r\n` read from disk, but never a lone `\r`.

    func testHeaderAfterLoneCarriageReturnIsRecognized() {
        let (leading, blocks) = BlockParser.parse("Intro prose.\r<!-- block: freeform -->\nBody text.\n")
        XCTAssertEqual(leading, "Intro prose.\r")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .freeform)
        XCTAssertEqual(blocks[0].markdown, "Body text.\n")
    }

    func testHeaderAfterCRLFIsRecognized() {
        let (leading, blocks) = BlockParser.parse("Intro prose.\r\n<!-- block: freeform -->\nBody text.\n")
        XCTAssertEqual(leading, "Intro prose.\r\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].markdown, "Body text.\n")
    }

    /// The terminator closing the header line may be CR or CRLF; exactly one is consumed, and none of
    /// it may survive at the head of the block body.
    func testCarriageReturnAfterHeaderCloseIsConsumed() {
        let (_, crlf) = BlockParser.parse("<!-- block: freeform -->\r\nBody text.\n")
        XCTAssertEqual(crlf.first?.markdown, "Body text.\n")
        let (_, cr) = BlockParser.parse("<!-- block: freeform -->\rBody text.\n")
        XCTAssertEqual(cr.first?.markdown, "Body text.\n")
    }

    /// A multi-line header whose field lines are CR-separated must still split into fields. Without
    /// this the header is recognized (above) but parses WORSE than before the fix: every field after
    /// the first is swallowed into the value of the one before it, so the kind falls back to
    /// `.freeform` and the whole source anchor is lost.
    func testCarriageReturnSeparatedHeaderFieldsParse() {
        let body = "<!-- block: reader-page\r     link: archivereader://x\r     page: 7 -->\rBody.\n"
        let (_, blocks) = BlockParser.parse(body)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .readerPage)
        XCTAssertEqual(blocks[0].source?.link, "archivereader://x")
        XCTAssertEqual(blocks[0].source?.page, 7)
    }

    /// `serialize`'s separator guard must not append a SECOND newline after CRLF-terminated text:
    /// `"…\r\n".hasSuffix("\n")` is FALSE (the last `Character` is the merged grapheme), so the guard
    /// inserted a blank line into the note on the first save after any CRLF paste.
    func testSerializeDoesNotDoubleTerminateCRLFText() {
        let blocks = [Block(kind: .freeform, source: nil, markdown: "Body\n", unknownHeaderFields: [])]
        XCTAssertEqual(BlockParser.serialize(leadingText: "Intro.\r\n", blocks: blocks),
                       "Intro.\r\n<!-- block: freeform -->\nBody\n")
    }

    /// A lone `\r` already ends the line, so nothing is appended — and appending was worse than
    /// useless: the `\n` merged into the preceding `\r` into one grapheme, leaving the header exactly
    /// as unrecognized as before. That merge is why this could not be fixed at `MarkdownBridge`.
    func testSerializeLeavesLoneCarriageReturnAlone() {
        let blocks = [Block(kind: .freeform, source: nil, markdown: "Body\n", unknownHeaderFields: [])]
        let out = BlockParser.serialize(leadingText: "Intro.\r", blocks: blocks)
        XCTAssertEqual(out, "Intro.\r<!-- block: freeform -->\nBody\n")
        let (leading, reparsed) = BlockParser.parse(out)
        XCTAssertEqual(leading, "Intro.\r")
        XCTAssertEqual(reparsed.count, 1)
    }

    /// The end state: a CR-delimited note keeps both blocks' provenance and is a fixed point under
    /// parse → serialize → parse, so an autosaving editor cannot grow or degrade it.
    func testCRDelimitedNoteRoundTripsAsAFixedPoint() {
        let body = "Intro.\r"
            + "<!-- block: reader-page\r     link: archivereader://a\r     page: 1 -->\rFirst body.\r"
            + "<!-- block: reader-doc\r     link: archivereader://b -->\rSecond body.\r"
        let (leading, blocks) = BlockParser.parse(body)
        XCTAssertEqual(leading, "Intro.\r")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .readerPage)
        XCTAssertEqual(blocks[0].source?.page, 1)
        XCTAssertEqual(blocks[1].kind, .readerDoc)
        XCTAssertEqual(blocks[1].source?.link, "archivereader://b")

        let once = BlockParser.serialize(leadingText: leading, blocks: blocks)
        let (leading2, blocks2) = BlockParser.parse(once)
        XCTAssertEqual(blocks2.count, 2)
        XCTAssertEqual(blocks2[0].source?.page, 1)
        XCTAssertEqual(BlockParser.serialize(leadingText: leading2, blocks: blocks2), once,
                       "parse → serialize → parse must be a fixed point for CR-delimited text")
    }
}
