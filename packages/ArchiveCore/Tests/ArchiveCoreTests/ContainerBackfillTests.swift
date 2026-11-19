import XCTest
@testable import ArchiveCore

/// W47.ct-backfill: an existing folder's markers found, proposed as runs, and written only when the user accepts a
/// directory (`ContainerBackfill`, `SPEC/containers.md` §Backfill). Scratch directories only: every test checks that
/// the photos' bytes and tags are untouched and that nothing but `.archivesuite/containers.json` is added.
final class ContainerBackfillTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func file(_ path: String, tags: [String] = [], label: Int? = nil) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo \(path)".utf8).write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func label(_ v: String) -> ContainerValue { ContainerValue(v, source: .label, reader: "vision+parser") }
    private func user(_ v: String) -> ContainerValue { ContainerValue(v, source: .user) }

    /// Every regular file below the scratch root with its bytes, so a test can say nothing but the container file moved.
    private func snapshot() -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = e?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: scratch.standardizedFileURL.path + "/", with: "")
            out[rel] = try? Data(contentsOf: url)
        }
        return out
    }

    private func markers(_ d: ContainerBackfill.Directory, reads: [String: ContainerFieldSet]) -> [ContainerMarker] {
        d.markers.map { ContainerMarker(fileName: $0.fileName, type: $0.type, read: reads[$0.fileName] ?? ContainerFieldSet()) }
    }

    func testTheScanFindsMarkersByTagAndByTheRootsColoursAndReadsOnlyTags() throws {
        try file("Glotzer/0001.pdf", label: 6)                // Red: a box under the older colours
        try file("Glotzer/0002.pdf")
        try file("Glotzer/0003.pdf", label: 3)                // Purple: a folder
        try file("Glotzer/0004.jpg", tags: ["Folder"])        // the token, whatever the colour
        try file("Glotzer/notes.txt", label: 6)               // not a photo
        try file("Glotzer/Box 2/0010.pdf", tags: ["Box"])
        try file("Glotzer/.archivesuite/x.pdf", tags: ["Box"]) // hidden: not entered
        let before = snapshot()

        let plain = try XCTUnwrap(ContainerBackfill.scan(root: scratch, colours: .none))
        XCTAssertEqual(plain.directories.map(\.relativePath), ["Glotzer", "Glotzer/Box 2"])
        XCTAssertEqual(plain.directories[0].markers.map(\.fileName), ["0004.jpg"], "no colours: only the token")
        XCTAssertEqual(plain.fileDirectories, [["Glotzer"], ["Glotzer"], ["Glotzer"], ["Glotzer"], ["Glotzer", "Box 2"]])

        let scan = try XCTUnwrap(ContainerBackfill.scan(root: scratch, colours: .redBoxPurpleFolder))
        XCTAssertEqual(scan.directories[0].markers.map(\.fileName), ["0001.pdf", "0003.pdf", "0004.jpg"])
        XCTAssertEqual(scan.directories[0].markers.map(\.type), [.box, .folder, .folder])
        XCTAssertEqual(scan.directories[0].fileCount, 4)
        XCTAssertEqual(scan.markerCount, 4)
        XCTAssertEqual(scan.fileCount, 5)
        XCTAssertEqual(snapshot(), before, "a scan writes nothing")
        XCTAssertNil(ContainerBackfill.scan(root: scratch, colours: .none, isCancelled: { true }))
    }

    func testAProposalWritesNothingAndAcceptWritesOnlyTheContainerFile() throws {
        try file("Kristol/0001.pdf", tags: ["Box"])
        try file("Kristol/0002.pdf")
        try file("Kristol/0003.pdf", tags: ["Folder"])
        try file("Kristol/0004.pdf")
        let before = snapshot()
        let scan = try XCTUnwrap(ContainerBackfill.scan(root: scratch, colours: .none))
        let dir = scan.directories[0]
        let reads = ["0001.pdf": ContainerFieldSet([.container: label("Box 10"), .collectionTitle: label("Irving Kristol Papers")]),
                     "0003.pdf": ContainerFieldSet([.folder: label("3")])]
        let proposal = ContainerBackfill.propose(markers(dir, reads: reads), in: dir.url)
        XCTAssertEqual(proposal.state, .ready)
        XCTAssertNil(proposal.base)
        XCTAssertEqual(proposal.changedRuns.map(\.level), [.collection, .box, .folder])
        XCTAssertEqual(snapshot(), before, "a proposal writes nothing")

        XCTAssertEqual(try ContainerBackfill.accept(proposal, root: scratch), .wrote)
        var after = snapshot()
        let written = try XCTUnwrap(after.removeValue(forKey: "Kristol/.archivesuite/containers.json"))
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(after, before, "only the container file is added; the photos' bytes are untouched")
        XCTAssertEqual(TagReading.read(dir.url.appendingPathComponent("0001.pdf")).tagNames, ["Box"])
        let stored = try XCTUnwrap(ContainerFileStore.load(directory: dir.url).document)
        XCTAssertEqual(stored.runs, proposal.proposed.runs)

        // Proposing the same reads again changes nothing.
        let again = ContainerBackfill.propose(markers(dir, reads: reads), in: dir.url)
        XCTAssertEqual(again.state, .unchanged)
        XCTAssertEqual(try ContainerBackfill.accept(again, root: scratch), .unchanged)
    }

    func testAFileChangedAfterTheProposalIsNotOverwritten() throws {
        try file("Shils/0001.pdf", tags: ["Box"])
        let scan = try XCTUnwrap(ContainerBackfill.scan(root: scratch, colours: .none))
        let dir = scan.directories[0]
        let proposal = ContainerBackfill.propose(markers(dir, reads: ["0001.pdf": ContainerFieldSet([.container: label("Box 101")])]),
                                                 in: dir.url)
        // The Reader edits the folder meanwhile.
        let edited = ContainerFile(runs: [ContainerRun(start: "0001.pdf", level: .box,
                                                       fields: ContainerFieldSet([.container: user("Box 110")]))])
        try ContainerFileStore.write(edited, directory: dir.url.resolvingSymlinksInPath(), expecting: nil)
        XCTAssertEqual(try ContainerBackfill.accept(proposal, root: scratch), .changedSinceRead)
        XCTAssertEqual(ContainerFileStore.load(directory: dir.url).document?.runs, edited.runs)

        // A fresh proposal keeps the user's value and says so.
        let fresh = ContainerBackfill.propose(markers(dir, reads: ["0001.pdf": ContainerFieldSet([.container: label("Box 101")])]),
                                              in: dir.url)
        XCTAssertEqual(fresh.proposed.runs.first?.fields.values[.container]?.value, "Box 110")
        XCTAssertTrue(fresh.warnings.contains { if case .readDisagreesWithUser = $0.kind { return true } else { return false } })
    }

    func testANewerOrUnreadableFileIsBlockedAndLeftAlone() throws {
        try file("Newer/0001.pdf", tags: ["Box"])
        try file("Broken/0001.pdf", tags: ["Box"])
        let newer = scratch.appendingPathComponent("Newer/.archivesuite/containers.json")
        let broken = scratch.appendingPathComponent("Broken/.archivesuite/containers.json")
        try FileManager.default.createDirectory(at: newer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "runs": []}"#.utf8).write(to: newer)
        try Data("not json".utf8).write(to: broken)
        let before = snapshot()
        let scan = try XCTUnwrap(ContainerBackfill.scan(root: scratch, colours: .none))
        for dir in scan.directories {
            let p = ContainerBackfill.propose(markers(dir, reads: ["0001.pdf": ContainerFieldSet([.container: label("Box 1")])]),
                                              in: dir.url)
            guard case .blocked = p.state else { return XCTFail("\(dir.relativePath) should be blocked: \(p.state)") }
            guard case .refused = try ContainerBackfill.accept(p, root: scratch) else { return XCTFail("accepted") }
        }
        XCTAssertEqual(snapshot(), before)
    }

    func testAFolderSwappedForALinkIsRefused() throws {
        try file("Real/0001.pdf", tags: ["Box"])
        try file("Elsewhere/0001.pdf")
        let scan = try XCTUnwrap(ContainerBackfill.scan(root: scratch, colours: .none))
        let dir = try XCTUnwrap(scan.directories.first { $0.relativePath == "Real" })
        let proposal = ContainerBackfill.propose(markers(dir, reads: ["0001.pdf": ContainerFieldSet([.container: label("Box 1")])]),
                                                 in: dir.url)
        try FileManager.default.moveItem(at: dir.url, to: scratch.appendingPathComponent("Moved"))
        try FileManager.default.createSymbolicLink(at: dir.url, withDestinationURL: scratch.appendingPathComponent("Elsewhere"))
        guard case .refused = try ContainerBackfill.accept(proposal, root: scratch) else { return XCTFail("accepted through a link") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Elsewhere/.archivesuite").path))
        XCTAssertNil(ContainerBackfill.realDirectory(scratch.appendingPathComponent("Other/x"), inside: scratch.appendingPathComponent("Real")))
    }
}
