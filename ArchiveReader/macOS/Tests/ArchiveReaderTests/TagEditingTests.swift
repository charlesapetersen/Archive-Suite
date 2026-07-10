import XCTest
@testable import ArchiveReader

final class TagEditingTests: XCTestCase {

    private func tags(_ raw: [String], label: Int? = nil) -> DocumentTags {
        DocumentTags.parse(raw: raw, labelNumber: label)
    }

    // MARK: delta(for:given:)

    func testSetYearReplacesExisting() {
        let d = TagEditing.delta(for: .setYear(1982), given: tags(["1980", "Unread", "Jerry Brown"]))
        XCTAssertEqual(d.add, ["1982"])
        XCTAssertEqual(d.remove, ["1980"])
    }

    func testSetYearNilClears() {
        let d = TagEditing.delta(for: .setYear(nil), given: tags(["1980", "Unread"]))
        XCTAssertTrue(d.add.isEmpty)
        XCTAssertEqual(d.remove, ["1980"])
    }

    func testSetPriorityReplaces() {
        let d = TagEditing.delta(for: .setPriority(10), given: tags(["P9", "1980"]))
        XCTAssertEqual(d.add, ["P10"])
        XCTAssertEqual(d.remove, ["P9"])
    }

    func testMonthTokenFormat() {
        XCTAssertEqual(TagEditing.monthToken(3), "03 March")
        XCTAssertEqual(TagEditing.monthToken(11), "11 November")
    }

    func testSetMonthReplaces() {
        let d = TagEditing.delta(for: .setMonth(5), given: tags(["03 March", "1980"]))
        XCTAssertEqual(d.add, ["05 May"])
        XCTAssertEqual(d.remove, ["03 March"])
    }

    // MARK: R-1 regression — a facet edit removes ONLY the consumed token, never a colliding subject.
    //
    // Parser is "last one wins": the LAST token that parses as a single-valued facet is that facet's
    // value; every EARLIER matching token is demoted to a subject. A facet-replacing edit must remove
    // only the recorded consumed token, so a subject that merely parses as that facet survives.

    func testSetYearPreservesCollidingSubject() {
        // "1980" (last) is the real year; "1984" is a book/topic subject that merely looks like a year.
        let t = tags(["1984", "Jerry Brown", "1980"])
        XCTAssertEqual(t.year, 1980)
        XCTAssertEqual(t.yearToken, "1980")
        XCTAssertTrue(t.subjects.contains("1984"))          // shadowed year-shaped token kept as subject
        let d = TagEditing.delta(for: .setYear(1982), given: t)
        XCTAssertEqual(d.add, ["1982"])
        XCTAssertEqual(d.remove, ["1980"])                  // ONLY the real year — never the "1984" subject
    }

    func testSetYearNilClearsOnlyYearToken() {
        let t = tags(["1984", "1980", "Unread"])            // year=1980; "1984" is a subject
        XCTAssertTrue(t.subjects.contains("1984"))
        let d = TagEditing.delta(for: .setYear(nil), given: t)
        XCTAssertTrue(d.add.isEmpty)
        XCTAssertEqual(d.remove, ["1980"])                  // clears only the year, not the "1984" subject
    }

    func testSetPriorityPreservesCollidingSubject() {
        // "P9" (last) is the real priority; "P8" is a literal subject (e.g. a doc named "P8").
        let t = tags(["P8", "Economics", "P9"])
        XCTAssertEqual(t.priority, 9)
        XCTAssertEqual(t.priorityToken, "P9")
        XCTAssertTrue(t.subjects.contains("P8"))
        let d = TagEditing.delta(for: .setPriority(10), given: t)
        XCTAssertEqual(d.add, ["P10"])
        XCTAssertEqual(d.remove, ["P9"])                    // ONLY the real priority — never the "P8" subject
    }

    func testSetMonthWithTwoMonthShapedTokens() {
        let t = tags(["03 March", "05 May", "1980"])        // two month-shaped tokens; last wins
        XCTAssertEqual(t.month?.number, 5)
        XCTAssertEqual(t.monthToken, "05 May")
        XCTAssertTrue(t.subjects.contains("03 March"))
        let d = TagEditing.delta(for: .setMonth(7), given: t)
        XCTAssertEqual(d.add, ["07 July"])
        XCTAssertEqual(d.remove, ["05 May"])                // demoted "03 March" survives as a subject
    }

    func testSetDayWithTwoDayShapedTokens() {
        let t = tags(["Day 3", "Day 25", "1980"])           // two day-shaped tokens; last wins
        XCTAssertEqual(t.day, 25)
        XCTAssertEqual(t.dayToken, "Day 25")
        XCTAssertTrue(t.subjects.contains("Day 3"))
        let d = TagEditing.delta(for: .setDay(10), given: t)
        XCTAssertEqual(d.add, ["Day 10"])
        XCTAssertEqual(d.remove, ["Day 25"])                // demoted "Day 3" survives as a subject
    }

