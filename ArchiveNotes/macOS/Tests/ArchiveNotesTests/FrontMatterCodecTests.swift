import XCTest
@testable import ArchiveNotes

final class FrontMatterCodecTests: XCTestCase {

    // MARK: - Fixtures

    /// The canonical §5 example (note with zotero + two blocks).
    private let canonicalFixture = """
        ---
        schema: 1
        id: 7f3a9c21-4b2e-4d1a-9c33-8e5f0a1b2c3d
        kind: note
        title: Moore on Intel culture
        authors: [Gordon E. Moore]
        date: 1968
        date_precision: year
        date_uncertain: false
        quality: 4
        tags: [Silicon Valley, Intel, Corporate Culture]
        roundup: false
        zotero:
          - selectLink: zotero://select/library/items/ABCD1234
            itemKey: ABCD1234
            library: library
            kind: item
            citation: "Moore, Gordon E. Oral History. Chemical Heritage Foundation, 2001."
        created: 2026-07-10T21:00:00Z
        modified: 2026-07-10T21:05:00Z
        ---
        <!-- block: reader-page
             link: archivereader://reveal?root=7F3A&rel=SV/Business/Moore.pdf&page=41
             display: "Gordon E. Moore Oral History - p. 41"
             thumb: assets/p41-thumb.png -->
        ![Gordon E. Moore Oral History - p. 41](assets/p41-thumb.png)

        Moore says he and Noyce were **responsible** for Intel's early egalitarian culture...

        <!-- block: freeform -->
        My own gloss: this cuts against the "Noyce as sole culture-setter" story...

        """

    /// Minimal valid note — only required fields.
    private let minimalFixture = """
        ---
        schema: 1
        id: 00000000-0000-0000-0000-000000000001
        kind: note
        title: Untitled
        roundup: false
        created: 2026-01-01T00:00:00Z
        modified: 2026-01-01T00:00:00Z
        ---

        """

    // MARK: - Decode

    func testDecodeCanonical() throws {
        let item = try FrontMatterCodec.decode(canonicalFixture)

        XCTAssertEqual(item.id, UUID(uuidString: "7f3a9c21-4b2e-4d1a-9c33-8e5f0a1b2c3d"))
        XCTAssertEqual(item.kind, .note)
        XCTAssertEqual(item.title, "Moore on Intel culture")
        XCTAssertEqual(item.authors, ["Gordon E. Moore"])
        XCTAssertEqual(item.date, "1968")
        XCTAssertEqual(item.datePrecision, .year)
        XCTAssertEqual(item.dateUncertain, false)
        XCTAssertEqual(item.quality, 4)
        XCTAssertEqual(item.tags, ["Silicon Valley", "Intel", "Corporate Culture"])
        XCTAssertEqual(item.roundup, false)
        XCTAssertEqual(item.schema, 1)

        XCTAssertEqual(item.zotero.count, 1)
        let z = item.zotero[0]
        XCTAssertEqual(z.selectLink, "zotero://select/library/items/ABCD1234")
        XCTAssertEqual(z.itemKey, "ABCD1234")
        XCTAssertEqual(z.library, .user)
        XCTAssertEqual(z.kind, .item)
        XCTAssertEqual(z.citation, "Moore, Gordon E. Oral History. Chemical Heritage Foundation, 2001.")

        XCTAssertEqual(item.blocks.count, 2)
        XCTAssertEqual(item.blocks[0].kind, .readerPage)
        XCTAssertEqual(item.blocks[0].source?.link,
                       "archivereader://reveal?root=7F3A&rel=SV/Business/Moore.pdf&page=41")
        XCTAssertEqual(item.blocks[0].source?.display, "Gordon E. Moore Oral History - p. 41")
        XCTAssertEqual(item.blocks[0].source?.thumbRef, "assets/p41-thumb.png")
        XCTAssertEqual(item.blocks[1].kind, .freeform)
        XCTAssertNil(item.blocks[1].source)
    }

