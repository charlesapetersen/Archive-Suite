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

    // MARK: - W3.notes-thumb-line-duplicates — the thumb line has exactly ONE home

    /// A `thumb:` block's `![display](thumb)` line lives in the block BODY, and a save must not add a
    /// second copy. `serializeBlockHeader` used to emit it from `box.thumbRef` while the body already
    /// held the same line — `BlockParser.parseSegment` leaves it there, which is also what renders it
    /// as the inline image the operator sees — so every save wrote it twice and the extra copy came
    /// back as body on the next load: 1 → 2 → 3 → …, one line per autosave, in the operator's own note.
    ///
    /// This replaces `testThumbLineConsumedIntoChip`, which could not fail on any of that: it asserted
    /// the line appears SOMEWHERE in the output, which is true whether it appears once or ten times.
    /// Its name also claimed a consumption into the chip that has never happened — `BlockHeaderChipView`
    /// draws a label and buttons, never the image — which is exactly why the body must keep the line.
    func testThumbLineIsWrittenOnceAndDoesNotGrowAcrossSaves() {
        let md = """
            <!-- block: reader-page
                 link: archivereader://x
                 display: "Doc"
                 thumb: assets/p1.png -->
            ![Doc](assets/p1.png)

            Body text.

            """
        XCTAssertEqual(occurrences(of: "![Doc](assets/p1.png)", in: md), 1,
                       "fixture precondition: the input holds exactly one thumb line")

        let first = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md))
        XCTAssertEqual(occurrences(of: "![Doc](assets/p1.png)", in: first), 1,
                       "The thumb line was emitted twice on the first save:\n\(first)")
        XCTAssertTrue(first.contains("thumb: assets/p1.png"),
                      "The durable thumb REF must stay in the header:\n\(first)")

        let second = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: first))
        XCTAssertEqual(occurrences(of: "![Doc](assets/p1.png)", in: second), 1,
                       "The thumb line grew on the second save:\n\(second)")
        XCTAssertEqual(second, first, "The thumb shape is not a fixed point:\n\(second)")
        XCTAssertEqual(occurrences(of: "Body text.", in: second), 1,
                       "The block body text was duplicated:\n\(second)")
    }

    /// Deleting the thumbnail image in the editor now STICKS. Re-emitting it from `thumbRef` meant the
    /// next save re-created it, so the operator could not remove even a duplicate the app had itself
    /// produced. The `thumb:` ref stays in the header either way — that is the durable provenance, and
    /// deleting a rendered image is not a statement about where the page came from.
    func testDeletingTheThumbImageIsNotUndoneByTheNextSave() {
        let withoutTheImageLine = """
            <!-- block: reader-page
                 link: archivereader://x
                 display: "Doc"
                 thumb: assets/p1.png -->
            Body text.
            """
        let serialized = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: withoutTheImageLine))

        XCTAssertFalse(serialized.contains("![Doc](assets/p1.png)"),
                       "A deleted thumbnail image came back on save:\n\(serialized)")
        XCTAssertTrue(serialized.contains("thumb: assets/p1.png"),
                      "The durable thumb REF must survive the deletion:\n\(serialized)")
    }

    /// The pasted-thumbnail path. `buildInsertableBlock` is now the ONE place that authors the
    /// `![display](thumb)` line, so a block inserted with a `thumbRef` must carry it into the body —
    /// otherwise dropping the serializer's copy would have silently left every pasted thumbnail with no
    /// rendered form at all (the chip never draws the image, and `thumb:` is a header field nothing
    /// renders). What it inserts must already be a fixed point, so the first save→reload does not
    /// reshape the note.
    func testInsertedBlockWithAThumbCarriesItsImageLineIntoTheBody() {
        let chip = MarkdownBridge.buildInsertableBlock(
            kind: .readerPage,
            anchor: SourceAnchor(link: "archivereader://x", display: "Doc p.41", page: 41,
                                 thumbRef: "assets/p41-thumb.png"))
        let serialized = MarkdownBridge.serialize(chip)

        XCTAssertEqual(occurrences(of: "![Doc p.41](assets/p41-thumb.png)", in: serialized), 1,
                       "The inserted block lost or doubled its thumbnail line:\n\(serialized)")
        XCTAssertTrue(serialized.contains("thumb: assets/p41-thumb.png"),
                      "The inserted block lost its thumb ref:\n\(serialized)")

        let reloaded = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: serialized))
        XCTAssertEqual(reloaded, serialized,
                       "What insertion produces is not a fixed point:\n\(reloaded)")

        let parsed = BlockParser.parse(serialized).blocks
        XCTAssertEqual(parsed.count, 1, "Inserted block lost on reload:\n\(serialized)")
        XCTAssertEqual(parsed.first?.source?.thumbRef, "assets/p41-thumb.png")
        XCTAssertEqual(parsed.first?.source?.page, 41)
    }

    /// W3.notes-thumb-line-duplicates-fu1 — the same authoring path, with a bracketed document title.
    /// `Moore [draft]` used to emit `![Moore [draft]](…)`, which the image pattern cannot match, so the
    /// first save→reload turned the thumbnail into escaped prose and orphaned the imported asset while
    /// `thumb:` went on claiming a thumbnail existed. The reference must survive, and what insertion
    /// produces must be a fixed point.
    func testInsertedBlockWithABracketedDisplayKeepsItsThumbnail() {
        let chip = MarkdownBridge.buildInsertableBlock(
            kind: .readerPage,
            anchor: SourceAnchor(link: "archivereader://x", display: "Moore [draft]", page: 41,
                                 thumbRef: "assets/p41-thumb.png"))
        let serialized = MarkdownBridge.serialize(chip)

        XCTAssertEqual(occurrences(of: "![Moore \\[draft\\]](assets/p41-thumb.png)", in: serialized), 1,
                       "The bracketed thumbnail line is missing or doubled:\n\(serialized)")

        let reloaded = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: serialized))
        XCTAssertEqual(reloaded, serialized,
                       "A bracketed display is not a fixed point:\n\(reloaded)")

        // The reference itself — not just the text — has to come back as an image.
        let reparsed = MarkdownBridge.parse(markdown: serialized)
        var relPath: String?
        reparsed.enumerateAttribute(.noteImageRelPath,
                                    in: NSRange(location: 0, length: reparsed.length)) { val, _, _ in
            if let p = val as? String { relPath = p }
        }
        XCTAssertEqual(relPath, "assets/p41-thumb.png",
                       "The thumbnail reloaded as prose, not as an image:\n\(serialized)")
        XCTAssertEqual(BlockParser.parse(serialized).blocks.first?.source?.thumbRef,
                       "assets/p41-thumb.png")
    }

    /// The over-fix guard: a block with NO thumb ref gains nothing from the same code path. Passes
    /// against both versions on purpose — it constrains the fix rather than proving it.
    func testInsertedBlockWithoutAThumbAddsNoImageLine() {
        let chip = MarkdownBridge.buildInsertableBlock(
            kind: .readerPage,
            anchor: SourceAnchor(link: "archivereader://x", display: "Doc", page: 2))
        let serialized = MarkdownBridge.serialize(chip)

        XCTAssertFalse(serialized.contains("!["),
                       "A thumb-less block invented an image line:\n\(serialized)")
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
    /// The `thumb:` shape was excluded here until `W3.notes-thumb-line-duplicates` was fixed: the
    /// serializer re-emitted the thumb line the body already carried, so that one shape grew a
    /// duplicate `![…](…)` on every pass. It is in the table now, and that is this table's job — the
    /// growth was invisible to every other assertion in the class, all of which use `contains`.
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
            // W3.notes-editor-blankline-collapse — a block BODY is ordinary prose, so it can hold
            // more than one paragraph. Before the fix the two paragraphs came back glued
            // ("…one.Body two."), which this table could not see: it compared block kinds and
            // provenance, and one glued block still has both.
            ("multi-paragraph block body", """
                <!-- block: freeform -->
                Body one.

                Body two.
                """),
            // W3.notes-thumb-line-duplicates — the shape this table used to exclude. The body opens
            // with the block's own `![display](thumb)` line, which the serializer also emitted from
            // `thumbRef`: two copies on the first pass, three on the second, unbounded.
            ("thumb block, image line in the body", """
                <!-- block: reader-page
                     link: archivereader://reveal?root=ABC&rel=doc.pdf&page=1
                     display: "Doc p.1"
                     page: 1
                     thumb: assets/p1.png -->
                ![Doc p.1](assets/p1.png)

                Annotation.
                """),
            // …and the same block with nothing but the thumb line, which is what a freshly pasted
            // Reader link becomes once it has been saved.
            ("thumb block, no other body", """
                <!-- block: reader-page
                     link: archivereader://reveal?root=ABC&rel=doc.pdf&page=2
                     display: "Doc p.2"
                     page: 2
                     thumb: assets/p2.png -->
                ![Doc p.2](assets/p2.png)
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

        // W3.notes-header-field-terminator — these values begin as in-memory metadata, not as an
        // already-damaged header string. Before the fix, every first serialization below either
        // truncated provenance, injected a field/block, leaked into the body, or failed to settle.
        let dangerousCases: [(name: String, block: Block, expected: Block)] = [
            unsafeHeaderCase(
                name: "link tail after LF",
                source: SourceAnchor(link: "archivereader://reveal?root=G&rel=a.pdf&x=\njunk"),
                expectedSource: SourceAnchor(link: "archivereader://reveal?root=G&rel=a.pdf&x= junk")
            ),
            unsafeHeaderCase(
                name: "link cannot inject note field",
                source: SourceAnchor(link: "archivereader://reveal?root=G&rel=a.pdf&x=\nnote: smuggled"),
                expectedSource: SourceAnchor(link: "archivereader://reveal?root=G&rel=a.pdf&x= note: smuggled")
            ),
            unsafeHeaderCase(
                name: "unquoted fields canonicalize boundary terminators immediately",
                source: SourceAnchor(link: "\rarchivereader://x\r\n"),
                unknown: [("future", "\nvalue\r")],
                expectedSource: SourceAnchor(link: "archivereader://x"),
                expectedUnknown: [("future", "value")]
            ),
            unsafeHeaderCase(
                name: "display CRLF stays one field",
                source: SourceAnchor(display: "Line1\r\nLine2"),
                expectedSource: SourceAnchor(display: "Line1 Line2")
            ),
            unsafeHeaderCase(
                name: "display cannot close comment",
                source: SourceAnchor(display: "A-->LEAK"),
                expectedSource: SourceAnchor(display: "A-- >LEAK")
            ),
            unsafeHeaderCase(
                name: "display cannot mint a second block",
                source: SourceAnchor(display: "Before\n<!-- block: freeform -->\nAfter"),
                unknown: [("future", "Line1\nnote: injected-->tail")],
                expectedSource: SourceAnchor(display: "Before <!-- block: freeform -- > After"),
                expectedUnknown: [("future", "Line1 note: injected-- >tail")]
            ),
            unsafeHeaderCase(
                name: "quoted display escapes symmetrically",
                source: SourceAnchor(display: "A \\\"quoted\\\" \\\\ path"),
                expectedSource: SourceAnchor(display: "A \\\"quoted\\\" \\\\ path")
            ),
        ]

        for (name, block, expected) in dangerousCases {
            let first = BlockParser.serialize(leadingText: nil, blocks: [block])
            let parsed = BlockParser.parse(first)

            XCTAssertEqual(parsed.blocks.count, 1,
                           "\(name): a field split or destroyed the block:\n\(first)")
            XCTAssertEqual(parsed.blocks.first, expected,
                           "\(name): provenance/body did not survive the first serialization:\n\(first)")

            let second = BlockParser.serialize(leadingText: parsed.leadingText, blocks: parsed.blocks)
            XCTAssertEqual(second, first, "\(name): storage serialization is not a fixed point")
            // The editor's established canonical form drops a final body newline. Its own SECOND pass
            // must be stable, and the safe source/body structure must survive that canonicalization.
            let editorFirst = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: first))
            let editorBlocks = BlockParser.parse(editorFirst).blocks
            XCTAssertEqual(editorBlocks.count, 1, "\(name): editor pass split the safe block")
            XCTAssertEqual(editorBlocks.first?.source, expected.source,
                           "\(name): editor pass changed the safe provenance")
            let editorSecond = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: editorFirst))
            XCTAssertEqual(editorSecond, editorFirst, "\(name): editor round-trip is not a fixed point")
        }
    }

    /// `display` is the one source value written into TWO grammars when a pasted block owns a thumb:
    /// the header and the body's Markdown image alt. Sanitizing only `serializeHeader` leaves that body
    /// line split, so this goes through the real insertion seam and requires both spellings to agree.
    func testInsertedThumbSanitizesDisplayInHeaderAndBodyTogether() {
        let expectedDisplay = "Line1 Line2 -- > \\\"quoted\\\" \\\\ path"
        let inserted = MarkdownBridge.buildInsertableBlock(
            kind: .readerPage,
            anchor: SourceAnchor(
                link: "archivereader://x",
                display: "Line1\r\nLine2 --> \\\"quoted\\\" \\\\ path",
                page: 3,
                thumbRef: "assets/p3.png"
            )
        )
        let serialized = MarkdownBridge.serialize(inserted)
        let parsed = BlockParser.parse(serialized)

        XCTAssertEqual(parsed.blocks.count, 1, "The display split its own block:\n\(serialized)")
        XCTAssertEqual(parsed.blocks.first?.source?.display, expectedDisplay)
        XCTAssertEqual(parsed.blocks.first?.markdown,
                       InlineImageMarkdown.emit(alt: expectedDisplay, path: "assets/p3.png"))

        let second = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: serialized))
        XCTAssertEqual(second, serialized, "The inserted thumb block is not a fixed point")
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

    /// How many times `needle` appears in `haystack`. Counting is the point for
    /// `W3.notes-thumb-line-duplicates`: `contains` is blind to a line written twice, which is how a
    /// defect that doubled a note's thumbnail on every save survived a suite that round-trips blocks
    /// constantly.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func unsafeHeaderCase(
        name: String,
        source: SourceAnchor,
        unknown: [(String, String)] = [],
        expectedSource: SourceAnchor,
        expectedUnknown: [(String, String)] = []
    ) -> (name: String, block: Block, expected: Block) {
        let body = "Operator body.\n"
        return (
            name,
            Block(kind: .readerPage, source: source, markdown: body, unknownHeaderFields: unknown),
            Block(kind: .readerPage, source: expectedSource, markdown: body,
                  unknownHeaderFields: expectedUnknown)
        )
    }

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
