import Foundation

// MARK: - Reading through the Claude plan: waiting for its usage window (W49.proc-plan-read-meter)
//
// A page waits for the reset when the five-hour meter reaches 90% or the CLI reports a hard limit.
// Reading resumes on the plan, using the same pause threshold as the segmentation windows (PlanRunGate).

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
    struct Wait: Sendable {
        let until: Date
        var fiveHourPercent: Int? = nil
    }

    private let lock = NSLock()
    private var waits: [UUID: Wait] = [:]

    func begin(_ id: UUID, wait: Wait) {
        lock.lock(); waits[id] = wait; lock.unlock()
    }

    func end(_ id: UUID) {
        lock.lock(); waits[id] = nil; lock.unlock()
    }

    var until: Date? { latest?.until }

    private var latest: Wait? {
        lock.lock(); defer { lock.unlock() }
        return waits.values.max { $0.until < $1.until }
    }

    /// The status line while paused, nil when no page is waiting.
    func message(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let wait = latest else { return nil }
        let until = wait.until
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
        let reason = wait.fiveHourPercent.map { "your Claude plan's five-hour window is at \($0)%." }
            ?? "your Claude plan's usage limit is reached."
        return "Paused: \(reason) Reading goes on with the plan \(when); "
            + "nothing is sent to a key. Stop keeps the run, to resume later."
    }
}
