import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

/// W6-S3: pure item-list cell rendering (`ItemSummary` display helpers).
struct ItemSummaryDisplayTests {

    private func sum(date: String?, precision: Item.DatePrecision?, uncertain: Bool = false,
                     quality: Int? = nil, managedTags: [String] = []) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: UUID(), title: "T", kind: .note, date: date, datePrecision: precision,
                           dateUncertain: uncertain, authors: [], sortDate: nil, quality: quality,
                           created: t, modified: t, mtime: 0, managedTags: managedTags)
    }

    // MARK: displayDate

    @Test func decadeRendersWithSuffix() {
        #expect(sum(date: "1970", precision: .decade).displayDate == "1970s")
    }
    @Test func yearRendersVerbatim() {
        #expect(sum(date: "1970", precision: .year).displayDate == "1970")
        #expect(sum(date: "842", precision: .year).displayDate == "842")   // 3-digit medieval year
    }
    @Test func noPrecisionTreatedAsYear() {
        #expect(sum(date: "1970", precision: nil).displayDate == "1970")
    }
    @Test func monthRendersNameAndYear() {
        #expect(sum(date: "1970-03", precision: .month).displayDate == "Mar 1970")
    }
    @Test func dayRendersNameDayYear() {
        #expect(sum(date: "1970-03-05", precision: .day).displayDate == "Mar 5, 1970")
    }
    @Test func nilAndEmptyDateReturnNil() {
        #expect(sum(date: nil, precision: nil).displayDate == nil)
        #expect(sum(date: "", precision: .year).displayDate == nil)
    }
    @Test func corruptMonthDegradesToRawDate() {
        // Out-of-range / unparseable month → show the stored string rather than crash.
        #expect(sum(date: "1970-13", precision: .month).displayDate == "1970-13")
        #expect(sum(date: "1970", precision: .month).displayDate == "1970")
    }

    // MARK: qualityStars

    @Test func qualityStarsFilledAndEmpty() {
        #expect(sum(date: nil, precision: nil, quality: 4).qualityStars == "★★★★☆")
        #expect(sum(date: nil, precision: nil, quality: 5).qualityStars == "★★★★★")
        #expect(sum(date: nil, precision: nil, quality: 1).qualityStars == "★☆☆☆☆")
    }
    @Test func qualityStarsUnratedAndClamped() {
        #expect(sum(date: nil, precision: nil, quality: nil).qualityStars == "—")
        #expect(sum(date: nil, precision: nil, quality: 0).qualityStars == "—")    // guard q >= 1
        #expect(sum(date: nil, precision: nil, quality: 9).qualityStars == "★★★★★") // clamp to 5
    }

    // MARK: displayTags

    @Test func displayTagsHidesArchiveSuiteMarker() {
        let s = sum(date: nil, precision: nil,
                    managedTags: ["History", ArchiveSuiteMarker.tagName, "Letters"])
        #expect(s.displayTags == "History, Letters")
    }
    @Test func displayTagsEmptyWhenOnlyMarker() {
        #expect(sum(date: nil, precision: nil, managedTags: [ArchiveSuiteMarker.tagName]).displayTags == "")
        #expect(sum(date: nil, precision: nil, managedTags: []).displayTags == "")
    }
}
