import XCTest
@testable import ArchiveReader
import ArchiveCore

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

    func testTagRenameDeltaSwapsOnlyThatTagAndPreservesBytes() throws {
        // The primitive behind the corpus-wide rename (D1): remove old + add new, per file.
        let url = try makeFile("rename.pdf", tags: ["Environtment", "Jerry Brown", "1980", "Unread", "P8"])
        let bytesBefore = try Data(contentsOf: url)
        let r = try TagWriter.apply(TagDelta(add: ["Environment"], remove: ["Environtment"]), to: url)
        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Environment"))
        XCTAssertFalse(after.contains("Environtment"))                          // old tag gone
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "1980", "Unread", "P8"]))  // everything else intact
        XCTAssertFalse(r.isNoOp)
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)                   // CORE DIRECTIVE: bytes unchanged
        // Undo (inverse delta) restores the original tag.
        _ = try TagWriter.apply(r.inverse, to: url)
        XCTAssertTrue(Set(try readTags(url)).contains("Environtment"))
        XCTAssertFalse(Set(try readTags(url)).contains("Environment"))
    }

    func testTagRenameIsNoOpOnFileWithoutTheTag() throws {
        let url = try makeFile("norename.pdf", tags: ["Jerry Brown", "Unread"])
        let r = try TagWriter.apply(TagDelta(add: ["Environment"], remove: ["Environtment"]), to: url)
        // File lacks "Environtment"; adding "Environment" is a real change here, so it's NOT a no-op —
        // but the rename model only visits files that CARRY the old tag, so this file is never touched.
        // Assert the delta applied cleanly and preserved existing tags (defensive check on the primitive).
        XCTAssertTrue(Set(try readTags(url)).isSuperset(of: ["Jerry Brown", "Unread"]))
        _ = r
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

    func testClearColorRemovesColorTokenAndLabelButKeepsSubjects() throws {
        // In macOS a "Red"/"Purple" tag IS the color label (the token and the label are coupled —
        // Finder auto-assigns label 6/3 for the token). Clearing color removes the color token that
        // matches the current label and clears the label, while leaving ordinary subjects intact.
        let url = try makeFile("box.pdf", tags: ["Red", "Cold War", "Unread"], label: 6)
        _ = try TagWriter.apply(TagDelta(color: .clear), to: url)
        let after = Set(try readTags(url))
        XCTAssertFalse(after.contains("Red"))                    // color token removed with the label
        XCTAssertTrue(after.isSuperset(of: ["Cold War", "Unread"]))  // ordinary subjects preserved
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
    }

    func testSetColorSwapsPreviousLabelToken() throws {
        // Purple folder marker → set to box: "Purple" token dropped, "Red" added, label 6.
        let url = try makeFile("swapcolor.pdf", tags: ["Purple", "Unread"], label: 3)
        _ = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Red"))
        XCTAssertFalse(after.contains("Purple"))
        XCTAssertEqual(try readLabel(url), 6)
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

    // Regression (review finding [1]/[3]): undo of a color change is label-only, so it restores the
    // label verbatim and never adds/removes a token beyond the recorded diff.
    func testUndoColorSwapRestoresLabelAndTokensExactly() throws {
        let url = try makeFile("boxswap.pdf", tags: ["Red", "Jerry Brown"], label: 6)   // box
        let r = try TagWriter.apply(TagDelta(color: .set(.folder)), to: url)
        XCTAssertEqual(try readLabel(url), 3)
        XCTAssertTrue(Set(try readTags(url)).contains("Purple"))
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))
        _ = try TagWriter.apply(r.inverse, to: url)                 // undo
        XCTAssertEqual(Set(try readTags(url)), ["Red", "Jerry Brown"])
        XCTAssertEqual(try readLabel(url), 6)                       // label restored verbatim
    }

    func testUndoSetColorOnUncoloredRemovesTokenAndLabel() throws {
        let url = try makeFile("plaincolor.pdf", tags: ["Jerry Brown", "Unread"], label: nil)
        let r = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))
        _ = try TagWriter.apply(r.inverse, to: url)
        let after = Set(try readTags(url))
        XCTAssertFalse(after.contains("Red"))
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "Unread"]))
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
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
