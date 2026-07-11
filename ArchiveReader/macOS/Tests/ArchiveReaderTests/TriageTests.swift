import XCTest
@testable import ArchiveReader
import ArchiveCore

/// Tests for the G4 keyboard-triage feature:
///  1. `TriageNavigation` — pure next/previous-unread selection math (skips read rows; wraps / stops).
///  2. The mark-as-read write path used by triage — exercised on THROWAWAY scratch files only (never
///     the corpus, per the Core Directive): it removes only `Unread`, preserves every other tag, and
///     the inverse-delta undo restores `Unread`.
final class TriageTests: XCTestCase {

    // MARK: 1. Pure next/previous-unread math

    /// `unread` marks which of `count` rows still carry Unread.
    private func isUnread(_ unread: Set<Int>) -> (Int) -> Bool { { unread.contains($0) } }

    func testNextUnreadSkipsReadRows() {
        // rows: 0=read 1=UNREAD 2=read 3=UNREAD 4=read
        let f = isUnread([1, 3])
        XCTAssertEqual(TriageNavigation.nextUnread(after: 0, count: 5, isUnread: f), 1)
        XCTAssertEqual(TriageNavigation.nextUnread(after: 1, count: 5, isUnread: f), 3)
        XCTAssertEqual(TriageNavigation.nextUnread(after: 2, count: 5, isUnread: f), 3)
    }

    func testNextUnreadFromNoSelectionStartsAtFirstUnread() {
        XCTAssertEqual(TriageNavigation.nextUnread(after: nil, count: 5, isUnread: isUnread([2, 4])), 2)
    }

    func testNextUnreadWrapsAround() {
        // Past the last unread, wrap back to the first.
        XCTAssertEqual(TriageNavigation.nextUnread(after: 3, count: 5, wrap: true, isUnread: isUnread([1, 3])), 1)
    }

    func testNextUnreadStopsWhenWrapDisabled() {
        XCTAssertNil(TriageNavigation.nextUnread(after: 3, count: 5, wrap: false, isUnread: isUnread([1, 3])))
    }

    func testNextUnreadNilWhenNoneUnread() {
        XCTAssertNil(TriageNavigation.nextUnread(after: 0, count: 5, isUnread: isUnread([])))
        XCTAssertNil(TriageNavigation.nextUnread(after: nil, count: 0, isUnread: isUnread([])))
    }

    func testNextUnreadReturnsAnchorOnlyWhenItIsTheSoleUnread() {
        // Row 2 is the only unread; wrapping from 2 lands back on 2 (caller reads this as "no other").
        XCTAssertEqual(TriageNavigation.nextUnread(after: 2, count: 5, wrap: true, isUnread: isUnread([2])), 2)
    }

    func testPreviousUnreadSkipsReadRowsAndWraps() {
        let f = isUnread([1, 3])
        XCTAssertEqual(TriageNavigation.previousUnread(before: 4, count: 5, isUnread: f), 3)
        XCTAssertEqual(TriageNavigation.previousUnread(before: 3, count: 5, isUnread: f), 1)
        XCTAssertEqual(TriageNavigation.previousUnread(before: 1, count: 5, wrap: true, isUnread: f), 3)   // wrap
        XCTAssertNil(TriageNavigation.previousUnread(before: 1, count: 5, wrap: false, isUnread: f))       // stop
    }

    func testPreviousUnreadFromNoSelectionStartsAtLastUnread() {
        XCTAssertEqual(TriageNavigation.previousUnread(before: nil, count: 5, isUnread: isUnread([0, 3])), 3)
    }

    // MARK: 2. Mark-as-read write path (scratch files only)

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveReaderTriageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeFile(_ name: String, tags: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return url
    }
    private func readTags(_ url: URL) throws -> [String] {
        (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    func testMarkReadRemovesOnlyUnreadAndPreservesOtherTags() throws {
        // The exact write `markReadAndAdvance` performs, on a scratch copy.
        let url = try makeFile("triage.pdf", tags: ["Unread", "Jerry Brown", "1980", "P9", "Economics"])
        let bytesBefore = try Data(contentsOf: url)

        let r = try TagWriter.setReadState(.read, on: url)

        let after = Set(try readTags(url))
        XCTAssertFalse(after.contains("Unread"))                                          // Unread removed
        XCTAssertTrue(after.contains("Read"))                                             // Read added (the swap)
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "1980", "P9", "Economics"]))   // nothing else touched
        XCTAssertEqual(after.count, 5)                                                    // only the state token changed
        XCTAssertFalse(r.isNoOp)
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)                            // CORE DIRECTIVE: bytes unchanged
    }

    func testMarkReadUndoRestoresUnread() throws {
        let url = try makeFile("triage-undo.pdf", tags: ["Unread", "Cold War", "1975"])
        let original = Set(try readTags(url))

        let r = try TagWriter.setReadState(.read, on: url)
        XCTAssertTrue(Set(try readTags(url)).contains("Read"))

        _ = try TagWriter.apply(r.inverse, to: url)                                       // undo = inverse delta
        let restored = Set(try readTags(url))
        XCTAssertEqual(restored, original)                                                // Unread back, others intact
        XCTAssertTrue(restored.contains("Unread"))
        XCTAssertFalse(restored.contains("Read"))
    }
}
