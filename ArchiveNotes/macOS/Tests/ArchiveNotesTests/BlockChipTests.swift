import XCTest
@testable import ArchiveNotes

/// Tests for block-header chip parse → serialize round-trip via `MarkdownBridge`.
/// Exercises the editor-layer block model (chips as NSTextAttachments with `noteBlockSource`
/// attribute), NOT the storage-layer `BlockParser` (tested in `BlockParserTests`).
@MainActor
final class BlockChipTests: XCTestCase {

    // MARK: - Multi-block body

    func testMultiBlockBodyRoundTrip() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://reveal?root=ABC&rel=doc.pdf&page=1
                 display: "Doc p.1"
                 page: 1 -->
            Some annotation text.

            <!-- block: freeform -->
            My freeform notes.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        // Verify the serialized output contains both block headers
        XCTAssertTrue(serialized.contains("<!-- block: reader-page"), "Missing reader-page header")
        XCTAssertTrue(serialized.contains("<!-- block: freeform"), "Missing freeform header")
        XCTAssertTrue(serialized.contains("link: archivereader://reveal?root=ABC&rel=doc.pdf&page=1"),
                       "Missing link field")
        XCTAssertTrue(serialized.contains("display: \"Doc p.1\""), "Missing display field")
        XCTAssertTrue(serialized.contains("page: 1"), "Missing page field")
    }

    // MARK: - Reader-page with all fields

    func testReaderPageWithAllFields() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://reveal?root=X&rel=y.pdf&page=3
                 display: "My Doc - p. 3"
                 page: 3
                 thumb: assets/p3.png -->
            ![My Doc - p. 3](assets/p3.png)

            Content here.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        XCTAssertTrue(serialized.contains("<!-- block: reader-page"))
        XCTAssertTrue(serialized.contains("display: \"My Doc - p. 3\""))
        XCTAssertTrue(serialized.contains("thumb: assets/p3.png"))
        XCTAssertTrue(serialized.contains("![My Doc - p. 3](assets/p3.png)"))
    }

    // MARK: - Zotero block

    func testZoteroBlock() {
        let md = """
            <!-- block: zotero-item
                 zotero: zotero://select/items/ABC123
                 display: "Smith 2020" -->
            Citation note.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        XCTAssertTrue(serialized.contains("<!-- block: zotero-item"))
        XCTAssertTrue(serialized.contains("zotero: zotero://select/items/ABC123"))
        XCTAssertTrue(serialized.contains("display: \"Smith 2020\""))
    }

    // MARK: - Unknown header fields preserved

    func testUnknownFieldsPreservedVerbatim() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://x
                 future_key: some_value
                 another_key: 42 -->
            Content.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        XCTAssertTrue(serialized.contains("future_key: some_value"),
                       "Unknown field future_key should be preserved")
        XCTAssertTrue(serialized.contains("another_key: 42"),
                       "Unknown field another_key should be preserved")
    }

    // MARK: - Absent header → freeform (no chip)

    func testAbsentHeaderBecomesFreeform() {
        let md = "Just plain text with **bold** and *italic*."
        let parsed = MarkdownBridge.parse(markdown: md)

        // No chip attachment should be present
        var foundChip = false
        parsed.enumerateAttribute(.noteBlockSource,
                                   in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if val != nil { foundChip = true }
        }
        XCTAssertFalse(foundChip, "Plain text should not produce any block-header chips")

        let serialized = MarkdownBridge.serialize(parsed)
        XCTAssertFalse(serialized.contains("<!-- block:"), "No block header in output")
    }

    // MARK: - Malformed header tolerated

    func testMalformedHeaderTolerated() {
        // Missing close --> in this inline use — BlockParser will try its best
        let md = "<!-- block: reader-page\n     link: archivereader://x -->\nSome text.\n"
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        // Should not crash; should contain something recognizable
        XCTAssertTrue(serialized.contains("reader-page") || serialized.contains("Some text"),
                       "Malformed header should degrade gracefully")
    }

    // MARK: - Chip as first character

    func testChipFirstChar() {
        let md = "<!-- block: freeform -->\nBody text.\n"
        let parsed = MarkdownBridge.parse(markdown: md)

        // The first character should be the chip attachment
        let firstAttr = parsed.attribute(.noteBlockSource, at: 0, effectiveRange: nil)
        XCTAssertNotNil(firstAttr, "First character should be a block-header chip")
    }

    // MARK: - Consecutive chips

    func testConsecutiveChips() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://a
                 display: "A" -->
            <!-- block: reader-page
                 link: archivereader://b
                 display: "B" -->
            Content after B.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        // Both chips should be present
        let displayA = serialized.range(of: "display: \"A\"")
        let displayB = serialized.range(of: "display: \"B\"")
        XCTAssertNotNil(displayA, "Chip A should be in serialized output")
        XCTAssertNotNil(displayB, "Chip B should be in serialized output")
    }

    // MARK: - Chip idempotency (second round-trip is no-op)

    func testSecondRoundTripIsNoOp() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://x
                 display: "Doc p.1"
                 page: 1 -->
            Some text with **bold**.

            """
        let parsed1 = MarkdownBridge.parse(markdown: md)
        let serialized1 = MarkdownBridge.serialize(parsed1)

        let parsed2 = MarkdownBridge.parse(markdown: serialized1)
        let serialized2 = MarkdownBridge.serialize(parsed2)

        XCTAssertEqual(serialized1, serialized2,
                       "Second round-trip should produce identical output")
    }

    // MARK: - Thumb line consumed into chip

    func testThumbLineConsumedIntoChip() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://x
                 display: "Doc"
                 thumb: assets/p1.png -->
            ![Doc](assets/p1.png)

            Body text.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        // The thumb line should be in the serialized output (emitted by chip serialization)
        XCTAssertTrue(serialized.contains("![Doc](assets/p1.png)"),
                       "Thumb line should be preserved in serialized output")
        XCTAssertTrue(serialized.contains("thumb: assets/p1.png"),
                       "Thumb ref should be in the header")
    }

    // MARK: - Insert block seam

    func testInsertBlockSeam() {
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=TEST&rel=test.pdf&page=5",
            display: "Test Doc - p. 5",
            page: 5
        )
        let chipStr = MarkdownBridge.buildInsertableBlock(
            kind: .readerPage, anchor: anchor
        )

        // Should have a chip attachment character
        XCTAssertGreaterThan(chipStr.length, 0)
        let box = chipStr.attribute(.noteBlockSource, at: 0,
                                     effectiveRange: nil) as? SourceAnchorBox
        XCTAssertNotNil(box, "Inserted block should carry noteBlockSource attribute")
        XCTAssertEqual(box?.anchor.display, "Test Doc - p. 5")
        XCTAssertEqual(box?.kind, .readerPage)
    }

    // MARK: - Leading text before blocks preserved

    func testLeadingTextPreserved() {
        let md = "Introduction paragraph.\n\n<!-- block: freeform -->\nBlock content.\n"
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        // The leading text should survive
        XCTAssertTrue(serialized.contains("Introduction paragraph"),
                       "Leading text should be preserved")
        XCTAssertTrue(serialized.contains("<!-- block: freeform"),
                       "Block header should be preserved")
    }

    // MARK: - Note-passage block

    func testNotePassageBlock() {
        let md = """
            <!-- block: note-passage
                 note: archivenotes://open?id=abc123#block-2
                 display: "Source Note" -->
            Quoted passage.

            """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)

        XCTAssertTrue(serialized.contains("<!-- block: note-passage"))
        XCTAssertTrue(serialized.contains("note: archivenotes://open?id=abc123#block-2"))
    }

    // MARK: - W3.notes-chip-header-needs-a-line-break — headers must begin a line

    /// A header the serializer emits must start on its OWN LINE, because `BlockParser.parse` only
    /// recognises `<!-- block:` at a line start (`BlockParser.swift:56-58`). A body segment that does
    /// not end in a newline — which is EVERY body, since `serializeBodySegment` joins paragraphs with
    /// `\n` and never appends a trailing one — would otherwise butt straight up against the next
    /// header, so on reload the two blocks merge into one and the second chip degrades to literal
    /// text: the passage loses its provenance anchor. `BlockParser.serialize` guards exactly this
    /// (`:90-101`); this asserts the editor side of the same rule.
    ///
    /// Every other multi-block test here asserts with `contains`, which is blind to where the header
    /// sits on the line — which is why the defect survived a suite that round-trips blocks constantly.
    func testEmittedHeaderAfterABodyStartsOnItsOwnLine() {
        let md = """
            <!-- block: note-passage
                 note: archivenotes://open?id=abc123#block-0
                 display: "Src" -->
            …an early egalitarian culture.
            <!-- block: freeform -->
            My own commentary.
            """
        let serialized = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md))

        XCTAssertTrue(headersAllStartALine(serialized),
                      "A header is glued to the end of a body line:\n\(serialized)")
        XCTAssertEqual(BlockParser.parse(serialized).blocks.count, 2,
                       "Reload merged the two blocks into one:\n\(serialized)")
    }

    /// The same rule for the FIRST header, when the note opens with leading prose that has no
    /// trailing newline (`BlockParser.serialize:92` guards this case separately).
    func testEmittedHeaderAfterLeadingProseStartsOnItsOwnLine() {
        let md = "Intro prose.\n<!-- block: freeform -->\nBlock body."
        let serialized = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md))

        XCTAssertTrue(headersAllStartALine(serialized),
                      "Header glued to the leading prose:\n\(serialized)")
        let reparsed = BlockParser.parse(serialized)
        XCTAssertEqual(reparsed.blocks.count, 1, "Block lost on reload:\n\(serialized)")
        XCTAssertEqual(reparsed.leadingText?.contains("Intro prose"), true,
                       "Leading prose lost on reload:\n\(serialized)")
    }

    /// parse→serialize→parse must preserve the BLOCK STRUCTURE — count, kind and provenance anchor —
    /// and be a fixed point after one pass. This class had no idempotence test at all before
    /// `W3.notes-chip-header-needs-a-line-break`, which is why two defects in it were found by
    /// accident rather than by the suite.
    ///
    /// The `thumb:` shape is deliberately absent: `serializeBlockHeader` re-emits the thumb line that
    /// is ALSO still in the block body, so that shape grows a duplicate `![…](…)` on every pass. That
    /// is a separate pre-existing defect (`W3.notes-thumb-line-duplicates`), not this one.
    func testParseSerializeParsePreservesBlockStructureAndIsAFixedPoint() {
        let cases: [(name: String, md: String)] = [
            ("body without a trailing newline", """
                <!-- block: note-passage
                     note: archivenotes://open?id=abc123#block-0
                     display: "Src" -->
                Passage text with no trailing newline.
                <!-- block: freeform -->
                Commentary.
                """),
            ("bodies with blank-line separators", """
                <!-- block: reader-page
                     link: archivereader://reveal?root=ABC&rel=doc.pdf&page=1
                     display: "Doc p.1"
                     page: 1 -->
                Annotation.

                <!-- block: freeform -->
                Notes.

                """),
            ("leading prose then a block", "Intro prose.\n\n<!-- block: freeform -->\nBody.\n"),
            ("consecutive headers, empty first body", """
                <!-- block: reader-page
                     link: archivereader://a
                     display: "A" -->
                <!-- block: reader-page
                     link: archivereader://b
                     display: "B" -->
                Content after B.
                """),
            ("three blocks, formatted bodies", """
                <!-- block: note-passage
                     note: archivenotes://open?id=abc#block-1 -->
                Text with **bold** and *italic*.
                <!-- block: zotero-item
                     zotero: zotero://select/items/ABC123
                     display: "Smith 2020" -->
                > A quoted line
                <!-- block: freeform -->
                Last.
                """),
        ]

        for (name, md) in cases {
            let want = BlockParser.parse(md).blocks
            let serialized = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md))
            let got = BlockParser.parse(serialized).blocks

            XCTAssertTrue(headersAllStartALine(serialized),
                          "\(name): a header does not begin a line:\n\(serialized)")
            XCTAssertEqual(got.count, want.count,
                           "\(name): block count changed on round-trip:\n\(serialized)")
            for (i, pair) in zip(got, want).enumerated() {
                XCTAssertEqual(pair.0.kind, pair.1.kind, "\(name): block \(i) kind changed")
                XCTAssertEqual(pair.0.source, pair.1.source, "\(name): block \(i) provenance changed")
            }

            let second = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: serialized))
            XCTAssertEqual(second, serialized, "\(name): second round-trip is not a fixed point")
        }
    }

    /// A chip inserted MID-LINE — `buildInsertableBlock` drops one wherever the caret happens to sit
    /// (`MarkdownEditorView.insertBlock`) — still serializes to a header on its own line, so the block
    /// survives the reload. The visible consequence is deliberate: `parse` inserts a newline AFTER a
    /// chip but never before one, so `Foo[chip] bar` reflows to `Foo[chip]⏎bar` on the next load. That
    /// is what the on-disk format requires, and strictly better than the pre-fix behaviour, which
    /// destroyed the chip outright.
    func testChipInsertedMidLineStillSerializesOntoItsOwnLine() {
        let body = NSMutableAttributedString(attributedString: MarkdownBridge.parse(markdown: "Foo bar"))
        let chip = MarkdownBridge.buildInsertableBlock(
            kind: .readerPage,
            anchor: SourceAnchor(link: "archivereader://x", display: "Doc", page: 1))
        body.insert(chip, at: 4)   // "Foo |bar" — mid-line, not at a paragraph boundary

        let serialized = MarkdownBridge.serialize(body)

        XCTAssertTrue(headersAllStartALine(serialized),
                      "Mid-line chip emitted a glued header:\n\(serialized)")
        let reparsed = BlockParser.parse(serialized)
        XCTAssertEqual(reparsed.blocks.count, 1, "Block lost on reload:\n\(serialized)")
        XCTAssertEqual(reparsed.blocks.first?.kind, .readerPage)
        XCTAssertEqual(reparsed.blocks.first?.source?.link, "archivereader://x")
        XCTAssertEqual(reparsed.leadingText?.contains("Foo"), true,
                       "Text before the chip lost:\n\(serialized)")
        XCTAssertEqual(reparsed.blocks.first?.markdown.contains("bar"), true,
                       "Text after the chip lost:\n\(serialized)")
    }

    // MARK: - Helpers

    /// True when every `<!-- block:` in `md` begins a line — the precondition `BlockParser.parse`
    /// applies before it will treat one as a header at all.
    private func headersAllStartALine(_ md: String) -> Bool {
        var search = md.startIndex
        while search < md.endIndex,
              let r = md.range(of: "<!-- block:", range: search..<md.endIndex) {
            if r.lowerBound != md.startIndex, md[md.index(before: r.lowerBound)] != "\n" {
                return false
            }
            search = r.upperBound
        }
        return true
    }
}
