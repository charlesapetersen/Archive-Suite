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

    @Test("Picking a folder with no marker is refused and reported, never silently granted")
    func pickingABadFolderIsRefusedAndReported() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-chooser-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
            let log = ReportLog()
            chooser.pickFolder = { tmp }
            chooser.report = { log.record($0) }

            let outcome = chooser.chooseRoot()

            #expect(outcome == .refused(.notAnArchiveRoot(tmp)))
            #expect(log.outcomes == [.refused(.notAnArchiveRoot(tmp))])
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
