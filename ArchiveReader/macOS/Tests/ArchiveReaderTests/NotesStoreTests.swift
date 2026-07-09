import XCTest
@testable import ArchiveReader

@MainActor
final class NotesStoreTests: XCTestCase {

    private func makeStore() -> (NotesStore, UserDefaults, String) {
        let name = "ArchiveReaderTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (NotesStore(defaults: d), d, name)
    }

    func testSetNoteAndFlagPersist() {
        let (s, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        s.setNote("check page 3", for: "/a.pdf")
        s.setFlag(true, for: "/a.pdf")
        XCTAssertEqual(s.annotation(for: "/a.pdf").note, "check page 3")
        XCTAssertTrue(s.isFlagged("/a.pdf"))
        // Reload from the same defaults — persisted outside the corpus.
        let reloaded = NotesStore(defaults: d)
        XCTAssertTrue(reloaded.isFlagged("/a.pdf"))
        XCTAssertEqual(reloaded.annotation(for: "/a.pdf").note, "check page 3")
    }

    func testEmptyAnnotationIsRemoved() {
        let (s, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        s.setNote("x", for: "/a.pdf")
        s.setNote("", for: "/a.pdf")     // back to empty → dropped
        XCTAssertTrue(s.annotations.isEmpty)
    }

    func testGroupToggleFlag() {
        let (s, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        s.toggleFlag(["/a.pdf", "/b.pdf"])   // none flagged → flag all
        XCTAssertTrue(s.isFlagged("/a.pdf")); XCTAssertTrue(s.isFlagged("/b.pdf"))
        s.toggleFlag(["/a.pdf", "/b.pdf"])   // all flagged → unflag all
        XCTAssertFalse(s.isFlagged("/a.pdf")); XCTAssertFalse(s.isFlagged("/b.pdf"))
    }
}
