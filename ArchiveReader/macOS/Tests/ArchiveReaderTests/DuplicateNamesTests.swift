import XCTest
@testable import ArchiveReader
import ArchiveCore

final class DuplicateNamesTests: XCTestCase {

    private func file(_ path: String) -> ArchiveFile {
        let url = URL(fileURLWithPath: path)
        return ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                           tags: DocumentTags.parse(raw: [], labelNumber: nil), contentModified: nil)
    }

    func testDuplicatesDetectedAcrossDifferentFolders() {
        let files = [
            file("/corpus/Box 1/00001 IMG — Brown.pdf"),
            file("/corpus/Box 2/00001 IMG — Brown.pdf"),
            file("/corpus/Box 1/00002 IMG — Brown.pdf"),
        ]
        let dups = DuplicateNames.duplicatedNames(in: files)
        XCTAssertEqual(dups, ["00001 img — brown.pdf"])
        XCTAssertTrue(DuplicateNames.isDuplicated("00001 IMG — Brown.pdf", in: dups))
        XCTAssertFalse(DuplicateNames.isDuplicated("00002 IMG — Brown.pdf", in: dups))
    }

    func testUniqueNamesNotFlagged() {
        let files = [file("/corpus/a/one.pdf"), file("/corpus/b/two.pdf"), file("/corpus/c/three.pdf")]
        XCTAssertTrue(DuplicateNames.duplicatedNames(in: files).isEmpty)
        XCTAssertFalse(DuplicateNames.isDuplicated("one.pdf", in: []))
    }

    func testCaseInsensitiveCollision() {
        let files = [file("/corpus/a/Report.pdf"), file("/corpus/b/report.pdf")]
        let dups = DuplicateNames.duplicatedNames(in: files)
        XCTAssertEqual(dups, ["report.pdf"])
        XCTAssertTrue(DuplicateNames.isDuplicated("REPORT.PDF", in: dups))
    }

    func testDisambiguatorReturnsParentFolder() {
        let url = URL(fileURLWithPath: "/corpus/Box 3/Folder A/00001 IMG — Brown.pdf")
        XCTAssertEqual(DuplicateNames.disambiguator(for: url), "Folder A")
    }

    func testEmptyAndSingleFileSets() {
        XCTAssertTrue(DuplicateNames.duplicatedNames(in: []).isEmpty)
        XCTAssertTrue(DuplicateNames.duplicatedNames(in: [file("/corpus/x/only.pdf")]).isEmpty)
    }
}
