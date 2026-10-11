import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W24.cal1-reader: the Date column in a document's display calendar, and the app-side store of each
/// document's choice. Display only — the tags, the sort key and the year filter keep the stored date.
@MainActor
final class DisplayCalendarReaderTests: XCTestCase {

    private func file(_ name: String, _ tags: [String]) -> ArchiveFile {
        ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name)"), name: name, fileType: "PDF",
                    tags: DocumentTags.parse(raw: tags, labelNumber: nil), contentModified: nil)
    }

    private let cutoverEve = ["1752", "09 September", "Day 13"]   // Gregorian 1752-09-13

    func testNoCalendarOrStandardIsExactlyTheStoredText() {
        for tags in [cutoverEve, ["1957", "11 November", "Day 3", "Sent With 1958-03-12"], ["1957"], []] {
            let f = file("f.pdf", tags)
            XCTAssertEqual(f.dateCellText(in: nil), f.dateCellText)
            XCTAssertEqual(f.dateCellText(in: .standard), f.dateCellText)
            XCTAssertNil(f.storedDateTooltip(in: .standard))
        }
    }

    func testJulianDayIsConvertedAndMarkedOldStyle() {
        let f = file("f.pdf", cutoverEve)
        XCTAssertEqual(f.dateCellText, "Sep 13, 1752")
        XCTAssertEqual(f.dateCellText(in: .julianEnglish1752), "2 September 1752 (O.S.)")
        XCTAssertEqual(f.dateCellText(in: .julian), "2 September 1752 (O.S.)")
        XCTAssertEqual(f.storedDateTooltip(in: .julian), "Stored as 1752-09-13")
        XCTAssertEqual(file("g.pdf", ["1752", "09 September", "Day 14"]).dateCellText(in: .julianEnglish1752),
                       "14 September 1752", "from the English cutover the day is New Style, unmarked")
    }

    func testOnlyDayPrecisionConverts() {
        for tags in [["1752"], ["1752", "09 September"], ["1750s"]] {
            let f = file("f.pdf", tags)
            XCTAssertEqual(f.dateCellText(in: .julian), f.dateCellText, "\(tags) stays as stored")
            XCTAssertNil(f.storedDateTooltip(in: .julian))
        }
    }

    func testSentWithDayConvertsAndKeepsItsLabel() {
        let enclosure = file("e.pdf", ["1957", "Sent With 1792-09-22"])
        XCTAssertEqual(enclosure.dateCellText(in: .frenchRepublican), "1957 \u{b7} sent 1 Vendémiaire An I")
        XCTAssertEqual(enclosure.storedDateTooltip(in: .frenchRepublican), "Sent with, stored as 1792-09-22")
        let sentOnly = file("s.pdf", ["Sent With 1792-09-22"])
        XCTAssertEqual(sentOnly.dateCellText(in: .frenchRepublican), "Sent with 1 Vendémiaire An I")
    }

    func testADayBeforeTheCalendarsEpochStaysStored() {
        let f = file("f.pdf", ["1792", "09 September", "Day 21"])
        XCTAssertEqual(f.dateCellText(in: .frenchRepublican), f.dateCellText)
        XCTAssertNil(f.storedDateTooltip(in: .frenchRepublican))
    }

    func testConversionLeavesSortAndFilterOnTheStoredDate() {
        let f = file("f.pdf", cutoverEve)
        let sortBefore = f.sortDate
        _ = f.dateCellText(in: .hebrew)
        XCTAssertEqual(f.sortDate, sortBefore)
        XCTAssertTrue(LibraryFilter(dateFromYear: 1752, dateToYear: 1752).matches(f))
    }

    // MARK: The per-document store

    private func scratchDefaults() -> UserDefaults {
        let name = "DisplayCalendarReaderTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testChoiceRoundTripsAcrossInstancesAndIsPerArchive() {
        let d = scratchDefaults()
        let root = UUID(), other = UUID()
        DisplayCalendarPreferences(defaults: d).set(.hebrew, rootGUID: root, relativePath: "Box 1/a.pdf")
        let reread = DisplayCalendarPreferences(defaults: d)
        XCTAssertEqual(reread.calendar(rootGUID: root, relativePath: "Box 1/a.pdf"), .hebrew)
        XCTAssertEqual(reread.calendar(rootGUID: root, relativePath: "Box 1/b.pdf"), .standard)
        XCTAssertEqual(reread.calendar(rootGUID: other, relativePath: "Box 1/a.pdf"), .standard)
    }

    func testStandardRemovesTheEntryAndAnUnknownValueReadsAsStandard() {
        let d = scratchDefaults()
        let root = UUID()
        let prefs = DisplayCalendarPreferences(defaults: d)
        prefs.set(.julian, rootGUID: root, relativePath: "a.pdf")
        XCTAssertNotNil(d.dictionary(forKey: DisplayCalendarPreferences.key))
        prefs.set(.standard, rootGUID: root, relativePath: "a.pdf")
        XCTAssertNil(d.object(forKey: DisplayCalendarPreferences.key), "as-stored leaves nothing behind")

        d.set(["\(root.uuidString.lowercased())/a.pdf": "mayan"], forKey: DisplayCalendarPreferences.key)
        XCTAssertEqual(DisplayCalendarPreferences(defaults: d).calendar(rootGUID: root, relativePath: "a.pdf"),
                       .standard)
    }

    func testSwitchIsOffByDefault() {
        let d = scratchDefaults()
        XCTAssertFalse(DisplayCalendarSettings.isEnabled(d))
        d.set(true, forKey: DisplayCalendarSettings.enabledKey)
        XCTAssertTrue(DisplayCalendarSettings.isEnabled(d))
    }
}
