#if DEBUG // W40.a5: a test driver, compiled out of Release
import AppKit
import Combine
import Foundation

/// W46.seg-check-time: times a person checking flagged gaps on the app's own Check Flagged Boundaries sheet.
///
/// `FLAGGED_CHECK_TIMING_PACK=<pack.json> FLAGGED_CHECK_TIMING_OUT=<run.json>` (`scripts/time-flagged-checks.sh`)
/// shows the sheet on the pack's gaps, built by `scripts/segbench/check_time.py pack` from a route's cached answers,
/// with no run, OCR, model call, manifest or output behind it. The sheet is not changed: the driver watches the
/// processor's flagged-gap answers and focus, which the sheet's keys and buttons set, and logs each change with its
/// time (system uptime, so a sleep is not counted). The log is rewritten after every event, so a crash keeps what was
/// done; Done or Cancel Run writes the last one and quits. `check_time.py score` turns the log into seconds a gap.
///
/// `FLAGGED_CHECK_TIMING_SELFTEST=1` (+ `FLAGGED_CHECK_TIMING_SELFTEST_OUT`) is its $0 headless self-test
/// (`scripts/test-flagged-check-timing.sh`): the recorder on fixed sequences, and the driver end to end on three
/// drawn pages in its own temporary directory, answered the way the sheet answers.
@MainActor
enum FlaggedCheckTimingTestDriver {
    struct PackItem: Decodable {
        let key: String
        let left: String
        let right: String
        let proposal: GapDecision
        let confidence: Double
        let cue: String
        let left_rotation: Int
        let right_rotation: Int
    }

    struct Pack: Decodable {
        let approach: String
        let items: [PackItem]
    }

    /// One change on the sheet, `t` seconds after it was shown: `focus` (a gap came into view), `answer` (a gap's
    /// answer was set or changed), then one `done` or `cancel`.
    struct Event: Codable, Equatable {
        let t: Double
        let kind: String
        var index: Int? = nil
        var answer: String? = nil
    }

    /// The log, fed the sheet's state each time it changes. An answer is logged before the focus move it causes.
    struct Recorder {
        private(set) var events: [Event] = []
        private var focus: Int?
        private var answers: [FlaggedGapAnswer?]
        private(set) var ended = false

        init(count: Int) { answers = Array(repeating: nil, count: count) }

        mutating func observe(t: Double, focus f: Int, answers now: [FlaggedGapAnswer?]) {
            guard !ended, now.count == answers.count else { return }
            for k in now.indices where now[k] != answers[k] {
                events.append(Event(t: t, kind: "answer", index: k, answer: now[k]?.rawValue))
            }
            answers = now
            let clamped = min(max(0, f), max(0, now.count - 1))
            if clamped != focus {
                events.append(Event(t: t, kind: "focus", index: clamped))
                focus = clamped
            }
        }

        mutating func end(t: Double, done: Bool) {
            guard !ended else { return }
            events.append(Event(t: t, kind: done ? "done" : "cancel"))
            ended = true
        }
    }

    struct RunItem: Codable, Equatable {
        let key: String
        let answer: String?
    }

    struct Run: Codable {
        let tag: String
        let pack: String
        let started: String
        let display: String
        let done: Bool?
        let items: [RunItem]
        let events: [Event]
    }

    private static var didRun = false
    private static var watch: AnyCancellable?

    static func runIfRequested(processor: OCRProcessor) {
        guard !didRun else { return }
        let env = ProcessInfo.processInfo.environment
        if env["FLAGGED_CHECK_TIMING_SELFTEST"] == "1" {
            didRun = true
            Task { @MainActor in await selfTest(processor: processor) }
            return
        }
        guard let packPath = env["FLAGGED_CHECK_TIMING_PACK"], let outPath = env["FLAGGED_CHECK_TIMING_OUT"] else {
            return
        }
        didRun = true
        Task { @MainActor in
            do {
                let pack = try JSONDecoder().decode(Pack.self, from: Data(contentsOf: URL(fileURLWithPath: packPath)))
                _ = await time(processor: processor, pack: pack, packPath: packPath,
                               out: URL(fileURLWithPath: outPath), now: { ProcessInfo.processInfo.systemUptime })
                NSApp.terminate(nil)
            } catch {
                processor.statusMessage = "Flagged-check timing: cannot read \(packPath): \(error.localizedDescription)"
            }
        }
    }

