import XCTest
import ArchiveCore

/// W26.walk1 — the deterministic filesystem walk that replaces Spotlight discovery.
///
/// Three things these tests are built to prove, because the incident of 2026-08-04 turned on all
/// three: the walk finds **exactly** the right set, it says **"I could not read this"** as something
/// distinct from "there is nothing here", and it **never writes to the tree it reads**.
///
/// Deliberately `import ArchiveCore`, not `@testable`: every symbol the two apps will build on is
/// public, and this file is the guard that a later refactor cannot quietly demote one.
///
/// Throwaway temp fixtures only — never the corpus (Reader Core Directive).
final class CorpusWalkerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusWalkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let tempDir else { return }
        // Some cases seal a directory or a file; restore access or removal itself fails.
        restoreAccess(tempDir)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture helpers

    /// A fresh `URL` for `path`. `URL.resourceValues` caches on the backing `NSURL`, so reusing a URL
    /// across a state change makes a test pass while asserting nothing (measured; plan §5.1).
    private func fresh(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @discardableResult
    private func makeFile(_ relativePath: String, tags: [String] = [], in root: URL? = nil) throws -> URL {
        let base = root ?? tempDir!
        let url = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty {
            try (fresh(url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        return url
    }

    private func chmod(_ url: URL, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func restoreAccess(_ root: URL) {
        let fm = FileManager.default
        chmod(root, 0o755)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                                    errorHandler: { _, _ in true }) else { return }
        while let u = en.nextObject() as? URL { chmod(u, 0o755) }
    }

    /// Relative paths of the entries a scan returned, sorted — the shape assertions read off this.
    ///
    /// Compared by path COMPONENTS after normalising both sides, not by stripping a string prefix:
    /// `NSTemporaryDirectory()` hands back `/var/folders/…` while `FileManager.enumerator` yields the
    /// resolved `/private/var/folders/…`, and `resolvingSymlinksInPath()` deliberately *removes* a
    /// leading `/private` — so a prefix strip silently leaves `/private` glued to every name.
    private func relativePaths(_ result: CorpusScanResult, root: URL) -> [String] {
        let rootComponents = normalized(root)
        return result.entries.map { entry in
            let components = normalized(entry.url)
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents
            else { return "NOT-UNDER-ROOT:\(entry.url.path)" }
            return components.dropFirst(rootComponents.count).joined(separator: "/")
        }.sorted()
    }

    private func normalized(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    private func fileSystemBytes(_ url: URL) -> [UInt8] {
        url.withUnsafeFileSystemRepresentation { raw in
            raw.map { Array(String(cString: $0).utf8) } ?? []
        }
    }

    // MARK: - 1. The exact membership set

    func testScanReturnsExactlyTheReadUnreadTaggedFilesOnAMixedFixture() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try makeFile("tagged-unread.pdf", tags: ["Unread", "Subject/Foo"], in: root)
        try makeFile("tagged-read.pdf", tags: ["Read", "P3"], in: root)
        // Case-insensitive, exactly as the shipped Spotlight predicate and fixture loader were.
        try makeFile("tagged-lowercase.pdf", tags: ["unread"], in: root)
        try makeFile("untagged.pdf", in: root)
        try makeFile("other-tags-only.pdf", tags: ["Purple", "Subject/Bar"], in: root)
        // Hidden: excluded by `.skipsHiddenFiles`.
        try makeFile(".hidden-tagged.pdf", tags: ["Unread"], in: root)
        // Nested, with the two characters the corpus actually contains: U+2014 em dash, U+00A0 NBSP.
        let awkward = "Nested/deep/report\u{2014}final\u{00A0}copy.pdf"
        try makeFile(awkward, tags: ["Read"], in: root)
        // Package descendant: excluded by `.skipsPackageDescendants`.
        try makeFile("Bundle.rtfd/inside-tagged.pdf", tags: ["Unread"], in: root)

        let result = CorpusWalker.scan(root: root)

        XCTAssertEqual(relativePaths(result, root: root),
                       [awkward, "tagged-lowercase.pdf", "tagged-read.pdf", "tagged-unread.pdf"].sorted(),
                       "membership must be exactly 'carries Read or Unread', case-insensitively")
        XCTAssertTrue(result.isClean, "a fully readable fixture must produce a clean pass")
        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.unreadable.isEmpty)
        XCTAssertTrue(result.directoryErrors.isEmpty)
        XCTAssertEqual(result.vanishedMidScan, 0)
        XCTAssertFalse(result.rootUnreadable)
        // 6 regular files at/below `root` that the options do not exclude: the four matches plus
        // untagged.pdf and other-tags-only.pdf. Hidden + package descendants are never even seen.
        XCTAssertEqual(result.filesSeen, 6, "filesSeen counts every regular file the walk classified")

        // Tag names travel raw, in disk order — the caller parses (DocumentTags), the walker does not.
        let unread = try XCTUnwrap(result.entries.first { $0.url.lastPathComponent == "tagged-unread.pdf" })
        XCTAssertEqual(unread.tagNames, ["Unread", "Subject/Foo"])
        XCTAssertEqual(unread.contentTypeIdentifier, "com.adobe.pdf")
        XCTAssertNotNil(unread.contentModified)
        XCTAssertFalse(unread.isDataless, "an ordinary local file is not a cloud placeholder")
    }

    func testHasAnyTagPredicateWidensMembershipWithoutChangingTheWalk() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("read.pdf", tags: ["Read"], in: root)
        try makeFile("subject-only.pdf", tags: ["Subject/Bar"], in: root)
        try makeFile("bare.pdf", in: root)

        let library = CorpusWalker.scan(root: root)
        let vocabulary = CorpusWalker.scan(root: root, predicate: CorpusWalker.hasAnyTag)

        XCTAssertEqual(relativePaths(library, root: root), ["read.pdf"])
        XCTAssertEqual(relativePaths(vocabulary, root: root), ["read.pdf", "subject-only.pdf"])
        XCTAssertEqual(library.filesSeen, vocabulary.filesSeen, "the predicate filters, it does not walk")
    }

    /// W26.fsev: a file event uses this one-path primitive instead of turning every tag edit into a
    /// 123k-file walk. Every classification is positive: unreadable is never folded into untracked.
    func testInspectClassifiesAPathThroughTheWalkersMembershipPrimitive() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tracked = try makeFile("tracked.pdf", tags: ["Unread", "Subject/Foo"], in: root)
        let untracked = try makeFile("untracked.pdf", tags: ["Subject/Bar"], in: root)
        let missing = root.appendingPathComponent("missing.pdf")

        guard case let .tracked(entry) = CorpusWalker.inspect(tracked) else {
            return XCTFail("Read/Unread must be a tracked entry")
        }
        XCTAssertEqual(entry.tagNames, ["Unread", "Subject/Foo"])
        XCTAssertEqual(CorpusWalker.inspect(untracked), .untracked)
        XCTAssertEqual(CorpusWalker.inspect(root), .directory)
        XCTAssertEqual(CorpusWalker.inspect(missing), .vanished)
    }

    /// `URL.resourceValues` caches on its backing NSURL. A live read must reconstruct from the path,
    /// or the exact URL already used for a pre-change read can hide a third-party Finder-tag update.
    func testInspectDoesNotReuseAStaleURLResourceCacheAcrossATagChange() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try makeFile("changed.pdf", tags: ["Unread"], in: root)
        _ = try url.resourceValues(forKeys: [.tagNamesKey])       // deliberately seed NSURL's cache

        try (fresh(url.path) as NSURL).setResourceValue(["Read", "Subject/New"], forKey: .tagNamesKey)

        guard case let .tracked(entry) = CorpusWalker.inspect(url) else {
            return XCTFail("the freshly tagged path must remain tracked")
        }
        XCTAssertEqual(entry.tagNames, ["Read", "Subject/New"],
                       "the event read must see disk, not a cached resource-value snapshot")
    }

    func testInspectRefreshesURLWithoutNormalisingItsFilesystemSpelling() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.path + "/caf\u{e9}.pdf"
        let url = path.withCString {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
        }
        try Data("PDF".utf8).write(to: url)
        try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        let spelling = fileSystemBytes(url)

        guard case let .tracked(entry) = CorpusWalker.inspect(url) else {
            return XCTFail("the exact-spelling fixture must remain tracked")
        }

        XCTAssertEqual(fileSystemBytes(entry.url), spelling,
                       "fresh inspection must not round-trip the path through NFC/NFD")
    }

    func testInspectDistinguishesADirectorySymlinkFromARealDirectory() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        let target = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(CorpusWalker.inspect(root), .directory)
        XCTAssertEqual(CorpusWalker.inspect(link), .directorySymbolicLink,
                       "live consumers must not turn this path into a subtree walk outside root")
    }

    // MARK: - 2. It must not write to what it reads

    func testAScanLeavesTheFixtureByteIdentical() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("tagged.pdf", tags: ["Unread", "Subject/Foo", "P1"], in: root)
        try makeFile("untagged.pdf", in: root)
        // A file whose tags were REMOVED keeps a 42-byte empty-array plist. 51 of the owner's corpus
        // files are in that state, and it is the shape most likely to tempt a "just rewrite it" fix.
        let emptied = try makeFile("emptied.pdf", tags: ["Unread"], in: root)
        try (fresh(emptied.path) as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
        try makeFile(".hidden.pdf", tags: ["Read"], in: root)
        try makeFile("Nested/deep/leaf.pdf", tags: ["Read"], in: root)
        try makeFile("Bundle.rtfd/inside.pdf", tags: ["Unread"], in: root)

        let before = snapshot(root)
        XCTAssertGreaterThanOrEqual(before.count, 8, "the snapshot must actually cover the fixture")

        _ = CorpusWalker.scan(root: root)
        _ = CorpusWalker.scan(root: root, predicate: CorpusWalker.hasAnyTag)

        let after = snapshot(root)
        XCTAssertEqual(after, before,
                       "the walk must not change size, mode, mtime, ctime, flags or tag xattr of anything")
    }

    /// mtime + **ctime** + size + mode + flags + the raw tag xattr, for every entry at or below `root`,
    /// hidden and package descendants included. ctime is the load-bearing one: an xattr write bumps
    /// ctime without touching mtime, which is exactly how a tag write hides from a naive check.
    /// `atime` is deliberately excluded — reading legitimately updates it.
    private func snapshot(_ root: URL) -> [String: String] {
        var urls = [root]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                  options: [], errorHandler: { _, _ in true }) {
            while let u = en.nextObject() as? URL { urls.append(u) }
        }
        var out: [String: String] = [:]
        for u in urls {
            out[u.path] = u.withUnsafeFileSystemRepresentation { raw -> String in
                guard let raw else { return "NO-FS-REPRESENTATION" }
                var st = stat()
                guard lstat(raw, &st) == 0 else { return "MISSING(errno \(errno))" }
                let size = getxattr(raw, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW)
                var tagBlob = "none(errno \(errno))"
                if size >= 0 {
                    var buf = [UInt8](repeating: 0, count: max(size, 1))
                    let read = getxattr(raw, "com.apple.metadata:_kMDItemUserTags", &buf, size, 0, XATTR_NOFOLLOW)
                    tagBlob = read >= 0 ? Data(buf[0..<read]).base64EncodedString() : "unreadable"
                }
                return [
                    "mode=\(st.st_mode)", "size=\(st.st_size)", "flags=\(st.st_flags)",
                    "mtime=\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)",
                    "ctime=\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)",
                    "tags=\(tagBlob)",
                ].joined(separator: " ")
            }
        }
        return out
    }

    // MARK: - 3. "I could not read this" is never "there is nothing here"

    func testAnUnreadableFileIsCountedAndNeverReportedAsUntagged() throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("readable.pdf", tags: ["Read"], in: root)
        let sealed = try makeFile("sealed.pdf", tags: ["Unread", "Subject/Foo", "P9"], in: root)
        chmod(sealed, 0o000)   // traversable parent, unreadable file — the W26.deny leak exactly

        let result = CorpusWalker.scan(root: root)

        XCTAssertEqual(relativePaths(result, root: root), ["readable.pdf"])
        XCTAssertEqual(result.unreadable.count, 1, "the failure must be counted, never `continue`d away")
        XCTAssertEqual(result.unreadable.first?.url.lastPathComponent, "sealed.pdf")
        XCTAssertFalse(result.isClean, "one unreadable file makes the whole pass non-authoritative")
        XCTAssertTrue(result.completed, "the enumerator still ran to the end — that is not the same thing")
        XCTAssertEqual(result.vanishedMidScan, 0, "a denial is not a disappearance")
        XCTAssertFalse(result.entries.contains { $0.url.lastPathComponent == "sealed.pdf" },
                       "an unreadable file must never appear as an entry with no tags")
    }

    func testAnUnreadableDirectoryIsRecordedRatherThanSilentlySkipped() throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("visible.pdf", tags: ["Read"], in: root)
        let sealedDir = root.appendingPathComponent("Sealed", isDirectory: true)
        try makeFile("Sealed/hidden-from-us.pdf", tags: ["Unread"], in: root)
        chmod(sealedDir, 0o000)

        let result = CorpusWalker.scan(root: root)

        XCTAssertEqual(relativePaths(result, root: root), ["visible.pdf"])
        XCTAssertFalse(result.directoryErrors.isEmpty,
                       "the errorHandler-less enumerator overload skips this in total silence")
        XCTAssertFalse(result.isClean, "1,849 tagged files were once reported as 'none' exactly like this")
    }

    func testAnUnreadableRootIsNotAnEmptyLibrary() throws {
        let missing = tempDir.appendingPathComponent("never-created", isDirectory: true)

        let result = CorpusWalker.scan(root: missing)

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.isClean, "a root we cannot enumerate must not report an actionable absence")
        XCTAssertTrue(result.rootUnreadable, "the root could not be opened, so say THAT")
    }

    // MARK: - 3b. `rootUnreadable` means what its name says (W26.vocab-fu1)

    /// The three ways a root goes bad, each pinned as `rootUnreadable` rather than as a completed pass
    /// over an empty tree.
    ///
    /// This is a regression test against a real, measured trap, not a hypothetical: `FileManager
    /// .enumerator(at:)` hands back a **live enumerator** for every one of these roots, reports the root
    /// once to `errorHandler:` and then ends. Before `W26.vocab-fu1` all three therefore came back
    /// `completed == true` / `rootUnreadable == false` / `filesSeen == 0`, so any caller gating on
    /// `completed` — which is what "did the walk finish?" reads like — could not tell a walk that read
    /// **nothing** from a walk that **found** nothing. That is the 2026-08-04 incident's shape one layer
    /// below where it was fixed.
    ///
    /// `isClean` is asserted alongside because it is the absence gate the Reader uses, and it was
    /// already false here (via `directoryErrors`) before this change. The point of the change is the
    /// *diagnosis*, so it must be `completed`/`rootUnreadable` that carry it.
    func testEveryUnopenableRootReportsRootUnreadableRatherThanACompletedEmptyPass() throws {
        try XCTSkipIf(getuid() == 0, "root can open a 0o000 directory; the denial case is meaningless")

        let missing = tempDir.appendingPathComponent("never-created", isDirectory: true)

        let sealed = tempDir.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try makeFile("sealed/inside.pdf", tags: ["Unread"], in: tempDir)
        chmod(sealed, 0o000)

        // Not a directory at all. A caller that hands us a file rather than a folder has not discovered
        // an empty archive either.
        let notADirectory = try makeFile("a-plain-file.pdf", tags: ["Unread"])

        for (label, root) in [("missing", missing), ("0o000", sealed), ("regular file", notADirectory)] {
            // The public seam every walk routes through, asserted directly: a caller aligning its own
            // root spelling (`W26.symroot`) must get the same verdict the walk acts on.
            XCTAssertNil(CorpusWalker.canonicalRoot(root), "\(label): there is nothing to enumerate")

            let result = CorpusWalker.scan(root: root)

            XCTAssertTrue(result.rootUnreadable, "\(label): the root could not be opened")
            XCTAssertFalse(result.completed, "\(label): a pass that opened nothing did not complete")
            XCTAssertFalse(result.isClean, "\(label): and absence here is never actionable")
            XCTAssertTrue(result.entries.isEmpty, "\(label)")
            XCTAssertEqual(result.filesSeen, 0, "\(label)")

            // The same answer from the cheap revalidation walk. `LibraryIndex` prunes cache rows off
            // this result, so a vanished root leaking through as "completed, zero files" would delete a
            // warm library rather than degrade it.
            let fingerprints = CorpusWalker.scanFingerprints(root: root)
            XCTAssertTrue(fingerprints.rootUnreadable, "\(label): fingerprint walk agrees")
            XCTAssertFalse(fingerprints.completed, "\(label)")
            XCTAssertTrue(fingerprints.entries.isEmpty, "\(label)")
        }
    }

    /// The counter-case that stops the probe above from being a blunt "any error fails the root": a
    /// denial **below** the root leaves the pass completed, because everything outside that subtree was
    /// genuinely read. Only `isClean` falls — the distinction `directoryErrors` exists to carry.
    ///
    /// Without this, tightening `rootUnreadable` would silently re-file every sealed subfolder as an
    /// unreadable archive, and the Processor's vocabulary harvest — which stamps on `completed` — would
    /// re-walk a 100k-file corpus on every tagging-UI appearance for one permanently-locked folder.
    func testADenialBELOWTheRootStillCompletesTheWalk() throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("readable.pdf", tags: ["Read"], in: root)
        try makeFile("Locked/hidden.pdf", tags: ["Unread"], in: root)
        chmod(root.appendingPathComponent("Locked", isDirectory: true), 0o000)

        let result = CorpusWalker.scan(root: root)

        try XCTSkipUnless(!result.directoryErrors.isEmpty,
                          "this environment could descend the 0o000 directory; case N/A")
        XCTAssertFalse(result.rootUnreadable, "the ROOT opened fine — only a subtree did not")
        XCTAssertTrue(result.completed, "so the pass completed, and the harvest may stamp it")
        XCTAssertFalse(result.isClean, "…while absence stays non-actionable")
        XCTAssertEqual(relativePaths(result, root: root), ["readable.pdf"])
    }

    // MARK: - 3c. A root that is ITSELF a symlink (W26.symroot)

    /// A symlinked root is walked **through its target**, and the entries come back spelled under the
    /// target — the identity decision this item had to settle before any code was written.
    ///
    /// `FileManager.enumerator(at:)` refuses a symlinked root outright: it reports the link to
    /// `errorHandler:` and yields nothing, even when the target is a readable directory full of tagged
    /// files (measured 2026-08-06, including through a trailing-slash spelling). So before this change
    /// such a root discovered *nothing at all* — first as a completed-looking empty pass, then, once
    /// `W26.vocab-fu1` taught the probe to `lstat`, as an honest `rootUnreadable`.
    ///
    /// **`W26.symroot` was filed expecting the opposite spelling** — walk the target but rewrite every
    /// discovered path back under the caller's `link/` prefix, to protect the byte-exact `(root, path)`
    /// contract `LibraryIndex` keys on. Measured, that premise does not hold: the enumerator **already**
    /// hands back ancestor-resolved paths (a root spelled `/var/folders/…` yields `/private/var/…`
    /// entries — see `testANonSymlinkedRootIsUsedEXACTLYAsTheCallerSpelledIt`), so the caller's spelling
    /// was never what the walk emitted. A rewrite would invent a third spelling that neither FileManager
    /// nor FSEvents ever produces, and `CorpusWatcher`'s realpath'd live events would then match no row:
    /// every tag write under such a root would look like a brand-new file. Hence the byte-exact
    /// assertion below, which is the one that would fail if someone re-implemented the filed design.
    func testARootThatIsItselfASymlinkIsWalkedThroughItsTarget() throws {
        let real = tempDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try makeFile("doc.pdf", tags: ["Read"], in: real)
        try makeFile("Nested/deep.pdf", tags: ["Unread"], in: real)
        try makeFile("untagged.pdf", in: real)
        let link = tempDir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The premise, pinned: Foundation still refuses the link itself. If a future Foundation follows
        // it, this fails as ITSELF — telling us the symlink branch is now redundant, rather than wrong.
        let raw = FileManager().enumerator(at: link, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                           errorHandler: { _, _ in true })
        XCTAssertNil(raw?.nextObject(), "premise: the enumerator yields nothing for a symlinked root")

        let result = CorpusWalker.scan(root: link)

        XCTAssertFalse(result.rootUnreadable, "the target is a readable directory, so this root IS readable")
        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.isClean, "and a fully readable tree reached through a link is authoritative")
        XCTAssertEqual(result.filesSeen, 3)
        // MEMBERSHIP only. `relativePaths` normalises BOTH sides through `resolvingSymlinksInPath()`, so
        // this line would pass unchanged even if the entries came back spelled under `link/` — it is not
        // the spelling assertion it can be mistaken for. The byte comparison below is the only thing
        // holding the identity decision; do not "simplify" it away on the strength of this line.
        XCTAssertEqual(relativePaths(result, root: real), ["Nested/deep.pdf", "doc.pdf"])

        // Identity follows enumeration: through the link or straight at the target, ONE byte-exact
        // spelling. Asserted in bytes, not on `URL`, because `String ==` is canonical equivalence.
        let direct = CorpusWalker.scan(root: real)
        XCTAssertEqual(direct.entries.count, 2, "premise: the target is a good root in its own right")
        XCTAssertEqual(result.entries.map { fileSystemBytes($0.url) },
                       direct.entries.map { fileSystemBytes($0.url) },
                       "a symlinked root must not be a SECOND byte-spelling of the same archive")

        // The cheap revalidation walk has to resolve the root the same way. If it did not, a warm root
        // would revalidate to zero files against rows the full walk had just written — and every one of
        // them would read as deleted.
        let fingerprints = CorpusWalker.scanFingerprints(root: link)
        XCTAssertFalse(fingerprints.rootUnreadable)
        XCTAssertEqual(Set(fingerprints.entries.map { fileSystemBytes($0.url) }),
                       Set(CorpusWalker.scanFingerprints(root: real).entries.map { fileSystemBytes($0.url) }),
                       "scan and scanFingerprints must agree about what the root IS")
    }

    /// The four ways a symlinked root is still unusable. None of them may look like an empty archive,
    /// and none may hang.
    ///
    /// The link-to-a-regular-file case is the load-bearing one: `realpath` *succeeds* for it, so only
    /// the `opendir` of the resolved path rejects it. Drop that second probe as redundant and this is
    /// the assertion that catches you — which is exactly why the uid check below is scoped to the ONE
    /// case that needs it instead of skipping the whole function. A function-wide `XCTSkipIf` here (how
    /// this was first written, and what the adversarial pass caught) would silently retire the strongest
    /// assertion in the file on any machine that runs the suite as root.
    func testASymlinkedRootWhoseTargetIsUnusableIsStillRootUnreadable() throws {
        let dangling = tempDir.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: tempDir.appendingPathComponent("never-created", isDirectory: true))

        let toFile = tempDir.appendingPathComponent("to-file", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: toFile,
                                                   withDestinationURL: try makeFile("target.pdf", tags: ["Read"]))

        let sealed = tempDir.appendingPathComponent("sealed-target", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try makeFile("inside.pdf", tags: ["Unread"], in: sealed)
        chmod(sealed, 0o000)
        let toSealed = tempDir.appendingPathComponent("to-sealed", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: toSealed, withDestinationURL: sealed)

        // A cycle. `realpath` answers `ELOOP` in one call — the reason it is used instead of chasing
        // `readlink` by hand, which would need its own loop bound.
        let cycleA = tempDir.appendingPathComponent("cycle-a", isDirectory: true)
        let cycleB = tempDir.appendingPathComponent("cycle-b", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: cycleA, withDestinationURL: cycleB)
        try FileManager.default.createSymbolicLink(at: cycleB, withDestinationURL: cycleA)

        var cases: [(String, URL)] = [("dangling", dangling), ("to a regular file", toFile),
                                      ("cycle", cycleA)]
        // Only THIS case is meaningless as root, which can open a 0o000 directory.
        if getuid() != 0 { cases.append(("to a denied directory", toSealed)) }

        for (label, root) in cases {
            XCTAssertNil(CorpusWalker.canonicalRoot(root), "\(label): there is nothing to enumerate")

            let result = CorpusWalker.scan(root: root)
            XCTAssertTrue(result.rootUnreadable, "\(label): the walk must say it could not look")
            XCTAssertFalse(result.completed, "\(label)")
            XCTAssertFalse(result.isClean, "\(label): absence here is never actionable")
            XCTAssertTrue(result.entries.isEmpty, "\(label)")

            XCTAssertTrue(CorpusWalker.scanFingerprints(root: root).rootUnreadable,
                          "\(label): the fingerprint walk agrees, so no cache row is pruned")
        }
    }

    /// The narrow half of the decision: a root that is NOT a symlink reaches the enumerator **exactly**
    /// as the caller spelled it.
    ///
    /// `LibraryIndex` keys rows on byte-exact paths, so a probe that "helpfully" `realpath`'d every root
    /// would re-spell every root in the suite (`/var/folders/…` → `/private/var/folders/…`, and a
    /// case-mismatched pick on a case-insensitive volume) and orphan every cached row wholesale. That is
    /// the cost the filed item was worried about, and this is what keeps it at zero. It also pins the
    /// measured asymmetry the identity decision rests on: the ROOT keeps the caller's spelling while the
    /// ENTRIES come back ancestor-resolved, from the same pass.
    func testANonSymlinkedRootIsUsedEXACTLYAsTheCallerSpelledIt() throws {
        let root = tempDir.appendingPathComponent("under-var", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("doc.pdf", tags: ["Read"], in: root)
        XCTAssertTrue(root.path.hasPrefix("/var/"),
                      "premise: this fixture really is reached through the /var alias — \(root.path)")

        let canonical = try XCTUnwrap(CorpusWalker.canonicalRoot(root))

        XCTAssertEqual(fileSystemBytes(canonical), fileSystemBytes(root),
                       "an aliased ANCESTOR must not be resolved — that re-spells every root in the suite")
        let entry = try XCTUnwrap(CorpusWalker.scan(root: root).entries.first)
        XCTAssertTrue(entry.url.path.hasPrefix("/private/var/"),
                      "…while the enumerator resolves it in the ENTRIES regardless — \(entry.url.path)")
    }

    // MARK: - 3d. The spelling discovered paths come back with (W26.symroot-fu1)

    /// The whole contract of `discoveredPathPrefix`, asserted against the walker's own output rather
    /// than against a second copy of the rule: **every** path a pass reports is that prefix plus `/`.
    ///
    /// A caller (the Reader's folder tree, its exclusions, its warm-start containment, its relative-path
    /// link writing) has to be able to strip the root off a discovered path. Until `W26.symroot-fu1` they
    /// all used the caller's own spelling of the root, which the table in `discoveredPathPrefix` shows is
    /// not the spelling the walk emits — for three of the four roots below.
    func testEveryPathTheWalkReportsStartsWithTheDiscoveredPathPrefix() throws {
        let real = tempDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        _ = try makeFile("doc.pdf", tags: ["Read"], in: real)
        _ = try makeFile("sub/deep.pdf", tags: ["Unread"], in: real)
        let link = tempDir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let roots: [(String, URL)] = [
            ("plain directory", real),
            ("through a symlinked root", link),
            ("through a MID-PATH symlink", link.appendingPathComponent("sub", isDirectory: true)),
            ("with a trailing slash", URL(fileURLWithPath: link.path + "/", isDirectory: true)),
        ]
        for (label, root) in roots {
            let prefix = try XCTUnwrap(CorpusWalker.discoveredPathPrefix(for: root), label)
            XCTAssertFalse(prefix.hasSuffix("/"),
                           "\(label): a prefix ending in / breaks every component-boundary test")

            let result = CorpusWalker.scan(root: root)
            XCTAssertFalse(result.entries.isEmpty, "\(label): premise — this root has tagged files")
            for entry in result.entries {
                XCTAssertTrue(entry.url.path.hasPrefix(prefix + "/"),
                              "\(label): \(entry.url.path) is not under \(prefix)")
            }
            // The cheap revalidation walk emits the same spelling, or a warm root would revalidate to
            // zero rows against the very paths the full walk had just written.
            for entry in CorpusWalker.scanFingerprints(root: root).entries {
                XCTAssertTrue(entry.url.path.hasPrefix(prefix + "/"),
                              "\(label): fingerprint pass — \(entry.url.path) is not under \(prefix)")
            }
        }
    }

    /// Why this is a SECOND function and not a use of `canonicalRoot`.
    ///
    /// A mid-path symlink is the case that separates them: the final component is an ordinary directory,
    /// so `canonicalRoot` returns the root byte-unchanged — correctly, that is its documented job — while
    /// the enumerator still reports every entry under the resolved target. Anyone who "simplifies" the
    /// comparison sites back onto `canonicalRoot` fails here, and nowhere else in this file.
    func testAMidPathSymlinkIsWhyThisIsNotCanonicalRoot() throws {
        let real = tempDir.appendingPathComponent("real", isDirectory: true)
        let sub = real.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try makeFile("sub/deep.pdf", tags: ["Read"], in: real)
        let link = tempDir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaLink = link.appendingPathComponent("sub", isDirectory: true)

        let canonical = try XCTUnwrap(CorpusWalker.canonicalRoot(viaLink))
        XCTAssertEqual(fileSystemBytes(canonical), fileSystemBytes(viaLink),
                       "premise: the final component is a real directory, so canonicalRoot leaves it alone")

        let prefix = try XCTUnwrap(CorpusWalker.discoveredPathPrefix(for: viaLink))
        XCTAssertNotEqual(prefix, viaLink.path,
                          "…while the spelling the walk emits resolves the link in the MIDDLE")
        let entry = try XCTUnwrap(CorpusWalker.scan(root: viaLink).entries.first)
        XCTAssertTrue(entry.url.path.hasPrefix(prefix + "/"), entry.url.path)
        XCTAssertFalse(entry.url.path.hasPrefix(canonical.path + "/"),
                       "the canonicalRoot spelling rejects the walker's own entry — \(entry.url.path)")
    }

    /// `nil` means *this path does not resolve*, and nothing else. In particular a `0o000` directory has
    /// a perfectly good spelling: a caller that has temporarily lost access to its granted root must keep
    /// comparing paths the same way, not have every containment check start answering "not mine".
    func testTheDiscoveredPathPrefixIsNilOnlyWhenTheRootDoesNotResolve() throws {
        let missing = tempDir.appendingPathComponent("never-created", isDirectory: true)
        let dangling = tempDir.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        let cycleA = tempDir.appendingPathComponent("cycle-a", isDirectory: true)
        let cycleB = tempDir.appendingPathComponent("cycle-b", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: cycleA, withDestinationURL: cycleB)
        try FileManager.default.createSymbolicLink(at: cycleB, withDestinationURL: cycleA)

        for (label, root) in [("missing", missing), ("dangling link", dangling), ("cycle", cycleA)] {
            XCTAssertNil(CorpusWalker.discoveredPathPrefix(for: root), label)
        }

        let sealed = tempDir.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        chmod(sealed, 0o000)
        defer { chmod(sealed, 0o755) }
        if getuid() != 0 {   // root can open a 0o000 directory, so only then is this the denied case
            XCTAssertNil(CorpusWalker.canonicalRoot(sealed),
                         "premise: there is nothing to ENUMERATE here…")
        }
        // Cross-checked against the same function applied to its readable PARENT rather than against
        // `resolvingSymlinksInPath()`, which resolves in the wrong direction here: it *strips*
        // `/private`, so it would answer `/var/folders/…` where the enumerator says `/private/var/…`.
        let parentPrefix = try XCTUnwrap(CorpusWalker.discoveredPathPrefix(for: tempDir))
        XCTAssertEqual(CorpusWalker.discoveredPathPrefix(for: sealed), parentPrefix + "/sealed",
                       "…yet it still has a spelling; openability is canonicalRoot's question, not this one")

        // A link to a regular file resolves, so it has a spelling too. The walk refuses it (see
        // `testASymlinkedRootWhoseTargetIsUnusableIsStillRootUnreadable`) and that refusal is the layer
        // which must reject it; this function deliberately does not.
        let toFile = tempDir.appendingPathComponent("to-file", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: toFile,
                                                   withDestinationURL: try makeFile("target.pdf"))
        XCTAssertNotNil(CorpusWalker.discoveredPathPrefix(for: toFile))
    }

    /// An aliased *ancestor* is not an aliased root. Every fixture in this file lives under
    /// `/var/folders/…`, where `/var` is a symlink to `/private/var`, so an `lstat` applied to anything
    /// but the final path component would have failed the whole suite — which is precisely how a
    /// too-eager symlink rule would show up.
    func testAnAliasedANCESTORDoesNotMakeARootUnreadable() throws {
        let root = tempDir.appendingPathComponent("under-var", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("doc.pdf", tags: ["Read"], in: root)

        XCTAssertTrue(root.path.hasPrefix("/var/"),
                      "premise: this fixture really is reached through the /var alias — \(root.path)")

        let result = CorpusWalker.scan(root: root)

        XCTAssertFalse(result.rootUnreadable)
        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.entries.count, 1)
    }

    // MARK: - 4. Churn is not denial

    func testAMidScanDisappearanceIsChurnNotADenial() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let made: [URL] = try (0..<24).map { try makeFile(String(format: "f%02d.pdf", $0), tags: ["Unread"], in: root) }

        // `onBatch` fires after each entry (batchSize 1), i.e. from inside the walk. Deleting the rest
        // of the fixture there reproduces what the reviewer measured on a live tree: the enumerator
        // keeps yielding paths that no longer exist (403 of 1,203, with two directories renamed
        // mid-pass). Those must be churn, not denials, or ordinary Finder activity would permanently
        // mark the library degraded.
        let firstBatch = UncheckedBox(false)
        let result = CorpusWalker.scan(root: root, options: .init(batchSize: 1), onBatch: { batch in
            guard !firstBatch.value else { return }
            firstBatch.value = true
            let keep = Set(batch.entries.map(\.url.path))
            for u in made where !keep.contains(u.path) { try? FileManager.default.removeItem(at: u) }
        })

        XCTAssertTrue(result.unreadable.isEmpty, "a vanished file is not an unreadable one")
        XCTAssertTrue(result.isClean, "normal churn must not make the pass non-authoritative")
        XCTAssertLessThan(result.entries.count, made.count, "the deletions must have taken effect")
        XCTAssertGreaterThan(result.vanishedMidScan, 0,
                             "the enumerator yields already-buffered paths that are now gone; count them")
        XCTAssertEqual(result.entries.count + result.vanishedMidScan, made.count,
                       "every file is either an entry or accounted for as vanished")
    }

    // MARK: - 5. Cancellation, batching, and the I/O policy

    func testCancellationLeavesTheResultNonAuthoritative() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<20 { try makeFile(String(format: "f%02d.pdf", i), tags: ["Read"], in: root) }

        let seen = UncheckedBox(0)
        let result = CorpusWalker.scan(root: root, isCancelled: {
            seen.value += 1
            return seen.value > 5
        })

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.completed)
        XCTAssertFalse(result.isClean, "a cancelled pass can never authorise treating a file as gone")
        XCTAssertLessThan(result.entries.count, 20)
    }

    func testBatchesDeliverEveryEntryExactlyOnceAndInOrder() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<7 { try makeFile(String(format: "f%02d.pdf", i), tags: ["Read"], in: root) }

        let collected = UncheckedBox<[CorpusEntry]>([])
        let counts = UncheckedBox<[Int]>([])
        let result = CorpusWalker.scan(root: root, options: .init(batchSize: 2), onBatch: { batch in
            collected.value.append(contentsOf: batch.entries)
            counts.value.append(batch.entries.count)
        })

        XCTAssertEqual(collected.value.map { $0.url }, result.entries.map { $0.url })
        XCTAssertEqual(counts.value, [2, 2, 2, 1], "full batches, then a flush of the remainder")
    }

    func testProgressBatchesAdvanceAcrossAnUntaggedTree() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<5 { try makeFile(String(format: "f%02d.pdf", i), in: root) }

        let seen = UncheckedBox<[Int]>([])
        let matches = UncheckedBox<[Int]>([])
        let result = CorpusWalker.scan(root: root, options: .init(batchSize: 2), onBatch: { batch in
            seen.value.append(batch.filesSeen)
            matches.value.append(batch.entries.count)
        })

        XCTAssertEqual(result.filesSeen, 5)
        XCTAssertTrue(result.entries.isEmpty, "the fixture is genuinely untagged")
        XCTAssertEqual(seen.value, [2, 4, 5],
                       "progress must be driven by files examined even when none match")
        XCTAssertEqual(matches.value, [0, 0, 0], "empty progress batches invent no library rows")
    }

    func testTheDatalessIOPolicyIsRestoredAfterAScan() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("f.pdf", tags: ["Read"], in: root)

        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = CorpusWalker.scan(root: root)
        let after = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)

        XCTAssertEqual(after, before, "leaving the policy OFF would silently change unrelated work")
    }

    func testTheDatalessPolicyIsActuallyDisabledInsideTheScope() {
        let inside = CorpusWalker.withDatalessMaterializationDisabled {
            getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        }
        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
                       "without this the enumerator stalls ~0.5 s per call on a cloud volume, then lies")
    }

    // MARK: - 6. W26.idx fingerprint-only revalidation

    func testFingerprintScanReturnsEveryRegularFileWithoutReadingTagMembership() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("tagged.pdf", tags: ["Unread", "Subject/Z"], in: root)
        try makeFile("untagged.pdf", in: root)
        let awkward = "Nested/report\u{2014}final\u{00A0}copy.pdf"
        try makeFile(awkward, tags: ["Purple"], in: root)
        try makeFile(".hidden.pdf", tags: ["Read"], in: root)

        let result = CorpusWalker.scanFingerprints(root: root)
        let rootComponents = normalized(root)
        let paths = result.entries.map { item -> String in
            normalized(item.url).dropFirst(rootComponents.count).joined(separator: "/")
        }.sorted()

        XCTAssertEqual(paths, [awkward, "tagged.pdf", "untagged.pdf"].sorted())
        XCTAssertEqual(result.filesSeen, 3)
        XCTAssertTrue(result.isClean)
        XCTAssertTrue(result.entries.allSatisfy { $0.fingerprint.size > 0 })
        XCTAssertTrue(result.entries.allSatisfy { !$0.fingerprint.isDataless })
    }

    func testOrdinaryScanCarriesTheSameFreshFingerprintUsedByTheIndex() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try makeFile("tracked.pdf", tags: ["Unread"], in: root)

        let ordinary = try XCTUnwrap(CorpusWalker.scan(root: root).entries.first)
        let cheap = try XCTUnwrap(CorpusWalker.scanFingerprints(root: root).entries.first)

        XCTAssertEqual(normalized(ordinary.url), normalized(url),
                       "the temp directory may be spelled /var or /private/var")
        XCTAssertEqual(ordinary.fingerprint, cheap.fingerprint,
                       "the persisted tuple must describe the same fresh stat as a full tag read")
    }

    func testTagOnlyChangeInvalidatesFingerprintThroughCtimeNotMtime() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try makeFile("changed.pdf", tags: ["Unread"], in: root)
        let before = try XCTUnwrap(CorpusWalker.scanFingerprints(root: root).entries.first?.fingerprint)

        var after = before
        for i in 0..<20 where after.ctime == before.ctime {
            try (fresh(url.path) as NSURL).setResourceValue(["Read", "Subject/\(i)"],
                                                            forKey: .tagNamesKey)
            after = try XCTUnwrap(CorpusWalker.scanFingerprints(root: root).entries.first?.fingerprint)
        }

        XCTAssertEqual(after.mtime, before.mtime,
                       "Finder tags are metadata and must not masquerade as a content change")
        XCTAssertNotEqual(after.ctime, before.ctime,
                          "ctime is load-bearing: otherwise a closed-app tag edit reuses stale tags")
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.inode, before.inode)
    }

    func testCancelledFingerprintScanCannotAuthoriseAbsence() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<20 { try makeFile(String(format: "f%02d.pdf", i), in: root) }
        let polls = UncheckedBox(0)

        let result = CorpusWalker.scanFingerprints(root: root, isCancelled: {
            polls.value += 1
            return polls.value > 5
        })

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.completed)
        XCTAssertFalse(result.isClean)
        XCTAssertLessThan(result.entries.count, 20)
    }

    // MARK: - 7. Off-main execution

    func testScanDetachedProducesTheSameResultOffTheCallingThread() async throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("a.pdf", tags: ["Read"], in: root)
        try makeFile("Nested/b.pdf", tags: ["Unread"], in: root)
        try makeFile("c.pdf", in: root)

        let result = await CorpusWalker.scanDetached(root: root)

        XCTAssertEqual(relativePaths(result, root: root), ["Nested/b.pdf", "a.pdf"].sorted())
        XCTAssertTrue(result.isClean)
    }

    func testScanOnDedicatedThreadRunsOffTheCallersThread() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile("a.pdf", tags: ["Read"], in: root)

        let done = expectation(description: "walk finished")
        let threadName = UncheckedBox<String?>(nil)
        let onMain = UncheckedBox(true)
        let count = UncheckedBox(0)
        CorpusWalker.scanOnDedicatedThread(root: root, completion: { result in
            threadName.value = Thread.current.name
            onMain.value = Thread.isMainThread
            count.value = result.entries.count
            done.fulfill()
        })
        wait(for: [done], timeout: 10)

        XCTAssertEqual(count.value, 1)
        XCTAssertFalse(onMain.value)
        XCTAssertEqual(threadName.value, "ArchiveCore.CorpusWalker",
                       "a ~10 s blocking walk must run on our own thread, not a cooperative-pool one")
    }

    // MARK: - 8. Symlinks are classified by their target

    func testASymlinkIsClassifiedByItsTargetJustAsTheWritePathWouldBe() throws {
        let root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Target lives OUTSIDE the walked root, so only the link is enumerated.
        let target = try makeFile("outside/target.pdf", tags: ["Unread"])
        let link = root.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = CorpusWalker.scan(root: root)

        // `resourceValues`/`TagReading` report the TARGET's tags through a link, so the walk must too —
        // otherwise discovery and the write path would disagree about the same entry (the symlink half
        // of the W26.deny correction).
        // Compared by name, not via `relativePaths`: the entry URL *is* the link, so resolving its
        // symlinks lands on the target outside the root — which is the point of the test.
        XCTAssertEqual(result.entries.map { $0.url.lastPathComponent }, ["link.pdf"])
        XCTAssertEqual(result.entries.first?.tagNames, ["Unread"])
        XCTAssertTrue(result.isClean)
    }
}

/// Minimal mutable box for values a synchronous callback writes from inside the walk. Not a
/// concurrency primitive — the walker invokes `onBatch`/`isCancelled` synchronously on one thread.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
