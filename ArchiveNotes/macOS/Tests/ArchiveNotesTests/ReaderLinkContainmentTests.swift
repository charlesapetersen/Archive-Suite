// ReaderLinkContainmentTests.swift — W23.l1: the granted-root containment check is
// canonical, so a symlink cannot walk the resolver out of the root the user granted.
//
// The defect these guard: `resolveExact` compared `standardizedFileURL` paths, which
// normalizes `.`/`..` **lexically** but does not resolve symlinks, and then called
// `fileExists`, which **does** follow them. So `<root>/alias.pdf` → an otherwise-reachable
// PDF outside the root passed the boundary test and came back `.resolved` — a semantic
// bypass of the resolver's own stated granted-root contract.
//
// Every escape case first asserts the PRE-FIX rule accepted the fixture, so a passing test
// can never be vacuous: the tree really does reproduce the bug (mirrors the W23.m3
// `AssetPathResolverTests` pattern). The no-regression cases matter just as much — a root
// that is *itself* reached through a symlink must still contain its own files, which is why
// both sides of the comparison are canonicalized rather than just the candidate.
//
// Scratch only: every fixture is a fresh temp tree, and `readerRootBookmarks` (the one thing
// `grantRoot` persists) is snapshotted and restored, so the host's defaults are left
// byte-identical. Never a real corpus.

import Testing
import Foundation
@testable import ArchiveNotes
@testable import ArchiveCore

@MainActor
@Suite("Reader link root containment (W23.l1)", .serialized)
struct ReaderLinkContainmentTests {

    // MARK: - Fixtures

    /// A scratch tree holding two siblings: `root` (a granted Reader root, with its marker)
    /// and `outside` — the target every escape in this suite aims at. Remove `base` to clean
    /// both up at once.
    private func makeTree() throws -> (base: URL, root: URL, outside: URL, guid: UUID) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-l1-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let guid = UUID()
        let marker = RootMarker(guid: guid, name: root.lastPathComponent,
                                kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: root.appendingPathComponent(RootMarker.filename), options: .atomic)

