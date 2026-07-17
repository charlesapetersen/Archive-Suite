#!/usr/bin/env swift
import Foundation

// Standalone, $0, no-GUI, no-network, no-real-CLI test of the LocalAgent PACING logic (W13.cli-3):
//   (1) LocalAgentClient.parseUsageWindowReset — CLI rate-limit message → the reset instant a bulk run
//       paces to (relative "in 45 minutes" / bare Retry-After / absolute "resets 3pm"), incl. the
//       window-size-vs-wait guard ("5-hour limit reached, resets 3pm" ⇒ absolute 3pm, not +5h) and the
//       next-occurrence rollover; plus usageWindowHint formatting;
//   (2) the dedicated concurrency ceiling: RequestLimiter(limit: 2) — the limiter LocalAgentClient wraps
//       `invoke` in so the subprocess path (which bypasses NetworkSession's HTTP limiter) never runs more
//       than 2 CLI children at once, and every acquire is balanced by a release (no slot leak / deadlock).
//
// The parser + RequestLimiter below are COPIES of the app types (OCR/LocalAgentClient.swift,
// OCR/NetworkSession.swift). If you change one, change both. Run:
//   swift ArchiveProcessor/scripts/localagent-pacing-test.swift

// ===================================================================================================
// COPY of LocalAgentClient's usage-window parser (OCR/LocalAgentClient.swift). Keep in sync.
func parseUsageWindowReset(fromStderr stderr: String, now: Date, calendar: Calendar = .current) -> Date? {
    let s = stderr.lowercased()
    if let secs = relativeResetSeconds(in: s), secs > 0 { return now.addingTimeInterval(secs) }
    if let (hour, minute) = absoluteResetClock(in: s) { return nextOccurrence(hour: hour, minute: minute, at: now, calendar: calendar) }
    return nil
}

func usageWindowHint(for reset: Date, now: Date, calendar: Calendar = .current) -> String {
    let fmt = DateFormatter()
    fmt.calendar = calendar
    fmt.timeZone = calendar.timeZone
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "h:mm a"
    return "around \(fmt.string(from: reset))"
}

let relativeResetTriggers = [
    "resets in", "reset in", "resetting in", "try again in", "retry in", "retry after",
    "available again in", "available in", "again in", "back in", "wait about", "in about",
]

func relativeResetSeconds(in s: String) -> Double? {
    var anchor: String.Index?
    for t in relativeResetTriggers {
        if let r = s.range(of: t), anchor == nil || r.upperBound < anchor! { anchor = r.upperBound }
    }
    guard let start = anchor else { return nil }
    let tail = String(s[start...])
    let ns = tail as NSString
    let full = NSRange(location: 0, length: ns.length)

    var total = 0.0
    var matched = false
    if let re = try? NSRegularExpression(pattern: #"(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|days?|d)\b"#) {
        for match in re.matches(in: tail, range: full) {
            guard let n = Double(ns.substring(with: match.range(at: 1))) else { continue }
            switch ns.substring(with: match.range(at: 2)).first {
            case "h": total += n * 3600;  matched = true
            case "m": total += n * 60;    matched = true
            case "s": total += n;         matched = true
            case "d": total += n * 86400; matched = true
            default:  break
            }
        }
    }
    if matched { return total }

    if let re = try? NSRegularExpression(pattern: #"^\s*(\d+)\b"#),
       let m = re.firstMatch(in: tail, range: full),
       let n = Double(ns.substring(with: m.range(at: 1))) {
        return n
    }
    return nil
}

func absoluteResetClock(in s: String) -> (hour: Int, minute: Int)? {
    guard let re = try? NSRegularExpression(
        pattern: #"(?:reset(?:s|ting)?|again|available|back)\s*(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#)
    else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
          var hour = Int(ns.substring(with: m.range(at: 1))) else { return nil }
    let minute = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
    let ampm = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
    if ampm == "pm" && hour < 12 { hour += 12 }
    if ampm == "am" && hour == 12 { hour = 0 }
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    return (hour, minute)
}

func nextOccurrence(hour: Int, minute: Int, at now: Date, calendar: Calendar) -> Date? {
    var comps = calendar.dateComponents([.year, .month, .day], from: now)
    comps.hour = hour; comps.minute = minute; comps.second = 0
    guard let candidate = calendar.date(from: comps) else { return nil }
    if candidate > now { return candidate }
    return calendar.date(byAdding: .day, value: 1, to: candidate)
}

// COPY of RequestLimiter (OCR/NetworkSession.swift). Keep in sync — this is the exact limiter
// LocalAgentClient instantiates at limit 2 for the CLI subprocess path.
actor RequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Never>)] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if active < limit { active += 1; return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in waiters.append((id, cont)) }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().cont.resume() }
        else { active = max(0, active - 1) }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: idx); active += 1; w.cont.resume()
    }
}

// ===================================================================================================
// Test harness.
var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

