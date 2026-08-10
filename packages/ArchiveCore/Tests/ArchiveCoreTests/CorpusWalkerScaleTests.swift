import XCTest
import ArchiveCore

/// W26.verify — the scale lane for the Spotlight-free walk, at 100k+ files.
///
/// **Env-gated, and skips by default.** Nothing here runs in an ordinary `swift test`: a 150k-file walk
/// takes seconds and needs a corpus that does not exist on a fresh checkout. `ops/scale/run-scale-verify.sh`
/// builds that corpus with `ops/scale/scale-corpus.swift`, exports `ARCHIVE_SCALE_ROOT`, and runs this file
/// by name. Absent the variable every case `XCTSkip`s, so the normal suite is unaffected.
///
/// **Why the measurement lives here rather than in the app.** `execution-plans/despotlight.md` §7a.7:
/// pointing the Reader at a folder WRITES `.archive-suite-root.json`, so a scale number taken by driving
/// the app cannot also carry a no-write assertion. This calls the walker directly, in a process that never
/// opens the app's stores — and the no-write assertion itself is taken by a *third* program, before and
/// after, because a subject cannot prove its own innocence (`scale-corpus manifest` + `compare`).
///
/// **Never the real corpus.** The harness only ever builds a tree whose leaf is named `scale-corpus*`, and
/// `scale-corpus.swift` hard-refuses any path mentioning the owner's archive. Reader Core Directive.
final class CorpusWalkerScaleTests: XCTestCase {