    /// Show the pack's gaps on the sheet, log every change until Done or Cancel Run, and return the last log.
    static func time(processor: OCRProcessor, pack: Pack, packPath: String, out: URL,
                     now: @escaping () -> Double) async -> Run? {
        guard !processor.isProcessing, !pack.items.isEmpty else { return nil }
        let keys = pack.items.map(\.key)
        processor.flaggedGapItems = pack.items.enumerated().map { k, p in
            FlaggedGapItem(id: k, leftURL: URL(fileURLWithPath: p.left), rightURL: URL(fileURLWithPath: p.right),
                           leftRotation: p.left_rotation, rightRotation: p.right_rotation, proposal: p.proposal,
                           confidence: p.confidence, cue: p.cue)
        }
        processor.flaggedGapFocus = 0
        processor.flaggedReviewApproachName = pack.approach
        let start = now()
        let started = ISO8601DateFormatter().string(from: Date())
        let display = NSScreen.main.map { s in
            "\(Int(s.frame.width))x\(Int(s.frame.height)) points at \(Int(s.backingScaleFactor))x"
        } ?? "unknown"
        var recorder = Recorder(count: keys.count)
        func save(done: Bool?) -> Run {
            let answers = processor.flaggedGapItems.map(\.answer?.rawValue)
            let run = Run(tag: "W46.seg-check-time", pack: packPath, started: started, display: display, done: done,
                          items: zip(keys, answers).map { RunItem(key: $0, answer: $1) }, events: recorder.events)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(run) { try? data.write(to: out, options: .atomic) }
            return run
        }
        recorder.observe(t: 0, focus: 0, answers: processor.flaggedGapItems.map(\.answer))
        _ = save(done: nil)
        // @Published sends the new value before it is stored, so each emission carries the state it reports.
        watch = processor.$flaggedGapItems.combineLatest(processor.$flaggedGapFocus)
            .sink { items, focus in
                guard items.count == keys.count else { return }
                recorder.observe(t: now() - start, focus: focus, answers: items.map(\.answer))
                _ = save(done: nil)
            }
        processor.awaitingFlaggedReview = true
        let done = await withCheckedContinuation { processor.flaggedReviewContinuation = $0 }
        watch = nil
        recorder.end(t: now() - start, done: done)
        return save(done: done)
    }

