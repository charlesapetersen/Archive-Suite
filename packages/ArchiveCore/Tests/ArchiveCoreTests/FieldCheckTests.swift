import XCTest
@testable import ArchiveCore

/// W40.reader-field-status: the `Checked <Field>` tags, the edits that write them, and the measured status table.
final class FieldCheckTests: XCTestCase {
    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }

    func testCheckTokensParseAsChecksNotSubjects() {
        let t = tags(["1958", "Checked Date", " Checked Publication ", "checked byline", "Checked", "Checked Dates",
                      "Lincoln"])
        XCTAssertEqual(t.checkedFields, [.date, .publication, .byline])
        XCTAssertEqual(t.subjects, ["Checked", "Checked Dates", "Lincoln"])
        XCTAssertFalse(t.topicalTags.contains { CheckableField(token: $0) != nil })
        XCTAssertEqual(t.year, 1958)
        XCTAssertEqual(t.raw.count, 7, "the raw array is untouched")
    }

    func testEveryFieldRoundTripsThroughItsToken() {
        for f in CheckableField.allCases {
            XCTAssertEqual(CheckableField(token: f.token), f)
            XCTAssertEqual(tags([f.token]).checkedFields, [f])
        }
    }

    func testMarkAndUncheckWriteOnlyTheCheck() {
        let t = tags(["1958", "Lincoln"])
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.date, true), given: t), TagDelta(add: ["Checked Date"]))
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.publication, true), given: t),
                       TagDelta(add: ["Checked Publication"]))
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.publication, false), given: t), TagDelta())
        let c = tags(["1958", "checked publication", "Lincoln"])
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.publication, true), given: c), TagDelta())
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.publication, false), given: c),
                       TagDelta(remove: ["checked publication"]))
    }

    func testADateIsCheckedOnlyWhereThereIsOne() {
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.date, true), given: tags(["Lincoln"])), TagDelta())
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.date, true), given: tags(["1950s"])),
                       TagDelta(add: ["Checked Date"]))
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.sentWith, true), given: tags(["1958"])), TagDelta())
        // Unchecking a stray check on an undated file still removes it.
        XCTAssertEqual(TagEditing.delta(for: .setChecked(.date, false), given: tags(["Checked Date"])),
                       TagDelta(remove: ["Checked Date"]))
    }

    func testAUserDateEditChecksTheDate() {
        let t = tags(["1958", "Lincoln"])
        let d = TagEditing.userDelta(for: .setDate(ArchiveDate(year: 1959)!), given: t)
        XCTAssertEqual(Set(d.add), ["1959", "Checked Date"])
        XCTAssertEqual(d.remove, ["1958"])
        // Already checked: the check is not added twice.
        let c = tags(["1958", "Checked Date"])
        XCTAssertEqual(TagEditing.userDelta(for: .setDate(ArchiveDate(year: 1959)!), given: c).add, ["1959"])
        // Marking it uncertain takes the check back; marking it certain checks it.
        XCTAssertEqual(TagEditing.userDelta(for: .setDateUncertain(true), given: c),
                       TagDelta(add: ["Date Uncertain"], remove: ["Checked Date"]))
        XCTAssertEqual(TagEditing.userDelta(for: .setDateUncertain(true), given: t), TagDelta(add: ["Date Uncertain"]))
        XCTAssertEqual(Set(TagEditing.userDelta(for: .setDateUncertain(false), given: tags(["1958", "Date Uncertain"])).remove),
                       ["Date Uncertain"])
        XCTAssertEqual(TagEditing.userDelta(for: .setDateUncertain(false), given: tags(["1958", "Date Uncertain"])).add,
                       ["Checked Date"])
    }

    func testClearingADateRemovesItsCheck() {
        let c = tags(["1958", "Checked Date", "Lincoln"])
        let d = TagEditing.userDelta(for: .setDate(nil), given: c)
        XCTAssertEqual(Set(d.remove), ["1958", "Checked Date"])
        XCTAssertTrue(d.add.isEmpty)
    }

    func testAnEditThatWritesNothingChecksNothing() {
        let t = tags(["1958"])
        XCTAssertEqual(TagEditing.userDelta(for: .setDate(ArchiveDate(year: 1958)!), given: t), TagDelta())
        XCTAssertEqual(TagEditing.userDelta(for: .setDateUncertain(false), given: t), TagDelta())
        // The uncertain flag on a file with no date is not a check of a date.
        XCTAssertEqual(TagEditing.userDelta(for: .setDateUncertain(true), given: tags([])).add, ["Date Uncertain"])
    }

    func testSentWithEditsCheckTheSentWithDateOnly() {
        let t = tags(["1958"])
        let d = TagEditing.userDelta(for: .setSentWith(ArchiveDate(year: 1957, month: 3)!), given: t)
        XCTAssertEqual(Set(d.add), [SentWithTag.token(for: ArchiveDate(year: 1957, month: 3)!), "Checked Sent With"])
        let c = tags(["1958", "Checked Date", "Sent With 1957-03", "Checked Sent With"])
        XCTAssertEqual(Set(TagEditing.userDelta(for: .setSentWith(nil), given: c).remove),
                       ["Sent With 1957-03", "Checked Sent With"])
    }

    func testThePlainDeltaNeverChecks() {
        let t = tags(["1958"])
        XCTAssertEqual(TagEditing.delta(for: .setDate(ArchiveDate(year: 1959)!), given: t),
                       TagDelta(add: ["1959"], remove: ["1958"]))
    }

    func testOtherEditsLeaveChecksAlone() {
        let c = tags(["1958", "Checked Date", "Lincoln"])
        XCTAssertEqual(TagEditing.userDelta(for: .addSubject("Truman"), given: c), TagDelta(add: ["Truman"]))
        XCTAssertEqual(TagEditing.userDelta(for: .setQuality(2), given: c), TagDelta(add: ["Q2"]))
    }

    // MARK: The status table

    func testItemFieldsThatFillAreUncheckedNotLower() {
        for f in [CheckableField.documentKind, .title, .byline, .publication, .publicationDate, .recipientPlace] {
            XCTAssertEqual(FieldStatusPolicy.itemField(f, checked: false).level, .unchecked, "\(f)")
            XCTAssertEqual(FieldStatusPolicy.itemField(f, checked: true).level, .checked, "\(f)")
        }
    }

    func testNoDateClassClearsTheRule() {
        for evidence in [nil, "image; page 1; top right; \"1958\"", "estimate; from a.pdf; line 3; \"x\"",
                         "inherited; from a.pdf", "stamp; page 1; stamp; \"MAY 2 1960\"",
                         "folder; from 0012.pdf; \"1965-1967\"", "something new"] {
            XCTAssertEqual(FieldStatusPolicy.date(checked: false, evidence: evidence).level, .lowerConfidence)
            XCTAssertEqual(FieldStatusPolicy.date(checked: true, evidence: evidence).level, .checked)
        }
        XCTAssertTrue(FieldStatusPolicy.date(checked: false, evidence: "Image; page 1").source.contains("image"))
        XCTAssertTrue(FieldStatusPolicy.date(checked: false, evidence: "stamp; page 1").source.contains("stamp"))
        XCTAssertTrue(FieldStatusPolicy.date(checked: false, evidence: "folder; from a.pdf").source.contains("folder’s confirmed date"))
        XCTAssertEqual(FieldStatusPolicy.sentWith(checked: false).level, .lowerConfidence)
    }

    /// W46.p17-folder-date-forms: a folder-dated document carries the figure of the form the rule wrote.
    func testFolderDateFigureFollowsTheWrittenForm() {
        func measured(_ e: String?) -> String { FieldStatusPolicy.date(checked: false, evidence: e).measured }
        XCTAssertTrue(measured("folder; from 00012.pdf; \"Feb. 1970\"").contains("13 of 14"))
        XCTAssertTrue(measured("folder; from the folder; \"1965-1967\"").contains("20 of 42"))
        XCTAssertTrue(measured("folder; from 0001.pdf; \"1958-1969\"").contains("not measured"))
        XCTAssertTrue(measured("folder; from 0001.pdf; \"1958-1969\"; gave 1960s, Date Uncertain").contains("not measured"))
        XCTAssertTrue(measured("folder; from 00012.pdf; \"Feb. 1970\"; gave 1970-02").contains("13 of 14"))
        XCTAssertTrue(measured("folder; from a.pdf").contains("33 of 56"))
        XCTAssertTrue(measured("folder; from a.pdf; \"1900-1950\"").contains("33 of 56"))
        XCTAssertEqual(FieldStatusPolicy.date(checked: true, evidence: "folder; from a.pdf; \"1965-1967\"").measured, "")
    }

    func testContainerValuesMapByTheirSource() {
        func level(_ v: ContainerValue, _ f: ContainerField = .container, _ l: ContainerLevel? = .box) -> FieldCheckLevel {
            FieldStatusPolicy.container(v, field: f, level: l).level
        }
        XCTAssertEqual(level(ContainerValue("Box 3", source: .user)), .checked)
        let label = FieldStatusPolicy.container(ContainerValue("Box 3", source: .label, reader: "gpt-5.6-luna",
                                                               confidence: 0.97), field: .container, level: .box)
        XCTAssertEqual(label.level, .lowerConfidence, "a reader's own confidence is a hint, never a rank")
        XCTAssertTrue(label.source.contains("gpt-5.6-luna"))
        XCTAssertTrue(label.measured.contains("0.97"))
        // The one label read that clears the rule: Vision + parser's box number off a box photo.
        XCTAssertEqual(level(ContainerValue("3", source: .label, reader: "vision+parser")), .unchecked)
        XCTAssertEqual(level(ContainerValue("3", source: .label, reader: "vision+parser"), .container, .folder),
                       .lowerConfidence, "a box number off a folder photo is 28 of 35")
        XCTAssertEqual(level(ContainerValue("3", source: .label, reader: "vision+parser"), .folder, .folder),
                       .lowerConfidence)
        XCTAssertEqual(level(ContainerValue("3", source: .path)), .lowerConfidence)
        // Confirming a label read checks it.
        XCTAssertEqual(level(ContainerValue("Box 3", source: .label).confirmed()), .checked)
    }

    func testEveryLevelHasItsOwnLabelAndShape() {
        XCTAssertEqual(Set(FieldCheckLevel.allCases.map(\.label)).count, 3)
        XCTAssertEqual(Set(FieldCheckLevel.allCases.map(\.symbol)).count, 3)
    }

    func testItemFieldValuesComeFromTheHeader() {
        let f = PDFItemFields(documentKind: "letter", publication: "  ", recipientPlace: "Boston")
        XCTAssertEqual(CheckableField.documentKind.value(in: f), "letter")
        XCTAssertNil(CheckableField.publication.value(in: f), "a blank line is no value")
        XCTAssertEqual(CheckableField.recipientPlace.value(in: f), "Boston")
        XCTAssertNil(CheckableField.date.value(in: f))
    }
}
