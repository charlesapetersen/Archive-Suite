import XCTest
@testable import ArchiveCore

/// Tests for `CoordinatedTagWriter.write` — the shared coordinated-write primitive.
/// Exercises the Safety Protocol guarantees directly on throwaway temp files (never the corpus).
final class TagWriterPrimitiveTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeFile(_ name: String, tags: [String], label: Int? = nil) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func readTags(_ url: URL) throws -> [String] {
        (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    private func readLabel(_ url: URL) throws -> Int? {
        try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }

    // MARK: §3 Trustworthy-read guard — unreadable file ABORTS

    func testUnreadableFileAborts() throws {
        let ghost = tempDir.appendingPathComponent("does-not-exist.pdf")
        XCTAssertThrowsError(try CoordinatedTagWriter.write(ghost) { _, _ in (["x"], nil) }) { error in
            XCTAssertTrue(error is TagWriteError)
        }
    }

    // MARK: No-op transform returns no-op result

    func testNilTransformIsNoOp() throws {
        let url = try makeFile("noop.pdf", tags: ["Unread", "x"])
        let r = try CoordinatedTagWriter.write(url) { _, _ in nil }
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Unread", "x"])
    }

    // MARK: §8 Verify by re-read — multiset equality

    func testWriteAndVerifyRoundTrip() throws {
        let url = try makeFile("verify.pdf", tags: ["A", "B"])
        let r = try CoordinatedTagWriter.write(url) { current, label in
            (current + ["C"], label)
        }
        XCTAssertFalse(r.isNoOp)
        XCTAssertTrue(multisetEqual(r.after, ["A", "B", "C"]))
        XCTAssertTrue(multisetEqual(try readTags(url), ["A", "B", "C"]))
    }

    // MARK: §7 Label written only when changed; drift restored

    func testLabelPreservedWhenTransformDoesNotChangeIt() throws {
        let url = try makeFile("labeldrift.pdf", tags: ["Unread", "Red"], label: 6)
        _ = try CoordinatedTagWriter.write(url) { current, label in
            // Replace "Unread" with "Read" but keep label the same
            (current.map { $0 == "Unread" ? "Read" : $0 }, label)
        }
        XCTAssertEqual(try readLabel(url), 6)
    }

    func testLabelChangedWhenTransformSetsIt() throws {
        let url = try makeFile("labelchange.pdf", tags: ["A"], label: nil)
        _ = try CoordinatedTagWriter.write(url) { current, _ in
            (current + ["Red"], 6)
        }
        XCTAssertEqual(try readLabel(url), 6)
    }

    // MARK: §9 Inverse delta

    func testInverseDeltaIsCorrect() throws {
        let url = try makeFile("inverse.pdf", tags: ["A", "B"])
        let r = try CoordinatedTagWriter.write(url) { _, label in
            (["A", "C"], label)
        }
        // Inverse should add "B" (was removed) and remove "C" (was added)
        XCTAssertTrue(r.inverse.add.contains("B"))
        XCTAssertTrue(r.inverse.remove.contains("C"))
    }

    // MARK: File bytes untouched

    func testFileBytesPreserved() throws {
        let url = try makeFile("bytes.pdf", tags: ["Unread"])
        let bytesBefore = try Data(contentsOf: url)
        _ = try CoordinatedTagWriter.write(url) { _, label in
            (["Read"], label)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    // MARK: TagReading integration

    func testTagReadingReadSuccess() throws {
        let url = try makeFile("read.pdf", tags: ["Jerry Brown", "1980"], label: 6)
        let result = TagReading.read(url)
        guard case let .success(tagNames, labelNumber) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(Set(tagNames), ["Jerry Brown", "1980"])
        XCTAssertEqual(labelNumber, 6)
    }

    func testTagReadingReadFailure() {
        let ghost = tempDir.appendingPathComponent("ghost.pdf")
        let result = TagReading.read(ghost)
        XCTAssertFalse(result.isReadable)
        XCTAssertNil(result.tagNames)
    }

    func testTagReadingReadTagsReturnsParsedFacets() throws {
        let url = try makeFile("facets.pdf", tags: ["1980", "P9", "Unread", "Jerry Brown"], label: 6)
        let tags = TagReading.readTags(url)
        XCTAssertNotNil(tags)
        XCTAssertEqual(tags?.year, 1980)
        XCTAssertEqual(tags?.priority, 9)
        XCTAssertEqual(tags?.readState, .unread)
        XCTAssertEqual(tags?.color, .box)
    }
}
