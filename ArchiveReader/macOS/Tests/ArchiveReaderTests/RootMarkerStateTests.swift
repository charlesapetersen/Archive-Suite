// RootMarkerStateTests.swift — W23.m6 functional gate (Reader side).
//
// A durable archive link is only as good as the root GUID it names. The marker layer used to hand
// the Reader a GUID even when the disk did not have one — an in-memory marker after a failed write,
// or a fresh marker minted because an EXISTING one merely failed to read — and the Reader minted
// links from it happily. Those links change GUID at the next launch and can never resolve.
//
// So the Reader now mints only from a DURABLE identity, and when there isn't one it says which of
// the four reasons applies instead of the old "Choose an archive folder first." (with a folder
// plainly open) or nothing at all.
//
// FILE SAFETY: every byte here lives in an `mktemp` scratch directory; the archive root is set via
// the volatile `ARUITestRootPath` argument domain, so the owner's real `archiveRootBookmark` is
// never read or written, and `RootFolderStore` is never constructed against it.
//
// Non-vacuity: restoring the pre-fix marker layer (a read failure reported as absence, a failed
// write returning the in-memory marker) turns `readOnlyRoot…`, `unreadableMarker…` and
// `malformedMarkerIsLeftUntouched` RED, and the two model-level tests RED on the message.

import XCTest
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class RootMarkerStateTests: XCTestCase {

    private var scratch: URL?

    private func scratchDir() throws -> URL {
        if let scratch { return scratch }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("W23m6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A fresh root directory inside the scratch area.
    private func makeRoot(_ name: String = "root") throws -> URL {
        let root = try scratchDir().appendingPathComponent("\(name)-\(UUID().uuidString)",
                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: - The identity itself

    func testWritableRootHasADurableIdentity() throws {
        let root = try makeRoot()
        let state = RootMarkerState.ensuring(root)

        XCTAssertNotNil(state.durableMarker, "a writable root can mint links")
        XCTAssertNil(state.degradation)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(RootMarker.filename).path
        ), "and the identity it minted from is on disk, so it survives a relaunch")
    }

    func testReadOnlyRootDegradesInsteadOfHandingOutAnUnpersistedIdentity() throws {
        try XCTSkipIf(getuid() == 0, "running as root defeats the permission fixture")
        let root = try makeRoot()
        try chmod(root, 0o500)                       // r-x: readable, not writable
        addTeardownBlock { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.path) }

        let state = RootMarkerState.ensuring(root)

        XCTAssertNil(state.durableMarker,
                     "an in-memory-only GUID must never reach a link — it changes at next launch")
        XCTAssertEqual(state.degradation, .notWritable)
    }

    func testUnreadableMarkerDegradesRatherThanLookingAbsent() throws {
        try XCTSkipIf(getuid() == 0, "running as root defeats the permission fixture")
        let root = try makeRoot()
        let fileURL = root.appendingPathComponent(RootMarker.filename)
        let planted = RootMarker(guid: UUID(), name: "root", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(planted).write(to: fileURL)
        let before = try Data(contentsOf: fileURL)
        try chmod(fileURL, 0o000)

        let state = RootMarkerState.ensuring(root)

        try chmod(fileURL, 0o644)
        XCTAssertEqual(state.degradation, .unreadable,
                       "unreadable is not absence — absence is what licenses minting a replacement")
        XCTAssertNil(state.durableMarker)
        XCTAssertEqual(try Data(contentsOf: fileURL), before,
                       "the root keeps the identity every already-copied link names")
    }

    func testMalformedMarkerIsLeftUntouched() throws {
        let root = try makeRoot()
        let fileURL = root.appendingPathComponent(RootMarker.filename)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL)

        let state = RootMarkerState.ensuring(root)

        XCTAssertEqual(state.degradation, .malformed)
        XCTAssertNil(state.durableMarker)
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
    }

    func testEveryDegradationExplainsItselfDistinctly() {
        let all: [RootMarkerDegradation] = [.notWritable, .malformed, .unreadable, .failed]
        let messages = all.map(\.message)
        XCTAssertEqual(Set(messages).count, all.count, "each reason says its own thing")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - What the reader actually experiences

    /// A scratch root the navigation model will adopt, carrying one discoverable (`Unread`-tagged)
    /// PDF and a DAMAGED identity file.
    private func makeDegradedRoot() throws -> (root: URL, filePath: String) {
        let root = try makeRoot("degraded")
        try Data("{ not json".utf8).write(to: root.appendingPathComponent(RootMarker.filename))
        let pdf = root.appendingPathComponent("doc.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["page one"], to: pdf), "scratch PDF")
        try (pdf as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        return (root, pdf.path)
    }

    /// A NavigationModel pinned to a scratch root. `ARUITestRootPath` lives in the volatile argument
    /// domain, so this never reads or writes the owner's real `archiveRootBookmark`.
    private func navModel(root: URL) -> NavigationModel {
        UserDefaults.standard.set(root.path, forKey: "ARUITestRootPath")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "ARUITestRootPath") }
        return NavigationModel()
    }

    func testCopyArchiveLinksRefusesADegradedRootAndSaysWhy() throws {
        let (root, filePath) = try makeDegradedRoot()
        let model = navModel(root: root)
        let file = try XCTUnwrap(model.library.files.first { $0.url.path == filePath },
                                 "precondition: the scratch PDF is discoverable")
        model.selection = [file.id]
        XCTAssertFalse(model.selectedFiles.isEmpty, "precondition: something is selected to link to")
        XCTAssertNil(model.rootStore.rootMarker, "precondition: the root's identity is degraded")

        model.copyArchiveLinks()

        XCTAssertEqual(model.statusMessage, RootMarkerDegradation.malformed.message,
                       "it names the damaged identity file — it used to claim no folder was open")
    }

    func testRevealTellsTheTruthAboutADegradedRoot() throws {
        let (root, _) = try makeDegradedRoot()
        let model = navModel(root: root)

        model.revealAndSelect(rootGUID: UUID(), relativePath: "doc.pdf", page: nil)

        XCTAssertEqual(model.statusMessage, RootMarkerDegradation.malformed.message,
                       "the link isn't pointing at a different archive — this one has no identity")
        XCTAssertTrue(model.selection.isEmpty, "and nothing was revealed")
    }

    /// The positive control for the pair above: a root with a real identity still resolves its own
    /// links, so the refusal above is about durability, not about links being switched off.
    func testDurableRootStillResolvesItsOwnLink() throws {
        let root = try makeRoot("durable")
        let guid = UUID()
        let marker = RootMarker(guid: guid, name: "durable", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: root.appendingPathComponent(RootMarker.filename))
        let pdf = root.appendingPathComponent("doc.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["page one"], to: pdf), "scratch PDF")
        try (pdf as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)

        let model = navModel(root: root)
        XCTAssertEqual(model.rootStore.rootMarker?.guid, guid)

        model.revealAndSelect(rootGUID: guid, relativePath: "doc.pdf", page: nil)

        XCTAssertFalse(model.selection.isEmpty, "the durable root reveals its own file")
    }
}
