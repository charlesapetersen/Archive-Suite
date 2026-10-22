// W40.root-marker — owner chose (b), 2026-10-17: defer creation to explicit archive-link copy.
// Every file is scratch and every defaults domain is throwaway; never the owner's root/bookmark.
import XCTest
import CryptoKit
import AppKit
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class RootMarkerDisclosureTests: XCTestCase {
    private func makeArchive() throws -> (root: URL, pdf: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("W40-root-marker-\(UUID().uuidString)", isDirectory: true)
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

    private func tags(_ url: URL) throws -> [String] {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func mtime(_ url: URL) throws -> TimeInterval {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970
    }

    private func readyModel(_ root: URL, _ name: String = #function) async throws -> NavigationModel {
        let model = fixtureNavigationModel(pinnedTo: root, name)
        let deadline = Date().addingTimeInterval(10)
        while model.library.jpegPartnerScanStatus != .ready, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.library.jpegPartnerScanStatus, .ready)
        model.selection = Set(model.library.files.map(\.id))
        XCTAssertFalse(model.selectedFiles.isEmpty)
        return model
    }

    private func copiedLink() throws -> (UUID, String, Int?) {
        let text = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        let url = try XCTUnwrap(URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let link = try XCTUnwrap(DurableLink(url: url))
        guard case let .readerReveal(guid, path, page, _) = link else {
            throw XCTUnwrapError()
        }
        return (guid, path, page)
    }
    private struct XCTUnwrapError: Error {}

    func testChoosingAFolderDoesNotWriteAnIdentityFileIntoIt() throws {
        let (root, pdf) = try makeArchive()
        let before = try listing(root), hash = try sha256(pdf), originalTags = try tags(pdf)
        let modified = try mtime(root)
        let defaults = fixtureDefaults()
        let store = RootFolderStore(defaults: defaults)
        XCTAssertNil(store.setRoot(root))
        XCTAssertEqual(store.markerState, .absent)
        XCTAssertNil(store.rootMarker)
        XCTAssertEqual(try listing(root), before)
        XCTAssertEqual(try mtime(root), modified)
        let relaunched = RootFolderStore(defaults: defaults)
        XCTAssertNotNil(relaunched.root)
        XCTAssertEqual(relaunched.markerState, .absent)
        XCTAssertEqual(try listing(root), before)
        XCTAssertEqual(try mtime(root), modified)
        XCTAssertEqual(try sha256(pdf), hash)
        XCTAssertEqual(try tags(pdf), originalTags)
    }

    func testFirstNavigationCopyWritesOneMarkerAndKeepsItAcrossRelaunch() async throws {
        let (root, pdf) = try makeArchive()
        let before = try listing(root), hash = try sha256(pdf), originalTags = try tags(pdf)
        let model = try await readyModel(root)
        XCTAssertNil(model.rootStore.rootMarker)
        model.copyArchiveLinks()
        let marker = try XCTUnwrap(RootMarker.read(at: root))
        XCTAssertEqual(marker.kind, .reader)
        XCTAssertEqual(marker.name, root.lastPathComponent)
        let link = try copiedLink()
        XCTAssertEqual(link.0, marker.guid)
        XCTAssertEqual(link.1, pdf.lastPathComponent)
        XCTAssertEqual(try listing(root).subtracting(before), [RootMarker.filename])
        let markerURL = root.appendingPathComponent(RootMarker.filename)
        let bytes = try Data(contentsOf: markerURL), modified = try mtime(markerURL)
        model.copyArchiveLinks()
        let defaults = fixtureDefaults()
        XCTAssertNil(RootFolderStore(defaults: defaults).setRoot(root))
        let relaunched = RootFolderStore(defaults: defaults)
        XCTAssertEqual(relaunched.rootMarker, marker)
        XCTAssertEqual(try Data(contentsOf: markerURL), bytes)
        XCTAssertEqual(try mtime(markerURL), modified)
        XCTAssertLessThan(bytes.count, 512)
        XCTAssertEqual(try sha256(pdf), hash)
        XCTAssertEqual(try tags(pdf), originalTags)
    }

    func testFirstPageCopyPreparesMarkerWithoutANavigationFocus() async throws {
        let (root, pdf) = try makeArchive()
        let model = try await readyModel(root)
        let context = ArchiveLinkContext()
        model.attach(linkContext: context)
        XCTAssertNotNil(context.target, "a markerless folder must enable the FIRST page-copy command")
        XCTAssertNil(context.target?.marker)
        let viewer = DocumentViewerModel(persists: false)
        viewer.load(DocumentSelection(filePaths: [pdf.path]))
        viewer.focusPane(.right)
        viewer.copyArchivePageLink(context: context)
        XCTAssertNil(viewer.archiveLinkError)
        let marker = try XCTUnwrap(RootMarker.read(at: root))
        let link = try copiedLink()
        XCTAssertEqual(link.0, marker.guid)
        XCTAssertEqual(link.1, pdf.lastPathComponent)
        XCTAssertEqual(link.2, 2)
    }

    func testRemovedMarkerIsNotRecreatedByRelaunchOrIncomingLink() async throws {
        let (root, _) = try makeArchive()
        let model = try await readyModel(root)
        model.copyArchiveLinks()
        let original = try XCTUnwrap(model.rootStore.rootMarker)
        try FileManager.default.removeItem(at: root.appendingPathComponent(RootMarker.filename))
        let reopened = try await readyModel(root, "removed")
        XCTAssertEqual(reopened.rootStore.markerState, .absent)
        reopened.revealAndSelect(rootGUID: original.guid, relativePath: "doc.pdf", page: nil)
        XCTAssertFalse(try listing(root).contains(RootMarker.filename))
        reopened.copyArchiveLinks()
        XCTAssertNotEqual(try XCTUnwrap(RootMarker.read(at: root)).guid, original.guid)
    }

    func testBrowsingTaggingAndOrdinaryCopyNeverCreateMarker() async throws {
        let (root, pdf) = try makeArchive()
        let model = try await readyModel(root)
        let file = try XCTUnwrap(model.selectedFiles.first)
        model.setReadStateInline(.read, for: file)
        XCTAssertTrue(try tags(pdf).contains("Read"))
        model.copyLinks()
        XCTAssertFalse(try listing(root).contains(RootMarker.filename))
        XCTAssertNil(model.rootStore.rootMarker)
    }

    func testReadOnlyCopyRefusesWithoutChangingClipboard() async throws {
        let (root, pdf) = try makeArchive()
        let model = try await readyModel(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep this", forType: .string)
        model.copyArchiveLinks()
        XCTAssertEqual(model.statusMessage, RootMarkerDegradation.notWritable.message)
        let context = ArchiveLinkContext()
        model.attach(linkContext: context)
        let viewer = DocumentViewerModel(persists: false)
        viewer.load(DocumentSelection(filePaths: [pdf.path]))
        viewer.copyArchivePageLink(context: context)
        XCTAssertEqual(viewer.archiveLinkError, RootMarkerDegradation.notWritable.message)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep this")
        XCTAssertFalse(try listing(root).contains(RootMarker.filename))
        XCTAssertEqual(try tags(pdf), ["1981", "Unread"])
    }

    func testMalformedMarkerAndRootSwitchNeverMintAPageLink() async throws {
        let (root, pdf) = try makeArchive()
        let model = try await readyModel(root)
        let context = ArchiveLinkContext()
        model.attach(linkContext: context)
        let viewer = DocumentViewerModel(persists: false)
        viewer.load(DocumentSelection(filePaths: [pdf.path]))
        let markerURL = root.appendingPathComponent(RootMarker.filename)
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: markerURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep this", forType: .string)
        viewer.copyArchivePageLink(context: context)
        XCTAssertEqual(viewer.archiveLinkError, RootMarkerDegradation.malformed.message)
        XCTAssertEqual(try Data(contentsOf: markerURL), damaged)
        let (otherRoot, _) = try makeArchive()
        XCTAssertNil(model.rootStore.setRoot(otherRoot))
        // No run-loop turn: even if the published target is stale, preparation uses the live root.
        viewer.copyArchivePageLink(context: context)
        XCTAssertTrue(viewer.archiveLinkError?.contains("different archive") == true)
        XCTAssertFalse(try listing(otherRoot).contains(RootMarker.filename))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep this")
    }

    func testDisplayPreferencesSurviveFirstCopyAndRelaunchWithoutCreatingMarker() async throws {
        let (root, _) = try makeArchive()
        let modelDefaults = fixtureDefaults(pinnedTo: root)
        let model = NavigationModel(defaults: modelDefaults)
        let deadline = Date().addingTimeInterval(10)
        while model.library.jpegPartnerScanStatus != .ready, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.library.jpegPartnerScanStatus, .ready)
        model.selection = Set(model.library.files.map(\.id))
        let preferenceID = try XCTUnwrap(model.rootStore.preferenceGUID)
        XCTAssertTrue(model.canChooseDisplayCalendar)
        model.setDisplayCalendar(.julian)
        XCTAssertEqual(model.selectionDisplayCalendar, .julian)
        XCTAssertFalse(try listing(root).contains(RootMarker.filename))
        let images = DocumentImageSourcePreferences(defaults: modelDefaults)
        let relativePath = try XCTUnwrap(model.selectedFiles.first).url.lastPathComponent
        images.set(.jpeg, rootGUID: preferenceID, relativePath: relativePath)
        let markerlessRelaunch = NavigationModel(defaults: modelDefaults)
        XCTAssertEqual(markerlessRelaunch.rootStore.preferenceGUID, preferenceID)
        XCTAssertFalse(try listing(root).contains(RootMarker.filename))
        model.copyArchiveLinks()
        XCTAssertEqual(model.rootStore.preferenceGUID, preferenceID)
        XCTAssertEqual(model.selectionDisplayCalendar, .julian)
        let relaunched = NavigationModel(defaults: modelDefaults)
        XCTAssertEqual(relaunched.rootStore.preferenceGUID, preferenceID)
        relaunched.recompute()   // only listed rows can be selected (W40.fix-reader-phantom-selection)
        relaunched.selection = Set(relaunched.library.files.map(\.id))
        XCTAssertEqual(relaunched.selectionDisplayCalendar, .julian)
        XCTAssertEqual(DocumentImageSourcePreferences(defaults: modelDefaults)
            .source(rootGUID: try XCTUnwrap(relaunched.rootStore.preferenceGUID), relativePath: relativePath), .jpeg)
    }

    func testDifferentDurableArchiveAtSamePathDoesNotInheritDisplayIdentity() throws {
        let (root, _) = try makeArchive()
        let defaults = fixtureDefaults()
        let store = RootFolderStore(defaults: defaults)
        XCTAssertNil(store.setRoot(root))
        let originalPreference = try XCTUnwrap(store.preferenceGUID)
        let original = try XCTUnwrap(store.prepareMarkerForLinkCopy())
        let replacement = RootMarker(guid: UUID(), name: "other archive", kind: .reader, createdAt: Date())
        // Scratch substitution simulates a different archive now occupying this path.
        try JSONEncoder().encode(replacement).write(to: root.appendingPathComponent(RootMarker.filename))
        let reopened = RootFolderStore(defaults: defaults)
        XCTAssertEqual(reopened.rootMarker?.guid, replacement.guid)
        XCTAssertEqual(reopened.preferenceGUID, replacement.guid)
        XCTAssertNotEqual(reopened.preferenceGUID, originalPreference)
        // A still-open store also rechecks disk before copying; it must not associate B with A.
        XCTAssertEqual(store.prepareMarkerForLinkCopy()?.guid, replacement.guid)
        XCTAssertEqual(store.preferenceGUID, replacement.guid)
        XCTAssertEqual(RootFolderStore(defaults: defaults).preferenceGUID, replacement.guid)
        // Bringing the original identity back restores its own container-only alias.
        try JSONEncoder().encode(original).write(to: root.appendingPathComponent(RootMarker.filename))
        XCTAssertEqual(RootFolderStore(defaults: defaults).preferenceGUID, originalPreference)
    }
}
