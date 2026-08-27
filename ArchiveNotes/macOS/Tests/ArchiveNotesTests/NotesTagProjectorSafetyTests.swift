import Testing
import Foundation
@testable import ArchiveNotes
import ArchiveCore

/// W8-S2 — the **crown jewel** safety suite for `NotesTagProjector`, the ONE file-safety write
/// surface in Archive Notes (00-overview §9; plan `08-testing-and-gui-verification.md` §1.3).
///
/// Every case runs on a `mktemp` `.md` with pre-seeded Finder tags — **never** the corpus or the
/// real store. Where a case performs a real Finder-tag write, it asserts the file's **data-fork
/// bytes are unchanged** afterward (the Reader `TagWriterTests` byte-equality pattern). Together
/// these pin each `TagWriter`/`CoordinatedTagWriter` invariant the projector reimplements.
///
/// Note on the verify-fail path (§8/§9, case 5): the multiset verify-by-re-read is enforced INSIDE
/// the shared, audited `ArchiveCore.CoordinatedTagWriter` (it throws `verificationFailed` on a
/// post-write mismatch — it never silently reports success and never blind-restores a stale array).
/// A fault-injection seam is deliberately NOT added to that cross-app choke-point for a test; case 5
/// instead pins the guarantees observable at the projector boundary: a reported-success is backed by
/// an independent ground-truth re-read, and a subsequent projection reconciles against a FRESH read
/// (delta) so a concurrent third-party tag is preserved rather than clobbered by a blind restore.
@Suite("NotesTagProjector — SAFETY (crown jewel, scratch copies)")
struct NotesTagProjectorSafetyTests {

    // MARK: - Helpers (mirror NotesTagProjectorTests + Reader TagWriterTests)