        return (base, root, outside, guid)
    }

    @discardableResult
    private func writeFile(at url: URL, _ text: String = "%PDF-1.4 scratch\n") throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func symlink(at linkURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: destination)
    }

    /// Run `body` with `readerRootBookmarks` snapshotted and restored — `grantRoot` persists
    /// there, and this suite must leave the host's defaults untouched.
    private func withHermeticBookmarks(_ body: () async throws -> Void) async rethrows {
        let key = "readerRootBookmarks"
        let saved = UserDefaults.standard.dictionary(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    /// Containment exactly as it read **before** W23.l1: a lexical `standardizedFileURL`
    /// prefix test, then a `fileExists` that follows symlinks. A fixture this accepts is one
    /// the resolver used to hand back as `.resolved`, which is what makes each refusal test
    /// below a real regression guard rather than a tautology.
    private func preFixRuleResolves(root: URL, relativePath: String) -> Bool {
        let target = root.appendingPathComponent(relativePath)
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return false }
        return FileManager.default.fileExists(atPath: targetPath)
    }

    // MARK: - 1. Escapes are refused

    @Test("A symlink under the root pointing at a file outside it is refused")
    func symlinkToOutsideFileIsRefused() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        let secret = try writeFile(at: tree.outside.appendingPathComponent("secret.pdf"))
        try symlink(at: tree.root.appendingPathComponent("alias.pdf"), to: secret)

        // Non-vacuity: this tree really did resolve before the fix.
        #expect(preFixRuleResolves(root: tree.root, relativePath: "alias.pdf"))

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            store.grantRoot(tree.root)
            let resolver = ReaderLinkResolver(rootStore: store)

            #expect(resolver.resolveExact(rootGUID: tree.guid, relativePath: "alias.pdf")
                    == .decided(.notFound))
            // And no basename walk is started to reach that answer.
            let result = await resolver.resolve(rootGUID: tree.guid, relativePath: "alias.pdf")
            #expect(result == .notFound)
        }
    }

    @Test("A symlinked directory under the root is refused for everything inside it")
    func symlinkedDirectoryEscapeIsRefused() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        try writeFile(at: tree.outside.appendingPathComponent("papers/secret.pdf"))
        try symlink(at: tree.root.appendingPathComponent("away"),
                    to: tree.outside.appendingPathComponent("papers", isDirectory: true))

        #expect(preFixRuleResolves(root: tree.root, relativePath: "away/secret.pdf"))

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            store.grantRoot(tree.root)
            let resolver = ReaderLinkResolver(rootStore: store)

            let result = await resolver.resolve(rootGUID: tree.guid, relativePath: "away/secret.pdf")
            #expect(result == .notFound)
        }
    }

    // MARK: - 2. Legitimate trees still resolve

    @Test("A symlink that stays inside the root still resolves")
    func symlinkInsideRootStillResolves() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        let real = try writeFile(at: tree.root.appendingPathComponent("collection/doc.pdf"))
        try symlink(at: tree.root.appendingPathComponent("shortcut.pdf"), to: real)

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            store.grantRoot(tree.root)
            let resolver = ReaderLinkResolver(rootStore: store)

            let result = await resolver.resolve(rootGUID: tree.guid, relativePath: "shortcut.pdf")
            if case .resolved(let url) = result {
                #expect(url.lastPathComponent == "shortcut.pdf")
            } else {
                Issue.record("Expected .resolved for an in-root symlink, got \(result)")
            }
        }
    }

    @Test("A root reached through a symlinked ancestor still resolves its own files")
    func rootUnderSymlinkedAncestorStillResolves() async throws {
        // `<base>/real/root` is the archive; the user granted it as `<base>/alias/root` — the
        // shape an archive under a symlinked/synced parent folder has. Canonicalizing only
        // the candidate would put every file in it "outside" the granted root; canonicalizing
        // both sides is what keeps it working.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-l1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let realRoot = base.appendingPathComponent("real/root", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)

        let guid = UUID()
        let marker = RootMarker(guid: guid, name: "root", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: realRoot.appendingPathComponent(RootMarker.filename), options: .atomic)
        try writeFile(at: realRoot.appendingPathComponent("collection/doc.pdf"))

        try symlink(at: base.appendingPathComponent("alias"),
                    to: base.appendingPathComponent("real", isDirectory: true))
        let aliasedRoot = base.appendingPathComponent("alias/root", isDirectory: true)

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            #expect(store.grantRoot(aliasedRoot)?.guid == guid)
            let resolver = ReaderLinkResolver(rootStore: store)

            let result = await resolver.resolve(rootGUID: guid, relativePath: "collection/doc.pdf")
            if case .resolved(let url) = result {
                #expect(url.lastPathComponent == "doc.pdf")
            } else {
                Issue.record("Expected .resolved under a symlinked ancestor, got \(result)")
            }
        }
    }

    @Test("A root that is itself a symlink contains its files under either spelling")
    func symlinkedRootContainsItsFiles() throws {
        // The predicate directly: `ReaderRootStore` cannot register a root that IS a symlink
        // (security-scoped `bookmarkData` refuses one), so this is the level the guarantee is
        // provable at — and it is the guarantee the resolver leans on.
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        let real = try writeFile(at: tree.root.appendingPathComponent("collection/doc.pdf"))
        let aliasRoot = tree.base.appendingPathComponent("aliasRoot")
        try symlink(at: aliasRoot, to: tree.root)

        let canonicalAlias = ReaderRootContainment.canonical(aliasRoot)
        #expect(ReaderRootContainment.isContained(aliasRoot.appendingPathComponent("collection/doc.pdf"),
                                                  inCanonicalRoot: canonicalAlias))
        // The same file named the other way round is the same location, not an escape.
        #expect(ReaderRootContainment.isContained(real, inCanonicalRoot: canonicalAlias))
        #expect(!ReaderRootContainment.isContained(tree.outside, inCanonicalRoot: canonicalAlias))
    }

    @Test("A dangling symlink is not an escape — it falls through to the basename search")
    func danglingSymlinkIsNotAnEscape() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        // Points outside, but at nothing: there is no target to escape to, and refusing it
        // outright would deny the cited file the same-basename fallback every other missing
        // file gets.
        try symlink(at: tree.root.appendingPathComponent("collection/doc.pdf"),
                    to: tree.outside.appendingPathComponent("gone.pdf"))

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            store.grantRoot(tree.root)
            let resolver = ReaderLinkResolver(rootStore: store)

            let fast = resolver.resolveExact(rootGUID: tree.guid, relativePath: "collection/doc.pdf")
            if case .needsBasenameSearch(_, let basename) = fast {
                #expect(basename == "doc.pdf")
            } else {
                Issue.record("Expected .needsBasenameSearch for a dangling symlink, got \(fast)")
            }
        }
    }

    // MARK: - 3. The containment predicate itself

    @Test("Containment is component-wise: a sibling whose name extends the root's is out")
    func siblingWithExtendedNameIsNotContained() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        // `…/root-extra/doc.pdf` string-prefixes `…/root` — the reason the comparison walks
        // path components instead of characters.
        let sibling = try writeFile(at: tree.base.appendingPathComponent("root-extra/doc.pdf"))
        let canonicalRoot = ReaderRootContainment.canonical(tree.root)

        #expect(!ReaderRootContainment.isContained(sibling, inCanonicalRoot: canonicalRoot))
        #expect(sibling.standardizedFileURL.path.hasPrefix(tree.root.standardizedFileURL.path))
    }

    @Test("The root itself is contained, and both path spellings agree")
    func rootAndItsAliasAreContained() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        let inside = try writeFile(at: tree.root.appendingPathComponent("a/b/doc.pdf"))
        let canonicalRoot = ReaderRootContainment.canonical(tree.root)

        #expect(ReaderRootContainment.isContained(tree.root, inCanonicalRoot: canonicalRoot))
        #expect(ReaderRootContainment.isContained(inside, inCanonicalRoot: canonicalRoot))
        #expect(!ReaderRootContainment.isContained(tree.outside, inCanonicalRoot: canonicalRoot))
        // A `/private`-prefixed spelling of the same file (what `FileManager`'s enumerator
        // hands back under `/var/folders`) must not read as a different location.
        let privateSpelling = URL(fileURLWithPath: "/private" + inside.path)
        if FileManager.default.fileExists(atPath: privateSpelling.path) {
            #expect(ReaderRootContainment.isContained(privateSpelling, inCanonicalRoot: canonicalRoot))
        }
    }

    // MARK: - 4. The basename fallback is held to the same contract

    /// The walk's match rule exactly as it read **before** W23.l1: the first entry whose last
    /// path component matches, with no containment test at all. The enumerator lists a symlink
    /// as an ordinary entry, so this is what used to offer an escape as `.renamedCandidate`.
    private func preFixScanMatch(name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        while let entry = enumerator.nextObject() {
            if let url = entry as? URL, url.lastPathComponent == name { return url }
        }
        return nil
    }

    @Test("The basename fallback never offers a match that escapes the root")
    func basenameFallbackRefusesEscapingMatch() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        // The cited path is gone; the only `doc.pdf` left under the root is a symlink out.
        let elsewhere = try writeFile(at: tree.outside.appendingPathComponent("doc.pdf"))
        try symlink(at: tree.root.appendingPathComponent("mirror/doc.pdf"), to: elsewhere)

        // Non-vacuity: the pre-fix walk would have handed that symlink back as the candidate.
        #expect(preFixScanMatch(name: "doc.pdf", under: tree.root) != nil)

        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: tree.root)
        #expect(scan.match == nil)
        // Skipped, not stopped: absence under the root really was established.
        #expect(scan.stop == .exhausted)

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            store.grantRoot(tree.root)
            let resolver = ReaderLinkResolver(rootStore: store)
            let result = await resolver.resolve(rootGUID: tree.guid,
                                                relativePath: "collection/doc.pdf")
            #expect(result == .notFound)
        }
    }

    @Test("A genuine in-root copy is still offered when an escaping twin shares its name")
    func basenameFallbackStillFindsTheContainedCopy() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }

        let elsewhere = try writeFile(at: tree.outside.appendingPathComponent("doc.pdf"))
        try symlink(at: tree.root.appendingPathComponent("aaa/doc.pdf"), to: elsewhere)
        let realCopy = try writeFile(at: tree.root.appendingPathComponent("zzz/doc.pdf"))

        // Whichever the walk meets first, the answer must be the contained one. Compared
        // canonically: the enumerator hands back its own spelling of the same path.
        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: tree.root)
        #expect(scan.match.map { ReaderRootContainment.canonical($0).path }
                == ReaderRootContainment.canonical(realCopy).path)

        await withHermeticBookmarks {
            let store = ReaderRootStore()
            store.grantRoot(tree.root)
            let resolver = ReaderLinkResolver(rootStore: store)
            let result = await resolver.resolve(rootGUID: tree.guid,
                                                relativePath: "collection/doc.pdf")
            if case .renamedCandidate(let url) = result {
                #expect(url.path.contains("zzz"))
                #expect(!url.path.contains("aaa"))
            } else {
                Issue.record("Expected .renamedCandidate for the contained copy, got \(result)")
            }
        }
    }
}
