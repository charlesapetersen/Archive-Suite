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

    /// Warm/cold index revalidation: cheap fresh fingerprints for every regular path, followed by a
    /// trustworthy tag read only for new, changed, or previously-unverified rows.
    ///
    /// The returned `CorpusScanResult.entries` intentionally contains ALL readable regular files.
    /// `ArchiveLibrary` applies the Read/Unread predicate for UI rows, while `LibraryIndex` persists
    /// the whole set so an untagged file that becomes tagged is one changed-row read next time.
    static func revalidatedPass(
        root: URL,
        cached: [LibraryIndexPath: LibraryIndexEntry],
        options: CorpusWalker.Options = CorpusWalker.Options(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onBatch: (@Sendable (CorpusScanBatch) -> Void)? = nil
    ) -> DiscoveryPass {
        CorpusWalker.withDatalessMaterializationDisabled {
            let before = CorpusRootFingerprint.capture(root)
            let fingerprints = CorpusWalker.scanFingerprints(
                root: root, options: options, isCancelled: isCancelled,
                onProgress: { seen in onBatch?(CorpusScanBatch(entries: [], filesSeen: seen)) }
            )

            var entries: [CorpusEntry] = []
            var unreadable = fingerprints.unreadable
            var vanished = fingerprints.vanishedMidScan
            var cancelled = fingerprints.cancelled
            var batch: [CorpusEntry] = []
            batch.reserveCapacity(options.batchSize)

            if !cancelled {
                for (offset, item) in fingerprints.entries.enumerated() {
                    if isCancelled() { cancelled = true; break }
                    let path = LibraryIndexPath(item.url)
                    let entry: CorpusEntry?
                    if let prior = cached[path], prior.verified,
                       prior.fingerprint == item.fingerprint {
                        entry = prior.corpusEntry()
                    } else {
                        // Predicate true means a successful tag read returns the raw entry whether it
                        // currently carries Read/Unread or not. A FRESH URL is built inside inspect.
                        switch CorpusWalker.inspect(item.url, predicate: { _ in true }) {
                        case let .tracked(fresh):
                            entry = fresh
                        case let .unreadable(failure):
                            unreadable.append(failure)
                            entry = nil
                        case .vanished, .directory, .directorySymbolicLink, .nonRegular:
                            // Normal namespace churn after the fingerprint phase: exclude the stale
                            // candidate, but do not turn a rename/replacement into a permission error.
                            vanished += 1
                            entry = nil
                        case .untracked:
                            // Impossible for the always-true predicate; fail closed if that contract
                            // ever changes rather than silently losing a regular file from persistence.
                            unreadable.append(CorpusReadFailure(
                                url: item.url,
                                reason: "tag inspection unexpectedly rejected an all-files predicate"
                            ))
                            entry = nil
                        }
                    }

                    if let entry {
                        entries.append(entry)
                        batch.append(entry)
                    }
                    if (offset + 1).isMultiple(of: options.batchSize), let onBatch {
                        // The fingerprint phase has already established the denominator. Keep it
                        // monotonic while these callbacks add newly tag-verified visible rows.
                        onBatch(CorpusScanBatch(entries: batch, filesSeen: fingerprints.filesSeen))
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !batch.isEmpty, let onBatch {
                onBatch(CorpusScanBatch(entries: batch, filesSeen: fingerprints.filesSeen))
            }

            let after = CorpusRootFingerprint.capture(root)
            return DiscoveryPass(
                result: CorpusScanResult(entries: entries,
                                         unreadable: unreadable,
                                         directoryErrors: fingerprints.directoryErrors,
                                         filesSeen: fingerprints.filesSeen,
                                         vanishedMidScan: vanished,
                                         rootUnreadable: fingerprints.rootUnreadable,
                                         cancelled: cancelled),
                rootStability: .between(before, after)
            )
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

    /// Indexed sibling of `onDedicatedThread`, using the two-phase fingerprint/tag revalidation.
    static func revalidateOnDedicatedThread(
        root: URL,
        cached: [LibraryIndexPath: LibraryIndexEntry],
        isCancelled: @escaping @Sendable () -> Bool,
        onBatch: (@Sendable (CorpusScanBatch) -> Void)?,
        completion: @escaping @Sendable (DiscoveryPass) -> Void
    ) {
        let thread = Thread {
            let outcome = revalidatedPass(root: root, cached: cached,
                                          isCancelled: isCancelled, onBatch: onBatch)
            DispatchQueue.main.async { completion(outcome) }
        }
        thread.name = "ArchiveReader.LibraryRevalidation"
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
