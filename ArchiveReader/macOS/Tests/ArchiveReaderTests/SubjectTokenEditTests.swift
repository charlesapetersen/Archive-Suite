import XCTest
@testable import ArchiveReader
import ArchiveCore

/// Integration tests for SubjectTokenField → TagEditing.subjectDelta → TagWriter.apply pipeline.
/// Pure diff logic tests live in ArchiveCoreTests/SubjectTokenEditTests. These test the full
/// write path on scratch files only — never the corpus.
final class SubjectTokenEditIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SubjectTokenEditIntegTests-\(UUID().uuidString)")
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

    func testInlineEditPreservesFacetTokensAndBytes() throws {
        let raw = ["1980", "P8", "Unread", "Economics", "Speeches"]
        let url = try makeFile("doc.pdf", tags: raw)
        let bytesBefore = try Data(contentsOf: url)

        let old = DocumentTags.parse(raw: raw, labelNumber: nil).subjects
        let delta = TagEditing.subjectDelta(from: old, to: ["Economics", "Taxes"])
        _ = try TagWriter.apply(delta, to: url)

        let after = try readTags(url)
        XCTAssertEqual(Set(after), Set(["1980", "P8", "Unread", "Economics", "Taxes"]),
                       "only the edited subject should change; facet tokens preserved")
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore, "file bytes must not change")
    }

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
