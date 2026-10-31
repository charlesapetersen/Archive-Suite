import XCTest
@testable import ArchiveCore

/// W40.fix-reader-date-ambiguity (ledger R-47) — two tags for one date facet are read by last-wins and flagged.
final class DateAmbiguityTests: XCTestCase {

    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }

    func testTwoYearsAreFlaggedAndNameTheOneSetAside() {
        let t = tags(["1980", "Cold War", "1984"])
        XCTAssertEqual(t.year, 1984, "the last-wins rule is unchanged")
        XCTAssertTrue(t.dateIsAmbiguous)
        XCTAssertEqual(t.dateAmbiguities, [DateAmbiguity(facet: .year, kept: "1984", setAside: ["1980"])])
        XCTAssertEqual(t.dateAmbiguities.first?.summary, "Two Year tags: 1984 is used, 1980 was set aside.")
    }

    func testTwoMonthsAndTwoDaysAreFlagged() {
        let t = tags(["1980", "03 March", "Day 4", "04 April", "Day 5"])
        XCTAssertEqual(t.month?.number, 4)
        XCTAssertEqual(t.dateAmbiguities.map(\.facet), [.month, .day])
        XCTAssertEqual(t.dateAmbiguities.first?.setAside, ["03 March"])
        XCTAssertEqual(t.dateAmbiguities.last?.kept, "Day 5")
    }

    func testThreeYearsListEveryOneSetAside() {
        let t = tags(["1970", "1975", "1980"])
        XCTAssertEqual(t.dateAmbiguities.first?.setAside, ["1970", "1975"])
        XCTAssertEqual(t.dateAmbiguities.first?.summary, "3 Year tags: 1980 is used, 1970, 1975 were set aside.")
    }

    func testOneOfEachFacetIsNotAmbiguous() {
        // A Year beside a Decade is the SPEC's supersede rule, not two of one facet.
        let t = tags(["1980", "03 March", "Day 4", "1980s", "Date Uncertain", "Sent With 1981", "Q2", "Read", "Cold War"])
        XCTAssertFalse(t.dateIsAmbiguous)
        XCTAssertEqual(t.dateAmbiguities, [])
        XCTAssertFalse(t.sentWithIsAmbiguous)
    }

    func testProseAndNonDateSubjectsDoNotFlag() {
        XCTAssertFalse(tags(["1980", "Sent With Love", "Box 1984", "12345", "Day One"]).dateIsAmbiguous)
    }

    func testSentWithConflictAndMalformedSentWith() {
        let two = tags(["Sent With 1958", "Sent With 1960-04"])
        XCTAssertEqual(two.dateAmbiguities, [DateAmbiguity(facet: .sentWith, kept: "Sent With 1960-04",
                                                           setAside: ["Sent With 1958"])])
        XCTAssertTrue(two.sentWithIsAmbiguous)
        let bad = tags(["Sent With 1958-13"])
        XCTAssertEqual(bad.dateAmbiguities.first?.kept, nil)
        XCTAssertEqual(bad.dateAmbiguities.first?.summary, "Sent With tag not read as a date: Sent With 1958-13.")
        XCTAssertTrue(bad.dateIsAmbiguous)
    }

    func testDateIsAmbiguousAgreesWithDateAmbiguities() {
        for raw in [["1980"], ["1980", "1981"], ["1970s", "1980s"], ["Sent With 1958-13"], ["Cold War", "Day 3"],
                    ["01 January", "1 January"], ["Sent With Love"]] {
            let t = tags(raw)
            XCTAssertEqual(t.dateIsAmbiguous, !t.dateAmbiguities.isEmpty, "\(raw)")
        }
        XCTAssertEqual(tags(["1970s", "1980s"]).dateAmbiguities.first?.facet, .decade)
        XCTAssertEqual(tags(["01 January", "1 January"]).dateAmbiguities.first?.facet, .month)
    }
}