    func testDecodeMinimal() throws {
        let item = try FrontMatterCodec.decode(minimalFixture)

        XCTAssertEqual(item.id, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(item.kind, .note)
        XCTAssertEqual(item.title, "Untitled")
        XCTAssertTrue(item.authors.isEmpty)
        XCTAssertNil(item.date)
        XCTAssertNil(item.datePrecision)
        XCTAssertNil(item.quality)
        XCTAssertTrue(item.tags.isEmpty)
        XCTAssertTrue(item.zotero.isEmpty)
        XCTAssertTrue(item.blocks.isEmpty)
    }

    func testDecodeMissingIdThrows() {
        let text = """
            ---
            schema: 1
            kind: note
            title: No ID
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        XCTAssertThrowsError(try FrontMatterCodec.decode(text))
    }

    func testDecodeNoFrontMatterThrows() {
        XCTAssertThrowsError(try FrontMatterCodec.decode("Just some text"))
    }

    func testDecodeMissingKindDefaultsNote() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000002
            title: No Kind
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.kind, .note)
    }

    func testDecodeExtract() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000003
            kind: extract
            title: An Extract
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.kind, .extract)
    }

    // MARK: - Unknown key preservation

    func testUnknownKeysPreserved() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000004
            kind: note
            title: With Unknown
            future_field: some value
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.unknownFrontMatter.count, 1)
        XCTAssertEqual(item.unknownFrontMatter[0].key, "future_field")
        XCTAssertEqual(item.unknownFrontMatter[0].rawLines, ["future_field: some value"])
    }

    func testUnknownKeyWithNestedLinesPreserved() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000005
            kind: note
            title: Nested Unknown
            sources:
              - link: something
                display: "A Source"
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.unknownFrontMatter.count, 1)
        XCTAssertEqual(item.unknownFrontMatter[0].key, "sources")
        XCTAssertEqual(item.unknownFrontMatter[0].rawLines.count, 3)

        let encoded = FrontMatterCodec.encode(item)
        XCTAssertTrue(encoded.contains("sources:"))
        XCTAssertTrue(encoded.contains("  - link: something"))
    }

    // MARK: - Round-trip (model level): decode(encode(x)) == x

    func testRoundTripModel() throws {
        let ref = Date(timeIntervalSinceReferenceDate: 804_070_200) // fixed date
        let item = Item(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            kind: .note,
            title: "Round-trip test: with colon",
            authors: ["Alice", "Bob"],
            date: "1968-03",
            datePrecision: .month,
            dateUncertain: true,
            quality: 3,
            tags: ["History", "Silicon Valley"],
            zotero: [ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                               itemKey: "ABCD1234", library: .user, citation: "Cite A")],
            roundup: false,
            created: ref,
            modified: ref,
            schema: 1,
            blocks: [
                Block(kind: .readerPage, source: SourceAnchor(link: "archivereader://x", display: "Doc p.1", page: 1),
                      markdown: "Some text\n\n", unknownHeaderFields: []),
                Block(kind: .freeform, source: nil, markdown: "Free text\n", unknownHeaderFields: []),
            ],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )

        let encoded = FrontMatterCodec.encode(item)
        let decoded = try FrontMatterCodec.decode(encoded)

        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.kind, item.kind)
        XCTAssertEqual(decoded.title, item.title)
        XCTAssertEqual(decoded.authors, item.authors)
        XCTAssertEqual(decoded.date, item.date)
        XCTAssertEqual(decoded.datePrecision, item.datePrecision)
        XCTAssertEqual(decoded.dateUncertain, item.dateUncertain)
        XCTAssertEqual(decoded.quality, item.quality)
        XCTAssertEqual(decoded.tags, item.tags)
        XCTAssertEqual(decoded.roundup, item.roundup)
        XCTAssertEqual(decoded.schema, item.schema)
        XCTAssertEqual(decoded.zotero.count, 1)
        XCTAssertEqual(decoded.zotero[0].selectLink, item.zotero[0].selectLink)
        XCTAssertEqual(decoded.zotero[0].citation, item.zotero[0].citation)
        XCTAssertEqual(decoded.blocks.count, 2)
        XCTAssertEqual(decoded.blocks[0].kind, .readerPage)
        XCTAssertEqual(decoded.blocks[0].source?.page, 1)
        XCTAssertEqual(decoded.blocks[1].kind, .freeform)
    }

    // MARK: - Byte-stable round-trip: encode(decode(text)) == text

    func testByteStableMinimal() throws {
        let item = try FrontMatterCodec.decode(minimalFixture)
        let reencoded = FrontMatterCodec.encode(item)
        XCTAssertEqual(reencoded, minimalFixture)
    }

    // MARK: - List parsing (flow + block style)

    func testBlockStyleList() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000006
            kind: note
            title: Block List
            tags:
              - Alpha
              - Beta
              - Gamma
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.tags, ["Alpha", "Beta", "Gamma"])
    }

    func testQuotedFlowElements() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000007
            kind: note
            title: Quoted Flow
            tags: ["A, B", C]
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.tags, ["A, B", "C"])
    }

    // MARK: - CRLF tolerance

    func testCRLFNormalized() throws {
        let text = "---\r\nschema: 1\r\nid: 00000000-0000-0000-0000-000000000008\r\nkind: note\r\ntitle: CRLF\r\nroundup: false\r\ncreated: 2026-01-01T00:00:00Z\r\nmodified: 2026-01-01T00:00:00Z\r\n---\r\n\r\n"
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.title, "CRLF")
    }

    // MARK: - Scalar quoting edge cases

    func testTitleWithColonQuoted() throws {
        let item = try FrontMatterCodec.decode(minimalFixture)
        var modified = item
        modified.title = "Part 1: The Beginning"
        let encoded = FrontMatterCodec.encode(modified)
        XCTAssertTrue(encoded.contains("title: \"Part 1: The Beginning\""))

        let roundTripped = try FrontMatterCodec.decode(encoded)
        XCTAssertEqual(roundTripped.title, "Part 1: The Beginning")
    }

    func testEmptyTitleQuoted() throws {
        let item = try FrontMatterCodec.decode(minimalFixture)
        var modified = item
        modified.title = ""
        let encoded = FrontMatterCodec.encode(modified)
        XCTAssertTrue(encoded.contains("title: \"\""))
    }

    // MARK: - Zotero with unknown sub-keys

    func testZoteroUnknownSubKeysPreserved() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000009
            kind: note
            title: Zotero Unknown
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: library
                kind: item
                future_zotero_key: surprise
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.zotero.count, 1)
        XCTAssertEqual(item.zotero[0].unknown.count, 1)
        XCTAssertEqual(item.zotero[0].unknown[0].key, "future_zotero_key")
    }

    // MARK: - Leading body text (trailingBodyRaw)

    func testLeadingBodyTextPreserved() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-00000000000a
            kind: note
            title: Leading Text
            roundup: false
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---
            Some intro text here.

            <!-- block: freeform -->
            Block content.

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.trailingBodyRaw, "Some intro text here.\n\n")
        XCTAssertEqual(item.blocks.count, 1)
        XCTAssertEqual(item.blocks[0].kind, .freeform)

        let reencoded = FrontMatterCodec.encode(item)
        XCTAssertEqual(reencoded, text)
    }

    /// W3.notes-frontmatter-codec-bypasses-the-leading-text-guard. `encode` used to append
    /// `trailingBodyRaw` itself and then call `BlockParser.serialize(leadingText: nil, …)`, so the
    /// guard that inserts the separating newline before a header (`BlockParser.swift:92`) never ran on
    /// the only path that reaches disk. A leading body with NO trailing newline therefore butted
    /// straight up against `<!-- block:`, which `BlockParser.parse` only recognizes at a line start —
    /// so on reload the header was plain prose and the block (with its provenance) was gone.
    /// Every producer of `trailingBodyRaw` in the app today is `BlockParser.parse`, whose leading text
    /// always ends in `\n`, so this was latent; a template/importer/migration setting it directly is
    /// all it would have taken. This test writes that value directly, which is the point.
    func testLeadingBodyWithoutTrailingNewlineKeepsItsFirstBlockOnReload() throws {
        let ref = Date(timeIntervalSinceReferenceDate: 804_070_200)
        let item = Item(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!,
            kind: .note, title: "No trailing newline", authors: [],
            date: nil, datePrecision: nil, dateUncertain: false, quality: nil,
            tags: [], zotero: [], roundup: false, created: ref, modified: ref, schema: 1,
            blocks: [
                Block(kind: .readerPage,
                      source: SourceAnchor(link: "archivereader://open?doc=abc", display: "Doc p.7", page: 7),
                      markdown: "Quoted passage.\n", unknownHeaderFields: []),
            ],
            unknownFrontMatter: [],
            trailingBodyRaw: "Intro prose with no trailing newline."
        )

        let encoded = FrontMatterCodec.encode(item)
        // The corruption shape: prose and header fused into one line.
        XCTAssertFalse(encoded.contains("newline.<!-- block:"),
                       "leading prose must not butt up against the block header")
        XCTAssertTrue(encoded.contains("\n<!-- block: reader-page"),
                      "the header must begin its own line")

        let decoded = try FrontMatterCodec.decode(encoded)
        // `first`, not `[0]`: on the pre-fix code `blocks` is EMPTY, and subscripting it would trap and
        // take the whole app-hosted bundle down with it instead of reporting one red test.
        XCTAssertEqual(decoded.blocks.count, 1, "the block must survive the reload")
        XCTAssertEqual(decoded.blocks.first?.kind, .readerPage)
        XCTAssertEqual(decoded.blocks.first?.source?.page, 7)
        XCTAssertEqual(decoded.blocks.first?.source?.link, "archivereader://open?doc=abc")
        // The separating newline is the only difference the fix introduces.
        XCTAssertEqual(decoded.trailingBodyRaw, "Intro prose with no trailing newline.\n")
    }

    /// The other half of the fix: with NO blocks there is no header to separate, so the newline must
    /// NOT be added — a body that is pure prose still round-trips byte-for-byte.
    func testLeadingBodyWithoutTrailingNewlineAndNoBlocksIsNotPadded() throws {
        let ref = Date(timeIntervalSinceReferenceDate: 804_070_200)
        let item = Item(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!,
            kind: .note, title: "Prose only", authors: [],
            date: nil, datePrecision: nil, dateUncertain: false, quality: nil,
            tags: [], zotero: [], roundup: false, created: ref, modified: ref, schema: 1,
            blocks: [], unknownFrontMatter: [],
            trailingBodyRaw: "Prose with no trailing newline."
        )

        let encoded = FrontMatterCodec.encode(item)
        XCTAssertTrue(encoded.hasSuffix("---\nProse with no trailing newline."),
                      "no spurious trailing newline; got: \(String(encoded.suffix(60)).debugDescription)")

        let decoded = try FrontMatterCodec.decode(encoded)
        XCTAssertEqual(decoded.trailingBodyRaw, "Prose with no trailing newline.")
        XCTAssertEqual(FrontMatterCodec.encode(decoded), encoded)
    }

    // MARK: - Zotero fetchedAt date

    func testZoteroFetchedAt() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-00000000000b
            kind: note
            title: Fetched
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: library
                kind: attachment
                fetchedAt: 2026-07-10T21:00:00Z
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertNotNil(item.zotero[0].fetchedAt)
        XCTAssertEqual(item.zotero[0].kind, .attachment)
    }

    // MARK: - Quality omitted when nil

    func testQualityOmittedWhenNil() {
        let text = minimalFixture
        XCTAssertFalse(text.contains("quality"))
        let item = try! FrontMatterCodec.decode(text)
        XCTAssertNil(item.quality)
        let encoded = FrontMatterCodec.encode(item)
        XCTAssertFalse(encoded.contains("quality"))
    }

    // MARK: - Multiple zotero refs

    func testMultipleZoteroRefs() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-00000000000c
            kind: note
            title: Multi Zotero
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/AAAAAAAA
                itemKey: AAAAAAAA
                library: library
                kind: item
              - selectLink: zotero://select/groups/42/items/BBBBBBBB
                itemKey: BBBBBBBB
                library: 42
                kind: attachment
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.zotero.count, 2)
        XCTAssertEqual(item.zotero[0].itemKey, "AAAAAAAA")
        XCTAssertEqual(item.zotero[0].library, .user)
        XCTAssertEqual(item.zotero[1].itemKey, "BBBBBBBB")
        XCTAssertEqual(item.zotero[1].library, .group(42))
        XCTAssertEqual(item.zotero[1].kind, .attachment)
    }
}
