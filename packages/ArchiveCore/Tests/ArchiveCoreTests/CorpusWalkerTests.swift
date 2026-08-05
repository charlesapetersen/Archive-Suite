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
        XCTAssertTrue(result.rootUnreadable || !result.directoryErrors.isEmpty,
                      "either the enumerator refused outright or it reported the failure — not neither")
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

    // MARK: - 6. Off-main execution

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

    // MARK: - 7. Symlinks are classified by their target

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
