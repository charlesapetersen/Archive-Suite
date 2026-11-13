import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W40.fix-suite-no-set-clear, W40.fix-reader-date-fields: what an Inspector date field writes when it is applied
/// (Return, leaving it, Close). One typed field per date, read by the suite's `DateFieldEntry`. A wrong answer here
/// writes tags to every selected file.
@MainActor
final class TagEditorFieldEditTests: XCTestCase {
    private typealias F = TagEditorView.DateField
    private typealias E = InspectorDateEntry
    private let mixed: String?? = .some(nil)
    private func date(_ wire: String) -> ArchiveDate { ArchiveDate.parse(wireValue: wire)! }
    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }

    func testEveryFormReadsAsOneDate() {
        for text in ["12 March 1958", "1958-03-12", "1958-3-12", "March 12, 1958", "12 mar 1958"] {
            XCTAssertEqual(E.read(text), .date(date("1958-03-12"), note: nil), text)
        }
        XCTAssertEqual(E.read("March 1958"), .date(date("1958-03"), note: nil))
        XCTAssertEqual(E.read("1958"), .date(date("1958"), note: nil))
        XCTAssertEqual(E.read("1950s"), .date(date("1950s"), note: nil))
        XCTAssertEqual(E.read("  "), .empty)
    }

    func testTheFieldShowsNoLeadingZeroAndReadsBack() {
        for wire in ["1950s", "1958", "1958-03", "1958-03-02"] {
            let text = E.text(date(wire))
            XCTAssertFalse(text.contains("03") || text.contains(" 02"), text)
            XCTAssertEqual(E.read(text), .date(date(wire), note: nil), text)
        }
        XCTAssertEqual(E.text(date("1958-03-02")), "2 March 1958")
    }

    func testAnImpossibleDayDropsToTheMonthAndSaysSo() {
        guard case .date(let d, let note?) = E.read("31 February 1958") else { return XCTFail() }
        XCTAssertEqual(d, date("1958-02"))
        XCTAssertTrue(note.contains("28 days"), note)
        XCTAssertEqual(E.hint("31 February 1958")?.isError, false)
    }

    func testInvalidEntryIsNeverWritten() {
        for text in ["19588", "99", "abc", "12/3/1958", "1958-13", "Smarch 1958", "50", "1958-03-00"] {
            if case .date = E.read(text) { XCTFail(text) }
            XCTAssertEqual(E.hint(text)?.isError, true, text)
            for field in [F.own, .sentWith] {
                XCTAssertNil(TagEditorView.edit(field, typed: text, shared: "1958"), "\(field) \(text)")
            }
        }
    }

    func testTypedValueWritesAndEmptiedFieldClears() {
        XCTAssertEqual(TagEditorView.edit(.own, typed: "1962", shared: "1958"), .setDate(date("1962")))
        XCTAssertEqual(TagEditorView.edit(.own, typed: "", shared: "1958"), .setDate(nil))
        XCTAssertEqual(TagEditorView.edit(.own, typed: "12 March 1958", shared: ""), .setDate(date("1958-03-12")))
        XCTAssertEqual(TagEditorView.edit(.sentWith, typed: "1958-03-12", shared: ""), .setSentWith(date("1958-03-12")))
        XCTAssertEqual(TagEditorView.edit(.sentWith, typed: "", shared: "1958"), .setSentWith(nil))
    }

    func testUnchangedValueWritesNothing() {
        XCTAssertNil(TagEditorView.edit(.own, typed: "March 1958", shared: "March 1958"))
        XCTAssertNil(TagEditorView.edit(.own, typed: "1958-03", shared: "March 1958"), "the same date typed another way")
        XCTAssertNil(TagEditorView.edit(.own, typed: "", shared: ""), "emptying an empty field is not an edit")
        XCTAssertEqual(TagEditorView.edit(.own, typed: "1958-03-12", shared: "March 1958"), .setDate(date("1958-03-12")))
    }

    /// The review's finding: typing into a mixed group's field and erasing it again must not clear every file.
    func testEmptiedMixedFieldLeavesEachFileAlone() {
        for field in [F.own, .sentWith] {
            XCTAssertNil(TagEditorView.edit(field, typed: "", shared: mixed), "\(field)")
            XCTAssertNil(TagEditorView.edit(field, typed: "   ", shared: mixed), "\(field)")
        }
        XCTAssertEqual(TagEditorView.edit(.own, typed: "1960", shared: mixed), .setDate(date("1960")),
                       "a value typed into a mixed field applies to every file")
    }

    func testOwnDateFromTheFacets() {
        XCTAssertEqual(E.ownText(tags(["1958", "03 March", "Day 12"])), "12 March 1958")
        XCTAssertEqual(E.ownText(tags(["1950s"])), "1950s")
        XCTAssertEqual(E.ownText(tags(["1950s", "1958"])), "1958", "a year wins over a decade")
        XCTAssertEqual(E.ownText(tags(["Economics"])), "")
        // Facets that make no date still show, say what is wrong, and never read back as a date (the review's
        // finding: `12 1958` read as December 1958, so typing that to add the month wrote nothing).
        for (raw, shown) in [(["03 March", "Day 12"], "12 March (no year)"), (["03 March"], "March (no year)"),
                             (["1958", "Day 12"], "1958, day 12 (no month)"),
                             (["1958", "02 February", "Day 31"], "31 February 1958 (no such day)"),
                             (["1950s", "03 March"], "March 1950s (no year)")] {
            XCTAssertNil(E.ownDate(tags(raw)), "\(raw)")
            XCTAssertEqual(E.ownText(tags(raw)), shown)
            if case .date = E.read(shown) { XCTFail(shown) }
        }
        XCTAssertEqual(TagEditorView.edit(.own, typed: "December 1958", shared: "1958, day 12 (no month)"),
                       .setDate(date("1958-12")))
        XCTAssertEqual(TagEditorView.edit(.own, typed: "February 1958", shared: "31 February 1958 (no such day)"),
                       .setDate(date("1958-02")))
    }

    func testFacetsSeedTheSharedValueOrMixed() {
        XCTAssertEqual(TagEditorView.DateFacets([]).texts[.own], .some(""))
    }
}