    func testSingleFacetDocEditsUnchanged() {
        // No collision → behaves exactly as before the fix (removes the one facet token, keeps the rest).
        let t = tags(["1980", "03 March", "Day 5", "P9", "Unread", "Jerry Brown"])
        XCTAssertEqual(TagEditing.delta(for: .setYear(1982), given: t).remove, ["1980"])
        XCTAssertEqual(TagEditing.delta(for: .setMonth(5), given: t).remove, ["03 March"])
        XCTAssertEqual(TagEditing.delta(for: .setDay(6), given: t).remove, ["Day 5"])
        XCTAssertEqual(TagEditing.delta(for: .setPriority(10), given: t).remove, ["P9"])
        XCTAssertTrue(TagEditing.delta(for: .setYear(nil), given: tags(["Jerry Brown", "Unread"])).remove.isEmpty)  // no year to clear
    }

    // MARK: Decade reconcile — year supersedes decade (no orphaned hidden decade)

    func testSetYearRemovesDecade() {
        // Setting a concrete year on a decade-only file removes the decade token.
        let t = tags(["1970s", "Economics", "Unread"])
        XCTAssertEqual(t.decade, 1970)
        XCTAssertEqual(t.decadeToken, "1970s")
        let d = TagEditing.delta(for: .setYear(1975), given: t)
        XCTAssertEqual(d.add, ["1975"])
        XCTAssertEqual(d.remove, ["1970s"])                      // decade removed, no orphan
    }

    func testClearYearAlsoRemovesDecade() {
        // "Clear" (setYear nil) on a decade file removes the decade too.
        let t = tags(["1970s", "Economics"])
        let d = TagEditing.delta(for: .setYear(nil), given: t)
        XCTAssertTrue(d.add.isEmpty)
        XCTAssertEqual(d.remove, ["1970s"])
    }

    func testSetYearOnFileWithBothYearAndDecade() {
        // A legacy file with both "1970s" and "1975" — setYear removes both tokens.
        let t = tags(["1970s", "1975", "Economics"])
        XCTAssertEqual(t.yearToken, "1975")
        XCTAssertEqual(t.decadeToken, "1970s")
        let d = TagEditing.delta(for: .setYear(1982), given: t)
        XCTAssertEqual(d.add, ["1982"])
        XCTAssertEqual(Set(d.remove), ["1975", "1970s"])         // both removed
    }

    func testAddAndRemoveSubject() {
        XCTAssertEqual(TagEditing.delta(for: .addSubject("Taxes"), given: tags(["1980"])).add, ["Taxes"])
        XCTAssertTrue(TagEditing.delta(for: .addSubject("   "), given: tags(["1980"])).isEmpty)
        XCTAssertEqual(TagEditing.delta(for: .removeSubject("Economics"), given: tags(["Economics", "1980"])).remove, ["Economics"])
    }

    func testSetDateUncertainTogglesIdempotently() {
        XCTAssertEqual(TagEditing.delta(for: .setDateUncertain(true), given: tags(["1980"])).add, ["Date Uncertain"])
        XCTAssertTrue(TagEditing.delta(for: .setDateUncertain(true), given: tags(["1980", "Date Uncertain"])).isEmpty)
        XCTAssertEqual(TagEditing.delta(for: .setDateUncertain(false), given: tags(["1980", "Date Uncertain"])).remove, ["Date Uncertain"])
    }

    func testSetColor() {
        XCTAssertEqual(TagEditing.delta(for: .setColor(.box), given: tags(["Unread"])).color, .set(.box))
        XCTAssertEqual(TagEditing.delta(for: .setColor(nil), given: tags(["Unread"])).color, .clear)
    }

    // MARK: GroupTagSummary

    func testGroupSummarySubjectsAndCommonFacets() {
        let a = tags(["Jerry Brown", "Economics", "1980", "Unread"])
        let b = tags(["Jerry Brown", "1980", "Unread"])
        let s = GroupTagSummary([a, b])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.subjectsOnAll, ["Jerry Brown"])
        XCTAssertEqual(s.subjectsOnSome, ["Economics"])
        XCTAssertEqual(s.commonYear, .some(.some(1980)))
        XCTAssertEqual(s.commonReadState, .some(.some(.unread)))
    }

    func testGroupSummaryMixedYearIsNil() {
        let s = GroupTagSummary([tags(["1975", "Unread"]), tags(["1980", "Unread"])])
        XCTAssertNil(s.commonYear)                    // mixed
        XCTAssertEqual(s.commonReadState, .some(.some(.unread)))
    }

    // MARK: On-disk integration (temp file, never the corpus)

    func testApplySetYearOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: url)
        try (url as NSURL).setResourceValue(["1980", "Unread", "Jerry Brown"], forKey: .tagNamesKey)

        let current = TagReading.readTags(url)!
        _ = try TagWriter.apply(TagEditing.delta(for: .setYear(1982), given: current), to: url)

        let after = Set((try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        XCTAssertEqual(after, ["1982", "Unread", "Jerry Brown"])   // year replaced, everything else kept
    }

    // R-1: an on-disk edit of a real year must NOT destroy a subject that merely parses as a year.
    func testApplySetYearPreservesCollidingSubjectOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: url)
        // "1980" (last) is the real year; "1984" is a book-title subject.
        try (url as NSURL).setResourceValue(["1984", "Jerry Brown", "1980"], forKey: .tagNamesKey)

        let current = TagReading.readTags(url)!
        _ = try TagWriter.apply(TagEditing.delta(for: .setYear(1982), given: current), to: url)

        let after = Set((try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        XCTAssertEqual(after, ["1984", "Jerry Brown", "1982"])   // real year swapped; "1984" subject SURVIVES
    }
}
