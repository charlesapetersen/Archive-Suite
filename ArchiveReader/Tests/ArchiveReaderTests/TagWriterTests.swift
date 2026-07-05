import XCTest
@testable import ArchiveReader

/// Integration tests for the safety-critical `TagWriter`. These operate ONLY on throwaway temp files
/// created per-test — NEVER the corpus. They exercise the Safety Protocol guarantees directly.
final class TagWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Create a temp file with some bytes and an initial tag set (+ optional label).
    private func makeFile(_ name: String, tags: [String], label: Int? = nil,
                          bytes: Data = Data("PDF-BYTES-\(UUID().uuidString)".utf8)) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try bytes.write(to: url)
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

    // MARK: Read-state fast path

    func testSetReadStateSwapsAndPreservesOtherTags() throws {
        let url = try makeFile("swap.pdf", tags: ["Unread", "Jerry Brown", "1980", "P9"])
        let bytesBefore = try Data(contentsOf: url)

        let r = try TagWriter.setReadState(.read, on: url)

        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Read"))
        XCTAssertFalse(after.contains("Unread"))
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "1980", "P9"]))  // every other tag preserved
        XCTAssertFalse(r.isNoOp)
        // CORE DIRECTIVE: file bytes are untouched.
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    func testMarkReadIsNoOpOnFileWithoutReadState() throws {
        // Box/folder markers carry no Read/Unread token — default must NOT add one.
        let url = try makeFile("marker.pdf", tags: ["DP chapters"], label: 6)
        let r = try TagWriter.setReadState(.read, on: url)
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["DP chapters"])
        XCTAssertEqual(try readLabel(url), 6)  // color untouched
    }

    func testMarkReadAddsWhenExplicitlyRequested() throws {
        let url = try makeFile("marker2.pdf", tags: ["DP chapters"])
        _ = try TagWriter.setReadState(.read, on: url, addIfMissing: true)
        XCTAssertTrue(Set(try readTags(url)).contains("Read"))
    }

    func testSetReadStateIdempotentWhenAlreadyTarget() throws {
        let url = try makeFile("already.pdf", tags: ["Read", "x"])
        let r = try TagWriter.setReadState(.read, on: url)
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Read", "x"])
    }

    // MARK: General delta edits

    func testApplyAddAndRemoveSubjects() throws {
        let url = try makeFile("edit.pdf", tags: ["Unread", "Speeches", "1982"])
        _ = try TagWriter.apply(TagDelta(add: ["Economics"], remove: ["Speeches"]), to: url)
        let after = Set(try readTags(url))
        XCTAssertEqual(after, ["Unread", "1982", "Economics"])
    }

    func testRemovingUnreadDoesNotTouchSubjectContainingReadSubstring() throws {
        let url = try makeFile("substr.pdf", tags: ["Unread", "Read later", "1970"])
        _ = try TagWriter.setReadState(.read, on: url)
        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Read later"))   // substring subject preserved
        XCTAssertTrue(after.contains("Read"))
        XCTAssertFalse(after.contains("Unread"))
    }

    func testColorSetAndClearKeepsTokenAndLabelConsistent() throws {
        let url = try makeFile("color.pdf", tags: ["Unread", "DP chapters"])
        _ = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertEqual(try readLabel(url), 6)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))

        _ = try TagWriter.apply(TagDelta(color: .clear), to: url)
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))
    }

    func testColorTokenPreservedOnUnrelatedReadStateWrite() throws {
        // Real box marker shape: Red label + "Red" token. A Read/Unread edit must keep the swatch.
        let url = try makeFile("boxmarker.pdf", tags: ["Red", "Unread", "Jerry Brown"], label: 6)
        _ = try TagWriter.setReadState(.read, on: url, addIfMissing: true)
        XCTAssertEqual(try readLabel(url), 6)                      // label preserved (Safety §7)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))
    }

    // MARK: Undo via inverse delta

    func testInverseDeltaUndoesEdit() throws {
        let url = try makeFile("undo.pdf", tags: ["Unread", "Speeches", "1982"])
        let original = Set(try readTags(url))

        let r = try TagWriter.apply(TagDelta(add: ["Economics"], remove: ["Speeches"]), to: url)
        XCTAssertNotEqual(Set(try readTags(url)), original)

        _ = try TagWriter.apply(r.inverse, to: url)               // undo
        XCTAssertEqual(Set(try readTags(url)), original)
    }

    func testInverseUndoesColorChange() throws {
        let url = try makeFile("undocolor.pdf", tags: ["Unread"])
        let r = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertEqual(try readLabel(url), 6)
        _ = try TagWriter.apply(r.inverse, to: url)
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))
    }

    // MARK: Safety guards

    func testUnreadableFileIsRefusedNotWiped() throws {
        // A file that cannot be read must ABORT — never be coerced into "no tags" then overwritten.
        let ghost = tempDir.appendingPathComponent("does-not-exist.pdf")
        XCTAssertThrowsError(try TagWriter.setReadState(.read, on: ghost, addIfMissing: true)) { error in
            // Either the read guard or coordination rejects it — the key point is it THROWS.
            XCTAssertTrue(error is TagWriteError)
        }
    }

    func testEmptyDeltaIsNoOp() throws {
        let url = try makeFile("noop.pdf", tags: ["Unread", "x"])
        let r = try TagWriter.apply(TagDelta(), to: url)
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Unread", "x"])
    }

    func testBatchApplyReturnsPerFileResults() throws {
        let a = try makeFile("a.pdf", tags: ["Unread", "x"])
        let b = try makeFile("b.pdf", tags: ["Unread", "y"])
        let ghost = tempDir.appendingPathComponent("ghost.pdf")
        let results = TagWriter.apply(TagDelta(add: ["Reviewed"]), to: [a, b, ghost])
        XCTAssertEqual(results.count, 3)
        XCTAssertNoThrow(try results[0].result.get())
        XCTAssertNoThrow(try results[1].result.get())
        XCTAssertThrowsError(try results[2].result.get())          // missing file surfaces as failure
        XCTAssertTrue(Set(try readTags(a)).contains("Reviewed"))
    }
}
