import Foundation
import ArchiveCore

// ============================================================================================
//  TagBatch — a bulk tag change's per-file writes, off the main actor (W49.reader-batch-writes-async).
//
//  Mark Read/Unread, the group editor, a corpus-wide rename, and undo or redo of any of them wrote file
//  after file on the main actor, so a large selection froze the window until the last file was done. A
//  batch of more than `NavigationModel.tagBatchInlineLimit` files runs here instead, with a live count
//  and a Cancel button; a smaller one still runs inline, where it is over before a progress bar could draw.
//
//  Every write is still one `TagWriter` call, so `CoordinatedTagWriter`'s per-file safety is unchanged.
//  What is new is only the scheduling:
//  * Lanes. Members that name one file (one path, or one device/inode under two paths) share a lane and
//    run in the order given: an undo batch lists one file's writes newest first and must reverse them in
//    that order, and file coordination serializes writes per path, not per inode. Lanes run at most
//    `width` at a time, each a blocking coordinated write on a pool thread.
//  * The ledger. The action's context (group, journal) is a task-local that every lane inherits.
//    `ActionJournal.open` is locked, so the intent is synchronized before any lane's first write, and
//    `withBatchContext` appends `actionDone` only once every lane has returned.
//  * Cancel stops each lane before its next member. A write already under way always finishes, so a
//    cancelled batch is a shorter batch, recorded and undone like any other.
// ============================================================================================

enum TagBatch {

    /// Concurrent lanes: enough to overlap the waits of coordination and the ledger, few enough to leave
    /// the pool threads the rest of the app needs.
    static let width = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Cancel and progress, shared by the lanes and the main actor.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var finished = 0
        private let stopAfter: Int?

        /// `stopAfter`: cancel as if Cancel were pressed once that many members are done (tests).
        init(stopAfter: Int? = nil) { self.stopAfter = stopAfter; cancelled = stopAfter == 0 }

        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
        /// Members done, written or not.
        var done: Int { lock.withLock { finished } }
        func step() {
            lock.withLock {
                finished += 1
                if let stopAfter, finished >= stopAfter { cancelled = true }
            }
        }

        private let completion = NSCondition()
        private var outcome: (any Sendable)?

        /// Set by `execute` once every lane has returned and the action is closed.
        func complete(_ value: any Sendable) {
            completion.lock(); outcome = value; completion.broadcast(); completion.unlock()
        }

        /// The outcome, waiting at most `timeout` for it. For a quit, which cannot wait for the main actor: the
        /// lanes never need it, so a main thread blocked here only waits for their current files.
        func waitForOutcome(timeout: TimeInterval) -> (any Sendable)? {
            completion.lock(); defer { completion.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while outcome == nil, completion.wait(until: deadline) {}
            return outcome
        }
    }

    /// A member's lane keys: its path and its device/inode. A member with no device/inode shares one lane with
    /// every other such member: an undo line without one may resolve (by its bookmark) to a file another names.
    static func keys(path: String, file: AuditLedger.FileNumber?) -> [String] {
        ["p:" + path, file.map { "i:\($0.device):\($0.inode)" } ?? "i:none"]
    }

    /// Members `0..<keys.count` grouped so that two sharing any key are in one lane, each lane in the
    /// members' order, the lanes in the order of their first member.
    static func lanes(_ keys: [[String]]) -> [[Int]] {
        var parent = Array(keys.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var owner: [String: Int] = [:]
        for (i, ks) in keys.enumerated() {
            for k in ks {
                if let j = owner[k] {
                    let (a, b) = (root(i), root(j))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else { owner[k] = i }
            }
        }
        var lanes: [[Int]] = []
        var laneOf: [Int: Int] = [:]
        for i in keys.indices {
            let r = root(i)
            if let l = laneOf[r] { lanes[l].append(i) } else { laneOf[r] = lanes.count; lanes.append([i]) }
        }
        return lanes
    }

    /// Run every lane, at most `width` at a time. `lane` gets its members in order and returns an outcome for
    /// each member it ran; it checks `control.isCancelled` before each member and calls `control.step()` after.
    static func run<R: Sendable>(_ lanes: [[Int]], control: Control,
                                 _ lane: @escaping @Sendable (_ members: [Int], _ control: Control) -> [(Int, R)])
        async -> [Int: R] {
        await withTaskGroup(of: [(Int, R)].self) { group in
            var next = 0
            var results: [Int: R] = [:]
            while next < min(width, lanes.count) {
                let members = lanes[next]
                group.addTask { lane(members, control) }
                next += 1
            }
            while let finished = await group.next() {
                for (i, r) in finished { results[i] = r }
                if next < lanes.count {
                    let members = lanes[next]
                    group.addTask { lane(members, control) }
                    next += 1
                }
            }
            return results
        }
    }

    /// One ledger action around `run`: the lanes' keys are read here, off the main actor (a device/inode is a
    /// stat), and afterwards each written file is read back, so a result that a later write has overtaken
    /// is reported in `stale` rather than shown on its row.
    static func execute<R: Sendable>(count: Int, keys: @escaping @Sendable (Int) -> [String],
                                     group: UUID, undoes: UUID? = nil, redoes: UUID? = nil, files: [URL] = [],
                                     control: Control, written: @escaping @Sendable (R) -> TagWriteResult?,
                                     _ lane: @escaping @Sendable (_ members: [Int], _ control: Control) -> [(Int, R)])
        async -> (results: [Int: R], stale: Set<URL>) {
        let lanes = lanes((0..<count).map(keys))
        let results = await AuditLedger.withBatchContext(group: group, undoes: undoes, redoes: redoes, files: files) {
            await run(lanes, control: control, lane)
        }
        // A file written twice (two lines of one undo) is judged by its last write, the one its row would show.
        var last: [URL: TagWriteResult] = [:]
        for i in results.keys.sorted() { if let r = results[i].flatMap(written) { last[r.url] = r } }
        var stale: Set<URL> = []
        for r in last.values {
            if case let .success(names, _) = TagReading.read(r.url), multisetEqual(names, r.after) { continue }
            stale.insert(r.url)
        }
        control.complete((results, stale))
        return (results, stale)
    }

    /// The simple lane: each member on its own, stopping at a cancel.
    static func each<R: Sendable>(_ body: @escaping @Sendable (Int) -> R)
        -> @Sendable ([Int], Control) -> [(Int, R)] {
        { members, control in
            var out: [(Int, R)] = []
            for i in members {
                if control.isCancelled { break }
                out.append((i, body(i)))
                control.step()
            }
            return out
        }
    }
}

/// What one member of a forward batch did.
enum TagBatchWrite: Sendable {
    case wrote(TagWriteResult)
    case failed

    var result: TagWriteResult? { if case .wrote(let r) = self { r } else { nil } }
}
