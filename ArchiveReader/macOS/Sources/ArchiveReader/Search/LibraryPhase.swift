import Foundation
import ArchiveCore

/// Why discovery is degraded, when it is (`nil` = healthy). Shaped after `ContentIndexer.Failure`:
/// one line for the status bar, one paragraph for its tooltip.
///
/// The distinction this type exists to carry is *"I could not look"* vs *"there is nothing here."*
/// Spotlight could not express it, so on 2026-08-04 the Reader said **"No Read/Unread-tagged PDFs
/// were found in this folder"** about 1,849 correctly-tagged files. Every case below is a reason the
/// app must NOT make that claim.
enum DiscoveryFailure: Equatable, Sendable {
    /// The root itself could not be enumerated at all.
    case rootUnreadable
    /// The root was replaced, ejected or became unreadable *during* the pass, so a short list is not
    /// evidence of absence even though the enumerator ended normally (plan §7a.11).
    case rootChangedMidScan
    /// The pass was cancelled (a root switch, app teardown) before reaching the end.
    case incomplete
    /// The pass ran to the end but could not read everything it saw.
    case partiallyUnreadable(files: Int, folders: Int)

    /// One line for the status bar.
    var message: String {
        switch self {
        case .rootUnreadable:     return "Archive folder unreadable"
        case .rootChangedMidScan: return "Archive folder changed while scanning"
        case .incomplete:         return "Scan incomplete"
        case let .partiallyUnreadable(files, folders):
            let parts = [files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil,
                         folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil]
                .compactMap { $0 }
            return "Could not read \(parts.joined(separator: " and "))"
        }
    }

    /// The longer explanation, for the status bar's tooltip.
    var detail: String {
        switch self {
        case .rootUnreadable:
            return "This app could not read the archive folder at all, so the list below is empty "
                 + "because nothing could be looked at — not because the folder has no tagged files."
        case .rootChangedMidScan:
            return "The archive folder was replaced, ejected or became unreadable while it was being "
                 + "scanned, so the scan stopped early without reporting an error. The list may be "
                 + "incomplete; rescan (⌘⌥R) once the folder is back."
        case .incomplete:
            return "The scan did not finish, so the list may be incomplete. Rescan with ⌘⌥R."
        case let .partiallyUnreadable(files, folders):
            let what = folders > 0
                ? "Some items could not be read (\(files) file\(files == 1 ? "" : "s"), "
                  + "\(folders) folder\(folders == 1 ? "" : "s"))"
                : "\(files) file\(files == 1 ? "" : "s") could not be read"
            return what + ", usually a permissions problem. Anything inside them is missing from the "
                 + "list, so an empty or short result here is not proof that nothing is tagged."
        }
    }
}

/// What the library currently knows, and how much of it is trustworthy.
///
/// ⚠️ **This replaced `isGathering: Bool` outright rather than reinterpreting it.** The old flag drove
/// a full-screen spinner that *blanks the list* (`NavigationWindowView.tableOverlay`), and it also
/// gated destructive content-index pruning (`NavigationModel.pruneIfSettled`). One boolean cannot do
/// both jobs once discovery revalidates in the background: reusing it would either blank real rows on
/// every rescan or claim the view is settled while a pass is still running.
enum LibraryPhase: Equatable, Sendable {
    /// No archive folder is open.
    case noRoot
    /// The first pass over a newly-opened root; the list is not populated yet. `done` = matching rows
    /// found so far, `seen` = regular files examined so far. No total: a filesystem walk cannot know
    /// one up front, and inventing one would be the same kind of lie this wave exists to remove.
    case firstScan(done: Int, seen: Int)
    /// A later pass, running behind rows already on screen. `asOf` is when discovery last settled —
    /// `nil` when it never has (a rescan after a degraded first pass still has rows worth keeping on
    /// screen, and claiming a settle time it never had would be its own small lie).
    case revalidating(asOf: Date?)
    /// A pass completed, read everything it saw, and the root held still. `scanned` is how many
    /// regular files it examined — the **denominator** the empty state is required to quote.
    case settled(asOf: Date, scanned: Int)
    /// The most recent pass could not be trusted. `asOf` is when discovery last settled, if ever.
    case degraded(DiscoveryFailure, asOf: Date?)

    /// **The absence gate.** True only for `.settled`.
    ///
    /// Everything else — including `.revalidating` and `.degraded` — must read false, because both
    /// authorise the same thing: deleting content-index rows for files the current snapshot omits
    /// (plan §7a.4). A degraded or mid-revalidation pass omits files it merely failed to reach.
    var isSettled: Bool {
        if case .settled = self { return true }
        return false
    }

    /// The only phase in which a list-blanking full-screen spinner is honest: there are no rows to
    /// blank yet.
    var isFirstScan: Bool {
        if case .firstScan = self { return true }
        return false
    }

    /// A pass is running (first or revalidating) — for the small status-bar spinner, which does not
    /// hide anything.
    var isScanning: Bool {
        switch self {
        case .firstScan, .revalidating: return true
        case .noRoot, .settled, .degraded: return false
        }
    }

    /// The failure to surface, if any.
    var failure: DiscoveryFailure? {
        if case let .degraded(f, _) = self { return f }
        return nil
    }
}

/// The single, pure place where a scan result becomes a health verdict.
///
/// Kept out of `ArchiveLibrary` on purpose: the library owns threads, `@Published` state and an
/// in-flight pass, none of which a test of *"which outcomes may claim the corpus is empty"* should
/// have to stand up. Every branch below is unit-tested in `DiscoveryHealthTests`.
enum DiscoveryHealth {

    /// Map one pass onto a failure, or `nil` when it is authoritative.
    ///
    /// `isClean` is **consulted, not re-derived** — it is already the plan §5.13 tier-1 gate and lives
    /// with the walker that produces the counters. This function only adds the two things the walker
    /// cannot see: whether the caller cancelled it, and whether the root held still (§7a.11).
    static func failure(for result: CorpusScanResult, rootHeldStill: Bool) -> DiscoveryFailure? {
        if result.rootUnreadable { return .rootUnreadable }
        if result.cancelled { return .incomplete }
        if !rootHeldStill { return .rootChangedMidScan }
        guard result.isClean else {
            return .partiallyUnreadable(files: result.unreadable.count,
                                        folders: result.directoryErrors.count)
        }
        return nil
    }

    /// The phase a finished pass publishes.
    ///
    /// - Parameter lastSettled: when discovery last settled, for a `.degraded` result to date itself
    ///   against ("showing what we knew at 14:03" beats an undated wrong claim).
    static func phase(after result: CorpusScanResult,
                      rootHeldStill: Bool,
                      finishedAt: Date,
                      lastSettled: Date?) -> LibraryPhase {
        if let f = failure(for: result, rootHeldStill: rootHeldStill) {
            return .degraded(f, asOf: lastSettled)
        }
        return .settled(asOf: finishedAt, scanned: result.filesSeen)
    }
}
