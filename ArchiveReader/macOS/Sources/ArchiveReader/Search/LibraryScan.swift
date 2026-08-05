import Foundation
import ArchiveCore

/// One discovery pass: what the walker found, plus the one verdict it cannot reach on its own.
struct DiscoveryPass: Sendable {
    let result: CorpusScanResult
    /// Did the root hold still from the pre-pass capture to the post-pass one (plan §7a.11)?
    let rootStability: RootStability
}

/// Runs a discovery pass — and brackets it with the root-identity capture that makes the pass's own
/// "complete and clean" verdict trustworthy.
///
/// Deliberately **not** a method on `ArchiveLibrary`: the library is `@MainActor`, and everything here
/// runs on the walking thread. Keeping it a `nonisolated` namespace is what makes that a compile-time
/// fact rather than a comment.
enum LibraryScan {

    /// Walk `root` synchronously on the calling thread.
    ///
    /// Both fingerprint captures happen **inside** `withDatalessMaterializationDisabled`, so a cloud
    /// placeholder root cannot turn the identity check itself into the 0.54 s-per-call stall the
    /// dataless guard exists to prevent. `CorpusWalker.scan` sets the same policy again; it
    /// save-and-restores, so nesting is a no-op rather than a leak.
    static func pass(root: URL,
                     isCancelled: @escaping @Sendable () -> Bool = { false },
                     onBatch: (@Sendable (CorpusScanBatch) -> Void)? = nil) -> DiscoveryPass {
        CorpusWalker.withDatalessMaterializationDisabled {
            let before = CorpusRootFingerprint.capture(root)
            let result = CorpusWalker.scan(root: root, isCancelled: isCancelled, onBatch: onBatch)
            let after = CorpusRootFingerprint.capture(root)
            return DiscoveryPass(result: result, rootStability: .between(before, after))
        }
    }

    /// Run `pass` on a **dedicated `Thread`** and deliver the result on the main queue.
    ///
    /// A real `Thread`, not `Task.detached`, for the two reasons `CorpusWalker` documents: the dataless
    /// I/O policy is thread-scoped and the cooperative pool reuses threads, and a ~10 s blocking walk
    /// would starve that pool for its duration (plan §4a.4, §7a.8).
    static func onDedicatedThread(root: URL,
                                  isCancelled: @escaping @Sendable () -> Bool,
                                  onBatch: (@Sendable (CorpusScanBatch) -> Void)?,
                                  completion: @escaping @Sendable (DiscoveryPass) -> Void) {
        let thread = Thread {
            let outcome = pass(root: root, isCancelled: isCancelled, onBatch: onBatch)
            DispatchQueue.main.async { completion(outcome) }
        }
        thread.name = "ArchiveReader.LibraryScan"
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// What the results area says when it has no rows to show.
///
/// Pure and separate from the view on purpose. The 2026-08-04 incident was a *sentence*: the Reader
/// rendered `"No Read/Unread-tagged PDFs were found in this folder"` — a claim about the corpus —
/// while the truth was "this app could not see it". The guard that makes that wording unreachable is
/// therefore a tested function, not a chain of `if`s inside a `@ViewBuilder`.
enum LibraryEmptyState: Equatable, Sendable {
    case noRoot
    /// A pass is running and there is nothing yet to show.
    case scanning
    /// We could not look properly, so we say that instead of describing the folder.
    case couldNotLook(DiscoveryFailure)
    /// The **only** case allowed to state that nothing is tagged — and it must quote its denominator.
    case nothingTagged(scanned: Int)
    /// A complete, clean pass that saw no files at all.
    case folderIsEmpty
    /// Rows exist; the user's own filters hide them.
    case filteredOut

    /// `nil` when rows are on screen and nothing needs saying.
    ///
    /// - Parameters:
    ///   - rowCount: rows in the library (`files.count`).
    ///   - displayedCount: rows surviving the user's filters.
    static func forPhase(_ phase: LibraryPhase, rowCount: Int, displayedCount: Int) -> LibraryEmptyState? {
        if case .noRoot = phase { return .noRoot }
        guard displayedCount == 0 else { return nil }
        if rowCount > 0 { return .filteredOut }
        // No rows. Whether we may blame the FOLDER for that is exactly the question.
        if let failure = phase.failure { return .couldNotLook(failure) }
        guard case let .settled(_, scanned) = phase else { return .scanning }
        return scanned > 0 ? .nothingTagged(scanned: scanned) : .folderIsEmpty
    }
}
