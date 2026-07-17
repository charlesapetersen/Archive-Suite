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

    // MARK: §6 Write-target identity re-verification

    /// Matching identity → the write proceeds normally.
    func testIdentityMatchAllowsWrite() throws {
        let url = try makeFile("id-match.pdf", tags: ["Unread"])
        let identity = try XCTUnwrap(FileIdentity.capture(url))
        let r = try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            (current + ["Read"], label)
        }
        XCTAssertFalse(r.isNoOp)
        XCTAssertTrue(multisetEqual(try readTags(url), ["Unread", "Read"]))
    }

    /// A DIFFERENT file was put at the same path since discovery → the write ABORTS with
    /// .identityMismatch and the replacement file is left untouched (never tag the wrong file).
    func testReplacedFileAbortsAndLeavesReplacementUntouched() throws {
        let name = "id-swap.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        let originalIdentity = try XCTUnwrap(FileIdentity.capture(original))

        // Replace with a genuinely different file (delete → recreate ⇒ new inode ⇒ new identity).
        try FileManager.default.removeItem(at: original)
        let replacement = try makeFile(name, tags: ["Untouched"])
        // Precondition guards the test itself: the replacement must have a distinct identity.
        let replacementIdentity = try XCTUnwrap(FileIdentity.capture(replacement))
        XCTAssertFalse(replacementIdentity.matches(originalIdentity),
                       "test setup: delete+recreate should yield a distinct file identity")

        XCTAssertThrowsError(try CoordinatedTagWriter.write(replacement, expectedIdentity: originalIdentity) { current, label in
            (current + ["Reviewed"], label)
        }) { error in
            guard case TagWriteError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
        // The aborted write changed nothing — the replacement's tags are exactly as created.
        XCTAssertEqual(Set(try readTags(replacement)), ["Untouched"])
    }

    /// Same replace scenario but WITHOUT passing an identity → the write proceeds. The §6 check is
    /// strictly opt-in; existing callers (nil identity) are unaffected (backward compatibility).
    func testNilIdentitySkipsCheckAndWrites() throws {
        let name = "id-nil.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        _ = try XCTUnwrap(FileIdentity.capture(original))
        try FileManager.default.removeItem(at: original)
        let replacement = try makeFile(name, tags: ["Untouched"])

        let r = try CoordinatedTagWriter.write(replacement) { current, label in
            (current + ["Reviewed"], label)
        }
        XCTAssertFalse(r.isNoOp)
        XCTAssertTrue(multisetEqual(try readTags(replacement), ["Untouched", "Reviewed"]))
    }

    // NOTE: the "captured file was fully DELETED (nothing at the path)" edge is intentionally NOT
    // asserted here. NSFileCoordinator's behavior on a vanished path is OS-implementation-defined
    // (it may recreate the path), so the failure surfaces nondeterministically as .identityMismatch,
    // .unreadable, .coordinationFailed, or a raw setResourceValue error — all of which prevent a
    // wrong-file tag, but none reliably. It is not a §6 safety scenario (no *different* file is
    // present to mis-tag); the existing `testUnreadableFileAborts` already covers ghost-file aborts,
    // and `testReplacedFileAborts…` covers the dangerous "different file at the same path" case.

    /// FileIdentity.capture + matches semantics: same file matches itself (and is symmetric),
    /// distinct files differ, and a nonexistent file yields nil.
    func testFileIdentityCaptureAndMatches() throws {
        let a = try makeFile("id-a.pdf", tags: [])
        let b = try makeFile("id-b.pdf", tags: [])
        let a1 = try XCTUnwrap(FileIdentity.capture(a))
        let a2 = try XCTUnwrap(FileIdentity.capture(a))
        let bId = try XCTUnwrap(FileIdentity.capture(b))
        XCTAssertTrue(a1.matches(a2))     // same file, captured twice
        XCTAssertTrue(a2.matches(a1))     // symmetric
        XCTAssertFalse(a1.matches(bId))   // distinct files
        XCTAssertNil(FileIdentity.capture(tempDir.appendingPathComponent("nope.pdf")))
    }
}
