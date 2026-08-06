import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.symroot-fu1 — everything in the Reader that compares a DISCOVERED path against the granted
/// root, exercised under a root whose spelling is not the one the walker reports.
///
/// The fixture is a **mid-path** symlink, chosen deliberately. `CorpusWalker.canonicalRoot` resolves
/// only a symlinked FINAL component, so a root spelled `…/link/corpus` reaches the enumerator
/// byte-for-byte as the caller wrote it while every entry comes back under `…/real/corpus`. Nothing
/// upstream papers over the divergence, and it is the same shape as any `/var/folders` root — which
/// is why the sidebar folder tree had never placed a file under a fixture root.
///
/// Scratch `mktemp` fixtures only; the store is pinned with the volatile `ARUITestRootPath` argument
/// domain, so no test here reads or writes the owner's `archiveRootBookmark`.
@MainActor
final class SymlinkedRootTests: XCTestCase {

    /// `(rootAsSpelled, realRoot)` — a root reachable both ways, with `Box/report.pdf` inside it.
    private func makeLinkedRoot(marker guid: UUID = UUID()) throws -> (linked: URL, real: URL, file: URL) {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SymlinkedRootTests-\(UUID().uuidString)", isDirectory: true)
        let real = scratch.appendingPathComponent("real", isDirectory: true)
        let corpus = real.appendingPathComponent("corpus", isDirectory: true)
        let box = corpus.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createSymbolicLink(
            at: scratch.appendingPathComponent("link", isDirectory: true), withDestinationURL: real)

        let rootMarker = RootMarker(guid: guid, name: "scratch", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(rootMarker).write(to: corpus.appendingPathComponent(RootMarker.filename))
        let file = box.appendingPathComponent("report.pdf")
        try Data("scratch PDF".utf8).write(to: file)
        try (file as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)

        let linked = scratch.appendingPathComponent("link", isDirectory: true)
            .appendingPathComponent("corpus", isDirectory: true)
        XCTAssertNotEqual(linked.path, corpus.path, "precondition: the two spellings really differ")
        return (linked, corpus, file)
    }

    private func navModel(pinnedTo root: URL) -> NavigationModel {
        UserDefaults.standard.set(root.path, forKey: "ARUITestRootPath")
        UserDefaults.standard.removeObject(forKey: "lastSelectionFileURLs")
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "ARUITestRootPath")
            UserDefaults.standard.removeObject(forKey: "lastSelectionFileURLs")
        }
        return NavigationModel()
    }

    /// `library.files` is populated synchronously for a fixture root, but `displayed` and
    /// `folderTree` are derived through a `receive(on: .main)` sink — so they need a run-loop turn.
    /// Spun rather than slept: a fixed sleep is either slower than it needs to be or flaky.
    private func spin(untilTrue condition: () -> Bool, _ what: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }

    /// The sidebar tree must PLACE the file, not merely count it.
    ///
    /// `buildFolderTree` stripped `rootStore.root?.path` off each discovered path and skipped any that
    /// did not start with it — but it had already incremented the root's recursive total, so the
    /// symptom was a sidebar claiming N documents at the root with no folder under it holding any of
    /// them.
    func testTheFolderTreePlacesFilesDiscoveredUnderALinkedRoot() throws {
        let fixture = try makeLinkedRoot()
        let model = navModel(pinnedTo: fixture.linked)

        XCTAssertTrue(model.library.files.contains { $0.url.path == fixture.file.path },
                      "precondition: discovery finds the file, spelled under the target")
        spin(untilTrue: { model.folderTree != nil }, "the sidebar tree to be built")
        let tree = try XCTUnwrap(model.folderTree, "a non-empty library must produce a tree")
        XCTAssertEqual(tree.fileCount, 1, "the recursive total has always been right — it is the trap")
        XCTAssertEqual(tree.children.map(\.name), ["Box"],
                       "and the file must actually be PLACED in its folder, not just counted at the root")
        XCTAssertEqual(tree.children.first?.fileCount, 1)
    }

    /// A deep link must reveal a file that is on screen.
    ///
    /// The reveal target was composed from the root URL and then matched against `file.url.path`,
    /// which is the walker's spelling — so three settled misses later the user was told "Document not
    /// found in the current archive" about a row they could see.
    func testADeepLinkRevealsAFileListedUnderALinkedRoot() throws {
        let guid = UUID()
        let fixture = try makeLinkedRoot(marker: guid)
        let model = navModel(pinnedTo: fixture.linked)
        XCTAssertEqual(model.rootStore.rootMarker?.guid, guid, "precondition: the marker was read")

        model.revealAndSelect(rootGUID: guid, relativePath: "Box/report.pdf", page: nil)

        XCTAssertEqual(model.selection, [fixture.file], "the reveal selects the row it named")
        XCTAssertEqual(model.statusMessage, "", "…and says nothing about a missing document")
    }

    /// A copied durable link must stay root-relative.
    ///
    /// `ArchiveLinkWriter` falls back to `lastPathComponent` when a file path is not under the root
    /// prefix — a quiet degradation, not an error, so every link copied under such a root lost its
    /// folder and would resolve to the wrong file (or none) in any archive with a duplicate name.
    func testACopiedArchiveLinkKeepsTheRootRelativePathUnderALinkedRoot() async throws {
        let guid = UUID()
        let fixture = try makeLinkedRoot(marker: guid)
        let model = navModel(pinnedTo: fixture.linked)
        let file = try XCTUnwrap(model.library.files.first { $0.url.path == fixture.file.path })
        // Through the published `ArchiveLinkTarget`, not by handing the writer a prefix directly —
        // that is the value a document window actually copies from, and it is where the root's
        // spelling is chosen.
        let context = ArchiveLinkContext()
        model.attach(linkContext: context)
        let target = try XCTUnwrap(context.target, "a root with a readable marker publishes a target")

        let item = await ArchiveLinkWriter.pasteboardItem(for: [file], rootPath: target.rootPath,
                                                          marker: target.marker, thumbnailer: nil)
        let text = try XCTUnwrap(item.string(forType: .string))

        XCTAssertTrue(text.contains("Box/report.pdf") || text.contains("Box%2Freport.pdf"),
                      "the link must carry the root-relative path, got: \(text)")
        XCTAssertFalse(text.hasSuffix("=report.pdf"),
                       "a bare filename is the silent degradation this fixes")
    }

    /// An excluded subfolder must actually disappear.
    ///
    /// `isExcludedAbsolute` rebuilds `root + "/" + relative` and prefix-tests the discovered path, so
    /// with the caller's spelling the test never matched and the exclusion did nothing at all — which
    /// is the failure direction that leaks documents into a view the user asked to narrow.
    func testAnExcludedSubfolderIsHonouredUnderALinkedRoot() throws {
        let fixture = try makeLinkedRoot()

        // Seeded BEFORE the model exists, so the exclusion is part of the first pass rather than an
        // async `objectWillChange` hop the test has to outwait. The store is a singleton over a real
        // defaults key — snapshot and restore it, never clear it, so a test cannot quietly drop the
        // owner's own exclusions.
        let previously = UserDefaults.standard.stringArray(forKey: "ar.excludedFolders")
        addTeardownBlock {
            MainActor.assumeIsolated {
                if let previously { UserDefaults.standard.set(previously, forKey: "ar.excludedFolders") }
                else { UserDefaults.standard.removeObject(forKey: "ar.excludedFolders") }
                ExcludedFoldersStore.shared.reload()
            }
        }
        UserDefaults.standard.set(["Box"], forKey: "ar.excludedFolders")
        ExcludedFoldersStore.shared.reload()

        let model = navModel(pinnedTo: fixture.linked)
        XCTAssertTrue(model.library.files.contains { $0.url.path == fixture.file.path },
                      "precondition: the exclusion is a DISPLAY filter — discovery still finds the file")
        // Driven directly rather than waited on: `recompute()` is the production filter and it is
        // synchronous, so the assertion below cannot pass merely because an async pass had not run.
        model.recompute()

        XCTAssertTrue(model.displayed.isEmpty, "an excluded folder's documents must not reach the list")
        // The sidebar's own exclusion branch (`buildFolderTree`) is NOT asserted here on purpose: it
        // is only reachable through an async sink, and with an exclusion live that sink queues a
        // content-index prune that took ~12 s to yield the main actor — a slower whole suite in
        // exchange for re-testing the one shared value the assertion above already pins.
    }
}
