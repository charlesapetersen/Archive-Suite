import XCTest
@testable import ArchiveReader

/// The inline subject-token editor (SubjectTokenField → NavigationModel.commitSubjectEdit) turns an
/// edited token set into a single `TagDelta` via `TagEditing.subjectDelta` and writes it through the
/// audited `TagWriter`. These tests pin the pure diff logic and the write path (on scratch files only —
/// never the corpus): facet tokens + file bytes are preserved, whole-string removal is exact, and the
/// edit round-trips via the inverse delta (the undo path).
final class SubjectTokenEditTests: XCTestCase {

    // MARK: - Pure diff: TagEditing.subjectDelta(from:to:)

    func testAddOne() {
        let d = TagEditing.subjectDelta(from: ["Economics"], to: ["Economics", "Taxes"])
        XCTAssertEqual(d.add, ["Taxes"])
        XCTAssertEqual(d.remove, [])
    }

    func testRemoveOne() {
        let d = TagEditing.subjectDelta(from: ["Economics", "Taxes"], to: ["Economics"])
        XCTAssertEqual(d.add, [])
        XCTAssertEqual(d.remove, ["Taxes"])
    }

    func testAddAndRemoveInOneDelta() {
        let d = TagEditing.subjectDelta(from: ["A", "B"], to: ["A", "C"])
        XCTAssertEqual(d.add, ["C"])
        XCTAssertEqual(d.remove, ["B"])
    }

    func testNoChangeIsEmpty() {
        XCTAssertTrue(TagEditing.subjectDelta(from: ["A", "B"], to: ["A", "B"]).isEmpty)
    }

    func testReorderOnlyIsNoOp() {
        XCTAssertTrue(TagEditing.subjectDelta(from: ["A", "B"], to: ["B", "A"]).isEmpty)
    }

    func testTrimsAddedToken() {
        XCTAssertEqual(TagEditing.subjectDelta(from: [], to: ["  Taxes "]).add, ["Taxes"])
    }

    func testDropsEmptyOrWhitespaceAdds() {
        XCTAssertTrue(TagEditing.subjectDelta(from: [], to: ["   ", ""]).isEmpty)
    }

    func testDeDupesAddedTokens() {
        XCTAssertEqual(TagEditing.subjectDelta(from: [], to: ["X", "X", " X "]).add, ["X"])
    }

    func testDoesNotReAddExistingSubject() {
        // A duplicate of a token the file already has is not re-added (TagWriter would skip it anyway).
        XCTAssertTrue(TagEditing.subjectDelta(from: ["X"], to: ["X", "X"]).isEmpty)
    }

    func testWhitespacePaddedSubjectIsNotChurned() {
        // A subject stored with surrounding whitespace, displayed/round-tripped trimmed, must NOT be
        // removed-and-rewritten when untouched (matched on canonical/trimmed form on both sides).
        XCTAssertTrue(TagEditing.subjectDelta(from: [" Draft"], to: ["Draft"]).isEmpty)
    }

    func testWhitespacePaddedSubjectPreservedWhileAddingAnother() {
        let d = TagEditing.subjectDelta(from: [" Draft"], to: ["Draft", "Taxes"])
        XCTAssertEqual(d.add, ["Taxes"])
        XCTAssertEqual(d.remove, [], "the untouched whitespace-padded subject must not be removed")
    }

    // MARK: - Integration: write path on scratch files (never the corpus)

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SubjectTokenEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String, tags: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("%PDF-1.4\n".utf8).write(to: url)
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return url
    }

    private func readTags(_ url: URL) throws -> [String] {
        (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// Editing subjects inline preserves the file's date/priority/read facet tokens and its bytes.
    func testInlineEditPreservesFacetTokensAndBytes() throws {
        let raw = ["1980", "P8", "Unread", "Economics", "Speeches"]
        let url = try makeFile("doc.pdf", tags: raw)
        let bytesBefore = try Data(contentsOf: url)

        let old = DocumentTags.parse(raw: raw, labelNumber: nil).subjects   // ["Economics", "Speeches"]
        let delta = TagEditing.subjectDelta(from: old, to: ["Economics", "Taxes"])   // −Speeches +Taxes
        _ = try TagWriter.apply(delta, to: url)

        let after = try readTags(url)
        XCTAssertEqual(Set(after), Set(["1980", "P8", "Unread", "Economics", "Taxes"]),
                       "only the edited subject should change; facet tokens preserved")
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore, "file bytes must not change")
    }

    /// Removing one subject uses exact whole-string matching — a sibling subject sharing a prefix stays.
    func testWholeStringRemovalDoesNotClobberPrefixSibling() throws {
        let raw = ["Unread", "Economics", "Economic Policy"]
        let url = try makeFile("c.pdf", tags: raw)
        let old = DocumentTags.parse(raw: raw, labelNumber: nil).subjects
        let delta = TagEditing.subjectDelta(from: old, to: old.filter { $0 != "Economics" })
        _ = try TagWriter.apply(delta, to: url)

        let after = try readTags(url)
        XCTAssertFalse(after.contains("Economics"))
        XCTAssertTrue(after.contains("Economic Policy"))
        XCTAssertTrue(after.contains("Unread"))
    }

    /// The inline edit round-trips through its inverse delta (the undo path).
    func testInlineEditInverseRoundTrips() throws {
        let raw = ["Unread", "Economics"]
        let url = try makeFile("u.pdf", tags: raw)
        let old = DocumentTags.parse(raw: raw, labelNumber: nil).subjects
        let r = try TagWriter.apply(TagEditing.subjectDelta(from: old, to: ["Economics", "Taxes"]), to: url)
        XCTAssertTrue(try readTags(url).contains("Taxes"))

        _ = try TagWriter.apply(r.inverse, to: url)
        XCTAssertEqual(Set(try readTags(url)), Set(raw), "inverse delta restores the original tag set")
    }
}
