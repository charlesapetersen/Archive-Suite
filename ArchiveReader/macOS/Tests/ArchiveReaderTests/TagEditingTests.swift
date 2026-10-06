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

    func testApplySetQualityWritesCanonicalTokenAndPreservesBytes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("quality.pdf")
        let bytes = Data("scratch PDF bytes".utf8)
        try bytes.write(to: url)
        try (url as NSURL).setResourceValue(["P9", "Unread", "History"], forKey: .tagNamesKey)

        let current = try XCTUnwrap(TagReading.readTags(url))
        _ = try TagWriter.apply(TagEditing.delta(for: .setQuality(3), given: current), to: url)

        let after = Set((try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        XCTAssertEqual(after, ["Q3", "Unread", "History"])
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Quality editing changes Finder metadata only")
    }

    /// W37: set → replace → clear a sent-with date on a scratch file. Only the consumed token moves;
    /// a role-looking subject, a duplicate subject, the own date, colour and the data fork survive.
    func testApplySentWithEditsOnDiskPreserveEverythingElse() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("enclosure.pdf")
        let bytes = Data("scratch PDF bytes".utf8)
        try bytes.write(to: url)
        try (url as NSURL).setResourceValue(["1957", "Sent With Love", "Report", "Report", "Date Uncertain", "Red"],
                                            forKey: .tagNamesKey)
        try (url as NSURL).setResourceValue(6, forKey: .labelNumberKey)

        func tags() throws -> [String] { try XCTUnwrap(TagReading.readTags(url)).raw }
        func edit(_ op: TagEditOp) throws {
            _ = try TagWriter.apply(TagEditing.delta(for: op, given: try XCTUnwrap(TagReading.readTags(url))), to: url)
        }

        try edit(.setSentWith(ArchiveDate(year: 1958, month: 3, day: 12)))
        try edit(.setSentWithUncertain(true))
        XCTAssertEqual(try tags().sorted(), ["1957", "Date Uncertain", "Red", "Report", "Report", "Sent With 1958-03-12",
                                             "Sent With Date Uncertain", "Sent With Love"])
        try edit(.setSentWith(ArchiveDate(decade: 1950)))
        XCTAssertEqual(try XCTUnwrap(TagReading.readTags(url)).sentWith, ArchiveDate(decade: 1950))
        XCTAssertTrue(try tags().contains("Sent With Date Uncertain"), "replacing the value keeps its flag")
        try edit(.setSentWith(nil))
        XCTAssertEqual(try tags().sorted(), ["1957", "Date Uncertain", "Red", "Report", "Report", "Sent With Love"])
        XCTAssertEqual(try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber, 6)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "sent-with editing changes Finder metadata only")
    }
}
