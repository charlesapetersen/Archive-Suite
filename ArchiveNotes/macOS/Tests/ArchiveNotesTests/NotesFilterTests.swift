import XCTest
@testable import ArchiveNotes

final class NotesFilterTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultFilterIsEmpty() {
        let filter = NotesFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(filter.searchText, "")
        XCTAssertEqual(filter.tags, [])
        XCTAssertEqual(filter.tagCombine, .all)
        XCTAssertEqual(filter.kind, .both)
        XCTAssertTrue(filter.qualities.isEmpty)
        XCTAssertNil(filter.dateFrom)
        XCTAssertNil(filter.dateTo)
        XCTAssertNil(filter.folderId)
    }

    func testNonEmptySearchText() {
        var filter = NotesFilter()
        filter.searchText = "hello"
        XCTAssertFalse(filter.isEmpty)
    }

    func testNonEmptyTags() {
        var filter = NotesFilter()
        filter.tags = ["History"]
        XCTAssertFalse(filter.isEmpty)
    }

    func testKindFilterNotBoth() {
        var filter = NotesFilter()
        filter.kind = .notes
        XCTAssertFalse(filter.isEmpty)
    }

    func testNonEmptyQualities() {
        var filter = NotesFilter()
        filter.qualities = [7, 8]
        XCTAssertFalse(filter.isEmpty)
    }

    func testDateFromMakesNonEmpty() {
        var filter = NotesFilter()
        filter.dateFrom = 19680000
        XCTAssertFalse(filter.isEmpty)
    }

    func testFolderIdMakesNonEmpty() {
        var filter = NotesFilter()
        filter.folderId = UUID()
        XCTAssertFalse(filter.isEmpty)
    }

    // MARK: - Equatable

    func testEqualFilters() {
        let a = NotesFilter()
        let b = NotesFilter()
        XCTAssertEqual(a, b)
    }

    func testUnequalFilters() {
        var a = NotesFilter()
        a.searchText = "test"
        let b = NotesFilter()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let folderId = UUID()
        var filter = NotesFilter()
        filter.searchText = "silicon valley"
        filter.tags = ["History", "Tech"]
        filter.tagCombine = .any
        filter.kind = .notes
        filter.qualities = [7, 8, 9]
        filter.dateFrom = 19600000
        filter.dateTo = 19691231
        filter.folderId = folderId

        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: data)

        XCTAssertEqual(decoded, filter)
        XCTAssertEqual(decoded.searchText, "silicon valley")
        XCTAssertEqual(decoded.tags, ["History", "Tech"])
        XCTAssertEqual(decoded.tagCombine, .any)
        XCTAssertEqual(decoded.kind, .notes)
        XCTAssertEqual(decoded.qualities, [7, 8, 9])
        XCTAssertEqual(decoded.dateFrom, 19600000)
        XCTAssertEqual(decoded.dateTo, 19691231)
        XCTAssertEqual(decoded.folderId, folderId)
    }

    func testDefaultFilterCodableRoundTrip() throws {
        let filter = NotesFilter()
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: data)
        XCTAssertEqual(decoded, filter)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - TagCombine / KindFilter raw values

    func testTagCombineRawValues() {
        XCTAssertEqual(TagCombine.all.rawValue, "all")
        XCTAssertEqual(TagCombine.any.rawValue, "any")
    }

    func testKindFilterRawValues() {
        XCTAssertEqual(KindFilter.notes.rawValue, "notes")
        XCTAssertEqual(KindFilter.extracts.rawValue, "extracts")
        XCTAssertEqual(KindFilter.both.rawValue, "both")
    }
}