    /// The scratch root under test, or a skip when the harness did not set one.
    private func scaleRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVE_SCALE_ROOT"], !path.isEmpty else {
            throw XCTSkip("ARCHIVE_SCALE_ROOT unset — run ops/scale/run-scale-verify.sh")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ARCHIVE_SCALE_ROOT=\(path) does not exist")
        }
        // Belt and braces: this process must not be pointed at anything but a scratch tree, even if the
        // harness were edited. The name is the same gate `scale-corpus.swift` enforces on the write side.
        guard url.lastPathComponent.hasPrefix("scale-corpus") else {
            throw XCTSkip("ARCHIVE_SCALE_ROOT is not a scale-corpus* tree, refusing to walk it: \(path)")
        }
        return url
    }

    /// The file count the lane demands — 100k by default, because that is what the item requires. The
    /// harness lowers it only for its own self-test (`run-scale-verify.sh --self-test`), which proves
    /// these three cases can FAIL by running them against a deliberately small and then mutated tree;
    /// a gate nobody has watched fail is the kind of green this wave keeps finding.
    private var requiredFileCount: Int {
        Int(ProcessInfo.processInfo.environment["ARCHIVE_SCALE_MIN_FILES"] ?? "") ?? 100_000
    }

    // MARK: - The three numbers

    /// Cold-ish full discovery, the number the wave's ~12 s baseline is about — and, on the same tree in
    /// the same process, the pre-W26 discovery path for an apples-to-apples ratio. The 10.15 s / 12.4 s
    /// figures in the plan were measured on the real corpus; comparing a synthetic tree against them
    /// would compare two different trees, so the baseline is re-measured here rather than assumed.
    func testFullWalkAtScaleAndAgainstTheOldPathOnTheSameTree() throws {
        let root = try scaleRoot()

        // (1) The shipped walker: enumerate + stat + trustworthy tag read + membership predicate.
        let walkStart = Date()
        let result = CorpusWalker.scan(root: root)
        let walkSeconds = Date().timeIntervalSince(walkStart)

        XCTAssertFalse(result.rootUnreadable, "the scale root must be enumerable")
        XCTAssertFalse(result.cancelled, "nothing cancelled this pass")
        XCTAssertTrue(result.completed, "a completed pass is what authorises any later prune")
        XCTAssertGreaterThanOrEqual(result.filesSeen, requiredFileCount,
                                    "the lane requires \(requiredFileCount)+ files; got \(result.filesSeen)")
        XCTAssertGreaterThan(result.entries.count, 0, "the corpus is tagged; discovery cannot be empty")

        // The hostile tree is deliberately present, so this pass must NOT be clean — and must say why.
        XCTAssertFalse(result.isClean,
                       "the planted unreadable file and sealed directory must make this pass unclean")
        XCTAssertFalse(result.unreadable.isEmpty, "the tagged 0o000 file must be reported, not coerced")
        XCTAssertFalse(result.directoryErrors.isEmpty, "the sealed directory must be reported")

        // (2) The path this wave replaced, on the same tree: FileManager.enumerator + resourceValues,
        // with no error handler and no stat — i.e. what `ArchiveLibrary` used to do per file.
        let baselineStart = Date()
        var baselineSeen = 0, baselineTracked = 0
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .tagNamesKey, .labelNumberKey],
            options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .tagNamesKey, .labelNumberKey]),
                      values.isRegularFile == true else { continue }
                baselineSeen += 1
                if CorpusWalker.tracksReadState(values.tagNames ?? []) { baselineTracked += 1 }
            }
        }
        let baselineSeconds = Date().timeIntervalSince(baselineStart)

        let perFileMicroseconds = walkSeconds / Double(max(result.filesSeen, 1)) * 1_000_000
        let footprint = Double(currentFootprintBytes()) / 1_048_576
        print("""
        SCALE walk root=\(root.path)
          filesSeen=\(result.filesSeen) tracked=\(result.entries.count) \
        unreadable=\(result.unreadable.count) dirErrors=\(result.directoryErrors.count) \
        vanished=\(result.vanishedMidScan)
          CorpusWalker.scan      \(String(format: "%.2f", walkSeconds)) s  \
        (\(String(format: "%.1f", perFileMicroseconds)) us/file)
          old resourceValues path \(String(format: "%.2f", baselineSeconds)) s  \
        (seen=\(baselineSeen) tracked=\(baselineTracked))
          footprint after walk \(String(format: "%.1f", footprint)) MiB
        """)

        // Both paths must agree on membership on the readable part of the tree. The walker finds MORE
        // than the old path can only where the old path silently coerced an unreadable tag read to "no
        // tags" — which is precisely §4a.1, and the planted denied file is exactly one such case.
        XCTAssertEqual(result.entries.count, baselineTracked,
                       "the two paths must agree on the readable tree's membership")

        // A ceiling, not a benchmark: the assertion is that a full walk is affordable, and the plan's
        // arithmetic (§2, conclusion 1) only needs it to be seconds rather than minutes.
        XCTAssertLessThan(walkSeconds, 120, "a full walk at this scale must not take minutes")
    }

    /// Warm-start's first phase: the cheap `stat`-only revalidation pass, which is the number that decides
    /// whether a warm launch can confirm 150k rows quickly enough to be worth caching them at all.
    func testFingerprintOnlyRevalidationPassAtScale() throws {
        let root = try scaleRoot()
        let start = Date()
        let result = CorpusWalker.scanFingerprints(root: root)
        let seconds = Date().timeIntervalSince(start)

        XCTAssertFalse(result.rootUnreadable)
        XCTAssertGreaterThanOrEqual(result.filesSeen, requiredFileCount)
        // `filesSeen` counts regular files whose `stat` succeeded and `vanishedMidScan` is a disjoint
        // branch, so the fingerprint pass keeps a strict one-row-per-file-seen invariant. Asserted
        // because a silent drop here is the §7a.3 shape: a row missing from a revalidation pass reads
        // as "this file is gone".
        XCTAssertEqual(result.entries.count, result.filesSeen,
                       "every regular file counted must carry a fingerprint row")
        print("""
        SCALE fingerprints \(String(format: "%.2f", seconds)) s \
        (\(String(format: "%.1f", seconds / Double(max(result.filesSeen, 1)) * 1_000_000)) us/file) \
        rows=\(result.entries.count) unreadable=\(result.unreadable.count)
        """)
        XCTAssertLessThan(seconds, 60, "the stat-only pass is meant to be the cheap phase")
    }

    /// Cancel mid-walk. Two things must hold, and the second is the one with teeth: a cancelled pass is
    /// **not clean and not completed**, because `.settled`/prune authority is derived from exactly that —
    /// §7a.11 of the plan. A cancelled walk that looked complete would authorise pruning every row it
    /// had not reached yet.
    func testCancellingMidWalkYieldsAnUnusableResultRatherThanAShortOne() throws {
        let root = try scaleRoot()
        // `isCancelled` is polled once per entry, so counting inside it is the entry count.
        let seen = Counter()
        let cancelAfter = max(requiredFileCount / 20, 50)
        let result = CorpusWalker.scan(root: root, isCancelled: { seen.tickAndExceeds(cancelAfter) })

        XCTAssertTrue(result.cancelled, "the cancel predicate must be honoured")
        XCTAssertFalse(result.completed, "a cancelled pass is not a completed one")
        XCTAssertFalse(result.isClean, "and therefore can never authorise treating a file as gone")
        XCTAssertLessThan(result.filesSeen, requiredFileCount,
                          "cancellation must actually stop the walk short")
        print("SCALE cancel stopped after filesSeen=\(result.filesSeen) entries=\(result.entries.count)")
    }

    /// A cancel predicate that counts entries, without an `inout` capture the walker's `@Sendable`
    /// closure cannot take.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func tickAndExceeds(_ limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count > limit
        }
    }

    /// Physical footprint of this process right now, in bytes.
    private func currentFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
