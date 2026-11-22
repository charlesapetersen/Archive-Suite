import XCTest
@testable import ArchiveCore

/// W47.ct-processor-intake: a folder given to Process Files read as a tree (`ContainerTree`), and the level map the
/// Processor offers for it (`ContainerLevelsDraft`, shared with the Reader). Scratch directories only; nothing here
/// writes outside them.
final class ContainerTreeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerTree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func touch(_ path: String) throws {
        let url = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func isPhoto(_ url: URL) -> Bool { ["jpg", "pdf"].contains(url.pathExtension.lowercased()) }

    func testATreeIsReadDepthFirstInFinderOrder() throws {
        for path in ["Glotzer/label.jpg", "Glotzer/Box 10/Folder 2/b.jpg", "Glotzer/Box 10/Folder 2/a.jpg",
                     "Glotzer/Box 10/Folder 10/c.jpg", "Glotzer/Box 9/Folder 1/d.pdf", "Glotzer/Box 9/notes.txt",
                     "Glotzer/.hidden/e.jpg", "Glotzer/Box 9/.archivesuite/containers.json", "Glotzer/Box 9/.f.jpg"] {
            try touch(path)
        }
        let entries = ContainerTree.files(in: scratch.appendingPathComponent("Glotzer"), accept: isPhoto)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["label.jpg", "d.pdf", "a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(entries.map(\.directory), [["Glotzer"], ["Glotzer", "Box 9", "Folder 1"],
                                                  ["Glotzer", "Box 10", "Folder 2"], ["Glotzer", "Box 10", "Folder 2"],
                                                  ["Glotzer", "Box 10", "Folder 10"]])
        XCTAssertTrue(ContainerTree.isTree(entries))
    }

    func testAFlatFolderIsNotATree() throws {
        try touch("Box 17/a.jpg")
        try touch("Box 17/Empty/notes.txt")
        let entries = ContainerTree.files(in: scratch.appendingPathComponent("Box 17"), accept: isPhoto)
        XCTAssertEqual(entries.map(\.directory), [["Box 17"]])
        XCTAssertFalse(ContainerTree.isTree(entries))
    }

    func testLinksToFoldersAndPackagesAreNotEntered() throws {
        try touch("Outside/x.jpg")
        try touch("Tree/Box 1/a.jpg")
        try touch("Tree/Doc.app/b.jpg")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: scratch.appendingPathComponent("Tree/Box 2"),
                                  withDestinationURL: scratch.appendingPathComponent("Outside"))
        try fm.createSymbolicLink(at: scratch.appendingPathComponent("Tree/Box 3.jpg"),
                                  withDestinationURL: scratch.appendingPathComponent("Outside"))
        try fm.createSymbolicLink(at: scratch.appendingPathComponent("Tree/Box 1/loop"),
                                  withDestinationURL: scratch.appendingPathComponent("Tree"))
        let entries = ContainerTree.files(in: scratch.appendingPathComponent("Tree"), accept: isPhoto)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["a.jpg"])
    }

    func testDepthLimitReportsEachSkippedBranchInFinderOrder() throws {
        let withinLimit = "Tree/" + Array(repeating: "Level", count: ContainerTree.maxDepth).joined(separator: "/")
        try touch("\(withinLimit)/last.jpg")
        try touch("\(withinLimit)/Folder 10/ignored.jpg")
        try touch("\(withinLimit)/Folder 2/Nested/ignored.jpg")
        try touch("\(withinLimit)/.hidden/ignored.jpg")
        try touch("\(withinLimit)/Package.app/ignored.jpg")
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("\(withinLimit)/Link"),
                                                   withDestinationURL: scratch.appendingPathComponent("Tree"))

        var skipped: [String] = []
        let entries = ContainerTree.files(in: scratch.appendingPathComponent("Tree"),
                                         onDepthLimit: { skipped.append($0.lastPathComponent) }, accept: isPhoto)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["last.jpg"])
        XCTAssertEqual(skipped, ["Folder 2", "Folder 10"])
    }

    func testRelativePathsStayInsideTheOutputFolder() {
        XCTAssertEqual(ContainerTree.relativePath(["Glotzer", "Box 17"]), "Glotzer/Box 17")
        XCTAssertNil(ContainerTree.relativePath([]))
        XCTAssertNil(ContainerTree.relativePath(["Glotzer", ".."]))
        XCTAssertNil(ContainerTree.relativePath([".archivesuite"]))
        XCTAssertNil(ContainerTree.relativePath(["a/b"]))
        XCTAssertNil(ContainerTree.relativePath([""]))
        XCTAssertEqual(ContainerTree.components(ofRelativePath: "Glotzer/Box 17"), ["Glotzer", "Box 17"])
        XCTAssertNil(ContainerTree.components(ofRelativePath: "Glotzer//Box 17"))
        XCTAssertNil(ContainerTree.components(ofRelativePath: "../x"))
    }

    /// The map the Processor offers for a dropped tree, from each file's folders below the output folder: the dropped
    /// folder's own name is level 1.
    func testTheOfferedMapReadsTheDroppedFolderAsLevelOne() throws {
        for path in ["Glotzer papers/Box 17/Folder 8/a.jpg", "Glotzer papers/Box 17/Folder 9/b.jpg",
                     "Glotzer papers/Box 18/Folder 1/c.jpg"] {
            try touch(path)
        }
        let entries = ContainerTree.files(in: scratch.appendingPathComponent("Glotzer papers"), accept: isPhoto)
        let draft = ContainerLevelsDraft.make(directories: entries.map(\.directory), tree: scratch,
                                              treePath: scratch.path)
        XCTAssertEqual(draft.map.levels, [.collection, .box, .folder])
        XCTAssertEqual(draft.examples[1], ["Box 17", "Box 18"])
        let fields = draft.map.pathFields(for: ["Glotzer papers", "Box 17", "Folder 8"])
        XCTAssertEqual(fields[0].values[.collectionTitle]?.value, "Glotzer papers")
        XCTAssertEqual(fields[1].values[.container]?.value, "Box 17")
        XCTAssertEqual(fields[2].values[.folder]?.value, "8")
    }
}