// Deterministic clock: fixed UTC calendar + fixed `now` = 2001-09-09 01:46:40 UTC.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
let now = Date(timeIntervalSince1970: 1_000_000_000)

print("parseUsageWindowReset — relative:")
let relatives: [(String, Double)] = [
    ("Claude usage limit reached. Try again in 45 minutes.", 2700),
    ("rate limit exceeded; retry after 30s", 30),
    ("You've hit your limit — resets in 2h 13m.", 7980),
    ("quota exceeded — retry after 120", 120),                       // bare Retry-After seconds
    ("limit reached, available again in 1 hour 30 minutes", 5400),
    ("slow down — in about 3 hours you'll be back", 10800),
]
for (msg, want) in relatives {
    let d = parseUsageWindowReset(fromStderr: msg, now: now, calendar: cal)
    let got = d?.timeIntervalSince(now)
    check("\"\(msg.prefix(38))…\" → +\(Int(want))s", got != nil && abs(got! - want) < 1,
          "got \(got.map { "+\(Int($0))s" } ?? "nil")")
}

print("parseUsageWindowReset — absolute clock (next occurrence at/after now):")
// now is 01:46 UTC. 3pm/22:59/15:00 are later today; 1am already passed ⇒ tomorrow.
let absolutes: [(String, Int, Int, Bool)] = [
    ("5-hour limit reached ∙ resets 3pm", 15, 0, false),            // window size NOT read as +5h
    ("Your limit will reset at 10:59pm.", 22, 59, false),
    ("resets at 15:00", 15, 0, false),
    ("resets at 1am", 1, 0, true),                                  // rolls to tomorrow
]
for (msg, wantH, wantM, wantTomorrow) in absolutes {
    guard let d = parseUsageWindowReset(fromStderr: msg, now: now, calendar: cal) else {
        check("\"\(msg.prefix(38))…\" parses", false, "got nil"); continue
    }
    let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
    // Compare the calendar DAY, not complete-24h deltas: a tomorrow-01:00 reset is only ~23h after a
    // now-01:46, so a `.day` delta would read 0 even though it correctly rolled to the next day.
    let rolled = !cal.isDate(d, inSameDayAs: now)
    check("\"\(msg.prefix(30))…\" → \(wantH):\(String(format: "%02d", wantM))\(wantTomorrow ? " (+1d)" : "")",
          h == wantH && m == wantM && d > now && rolled == wantTomorrow,
          "got \(h):\(String(format: "%02d", m)) rolled=\(rolled)")
}

print("parseUsageWindowReset — no reset stated ⇒ nil:")
for msg in ["", "5-hour limit reached", "some unrelated error: file not found", "rate limited"] {
    check("\"\(msg.prefix(38))\" → nil", parseUsageWindowReset(fromStderr: msg, now: now, calendar: cal) == nil)
}

print("usageWindowHint:")
let reset3pm = parseUsageWindowReset(fromStderr: "resets at 3:15pm", now: now, calendar: cal)!
check("hint(3:15pm) == \"around 3:15 PM\"", usageWindowHint(for: reset3pm, now: now, calendar: cal) == "around 3:15 PM",
      "got \"\(usageWindowHint(for: reset3pm, now: now, calendar: cal))\"")

// ---------------------------------------------------------------------------------------------------
// Concurrency ceiling: limit 2 must never be exceeded, and every acquire must be released (no leak).
func runAsyncTest(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    _ = sem.wait(timeout: .now() + 15)   // if slots leaked, later tasks would hang → timeout → visible fail
}

print("RequestLimiter(limit: 2) ceiling:")
final class Peak: @unchecked Sendable {   // observe max simultaneous holders across tasks
    private let lock = NSLock(); private var live = 0; private(set) var max = 0; private(set) var done = 0
    func enter() { lock.lock(); live += 1; if live > max { max = live }; lock.unlock() }
    func leave() { lock.lock(); live -= 1; done += 1; lock.unlock() }
}
let peak = Peak()
runAsyncTest {
    let limiter = RequestLimiter(limit: 2)
    // Two rounds prove slots are released between them (round 2 would hang if release were unbalanced).
    for _ in 0..<2 {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await limiter.acquire()
                    peak.enter()
                    try? await Task.sleep(nanoseconds: 40_000_000)   // 40ms — force genuine overlap
                    peak.leave()
                    await limiter.release()
                }
            }
        }
    }
}
check("never exceeded 2 concurrent CLI calls", peak.max <= 2, "peak was \(peak.max)")
check("did gate (≥2 overlapped, not serialized)", peak.max >= 2, "peak was \(peak.max)")
check("all 12 acquires released (no leak/deadlock)", peak.done == 12, "completed \(peak.done)/12")

print("\n\(fail == 0 ? "ALL PASS" : "SOME FAILED") (\(pass) pass, \(fail) fail)")
exit(fail == 0 ? 0 : 1)
