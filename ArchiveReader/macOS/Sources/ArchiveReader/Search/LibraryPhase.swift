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
    /// One or more files live on a volume that cannot store Finder tags at all (`getxattr` returned
    /// `ENOTSUP`). Keep the other failure counts too: a root may cross mount boundaries, and naming
    /// the unsupported volume must not hide simultaneous permissions or directory failures.
    case finderTagsUnsupported(files: Int, otherFiles: Int, folders: Int)
    /// The pass ran to the end but could not read everything it saw.
    case partiallyUnreadable(files: Int, folders: Int)

    /// One line for the status bar.
    var message: String {
        switch self {
        case .rootUnreadable:     return "Archive folder unreadable"
        case .rootChangedMidScan: return "Archive folder changed while scanning"
        case .incomplete:         return "Scan incomplete"
        case let .finderTagsUnsupported(files, _, _):
            return "Finder tags unavailable for \(files) file\(files == 1 ? "" : "s")"
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
        case let .finderTagsUnsupported(files, otherFiles, folders):
            let volume = files == 1
                ? "The volume holding this file does"
                : "One or more volumes holding these files do"
            let affected = files == 1 ? "this file carries" : "these \(files) files carry"
            var detail = "\(volume) not support Finder tags, so Archive Reader cannot tell whether "
                       + "\(affected) Read or Unread and will not list or edit them. Use a copy "
                       + "of the archive on a volume with Finder-tag support, such as APFS, then rescan (⌘⌥R)."
            if otherFiles > 0 || folders > 0 {
                let other = [otherFiles > 0
                                ? "\(otherFiles) other file\(otherFiles == 1 ? "" : "s")" : nil,
                             folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil]
                    .compactMap { $0 }
                    .joined(separator: " and ")
                detail += " The scan also could not read \(other); the result may be incomplete for "
                        + "more than one reason."
            }
            return detail
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

/// Whether the root vouched for the pass that just walked it (plan §7a.11).
///
/// Three states, not two, and the third one is a bug I found reviewing my own first cut: a root that
/// was **never readable** fails the before/after comparison exactly like one that was swapped
/// mid-pass, so a two-state answer made an unreadable folder report *"Archive folder changed while
/// scanning"* — a confident, specific, wrong diagnosis of the commonest case there is.
enum RootStability: Equatable, Sendable {
    /// The same readable root before and after the pass.
    case heldStill
    /// Identified at the start, but not the same root — or no longer readable — at the end.
    case changedMidScan
    /// Could not be identified even at the start: nothing here was ever readable.
    case neverIdentified

    static func between(_ before: CorpusRootFingerprint?, _ after: CorpusRootFingerprint?) -> RootStability {
        guard before != nil else { return .neverIdentified }
        return CorpusRootFingerprint.rootHeldStill(before: before, after: after) ? .heldStill : .changedMidScan
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

    /// Stable suffix emitted by ArchiveCore's `TagXattr.inspect` for `getxattr(...)=ENOTSUP`.
    /// Do not infer this from generic localized errors: only that syscall result proves the volume
    /// cannot represent Finder tags, rather than merely denying access to one file.
    private static let finderTagsUnsupportedSuffix =
        "extended attributes unsupported on this volume (ENOTSUP)"

    /// Map one pass onto a failure, or `nil` when it is authoritative.
    ///
    /// `isClean` is **consulted, not re-derived** — it is already the plan §5.13 tier-1 gate and lives
    /// with the walker that produces the counters. This function only adds the two things the walker
    /// cannot see: whether the caller cancelled it, and whether the root held still (§7a.11).
    static func failure(for result: CorpusScanResult, root: RootStability) -> DiscoveryFailure? {
        // A root that could not be identified at all is unreadable, NOT "changed" — the walker's own
        // `rootUnreadable` only fires when `FileManager` hands back no enumerator, which a sealed
        // directory does not always do.
        if result.rootUnreadable || root == .neverIdentified { return .rootUnreadable }
        if result.cancelled { return .incomplete }
        if root == .changedMidScan { return .rootChangedMidScan }
        guard result.isClean else {
            let unsupported = result.unreadable.reduce(into: 0) { count, failure in
                if failure.reason.hasSuffix(finderTagsUnsupportedSuffix) { count += 1 }
            }
            if unsupported > 0 {
                return .finderTagsUnsupported(files: unsupported,
                                              otherFiles: result.unreadable.count - unsupported,
                                              folders: result.directoryErrors.count)
            }
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
                      root: RootStability,
                      finishedAt: Date,
                      lastSettled: Date?) -> LibraryPhase {
        if let f = failure(for: result, root: root) {
            return .degraded(f, asOf: lastSettled)
        }
        return .settled(asOf: finishedAt, scanned: result.filesSeen)
    }
}
