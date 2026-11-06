import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W40.fix-suite-no-set-clear: what an Edit Info date field writes when it is applied (Return, leaving it, Done),
/// now that there is no Set or Clear button. A wrong answer here writes tags to every selected file.
@MainActor
final class TagEditorFieldEditTests: XCTestCase {
    private typealias F = TagEditorView.DateField
    private let mixed: String?? = .some(nil)

    func testTypedValueWritesAndEmptiedFieldClears() {
        XCTAssertEqual(TagEditorView.edit(.year, typed: "1962", shared: "1958"), .setYear(1962))
        XCTAssertEqual(TagEditorView.edit(.year, typed: "", shared: "1958"), .setYear(nil))
        XCTAssertEqual(TagEditorView.edit(.day, typed: " 12 ", shared: ""), .setDay(12))
        XCTAssertEqual(TagEditorView.edit(.day, typed: "", shared: "3"), .setDay(nil))
        XCTAssertEqual(TagEditorView.edit(.sentWith, typed: "1958-03-12", shared: ""),
                       .setSentWith(ArchiveDate.parse(wireValue: "1958-03-12")))
        XCTAssertEqual(TagEditorView.edit(.sentWith, typed: "", shared: "1958"), .setSentWith(nil))
    }

    func testUnchangedValueWritesNothing() {
        XCTAssertNil(TagEditorView.edit(.year, typed: "1958", shared: "1958"))
        XCTAssertNil(TagEditorView.edit(.year, typed: " 1958", shared: "1958"))
        XCTAssertNil(TagEditorView.edit(.day, typed: "", shared: ""), "emptying an empty field is not an edit")
    }

    /// The review's finding: typing into a mixed group's field and erasing it again must not clear every file.
    func testEmptiedMixedFieldLeavesEachFileAlone() {
        for field in [F.year, .day, .sentWith] {
            XCTAssertNil(TagEditorView.edit(field, typed: "", shared: mixed), "\(field)")
            XCTAssertNil(TagEditorView.edit(field, typed: "   ", shared: mixed), "\(field)")
        }
        XCTAssertEqual(TagEditorView.edit(.year, typed: "1960", shared: mixed), .setYear(1960),
                       "a value typed into a mixed field applies to every file")
    }

    func testInvalidEntryIsNeverWritten() {
        for (field, text) in [(F.year, "19588"), (.year, "99"), (.year, "abc"), (.day, "32"), (.day, "0"),
                              (.sentWith, "March 1958")] {
            XCTAssertNil(TagEditorView.dateOp(field, text), "\(field) \(text)")
            XCTAssertNil(TagEditorView.edit(field, typed: text, shared: "1958"), "\(field) \(text)")
        }
    }

    func testFacetsSeedTheSharedValueOrMixed() {
        XCTAssertEqual(TagEditorView.DateFacets([]).texts[.year], .some(""))
    }
}
