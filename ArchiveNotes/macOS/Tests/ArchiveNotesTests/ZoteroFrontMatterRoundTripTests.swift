import XCTest
@testable import ArchiveNotes

final class ZoteroFrontMatterRoundTripTests: XCTestCase {

    // MARK: - Decode typed zotero

    func testDecodeUserLibrary() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000001
            kind: note
            title: User Lib
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: library
                kind: item
                citation: "Moore, G. 2001."
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.zotero.count, 1)
        let z = item.zotero[0]
        XCTAssertEqual(z.library, .user)
        XCTAssertEqual(z.itemKey, "ABCD1234")
        XCTAssertEqual(z.citation, "Moore, G. 2001.")
        XCTAssertNil(z.fetchedAt)
        XCTAssertNil(z.parentKey)
    }

    func testDecodeGroupLibrary() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000002
            kind: note
            title: Group Lib
            roundup: false
            zotero:
              - selectLink: zotero://select/groups/42/items/XY9Z0A1B
                itemKey: XY9Z0A1B
                library: 42
                kind: attachment
                parentKey: PKEY5678
                fetchedAt: 2026-07-10T21:00:00Z
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        let z = item.zotero[0]
        XCTAssertEqual(z.library, .group(42))
        XCTAssertEqual(z.kind, .attachment)
        XCTAssertEqual(z.parentKey, "PKEY5678")
        XCTAssertNotNil(z.fetchedAt)
    }

    func testDecodeCaseInsensitiveLibrary() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000003
            kind: note
            title: Case
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: Library
                kind: item
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.zotero[0].library, .user)
    }

    // MARK: - Byte-stable round-trip

    func testByteStableUserLibWithCitation() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000004
            kind: note
            title: Byte stable
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: library
                kind: item
                citation: Moore 2001
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        let reencoded = FrontMatterCodec.encode(item)
        XCTAssertEqual(reencoded, text)
    }

    func testByteStableGroupWithAllFields() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000005
            kind: note
            title: All fields
            roundup: false
            zotero:
              - selectLink: zotero://select/groups/7/items/WXYZ5678
                itemKey: WXYZ5678
                library: 7
                kind: attachment
                parentKey: ABCD1234
                citation: Smith 1999
                fetchedAt: 2026-07-10T21:00:00Z
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        let reencoded = FrontMatterCodec.encode(item)
        XCTAssertEqual(reencoded, text)
    }

    // MARK: - Model-level round-trip

    func testModelRoundTripWithZotero() throws {
        let ref = Date(timeIntervalSinceReferenceDate: 804_070_200)
        let fetchDate = Date(timeIntervalSinceReferenceDate: 804_070_000)
        let item = Item(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            kind: .note,
            title: "Round-trip zotero",
            authors: [],
            date: nil,
            datePrecision: nil,
            dateUncertain: false,
            quality: nil,
            tags: [],
            zotero: [
                ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                          itemKey: "ABCD1234", library: .user,
                          citation: "A citation"),
                ZoteroRef(selectLink: "zotero://select/groups/5/items/WXYZ5678",
                          itemKey: "WXYZ5678", library: .group(5), kind: .attachment,
                          parentKey: "PKEY0000", citation: "B cite", fetchedAt: fetchDate),
            ],
            roundup: false,
            created: ref,
            modified: ref,
            schema: 1,
            blocks: [],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )

        let encoded = FrontMatterCodec.encode(item)
        let decoded = try FrontMatterCodec.decode(encoded)

        XCTAssertEqual(decoded.zotero.count, 2)

        let z0 = decoded.zotero[0]
        XCTAssertEqual(z0.selectLink, "zotero://select/library/items/ABCD1234")
        XCTAssertEqual(z0.itemKey, "ABCD1234")
        XCTAssertEqual(z0.library, .user)
        XCTAssertEqual(z0.kind, .item)
        XCTAssertEqual(z0.citation, "A citation")
        XCTAssertNil(z0.parentKey)
        XCTAssertNil(z0.fetchedAt)

        let z1 = decoded.zotero[1]
        XCTAssertEqual(z1.selectLink, "zotero://select/groups/5/items/WXYZ5678")
        XCTAssertEqual(z1.library, .group(5))
        XCTAssertEqual(z1.kind, .attachment)
        XCTAssertEqual(z1.parentKey, "PKEY0000")
        XCTAssertEqual(z1.citation, "B cite")
        XCTAssertNotNil(z1.fetchedAt)
    }

    // MARK: - ZoteroLibrary Codable

    func testZoteroLibraryCodableUser() throws {
        let data = try JSONEncoder().encode(ZoteroLibrary.user)
        let decoded = try JSONDecoder().decode(ZoteroLibrary.self, from: data)
        XCTAssertEqual(decoded, .user)
    }

    func testZoteroLibraryCodableGroup() throws {
        let data = try JSONEncoder().encode(ZoteroLibrary.group(42))
        let decoded = try JSONDecoder().decode(ZoteroLibrary.self, from: data)
        XCTAssertEqual(decoded, .group(42))
    }

    // MARK: - Citation survives round-trip (§5 durable survivor)

    func testCitationSurvivesRoundTrip() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000006
            kind: note
            title: Citation test
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: library
                kind: item
                citation: "Moore, Gordon E. Oral History. Chemical Heritage Foundation, 2001."
                fetchedAt: 2026-07-10T21:00:00Z
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        let reencoded = FrontMatterCodec.encode(item)
        let reread = try FrontMatterCodec.decode(reencoded)

        XCTAssertEqual(reread.zotero[0].citation, item.zotero[0].citation)
        XCTAssertNotNil(reread.zotero[0].fetchedAt)
    }

    // MARK: - Unknown zotero sub-keys preserved across round-trip

    func testUnknownZoteroKeysRoundTrip() throws {
        let text = """
            ---
            schema: 1
            id: 00000000-0000-0000-0000-000000000007
            kind: note
            title: Unknown keys
            roundup: false
            zotero:
              - selectLink: zotero://select/library/items/ABCD1234
                itemKey: ABCD1234
                library: library
                kind: item
                future_key: future_value
            created: 2026-01-01T00:00:00Z
            modified: 2026-01-01T00:00:00Z
            ---

            """
        let item = try FrontMatterCodec.decode(text)
        XCTAssertEqual(item.zotero[0].unknown.count, 1)
        XCTAssertEqual(item.zotero[0].unknown[0].key, "future_key")

        let reencoded = FrontMatterCodec.encode(item)
        XCTAssertTrue(reencoded.contains("future_key: future_value"))
    }

    // MARK: - Empty zotero array not emitted

    func testEmptyZoteroNotEmitted() {
        let item = Item(
            id: UUID(), kind: .note, title: "No refs", authors: [], date: nil,
            datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
            zotero: [], roundup: false, created: Date(), modified: Date(),
            schema: 1, blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil
        )
        let encoded = FrontMatterCodec.encode(item)
        XCTAssertFalse(encoded.contains("zotero"))
    }
}
