import XCTest
@testable import ArchiveReader
import ArchiveCore

/// On-disk integration tests for TagEditing → TagWriter.apply pipeline. Pure delta logic tests
/// live in ArchiveCoreTests/TagEditingTests. These test the full apply-to-disk path (scratch only).
final class TagEditingIntegrationTests: XCTestCase {

    func testApplySetYearOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: url)
        try (url as NSURL).setResourceValue(["1980", "Unread", "Jerry Brown"], forKey: .tagNamesKey)

        let current = TagReading.readTags(url)!
        _ = try TagWriter.apply(TagEditing.delta(for: .setYear(1982), given: current), to: url)

        let after = Set((try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        XCTAssertEqual(after, ["1982", "Unread", "Jerry Brown"])
    }

    func testApplySetYearPreservesCollidingSubjectOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        try Data("x".utf8).write(to: url)
        try (url as NSURL).setResourceValue(["1984", "Jerry Brown", "1980"], forKey: .tagNamesKey)

        let current = TagReading.readTags(url)!
        _ = try TagWriter.apply(TagEditing.delta(for: .setYear(1982), given: current), to: url)

        let after = Set((try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        XCTAssertEqual(after, ["1984", "Jerry Brown", "1982"])
    }
}
