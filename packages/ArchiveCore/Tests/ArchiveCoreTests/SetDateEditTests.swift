import XCTest
@testable import ArchiveCore

/// W40.fix-reader-date-fields: `TagEditOp.setDate`, the own date written as one value. It must write the same tokens
/// `setYear`/`setMonth`/`setDay` write (the tag contract is unchanged) and remove only the date facets' own tokens.
final class SetDateEditTests: XCTestCase {
    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }
    private func date(_ wire: String) -> ArchiveDate { ArchiveDate.parse(wireValue: wire)! }
    private func applied(_ op: TagEditOp, to raw: [String]) -> DocumentTags {
        let d = TagEditing.delta(for: op, given: tags(raw))
        var out = raw.filter { t in !d.remove.contains { shouldRemoveTag(t, matching: $0) } }
        out += d.add.filter { a in !out.contains(where: { isSameTag($0, a) }) }
        return tags(out)
    }

    func testEachPrecisionWritesTheFacetTokens() {
        XCTAssertEqual(TagEditing.dateTokens(for: date("1958-03-12")), ["1958", "03 March", "Day 12"])
        XCTAssertEqual(TagEditing.dateTokens(for: date("1958-03")), ["1958", "03 March"])
        XCTAssertEqual(TagEditing.dateTokens(for: date("1958")), ["1958"])
        XCTAssertEqual(TagEditing.dateTokens(for: date("1950s")), ["1950s"])
        // The same tokens the separate ops write.
        let given = tags([])
        let separate = [TagEditOp.setYear(1958), .setMonth(3), .setDay(12)].flatMap { TagEditing.delta(for: $0, given: given).add }
        XCTAssertEqual(separate, TagEditing.dateTokens(for: date("1958-03-12")))
    }

    func testReplacesEveryDateFacetAndKeepsEverythingElse() {
        let raw = ["Economics", "1960s", "1961", "04 April", "Day 3", "Date Uncertain", "Q2", "Sent With 1958-03-12"]
        let t = applied(.setDate(date("1958-03-12")), to: raw)
        XCTAssertEqual(t.year, 1958); XCTAssertEqual(t.month?.number, 3); XCTAssertEqual(t.day, 12)
        XCTAssertNil(t.decade, "a year supersedes the decade, as setYear does")
        XCTAssertEqual(t.subjects, ["Economics"])
        XCTAssertTrue(t.dateUncertain); XCTAssertEqual(t.quality, 2); XCTAssertEqual(t.sentWith, date("1958-03-12"))

        let coarser = applied(.setDate(date("1950s")), to: raw)
        XCTAssertNil(coarser.year); XCTAssertNil(coarser.month); XCTAssertNil(coarser.day)
        XCTAssertEqual(coarser.decade, 1950)

        let cleared = applied(.setDate(nil), to: raw)
        XCTAssertNil(cleared.year); XCTAssertNil(cleared.month); XCTAssertNil(cleared.day); XCTAssertNil(cleared.decade)
        XCTAssertEqual(cleared.subjects, ["Economics"])
        XCTAssertTrue(cleared.dateUncertain, "the uncertain flag is its own control")
    }

    func testTheSameDateWritesNothing() {
        XCTAssertTrue(TagEditing.delta(for: .setDate(date("1958-03-12")), given: tags(["Day 12", "1958", "03 March", "X"])).isEmpty)
        XCTAssertTrue(TagEditing.delta(for: .setDate(nil), given: tags(["X"])).isEmpty)
        XCTAssertFalse(TagEditing.delta(for: .setDate(date("1958")), given: tags(["1958", "1950s"])).isEmpty,
                       "a hidden decade beside the year is dropped")
    }

    func testASubjectThatLooksLikeADateIsNotTouched() {
        // The second "1961" is demoted to a subject; setDate names only the facet's token. The writer matches by
        // value, so an identical demoted copy goes with it (as for setYear): the end state has one year.
        let d = TagEditing.delta(for: .setDate(date("1958")), given: tags(["Day 12 of the strike", "1961"]))
        XCTAssertEqual(d.remove, ["1961"])
        XCTAssertEqual(d.add, ["1958"])
    }
}
