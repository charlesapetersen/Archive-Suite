import Foundation

// MARK: - Reading through the Claude plan: waiting out its usage limit (W41.app-claude-plan-reading)
//
// The plan's five-hour and weekly windows are a limit, not a price. When `claude -p` says the limit is reached, the
// page waits for the reset the CLI printed and is read on the plan again (`LocalAgentClient.invokePaced`); a long
// batch therefore pauses and resumes by itself, and nothing falls back to a billed key. The segmentation windows stop
// the run instead (`PlanRunGate`), because a stage that has not started can be resumed later as a whole.

/// When a page waiting for the plan's window tries again.
struct UsageWindowPacing: Sendable {
    /// Past the reset the CLI printed, so the first call after it lands in the new window.
    var grace: TimeInterval
    /// No reset time printed: how long before trying the plan again.
    var unknownWait: TimeInterval
    /// The shortest wait, so a reset already past (a clock the CLI rounds) never becomes a tight loop of calls.
    var minimumWait: TimeInterval
    /// The longest single sleep: a Mac that slept through the reset wakes to it within this.
    var tick: TimeInterval

    static let standard = UsageWindowPacing(grace: 60, unknownWait: 15 * 60, minimumWait: 30, tick: 30)

    func resumeAt(reset: Date?, now: Date) -> Date {
        guard let reset else { return now.addingTimeInterval(max(unknownWait, minimumWait)) }
        return max(reset.addingTimeInterval(grace), now.addingTimeInterval(minimumWait))
    }

    /// Sleeps until `until` by the wall clock, in ticks. False when the task was cancelled (the run was stopped).
    func wait(until: Date) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let left = until.timeIntervalSinceNow
            if left <= 0 { return true }
            do {
                try await Task.sleep(nanoseconds: UInt64(min(left, max(tick, 0.05)) * 1_000_000_000))
            } catch {
                return false
            }
        }
    }
}

/// The pages now waiting for the plan's window, app-wide, so the status line can say the run is paused and when it
/// goes on. Each waiting call registers itself; the latest of their resume times is the one shown.
final class UsageWindowPause: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [UUID: Date] = [:]

    func begin(_ id: UUID, until: Date) {
        lock.lock(); waits[id] = until; lock.unlock()
    }

    func end(_ id: UUID) {
        lock.lock(); waits[id] = nil; lock.unlock()
    }

    var until: Date? {
        lock.lock(); defer { lock.unlock() }
        return waits.values.max()
    }

    /// The status line while paused, nil when no page is waiting.
    func message(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let until else { return nil }
        var when = LocalAgentClient.usageWindowHint(for: until, now: now, calendar: calendar)
        // The weekly window can reset days ahead: then say the day as well.
        if !calendar.isDate(until, inSameDayAs: now) {
            let day = DateFormatter()
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "EEE d MMM"
            when = "on \(day.string(from: until)) \(when)"
        }
        return "Paused: your Claude plan's usage limit is reached. Reading goes on with the plan \(when); "
            + "nothing is sent to a key. Stop keeps the run, to resume later."
    }
}
