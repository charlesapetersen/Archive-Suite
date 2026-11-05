import XCTest
@testable import ArchiveReader

@MainActor
final class FlagStoreTests: XCTestCase {

    private func makeStore() -> (FlagStore, UserDefaults, String) {
        let name = "ArchiveReaderTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (FlagStore(defaults: d), d, name)
    }

    func testSetFlagPersists() {
        let (s, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        s.setFlag(true, for: "/a.pdf")
        XCTAssertTrue(s.isFlagged("/a.pdf"))
        XCTAssertFalse(s.isFlagged("/b.pdf"))
        // Reload from the same defaults — persisted outside the corpus.
        XCTAssertTrue(FlagStore(defaults: d).isFlagged("/a.pdf"))
        s.setFlag(false, for: "/a.pdf")
        XCTAssertTrue(s.flagged.isEmpty)
        XCTAssertFalse(FlagStore(defaults: d).isFlagged("/a.pdf"))
    }

    func testGroupToggleFlag() {
        let (s, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        s.setFlag(true, for: "/a.pdf")
        s.toggleFlag(["/a.pdf", "/b.pdf"])   // one unflagged → flag all
        XCTAssertTrue(s.isFlagged("/a.pdf")); XCTAssertTrue(s.isFlagged("/b.pdf"))
        s.toggleFlag(["/a.pdf", "/b.pdf"])   // all flagged → unflag all
        XCTAssertFalse(s.isFlagged("/a.pdf")); XCTAssertFalse(s.isFlagged("/b.pdf"))
        XCTAssertTrue(FlagStore(defaults: d).flagged.isEmpty)
    }
}
