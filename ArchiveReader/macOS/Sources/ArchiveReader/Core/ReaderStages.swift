import Foundation
import os

/// Named intervals around the stages one library change sets off (W40.reader-scale-measure).
///
/// Each stage is an `os_signpost` interval in the `com.archivereader.app` / `Stages` log, so Instruments'
/// Points of Interest and `xctrace` show the chain behind a stall in the running app. The at-size lane
/// (`ReaderAtSizeTests`) also turns the in-process recorder on, which totals each stage's wall time per
/// thread kind; with it off, a stage costs the signposter's enabled check and nothing else.
enum ReaderStages {
    static let signposter = OSSignposter(subsystem: "com.archivereader.app", category: "Stages")
    static let recorder = StageRecorder()

    /// Run `body` as the stage `name`.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = recorder.isRecording ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            signposter.endInterval(name, state)
            if start != 0 { recorder.add(name, nanoseconds: DispatchTime.now().uptimeNanoseconds - start) }
        }
        return try body()
    }
}

/// Per-stage totals for the at-size lane. Locked: stages run on the main actor and off it.
final class StageRecorder: @unchecked Sendable {
    struct Total: Equatable, Sendable {
        var count = 0
        var nanoseconds: UInt64 = 0
        var maxNanoseconds: UInt64 = 0
    }
    /// A stage's totals, keyed by its name and whether it ran on the main thread.
    struct Key: Hashable, Sendable { let stage: String; let onMain: Bool }

    private let lock = NSLock()
    private var recording = false
    private var totals: [Key: Total] = [:]
    private var lastEnd: UInt64 = 0

    var isRecording: Bool { lock.withLock { recording } }

    /// Clear the totals and start (or stop) recording.
    func reset(recording on: Bool) {
        lock.withLock { recording = on; totals = [:]; lastEnd = 0 }
    }

    func add(_ name: StaticString, nanoseconds: UInt64) {
        let key = Key(stage: "\(name)", onMain: Thread.isMainThread)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            guard recording else { return }
            var total = totals[key, default: Total()]
            total.count += 1
            total.nanoseconds += nanoseconds
            total.maxNanoseconds = max(total.maxNanoseconds, nanoseconds)
            totals[key] = total
            lastEnd = max(lastEnd, now)
        }
    }

    /// The totals so far, and the uptime at which the latest stage ended (0 if none has).
    func snapshot() -> (totals: [Key: Total], lastEnd: UInt64) {
        lock.withLock { (totals, lastEnd) }
    }
}
