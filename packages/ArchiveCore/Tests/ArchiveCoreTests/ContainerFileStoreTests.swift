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
                for name in names.split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) {
                    let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    var value = [UInt8](repeating: 0, count: max(0, size))
                    _ = getxattr(url.path, name, &value, value.count, 0, XATTR_NOFOLLOW)
                    data.append(contentsOf: Array(name.utf8) + value)
                }
            }
            var st = stat()
            lstat(url.path, &st)
            data.append(contentsOf: Array("\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)".utf8))
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

    /// W47.ct-reader-edit-undo: a write returns the stamp of what it put in place, so an undo can check the file is
    /// still that one; a later write makes it stale.
    func testAWriteReturnsTheStampTheNextReadSees() throws {
        let first = try ContainerFileStore.write(sample(), directory: dir, expecting: nil)
        XCTAssertEqual(ContainerFileStore.load(directory: dir).stamp, first)
        let second = try ContainerFileStore.write(sample("Box 18"), directory: dir, expecting: first)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(ContainerFileStore.load(directory: dir).stamp, second)
        let names = try ContainerFileStore.writeNames(ContainerNames(), root: dir, expecting: nil)
        XCTAssertEqual(ContainerFileStore.loadNames(root: dir).stamp, names)
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

    func testAWriterNeverOverwritesValuesItsReadingDropped() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let newer = Data(#"""
        {"schemaVersion": 1, "directory": {"fields": {"shelfmark": {"value": "S-12", "source": "user"},
          "repository": {"value": "Hoover", "source": "finding-aid"}}}, "runs": []}
        """#.utf8)
        try newer.write(to: target)
        let load = ContainerFileStore.load(directory: dir)
        let stamp = try XCTUnwrap(load.stamp)
        XCTAssertTrue(stamp.droppedOnReading)
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: stamp)) {
            guard case .refusedExisting = $0 as? ContainerWriteError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), newer)

        // Our own document, fractions in a date and nulls included, reads whole.
        let ours = Data(#"{"schemaVersion": 1, "directory": {"fields": {}}, "runs": [], "updatedAt": "2026-11-17T10:00:00.5Z", "x": null}"#.utf8)
        try ours.write(to: target)
        XCTAssertEqual(ContainerFileStore.load(directory: dir).stamp?.droppedOnReading, false)
    }

    func testWhatReadingDropsIsNotedAndNothingElse() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let value = #"{"value": "Box 1", "source": "label"}"#
        let cases: [(String, Bool)] = [
            // Runs out of order, nulls and date fractions: all ours, nothing dropped.
            (#"{"schemaVersion": 1, "runs": [{"start": "b", "level": "box"}, {"start": "a", "level": "box", "fields": null}], "updatedAt": "2026-11-17T10:00:00.5Z", "x": null}"#, false),
            (#"{"schemaVersion": 1, "future": 1}"#, true),
            (#"{"schemaVersion": 1, "directory": 5}"#, true),
            (#"{"schemaVersion": 1, "directory": {"fields": 5}}"#, true),
            (#"{"schemaVersion": 1, "directory": {"fields": {}, "extra": 1}}"#, true),
            (#"{"schemaVersion": 1, "runs": "x"}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box", "fields": 5}]}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box", "note": "x"}]}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box"}, {"start": "a", "level": "box"}]}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box", "fields": {"container": {"value": "Box 1", "source": "label", "confidence": "0.9"}}}]}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box", "fields": {"container": {"value": "Box 1", "source": "label", "confidence": 1.5}}}]}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box", "fields": {"container": \#(value)}}], "updatedAt": "soon"}"#, true),
            (#"{"schemaVersion": 1, "runs": [{"start": "a", "level": "box", "fields": {"container": \#(value)}}]}"#, false),
        ]
        for (body, dropped) in cases {
            try Data(body.utf8).write(to: target)
            XCTAssertEqual(ContainerFileStore.load(directory: dir).stamp?.droppedOnReading, dropped, body)
        }
    }

    func testSettingAsideKeepsTheOldDocumentAndOnlyOnRequest() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let junk = Data("not json".utf8)
        try junk.write(to: target)
        try ContainerFileStore.write(sample(), directory: dir, expecting: nil, settingAside: true)
        XCTAssertEqual(ContainerFileStore.load(directory: dir).document, sample())
        let names = try FileManager.default.contentsOfDirectory(atPath: suite.path).sorted()
        XCTAssertEqual(names.count, 2)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("containers.json.set-aside-") })
        XCTAssertEqual(try Data(contentsOf: suite.appendingPathComponent(aside)), junk)

        // A newer document is never set aside.
        let newer = Data(#"{"schemaVersion": 9}"#.utf8)
        try newer.write(to: target)
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil, settingAside: true))
        XCTAssertEqual(try Data(contentsOf: target), newer)
    }

    /// W49.reader-ct-set-aside: the write names the set-aside file, and putting it back swaps the two, deleting nothing;
    /// a second put-back is the redo.
    func testPuttingBackASetAsideDocumentSwapsItWithTheOneWritten() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let junk = Data("not json".utf8)
        try junk.write(to: target)
        let wrote = try ContainerFileStore.writeSettingAside(sample(), directory: dir, expecting: nil)
        let aside = try XCTUnwrap(wrote.setAsideName)
        XCTAssertTrue(aside.hasPrefix("containers.json.set-aside-"))
        XCTAssertEqual(try Data(contentsOf: suite.appendingPathComponent(aside)), junk)
        let written = try Data(contentsOf: target)

        let back = try ContainerFileStore.putBackSetAside(aside, as: ContainerFile.fileName, in: dir,
                                                          expecting: wrote.stamp)
        XCTAssertEqual(try Data(contentsOf: target), junk, "the set-aside document is the container file again")
        XCTAssertEqual(try Data(contentsOf: suite.appendingPathComponent(aside)), written, "and nothing was deleted")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: suite.path).count, 2)

        // The redo swaps them again; a stale stamp is refused and changes nothing.
        XCTAssertThrowsError(try ContainerFileStore.putBackSetAside(aside, as: ContainerFile.fileName, in: dir,
                                                                    expecting: wrote.stamp)) {
            XCTAssertEqual($0 as? ContainerWriteError, .changedSinceRead)
        }
        XCTAssertEqual(try Data(contentsOf: target), junk)
        try ContainerFileStore.putBackSetAside(aside, as: ContainerFile.fileName, in: dir, expecting: back)
        XCTAssertEqual(ContainerFileStore.load(directory: dir).document, sample())

        // Only a set-aside name of the document itself, and never a link.
        XCTAssertThrowsError(try ContainerFileStore.putBackSetAside("../x", as: ContainerFile.fileName, in: dir,
                                                                    expecting: back))
        let link = "containers.json.set-aside-link"
        try FileManager.default.createSymbolicLink(atPath: suite.appendingPathComponent(link).path,
                                                   withDestinationPath: "/etc/hosts")
        let now = try XCTUnwrap(ContainerFileStore.load(directory: dir).stamp)
        XCTAssertThrowsError(try ContainerFileStore.putBackSetAside(link, as: ContainerFile.fileName, in: dir,
                                                                    expecting: now)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary(link))
        }
        XCTAssertEqual(ContainerFileStore.load(directory: dir).document, sample())
    }

    func testAnUnreadableStandardNamesFileIsSetAsideOnlyOnRequest() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        let url = ContainerFileStore.namesURL(in: dir)
        let strict = Data(#"{"schemaVersion": 1, "names": [], "colour": "red"}"#.utf8)
        try strict.write(to: url)
        XCTAssertThrowsError(try ContainerFileStore.writeNames(ContainerNames(), root: dir, expecting: nil))
        let wrote = try ContainerFileStore.writeNamesSettingAside(ContainerNames(), root: dir, expecting: nil)
        let aside = try XCTUnwrap(wrote.setAsideName)
        XCTAssertTrue(aside.hasPrefix("container-names.json.set-aside-"))
        XCTAssertEqual(try Data(contentsOf: suite.appendingPathComponent(aside)), strict)
        try ContainerFileStore.putBackSetAside(aside, as: ContainerNames.fileName, in: dir, expecting: wrote.stamp)
        XCTAssertEqual(try Data(contentsOf: url), strict)
    }

    func testADocumentWithoutAnIntegerSchemaVersionIsUnreadable() throws {
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: false)
        for body in ["{}", #"{"schemaVersion": "1", "runs": []}"#, #"{"schemaVersion": 0}"#] {
            try Data(body.utf8).write(to: target)
            guard case .unreadable = ContainerFileStore.load(directory: dir) else { return XCTFail(body) }
            XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil), body)
        }
    }

    func testReadingThroughALinkedSuiteFolderIsRefused() throws {
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try ContainerFileStore.write(sample(), directory: other, expecting: nil)
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: sub.appendingPathComponent(ContainerFile.folderName),
                                                   withDestinationURL: other.appendingPathComponent(ContainerFile.folderName))
        guard case .unreadable = ContainerFileStore.load(directory: sub) else { return XCTFail("followed the link") }
        // A linked directory is refused too.
        let linked = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: other)
        guard case .unreadable = ContainerFileStore.load(directory: linked) else { return XCTFail("followed the link") }
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: linked, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary("the directory"))
        }
    }

    func testFilesOfTheWrongKindAreRefused() throws {
        try Data("x".utf8).write(to: suite)   // `.archivesuite` as a file
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary(ContainerFile.folderName))
        }
        XCTAssertEqual(try Data(contentsOf: suite), Data("x".utf8))
        try FileManager.default.removeItem(at: suite)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)   // the document as a folder
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary(ContainerFile.fileName))
        }
        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(mkfifo(target.path, 0o644), 0)   // a FIFO must neither hang the read nor be replaced
        guard case .unreadable = ContainerFileStore.load(directory: dir) else { return XCTFail("read a FIFO") }
        XCTAssertThrowsError(try ContainerFileStore.write(sample(), directory: dir, expecting: nil)) {
            XCTAssertEqual($0 as? ContainerWriteError, .notOrdinary(ContainerFile.fileName))
        }
    }

    func testConcurrentFirstWritersExactlyOneWins() throws {
        let results = ContainerTestCounter()
        let docs = (0..<16).map { sample("Box \($0)") }, d: URL = dir
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            do {
                try ContainerFileStore.write(docs[i], directory: d, expecting: nil)
                results.add(true)
            } catch {
                XCTAssertEqual(error as? ContainerWriteError, .changedSinceRead)
                results.add(false)
            }
        }
        XCTAssertEqual(results.wins, 1)
        XCTAssertNotNil(ContainerFileStore.load(directory: dir).document)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: suite.path), [ContainerFile.fileName])
    }

    func testConcurrentUpdatesFromOneReadExactlyOneWins() throws {
        try ContainerFileStore.write(sample(), directory: dir, expecting: nil)
        let stamp = try XCTUnwrap(ContainerFileStore.load(directory: dir).stamp)
        let results = ContainerTestCounter()
        let docs = (0..<16).map { sample("Box \($0)") }, d: URL = dir
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            results.add((try? ContainerFileStore.write(docs[i], directory: d, expecting: stamp)) != nil)
        }
        XCTAssertEqual(results.wins, 1)
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

    // MARK: Size (W49.ct-file-size-cap)

    /// A run for every file of the corpus's largest folder (7,124), as a scattered selection there makes: 2.5 MB,
    /// refused under the old 1 MB cap, written and read back now.
    func testARunForEveryFileOfTheLargestFolderIsWrittenAndRead() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let file = ContainerFile(runs: (0..<7_124).map {
            ContainerRun(start: String(format: "%05d ", $0) + String(repeating: "n", count: 128), level: .folder,
                         fields: ContainerFieldSet([.date: ContainerValue("1965", source: .user, at: at)]))
        }, updatedAt: at)
        XCTAssertNoThrow(try ContainerFileStore.checkSize(file))
        try ContainerFileStore.write(file, directory: dir, expecting: nil)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 2 * 1024 * 1024)
        XCTAssertEqual(ContainerFileStore.load(directory: dir).document, file)
    }

    func testCheckSizeRefusesWhatWriteWouldRefuse() throws {
        let data = try ContainerFileStore.encoder.encode(sample())
        XCTAssertNoThrow(try ContainerFileStore.checkSize(sample(), limit: data.count))
        XCTAssertThrowsError(try ContainerFileStore.checkSize(sample(), limit: data.count - 1)) {
            XCTAssertEqual($0 as? ContainerWriteError, .tooBig)
        }
    }

    /// A file past the cap is not read, whatever it holds; the size is looked at before any byte is read.
    func testAFilePastTheCapIsNotRead() throws {
        try ContainerFileStore.write(sample(), directory: dir, expecting: nil)
        let fd = open(target.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(ContainerFile.maxFileBytes + 1)), 0)   // sparse: no 64 MB written
        close(fd)
        guard case .unreadable(let why) = ContainerFileStore.load(directory: dir) else { return XCTFail("read") }
        XCTAssertEqual(why, "over 64 MB")
    }
}

private final class ContainerTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ won: Bool) { lock.lock(); if won { count += 1 }; lock.unlock() }
    var wins: Int { lock.lock(); defer { lock.unlock() }; return count }
}
