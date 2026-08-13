import XCTest
@testable import ArchiveCore

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

    func testSetYearPreservesCollidingSubject() {
        let t = tags(["1984", "Jerry Brown", "1980"])
        XCTAssertEqual(t.year, 1980)
        XCTAssertEqual(t.yearToken, "1980")
        XCTAssertTrue(t.subjects.contains("1984"))
        let d = TagEditing.delta(for: .setYear(1982), given: t)
        XCTAssertEqual(d.add, ["1982"])
        XCTAssertEqual(d.remove, ["1980"])
    }

    func testSetYearNilClearsOnlyYearToken() {
        let t = tags(["1984", "1980", "Unread"])
        XCTAssertTrue(t.subjects.contains("1984"))
        let d = TagEditing.delta(for: .setYear(nil), given: t)
        XCTAssertTrue(d.add.isEmpty)
        XCTAssertEqual(d.remove, ["1980"])
    }

    func testSetPriorityPreservesCollidingSubject() {
        let t = tags(["P8", "Economics", "P9"])
        XCTAssertEqual(t.priority, 9)
        XCTAssertEqual(t.priorityToken, "P9")
        XCTAssertTrue(t.subjects.contains("P8"))
        let d = TagEditing.delta(for: .setPriority(10), given: t)
        XCTAssertEqual(d.add, ["P10"])
        XCTAssertEqual(d.remove, ["P9"])
    }

    // MARK: Quality edits (W19.q2) — the facet's only write primitive

    func testSetQualityWritesTheCanonicalTokenAndReplacesTheWinner() {
        let d = TagEditing.delta(for: .setQuality(3), given: tags(["Q1", "1980"]))
        XCTAssertEqual(d.add, ["Q3"])
        XCTAssertEqual(d.remove, ["Q1"])
    }

    // The owner-locked clause: unrated writes NO tag. A clear removes, and adds nothing.
    func testSetQualityNilClearsAndNeverWritesQ0() {
        let d = TagEditing.delta(for: .setQuality(nil), given: tags(["Q2", "Economics"]))
        XCTAssertTrue(d.add.isEmpty, "unrated is the absence of a token")
        XCTAssertEqual(d.remove, ["Q2"])

        // An off-scale value cannot become a token either — it degrades to a clear.
        XCTAssertTrue(TagEditing.delta(for: .setQuality(0), given: tags(["Q2"])).add.isEmpty)
        XCTAssertTrue(TagEditing.delta(for: .setQuality(4), given: tags(["Q2"])).add.isEmpty)
    }

    // Setting a rating on a legacy file RETIRES the P token instead of leaving two ratings on one file.
    func testSetQualityOnALegacyPriorityFileRetiresTheLegacyToken() {
        let d = TagEditing.delta(for: .setQuality(1), given: tags(["P10", "Economics"]))
        XCTAssertEqual(d.add, ["Q1"])
        XCTAssertEqual(d.remove, ["P10"], "one facet, one winner, whichever spelling it used")

        // Including the retired P7, which reads as unrated but is still the facet's token.
        let cleared = TagEditing.delta(for: .setQuality(nil), given: tags(["P7", "Economics"]))
        XCTAssertTrue(cleared.add.isEmpty)
        XCTAssertEqual(cleared.remove, ["P7"])
    }

    // R-1 for the new facet: a SUBJECT that merely parses as a rating is never destroyed.
    func testSetQualityPreservesCollidingSubject() {
        let t = tags(["Q1", "Economics", "Q3"])
        XCTAssertEqual(t.quality, 3)
        XCTAssertEqual(t.qualityToken, "Q3")
        XCTAssertTrue(t.subjects.contains("Q1"), "the shadowed token stays visible as a subject")
        let d = TagEditing.delta(for: .setQuality(2), given: t)
        XCTAssertEqual(d.add, ["Q2"])
        XCTAssertEqual(d.remove, ["Q3"], "only the consumed winner — never a facet predicate")
    }

    // The retired Priority cell cannot reach a canonical rating: `priorityToken` is P-only by construction.
    func testRetiredSetPriorityCannotRemoveACanonicalQualityToken() {
        let t = tags(["Q2", "Economics"])
        XCTAssertEqual(t.priority, 9, "it still READS as the old P9")
        XCTAssertNil(t.priorityToken)
        XCTAssertTrue(TagEditing.delta(for: .setPriority(nil), given: t).remove.isEmpty,
                      "the retired edit must not destroy a Quality rating it cannot see")
    }

    func testGroupSummaryReportsQualityAndTheRetiredView() {
        // `nil` = the selection disagrees; `.some(nil)` = they agree, and agree on UNRATED.
        let mixed = GroupTagSummary([tags(["Q1"]), tags(["P10"])])
        XCTAssertNil(mixed.commonQuality, "1 vs 3 — no common value")

        let agreeing = GroupTagSummary([tags(["Q3"]), tags(["P10", "Economics"])])
        XCTAssertEqual(agreeing.commonQuality, .some(3), "the two spellings are the same rating")
        XCTAssertEqual(agreeing.commonPriority, .some(10))

        let unrated = GroupTagSummary([tags(["P7"]), tags(["Economics"])])
        XCTAssertEqual(unrated.commonQuality, .some(nil), "P7 and no-token are both unrated")
    }

    func testSetMonthWithTwoMonthShapedTokens() {
        let t = tags(["03 March", "05 May", "1980"])
        XCTAssertEqual(t.month?.number, 5)
        XCTAssertEqual(t.monthToken, "05 May")
        XCTAssertTrue(t.subjects.contains("03 March"))
        let d = TagEditing.delta(for: .setMonth(7), given: t)
        XCTAssertEqual(d.add, ["07 July"])
        XCTAssertEqual(d.remove, ["05 May"])
    }

    func testSetDayWithTwoDayShapedTokens() {
        let t = tags(["Day 3", "Day 25", "1980"])
        XCTAssertEqual(t.day, 25)
        XCTAssertEqual(t.dayToken, "Day 25")
        XCTAssertTrue(t.subjects.contains("Day 3"))
        let d = TagEditing.delta(for: .setDay(10), given: t)
        XCTAssertEqual(d.add, ["Day 10"])
        XCTAssertEqual(d.remove, ["Day 25"])
    }

    func testSingleFacetDocEditsUnchanged() {
        let t = tags(["1980", "03 March", "Day 5", "P9", "Unread", "Jerry Brown"])
        XCTAssertEqual(TagEditing.delta(for: .setYear(1982), given: t).remove, ["1980"])
        XCTAssertEqual(TagEditing.delta(for: .setMonth(5), given: t).remove, ["03 March"])
        XCTAssertEqual(TagEditing.delta(for: .setDay(6), given: t).remove, ["Day 5"])
        XCTAssertEqual(TagEditing.delta(for: .setPriority(10), given: t).remove, ["P9"])
        XCTAssertTrue(TagEditing.delta(for: .setYear(nil), given: tags(["Jerry Brown", "Unread"])).remove.isEmpty)
    }

    // MARK: Decade reconcile — year supersedes decade

    func testSetYearRemovesDecade() {
        let t = tags(["1970s", "Economics", "Unread"])
        XCTAssertEqual(t.decade, 1970)
        XCTAssertEqual(t.decadeToken, "1970s")
        let d = TagEditing.delta(for: .setYear(1975), given: t)
        XCTAssertEqual(d.add, ["1975"])
        XCTAssertEqual(d.remove, ["1970s"])
    }

    func testClearYearAlsoRemovesDecade() {
        let t = tags(["1970s", "Economics"])
        let d = TagEditing.delta(for: .setYear(nil), given: t)
        XCTAssertTrue(d.add.isEmpty)
        XCTAssertEqual(d.remove, ["1970s"])
    }

    func testSetYearOnFileWithBothYearAndDecade() {
        let t = tags(["1970s", "1975", "Economics"])
        XCTAssertEqual(t.yearToken, "1975")
        XCTAssertEqual(t.decadeToken, "1970s")
        let d = TagEditing.delta(for: .setYear(1982), given: t)
        XCTAssertEqual(d.add, ["1982"])
        XCTAssertEqual(Set(d.remove), ["1975", "1970s"])
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
        XCTAssertNil(s.commonYear)
        XCTAssertEqual(s.commonReadState, .some(.some(.unread)))
    }
}
