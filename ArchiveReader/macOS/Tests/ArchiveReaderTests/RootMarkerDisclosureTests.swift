// RootMarkerDisclosureTests.swift — W40.f2: the Reader writes a file into the archive root it is given.
//
// The Core Directive (`ArchiveReader/CLAUDE.md`) says Finder-tag metadata is "the *only* thing the app
// ever changes" and that everything but deliberate tag edits is "strictly read-only". But choosing a
// folder runs `RootFolderStore.setRoot` → `loadOrEnsureMarker` → `RootMarker.ensure`, which creates
// `.archive-suite-root.json` inside that folder. Once the owner points the Reader at the corpus, that is
// a new file in the corpus tree that nobody asked for and the directive does not mention.
//
// These tests demonstrate the write on the real adoption paths (the open-panel pick and the relaunch
// re-resolve), show what it does and does not touch, and show that reading works without it. They
// assert what the app does TODAY; whether to keep, defer or disclose the write is the owner's call
// (Daemon Report, gate `W40.root-marker-owner-ok`).
//
// FILE SAFETY: every root is an `mktemp`-style scratch directory; every store gets a throwaway
// `UserDefaults` suite, so the owner's real `archiveRootBookmark` is never read or written.

import XCTest
import CryptoKit
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class RootMarkerDisclosureTests: XCTestCase {

    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "RootMarkerDisclosureTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// A scratch archive root holding one tagged PDF, as a corpus folder would.
    private func makeArchive(_ name: String = #function) throws -> (root: URL, pdf: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("W40f2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let pdf = root.appendingPathComponent("00001 IMG — Box 1.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["page one", "Classification: Start"], to: pdf))
        try (pdf as NSURL).setResourceValue(["1981", "Unread"], forKey: .tagNamesKey)
        return (root, pdf)
    }

    private func listing(_ dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Read tags through a fresh `URL` — a reused one answers from its resource-value cache.
    private func tags(_ url: URL) throws -> [String] {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    /// The directory's own modification time, by `stat(2)` (not cached).
    private func mtime(_ url: URL) -> timespec {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        return st.st_mtimespec
    }

    private var markerPath: String { RootMarker.filename }

    // MARK: - The write

    /// Choosing a folder — and nothing else: no link copied, no tag edited — writes a new file into it.
    func testChoosingAFolderWritesAnIdentityFileIntoIt() throws {
        let (root, pdf) = try makeArchive()
        let before = try listing(root)
        let pdfHash = try sha256(pdf)
        let pdfTags = try tags(pdf)
        let rootMtime = mtime(root)
        XCTAssertFalse(before.contains(markerPath), "precondition: the archive has no marker")
        Thread.sleep(forTimeInterval: 0.01)   // so a directory mtime change is observable

        let store = RootFolderStore(defaults: scratchDefaults())
        XCTAssertNil(store.setRoot(root), "the folder is adopted")

        let after = try listing(root)
        XCTAssertEqual(after.subtracting(before), [markerPath],
                       "exactly one new entry appears in the archive root: the identity file")
        XCTAssertTrue(before.isSubset(of: after), "nothing that was there is gone")
        let changed = mtime(root)
        XCTAssertFalse(changed.tv_sec == rootMtime.tv_sec && changed.tv_nsec == rootMtime.tv_nsec,
                       "the root directory itself is modified (a new entry)")

        // What it does NOT touch: the archive's own files.
        XCTAssertEqual(try sha256(pdf), pdfHash, "the PDF's bytes are unchanged")
        XCTAssertEqual(try tags(pdf), pdfTags, "the PDF's tags are unchanged")

        // What it writes: a small JSON identity, kind reader, named after the folder.
        let marker = try XCTUnwrap(RootMarker.read(at: root))
        XCTAssertEqual(marker.kind, .reader)
        XCTAssertEqual(marker.name, root.lastPathComponent)
        XCTAssertEqual(store.rootMarker, marker, "and that is the identity links are minted from")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(markerPath).path)[.size] as? Int)
        XCTAssertLessThan(size, 512, "a few hundred bytes")
    }

    /// The write is once: a second launch reads the marker and leaves its bytes alone.
    func testARelaunchReadsTheMarkerAndDoesNotRewriteIt() throws {
        let (root, _) = try makeArchive()
        let defaults = scratchDefaults()
        XCTAssertNil(RootFolderStore(defaults: defaults).setRoot(root))
        let markerURL = root.appendingPathComponent(markerPath)
        let firstBytes = try Data(contentsOf: markerURL)
        let firstMtime = mtime(markerURL)
        Thread.sleep(forTimeInterval: 0.01)

        let relaunched = RootFolderStore(defaults: defaults)   // init → reResolveSavedRoot
        XCTAssertEqual(relaunched.root?.standardizedFileURL.path, root.standardizedFileURL.path)

        XCTAssertEqual(try Data(contentsOf: markerURL), firstBytes)
        let again = mtime(markerURL)
        XCTAssertTrue(again.tv_sec == firstMtime.tv_sec && again.tv_nsec == firstMtime.tv_nsec,
                      "the existing marker is not rewritten")
    }

    /// …but if it is removed (say, by someone tidying the corpus), the next launch writes a NEW one
    /// with a different GUID, silently, and every link copied before then names a root that no
    /// longer exists.
    func testARemovedMarkerIsSilentlyReplacedWithANewIdentity() throws {
        let (root, _) = try makeArchive()
        let defaults = scratchDefaults()
        let first = RootFolderStore(defaults: defaults)
        XCTAssertNil(first.setRoot(root))
        let originalGUID = try XCTUnwrap(first.rootMarker?.guid)

        try FileManager.default.removeItem(at: root.appendingPathComponent(markerPath))

        let relaunched = RootFolderStore(defaults: defaults)
        let newGUID = try XCTUnwrap(relaunched.rootMarker?.guid,
                                    "the relaunch wrote a marker again, with nobody asking")
        XCTAssertNotEqual(newGUID, originalGUID,
                          "a new identity: links copied under the old one no longer resolve here")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(markerPath).path))
    }

    // MARK: - Reading does not need it

    /// A folder the Reader cannot write is still adopted and read; only link-making is refused. So
    /// the write serves durable links alone, and nothing else in the Reader depends on it.
    func testAFolderThatCannotBeWrittenIsStillOpenedAndRead() throws {
        try XCTSkipIf(getuid() == 0, "running as root defeats the permission fixture")
        let (root, pdf) = try makeArchive()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        let store = RootFolderStore(defaults: scratchDefaults())
        XCTAssertNil(store.setRoot(root), "a read-only folder is adopted all the same")

        XCTAssertNotNil(store.root)
        XCTAssertEqual(store.markerState.degradation, .notWritable,
                       "only the identity is missing, and the app says so when a link is asked for")
        XCTAssertNil(store.rootMarker)
        XCTAssertFalse(try listing(root).contains(markerPath), "and nothing was written")
        XCTAssertEqual(try tags(pdf), ["1981", "Unread"], "its files' tags still read")
    }
}
