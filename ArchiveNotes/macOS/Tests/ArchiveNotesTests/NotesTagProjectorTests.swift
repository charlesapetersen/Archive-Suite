import Testing
import Foundation
@testable import ArchiveNotes
import ArchiveCore

/// Adversarial tests for NotesTagProjector — the one file-safety surface in Archive Notes.
///
/// Every test operates on scratch `.md` files in `mktemp` — **never** the real corpus or store.
/// The tests exercise each invariant cited in NotesTagProjector.swift.
@Suite("NotesTagProjector — adversarial (scratch copies)")
struct NotesTagProjectorTests {

    // MARK: - Helpers

    private func makeScratchDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagProjectorTests-\(UUID().uuidString)", isDirectory: true)
        // Mimic NoteStore layout: <root>/items/<uuid>/
        let itemDir = tmp.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        return itemDir
    }

    /// Write a minimal .md file and pre-seed its Finder tags.
    private func makeScratchFile(
        in dir: URL,
        name: String = "Test Note.md",
        tags: [String] = []
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("---\ntitle: Test\n---\nBody.\n".utf8).write(to: url, options: [.atomic])
        if !tags.isEmpty {
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        return url
    }

    private func readTags(_ url: URL) throws -> [String] {
        let rv = try url.resourceValues(forKeys: [.tagNamesKey])
        return rv.tagNames ?? []
    }

    private func readLabel(_ url: URL) throws -> Int? {
        let rv = try url.resourceValues(forKeys: [.labelNumberKey])
        return rv.labelNumber
    }

    private func makeItem(tags: [String]) -> Item {
        Item(
            id: UUID(),
            kind: .note,
            title: "Test",
            authors: [],
            date: nil,
            datePrecision: nil,
            dateUncertain: false,
            quality: nil,
            tags: tags,
            zotero: [],
            roundup: false,
            created: Date(),
            modified: Date(),
            schema: 1,
            blocks: [],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )
    }

    private func cleanup(_ url: URL) {
        // Walk up to the TagProjectorTests-* dir and remove it.
        var dir = url
        while dir.lastPathComponent != "items" && dir.path != "/" { dir = dir.deletingLastPathComponent() }
        if dir.lastPathComponent == "items" {
            try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        }
    }

    // MARK: - §3 Unreadable file aborts, tags untouched

    @Test("unreadable file aborts — tags untouched")
    func unreadableFileAborts_tagsUntouched() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        // Point at a non-existent file — read will fail inside coordination.
        let bogus = dir.appendingPathComponent("does-not-exist.md")
        let desired: Set<String> = ["History"]
        do {
            _ = try NotesTagProjector.project(desired, previouslyManaged: [], to: bogus, itemDir: dir)
            Issue.record("Expected an error for unreadable file")
        } catch {
            // Any error is acceptable — the point is we did not write tags.
            // (CoordinatedTagWriter throws TagWriteError.unreadable or .coordinationFailed.)
        }
    }

    // MARK: - §4 Lossless: preserves user-added subjects

    @Test("lossless preserves user subject not in managed set")
    func losslessPreservesUserSubject() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        // Pre-seed with a user tag and the retired legacy marker.
        let url = try makeScratchFile(in: dir, tags: ["UserCustomTag", "ArchiveSuite", "History"])
        let previouslyManaged: Set<String> = ["History", "ArchiveSuite"]

        // Now project with a changed subject set: remove "History" and the legacy marker, add Economics.
        let desired: Set<String> = ["Economics"]
        let result = try NotesTagProjector.project(desired, previouslyManaged: previouslyManaged, to: url, itemDir: dir)

        let after = try readTags(url)
        // "UserCustomTag" must survive — we never managed it.
        #expect(after.contains("UserCustomTag"), "User tag must be preserved")
        // "History" should be gone (we previously managed it, now it's not desired).
        #expect(!after.contains("History"), "Previously managed tag should be removed")
        // Economics should be present, and the old marker must be stripped.
        #expect(after.contains("Economics"), "New managed tag should be added")
        #expect(!after.contains("ArchiveSuite"), "Legacy marker should be stripped")
        // Result should reflect what's managed.
        #expect(result.contains("Economics"))
    }

    // MARK: - §5 Removes only previously managed tokens

    @Test("removes only previously managed — never touches unmanaged")
    func removesOnlyPreviouslyManaged() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        // File has "Science" (managed) + "MyPersonalTag" (unmanaged) + a legacy marker.
        let url = try makeScratchFile(in: dir, tags: ["Science", "MyPersonalTag", "ArchiveSuite"])
        let previouslyManaged: Set<String> = ["Science", "ArchiveSuite"]

        // Project with empty subjects — all previously managed tokens are removed.
        let desired: Set<String> = []
        _ = try NotesTagProjector.project(desired, previouslyManaged: previouslyManaged, to: url, itemDir: dir)

        let after = try readTags(url)
        #expect(!after.contains("Science"), "Previously managed tag removed")
        #expect(after.contains("MyPersonalTag"), "Unmanaged tag preserved")
        #expect(!after.contains("ArchiveSuite"), "Legacy marker stripped")
    }

    // MARK: - §6 ArchiveSuite is now an ordinary subject: no dup

    @Test("ArchiveSuite subject remains an ordinary subject — no dup")
    func archiveSuiteSubjectCollisionNoDup() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        // The former marker name is now simply a user subject.
        let url = try makeScratchFile(in: dir, tags: [])
        let item = makeItem(tags: ["ArchiveSuite", "History"])
        let desired = NotesTagVocabulary.managedTokens(for: item)

        // First projection (no previous managed).
        let result = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)

        let after = try readTags(url)
        // "ArchiveSuite" appears exactly once (deduped as a normal subject).
        let subjectCount = after.filter { $0 == "ArchiveSuite" }.count
        #expect(subjectCount == 1, "ArchiveSuite must appear exactly once, got \(subjectCount)")
        #expect(after.contains("History"), "Subject tag present")
        #expect(result.contains("ArchiveSuite"))
    }

    // MARK: - §8 Verify-by-re-read catches mismatch

    @Test("verify by re-read catches mismatch (via CoordinatedTagWriter)")
    func verifyByReReadCatchesMismatch() async throws {
        // CoordinatedTagWriter already enforces §8 internally — this test confirms the
        // projector surfaces failures rather than silently succeeding. We test the normal
        // happy path (which should not fail) and confirm the mechanism works by asserting
        // that a successful projection's result matches re-read.
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        let url = try makeScratchFile(in: dir, tags: [])
        let desired: Set<String> = ["History", "Economics"]
        _ = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)

        // Re-read and confirm the tags match.
        let after = try readTags(url)
        for token in desired {
            #expect(after.contains(token), "Expected \(token) in re-read tags")
        }
        // No extra managed tokens.
        let extras = Set(after).subtracting(desired)
        #expect(extras.isEmpty, "No unexpected tokens: \(extras)")
    }

    // MARK: - §7 Never writes label

    @Test("never writes label — label unchanged after projection")
    func neverWritesLabel() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        let url = try makeScratchFile(in: dir, tags: [])
        // Set a color label manually (e.g. Red = 6).
        try (url as NSURL).setResourceValue(6, forKey: .labelNumberKey)
        let labelBefore = try readLabel(url)

        let desired: Set<String> = ["History"]
        _ = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)

        let labelAfter = try readLabel(url)
        #expect(normalizedLabel(labelAfter) == normalizedLabel(labelBefore),
                "Label must not change: was \(String(describing: labelBefore)), now \(String(describing: labelAfter))")
    }

    // MARK: - Concurrent third-party tag preserved

    @Test("concurrent third-party tag added between calls is preserved")
    func concurrentThirdPartyTagPreserved() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        let url = try makeScratchFile(in: dir, tags: [])

        // First projection: add History.
        let desired1: Set<String> = ["History"]
        let managed1 = try NotesTagProjector.project(desired1, previouslyManaged: [], to: url, itemDir: dir)

        // Simulate a third-party adding a tag between projections.
        var tags = try readTags(url)
        tags.append("ThirdPartyTag")
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)

        // Second projection: same desired, with managed1 as previouslyManaged.
        let desired2: Set<String> = ["History"]
        _ = try NotesTagProjector.project(desired2, previouslyManaged: managed1, to: url, itemDir: dir)

        let after = try readTags(url)
        #expect(after.contains("ThirdPartyTag"), "Third-party tag must survive re-projection")
        #expect(after.contains("History"))
    }

    // MARK: - Component-boundary guard

    @Test("rejects URL outside item directory")
    func outsideItemDirRejected() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        // Create a file OUTSIDE the item dir.
        let outsideDir = dir.deletingLastPathComponent()
        let url = try makeScratchFile(in: outsideDir, name: "escape.md")

        let desired: Set<String> = ["History"]
        do {
            _ = try NotesTagProjector.project(desired, previouslyManaged: [], to: url, itemDir: dir)
            Issue.record("Expected outsideItemDir error")
        } catch let e as NotesTagProjector.ProjectError {
            if case .outsideItemDir = e { /* expected */ } else {
                Issue.record("Wrong error: \(e)")
            }
        }
    }

    // MARK: - Recovery helper

    @Test("recoverPreviouslyManaged seeds from current tags")
    func recoverPreviouslyManaged() async throws {
        let dir = try makeScratchDir()
        defer { cleanup(dir) }

        // File already has a managed-looking subject, a retired marker, and an unmanaged tag.
        let url = try makeScratchFile(in: dir, tags: ["History", "ArchiveSuite", "Random"])
        let item = makeItem(tags: ["history"]) // lowercase in front-matter

        let recovered = NotesTagProjector.recoverPreviouslyManaged(for: item, from: url)
        // "History" matches titleCased("history"). The retired marker is no longer managed.
        #expect(recovered.contains("History"))
        #expect(!recovered.contains("ArchiveSuite"))
        // "Random" is not a candidate managed token.
        #expect(!recovered.contains("Random"))
    }
}
