#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation

/// Headless, $0 self-test of the Claude plan route (W36.seg-opt-subscription), gated by `SEGMENTATION_PLAN_TEST=1`
/// (does nothing in normal use). No model call and no real plan use: every `claude` is the committed fake CLI
/// (`scripts/localagent-fake-cli.sh`, path in `LOCALAGENT_FAKE_CLI`), and the calibration is kept in a scratch
/// defaults suite, never the app's own. Run by `scripts/test-segmentation-plan.sh`.
///
/// What has to be true:
///   1. The stream is read: the meter from `rate_limit_event` (a line the real CLI printed), the envelope and the
///      notional dollars from the `result` event, and a CLI that printed one JSON envelope still works.
///   2. The calibration follows usage.md: not yet, unreadable, measured (points per notional dollar, the weekly
///      bound), under 3 points in 100 pages, and discarded when the meter goes backwards or jumps.
///   3. The store keeps the median of the last five runs; the share reads as usage.md words it.
///   4. The chooser's plan line: notional before any run, the measured share after one; the route chosen only
///      when both a key and `claude` exist; the run's transport follows the same route.
///   5. Against the fake CLI: the first measurement asks once and goes on, or stops resumably when declined; the
///      five-hour meter at 90% pauses with the reset time; no meter means no question.
///   6. Cancelling stops the `claude` children (the window call and a whole engine run), a cancelled call never
///      spawns, and a child that exits without reading its stdin cannot take the app down with SIGPIPE.
@MainActor
enum SegmentationPlanTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENTATION_PLAN_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    private static let started = Date()

    /// Each section's elapsed time, written as it goes, so a run that times out shows where it was.
    private static func section(_ name: String) {
        lines.append(String(format: "-- %@ (%.1f s)", name, Date().timeIntervalSince(started)))
        let out = ProcessInfo.processInfo.environment["SEGMENTATION_PLAN_TEST_OUT"] ?? "/tmp/segmentation-plan-test.txt"
        try? lines.joined(separator: "\n").appending("\n").write(toFile: out + ".partial", atomically: true, encoding: .utf8)
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        let out = ProcessInfo.processInfo.environment["SEGMENTATION_PLAN_TEST_OUT"] ?? "/tmp/segmentation-plan-test.txt"
        try? lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    private static func record(_ five: Double?, _ week: Double? = nil, usd: Double = 0.25, pages: Int = 3)
        -> PlanCallRecord {
        PlanCallRecord(meter: five.map { PlanMeterReading(fiveHour: $0, sevenDay: week) }, notionalUSD: usd,
                       pages: pages)
    }

    private static let day = Date(timeIntervalSince1970: 1_791_720_000)   // 11 Oct 2026, midday UTC

    static func run() async {
        defer { finish() }
        section("stream"); stream()
        section("calibration"); calibration()
        section("store"); store()
        section("chooser"); chooser()
        guard let fake = ProcessInfo.processInfo.environment["LOCALAGENT_FAKE_CLI"],
              FileManager.default.isExecutableFile(atPath: fake) else {
            check("LOCALAGENT_FAKE_CLI is the fake CLI (run via scripts/test-segmentation-plan.sh)", false)
            return
        }
        section("gate"); await gateUnit()
        section("fake runs"); await fakeRuns(fake)
        section("cancellation"); await cancellation(fake)
        section("done")
        unsetenv("LOCALAGENT_FAKE_MODE")
        unsetenv("LOCALAGENT_FAKE_METER_DIR")
        unsetenv("LOCALAGENT_FAKE_PID_DIR")
    }

    // MARK: 1. The stream

    private static func stream() {
        // Printed by the real `claude -p --output-format stream-json --verbose` on 2026-10-11 (ids removed).
        let real = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1791943200,"rateLimitType":"seven_day","utilization":0.79,"isUsingOverage":false,"surpassedThreshold":0.75,"unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":1791783000},"seven_day":{"utilization":0.79,"resetsAt":1791943200}}}}"#
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ANSWER","total_cost_usd":0.019533}"#
        let s = ClaudeStreamOutput.parse(#"{"type":"system","subtype":"init"}"# + "\n" + real + "\n"
                                         + #"{"type":"assistant"}"# + "\nnot json\n" + result + "\n")
        eq("1 five-hour meter", s.meter?.fiveHour, 0.2)
        eq("1 weekly meter", s.meter?.sevenDay, 0.79)
        eq("1 five-hour reset", s.meter?.fiveHourResetsAt, Date(timeIntervalSince1970: 1_791_783_000))
        eq("1 notional dollars", s.notionalUSD, 0.019533)
        eq("1 envelope result", s.envelope?["result"] as? String, "ANSWER")
        let run = LocalAgentClient.CLIRun(exitCode: 0, stdout: real + "\n" + result, stderr: "", timedOut: false,
                                          spawnFailed: false)
        eq("1 classify reads the result event", try? LocalAgentWindowTransport.classify(run, now: day), "ANSWER")
        let single = LocalAgentClient.CLIRun(
            exitCode: 0, stdout: #"{"subtype":"success","is_error":false,"result":"OLD"}"#, stderr: "",
            timedOut: false, spawnFailed: false)
        eq("1 one JSON envelope still works", try? LocalAgentWindowTransport.classify(single, now: day), "OLD")
        eq("1 no meter in it", ClaudeStreamOutput.parse(single.stdout).meter, nil)
        let limited = LocalAgentClient.CLIRun(
            exitCode: 1, stdout: #"{"type":"result","subtype":"error","is_error":true,"result":"You've hit your limit · resets 3pm"}"#,
            stderr: "", timedOut: false, spawnFailed: false)
        do {
            _ = try LocalAgentWindowTransport.classify(limited, now: day)
            check("1 a limit in the result event stops the run", false)
        } catch WindowTransportError.usageLimit(let reset, _) {
            check("1 a limit in the result event stops the run, with its reset", reset != nil)
        } catch { check("1 a limit in the result event stops the run", false, "\(error)") }
        var cancelled = run
        cancelled.cancelled = true
        check("1 a cancelled call is a cancellation",
              (try? LocalAgentWindowTransport.classify(cancelled, now: day)) == nil
              && { do { _ = try LocalAgentWindowTransport.classify(cancelled, now: day); return false }
                   catch is CancellationError { return true } catch { return false } }())
        eq("1 the args ask for stream-json, verbose, the Read tool only",
           LocalAgentWindowTransport.arguments(model: "m"),
           ["-p", "--model", "m", "--output-format", "stream-json", "--verbose", "--allowedTools", "Read",
            "--permission-mode", "default", "--no-session-persistence"])
    }

    // MARK: 2. Calibration

    private static func calibration() {
        eq("2 two calls: not yet", PlanCalibration.measure([record(0.27), record(0.27)]), .notYet)
        eq("2 three calls, no meter: unreadable", PlanCalibration.measure([record(nil), record(nil), record(nil)]),
           .unreadable)
        let crossing = [record(0.27, 0.75), record(0.28, 0.75), record(0.29, 0.75), record(0.30, 0.76)]
        if case .measured(let s) = PlanCalibration.measure(crossing, now: day) {
            // 3 points over the three calls before the last reading: $0.75.
            check("2 ratio is points per notional dollar", abs(s.fiveHourPointsPerUSD - 4) < 1e-9,
                  "\(s.fiveHourPointsPerUSD)")
            eq("2 weekly points", s.sevenDayPoints, 1)
            eq("2 weekly not read below 3 points", s.sevenDayPointsPerUSD, nil)
            check("2 weekly bound is (points + 1) per dollar", abs(s.sevenDayBoundPerUSD - 2 / 0.75) < 1e-9)
            eq("2 pages", s.pages, 12)
        } else { check("2 three points crossed: measured", false, "\(PlanCalibration.measure(crossing))") }
        let flat = (0..<34).map { _ in record(0.27) }
        eq("2 100 pages under 3 points", PlanCalibration.measure(flat), .underThreshold(pages: 102))
        if case .discarded = PlanCalibration.measure([record(0.40), record(0.41), record(0.02), record(0.05)]) {
            check("2 a meter that went backwards is discarded", true)
        } else { check("2 a meter that went backwards is discarded", false) }
        let jump = [record(0.27), record(0.27), record(0.27), record(0.27), record(0.27), record(0.27),
                    record(0.27), record(0.27), record(0.27), record(0.27), record(0.37)]
        if case .discarded = PlanCalibration.measure(jump) {
            check("2 a jump the calls do not explain is discarded", true)
        } else { check("2 a jump the calls do not explain is discarded", false, "\(PlanCalibration.measure(jump))") }
        // The owner's Dean run shape (usage.md): even steps, one point every 6 windows, are kept.
        var dean: [PlanCallRecord] = []
        for i in 0..<68 { dean.append(record(0.27 + Double(i / 6) / 100, usd: 0.15)) }
        if case .measured(let s) = PlanCalibration.measure(dean) {
            check("2 even steps are kept", s.fiveHourPointsPerUSD > 1 && s.fiveHourPointsPerUSD < 1.3,
                  "\(s.fiveHourPointsPerUSD)")
        } else { check("2 even steps are kept", false, "\(PlanCalibration.measure(dean))") }
        // Calls finish out of order: a reading one point below the one before is not a reset.
        let unordered = [record(0.30), record(0.31), record(0.30), record(0.32), record(0.33)]
        if case .measured(let s) = PlanCalibration.measure(unordered) {
            check("2 out-of-order readings are kept, measured to the first top reading",
                  abs(s.fiveHourPointsPerUSD - 3 / 1.0) < 1e-9, "\(s.fiveHourPointsPerUSD)")
        } else { check("2 out-of-order readings are kept", false, "\(PlanCalibration.measure(unordered))") }
        let moved = [PlanCallRecord(meter: PlanMeterReading(fiveHour: 0.30, fiveHourResetsAt: day), notionalUSD: 0.25, pages: 3),
                     PlanCallRecord(meter: PlanMeterReading(fiveHour: 0.31, fiveHourResetsAt: day), notionalUSD: 0.25, pages: 3),
                     PlanCallRecord(meter: PlanMeterReading(fiveHour: 0.33, fiveHourResetsAt: day + 18_000),
                                    notionalUSD: 0.25, pages: 3)]
        if case .discarded = PlanCalibration.measure(moved) {
            check("2 a new reset time is a reset", true)
        } else { check("2 a new reset time is a reset", false, "\(PlanCalibration.measure(moved))") }
        let weekly = [record(0.10, 0.50), record(0.12, 0.53), record(0.14, 0.56), record(0.16, 0.59)]
        if case .measured(let s) = PlanCalibration.measure(weekly) {
            check("2 weekly read at 3 points or more", s.sevenDayPointsPerUSD.map { abs($0 - 12) < 1e-9 } == true,
                  "\(String(describing: s.sevenDayPointsPerUSD))")
        } else { check("2 weekly read at 3 points or more", false) }
    }

    // MARK: 3. Store and text

    private static func store() {
        func sample(_ r: Double, week: Int = 0) -> PlanRunSample {
            PlanRunSample(fiveHourPointsPerUSD: r, sevenDayPoints: week, notionalUSD: 10, pages: 100, measured: day)
        }
        var s = PlanCalibrationStore()
        eq("3 empty: no estimate", s.estimate(notionalUSD: 50), nil)
        for r in [5.0, 1.0, 2.0, 3.0, 4.0, 9.0] { s.add(sample(r)) }
        eq("3 keeps the last five", s.samples.count, 5)
        eq("3 median of the last five", s.fiveHourPointsPerUSD, 3)
        eq("3 weekly bound is the tightest", s.sevenDayBoundPerUSD, 0.1)
        eq("3 estimate text", s.estimate(notionalUSD: 10), "about 30% of a five-hour window, under about 1% of your week")
        s.add(sample(3, week: 5))
        eq("3 weekly read once a run crossed it", s.sevenDayPointsPerUSD, 0.5)
        eq("3 under 1%", PlanShareText.fiveHour(0.4), "under 1% of a five-hour window")
        eq("3 more than a window", PlanShareText.fiveHour(160), "about 1.6 five-hour windows")
        eq("3 week exact", PlanShareText.week(points: 4.6, bound: 9), "about 5% of your week")

        let suite = "APSegPlanTest-\(ProcessInfo.processInfo.processIdentifier)"
        guard let d = UserDefaults(suiteName: suite) else { check("3 scratch defaults", false); return }
        defer { d.removePersistentDomain(forName: suite) }
        let records = [record(0.27), record(0.28), record(0.29), record(0.30)]
        if case .measured = PlanCalibrationStore.recordRun(records, defaults: d, now: day) {} else {
            check("3 recordRun measures", false)
        }
        eq("3 recordRun stores the run", PlanCalibrationStore.load(d).samples.count, 1)
        PlanCalibrationStore.recordRun([record(0.27), record(0.28)], defaults: d, now: day)
        eq("3 a run that did not cross is not stored", PlanCalibrationStore.load(d).samples.count, 1)
    }

    // MARK: 4. The chooser and the route

    private static func chooser() {
        guard let options = try? SegmentationOptions.loadBundled() else {
            check("4 bundled options.json decodes", false); return
        }
        let notional = "Claude plan: uses about as much of your plan as $50.29 of API calls at list price; "
            + "measured on your account after the first run"
        let both = SegmentationRoutes(hasAnthropicKey: true, hasClaudeCLI: true)
        var bothPlan = both
        bothPlan.claudeRoute = .plan
        check("4 the route is offered only with both", both.offersClaudeRouteChoice
              && !SegmentationRoutes(hasClaudeCLI: true).offersClaudeRouteChoice
              && !SegmentationRoutes(hasAnthropicKey: true).offersClaudeRouteChoice)
        let byKey = SegmentationRow.make(.claude, options: options, pageCount: 1000, routes: both, today: day)
        check("4 both, API key chosen: priced by key", byKey.costLines.first?.contains("by API key") == true
              && byKey.apiDollars != nil, "\(byKey.costLines)")
        let byPlan = SegmentationRow.make(.claude, options: options, pageCount: 1000, routes: bothPlan, today: day)
        eq("4 both, plan chosen: the plan line", byPlan.costLines, [notional])
        eq("4 both, plan chosen: no dollars", byPlan.apiDollars, nil)

        var measured = SegmentationRoutes(hasClaudeCLI: true)
        measured.planCalibration.add(PlanRunSample(fiveHourPointsPerUSD: 1, sevenDayPoints: 0, notionalUSD: 10,
                                                   pages: 100, measured: day))
        let row = SegmentationRow.make(.claude, options: options, pageCount: 1000, routes: measured, today: day)
        eq("4 after a run: the measured share", row.costLines,
           ["Claude plan: about 50% of a five-hour window, under about 6% of your week; measured on your account, "
            + "\(PlanShareText.measuredDate(day))"])
        check("4 the mix's Claude half is measured too",
              SegmentationRow.make(.mix, options: options, pageCount: 1000,
                                   routes: { var r = measured; r.hasGeminiKey = true; return r }(), today: day)
                .costLines.contains { $0.hasPrefix("Claude plan: about") })
        check("4 Gemini has no plan figure", SegmentationRow.planNotionalUSD(.gemini, options: options, pageCount: 100) == nil)
        check("4 plan notional per 1,000 pages",
              abs((SegmentationRow.planNotionalUSD(.claude, options: options, pageCount: 1000) ?? 0) - 50.29) < 0.01)

        guard let spec = try? options.spec(for: .claude) else { check("4 claude spec", false); return }
        func plan(_ keys: [WindowProvider: String], _ bin: String?, _ route: ClaudeRoute) -> Bool? {
            guard case .success(let t) = WindowStageTransport.make(spec, keys: keys, claudeBinary: bin, route: route)
            else { return nil }
            return OCRProcessor.usesPlan(t)
        }
        eq("4 transport: key + claude, plan chosen → plan", plan([.anthropic: "k"], "/bin/echo", .plan), true)
        eq("4 transport: key + claude, key chosen → key", plan([.anthropic: "k"], "/bin/echo", .apiKey), false)
        eq("4 transport: claude only → plan", plan([:], "/bin/echo", .apiKey), true)
        eq("4 transport: key only, plan chosen → key", plan([.anthropic: "k"], nil, .plan), false)
        eq("4 transport: neither → missing", plan([:], nil, .plan), nil)
    }

    // MARK: 5. The gate

    actor Asked {
        var prompts: [PlanCheckPrompt] = []
        func add(_ p: PlanCheckPrompt) { prompts.append(p) }
    }

    private static func gateUnit() async {
        let asked = Asked()
        let gate = PlanRunGate(pagesPerCall: 3, folderNotionalUSD: 10, calibrated: false) { p in
            await asked.add(p); return true
        }
        for (i, f) in [0.27, 0.28, 0.29, 0.30, 0.31].enumerated() {
            do { try await gate.beforeCall() } catch { check("5 gate goes on (call \(i))", false, "\(error)") }
            await gate.record(meter: PlanMeterReading(fiveHour: f, sevenDay: 0.5), notionalUSD: 0.25, answered: true)
        }
        try? await gate.beforeCall()
        let prompts = await asked.prompts
        eq("5 asked exactly once", prompts.count, 1)
        check("5 the question gives the folder's share",
              prompts.first?.message.contains("about 40% of a five-hour window") == true
              && prompts.first?.message.contains("first 12 pages") == true, prompts.first?.message ?? "nil")

        let calibrated = PlanRunGate(pagesPerCall: 3, folderNotionalUSD: 10, calibrated: true) { p in
            await asked.add(p); return true
        }
        for f in [0.27, 0.28, 0.29, 0.30, 0.31] {
            try? await calibrated.beforeCall()
            await calibrated.record(meter: PlanMeterReading(fiveHour: f), notionalUSD: 0.25, answered: true)
        }
        try? await calibrated.beforeCall()
        eq("5 a stored ratio: no question", await asked.prompts.count, 1)

        // The pause reads the highest figure, not the last call to finish.
        let unordered = PlanRunGate(pagesPerCall: 3, folderNotionalUSD: 10, calibrated: true) { _ in true }
        await unordered.record(meter: PlanMeterReading(fiveHour: 0.90), notionalUSD: 0.25, answered: true)
        await unordered.record(meter: PlanMeterReading(fiveHour: 0.89), notionalUSD: 0.25, answered: true)
        check("5 90% read from the highest figure", (try? await unordered.beforeCall()) == nil)

        // Two Claude voters: only one voter's windows count the pages.
        let twoVoters = PlanRunGate(pagesPerCall: 3, folderNotionalUSD: 10, calibrated: true, pageVoter: "a") { _ in true }
        await twoVoters.record(meter: nil, notionalUSD: 0.25, answered: true, voter: "a")
        await twoVoters.record(meter: nil, notionalUSD: 0.25, answered: true, voter: "b")
        eq("5 pages counted once per window", await twoVoters.records.map(\.pages), [3, 0])

        // A window cancelled while the question is on its way cancels the question.
        let cancelledAsk = Asked()
        let slow = PlanRunGate(pagesPerCall: 3, folderNotionalUSD: 10, calibrated: false) { p in
            do { try await Task.sleep(for: .seconds(60)); return true } catch { await cancelledAsk.add(p); return false }
        }
        for f in [0.27, 0.28, 0.29, 0.30] {
            await slow.record(meter: PlanMeterReading(fiveHour: f), notionalUSD: 0.25, answered: true)
        }
        let waiting = Task { try await slow.beforeCall() }
        try? await Task.sleep(for: .milliseconds(300))
        let t0 = Date()
        waiting.cancel()
        let waited = await waiting.result
        check("5 a cancelled window stops waiting for the answer",
              { if case .failure(let e) = waited { return e is CancellationError }; return false }()
              && Date().timeIntervalSince(t0) < 3, "\(waited)")
        var questionCancelled = false
        for _ in 0..<30 where !questionCancelled {
            questionCancelled = await cancelledAsk.prompts.count == 1
            if !questionCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        }
        check("5 and the question is cancelled with it", questionCancelled)

        await calibrated.record(meter: PlanMeterReading(fiveHour: 0.9, fiveHourResetsAt: day), notionalUSD: 0.25,
                                answered: true)
        do {
            try await calibrated.beforeCall()
            check("5 90% pauses", false)
        } catch WindowTransportError.paused(let reset, let message) {
            check("5 90% pauses with the reset time", reset == day && message.contains("90%"), message)
        } catch { check("5 90% pauses", false, "\(error)") }
    }

    // MARK: 5. Against the fake CLI

    private static func meterDir(five: Int, week: Int) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("APSegPlanMeter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? "\(five)".write(to: d.appendingPathComponent("five"), atomically: true, encoding: .utf8)
        try? "\(week)".write(to: d.appendingPathComponent("week"), atomically: true, encoding: .utf8)
        return d
    }

    private static func describe(_ g: PlanRunGate) async -> String {
        await g.records.map { "\($0.meter?.fiveHour ?? -1)/\($0.pages)" }.joined(separator: " ")
    }

    private static func fakeRuns(_ fake: String) async {
        guard let options = try? SegmentationOptions.loadBundled(), let spec = try? options.spec(for: .claude) else {
            check("5 claude spec", false); return
        }
        let n = 30
        let pages = (0..<n).map { _ in PageInput(jpeg: Data([0xFF, 0xD8]), text: "text") }
        let kinds = [PhotoKind?](repeating: nil, count: n)
        let windows = WindowLayout.windows(pageCount: n, pages: spec.windowPages, stride: spec.windowStride).count
        func engine(_ gate: PlanRunGate) -> WindowSegmenter {
            var e = WindowSegmenter(transport: LocalAgentWindowTransport(binaryPath: fake, timeout: 30, gate: gate))
            e.maxConcurrent = 1   // the fake's meter files are not safe for concurrent calls
            e.retryDelay = .zero
            return e
        }

        // a. First run on the account: asked once, goes on, and the run's ratio is what the meter said.
        setenv("LOCALAGENT_FAKE_MODE", "stream", 1)
        setenv("LOCALAGENT_FAKE_METER_DIR", meterDir(five: 20, week: 50).path, 1)
        let asked = Asked()
        let gate = PlanRunGate(pagesPerCall: spec.windowStride, folderNotionalUSD: 10, calibrated: false) { p in
            await asked.add(p); return true
        }
        do {
            let r = try await engine(gate).segment(pages: pages, photoKinds: kinds, approach: spec)
            eq("5a every window answered", r.answered.count, windows)
            eq("5a every gap proposed", r.proposals.count, n - 1)
            eq("5a no window failed", r.failed.count, 0)
        } catch { check("5a the run finishes", false, "\(error)") }
        eq("5a asked once", await asked.prompts.count, 1)
        let records = await gate.records
        eq("5a one record per call", records.count, windows)
        if case .measured(let s) = PlanCalibration.measure(records) {
            check("5a ratio from the fake meter (1 point per $0.25)", abs(s.fiveHourPointsPerUSD - 4) < 1e-9,
                  "\(s.fiveHourPointsPerUSD)")
        } else { check("5a the run is measured", false, "\(PlanCalibration.measure(records))") }

        // b. Declined: the run stops resumably, keeping the windows answered before the question.
        setenv("LOCALAGENT_FAKE_METER_DIR", meterDir(five: 20, week: 50).path, 1)
        let declining = PlanRunGate(pagesPerCall: spec.windowStride, folderNotionalUSD: 10, calibrated: false) { _ in
            false
        }
        do {
            _ = try await engine(declining).segment(pages: pages, photoKinds: kinds, approach: spec)
            check("5b declining stops the run", false)
        } catch WindowSegmenterError.paused(_, let message, let answered) {
            let seen = await describe(declining)
            check("5b declining stops the run, resumably", answered.count == 4 && message.contains("chose to stop"),
                  "\(answered.count) \(message) records \(seen)")
        } catch { check("5b declining stops the run", false, "\(error)") }

        // c. The five-hour meter at 90%: paused, with the reset time the CLI gave.
        setenv("LOCALAGENT_FAKE_METER_DIR", meterDir(five: 88, week: 50).path, 1)
        let full = PlanRunGate(pagesPerCall: spec.windowStride, folderNotionalUSD: 10, calibrated: true) { _ in true }
        do {
            _ = try await engine(full).segment(pages: pages, photoKinds: kinds, approach: spec)
            check("5c 90% pauses", false)
        } catch WindowSegmenterError.paused(let reset, _, let answered) {
            let seen = await describe(full)
            check("5c 90% pauses after the call that read it, with the reset",
                  answered.count == 3 && reset == Date(timeIntervalSince1970: 1_791_783_000),
                  "\(answered.count) \(String(describing: reset)) records \(seen)")
        } catch { check("5c 90% pauses", false, "\(error)") }

        // d. No meter: no question, the run finishes, and nothing is measured.
        setenv("LOCALAGENT_FAKE_MODE", "streamnometer", 1)
        let blind = Asked()
        let noMeter = PlanRunGate(pagesPerCall: spec.windowStride, folderNotionalUSD: 10, calibrated: false) { p in
            await blind.add(p); return true
        }
        do {
            let r = try await engine(noMeter).segment(pages: pages, photoKinds: kinds, approach: spec)
            eq("5d no meter: the run finishes", r.answered.count, windows)
        } catch { check("5d no meter: the run finishes", false, "\(error)") }
        eq("5d no meter: no question", await blind.prompts.count, 0)
        eq("5d no meter: unreadable", PlanCalibration.measure(await noMeter.records), .unreadable)
    }

    // MARK: 6. Cancellation

    private static func pids(in dir: URL) -> [pid_t] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { pid_t($0) }
    }

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    private static func cancellation(_ fake: String) async {
        setenv("LOCALAGENT_FAKE_MODE", "timeout", 1)
        let pidDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("APSegPlanPids-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)
        setenv("LOCALAGENT_FAKE_PID_DIR", pidDir.path, 1)
        defer { try? FileManager.default.removeItem(at: pidDir) }

        // One window call.
        let transport = LocalAgentWindowTransport(binaryPath: fake, timeout: 60)
        let request = WindowRequest(voter: WindowVoter.catalog.first { $0.provider == .anthropic }!, prompt: "P",
                                    images: [Data([1]), Data([2])], pageNumbers: [1, 2])
        let call = Task { try await transport.send(request) }
        let started = await waitUntil(5) { !pids(in: pidDir).isEmpty }
        check("6 the fake claude started", started)
        let t0 = Date()
        call.cancel()
        let outcome = await call.result
        let elapsed = Date().timeIntervalSince(t0)
        check("6 a cancelled call ends as a cancellation, at once",
              { if case .failure(let e) = outcome { return e is CancellationError }; return false }() && elapsed < 6,
              "\(outcome) after \(elapsed) s")
        let first = pids(in: pidDir)
        check("6 its claude child is gone", await waitUntil(5) { first.allSatisfy { !alive($0) } }, "\(first)")

        // A whole engine run, three calls at once.
        for f in first { try? FileManager.default.removeItem(at: pidDir.appendingPathComponent("\(f)")) }
        guard let spec = try? SegmentationOptions.loadBundled().spec(for: .claude) else { return }
        var engine = WindowSegmenter(transport: transport)
        engine.retryDelay = .zero
        let pages = (0..<30).map { _ in PageInput(jpeg: Data([0xFF]), text: "t") }
        let kinds = [PhotoKind?](repeating: nil, count: 30)
        let run = Task { try await engine.segment(pages: pages, photoKinds: kinds, approach: spec) }
        check("6 three claude calls in flight", await waitUntil(8) { pids(in: pidDir).count >= 3 },
              "\(pids(in: pidDir).count)")
        let t1 = Date()
        run.cancel()
        let ran = await run.result
        let runElapsed = Date().timeIntervalSince(t1)
        check("6 a cancelled run ends at once", { if case .failure(let e) = ran { return e is CancellationError }
                                                  return false }() && runElapsed < 8, "\(ran) after \(runElapsed) s")
        let three = pids(in: pidDir)
        check("6 every claude child of the run is gone", await waitUntil(5) { three.allSatisfy { !alive($0) } },
              "\(three.filter(alive))")
        try? await Task.sleep(for: .seconds(1))
        eq("6 no call started after the cancel", pids(in: pidDir).count, three.count)

        // Cancelled before it starts: never spawned.
        for f in pids(in: pidDir) { try? FileManager.default.removeItem(at: pidDir.appendingPathComponent("\(f)")) }
        let canceller = LocalAgentClient.ProcessCanceller()
        canceller.cancel()
        let never = LocalAgentClient.runProcess(binaryPath: fake, args: [], stdinText: "", timeout: 5,
                                                canceller: canceller)
        check("6 a call cancelled first never spawns", never.cancelled && pids(in: pidDir).isEmpty)

        // The plan route does not pass on an API key from the shell that launched the app.
        setenv("ANTHROPIC_API_KEY", "sk-test-not-a-key", 1)
        let env = LocalAgentClient.runProcess(binaryPath: "/usr/bin/env", args: [], stdinText: "", timeout: 10,
                                              unsetEnvironment: LocalAgentWindowTransport.apiCredentialVariables)
        unsetenv("ANTHROPIC_API_KEY")
        check("6 no API key reaches claude on the plan route",
              !env.stdout.contains("ANTHROPIC_API_KEY") && env.stdout.contains("PATH="), String(env.stdout.prefix(200)))

        // A child that exits without reading 2 MB of stdin: the write fails, the app lives on.
        let big = String(repeating: "x", count: 2_000_000)
        let quick = LocalAgentClient.runProcess(binaryPath: "/usr/bin/true", args: [], stdinText: big, timeout: 10)
        check("6 an unread stdin cannot raise SIGPIPE", quick.exitCode == 0 && !quick.spawnFailed, "\(quick)")
    }
}

#endif
