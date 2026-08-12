import XCTest
@testable import ArchiveReader

/// Tests for file-link formatting / percent-encoding.
final class FileLinkTests: XCTestCase {

    func testFileURLPercentEncodesEmDashAndSpaces() {
        let url = URL(fileURLWithPath: "/Users/archivist/Archive/00001 — Brown.pdf")
        let f = FileLinkFormatter(format: .fileURL)
        let s = f.line(for: url)
        XCTAssertTrue(s.hasPrefix("file:///"))
        XCTAssertTrue(s.contains("%20"))        // space
        XCTAssertTrue(s.contains("%E2%80%94"))  // em dash U+2014
        XCTAssertFalse(s.contains(" "))
    }

    func testPosixPathIsUnencoded() {
        let url = URL(fileURLWithPath: "/Users/archivist/Archive/00001 — Brown.pdf")
        let f = FileLinkFormatter(format: .posixPath)
        XCTAssertEqual(f.line(for: url), "/Users/archivist/Archive/00001 — Brown.pdf")
    }

    func testMarkdownUsesNameAndEncodedURL() {
        let url = URL(fileURLWithPath: "/Users/archivist/Archive/00001 — Brown.pdf")
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
