import XCTest
@testable import ArchiveCore

final class TitleCaseTests: XCTestCase {

    func testHeadingInCapitals() {
        XCTAssertEqual(TitleCase.titleCased("MANAGING DIRECTOR QUALIFICATIONS"), "Managing Director Qualifications")
        XCTAssertEqual(TitleCase.titleCased("BOX 12"), "Box 12")
        XCTAssertEqual(TitleCase.titleCased("JANE DOE PAPERS"), "Jane Doe Papers")
    }

    func testSmallWordsLowerInsideCapitalisedAtEnds() {
        XCTAssertEqual(TitleCase.titleCased("THE STATE OF THE UNION"), "The State of the Union")
        XCTAssertEqual(TitleCase.titleCased("A PLACE TO STAND ON"), "A Place to Stand On")
        XCTAssertEqual(TitleCase.titleCased("REPORT: THE FIRST YEAR"), "Report: The First Year")
    }

    func testAcronymsAndInitialsKept() {
        XCTAssertEqual(TitleCase.titleCased("LETTER FROM UCLA TO THE M/D"), "Letter from UCLA to the M/D")
        XCTAssertEqual(TitleCase.titleCased("J. W. SMITH AND THE U.S.A."), "J. W. Smith and the U.S.A.")
        XCTAssertEqual(TitleCase.titleCased("NBC AND HBS ON WORLD WAR II"), "NBC and HBS on World War II")
        XCTAssertEqual(TitleCase.titleCased("THE AFL-CIO"), "The AFL-CIO")
        XCTAssertEqual(TitleCase.titleCased("PAPERS OF ACME CORP", keeping: ["acme"]), "Papers of ACME Corp")
    }

    func testTitlesContractionsNamesNumbers() {
        XCTAssertEqual(TitleCase.titleCased("MR. O'BRIEN DON'T"), "Mr. O'Brien Don't")
        XCTAssertEqual(TitleCase.titleCased("THE PRESIDENT’S 12TH REPORT, 1960S"), "The President’s 12th Report, 1960s")
        XCTAssertEqual(TitleCase.titleCased("FIRST-CLASS MAIL AND/OR FREIGHT"), "First-Class Mail and/or Freight")
        XCTAssertEqual(TitleCase.titleCased("“THE FIRM” (DRAFT)"), "“The Firm” (Draft)")
    }

    func testMixedCaseTextIsLeftAlone() {
        let s = "He wrote to the UCLA library and to MR SMITH."
        XCTAssertEqual(TitleCase.titleCased(s), s)
        XCTAssertFalse(TitleCase.isAllCapitals(s))
        XCTAssertFalse(TitleCase.isAllCapitals("A"), "one capital is not a line in capitals")
        XCTAssertFalse(TitleCase.isAllCapitals("12 — 14"))
        XCTAssertTrue(TitleCase.isAllCapitals("TO:"))
    }

    func testOnlyCaseChangesAndWhitespaceIsKept() {
        let s = "  THE   COMMITTEE,\tON (A) DRAFT —  NOT FINAL  "
        let t = TitleCase.titleCased(s)
        XCTAssertEqual(t.lowercased(), s.lowercased())
        XCTAssertEqual(t, "  The   Committee,\ton (A) Draft —  Not Final  ")
    }
}
