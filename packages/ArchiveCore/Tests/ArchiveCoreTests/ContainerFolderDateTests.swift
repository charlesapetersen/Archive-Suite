import XCTest
@testable import ArchiveCore

/// The folder-date rule (W47.ct-folder-date; owner, 2026-11-19 walkthrough).
final class ContainerFolderDateTests: XCTestCase {
    private func parsed(_ s: String) -> [Int?] {
        guard let d = ContainerFolderDate.parse(s) else { return [] }
        return [d.lo, d.hi, d.month]
    }

    func testTheValuesAFolderLabelCarriesAreRead() {
        XCTAssertEqual(parsed("1953"), [1953, 1953, nil])
        XCTAssertEqual(parsed("1965-1967"), [1965, 1967, nil])
        XCTAssertEqual(parsed("1966-70"), [1966, 1970, nil])
        XCTAssertEqual(parsed("1939- 78"), [1939, 1978, nil])
        XCTAssertEqual(parsed("1965 – 1967"), [1965, 1967, nil])
        XCTAssertEqual(parsed("1965 to 1967"), [1965, 1967, nil])
        XCTAssertEqual(parsed("1958-02"), [1958, 1958, nil], "an end before the start is the start year alone")
        XCTAssertEqual(parsed("1960s"), [1960, 1969, nil])
        XCTAssertEqual(parsed("1960's"), [1960, 1969, nil])
        XCTAssertEqual(parsed("Feb. 1970"), [1970, 1970, 2], "D18's folder")
        XCTAssertEqual(parsed("february 12, 1970"), [1970, 1970, 2])
        XCTAssertEqual(parsed("Sept 1970"), [1970, 1970, 9])
        XCTAssertEqual(parsed("2/1970"), [1970, 1970, 2])
        XCTAssertEqual(parsed("6/2/61"), [1961, 1961, 6])
        XCTAssertEqual(parsed("13/2/61"), [1961, 1961, nil], "no 13th month")
    }

    func testAnythingElseDatesNothing() {
        for s in ["", "Correspondence", "1967-1965", "1684", "2045", "Reports 1959", "ca. 1965", "Flob 1970"] {
            XCTAssertNil(ContainerFolderDate.parse(s), s)
        }
    }

    private func inherited(_ s: String) -> ContainerFolderDate.Inherited? { ContainerFolderDate.parse(s)?.inherited }

    func testTheOwnersRuleBySpan() {
        XCTAssertEqual(inherited("1971"), .year(1971, month: nil, uncertain: false), "a single year, no Date Uncertain")
        XCTAssertEqual(inherited("Feb. 1970"), .year(1970, month: 2, uncertain: false), "the folder's month fills the Month")
        XCTAssertEqual(inherited("1965-1967"), .year(1966, month: nil, uncertain: true), "D14: the mid-point year")
        XCTAssertEqual(inherited("1971-1972"), .year(1971, month: nil, uncertain: true), "an even span: the earlier middle")
        XCTAssertEqual(inherited("1971-1974"), .year(1972, month: nil, uncertain: true))
        XCTAssertEqual(inherited("1970-1976"), .year(1973, month: nil, uncertain: true), "7 years is still a mid-point")
        XCTAssertEqual(inherited("1970-1977"), .decade(1970), "8 years: the decade")
        XCTAssertEqual(inherited("1958-1969"), .decade(1960), "the decade holding most of its years")
        XCTAssertEqual(inherited("1965-1974"), .decade(1960), "a tie goes to the earlier decade")
        XCTAssertEqual(inherited("1960s"), .decade(1960))
        XCTAssertEqual(inherited("1950-1968"), .decade(1950), "19 years: still a decade")
        XCTAssertNil(inherited("1950-1969"), "20 years or more: no tag")
        XCTAssertNil(inherited("1939- 78"))
    }

    private func run(_ start: String, _ level: ContainerLevel, date: ContainerValue? = nil) -> ContainerRun {
        ContainerRun(start: start, level: level, fields: ContainerFieldSet(date.map { [.date: $0] } ?? [:]))
    }

    func testOnlyTheLiveFolderRunsConfirmedDateDates() {
        let user = ContainerValue("1965-1967", source: .user)
        let confirmed = ContainerValue("1971", source: .label, reader: "gpt-5.6-luna").confirmed()
        let read = ContainerValue("1980", source: .label, reader: "vision+parser")
        let runs = [run("0001", .box, date: ContainerValue("1950", source: .user)),
                    run("0002", .folder, date: user), run("0005", .folder, date: read),
                    run("0008", .folder, date: confirmed), run("0010", .folder),
                    run("0012", .box), run("0014", .folder, date: ContainerValue("", source: .user))]
        func at(_ f: String) -> String? { ContainerFolderDate.confirmed(at: f, in: runs)?.text }
        XCTAssertNil(at("0001"), "a box run's date dates nothing")
        XCTAssertNil(at("0002"), "the folder photo itself is a label")
        XCTAssertEqual(at("0003"), "1965-1967")
        XCTAssertEqual(ContainerFolderDate.confirmed(at: "0004", in: runs)?.start, "0002")
        XCTAssertNil(at("0006"), "a label read nobody confirmed dates nothing")
        XCTAssertEqual(at("0009"), "1971", "a confirmed read is the user's")
        XCTAssertNil(at("0011"), "a folder with no date ends the earlier folder's")
        XCTAssertNil(at("0013"), "a new box ends the folder run")
        XCTAssertNil(at("0015"), "the user's \"none here\"")
        XCTAssertNil(ContainerFolderDate.confirmed(at: "0003", in: []))
    }
}
