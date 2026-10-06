import XCTest
@testable import ArchiveCore

/// W37.dual-date — an enclosure carries its own date AND its covering letter's ("sent with") date.
final class DualDateTests: XCTestCase {

    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }

    // MARK: ArchiveDate wire grammar

    func testWireRoundTripAllFourPrecisions() throws {
        for (wire, precision, display) in [("1958", ArchiveDate.Precision.year, "1958"),
                                           ("1958-03", .month, "Mar 1958"),
                                           ("1958-03-12", .day, "Mar 12, 1958"),
                                           ("1950s", .decade, "1950s"),
                                           ("800", .year, "800"),
                                           ("970s", .decade, "970s")] {
            let d = try XCTUnwrap(ArchiveDate.parse(wireValue: wire), wire)
            XCTAssertEqual(d.precision, precision, wire)
            XCTAssertEqual(d.wireValue, wire)
            XCTAssertEqual(d.display, display)
        }
    }

    func testWireRejectsMalformedWithoutInventingPrecision() {
        for bad in ["", "58", "19580", "0958", "1958-3", "1958-13", "1958-00", "1958-03-1", "1958-02-30",
                    "1900-02-29", "1958-03-12-01", "1955s", "1950S", "1958-", "-1958", "１９５８", "1958 "] {
            XCTAssertNil(ArchiveDate.parse(wireValue: bad), bad)
        }
        XCTAssertNotNil(ArchiveDate.parse(wireValue: "2000-02-29"))
        XCTAssertNotNil(ArchiveDate.parse(wireValue: "1956-02-29"))
    }

    func testSortKeysUseTheSharedFormula() {
        XCTAssertEqual(ArchiveDate(year: 1958, month: 3, day: 12)?.sortKey, 19_580_312)
        XCTAssertEqual(ArchiveDate(year: 1958)?.sortKey, 19_580_000)
        XCTAssertEqual(ArchiveDate(decade: 1950)?.sortKey, 19_500_000)
        XCTAssertNil(ArchiveDate(year: 1958, day: 3), "a day without a month is not a value")
    }

    // MARK: Parsing

    func testDifferentDatesParseIntoSeparateRoles() {
        let t = tags(["1957", "11 November", "Day 3", "Sent With 1958-03-12", "Report", "Unread"])
        XCTAssertEqual(t.year, 1957); XCTAssertEqual(t.month?.number, 11); XCTAssertEqual(t.day, 3)
        XCTAssertEqual(t.sentWith, ArchiveDate(year: 1958, month: 3, day: 12))
        XCTAssertEqual(t.sentWithToken, "Sent With 1958-03-12")
        XCTAssertEqual(t.subjects, ["Report"])
        XCTAssertEqual(t.topicalTags, ["Report"])
        XCTAssertEqual(t.displayDate, "Nov 3, 1957")
        XCTAssertEqual(t.displaySentWith, "Mar 12, 1958")
        XCTAssertFalse(t.sentWithIsAmbiguous)
    }

    func testOwnDateSortsAndSentWithIsTheFallback() {
        let both = tags(["1957", "Sent With 1958-03-12"])
        XCTAssertEqual(both.sortDate, 19_570_000)
        XCTAssertFalse(both.sortsBySentWith)
        let sentOnly = tags(["Sent With 1958-03", "Report"])
        XCTAssertEqual(sentOnly.sortDate, 19_580_300)
        XCTAssertTrue(sentOnly.sortsBySentWith)
        XCTAssertNil(sentOnly.ownSortDate)
        XCTAssertNil(sentOnly.displayDate, "the own date stays missing; nothing is borrowed")
        let ownOnly = tags(["1957"])
        XCTAssertNil(ownOnly.sentWith)
        XCTAssertEqual(ownOnly.dateKeysByRole, [.own: 19_570_000])
    }

    func testIdenticalDatesStaySeparatelyLabelled() {
        let t = tags(["1958", "03 March", "Day 12", "Sent With 1958-03-12"])
        XCTAssertEqual(t.dateKeysByRole, [.own: 19_580_312, .sentWith: 19_580_312])
    }

    func testUncertaintyBelongsToEachRole() {
        let t = tags(["1957", "Sent With 1950s", "Sent With Date Uncertain"])
        XCTAssertFalse(t.dateUncertain)
        XCTAssertTrue(t.sentWithUncertain)
        XCTAssertEqual(t.sentWith?.precision, .decade)
        XCTAssertTrue(t.topicalTags.isEmpty)
        let u = tags(["1957", "Date Uncertain", "Sent With 1958"])
        XCTAssertTrue(u.dateUncertain)
        XCTAssertFalse(u.sentWithUncertain)
    }

    func testMalformedAndRoleLookingSubjectsStayVerbatim() {
        let t = tags(["sent with 1958", "Sent With 1958-13", "Sent With Love", "Sent  With 1958", "1957"])
        XCTAssertNil(t.sentWith)
        XCTAssertEqual(t.subjects, ["sent with 1958", "Sent With 1958-13", "Sent With Love", "Sent  With 1958"])
        XCTAssertTrue(t.sentWithIsAmbiguous)
        XCTAssertFalse(DocumentTags.isDateFacetLike("Sent With Love"))
        XCTAssertTrue(DocumentTags.isDateFacetLike("Sent With 1958"))
        XCTAssertTrue(DocumentTags.isDateFacetLike("Sent With Date Uncertain"))
    }

    func testConflictingTokensDemoteTheEarlierAndNeverCombine() {
        let t = tags(["Sent With 1958", "Sent With 1960-04"])
        XCTAssertEqual(t.sentWith, ArchiveDate(year: 1960, month: 4))
        XCTAssertEqual(t.sentWithToken, "Sent With 1960-04")
        XCTAssertEqual(t.subjects, ["Sent With 1958"])
        XCTAssertTrue(t.sentWithIsAmbiguous)
    }

    func testBareComponentsNeverCrossPairWithSentWith() {
        // The covering letter's month cannot leak into the item's year-only own date.
        let t = tags(["1957", "Sent With 1958-03-12"])
        XCTAssertNil(t.month); XCTAssertNil(t.day)
        XCTAssertEqual(t.displayDate, "1957")
    }

    // MARK: Generated tags

    func testGeneratedTagsEmitSentWithAfterOwnDate() {
        let g = GeneratedTags(year: "1957", month: "11 November", day: "Day 3", dateUncertain: true,
                              sentWith: ArchiveDate(year: 1958, month: 3, day: 12), sentWithUncertain: true,
                              subjectTags: ["report"], quality: 2)
        XCTAssertEqual(g.allTags, ["1957", "11 November", "Day 3", "Date Uncertain",
                                   "Sent With 1958-03-12", "Sent With Date Uncertain", "Report", "Q2"])
        let parsed = tags(g.allTags)
        XCTAssertEqual(parsed.sentWith, g.sentWith)
        XCTAssertTrue(parsed.sentWithUncertain)
        XCTAssertEqual(parsed.subjects, ["Report"])
    }

    func testGeneratedUncertainFlagNeedsAValue() {
        let g = GeneratedTags(year: "1957", sentWithUncertain: true)
        XCTAssertEqual(g.allTags, ["1957"])
    }

    func testGeneratedTagsCodableKeepsRoleAndPrecision() throws {
        let g = GeneratedTags(year: "1957", sentWith: ArchiveDate(decade: 1950), sentWithUncertain: true)
        let back = try JSONDecoder().decode(GeneratedTags.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back.sentWith, ArchiveDate(decade: 1950))
        XCTAssertTrue(back.sentWithUncertain)
    }

    // MARK: Editing

    func testSetSentWithReplacesOnlyTheConsumedToken() {
        let t = tags(["Sent With 1958", "1957", "Sent With 1960"])
        let d = TagEditing.delta(for: .setSentWith(ArchiveDate(year: 1961, month: 1)), given: t)
        XCTAssertEqual(d.add, ["Sent With 1961-01"])
        XCTAssertEqual(d.remove, ["Sent With 1960"])
    }

    func testSetSentWithSameValueIsANoOp() {
        let d = TagEditing.delta(for: .setSentWith(ArchiveDate(year: 1958)), given: tags(["Sent With 1958"]))
        XCTAssertEqual(d, TagDelta())
    }

    func testClearSentWithAlsoClearsItsUncertainFlagButNotTheOwn() {
        let t = tags(["1957", "Date Uncertain", "Sent With 1958", "Sent With Date Uncertain"])
        let d = TagEditing.delta(for: .setSentWith(nil), given: t)
        XCTAssertTrue(d.add.isEmpty)
        XCTAssertEqual(Set(d.remove), ["Sent With 1958", "Sent With Date Uncertain"])
    }

    func testSentWithUncertainToggle() {
        let t = tags(["Sent With 1958"])
        XCTAssertEqual(TagEditing.delta(for: .setSentWithUncertain(true), given: t).add, ["Sent With Date Uncertain"])
        XCTAssertEqual(TagEditing.delta(for: .setSentWithUncertain(true), given: tags(["1957"])), TagDelta(),
                       "no flag without a sent-with value")
        let u = tags(["Sent With 1958", "Sent With Date Uncertain", "Date Uncertain"])
        XCTAssertEqual(TagEditing.delta(for: .setSentWithUncertain(false), given: u).remove, ["Sent With Date Uncertain"])
        XCTAssertEqual(TagEditing.delta(for: .setDateUncertain(false), given: u).remove, ["Date Uncertain"],
                       "clearing the own flag leaves the sent-with flag")
    }

    // MARK: Range filter — either date, but each bound by the SAME value

    func testRangeMatchesEitherDateOnce() {
        let t = tags(["1957", "11 November", "Day 3", "Sent With 1958-03-12"])
        XCTAssertEqual(DateRangeFilter(fromYear: 1957, toYear: 1957).matchingRoles(t.dateKeysByRole), [.own])
        XCTAssertEqual(DateRangeFilter(fromYear: 1958, toYear: 1958).matchingRoles(t.dateKeysByRole), [.sentWith])
        XCTAssertEqual(DateRangeFilter(fromYear: 1950, toYear: 1960).matchingRoles(t.dateKeysByRole), [.own, .sentWith])
    }

    func testRangeCannotBeSatisfiedByOneDatePerBound() {
        let t = tags(["1950", "Sent With 1970"])
        XCTAssertTrue(DateRangeFilter(fromYear: 1960, toYear: 1965).matchingRoles(t.dateKeysByRole).isEmpty)
    }

    func testRangeKeepsSortKeySemanticsForYearAndDecade() {
        XCTAssertTrue(DateRangeFilter(fromYear: 1958, toYear: 1958).contains(ArchiveDate(year: 1958)!.sortKey))
        XCTAssertTrue(DateRangeFilter(fromYear: 1958, toYear: 1958).contains(ArchiveDate(year: 1958, month: 12, day: 31)!.sortKey))
        XCTAssertFalse(DateRangeFilter(fromYear: 1955, toYear: 1959).contains(ArchiveDate(decade: 1950)!.sortKey))
        XCTAssertTrue(DateRangeFilter(fromYear: 1950, toYear: nil).contains(ArchiveDate(decade: 1950)!.sortKey))
        XCTAssertTrue(DateRangeFilter().isUnbounded)
    }
}
