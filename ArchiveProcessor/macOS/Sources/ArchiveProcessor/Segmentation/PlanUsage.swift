import Foundation

// MARK: - The Claude plan route: its meter, calibration and pauses (W36.seg-opt-subscription)
//
// Spec: `ArchiveProcessor/segbench-results/usage.md` ("How the app shows it") and
// execution-plans/segmentation/04-options-build.md Part 3 §4. The meter is the `rate_limit_event` that
// `claude -p --output-format stream-json` prints on every call: the account's five-hour and weekly utilization, in
// whole percent. The app never reads the CLI's login (usage.md, condition 2), so this stream is the only meter it has.
// Because the meter is whole-percent, a share is measured as a ratio, meter points per notional dollar (each call's
// `total_cost_usd`, what the same calls would cost at API list price), and a folder is scaled by its notional dollars.

/// Which way Claude's windows are paid for, when the user has both an Anthropic key and `claude`. Asked only then;
/// with one of the two, that one is used.
enum ClaudeRoute: String, CaseIterable, Sendable {
    case apiKey
    case plan

    static func stored(_ defaults: UserDefaults = .standard) -> ClaudeRoute {
        defaults.string(forKey: DefaultsKeys.segmentationClaudeRoute).flatMap(ClaudeRoute.init(rawValue:)) ?? .apiKey
    }
}

/// The account's meter as one call reported it. Utilization is a fraction (0.27 is 27%).
struct PlanMeterReading: Sendable, Equatable, Codable {
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
}

/// One `claude -p --output-format stream-json --verbose` call's output, read.
struct ClaudeStreamOutput {
    /// The final `result` event: the envelope `--output-format json` prints (`subtype`, `is_error`, `result`,
    /// `total_cost_usd`).
    var envelope: [String: Any]?
    /// The call's last `rate_limit_event`, nil when the CLI printed none (an older CLI, or an API-key login).
    var meter: PlanMeterReading?

    var notionalUSD: Double? { (envelope?["total_cost_usd"] as? NSNumber)?.doubleValue }

