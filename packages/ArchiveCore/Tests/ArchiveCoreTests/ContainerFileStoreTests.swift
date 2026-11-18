import XCTest
import Darwin
@testable import ArchiveCore

/// The container file's write path on scratch directories (`SPEC/containers.md` §The container file; Tier-2, W47.ct-spec):
/// new files only inside `.archivesuite`, nothing else touched, and a link, a newer or unreadable document, or a
/// change since reading is refused rather than overwritten.
final class ContainerFileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var suite: URL { dir.appendingPathComponent(ContainerFile.folderName, isDirectory: true) }
    private var target: URL { ContainerFileStore.containerFileURL(in: dir) }

    private func sample(_ box: String = "Box 17") -> ContainerFile {
        ContainerFile(directory: ContainerFieldSet([.repository: ContainerValue("Hoover", source: .user)]),
                      runs: [ContainerRun(start: "0001.pdf", level: .box,
                                          fields: ContainerFieldSet([.container: ContainerValue(box, source: .label,
                                                                                                reader: "vision+parser",
                                                                                                confidence: 0.97)]))],
                      updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Every file under `dir` outside `.archivesuite`, with its bytes and extended attributes.
    private func snapshot() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        for case let url as URL in e where !url.pathComponents.contains(ContainerFile.folderName) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            var data = try Data(contentsOf: url)
            let n = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            if n > 0 {
                var names = [CChar](repeating: 0, count: n)
                _ = listxattr(url.path, &names, n, XATTR_NOFOLLOW)
                data.append(contentsOf: names.map { UInt8(bitPattern: $0) })
            }
            out[url.lastPathComponent] = data
        }
        return out
    }

    func testWritesANewFileAndReadsItBackWithoutTouchingAnythingElse() throws {
        let photo = dir.appendingPathComponent("0001.pdf")
        try Data("%PDF-1.4 scratch".utf8).write(to: photo)
        XCTAssertEqual(setxattr(photo.path, "com.apple.metadata:_kMDItemUserTags", "x", 1, 0, 0), 0)
        let before = try snapshot()

        XCTAssertEqual(ContainerFileStore.load(directory: dir), .missing)
        try ContainerFileStore.write(sample(), directory: dir, expecting: nil)
        XCTAssertEqual(try snapshot(), before, "files beside it are untouched, bytes and xattrs")

        guard case .loaded(let back, _) = ContainerFileStore.load(directory: dir) else { return XCTFail("not loaded") }
        XCTAssertEqual(back, sample())
        let names = try FileManager.default.contentsOfDirectory(atPath: suite.path)
        XCTAssertEqual(names, [ContainerFile.fileName], "no temporary file left behind")
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("\"2027-01-15T08:00:00Z\""), "whole-second ISO 8601")
    }

    func testAnUpdateNeedsTheStampOfTheLoadItCameFrom() throws {
        try ContainerFileStore.write(sample(), directory: dir, expecting: nil)
        let stamp = try XCTUnwrap(ContainerFileStore.load(directory: dir).stamp)
        XCTAssertThrowsError(try ContainerFileStore.write(sample("Box 18"), directory: dir, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .changedSinceRead)
        }
        try ContainerFileStore.write(sample("Box 18"), directory: dir, expecting: stamp)
        XCTAssertThrowsError(try ContainerFileStore.write(sample("Box 19"), directory: dir, expecting: stamp),
                             "the first update changed the file, so the old stamp is stale") {
            XCTAssertEqual($0 as? ContainerWriteError, .changedSinceRead)
        }
        XCTAssertEqual(ContainerFileStore.load(directory: dir).document?.runs.first?.fields[.container]?.value, "Box 18")
    }

    func testANewerDocumentIsNeitherReadNorOverwritten() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let newer = Data(#"{"schemaVersion": 2, "whatever": true}"#.utf8)
        try newer.write(to: target)
        XCTAssertEqual(ContainerFileStore.load(directory: dir), .newer)
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil))
        XCTAssertEqual(try Data(contentsOf: target), newer)
    }

    func testAnUnreadableDocumentIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let junk = Data("not json".utf8)
        try junk.write(to: target)
        guard case .unreadable = ContainerFileStore.load(directory: dir) else { return XCTFail("read junk") }
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil)) {
            guard case .refusedExisting = $0 as? ContainerWriteError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), junk)
    }

    func testLinksAreRefusedAndTheirTargetsUntouched() throws {
        // A linked document.
        let elsewhere = dir.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        guard case .unreadable = ContainerFileStore.load(directory: dir) else { return XCTFail("followed a link") }
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary(ContainerFile.fileName))
        }
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("{}".utf8))

        // A linked `.archivesuite`.
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: sub.appendingPathComponent(ContainerFile.folderName),
                                                   withDestinationURL: other)
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: sub, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary(ContainerFile.folderName))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testAMissingDirectoryIsNeverCreated() {
        let gone = dir.appendingPathComponent("not-here", isDirectory: true)
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: gone, expecting: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    func testTheLevelMapRoundTripsAndTheNearestOneIsFound() throws {
        let root = dir!
        let deep = root.appendingPathComponent("Hoover/Glotzer/Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let map = ContainerLevelMap(levels: [.repository, .collection, .box],
                                    overrides: ["05 Final Tagging": .init(role: .ignore)],
                                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(ContainerFileStore.locateLevelMap(from: deep, within: root))
        try ContainerFileStore.writeLevelMap(map, root: root, expecting: nil)
        XCTAssertEqual(ContainerFileStore.loadLevelMap(root: root).document, map)
        XCTAssertEqual(ContainerFileStore.locateLevelMap(from: deep, within: root)?.standardizedFileURL.pathComponents,
                       root.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
        XCTAssertNil(ContainerFileStore.locateLevelMap(from: FileManager.default.temporaryDirectory, within: deep))
    }
}