    // MARK: - Self-test

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func selfTest(processor: OCRProcessor) async {
        // 1. The recorder on a fixed sequence: shown, answered (focus moves on), moved back, changed, done.
        var r = Recorder(count: 3)
        r.observe(t: 0, focus: 0, answers: [nil, nil, nil])
        r.observe(t: 4, focus: 0, answers: [.keep, nil, nil])
        r.observe(t: 4, focus: 1, answers: [.keep, nil, nil])
        r.observe(t: 9, focus: 1, answers: [.keep, nil, nil])          // nothing changed: no event
        r.observe(t: 11, focus: 0, answers: [.keep, nil, nil])
        r.observe(t: 15, focus: 0, answers: [.split, nil, nil])
        r.observe(t: 15, focus: 7, answers: [.split, nil, nil])        // clamped to the last gap
        r.end(t: 20, done: true)
        r.end(t: 30, done: false)                                       // only the first end counts
        r.observe(t: 31, focus: 0, answers: [nil, nil, nil])           // nothing after the end
        let want: [Event] = [Event(t: 0, kind: "focus", index: 0), Event(t: 4, kind: "answer", index: 0, answer: "keep"),
                             Event(t: 4, kind: "focus", index: 1), Event(t: 11, kind: "focus", index: 0),
                             Event(t: 15, kind: "answer", index: 0, answer: "split"), Event(t: 15, kind: "focus", index: 2),
                             Event(t: 20, kind: "done")]
        check("1 the recorder's log", r.events == want, "got \(r.events)")

        // 2. End to end: three drawn pages, answered as the sheet's answer() does, on a fake clock.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlaggedCheckTiming-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = (1...3).map { n -> String in
            let url = dir.appendingPathComponent("page-\(n).png")
            let image = NSImage(size: NSSize(width: 60, height: 80), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill(); return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            return url.path
        }
        let packJSON = """
        {"approach": "Gemini", "items": [
         {"key": "T 1|2", "left": "\(urls[0])", "right": "\(urls[1])", "proposal": "new", "confidence": 0.9,
          "cue": "new:a letterhead", "left_rotation": 0, "right_rotation": 90},
         {"key": "T 2|3", "left": "\(urls[1])", "right": "\(urls[2])", "proposal": "continue", "confidence": 0.6,
          "cue": "continue:page 2", "left_rotation": 90, "right_rotation": 0}]}
        """
        let packURL = dir.appendingPathComponent("pack.json")
        try? packJSON.write(to: packURL, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("run.json")
        let clock = ClockBox()
        guard let pack = try? JSONDecoder().decode(Pack.self, from: Data(contentsOf: packURL)) else {
            check("2 the pack decodes", false)
            return finish(dir)
        }
        let task = Task { @MainActor in
            await time(processor: processor, pack: pack, packPath: packURL.path, out: out, now: { clock.t })
        }
        for _ in 0..<200 where processor.flaggedReviewContinuation == nil { try? await Task.sleep(for: .milliseconds(10)) }
        check("2 the sheet is up on the pack", processor.awaitingFlaggedReview && processor.flaggedGapItems.count == 2
              && processor.flaggedGapItems[1].leftRotation == 90 && processor.flaggedReviewApproachName == "Gemini")
        check("2 Done is not offered yet", !FlaggedReview.isComplete(processor.flaggedGapItems))
        clock.t = 6
        processor.flaggedGapItems[0].answer = .keep
        processor.flaggedGapFocus = 1
        let partial = (try? Data(contentsOf: out)).flatMap { try? JSONDecoder().decode(Run.self, from: $0) }
        check("2 the log is on disk before Done", partial?.done == nil && partial?.events.count == 3,
              "got \(String(describing: partial?.events))")
        clock.t = 13.5
        processor.flaggedGapItems[1].answer = .split
        clock.t = 15
        processor.confirmFlaggedReview()
        let run = await task.value
        let saved = (try? Data(contentsOf: out)).flatMap { try? JSONDecoder().decode(Run.self, from: $0) }
        check("2 Done ends the log", saved?.done == true && saved?.events.last == Event(t: 15, kind: "done"))
        check("2 the answers by key", saved?.items == [RunItem(key: "T 1|2", answer: "keep"),
                                                      RunItem(key: "T 2|3", answer: "split")])
        check("2 the events", saved?.events == [Event(t: 0, kind: "focus", index: 0),
                                                Event(t: 6, kind: "answer", index: 0, answer: "keep"),
                                                Event(t: 6, kind: "focus", index: 1),
                                                Event(t: 13.5, kind: "answer", index: 1, answer: "split"),
                                                Event(t: 15, kind: "done")], "got \(String(describing: saved?.events))")
        check("2 the returned run is the saved one", run?.events == saved?.events)
        check("2 the sheet is closed", !processor.awaitingFlaggedReview)
        finish(dir)
    }

    @MainActor private final class ClockBox { var t = 0.0 }

    private static func finish(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["FLAGGED_CHECK_TIMING_SELFTEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
