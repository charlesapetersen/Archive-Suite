// ReaderRootChooserTests.swift — W26.notesabsence-fu2: the chooser that was missing entirely.
//
// Before this item, `ReaderRootStore.grantRoot`'s only caller was `ReaderLinkResolver.grantAndResolve`,
// and THAT had no caller outside these tests — `NSOpenPanel` appeared nowhere in Notes' sources, so
// every real machine's `knownRoots` started empty and stayed empty. `ReaderRootChooser` is the panel;
// these tests drive it through its two seams (`pickFolder`, `report`) so a unit-test host never opens
// a real `NSOpenPanel` or `NSAlert` — either would block the whole bundle with nobody there to dismiss it.

import Testing
import Foundation
@testable import ArchiveNotes
@testable import ArchiveCore

@MainActor
@Suite("ReaderRootChooser")
struct ReaderRootChooserTests {

    private func makeMarkedRoot(
        _ label: String, kind: RootKind = .reader, guid: UUID = UUID()
    ) throws -> (URL, RootMarker) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-chooser-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = RootMarker(guid: guid, name: label, kind: kind, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: dir.appendingPathComponent(RootMarker.filename), options: .atomic)
        return (dir, marker)
    }

    /// Records the outcomes `report` was called with, so a test can assert both THAT it was called
    /// and how many times — the panel's alert is deliberately suppressed here (real one blocks).
    @MainActor
    private final class ReportLog {
        private(set) var outcomes: [ReaderRootChooser.Outcome] = []
        func record(_ outcome: ReaderRootChooser.Outcome) { outcomes.append(outcome) }
    }

    // MARK: - chooseRoot() — File ▸ Choose Archive Folder…, no link in hand

    @Test("Cancelling the panel reports nothing and grants nothing")
    func cancelledPanelReportsNothing() async throws {
        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            let log = ReportLog()
            chooser.pickFolder = { nil }
            chooser.report = { log.record($0) }

            let outcome = chooser.chooseRoot()

            #expect(outcome == .cancelled)
            #expect(log.outcomes.isEmpty, "a cancelled panel has nothing to say")
            #expect(store.knownRoots.isEmpty)
        }
    }

    @Test("Picking a real Reader root grants it and reports success")
    func pickingAGoodRootGrantsAndReports() async throws {
        let (root, marker) = try makeMarkedRoot("good")
        defer { try? FileManager.default.removeItem(at: root) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            let log = ReportLog()
            chooser.pickFolder = { root }
            chooser.report = { log.record($0) }

            let outcome = chooser.chooseRoot()

            // Not compared with `== .granted(marker, picked: root)`: `marker` is the in-memory value
            // this test minted, but the outcome's marker came back through `RootMarker.read`, i.e.
            // through the ISO-8601 round trip that drops sub-second precision on `createdAt`
            // (`ArchiveCoreWiringTests.testRootMarkerCodableRoundTrip` documents the same gap). Two
            // otherwise-identical markers a moment apart in wall-clock time are NOT `==`.
            guard case let .granted(returnedMarker, picked) = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            #expect(returnedMarker.guid == marker.guid)
            #expect(returnedMarker.name == marker.name)
            #expect(returnedMarker.kind == marker.kind)
            #expect(picked == root)
            #expect(log.outcomes.count == 1)
            #expect(store.knownRoots[marker.guid] != nil)
        }
    }

    private func makePlainFolder(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-chooser-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func listing(_ dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    // W40.root-marker-auto (owner, 2026-11-06): choosing a folder gives it its identity, as the Reader does.
    @Test("Picking a folder with no marker gives it one Reader identity and grants it")
    func pickingAPlainFolderCreatesTheIdentity() async throws {
        let tmp = try makePlainFolder("plain")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pdf = tmp.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4 scratch\n".utf8).write(to: pdf, options: .atomic)
        let pdfBytes = try Data(contentsOf: pdf)
        let before = try listing(tmp)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.notesStoreFolder = { nil }
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            let log = ReportLog()
            chooser.pickFolder = { tmp }
            chooser.report = { log.record($0) }

            let outcome = chooser.chooseRoot()

            guard case let .granted(marker, picked) = outcome else {
                Issue.record("expected .granted, got \(outcome)")
                return
            }
            #expect(picked == tmp)
            #expect(marker.kind == .reader)
            #expect(marker.name == tmp.lastPathComponent)
            #expect(try RootMarker.read(at: tmp) == marker)
            #expect(try listing(tmp).subtracting(before) == [RootMarker.filename])
            #expect(try listing(tmp).count == before.count + 1)
            #expect(try Data(contentsOf: pdf) == pdfBytes)
            #expect(store.knownRoots[marker.guid] != nil)
            #expect(log.outcomes.count == 1)

            // Choosing it again adopts the same identity and never rewrites the file.
            let markerURL = tmp.appendingPathComponent(RootMarker.filename)
            let bytes = try Data(contentsOf: markerURL)
            let again = chooser.chooseRoot()
            guard case let .granted(second, _) = again else {
                Issue.record("expected .granted, got \(again)")
                return
            }
            #expect(second.guid == marker.guid)
            #expect(try Data(contentsOf: markerURL) == bytes)
        }
    }

    @Test("A folder holding the notes store, or inside it, is refused and nothing is written")
    func pickingAroundTheNotesStoreIsRefused() async throws {
        let outer = try makePlainFolder("holds-store")
        defer { try? FileManager.default.removeItem(at: outer) }
        let storeDir = outer.appendingPathComponent("Store", isDirectory: true)
        let inner = storeDir.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.notesStoreFolder = { storeDir }
            for pick in [outer, inner] {
                let before = try listing(pick)
                let result = store.grantRoot(pick, createIdentity: true)
                #expect(result.refusal == .overlapsNotesStore(pick))
                #expect(try listing(pick) == before)
            }
            #expect(store.knownRoots.isEmpty)
        }
    }

    @Test("A folder inside another archive is refused and nothing is written")
    func pickingInsideAnArchiveIsRefused() async throws {
        let (root, _) = try makeMarkedRoot("outer")
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("Box 1", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.notesStoreFolder = { nil }
            let result = store.grantRoot(sub, createIdentity: true)
            #expect(result.refusal == .insideAnotherRoot(sub))
            // The sandbox hides parents, so a granted archive is what catches it in the app: the
            // outer marker removed, the grant alone still refuses the subfolder.
            #expect(store.grantRoot(root).marker != nil)
            try FileManager.default.removeItem(at: root.appendingPathComponent(RootMarker.filename))
            #expect(store.grantRoot(sub, createIdentity: true).refusal == .insideAnotherRoot(sub))
            let left = try listing(sub)
            #expect(left.isEmpty)
        }
    }

    @Test("A folder holding a granted archive, or a Reader layout subfolder, is refused, nothing written")
    func pickingAroundAnArchiveIsRefused() async throws {
        let outer = try makePlainFolder("holds-archive")
        defer { try? FileManager.default.removeItem(at: outer) }
        let archive = outer.appendingPathComponent("Archive", isDirectory: true)
        let main = archive.appendingPathComponent("Archival Photos", isDirectory: true)
        let jpegs = archive.appendingPathComponent("Archival Photos JPEGS", isDirectory: true)
        for dir in [main, jpegs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let marker = RootMarker(guid: UUID(), name: "Archive", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: archive.appendingPathComponent(RootMarker.filename))

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.notesStoreFolder = { nil }
            // Not yet granted: the name alone refuses the main and JPEG folders.
            for sub in [main, jpegs] {
                #expect(store.grantRoot(sub, createIdentity: true).refusal == .readerLayoutSubfolder(sub))
            }
            #expect(store.grantRoot(archive, createIdentity: true).marker?.guid == marker.guid)
            #expect(store.grantRoot(outer, createIdentity: true).refusal == .holdsAnotherRoot(outer))
            for dir in [outer, main, jpegs] {
                #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(RootMarker.filename).path))
            }
        }
    }

    @Test("A bookmark that cannot be made refuses the grant before any identity is written")
    func bookmarkFailureWritesNothing() async throws {
        let tmp = try makePlainFolder("nobookmark")
        defer { try? FileManager.default.removeItem(at: tmp) }
        struct Refused: Error {}

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.notesStoreFolder = { nil }
            store.mintBookmark = { _ in throw Refused() }
            guard case .couldNotBookmark(let named, _)? = store.grantRoot(tmp, createIdentity: true).refusal else {
                Issue.record("expected .couldNotBookmark")
                return
            }
            #expect(named == tmp)
            let left = try listing(tmp)
            #expect(left.isEmpty)
        }
    }

    @Test("A read-only folder with no marker is refused with the reason, nothing written")
    func pickingAReadOnlyFolderIsRefused() async throws {
        let tmp = try makePlainFolder("readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.notesStoreFolder = { nil }
            let result = store.grantRoot(tmp, createIdentity: true)
            guard case .couldNotCreateIdentity(let named, _)? = result.refusal else {
                Issue.record("expected .couldNotCreateIdentity, got \(String(describing: result.refusal))")
                return
            }
            #expect(named == tmp)
            #expect(result.refusal?.message.contains("can’t be written to") == true)
            let left = try listing(tmp)
            #expect(left.isEmpty)
            #expect(store.knownRoots.isEmpty)
        }
    }

    @Test("Picking Notes' own folder is refused by kind, not adopted under a foreign GUID")
    func pickingTheNotesFolderIsRefused() async throws {
        let (root, marker) = try makeMarkedRoot("own-notes", kind: .notes)
        defer { try? FileManager.default.removeItem(at: root) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            let log = ReportLog()
            chooser.pickFolder = { root }
            chooser.report = { log.record($0) }

            let outcome = chooser.chooseRoot()

            #expect(outcome == .refused(.wrongRootKind(root, .notes)))
            #expect(log.outcomes.count == 1)
            #expect(store.knownRoots[marker.guid] == nil)
        }
    }

    // MARK: - chooseRootAndResolve — the in-popover variant

    @Test("Cancelling the panel from the popover leaves the caller nothing new to show")
    func cancelledPanelFromPopoverReturnsNil() async throws {
        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            chooser.pickFolder = { nil }

            let result = await chooser.chooseRootAndResolve(rootGUID: UUID(), relativePath: "x.pdf")

            #expect(result == nil)
        }
    }

    @Test("Picking the RIGHT root from the popover grants it and resolves the waiting link")
    func pickingTheRightRootResolvesTheLink() async throws {
        let guid = UUID()
        let (root, _) = try makeMarkedRoot("right", guid: guid)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("%PDF-1.4 scratch\n".utf8).write(
            to: root.appendingPathComponent("sample.pdf"), options: .atomic)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            chooser.pickFolder = { root }

            let result = await chooser.chooseRootAndResolve(rootGUID: guid, relativePath: "sample.pdf")

            guard case .resolved(let url) = result else {
                Issue.record("expected .resolved after granting the right root, got \(String(describing: result))")
                return
            }
            #expect(url.lastPathComponent == "sample.pdf")
        }
    }

    @Test("Picking the WRONG root from the popover reports the mismatch, not a silent re-ask")
    func pickingTheWrongRootReportsMismatch() async throws {
        let (root, marker) = try makeMarkedRoot("wrong-one")
        defer { try? FileManager.default.removeItem(at: root) }
        let wanted = UUID()

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            chooser.pickFolder = { root }

            let result = await chooser.chooseRootAndResolve(rootGUID: wanted, relativePath: "sample.pdf")

            #expect(result == .wrongArchive(picked: root, granted: marker.guid, wanted: wanted))
        }
    }
}
