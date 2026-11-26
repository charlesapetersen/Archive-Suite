import CoreGraphics
import Darwin
import Foundation
import Vision

/// W49.proc-vision-page-cache (owner, 2026-11-24) — one Apple Vision pass per page, pass kind and orientation.
///
/// A page meets Vision several times on its way through a run: page-kind classification before the run and again in
/// the newspaper reader, rotation, the cascade's word count, the read-poorly check, the Vision reader itself and the
/// reading copy's straightening slope. Each stage used to run its own `VNRecognizeTextRequest`, so a pass with the same
/// image and the same request settings ran two or three times per page. This cache keys a pass by the page file (its
/// device, inode, size and modification time, read with stat(2), so an edited or replaced file is a new key), the
/// clockwise turn applied before reading and the pass's request profile, and hands every later stage the first
/// stage's result. A pass still running is joined, not started again (rotation runs beside the reading).
///
/// Passes with DIFFERENT request settings are not merged here: rotation reads a 1,000-pixel thumbnail with language
/// correction and a minimum text height, page kind reads the full page without correction (the bundled model was
/// fitted on those features), the straightening slope reads at 1,600 pixels, and the transcription uses the run's
/// languages and vocabulary. Each of those was measured as it is; sharing one pass across them changes what each
/// stage sees and is settled by measurement, not by this cache.
struct PageVisionSnapshot: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        let text: String
        let confidence: Float
        /// Normalised, bottom-left origin, as Vision gives it.
        let boundingBox: CGRect
        let bottomLeft: CGPoint
        let bottomRight: CGPoint
        /// The boxes of the first and last non-blank characters (the reading direction), when Vision gives them.
        let firstCharacter: CGRect?
        let lastCharacter: CGRect?
    }

    /// The pixel size of the image Vision read.
    let width: Int
    let height: Int
    let lines: [Line]

    /// The top candidate of every observation, in Vision's order. `characterBoxes` also records each line's first and
    /// last character boxes (one extra lookup per line; only rotation reads them).
    init(observations: [VNRecognizedTextObservation], width: Int, height: Int, characterBoxes: Bool = false) {
        self.width = width
        self.height = height
        lines = observations.compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            var first: CGRect?, last: CGRect?
            let text = c.string
            if characterBoxes, let a = text.firstIndex(where: { !$0.isWhitespace }),
               let b = text.lastIndex(where: { !$0.isWhitespace }), a < b {
                first = (try? c.boundingBox(for: a..<text.index(after: a)))?.boundingBox
                last = (try? c.boundingBox(for: b..<text.index(after: b)))?.boundingBox
            }
            return Line(text: text, confidence: c.confidence, boundingBox: o.boundingBox, bottomLeft: o.bottomLeft,
                        bottomRight: o.bottomRight, firstCharacter: first, lastCharacter: last)
        }
    }

    init(width: Int, height: Int, lines: [Line]) {
        self.width = width
        self.height = height
        self.lines = lines
    }
}

final class PageVisionCache: @unchecked Sendable {
    static let shared = PageVisionCache()

    /// A page file as it is now. Two reads of the same unchanged file give the same identity; a rewrite does not.
    struct FileIdentity: Hashable, Sendable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        /// nil when the file cannot be read: the pass then runs uncached.
        init?(_ url: URL) {
            var st = stat()
            guard url.isFileURL, stat(url.path, &st) == 0 else { return nil }
            path = url.standardizedFileURL.path
            device = UInt64(st.st_dev)
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            modifiedSeconds = Int(st.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int(st.st_mtimespec.tv_nsec)
        }
    }

    struct Key: Hashable, Sendable {
        let file: FileIdentity
        /// The clockwise turn applied to the upright image before Vision read it.
        let rotation: Int
        /// The pass and every request setting that changes its result.
        let profile: String
    }

    /// Bounded so a long run cannot grow it without limit; the oldest result goes first. A run reads each page's
    /// passes within a few minutes, so a few hundred pages' worth is enough to catch every repeat.
    let capacity: Int
    private let lock = NSLock()
    private var done: [Key: any Sendable] = [:]
    private var order: [Key] = []
    private var running: [Key: Task<any Sendable, Never>] = [:]
    private var counts = Counts()

    struct Counts: Equatable, Sendable {
        var computed = 0
        var reused = 0
    }

    init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    /// The key for `url` read at `rotation` degrees clockwise with `profile`, or nil when the file cannot be stat'ed.
    static func key(_ url: URL, rotation: Int = 0, profile: String) -> Key? {
        FileIdentity(url).map { Key(file: $0, rotation: ((rotation % 360) + 360) % 360, profile: profile) }
    }

    /// The pass's result: an earlier one for the same key, the one in flight, or `compute`'s. With no key (the file
    /// could not be stat'ed) it just computes. Every completed result is kept, nil answers included: the same file,
    /// pass and turn give the same answer. `keeps` false (a request that failed and may not fail again) hands the result
    /// to the callers waiting on this pass without keeping it.
    func value<T: Sendable>(_ key: Key?, keeps: @escaping @Sendable (T) -> Bool = { _ in true },
                            compute: @escaping @Sendable () async -> T) async -> T {
        guard let key else { return await compute() }
        let step: (hit: T?, task: Task<any Sendable, Never>?) = lock.withLock {
            // Unwrap the entry before the cast: a missing entry cast to an Optional T would read as a nil answer.
            if let stored = done[key], let hit = stored as? T {
                counts.reused += 1
                return (hit, nil)
            }
            if let inFlight = running[key] {
                counts.reused += 1
                return (nil, inFlight)
            }
            counts.computed += 1
            // Detached: the pass belongs to no caller, so one caller's cancellation or actor does not reach the others.
            let t = Task<any Sendable, Never>.detached(priority: Task.currentPriority) { await compute() }
            running[key] = t
            return (nil, t)
        }
        guard let task = step.task else { return step.hit! }
        let result = await task.value
        lock.withLock {
            if running[key] == task {
                running[key] = nil
                guard let typed = result as? T, keeps(typed) else { return }
                if done[key] == nil { order.append(key) }
                done[key] = result
                while order.count > capacity { done[order.removeFirst()] = nil }
            }
        }
        // The only writer for a key is `compute`, which returns T, so this cast holds; recompute rather than trap.
        if let typed = result as? T { return typed }
        return await compute()
    }

    /// How many passes ran and how many were answered from an earlier one (the regression's evidence).
    var statistics: Counts { lock.withLock { counts } }

    /// Test seam: start empty.
    func removeAll() {
        lock.withLock {
            done = [:]; order = []; running = [:]; counts = Counts()
        }
    }
}
