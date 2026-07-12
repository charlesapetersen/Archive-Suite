import XCTest
@testable import ArchiveNotes

final class ZoteroSelectLinkTests: XCTestCase {

    // MARK: - Form 1: library/items/<KEY>

    func testUserLibraryItems() {
        let ref = ZoteroSelectLink.parse("zotero://select/library/items/ABCD1234")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
        XCTAssertEqual(ref?.library, .user)
        XCTAssertEqual(ref?.selectLink, "zotero://select/library/items/ABCD1234")
    }

    // MARK: - Form 2: groups/<GID>/items/<KEY>

    func testGroupLibraryItems() {
        let ref = ZoteroSelectLink.parse("zotero://select/groups/42/items/XY9Z0A1B")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "XY9Z0A1B")
        XCTAssertEqual(ref?.library, .group(42))
        XCTAssertEqual(ref?.selectLink, "zotero://select/groups/42/items/XY9Z0A1B")
    }

    // MARK: - Form 3: items/<libID>_<KEY> (legacy)

    func testLegacyUserLibID0() {
        let ref = ZoteroSelectLink.parse("zotero://select/items/0_ABCD1234")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.library, .user)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
        XCTAssertEqual(ref?.selectLink, "zotero://select/library/items/ABCD1234")
    }

    func testLegacyUserLibID1() {
        let ref = ZoteroSelectLink.parse("zotero://select/items/1_ABCD1234")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.library, .user)
    }

    func testLegacyGroupLibID() {
        let ref = ZoteroSelectLink.parse("zotero://select/items/99_WXYZ5678")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.library, .group(99))
        XCTAssertEqual(ref?.itemKey, "WXYZ5678")
        XCTAssertEqual(ref?.selectLink, "zotero://select/groups/99/items/WXYZ5678")
    }

    // MARK: - Form 4: items/<KEY> (assume user)

    func testBareItemsKey() {
        let ref = ZoteroSelectLink.parse("zotero://select/items/ZZZZ9999")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.library, .user)
        XCTAssertEqual(ref?.itemKey, "ZZZZ9999")
        XCTAssertEqual(ref?.selectLink, "zotero://select/library/items/ZZZZ9999")
    }

    // MARK: - Canonicalization

    func testCanonicalSelectLinkForUser() {
        let ref = ZoteroSelectLink.parse("zotero://select/items/ABCD1234")
        XCTAssertEqual(ref?.selectLink, "zotero://select/library/items/ABCD1234")
    }

    func testCanonicalSelectLinkForGroup() {
        let ref = ZoteroSelectLink.parse("zotero://select/items/5_ABCD1234")
        XCTAssertEqual(ref?.selectLink, "zotero://select/groups/5/items/ABCD1234")
    }

    // MARK: - Edge cases

    func testTrailingSlash() {
        let ref = ZoteroSelectLink.parse("zotero://select/library/items/ABCD1234/")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
    }

    func testURLEncodedKey() {
        let ref = ZoteroSelectLink.parse("zotero://select/library/items/AB%43D1234")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
    }

    func testExtraQueryFragment() {
        let ref = ZoteroSelectLink.parse("zotero://select/library/items/ABCD1234?foo=bar#baz")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
    }

    func testWhitespaceAroundURL() {
        let ref = ZoteroSelectLink.parse("  zotero://select/library/items/ABCD1234  \n")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
    }

    func testCaseInsensitiveSchemeAndHost() {
        let ref = ZoteroSelectLink.parse("Zotero://Select/library/items/ABCD1234")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.itemKey, "ABCD1234")
    }

    // MARK: - Rejection cases

    func testRejectNonZoteroScheme() {
        XCTAssertNil(ZoteroSelectLink.parse("https://select/library/items/ABCD1234"))
    }

    func testRejectNonSelectHost() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://open-pdf/library/items/ABCD1234"))
    }

    func testRejectOpenPDF() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://open-pdf/0_ABCD1234"))
    }

    func testRejectShortKey() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://select/library/items/ABC"))
    }

    func testRejectLongKey() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://select/library/items/ABCDEFGH9"))
    }

    func testRejectLowercaseKey() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://select/library/items/abcd1234"))
    }

    func testRejectEmptyPath() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://select"))
    }

    func testRejectJunk() {
        XCTAssertNil(ZoteroSelectLink.parse("not a url at all"))
    }

    func testRejectEmptyString() {
        XCTAssertNil(ZoteroSelectLink.parse(""))
    }

    func testRejectKeyWithSpecialChars() {
        XCTAssertNil(ZoteroSelectLink.parse("zotero://select/library/items/ABCD-234"))
    }

    // MARK: - Default kind

    func testDefaultKindIsItem() {
        let ref = ZoteroSelectLink.parse("zotero://select/library/items/ABCD1234")
        XCTAssertEqual(ref?.kind, .item)
    }
}
