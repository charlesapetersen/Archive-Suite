import Foundation
import ArchiveCore
import os

/// A bulk tag change running off the main actor: what the status bar shows (W49.reader-batch-writes-async).
struct TagBatchStatus: Equatable {
    let title: String
    var done: Int
    let total: Int
    var cancelling = false
}

/// The archive folders a tag change may write, read once on the main actor so the lanes of a batch can check
/// them off it: MAIN for every change, and the read-state trees for one that touches only Read and Unread.
struct TagWriteBounds: Sendable {
    let mainRoot: String?
    let readStateRoots: [String]

    func allows(_ url: URL, readStateOnly: Bool) -> Bool {
        readStateOnly ? readStateRoots.contains { ReaderArchiveLayout.isContained(url, inRootPath: $0) }
            : mainRoot.map { ReaderArchiveLayout.isContained(url, inRootPath: $0) } ?? false
    }
}

extension NavigationModel {

    func tagWriteBounds() -> TagWriteBounds {
        var main: String?
        if let root = rootStore.root {
            let layout = ReaderArchiveLayout(grantedRoot: root)
            if !layout.needsCommonParentGrant { main = layout.mainRoot.path }
        }
        return TagWriteBounds(mainRoot: main, readStateRoots: readStateRoots().map(\.path))
    }

    /// True, with the reason on the status line, while a batch runs: no other Reader tag change starts until it
    /// ends, so its rows, its undo step and the next change's never interleave.
    func refuseWhileTagBatchRuns() -> Bool {
        guard tagBatch != nil else { return false }
        statusMessage = "Wait for the tag change in progress to finish, or cancel it."
        announce(statusMessage)
        return true
    }

    /// Stops the running batch before its next file; the files already written stay written, as one undo step.
    func cancelTagBatch() {
        guard let control = tagBatchControl, tagBatch?.cancelling == false else { return }
        control.cancel()
        tagBatch?.cancelling = true
    }

    /// Returns once the running batch, if any, has finished and reported.
    func tagBatchFinished() async {
        await tagBatchTask?.value
    }

    /// " Cancelled; N files left unchanged." for a status line, or "" when nothing was stopped.
    static func cancelledNote(_ stopped: Int) -> String {
        stopped == 0 ? "" : " Cancelled; \(stopped) file\(stopped == 1 ? "" : "s") left unchanged."
    }

    /// Runs a batch of `count` members as one ledger action. Up to `tagBatchInlineLimit` members run inline, in one
    /// lane in their order, as every batch did before. A larger batch runs off the main actor in lanes (`TagBatch`),
    /// with `tagBatch` published for the status bar until it ends. `finish` runs on the main actor with each
    /// member's outcome (a member a cancel stopped has none) and the written files a later write has overtaken.
    func runTagBatch<R: Sendable>(_ title: String, count: Int,
                                  keys: @escaping @Sendable (Int) -> [String],
                                  group: UUID, undoes: UUID? = nil, redoes: UUID? = nil, files: [URL] = [],
                                  written: @escaping @Sendable (R) -> TagWriteResult?,
                                  lane: @escaping @Sendable ([Int], TagBatch.Control) -> [(Int, R)],
                                  finish: @escaping @MainActor ([Int: R], Set<URL>) -> Void) {
        guard count > tagBatchInlineLimit else {
            let outcomes = ReaderStages.measure("tagWriter.writes") {
                AuditLedger.withContext(group: group, undoes: undoes, redoes: redoes, files: files) {
                    lane(Array(0..<count), TagBatch.Control())
                }
            }
            finish(Dictionary(outcomes, uniquingKeysWith: { $1 }), [])
            return
        }
        let control = TagBatch.Control(stopAfter: tagBatchStopAfter)
        tagBatchControl = control
        tagBatch = TagBatchStatus(title: title, done: 0, total: count)
        refreshUndoHistory()   // hides Undo and Redo until the batch ends
        statusMessage = "\(title)…"
        announce(statusMessage)
        // Reports once, from whichever comes first: the batch's end, or a quit that cannot wait for it.
        let report: @MainActor ([Int: R], Set<URL>) -> Void = { [weak self] results, stale in
            guard let self, tagBatchControl === control else { return }
            tagBatch = nil
            tagBatchControl = nil
            tagBatchTask = nil
            tagBatchQuitFlush = nil
            finish(results, stale)
        }
        tagBatchQuitFlush = {
            control.cancel()
            guard let outcome = control.waitForOutcome(timeout: 30) as? ([Int: R], Set<URL>) else {
                // Safe (an undo's unreached lines are lost, never replayed), but say so where it can be found.
                Logger(subsystem: "com.archivereader.app", category: "TagBatch")
                    .error("quit: \(title, privacy: .public) did not stop within 30 s; its report was not recorded")
                return
            }
            report(outcome.0, outcome.1)
            Self.folderDateRecordQueue.sync {}   // an undo's folder-date records land before the process ends
        }
        // Detached, so the lanes start at once and never wait for the main actor; a quit blocks it to wait for them.
        let work = Task.detached(priority: .userInitiated) {
            await TagBatch.execute(count: count, keys: keys, group: group, undoes: undoes, redoes: redoes,
                                   files: files, control: control, written: written, lane)
        }
        tagBatchTask = Task {
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    tagBatch?.done = control.done
                }
            }
            let outcome = await work.value
            ticker.cancel()
            report(outcome.results, outcome.stale)
        }
    }
}
