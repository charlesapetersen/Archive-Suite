import XCTest
@testable import ArchiveReader

/// Tests for the read-only tag-facet parser, keyed to REAL tag arrays from the corpus.
final class DocumentTagsTests: XCTestCase {

    // Real file 03063 IMG — Brown.pdf
    func testParsesRealDocumentTags() {
        let raw = ["DP chapters", "Unread", "Jerry Brown", "01 January", "1983", "P9", "Speeches", "NCII"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.year, 1983)
        XCTAssertEqual(t.month?.number, 1)
        XCTAssertEqual(t.month?.name, "January")
        XCTAssertEqual(t.priority, 9)
        XCTAssertEqual(t.readState, .unread)
        XCTAssertNil(t.color)
        XCTAssertFalse(t.dateIsSpeculative)
        XCTAssertEqual(t.sortDate, 19_830_100)
        XCTAssertEqual(Set(t.subjects), ["DP chapters", "Jerry Brown", "Speeches", "NCII"])
    }

    // Real box marker 00001: Red label + "Red" token, no date/priority.
    func testBoxMarkerFoldsColorAndIsUndated() {
        let raw = ["Red", "Unread", "DP chapters", "Jerry Brown"]
        let t = DocumentTags.parse(raw: raw, labelNumber: 6)
        XCTAssertEqual(t.color, .box)
        XCTAssertNil(t.year)
        XCTAssertNil(t.priority)
        XCTAssertEqual(t.readState, .unread)
        XCTAssertFalse(t.subjects.contains("Red"))  // color token, not a subject
        XCTAssertEqual(Set(t.subjects), ["DP chapters", "Jerry Brown"])
        XCTAssertNil(t.sortDate)                     // undated → sorts last
    }

    func testDayTagAndSpeculativeDate() {
        let raw = ["1215", "05 May", "Day 25", "Date Uncertain", "Crusades"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.year, 1215)                 // medieval-safe: no epoch limit
        XCTAssertEqual(t.month?.number, 5)
        XCTAssertEqual(t.day, 25)
        XCTAssertTrue(t.dateUncertain)
        XCTAssertTrue(t.dateIsSpeculative)
        XCTAssertEqual(t.sortDate, 12_150_525)
        XCTAssertEqual(t.subjects, ["Crusades"])
    }

    // A subject literally "Red" with NO red label must stay a subject (no color inference).
    func testSubjectNamedRedWithoutLabelStaysSubject() {
        let raw = ["Red", "Cold War", "1950", "Unread"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertNil(t.color)
        XCTAssertTrue(t.subjects.contains("Red"))
        XCTAssertEqual(t.year, 1950)
    }

    // Read-state matching is exact whole-string — a subject "Read later" must NOT be seen as Read.
    func testReadStateIsExactWholeStringMatch() {
        let raw = ["Read later", "Unread", "1970"]
        let t = DocumentTags.parse(raw: raw, labelNumber: nil)
        XCTAssertEqual(t.readState, .unread)
        XCTAssertTrue(t.subjects.contains("Read later"))
    }

    // "P7" as priority, not a subject; but a 3–4 digit numeric subject can collide with year (display-only).
    func testPriorityParsing() {
        XCTAssertEqual(DocumentTags.parsePriority("P10"), 10)
        XCTAssertEqual(DocumentTags.parsePriority("p7"), 7)
        XCTAssertNil(DocumentTags.parsePriority("P6"))
        XCTAssertNil(DocumentTags.parsePriority("Proposal"))
    }

    func testRawArrayIsPreservedVerbatim() {
        let raw = ["Red", "Unread", "DP chapters", "Jerry Brown"]
        let t = DocumentTags.parse(raw: raw, labelNumber: 6)
        XCTAssertEqual(t.raw, raw)  // never reordered or mutated
    }
}

/// Tests for file-link formatting / percent-encoding.
final class FileLinkTests: XCTestCase {

    func testFileURLPercentEncodesEmDashAndSpaces() {
        let url = URL(fileURLWithPath: "/Users/<user>/Archive/00001 — Brown.pdf")
        let f = FileLinkFormatter(format: .fileURL)
        let s = f.line(for: url)
        XCTAssertTrue(s.hasPrefix("file:///"))
        XCTAssertTrue(s.contains("%20"))        // space
        XCTAssertTrue(s.contains("%E2%80%94"))  // em dash U+2014
        XCTAssertFalse(s.contains(" "))
    }

    func testPosixPathIsUnencoded() {
        let url = URL(fileURLWithPath: "/Users/<user>/Archive/00001 — Brown.pdf")
        let f = FileLinkFormatter(format: .posixPath)
        XCTAssertEqual(f.line(for: url), "/Users/<user>/Archive/00001 — Brown.pdf")
    }

    func testMarkdownUsesNameAndEncodedURL() {
        let url = URL(fileURLWithPath: "/Users/<user>/Archive/00001 — Brown.pdf")
        let f = FileLinkFormatter(format: .markdown)
        let s = f.line(for: url)
        XCTAssertTrue(s.hasPrefix("[00001 — Brown]("))
        XCTAssertTrue(s.contains("%E2%80%94"))
    }

    func testGroupClipboardJoinsWithConfiguredBlankLines() {
        let urls = [
            URL(fileURLWithPath: "/a/one.pdf"),
            URL(fileURLWithPath: "/a/two.pdf"),
        ]
        let f = FileLinkFormatter(format: .posixPath, newlinesBetweenLinks: 1)
        XCTAssertEqual(f.clipboardString(for: urls), "/a/one.pdf\n\n/a/two.pdf")
    }
}
