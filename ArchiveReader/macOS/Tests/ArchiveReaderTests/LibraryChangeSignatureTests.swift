import XCTest
@testable import ArchiveReader
import ArchiveCore

/// Guards the library change-signatures used by `NavigationModel.libraryDidChange` to gate cache
/// rebuilds. The subjects signature had a parity bug (a raw-multiset XOR self-cancels for any subject
/// on an even number of files), which skipped `refreshSubjectsCache()` after ~half of all tag edits
/// and left the ⌘L autocomplete + near-duplicate check stale. These tests pin the union-based fix.
final class LibraryChangeSignatureTests: XCTestCase {

    private func file(_ name: String, _ subjects: [String]) -> ArchiveFile {
        // "Unread" keeps a read-state facet present; the rest parse as subjects.
        ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name)"), name: name, fileType: "PDF",
                    tags: DocumentTags.parse(raw: subjects + ["Unread"], labelNumber: nil),
                    contentModified: nil)
    }

    // MARK: subjects — the parity regression

    /// THE regression: renaming a subject carried by an EVEN number of files must change the signature.
    /// The old flat-multiset XOR gave 0 both before and after (hash^hash == 0), so the refresh was
    /// wrongly skipped. The union-based signature distinguishes {Draft} from {Final}.
    func testEvenCountRenameChangesSubjectsSignature() {
        let before = [file("a", ["Draft"]), file("b", ["Draft"])]      // "Draft" on 2 (even) files
        let after  = [file("a", ["Final"]), file("b", ["Final"])]      // renamed on both
        XCTAssertNotEqual(LibraryChangeSignature.subjects(before),
                          LibraryChangeSignature.subjects(after),
                          "even-count rename must flip the subjects signature (it did not with the multiset XOR)")
    }

    /// Adding a brand-new subject to an even number of files (0 → even) must change the signature too.
    func testEvenCountAddChangesSubjectsSignature() {
        let before = [file("a", ["Econ"]), file("b", ["Econ"])]
        let after  = [file("a", ["Econ", "Water Board"]), file("b", ["Econ", "Water Board"])]
        XCTAssertNotEqual(LibraryChangeSignature.subjects(before),
                          LibraryChangeSignature.subjects(after))
    }

    /// Removing a subject's LAST (even count of) occurrences must change the signature.
    func testEvenCountRemovalChangesSubjectsSignature() {
        let before = [file("a", ["Econ", "Law"]), file("b", ["Econ", "Law"])]
        let after  = [file("a", ["Econ"]), file("b", ["Econ"])]        // "Law" removed from both
        XCTAssertNotEqual(LibraryChangeSignature.subjects(before),
                          LibraryChangeSignature.subjects(after))
    }

    /// The signature reflects the DISTINCT union, so it is identical for the same union regardless of
    /// how subjects are distributed across files (and regardless of duplicates).
    func testSubjectsSignatureIsUnionOnly() {
        let one  = [file("a", ["Law", "Econ"])]
        let many = [file("a", ["Law"]), file("b", ["Econ"]), file("c", ["Law", "Econ"])]  // same union
        XCTAssertEqual(LibraryChangeSignature.subjects(one),
                       LibraryChangeSignature.subjects(many))
    }

    func testSubjectsSignatureIsOrderIndependent() {
        let files = [file("a", ["Law", "Econ"]), file("b", ["Water"])]
        XCTAssertEqual(LibraryChangeSignature.subjects(files),
                       LibraryChangeSignature.subjects(files.reversed()))
    }

    // MARK: matchFacets — sensitive to the facets that drive smart-folder counts

    /// A read-state change (which never touches subjects) must flip the match signature so smart-folder
    /// badges refresh — even though the subjects signature stays put.
    func testMatchFacetsSensitiveToReadState() {
        let unread = [ArchiveFile(url: URL(fileURLWithPath: "/corpus/a"), name: "a", fileType: "PDF",
                                  tags: DocumentTags.parse(raw: ["Econ", "Unread"], labelNumber: nil),
                                  contentModified: nil)]
        let read   = [ArchiveFile(url: URL(fileURLWithPath: "/corpus/a"), name: "a", fileType: "PDF",
                                  tags: DocumentTags.parse(raw: ["Econ", "Read"], labelNumber: nil),
                                  contentModified: nil)]
        XCTAssertNotEqual(LibraryChangeSignature.matchFacets(unread),
                          LibraryChangeSignature.matchFacets(read))
        XCTAssertEqual(LibraryChangeSignature.subjects(unread),
                       LibraryChangeSignature.subjects(read),
                       "read-state change must not alter the subjects union")
    }

    // MARK: paths — sensitive to the file set (drives the folder tree)

    func testPathsSignatureChangesWithFileSet() {
        let a  = [file("a", ["X"])]
        let ab = [file("a", ["X"]), file("b", ["X"])]
        XCTAssertNotEqual(LibraryChangeSignature.paths(a), LibraryChangeSignature.paths(ab))
    }
}
