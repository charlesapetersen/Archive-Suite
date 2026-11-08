import XCTest
import ArchiveCore
@testable import ArchiveReader

final class TagChangeStatusTests: XCTestCase {
    private func result(_ before: [String], _ after: [String], name: String = "letter.pdf",
                        labels: (Int?, Int?) = (nil, nil)) -> TagWriteResult {
        TagWriteResult(url: URL(fileURLWithPath: "/scratch/\(name)"), before: before, after: after,
                       beforeLabel: labels.0, afterLabel: labels.1, inverse: TagDelta())
    }

    func testNamesEveryChangedFieldIncludingAStandaloneMonthAndClearedValues() {
        let r = result(["1984", "03 March", "Day 25", "Q3", "Date Uncertain", "Sent With 1958-03-12"],
                       ["1980", "04 April", "Q1", "Sent With Date Uncertain"])
        let status = TagChangeStatus.reversal([r], redo: false)
        XCTAssertTrue(status.hasPrefix("Undid 1 change in letter.pdf:"), status)
        for detail in ["Year: “1984” → “1980”", "Month: “03 March” → “04 April”", "Day: “Day 25” → none",
                       "Quality: “Q3” → “Q1”", "Date uncertain: “Date Uncertain” → none",
                       "Sent with: “Sent With 1958-03-12” → none",
                       "Sent with uncertain: none → “Sent With Date Uncertain”"] {
            XCTAssertTrue(status.contains(detail), status)
        }
        XCTAssertTrue(TagChangeStatus.reversal([result(["03 March"], ["04 April"])], redo: true)
            .contains("Month: “03 March” → “04 April”"))
    }

    func testSubjectDeltaPreservesOccurrenceCountsCaseAndUnrelatedSubjects() {
        let status = TagChangeStatus.reversal([result(["A", "A", "B", "Keep"], ["A", "b", "Keep"])], redo: false)
        XCTAssertEqual(status, "Undid 1 change in letter.pdf: Subjects: removed “A”, “B”, added “b”")
    }

    func testColorUsesActualLabelAndKeepsAnUnlabelledRedSubjectDistinct() {
        let status = TagChangeStatus.reversal([result(["Red"], ["Purple"], labels: (6, 3))], redo: false)
        XCTAssertTrue(status.contains("Color: Red → Purple"), status)
        XCTAssertTrue(status.contains("Color tags: “Red” → “Purple”"), status)
        XCTAssertFalse(status.contains("Subjects"), status)
        XCTAssertEqual(TagChangeStatus.reversal([result(["Red"], [])], redo: false),
                       "Undid 1 change in letter.pdf: Subjects: removed “Red”")
        XCTAssertTrue(TagChangeStatus.reversal([result([], [], labels: (nil, 2))], redo: true)
            .contains("Color: none → Finder label 2"))
    }

    func testGroupCountsDistinctFilesAndGroupsTheirActualTransitions() {
        let results = [result(["Read"], ["Unread"], name: "a.pdf"),
                       result(["Read"], ["Unread"], name: "b.pdf"),
                       result(["Read", "X"], ["Read"], name: "c.pdf"),
                       result(["Read"], ["Read"], name: "no-op.pdf")]
        XCTAssertEqual(TagChangeStatus.reversal(results, redo: false),
                       "Undid 3 changes in 3 files: Read state: “Read” → “Unread” (2 files); Subjects: removed “X” (1 file)")
    }

    func testSuccessiveWritesToOneFileDescribeTheNetChange() {
        let results = [result(["1984"], ["1982"]), result(["1982"], ["1980"])]
        XCTAssertEqual(TagChangeStatus.reversal(results, redo: true),
                       "Redid 2 changes in letter.pdf: Year: “1984” → “1980”")
        XCTAssertEqual(TagChangeStatus.reversal([result(["A"], ["B"]), result(["B"], ["A"])], redo: false),
                       "Undid 2 changes in letter.pdf: no net tag change")
    }

    func testAmbiguousDateTokensAreNotLostInAParsedWinner() {
        XCTAssertTrue(TagChangeStatus.reversal([result(["1980", "1984"], ["1980"])], redo: false)
            .contains("Year: “1980”, “1984” → “1980”"))
    }

    func testAnExternalEditBetweenTwoWritesIsNeverClaimedByUndo() {
        let results = [result(["Read", "A"], ["Unread", "A"]),
                       result(["Unread", "A", "External"], ["Unread", "External"])]
        XCTAssertEqual(TagChangeStatus.reversal(results, redo: false),
                       "Undid 2 changes in letter.pdf: Read state: “Read” → “Unread”; then Subjects: removed “A”")
        let labels = [result([], [], labels: (6, 3)), result([], ["X"], labels: (4, 4))]
        let status = TagChangeStatus.reversal(labels, redo: true)
        XCTAssertTrue(status.contains("Color: Red → Purple"), status)
        XCTAssertFalse(status.contains("Finder label 4"), "the external label change was not redone: \(status)")
    }
}