    /// A fresh `<tmp>/…/items/<uuid>/` item directory (mimics the NoteStore layout).
    private func makeScratchItemDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagProjectorSafety-\(UUID().uuidString)", isDirectory: true)
        let itemDir = root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        return itemDir
    }

    @discardableResult
    private func makeScratchFile(
        in dir: URL,
        name: String = "Test Note.md",
        tags: [String] = [],
        label: Int? = nil,
        bytes: Data = Data("---\ntitle: Test\n---\nBody \(UUID().uuidString).\n".utf8)
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url, options: [.atomic])
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func readTags(_ url: URL) throws -> [String] {
        (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    private func readLabel(_ url: URL) throws -> Int? {
        try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }
    private func fileBytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    private func mtime(_ url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? Date.distantPast
    }

    private func makeItem(tags: [String]) -> Item {
        Item(
            id: UUID(), kind: .note, title: "Test", authors: [],
            date: nil, datePrecision: nil, dateUncertain: false, quality: nil,
            tags: tags, zotero: [], roundup: false,
            created: Date(), modified: Date(), schema: 1,
            blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil
        )
    }

    private func cleanup(_ dir: URL) {
        // Walk up to the `TagProjectorSafety-*` root and remove it wholesale.
        var d = dir
        while !d.lastPathComponent.hasPrefix("TagProjectorSafety-") && d.path != "/" {
            d = d.deletingLastPathComponent()
        }
        if d.lastPathComponent.hasPrefix("TagProjectorSafety-") {
            try? FileManager.default.removeItem(at: d)
        }
    }

    // MARK: - §3 tag-wipe-on-unreadable aborts (never coerce a failed read to [])

    @Test("§3 read failure aborts — writes nothing, leaves neighbors untouched")
    func attemptedTagWipeOnUnreadableFileAborts() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }

        // A real, pre-seeded sibling in the same item dir — must be byte- and tag-untouched.
        let sibling = try makeScratchFile(in: dir, name: "Real Note.md", tags: ["History"])
        let siblingBytes = try fileBytes(sibling)
        let siblingTags = Set(try readTags(sibling))

        // A path (inside the item dir, so the boundary guard passes) that does NOT exist → the fresh
        // read inside coordination throws → the write MUST abort, never coerce the failed read to [].
        let missing = dir.appendingPathComponent("vanished.md")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        var threw = false
        do {
            _ = try NotesTagProjector.project(
                ["Economics"], previouslyManaged: [], to: missing, itemDir: dir)
        } catch {
            threw = true // an unreadable/coordination abort — the point is it did not WRITE.
            if let e = error as? TagWriteError {
                switch e {
                case .unreadable, .coordinationFailed: break
                // .identityMismatch (Safety §6, added W14.2) cannot arise here — the projector passes no
                // expectedIdentity — so treat it, like verificationFailed, as an unexpected error.
                case .verificationFailed, .identityMismatch:
                    Issue.record("unexpected \(e) on unreadable input")
                }
            }
        }
        #expect(threw, "an unreadable file must ABORT with a thrown error, never a silent []-coercion write")
        // No file was fabricated at the missing path (no coerce-to-[] then write-back).
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        // The real neighbor is completely untouched.
        #expect(try fileBytes(sibling) == siblingBytes)
        #expect(Set(try readTags(sibling)) == siblingTags)
    }

    // MARK: - Concurrency: never corrupt or lose a projected subject (torn-write / wipe guard)

    @Test("concurrent same-file projections keep BOTH racing subjects; never corrupt (§10, W15.tu4)")
    func concurrentProjectionsNeverCorrupt() async throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        let url = try makeScratchFile(in: dir, tags: [])
        let bytesBefore = try fileBytes(url)

        // Two genuinely-parallel projections, each adding a distinct subject.
        let a = Task.detached {
            try NotesTagProjector.project(["Economics"], previouslyManaged: [], to: url, itemDir: dir)
        }
        let b = Task.detached {
            try NotesTagProjector.project(["History"], previouslyManaged: [], to: url, itemDir: dir)
        }
        // Neither call throws — coordination keeps each write self-consistent.
        _ = try await a.value
        _ = try await b.value

        let after = Set(try readTags(url))
        // W15.tu4 — the assertion is now STRONGER than at W8-S2: the §10 per-resolved-path lock
        // (W15.tu3, inside ArchiveCore.CoordinatedTagWriter) serializes the two same-file writes, so
        // BOTH racing subjects survive. Each projection passes
        // previouslyManaged: [] (so it removes nothing), and the second to acquire the lock reads the
        // first's committed tags fresh and merely appends its own subject → exactly the two subjects
        // deterministically, in either interleaving.
        #expect(after == ["Economics", "History"],
                "both racing subjects survive; no lost update, no invented/torn token (§10)")
        #expect(try fileBytes(url) == bytesBefore, "CORE DIRECTIVE: file bytes never change")
        // NOTE (W15.tu4): before W15.tu3 this test could assert only the weaker invariants (marker
        // never lost, no corruption/wipe) because `.contentIndependentMetadataOnly` does not
        // mutually-exclude two concurrent metadata-only write claims, so a racing *subject* could be
        // superseded (the lost update formerly tracked in ArchiveNotes/KNOWN_ISSUES.md). The §10
        // in-process per-path lock closes it. Its non-vacuous deterministic-loss-*without*-the-lock
        // proof lives in ArchiveCore `TagWriterPrimitiveTests.testConcurrentSamePathWritesBothSurvive`
        // (that seam can widen the RMW window from inside the transform); this pins that the Notes
        // projector — the app's ONE file-safety write surface — is on that protected path.
        // Cross-PROCESS writers remain out of scope (an in-process lock cannot cover them).
    }

    // MARK: - §5 lossless: never touch a token the projector does not manage

    @Test("§5 hand-applied unrelated Finder tag preserved verbatim; bytes unchanged")
    func preExistingUnrelatedTagPreservedLossless() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        // A hand-applied, projector-unmanaged tag (with a space) alongside a managed subject + legacy marker.
        let url = try makeScratchFile(in: dir, tags: ["Do Not Sync", "History", "ArchiveSuite"])
        let bytesBefore = try fileBytes(url)

        // The legacy marker is not supplied as previously managed. This proves R13d's new cleanup
        // rule rather than the pre-existing generic delta: remove only the legacy marker and preserve
        // every other existing tag, all on this scratch file.
        _ = try NotesTagProjector.project(
            ["History"], previouslyManaged: ["History"], to: url, itemDir: dir)

        let after = Set(try readTags(url))
        #expect(after.contains("Do Not Sync"), "unmanaged user tag must survive verbatim")
        #expect(after.contains("History"), "current managed subject must survive")
        #expect(!after.contains("ArchiveSuite"), "legacy marker stripped")
        #expect(try fileBytes(url) == bytesBefore, "CORE DIRECTIVE: file bytes never change")
    }

    // MARK: - §6 the former marker name is now an ordinary subject

    @Test("§6 subject literally 'ArchiveSuite' — single token, whole-string match")
    func subjectLiterallyArchiveSuiteCollision() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        let url = try makeScratchFile(in: dir, tags: [])

        // (a) A note whose SUBJECT is literally "ArchiveSuite", plus a near-miss token that must NOT
        //     be conflated with the marker (whole-string exact matching, not prefix/substring).
        let item1 = makeItem(tags: ["ArchiveSuite", "ArchiveSuiteReport"])
        let desired1 = NotesTagVocabulary.managedTokens(for: item1)
        let managed1 = try NotesTagProjector.project(desired1, previouslyManaged: [], to: url, itemDir: dir)
        let after1 = try readTags(url)
        #expect(after1.filter { $0 == "ArchiveSuite" }.count == 1, "exactly one ArchiveSuite token (deduped)")
        // (b) whole-string: the near-miss is its own independent token, present once.
        #expect(after1.filter { $0 == "ArchiveSuiteReport" }.count == 1)

        // (c) dropping the subject removes it, because it is no longer a separate membership marker.
        let item2 = makeItem(tags: ["ArchiveSuiteReport"])
        let desired2 = NotesTagVocabulary.managedTokens(for: item2)
        _ = try NotesTagProjector.project(desired2, previouslyManaged: managed1, to: url, itemDir: dir)
        let after2 = try readTags(url)
        #expect(!after2.contains("ArchiveSuite"),
                "dropping the ordinary subject removes its exact token")
        #expect(after2.contains("ArchiveSuiteReport"))
    }

    // MARK: - §8/§9 verify-by-re-read is disk-backed; reconcile via fresh delta (no blind restore)

    @Test("§8 success backed by independent re-read; §9 reconcile keeps a concurrent tag")
    func verifyByReReadBackedByGroundTruthAndReconciles() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        let url = try makeScratchFile(in: dir, tags: [])

        // (A) A reported-success projection's managed set must equal the managed tokens ACTUALLY on
        //     disk (an independent reader): verify-by-re-read is real, not a blind claim.
        let desired: Set<String> = ["History", "Economics"]
        let reported = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)
        guard case let .success(onDisk, _) = TagReading.read(url) else {
            Issue.record("independent ground-truth re-read failed"); return
        }
        #expect(reported == desired.intersection(Set(onDisk)), "reported managed set == what's truly on disk")
        #expect(desired.isSubset(of: Set(onDisk)), "every managed token is truly persisted")

        // (B) A third party adds an unrelated tag AFTER our write; the next projection must reconcile
        //     against a FRESH read (delta) and preserve it — never restore a stale full array.
        var t = try readTags(url); t.append("Do Not Sync")
        try (url as NSURL).setResourceValue(t, forKey: .tagNamesKey)

        _ = try NotesTagProjector.project(
            ["History"], previouslyManaged: reported, to: url, itemDir: dir)
        let after = Set(try readTags(url))
        #expect(after.contains("Do Not Sync"), "concurrent third-party tag preserved (no blind full-array restore)")
        #expect(!after.contains("Economics"), "dropped managed token removed via delta")
        #expect(after.isSuperset(of: ["History"]))
    }

    // MARK: - §5 idempotent no-op: identical projection writes nothing (no mod-date churn)

    @Test("§5 identical projection is a no-op — mtime + bytes unchanged")
    func noOpDeltaWritesNothing() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        let url = try makeScratchFile(in: dir, tags: [])
        let desired: Set<String> = ["History"]

        let managed = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)
        let mtime1 = try mtime(url)
        let bytes1 = try fileBytes(url)

        // Re-project the identical managed set: the projector detects the no-op and writes nothing.
        let managed2 = try NotesTagProjector.project(desired, previouslyManaged: managed, to: url, itemDir: dir)

        #expect(managed2 == managed)
        #expect(try mtime(url) == mtime1, "a no-op projection must not churn the modification date")
        #expect(try fileBytes(url) == bytes1)
        #expect(Set(try readTags(url)) == desired)
    }

    // MARK: - §5 title-casing via the shared convention

    @Test("§5 subjects title-cased via the shared convention")
    func titleCasingMatchesSharedConvention() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        let url = try makeScratchFile(in: dir, tags: [])

        // Lower/mixed-case subjects in front-matter → title-cased managed tokens.
        let item = makeItem(tags: ["economic policy", "jerry brown", "HISTORY"])
        let desired = NotesTagVocabulary.managedTokens(for: item)
        _ = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)

        let after = Set(try readTags(url))
        // capitalizeFirstLetters: first letter of each word up-cased, the rest preserved.
        #expect(after.contains("Economic Policy"))
        #expect(after.contains("Jerry Brown"))
        #expect(after.contains("HISTORY"), "already-capitalized words are preserved, not down-cased")
    }

    // MARK: - §7 label never written (drift guard) + bytes unchanged

    @Test("§7 color label never changed by a tag projection")
    func neverWritesLabelBytesUnchanged() throws {
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        // Pre-set a Red (6) label; a tag projection must leave it exactly as-is.
        let url = try makeScratchFile(in: dir, tags: ["ArchiveSuite"], label: 6)
        let labelBefore = try readLabel(url)
        let bytesBefore = try fileBytes(url)

        _ = try NotesTagProjector.project(
            ["History"], previouslyManaged: ["ArchiveSuite"], to: url, itemDir: dir)

        #expect(normalizedLabel(try readLabel(url)) == normalizedLabel(labelBefore),
                "the color label must not drift across a tag-only write")
        #expect(try readTags(url).contains("History"))
        #expect(try fileBytes(url) == bytesBefore, "CORE DIRECTIVE: file bytes never change")
    }

    // MARK: - §5 scratch-write guard logic (the DEBUG belt-and-suspenders predicate)

    @Test("isScratchPath accepts scratch prefixes and rejects the real store / corpus")
    func scratchPathPredicate() throws {
        // Accepts: the system temp dir (this test's own scratch dir lives here).
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        #expect(NotesTagProjector.isScratchPath(dir.path))
        #expect(NotesTagProjector.isScratchPath(NSTemporaryDirectory() + "some/deep/file.md"))
        #expect(NotesTagProjector.isScratchPath("/tmp/whatever.md"))
        #expect(NotesTagProjector.isScratchPath("/private/tmp/whatever.md"))
        #expect(NotesTagProjector.isScratchPath(
            "/Users/x/Library/Application Support/ArchiveNotes/AN-GUI-Fixture/items/1/n.md"))
        // Rejects: the real store + the archive corpus (a projector write must never land here).
        #expect(!NotesTagProjector.isScratchPath(
            "/Users/x/Library/Application Support/ArchiveNotes/items/1/note.md"))
        #expect(!NotesTagProjector.isScratchPath("/Users/x/Desktop/Google Drive/Archival Photos/00001.pdf"))
        #expect(!NotesTagProjector.isScratchPath("/etc/passwd"))
    }

    @Test("the DEBUG guard is active under XCTest yet a legitimate scratch write still succeeds")
    func scratchGuardAllowsLegitimateScratchWrite() throws {
        // The DEBUG scratch-write guard keys on this env var, which the XCTest host sets — assert it
        // is present so we KNOW the guard is live during this run (not silently dormant). A normal
        // scratch projection must then sail through it (the guard only aborts NON-scratch writes,
        // which no test performs) — i.e. the guard is wired and does not false-positive.
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
                "expected to be running under the XCTest host so the scratch-write guard is active")
        let dir = try makeScratchItemDir(); defer { cleanup(dir) }
        let url = try makeScratchFile(in: dir, tags: [])
        let managed = try NotesTagProjector.project(
            ["History"], previouslyManaged: [], to: url, itemDir: dir)
        #expect(managed.contains("History"))
        #expect(Set(try readTags(url)) == ["History"])
    }
}
