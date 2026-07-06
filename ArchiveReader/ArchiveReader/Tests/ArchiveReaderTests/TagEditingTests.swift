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
}
