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
}
