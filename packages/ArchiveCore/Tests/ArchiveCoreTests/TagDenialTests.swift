import XCTest
@testable import ArchiveCore

/// W26.deny — a file whose tags cannot be READ must never be reported as a file with NO tags.
///
/// `URL.resourceValues(forKeys: [.tagNamesKey])` **succeeds** and yields `nil` for a file whose
/// extended attributes are unreadable while its directory is traversable. Both this repo's read path
/// (`TagReading.read`) and its single audited write path (`CoordinatedTagWriter.write`) used to coerce
/// that `nil` to `[]`, which turned `["Unread","Subj","P9"]` into `["Read"]` on disk — a direct
/// violation of the Core Directive. These tests are the reproduction, inverted.
///
/// ⚠️ Every probe builds a **fresh `URL` from the path string**. `URL.resourceValues` caches on the
/// backing `NSURL`, so a test that reuses a `URL` value passes while asserting nothing — that trap
/// produced one wrong measurement in the execution plan before it produced a correct one.
///
/// Throwaway temp files only; never the corpus.
final class TagDenialTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        // chmod/ACL denials do not apply to root, so every denial case here would silently pass.
        try XCTSkipIf(getuid() == 0, "denial cases are meaningless when running as root")
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveCoreDenialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let tempDir else { return }
        // Restore access before deleting: a sealed directory or a deny-ACL blocks removal itself.
        shell(["chmod", "-R", "-N", tempDir.path])          // strip every ACL
        shell(["chmod", "-R", "u+rwX", tempDir.path])       // restore owner access
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    /// A fresh `URL` value for `path`. Never reuse one across a state change (see the class note).
    private func fresh(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @discardableResult
    private func shell(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Creates a file carrying `tags` and returns its PATH (not a URL — see the caching note).
    private func makeFile(_ name: String, tags: [String], in dir: URL? = nil) throws -> String {
        let url = (dir ?? tempDir).appendingPathComponent(name)
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty {
            try (fresh(url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        return url.path
    }

    private func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func denyACL(_ path: String, _ perms: String) {
        XCTAssertEqual(shell(["chmod", "+a", "user:\(NSUserName()) deny \(perms)", path]), 0,
                       "could not install the deny ACL this test depends on")
    }

    /// Tag names straight from the filesystem, bypassing `TagReading` entirely — so an assertion about
    /// what survived on disk cannot be satisfied by the very code under test.
    private func tagsOnDisk(_ path: String) -> [String] {
        (try? fresh(path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    private func assertFailure(_ result: TagReadResult, _ message: String) {
        switch result {
        case .failure: break
        case let .success(names, _):
            XCTFail("\(message) — got .success(\(names)); an unreadable file was reported as readable")
        }
    }

    /// A *confirmed* "this file has no tags" — as distinct from `.failure`. The label is compared
    /// through `normalizedLabel` because macOS reports an unlabelled file as `0`, not `nil`.
    private func assertConfirmedEmpty(_ result: TagReadResult, _ message: String,
                                      line: UInt = #line) {
        switch result {
        case let .success(names, label):
            XCTAssertEqual(names, [], message, line: line)
            XCTAssertEqual(normalizedLabel(label), 0, message, line: line)
        case let .failure(why):
            XCTFail("\(message) — got .failure(\(why)); a readable untagged file was reported unreadable",
                    line: line)
        }
    }

    // MARK: - TagReading — the four denial shapes must all report .failure

    /// The leak itself: the read does NOT throw here, so the `catch` never fires.
    func testUnreadableFileWithTraversableParentIsAFailureNotEmpty() throws {
        let path = try makeFile("write-only.pdf", tags: ["Unread", "Subj", "P9"])
        try chmod(path, 0o200)
        assertFailure(TagReading.read(fresh(path)), "mode 0o200 (write-only) file")
    }

    func testFullyDeniedFileIsAFailureNotEmpty() throws {
        let path = try makeFile("no-access.pdf", tags: ["Unread", "Subj", "P9"])
        try chmod(path, 0o000)
        assertFailure(TagReading.read(fresh(path)), "mode 0o000 file")
    }

    /// The narrowest shape, and the one `access(R_OK)` cannot see: file data stays readable.
    func testACLDenyingOnlyReadExtAttrIsAFailureNotEmpty() throws {
        let path = try makeFile("acl-xattr.pdf", tags: ["Unread", "Subj", "P9"])
        denyACL(path, "readextattr")
        XCTAssertEqual(access(path, R_OK), 0, "precondition: file DATA is still readable, only xattrs are denied")
        assertFailure(TagReading.read(fresh(path)), "ACL denying readextattr")
    }

    /// Already honest before this fix (`resourceValues` throws 257) — pinned so it stays that way.
    func testACLDenyingWideReadIsAFailure() throws {
        let path = try makeFile("acl-wide.pdf", tags: ["Unread", "Subj", "P9"])
        denyACL(path, "read,readattr,readextattr")
        assertFailure(TagReading.read(fresh(path)), "ACL denying read,readattr,readextattr")
    }

    /// Also already honest (throws 257) — pinned for the same reason.
    func testSealedParentDirectoryIsAFailure() throws {
        let dir = tempDir.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = try makeFile("inside.pdf", tags: ["Unread", "Subj"], in: dir)
        try chmod(dir.path, 0o000)
        assertFailure(TagReading.read(fresh(path)), "file inside a sealed directory")
    }

    /// A tag attribute that is present and readable but holds something that is not a tag array is
    /// "I don't know", not "no tags" — otherwise the next write silently overwrites it.
    func testUndecodableTagAttributeIsAFailure() throws {
        let path = try makeFile("corrupt-xattr.pdf", tags: [])
        let junk = Data("this is not a property list".utf8)
        let rc = junk.withUnsafeBytes { setxattr(path, finderTagsXattrName, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(rc, 0, "precondition: could not plant the corrupt attribute")
        XCTAssertNil(try fresh(path).resourceValues(forKeys: [.tagNamesKey]).tagNames,
                     "precondition: macOS reports nil tagNames for a corrupt attribute")
        assertFailure(TagReading.read(fresh(path)), "corrupt tag attribute")
    }

    /// An attribute holding a NON-empty array that macOS still reported as no tags is something we can
    /// see but cannot interpret — "I don't know", not "there is nothing here". (This is also the shape
    /// of a file that becomes readable between the `resourceValues` call and the probe.)
    func testNonEmptyArrayMacOSDidNotReportAsTagsIsAFailure() throws {
        let path = try makeFile("odd-array.pdf", tags: [])
        let plist = try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .binary, options: 0)
        let rc = plist.withUnsafeBytes { setxattr(path, finderTagsXattrName, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(rc, 0, "precondition: could not plant the attribute")
        XCTAssertNil(try fresh(path).resourceValues(forKeys: [.tagNamesKey]).tagNames,
                     "precondition: macOS reports nil tagNames for a non-string array")
        assertFailure(TagReading.read(fresh(path)), "an attribute holding a non-tag array")
    }

    /// A symlink resolves to its target's tags, so the denial probe must follow it too. With
    /// `XATTR_NOFOLLOW` this file's answer is ENOATTR — "confirmed no tags" — about a denied target.
    func testSymlinkToDeniedTargetIsAFailure() throws {
        let target = try makeFile("denied-target.pdf", tags: ["Unread", "Subj", "P9"])
        let link = tempDir.appendingPathComponent("link.pdf").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        try chmod(target, 0o200)
        assertFailure(TagReading.read(fresh(link)), "symlink to an unreadable target")
    }

    // MARK: - …and the honest cases must stay honest (this fix must not invent failures)

    func testUntaggedFileIsConfirmedEmpty() throws {
        let path = try makeFile("untagged.pdf", tags: [])
        assertConfirmedEmpty(TagReading.read(fresh(path)), "an untagged file")
    }

    /// The corpus shape that makes over-strictness dangerous: removing a file's tags leaves a 42-byte
    /// empty-array attribute behind, and macOS reports `tagNames == nil` for it. 51 of the owner's
    /// 123,302 files look like this (measured 2026-08-05, read-only). They are untagged, not unreadable.
    func testEmptyArrayResidueIsConfirmedEmpty() throws {
        let path = try makeFile("emptied.pdf", tags: ["Temp"])
        try (fresh(path) as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
        XCTAssertNil(try fresh(path).resourceValues(forKeys: [.tagNamesKey]).tagNames,
                     "precondition: this is the nil-tagNames-with-attribute-present shape")
        XCTAssertGreaterThan(getxattr(path, finderTagsXattrName, nil, 0, 0, 0), 0,
                             "precondition: the attribute is still on disk")
        assertConfirmedEmpty(TagReading.read(fresh(path)), "a file whose tags were removed")
    }

    func testTaggedFileStillReadsItsTags() throws {
        let path = try makeFile("tagged.pdf", tags: ["Unread", "Subj", "P9"])
        XCTAssertEqual(TagReading.read(fresh(path)).tagNames, ["Unread", "Subj", "P9"])
    }

    /// A traverse-only parent (0o111) reads fine — the denial is per-file, not per-directory.
    func testTraverseOnlyParentStillReads() throws {
        let dir = tempDir.appendingPathComponent("traverse", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = try makeFile("inside.pdf", tags: ["Unread", "Subj"], in: dir)
        try chmod(dir.path, 0o111)
        XCTAssertEqual(TagReading.read(fresh(path)).tagNames, ["Unread", "Subj"])
    }

    /// Directories carry no tag attribute; a walker must not see every folder as unreadable.
    func testDirectoryIsConfirmedEmpty() throws {
        assertConfirmedEmpty(TagReading.read(fresh(tempDir.path)), "a plain directory")
    }

    // MARK: - CoordinatedTagWriter — the reproduction, inverted

    /// The exact destruction, as a test: mode 0o200 read no-throw with `before == []`, the write
    /// SUCCEEDED, and `["Unread","Subj","P9"]` became `["Read"]` on disk. It must now abort untouched.
    private func assertWriteAbortsAndPreservesTags(_ path: String, _ what: String) {
        let original = ["Unread", "Subj", "P9"]
        var thrown: Error?
        XCTAssertThrowsError(
            try CoordinatedTagWriter.write(fresh(path)) { current, label in
                // The Reader's real edit shape: swap Unread for Read. Against a `before` of [] this
                // is what wrote ["Read"] over three tags.
                (current.map { $0 == "Unread" ? "Read" : $0 }, label)
            },
            "\(what): the write must refuse when the current tags cannot be read"
        ) { thrown = $0 }

        guard case .unreadable = thrown as? TagWriteError else {
            return XCTFail("\(what): expected TagWriteError.unreadable, got \(String(describing: thrown))")
        }
        // Restore access and confirm the tags are byte-identical — asserted straight from the
        // filesystem, not through the code under test.
        shell(["chmod", "-N", path])
        try? chmod(path, 0o644)
        XCTAssertEqual(tagsOnDisk(path), original, "\(what): tags must be untouched after the refusal")
    }

    func testWriteAbortsAndPreservesTagsWhenFileIsWriteOnly() throws {
        let path = try makeFile("victim-0200.pdf", tags: ["Unread", "Subj", "P9"])
        try chmod(path, 0o200)
        assertWriteAbortsAndPreservesTags(path, "mode 0o200")
    }

    func testWriteAbortsAndPreservesTagsWhenACLDeniesReadExtAttr() throws {
        let path = try makeFile("victim-acl.pdf", tags: ["Unread", "Subj", "P9"])
        denyACL(path, "readextattr")
        assertWriteAbortsAndPreservesTags(path, "ACL denying readextattr")
    }

    /// The 0o000 row: the write already failed here (-5000), so the tags survived by accident — but
    /// the reported `before`/`inverse` was `[]`, so an UNDO of it would have been corrupt. Aborting
    /// means there is no result to be wrong about.
    func testWriteAbortsBeforeProducingACorruptInverse() throws {
        let path = try makeFile("victim-0000.pdf", tags: ["Unread", "Subj", "P9"])
        try chmod(path, 0o000)

        var result: TagWriteResult?
        XCTAssertThrowsError(
            result = try CoordinatedTagWriter.write(fresh(path)) { current, label in
                (current + ["Read"], label)
            }
        ) { error in
            guard case .unreadable = error as? TagWriteError else {
                return XCTFail("expected TagWriteError.unreadable, got \(error)")
            }
        }
        XCTAssertNil(result, "no TagWriteResult — and so no `before: []` inverse to undo into")
        try chmod(path, 0o644)
        XCTAssertEqual(tagsOnDisk(path), ["Unread", "Subj", "P9"])
    }

    /// The transform must never even be consulted: it is what computes the destructive delta.
    func testTransformIsNotCalledWhenTagsAreUnreadable() throws {
        let path = try makeFile("victim-transform.pdf", tags: ["Unread", "Subj", "P9"])
        try chmod(path, 0o200)
        var transformCalls = 0
        XCTAssertThrowsError(try CoordinatedTagWriter.write(fresh(path)) { current, label in
            transformCalls += 1
            return (current + ["Read"], label)
        })
        XCTAssertEqual(transformCalls, 0, "the transform saw a fabricated empty `before`")
    }

    /// A readable file must still be writable — this fix must not make the writer refuse ordinary work.
    func testOrdinaryWriteStillSucceeds() throws {
        let path = try makeFile("ordinary.pdf", tags: ["Unread", "Subj", "P9"])
        let result = try CoordinatedTagWriter.write(fresh(path)) { current, label in
            (current.map { $0 == "Unread" ? "Read" : $0 }, label)
        }
        XCTAssertTrue(multisetEqual(result.before, ["Unread", "Subj", "P9"]))
        XCTAssertTrue(multisetEqual(tagsOnDisk(path), ["Read", "Subj", "P9"]))
    }

    /// And a file with genuinely no tags must still be taggable — the empty `before` that is REAL.
    func testWriteToAConfirmedUntaggedFileStillSucceeds() throws {
        let path = try makeFile("blank.pdf", tags: [])
        let result = try CoordinatedTagWriter.write(fresh(path)) { current, label in
            (current + ["Unread"], label)
        }
        XCTAssertEqual(result.before, [])
        XCTAssertEqual(tagsOnDisk(path), ["Unread"])
    }

    // MARK: - The probe itself

    func testInspectDistinguishesAbsentFromUnreadable() throws {
        let untagged = try makeFile("probe-untagged.pdf", tags: [])
        XCTAssertEqual(TagXattr.inspect(fresh(untagged)), .absent)

        let emptied = try makeFile("probe-emptied.pdf", tags: ["Temp"])
        try (fresh(emptied) as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
        XCTAssertEqual(TagXattr.inspect(fresh(emptied)), .readableEmpty)

        let denied = try makeFile("probe-denied.pdf", tags: ["Unread"])
        try chmod(denied, 0o200)
        guard case .unreadable = TagXattr.inspect(fresh(denied)) else {
            return XCTFail("a mode-0o200 file must probe as .unreadable")
        }
    }
}
