// DurableLinkE2ETests.swift — W8-S9 end-to-end durable-link scenario.
//
// The single integration test that proves the D5 durable-provenance promise
// (execution-plans/archive-notes/08-testing-and-gui-verification.md §4): a
// reader-page durable link resolves by root GUID, SURVIVES a "computer move"
// (same GUID, new absolute path, one re-grant), and NEVER fails silently — an
// unknown GUID or a wrong folder yields a guided re-grant, never a wrong file
// (00-overview §8.3).
//
// Fully hermetic + GUI-off: it builds its own scratch Reader corpus under the
// system temp dir (which `NotesTagProjector.isScratchPath` recognizes),
// exercises `ReaderLinkResolver`/`ReaderRootStore` directly (no window, no
// XCUITest), and snapshot/restores the only persisted side effect
// (`readerRootBookmarks` in `UserDefaults.standard`, written by `grantRoot`) so
// it leaves the host defaults byte-identical. It never touches the real
// corpus/store (Prime Directive #1). Runs in the free unit gate; the shell
// counterpart `scripts/e2e-durable-links.sh` proves the same promise over the
// shipped `make-notes-fixture.sh` at the filesystem level.

import Testing
import Foundation
@testable import ArchiveNotes
@testable import ArchiveCore

@MainActor
@Suite("Durable-link E2E (W8-S9)", .serialized)
struct DurableLinkE2ETests {

    // MARK: - Scratch fixture helpers

    /// Create a scratch Reader corpus (RootMarker + a regular file at `relFile`)
    /// under the system temp dir. Returns the corpus root URL and its marker.
    private func makeScratchCorpus(guid: UUID, relFile: String) throws -> (URL, RootMarker) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let marker = RootMarker(guid: guid, name: root.lastPathComponent,
                                kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: root.appendingPathComponent(RootMarker.filename), options: .atomic)

        let fileURL = root.appendingPathComponent(relFile)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4 scratch\n".utf8).write(to: fileURL, options: .atomic)

        return (root, marker)
    }

    /// Run `body` with `readerRootBookmarks` snapshotted and restored, so the
    /// suite never leaves stale bookmarks (or clobbers a prior value) in the
    /// host's `UserDefaults.standard` — `grantRoot` persists there.
    private func withHermeticBookmarks(_ body: () async throws -> Void) async rethrows {
        let key = "readerRootBookmarks"
        let saved = UserDefaults.standard.dictionary(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    private func isUnder(_ url: URL, _ root: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    // MARK: - The scenario

    @Test("Durable link round-trips and survives a computer move (re-grant by GUID)")
    func linkResolvesThenSurvivesComputerMove() async throws {
        try await withHermeticBookmarks {
            let guid = UUID()
            let (corpusA, _) = try makeScratchCorpus(guid: guid, relFile: "sample.pdf")
            var deletedA = false
            defer { if !deletedA { try? FileManager.default.removeItem(at: corpusA) } }

            // (0) The stored durable link round-trips to the resolver's inputs.
            let link = DurableLink.readerReveal(rootGUID: guid, relativePath: "sample.pdf", page: 1)
            guard case let .readerReveal(pGUID, pRel, pPage)? = DurableLink(url: link.url) else {
                Issue.record("durable link did not round-trip through DurableLink(url:)")
                return
            }
            #expect(pGUID == guid)
            #expect(pRel == "sample.pdf")
            #expect(pPage == 1)

            let store = ReaderRootStore()
            let resolver = ReaderLinkResolver(rootStore: store)

            // (a) Same machine: grant the root, resolve the link.
            let r1 = await resolver.grantAndResolve(url: corpusA, rootGUID: pGUID, relativePath: pRel)
            guard case let .resolved(url1) = r1 else {
                Issue.record("expected .resolved on the granting machine, got \(r1)")
                return
            }
            #expect(url1.lastPathComponent == "sample.pdf")
            #expect(isUnder(url1, corpusA))

            // (b) Simulate a computer move: copy the whole corpus to a DIFFERENT
            // absolute path (new username/volume), then delete the original.
            let corpusB = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveNotes-e2e-moved-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: corpusA, to: corpusB)
            defer { try? FileManager.default.removeItem(at: corpusB) }
            try FileManager.default.removeItem(at: corpusA)
            deletedA = true

            // The stale path no longer resolves — a missing file, NOT a silent
            // wrong file (the granting machine's scope now points at nothing).
            let rStale = await resolver.resolve(rootGUID: guid, relativePath: "sample.pdf")
            #expect(rStale == .notFound)

            // (c) Re-grant the SAME GUID at the NEW path → resolves again
            // (00-overview §8.3 new-machine path: one re-grant, keyed by GUID).
            let r2 = await resolver.grantAndResolve(url: corpusB, rootGUID: guid, relativePath: "sample.pdf")
            guard case let .resolved(url2) = r2 else {
                Issue.record("expected .resolved after computer-move re-grant, got \(r2)")
                return
            }
            #expect(url2.lastPathComponent == "sample.pdf")
            #expect(isUnder(url2, corpusB))
        }
    }

    @Test("Unknown root GUID asks for a re-grant — never a silent failure")
    func unknownGUIDRequestsRegrant() async {
        await withHermeticBookmarks {
            let store = ReaderRootStore()
            let resolver = ReaderLinkResolver(rootStore: store)
            let unknown = UUID()
            #expect(await resolver.resolve(rootGUID: unknown, relativePath: "whatever.pdf")
                    == .needsRootGrant(guid: unknown))
        }
    }

    @Test("Re-granting the WRONG folder names the mismatch, never a wrong file — and keeps the grant")
    func regrantWrongFolderRejected() async throws {
        try await withHermeticBookmarks {
            // The folder carries some other GUID; the link wants `wanted`.
            let (corpus, marker) = try makeScratchCorpus(guid: UUID(), relFile: "sample.pdf")
            defer { try? FileManager.default.removeItem(at: corpus) }

            let store = ReaderRootStore()
            let resolver = ReaderLinkResolver(rootStore: store)
            let wanted = UUID()
            #expect(wanted != marker.guid)
            // W26.notesabsence-fu2: a real, grantable archive that just isn't THIS link's is no
            // longer reported with the same case as "nothing chosen yet" (`.needsRootGrant`) — that
            // told a user who had just picked a folder to go pick one. `.wrongArchive` names both
            // GUIDs, and the pick is still honoured: `marker.guid` is usable in Notes from here on.
            #expect(await resolver.grantAndResolve(url: corpus, rootGUID: wanted, relativePath: "sample.pdf")
                    == .wrongArchive(picked: corpus, granted: marker.guid, wanted: wanted))
            #expect(store.knownRoots[marker.guid] != nil)
        }
    }

    @Test("A file moved WITHIN the root is offered as a renamed candidate, not opened silently")
    func renamedFileOffersCandidate() async throws {
        try await withHermeticBookmarks {
            let guid = UUID()
            // The file lives at a new sub-path; the link points at the old one.
            let (corpus, _) = try makeScratchCorpus(guid: guid, relFile: "new/place/sample.pdf")
            defer { try? FileManager.default.removeItem(at: corpus) }

            let store = ReaderRootStore()
            store.grantRoot(corpus)
            let resolver = ReaderLinkResolver(rootStore: store)

            let result = await resolver.resolve(rootGUID: guid, relativePath: "old/place/sample.pdf")
            guard case let .renamedCandidate(url) = result else {
                Issue.record("expected .renamedCandidate for a moved-within-root file, got \(result)")
                return
            }
            #expect(url.lastPathComponent == "sample.pdf")
            #expect(isUnder(url, corpus))
        }
    }
}
