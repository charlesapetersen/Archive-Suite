import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.verify — the warm-start half of the scale lane, at 150k rows.
///
/// `W26.idx` shipped its per-item gate but never ran a scale lane at all, so it owes this item three
/// numbers and one semantic guard, none of which any existing test covers:
///
///   * **cold** — full walk, then persist every row (the one-time cost);
///   * **warm start** — reopen the cache and publish rows, which is the number the whole item exists to
///     move (Spotlight's answer for the same corpus was zero rows, in ~0 s);
///   * **steady revalidation** — a fingerprint pass with ~0 changed rows, i.e. what a normal launch pays;
///   * and the guard: **a cancelled revalidation must leave `asOf == nil` and prune nothing.** A cancelled
///     pass that looked settled would authorise deleting every row it had not reached.
///
/// **Env-gated and skips by default** (`ARCHIVE_SCALE_ROOT`), like the ArchiveCore half — a 150k-row
/// build is minutes of work and the corpus does not exist on a fresh checkout. Driven by
/// `ops/scale/run-scale-verify.sh`, which builds the scratch corpus and passes the root through
/// `TEST_RUNNER_ARCHIVE_SCALE_ROOT`.
///
/// **This drives `LibraryScan` + `LibraryIndex` directly, never the app's own stores.** It is the same
/// sequence `ArchiveLibrary` runs, minus the UI — and deliberately minus `RootFolderStore`, so nothing
/// here can touch the owner's granted root or write a root marker into the tree under measurement
/// (`execution-plans/despotlight.md` §7a.7; the incident of 2026-07-11).
final class LibraryIndexScaleTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexScaleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Where the harness leaves the scratch-corpus path for this lane.
    ///
    /// **A file, not an environment variable, and that is a measured decision.** Passing it as
    /// `TEST_RUNNER_ARCHIVE_SCALE_ROOT=…` was tried first: the build tool accepts it and echoes it back
    /// in the build settings, but the value does **not** reach an app-HOSTED unit test's process — every
    /// case here skipped with "unset" while the run still reported TEST SUCCEEDED. (The harness caught
    /// that, because it fails on a SKIPPED lane instead of trusting the green.)
    ///
    /// `NSUserName()` rather than `NSHomeDirectory()`/`$HOME`: inside the sandbox both resolve to the app
    /// CONTAINER, which is exactly the trap that made every Wave-7 fixture UITest skip for a week — the
    /// test computed a path the runner could see and the writer could not. The Debug entitlements carry a
    /// `/Users/` temporary exception, so this absolute path is readable; Release has no such entitlement,
    /// and this file is test-only.
    private var handshakeFile: String {
        "/Users/\(NSUserName())/Library/Caches/ArchiveSuiteScale/scale-lane-root.txt"
    }

    private func scaleRoot() throws -> URL {
        var path = ProcessInfo.processInfo.environment["ARCHIVE_SCALE_ROOT"] ?? ""
        if path.isEmpty, let handshake = try? String(contentsOfFile: handshakeFile, encoding: .utf8) {
            path = handshake.split(separator: "\n").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        guard !path.isEmpty else {
            throw XCTSkip("no scale root — run ops/scale/run-scale-verify.sh (handshake: \(handshakeFile))")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.lastPathComponent.hasPrefix("scale-corpus") else {
            throw XCTSkip("ARCHIVE_SCALE_ROOT is not a scale-corpus* tree, refusing to walk it: \(path)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ARCHIVE_SCALE_ROOT=\(path) does not exist")
        }
        return url
    }

    /// The file count the lane demands — 100k by default, lowered only by the harness's own self-test.
    /// Line 2 of the handshake, for the same reason the root is line 1 (see `handshakeFile`).
    private var requiredFileCount: Int {
        if let fromEnv = Int(ProcessInfo.processInfo.environment["ARCHIVE_SCALE_MIN_FILES"] ?? "") {
            return fromEnv
        }
        let lines = (try? String(contentsOfFile: handshakeFile, encoding: .utf8))?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if lines.count > 1, let fromFile = Int(lines[1]) { return fromFile }
        return 100_000
    }

    /// Physical footprint of this process, in bytes — what macOS bills against the jetsam limit, so the
    /// honest memory number. `resident_size` under-reports compressed pages.
    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private func fileSizeBytes(_ url: URL) -> Int64 {
        // WAL and shm count: a cache that keeps its size in a 200 MB sidecar has not been frugal.
        ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let path = url.path + suffix
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - The three timings, plus the size and memory ceilings

    func testColdBuildWarmStartAndSteadyRevalidationAt150kRows() async throws {
        let root = try scaleRoot()
        let indexURL = scratch.appendingPathComponent("library-index.sqlite3")
        let identity = LibraryIndexRoot(path: root.path, markerGUID: UUID())
        let baselineFootprint = footprintBytes()

        // ── COLD: the full walk, then persistence. What a first launch pays, once.
        let coldWalkStart = Date()
        let cold = LibraryScan.pass(root: root)
        let coldWalkSeconds = Date().timeIntervalSince(coldWalkStart)
        XCTAssertGreaterThanOrEqual(cold.result.filesSeen, requiredFileCount,
                                    "the lane requires \(requiredFileCount)+ files")
        XCTAssertFalse(cold.result.rootUnreadable)
        XCTAssertFalse(cold.result.cancelled)

        let coldIndex = LibraryIndex(url: indexURL)
        let persistStart = Date()
        let coldScan = try await coldIndex.beginScan(root: identity)
        try await coldIndex.completeScan(
            coldScan, entries: cold.result.entries,
            verdict: LibraryIndexScanVerdict(finishedAt: Date(), filesSeen: cold.result.filesSeen,
                                             directoryErrors: cold.result.directoryErrors.count,
                                             outcome: "complete", absenceIsAuthoritative: true))
        let persistSeconds = Date().timeIntervalSince(persistStart)
        await coldIndex.close()

        let dbBytes = fileSizeBytes(indexURL)
        let rowCount = cold.result.entries.count
        XCTAssertGreaterThan(rowCount, 0, "the corpus is tagged, so the cold pass must persist rows")

        // ── WARM START: a NEW index object on the same file, exactly as a relaunch sees it.
        let warmIndex = LibraryIndex(url: indexURL)
        let warmStart = Date()
        let warm = try await warmIndex.snapshot(for: identity)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(warm.entries.count, rowCount, "warm start must publish every persisted row")
        XCTAssertNotNil(warm.asOf,
                        "a completed, clean, authoritative pass is exactly when warm start may claim currency")

        // ── STEADY REVALIDATION: fingerprints for every path, trustworthy tag reads only for rows the
        // cache cannot vouch for. This is what a normal launch pays after the first one.
        let revalidateStart = Date()
        let steady = LibraryScan.revalidatedPass(root: root, cached: warm.entries)
        let revalidateSeconds = Date().timeIntervalSince(revalidateStart)
        XCTAssertFalse(steady.result.cancelled)
        XCTAssertGreaterThanOrEqual(steady.result.filesSeen, requiredFileCount)
        // Nothing changed on disk between the two passes, so every cached row must have been reused
        // rather than re-read. `revalidatedPass` returns ALL readable regular files (the cold pass
        // persists only Read/Unread-tagged ones), so the reuse is measured against the cached set.
        XCTAssertGreaterThanOrEqual(steady.result.entries.count, rowCount,
                                    "a revalidation covers at least the rows the cache held")

        let peakFootprintMiB = Double(footprintBytes()) / 1_048_576
        let baselineMiB = Double(baselineFootprint) / 1_048_576
        print("""
        SCALE index root=\(root.path)
          filesSeen=\(cold.result.filesSeen) persistedRows=\(rowCount) \
        revalidatedRows=\(steady.result.entries.count)
          cold walk         \(String(format: "%.2f", coldWalkSeconds)) s
          cold persist      \(String(format: "%.2f", persistSeconds)) s \
        (\(String(format: "%.1f", persistSeconds / Double(max(rowCount, 1)) * 1_000_000)) us/row)
          WARM START        \(String(format: "%.3f", warmSeconds)) s \
        (\(String(format: "%.1f", warmSeconds / Double(max(rowCount, 1)) * 1_000_000)) us/row)
          steady revalidate \(String(format: "%.2f", revalidateSeconds)) s
          sqlite total      \(String(format: "%.1f", Double(dbBytes) / 1_048_576)) MiB \
        (\(dbBytes / Int64(max(rowCount, 1))) B/row)
          footprint         \(String(format: "%.1f", baselineMiB)) -> \
        \(String(format: "%.1f", peakFootprintMiB)) MiB
        """)

        // Ceilings, not benchmarks. Each is set where the DESIGN would be wrong, not where this machine
        // happens to land, so a slower machine does not turn the lane red for no reason.
        XCTAssertLessThan(warmSeconds, 5,
                          "warm start is the whole point of the cache; seconds of it defeats the purpose")
        XCTAssertLessThan(Double(dbBytes) / Double(max(rowCount, 1)), 1_024,
                          "a disposable cache over 1 KiB per row is ballooning, not caching")
        XCTAssertLessThan(peakFootprintMiB, 4_096,
                          "a discovery pass that needs gigabytes at 150k files is a design fault")

        // ── The cross-lane yardstick (`W26.verify-fu1`). Last, so it disturbs none of the numbers above,
        // and `CorpusWalker.scan` directly rather than `LibraryScan.pass` so it is literally the call the
        // ArchiveCore lane calibrates. Both passes here are warm — the tree has been walked three times —
        // which is the condition `ScaleLaneCalibration.measure` requires to mean anything.
        //
        // **On a `.utility` thread, because that is where the app walks.** `LibraryScan.onDedicatedThread`
        // sets `qualityOfService = .utility`, so a sample taken on the ambient test thread (user-initiated)
        // would come from a band the shipping app never runs discovery in — a subtler version of the very
        // fault this item exists to fix. The user-initiated sample is taken as well and reported, so the
        // size of the band's effect is on the record rather than assumed in either direction.
        let calibration = Self.measuringOnThread(qos: .utility) {
            let start = Date()
            let walk = CorpusWalker.scan(root: root)
            return ScaleLaneCalibration.measure(
                lane: "reader", root: root,
                warmWalkSeconds: Date().timeIntervalSince(start), filesSeen: walk.filesSeen)
        }
        let ambient = Self.measuringOnThread(qos: .userInitiated) {
            let start = Date()
            let walk = CorpusWalker.scan(root: root)
            return ScaleLaneCalibration.measure(
                lane: "reader-userInitiated", root: root,
                warmWalkSeconds: Date().timeIntervalSince(start), filesSeen: walk.filesSeen)
        }
        print(calibration.line)
        print(String(format: "SCALE qosband shipping(utility) qos=%u walk=%.1f | userInitiated qos=%u "
                     + "walk=%.1f | shipping/userInitiated=%.2f",
                     calibration.qos, calibration.walkMicrosecondsPerFile,
                     ambient.qos, ambient.walkMicrosecondsPerFile,
                     calibration.walkMicrosecondsPerFile
                        / max(ambient.walkMicrosecondsPerFile, 0.000_001)))
        XCTAssertEqual(calibration.qos, ScaleLaneCalibration.shippingBand,
                       "the shipping-band sample must actually have been taken at utility — if the host "
                       + "process is itself QoS-clamped the thread cannot reach it, and the number below "
                       + "would silently describe some other band")
        XCTAssertTrue(calibration.quotable,
                      "a sample from the app's own discovery band is by definition quotable")

        await warmIndex.close()
    }

    /// The guard with teeth. A revalidation that starts and is then cancelled — the app quit, the root
    /// switched, the user hit Rescan again — must leave the cache **unable to claim currency** and must
    /// **delete nothing**: `beginScan` marks every carried row unverified, and only a finished,
    /// complete, error-free pass may restore `asOf`. §7a.11 / §7a.13 of the plan.
    func testACancelledWarmRevalidationLeavesAsOfNilAndPrunesNothing() async throws {
        let root = try scaleRoot()
        let indexURL = scratch.appendingPathComponent("cancelled-index.sqlite3")
        let identity = LibraryIndexRoot(path: root.path, markerGUID: UUID())

        // Seed a good cache first, so "prunes nothing" has something to be about.
        let seedIndex = LibraryIndex(url: indexURL)
        let cold = LibraryScan.pass(root: root)
        let seedScan = try await seedIndex.beginScan(root: identity)
        try await seedIndex.completeScan(
            seedScan, entries: cold.result.entries,
            verdict: LibraryIndexScanVerdict(finishedAt: Date(), filesSeen: cold.result.filesSeen,
                                             directoryErrors: cold.result.directoryErrors.count,
                                             outcome: "complete", absenceIsAuthoritative: true))
        let seeded = try await seedIndex.snapshot(for: identity)
        XCTAssertNotNil(seeded.asOf, "precondition: the seeded cache is current")
        XCTAssertGreaterThan(seeded.entries.count, 0, "precondition: the seeded cache holds rows")
        await seedIndex.close()

        // Now begin a fresh pass and abandon it partway — the shape of a quit mid-revalidation.
        let liveIndex = LibraryIndex(url: indexURL)
        _ = try await liveIndex.beginScan(root: identity)
        let cancelAfter = max(requiredFileCount / 20, 50)
        let counter = Counter()
        let cancelled = LibraryScan.revalidatedPass(root: root, cached: seeded.entries,
                                                    isCancelled: { counter.tickAndExceeds(cancelAfter) })
        XCTAssertTrue(cancelled.result.cancelled, "the pass must actually have been cancelled")
        await liveIndex.close()

        // The relaunch. Nothing finished the pass, so currency is gone — and every row is still there.
        let relaunch = LibraryIndex(url: indexURL)
        let afterCancel = try await relaunch.snapshot(for: identity)
        XCTAssertNil(afterCancel.asOf,
                     "an unfinished pass must not let a warm start claim currency")
        XCTAssertEqual(afterCancel.entries.count, seeded.entries.count,
                       "a cancelled pass must delete nothing — absence was never established")

        // And a pass that finishes but is NOT authoritative must behave the same way: usable rows,
        // no currency, no deletions. This is the branch `ArchiveLibrary` takes for an unclean walk.
        let partialScan = try await relaunch.beginScan(root: identity)
        try await relaunch.completeScan(
            partialScan, entries: Array(cold.result.entries.prefix(10)),
            verdict: LibraryIndexScanVerdict(finishedAt: Date(), filesSeen: 10, directoryErrors: 1,
                                             outcome: "partial", absenceIsAuthoritative: false))
        let afterPartial = try await relaunch.snapshot(for: identity)
        XCTAssertNil(afterPartial.asOf, "a partial pass may never restore currency")
        XCTAssertEqual(afterPartial.entries.count, seeded.entries.count,
                       "a partial pass must not prune the rows it did not reach")
        print("SCALE cancel-semantics rows=\(seeded.entries.count) "
              + "cancelledAfterFilesSeen=\(cancelled.result.filesSeen) asOf=nil ✓ pruned=0 ✓")
        await relaunch.close()
    }

    /// Run `body` to completion on a **dedicated `Thread` at `qos`**, and hand back what it returned.
    ///
    /// A real `Thread`, configured the way `LibraryScan.onDedicatedThread` configures its own, rather
    /// than a `DispatchQueue` or a `Task` — the point is to reproduce the shipping walk's execution
    /// context exactly, and the cooperative pool does not let a caller pin a band. Blocking the caller
    /// on a semaphore is fine here: this is a measurement lane, the walk is the only thing running, and
    /// nothing it does needs the calling thread.
    private static func measuringOnThread<T: Sendable>(qos: QualityOfService,
                                                       _ body: @escaping @Sendable () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.name = "W26.verify-fu1.calibration"
        thread.qualityOfService = qos
        thread.start()
        done.wait()
        // Force-unwrap deliberately: the semaphore is signalled only after the box is filled, so a nil
        // here would mean the thread never ran, which must fail the lane rather than be papered over.
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func tickAndExceeds(_ limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count > limit
        }
    }
}
