import XCTest
import ArchiveCore

/// W26.walk2 — the §7a.11 gate: *"the enumerator ended"* is not *"the walk was authoritative."*
///
/// A root that is swapped, ejected or sealed mid-pass can leave the enumerator finishing normally
/// with a short list and zero errors. These cases pin that the fingerprint separates that from a
/// genuine complete pass, since everything downstream (the empty-state copy, content-index pruning)
/// keys off the difference.
///
/// Throwaway temp fixtures only — never the corpus (Reader Core Directive).
final class CorpusRootFingerprintTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusRootFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let tempDir else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The stable case

    func testTheSameDirectoryFingerprintsIdenticallyAcrossCalls() throws {
        let a = try XCTUnwrap(CorpusRootFingerprint.capture(tempDir))
        // Content churn is not identity churn: adding a file must not change the answer, or every
        // pass over a live corpus would look like a root swap.
        try Data("x".utf8).write(to: tempDir.appendingPathComponent("new.pdf"))
        let b = try XCTUnwrap(CorpusRootFingerprint.capture(tempDir))

        XCTAssertEqual(a, b)
        XCTAssertTrue(CorpusRootFingerprint.rootHeldStill(before: a, after: b))
    }

    /// A **fresh `URL` per capture**, because `URL.resourceValues` caches on the backing `NSURL` and a
    /// reused value is how the wave's first measurement came to assert nothing (plan §4a.1). This type
    /// uses raw syscalls precisely so it cannot cache — asserted here rather than assumed.
    func testCaptureIsNotServedFromAReusedURLsCache() throws {
        let path = tempDir.path
        let before = try XCTUnwrap(CorpusRootFingerprint.capture(URL(fileURLWithPath: path)))

        // Replace the directory with a DIFFERENT directory at the same path.
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        let sameURLObject = tempDir!   // the very object used for the first capture
        let after = try XCTUnwrap(CorpusRootFingerprint.capture(sameURLObject))

        XCTAssertNotEqual(before.inode, after.inode,
                          "a different directory at the same path must not fingerprint the same")
        XCTAssertFalse(CorpusRootFingerprint.rootHeldStill(before: before, after: after))
    }

    // MARK: - Every way of saying "not the same readable root"

    func testAVanishedRootCapturesNil() throws {
        let before = CorpusRootFingerprint.capture(tempDir)
        try FileManager.default.removeItem(at: tempDir)

        XCTAssertNil(CorpusRootFingerprint.capture(tempDir))
        XCTAssertFalse(CorpusRootFingerprint.rootHeldStill(before: before,
                                                          after: CorpusRootFingerprint.capture(tempDir)),
                       "a pass whose root disappeared under it is not authoritative")
    }

    func testAnUnreadableRootCapturesNil() throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tempDir.path)

        XCTAssertNil(CorpusRootFingerprint.capture(tempDir),
                     "a root that cannot be read cannot vouch for the pass that just walked it")
    }

    func testAFileIsNotARoot() throws {
        let file = tempDir.appendingPathComponent("not-a-directory.pdf")
        try Data("x".utf8).write(to: file)

        XCTAssertNil(CorpusRootFingerprint.capture(file))
    }

    func testEitherCaptureMissingMeansTheRootDidNotHoldStill() {
        let some = CorpusRootFingerprint(filesystemID: 1, deviceID: 2, inode: 3)

        XCTAssertFalse(CorpusRootFingerprint.rootHeldStill(before: nil, after: some))
        XCTAssertFalse(CorpusRootFingerprint.rootHeldStill(before: some, after: nil))
        XCTAssertFalse(CorpusRootFingerprint.rootHeldStill(before: nil, after: nil))
        XCTAssertTrue(CorpusRootFingerprint.rootHeldStill(before: some, after: some))
    }

    /// Equality must involve every field — a fingerprint that ignored one would silently accept a
    /// swap that changed only that field.
    func testEveryFieldParticipatesInEquality() {
        let base = CorpusRootFingerprint(filesystemID: 10, deviceID: 20, inode: 30)

        XCTAssertNotEqual(base, CorpusRootFingerprint(filesystemID: 11, deviceID: 20, inode: 30))
        XCTAssertNotEqual(base, CorpusRootFingerprint(filesystemID: 10, deviceID: 21, inode: 30))
        XCTAssertNotEqual(base, CorpusRootFingerprint(filesystemID: 10, deviceID: 20, inode: 31))
    }
}
