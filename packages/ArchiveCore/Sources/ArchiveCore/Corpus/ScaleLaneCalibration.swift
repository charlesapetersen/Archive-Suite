import Foundation

/// The yardstick the two scale lanes measure themselves against, so their numbers can be compared.
///
/// **Why this exists (`W26.verify-fu1`).** `ops/scale/run-scale-verify.sh` walks one 150k-file scratch
/// tree twice: once from `swift test -c release` (ArchiveCore) and once from the app-HOSTED Reader unit
/// bundle. On 2026-08-10 those two lanes reported **248 µs/file and 56 µs/file for the same walk over the
/// same tree** — 4.4× apart — and the harness had no way to say which number was real.
///
/// It is neither the code nor the build. Measured by decomposing the walk into its primitives and running
/// the identical decomposition in both processes: **every filesystem primitive is ~5-6× more expensive in
/// the `swift test` process**, including bare `FileManager.enumerator` iteration (6.3 vs 1.4 µs/entry) and
/// a bare `stat(2)` (16.6 vs 3.4 µs/entry) — code paths that contain no ArchiveCore at all. The cause is
/// the *measuring process's* scheduling: an unattended daemon session runs at `QOS_CLASS_BACKGROUND`, so
/// everything it spawns is clamped to efficiency cores (`qos_class_self() == 9`, and
/// `pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)` fails with the task clamp in place). The
/// app-hosted test host escapes the clamp because `testmanagerd`, not the session's shell, launches it.
///
/// **So a per-file absolute is a property of the thread that took it, not of the walker.** What survives
/// the environment is the *ratio* of the full walk to a reference pass measured on the same thread,
/// moments apart, at the same cache warmth. Both lanes therefore emit a `SCALE calib` line, and the
/// harness compares the two RATIOS. That is also why this type lives in the product module rather than in
/// either test bundle: a yardstick each lane implemented for itself could drift, and a drifted yardstick
/// turns the cross-lane check into a green that means nothing.
///
/// **And exactly one band gives the absolute anyone wants: the one the app walks in.** `LibraryScan`
/// runs discovery on a dedicated `.utility` thread, so the Reader lane takes its calibration sample on a
/// thread configured the same way and `quotable` is measured against that bar — see the property. Both
/// halves matter: the ratio says the two lanes agree about the *walker*, and the shipping-band sample
/// says what the walk *costs*. Neither answers the other's question.
///
/// The reference is `CorpusWalker.scanFingerprints` — the shipped stat-only pass. Deliberately not the
/// walk's own dominant cost (the trustworthy tag read, which is ~90% of it): normalising by the thing
/// under test would make the comparison vacuous.
public struct ScaleLaneCalibration: Sendable {

    /// Which lane took this sample — `core` or `reader`.
    public let lane: String
    /// `qos_class_self()` on the measuring thread. 9 = background, 17 = utility, 21 = default,
    /// 25 = user-initiated, 33 = user-interactive, 0 = unspecified/legacy.
    public let qos: UInt32
    /// Whether this sample's per-file **absolute** may be quoted as a cost the app would pay.
    ///
    /// The bar is the band the shipping discovery pass actually runs in: `LibraryScan`'s dedicated
    /// thread is `.utility` (`LibraryScan.onDedicatedThread`, `revalidateOnDedicatedThread`), so a
    /// sample taken at utility **or better** is quotable and one taken below it is not.
    ///
    /// Deliberately NOT "unclamped". The first draft of this type treated utility itself as a clamp,
    /// which disqualified the only band anybody wants a number from and left the harness quoting a
    /// user-initiated figure — a band the app never runs discovery in — as though it were the
    /// shipping cost. Unspecified (0) is not quotable: it means the band could not be read, and a
    /// measurement that cannot say where it was taken is not one to build arithmetic on.
    public let quotable: Bool
    public let walkMicrosecondsPerFile: Double
    public let referenceMicrosecondsPerFile: Double
    public let filesSeen: Int

    /// The environment-free number: how many stat-only passes one full walk costs.
    public var normalised: Double {
        walkMicrosecondsPerFile / max(referenceMicrosecondsPerFile, 0.000_001)
    }

    /// One machine-readable line, parsed by `ops/scale/run-scale-verify.sh`.
    public var line: String {
        String(format: "SCALE calib lane=%@ qos=%u quotable=%@ files=%d walk=%.1f reference=%.1f normalised=%.2f",
               lane, qos, quotable ? "yes" : "no", filesSeen,
               walkMicrosecondsPerFile, referenceMicrosecondsPerFile, normalised)
    }

    /// The QoS band the shipping discovery pass runs in — `LibraryScan`'s dedicated thread. A sample
    /// taken here is the one the arithmetic should use; anything below it is inflated.
    public static let shippingBand = UInt32(QOS_CLASS_UTILITY.rawValue)

    /// Time the reference pass **now**, and pair it with a full-walk timing the caller has just taken.
    ///
    /// Call this immediately after the walk being calibrated, so the two share cache warmth: a warm walk
    /// over a cold reference (or the reverse) reports the ordering, not the ratio.
    public static func measure(lane: String,
                               root: URL,
                               warmWalkSeconds: TimeInterval,
                               filesSeen: Int) -> ScaleLaneCalibration {
        let start = Date()
        let reference = CorpusWalker.scanFingerprints(root: root)
        let referenceSeconds = Date().timeIntervalSince(start)

        let files = Double(max(filesSeen, 1))
        let referenceFiles = Double(max(reference.filesSeen, 1))
        let currentQoS = UInt32(qos_class_self().rawValue)
        return ScaleLaneCalibration(
            lane: lane,
            qos: currentQoS,
            quotable: currentQoS >= shippingBand,
            walkMicrosecondsPerFile: warmWalkSeconds / files * 1_000_000,
            referenceMicrosecondsPerFile: referenceSeconds / referenceFiles * 1_000_000,
            filesSeen: filesSeen)
    }
}