    static func parse(_ stdout: String) -> ClaudeStreamOutput {
        var out = ClaudeStreamOutput()
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let ev = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch ev["type"] as? String {
            case "rate_limit_event": if let m = meter(ev) { out.meter = m }
            case "result": out.envelope = ev
            default: break
            }
        }
        // A CLI that printed one JSON envelope instead of the stream.
        if out.envelope == nil,
           let whole = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any],
           whole["result"] != nil {
            out.envelope = whole
        }
        return out
    }

    /// `rate_limit_info.unifiedWindows.{five_hour,seven_day}.{utilization,resetsAt}` (resetsAt in Unix seconds).
    static func meter(_ ev: [String: Any]) -> PlanMeterReading? {
        guard let info = ev["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return nil }
        func window(_ k: String) -> (Double?, Date?) {
            let w = windows[k] as? [String: Any]
            return ((w?["utilization"] as? NSNumber)?.doubleValue,
                    (w?["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let (f, fr) = window("five_hour")
        let (s, sr) = window("seven_day")
        guard f != nil || s != nil else { return nil }
        return PlanMeterReading(fiveHour: f, sevenDay: s, fiveHourResetsAt: fr, sevenDayResetsAt: sr)
    }
}

/// One finished `claude` window call, in the order the calls finished.
struct PlanCallRecord: Sendable, Equatable {
    let meter: PlanMeterReading?
    let notionalUSD: Double
    /// The run's pages this call stands for: the windows' stride when it answered, 0 when it failed (a retry
    /// covers the same pages).
    let pages: Int
}

/// One run's ratio, kept to estimate later folders.
struct PlanRunSample: Sendable, Equatable, Codable {
    let fiveHourPointsPerUSD: Double
    /// Whole points the weekly meter moved over the same stretch.
    let sevenDayPoints: Int
    let notionalUSD: Double
    let pages: Int
    let measured: Date

    /// The weekly ratio, once the stretch crossed enough weekly points to read it (usage.md step 6).
    var sevenDayPointsPerUSD: Double? {
        sevenDayPoints >= PlanCalibration.crossPoints ? Double(sevenDayPoints) / notionalUSD : nil
    }
    /// What the weekly ratio is at most: a whole-percent meter that moved d points moved less than d + 1.
    var sevenDayBoundPerUSD: Double { Double(sevenDayPoints + 1) / notionalUSD }
}

enum PlanMeasurement: Equatable {
    /// Not enough calls or pages yet.
    case notYet
    /// Three calls and not one meter: the fallback figures only.
    case unreadable
    case measured(PlanRunSample)
    /// `maxPages` pages done and the five-hour meter has not moved `crossPoints` (usage.md step 4).
    case underThreshold(pages: Int)
    /// The meter cannot be trusted for this run (usage.md step 7).
    case discarded(String)
}

enum PlanCalibration {
    /// usage.md step 3: measure once the five-hour meter has moved this many points, or after `maxPages`.
    static let crossPoints = 3
    static let maxPages = 100
    /// usage.md "Limits": pause when the five-hour meter reaches this.
    static let pausePercent = 90
    /// The calls in flight at once (the engine's `maxConcurrent`): a meter step can include their use.
    static let inFlight = 3.0

    static func points(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

    /// The ratio over `records` (usage.md steps 1–4 and 7). The first reading is the baseline; the notional
    /// dollars that explain a later reading are those of the calls that finished before it.
    static func measure(_ records: [PlanCallRecord], now: Date = Date()) -> PlanMeasurement {
        let read = records.indices.filter { records[$0].meter?.fiveHour != nil }
        let pages = records.reduce(0) { $0 + $1.pages }
        guard let first = read.first else {
            return records.count >= 3 ? .unreadable : .notYet
        }
        func raw(_ i: Int) -> Int { points(records[i].meter!.fiveHour!) }
        func usd(_ a: Int, _ b: Int) -> Double { records[a..<b].reduce(0) { $0 + $1.notionalUSD } }

        // Rule 7: a window reset. Records are in the order calls FINISHED, but each carries the meter as it stood
        // while that call ran, so with calls in flight together a reading one point below the one before is
        // ordinary. A reset is a new reset time, or a drop of 2 points or more below the highest reading so far.
        var peak: [Int: Int] = [:]   // the running maximum, per reading
        var high = raw(first)
        for i in read {
            if raw(i) <= high - 2 || resetMoved(records[first].meter?.fiveHourResetsAt, records[i].meter?.fiveHourResetsAt) {
                return .discarded("the five-hour window reset during the measurement")
            }
            high = max(high, raw(i))
            peak[i] = high
        }
        func five(_ i: Int) -> Int { peak[i]! }
        // The stretch ends at the first reading of the highest level, so its dollars are the calls before it.
        let last = read.first { peak[$0] == high }!
        let moved = five(last) - five(first)
        let dollars = usd(first, last)
        guard moved >= crossPoints, dollars > 0 else {
            return pages >= maxPages ? .underThreshold(pages: pages) : .notYet
        }
        let ratio = Double(moved) / dollars
        // Rule 7: a step faster than the calls explain is other use of the account. Each step is judged by the
        // rest of the run (so a jump cannot vouch for itself), with the rest's points taken as at least 1 for the
        // meter's whole-percent resolution. A step can include the calls still in flight, so it is allowed their
        // cost too, then three times that, and never less than 2 points.
        let meanCall = dollars / Double(max(1, last - first))
        for (a, b) in zip(read, read.dropFirst()) {
            let step = five(b) - five(a)
            let restUSD = dollars - usd(a, b)
            guard step > 2, restUSD > 0 else { continue }
            let restRatio = Double(max(1, moved - step)) / restUSD
            if Double(step) > max(2, 3 * restRatio * (usd(a, b) + inFlight * meanCall)) {
                return .discarded("the meter moved faster than these calls explain (other use of the account)")
            }
        }
        // The weekly meter over the same stretch, read the same way.
        var weekly = 0
        if let w0 = records[first].meter?.sevenDay {
            var weekHigh = points(w0)
            for i in read where i <= last {
                guard let w = records[i].meter?.sevenDay else { continue }
                if points(w) <= weekHigh - 2
                    || resetMoved(records[first].meter?.sevenDayResetsAt, records[i].meter?.sevenDayResetsAt) {
                    return .discarded("the weekly window reset during the measurement")
                }
                weekHigh = max(weekHigh, points(w))
            }
            weekly = weekHigh - points(w0)
        }
        return .measured(PlanRunSample(fiveHourPointsPerUSD: ratio, sevenDayPoints: weekly, notionalUSD: dollars,
                                       pages: pages, measured: now))
    }

    /// A window's reset time moved on (by more than five minutes, which absorbs any rounding in the CLI's figure).
    static func resetMoved(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(b.timeIntervalSince(a)) > 300
    }
}

/// The ratios measured on this account, under `DefaultsKeys.segmentationPlanCalibration`. Not keyed by plan, because
/// the CLI does not name one: a change of plan shows as a ratio that moves, and the median of the last few runs
/// follows it (04-options-build.md Part 3 §4).
struct PlanCalibrationStore: Sendable, Equatable, Codable {
    var samples: [PlanRunSample] = []

    static let keep = 5

    var fiveHourPointsPerUSD: Double? { Self.median(samples.map(\.fiveHourPointsPerUSD)) }
    var sevenDayPointsPerUSD: Double? { Self.median(samples.compactMap(\.sevenDayPointsPerUSD)) }
    /// The tightest weekly bound any run gives, used until a run reads the weekly ratio itself.
    var sevenDayBoundPerUSD: Double? { samples.map(\.sevenDayBoundPerUSD).min() }
    var lastMeasured: Date? { samples.map(\.measured).max() }

    mutating func add(_ s: PlanRunSample) {
        samples.append(s)
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func load(_ defaults: UserDefaults = .standard) -> PlanCalibrationStore {
        guard let data = defaults.data(forKey: DefaultsKeys.segmentationPlanCalibration),
              let store = try? JSONDecoder().decode(PlanCalibrationStore.self, from: data) else { return .init() }
        return store
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: DefaultsKeys.segmentationPlanCalibration)
        }
    }

    /// After a run on the plan: keep its ratio if it crossed the threshold and the meter can be trusted
    /// (usage.md steps 5 and 7). Returns what it measured.
    @discardableResult
    static func recordRun(_ records: [PlanCallRecord], defaults: UserDefaults = .standard,
                          now: Date = Date()) -> PlanMeasurement {
        let m = PlanCalibration.measure(records, now: now)
        if case .measured(let s) = m {
            var store = load(defaults)
            store.add(s)
            store.save(defaults)
        }
        return m
    }

    /// "about 5% of a five-hour window, about 1% of your week" for `notionalUSD` of calls, or nil before any run
    /// has been measured.
    func estimate(notionalUSD: Double) -> String? {
        guard let five = fiveHourPointsPerUSD else { return nil }
        return PlanShareText.share(fiveHourPoints: five * notionalUSD,
                                   weekPoints: sevenDayPointsPerUSD.map { $0 * notionalUSD },
                                   weekBound: sevenDayBoundPerUSD.map { $0 * notionalUSD })
    }
}

enum PlanShareText {
    /// A meter point is one percent of the window.
    static func fiveHour(_ points: Double) -> String {
        if points < 1 { return "under 1% of a five-hour window" }
        if points >= 100 { return "about \(SegmentationRow.twoSignificant(points / 100)) five-hour windows" }
        return "about \(Int(points.rounded()))% of a five-hour window"
    }

    static func week(points: Double?, bound: Double?) -> String? {
        if let p = points { return p < 1 ? "under 1% of your week" : "about \(Int(p.rounded()))% of your week" }
        if let b = bound { return "under about \(max(1, Int(b.rounded(.up))))% of your week" }
        return nil
    }

    static func share(fiveHourPoints: Double, weekPoints: Double?, weekBound: Double?) -> String {
        [fiveHour(fiveHourPoints), week(points: weekPoints, bound: weekBound)].compactMap { $0 }
            .joined(separator: ", ")
    }

    static func measuredDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = .current
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

/// The question asked once, the first time the plan route runs on an account (usage.md step 3).
struct PlanCheckPrompt: Equatable, Sendable {
    let message: String
}

/// One run's meter, and the two places it stops the windows: the first measurement, when no ratio is stored yet
/// (the user is asked whether to go on), and the five-hour meter at 90% (the run pauses and says when the window
/// resets). Every `claude` window call passes through `beforeCall` and `record`.
actor PlanRunGate {
    private let pagesPerCall: Int
    private let folderNotionalUSD: Double
    /// A ratio is stored, so the estimate was shown up front and there is no pause to measure.
    private let calibrated: Bool
    private let ask: @Sendable (PlanCheckPrompt) async -> Bool

    private(set) var records: [PlanCallRecord] = []
    private var checked = false
    private var asking: Task<Bool, Never>?
    private var stopped: WindowTransportError?

    /// The voter whose answered windows count the pages measured: with two Claude voters each window is sent twice,
    /// and counting both would reach usage.md's 100 pages at 50. nil counts every call.
    private let pageVoter: String?

    init(pagesPerCall: Int, folderNotionalUSD: Double, calibrated: Bool, pageVoter: String? = nil,
         ask: @escaping @Sendable (PlanCheckPrompt) async -> Bool) {
        self.pagesPerCall = pagesPerCall
        self.pageVoter = pageVoter
        self.folderNotionalUSD = folderNotionalUSD
        self.calibrated = calibrated
        self.ask = ask
    }

    func record(meter: PlanMeterReading?, notionalUSD: Double, answered: Bool, voter: String? = nil) {
        let counts = answered && (pageVoter == nil || voter == pageVoter)
        records.append(PlanCallRecord(meter: meter, notionalUSD: notionalUSD, pages: counts ? pagesPerCall : 0))
    }

    /// Waits for `task` (the question), cancelling it if the calling window is cancelled, so a run stopped while
    /// the question is on its way never leaves the user a dialog for a run that is gone.
    private func wait(_ task: Task<Bool, Never>) async throws {
        _ = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
    }

    /// Before each call: throws `WindowTransportError.paused` when the run should stop here.
    func beforeCall() async throws {
        if let stopped { throw stopped }
        // While the user is being asked, no further window is sent.
        if let asking {
            try await wait(asking)
            if let stopped { throw stopped }
        }
        // The highest reading, not the latest: calls finish out of order, so the latest can be an older figure.
        if let m = records.compactMap(\.meter).filter({ $0.fiveHour != nil }).max(by: { $0.fiveHour! < $1.fiveHour! }),
           let f = m.fiveHour, PlanCalibration.points(f) >= PlanCalibration.pausePercent {
            let e = WindowTransportError.paused(
                reset: m.fiveHourResetsAt,
                message: "Your Claude plan's five-hour window is at \(PlanCalibration.points(f))%, so segmentation "
                    + "paused before it runs out.")
            stopped = e
            throw e
        }
        guard !calibrated, !checked else { return }
        let message: String
        switch PlanCalibration.measure(records) {
        case .notYet:
            return
        case .unreadable, .discarded:
            // Nothing to show that the up-front notional line did not already say; the run goes on.
            checked = true
            return
        case .measured(let s):
            message = "Measured on your account over the first \(s.pages) pages, this folder uses "
                + PlanShareText.share(fiveHourPoints: s.fiveHourPointsPerUSD * folderNotionalUSD,
                                      weekPoints: s.sevenDayPointsPerUSD.map { $0 * folderNotionalUSD },
                                      weekBound: s.sevenDayBoundPerUSD * folderNotionalUSD) + "."
        case .underThreshold(let pages):
            message = "Measured on your account over the first \(pages) pages: under about "
                + "\(PlanCalibration.crossPoints)% of a five-hour window per 100 pages."
        }
        // A cancelled run never shows the question.
        try Task.checkCancellation()
        checked = true
        let ask = self.ask
        let task = Task { () -> Bool in
            let goOn = await ask(PlanCheckPrompt(message: message))
            if !goOn && !Task.isCancelled {
                self.stopAfterCheck()
            }
            return goOn
        }
        asking = task
        defer { asking = nil }
        try await wait(task)
        if let stopped { throw stopped }
    }

    private func stopAfterCheck() {
        stopped = .paused(reset: nil, message: "You chose to stop after the first measurement of your Claude plan.")
    }
}
