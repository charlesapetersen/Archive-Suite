import Foundation

// W40.fix-processor-rotation-deadlock — compiled with the REAL `RotationDetector.swift` by
// test-rotation-deadlock.sh. It queues many pages through `RotationDetector.detectCorrection` at once, the way a
// Live Capture segment's task group does, and requires them all to finish inside a time limit. The old shape (four
// synchronous Vision passes per page on the cooperative pool) left Vision's own work without a thread and hung.
// It also checks each page still comes back on the right text axis.

final class WatchdogFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var done: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@main
struct RotationDeadlockHeadlessDriver {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: rotation-deadlock-headless <page-dir> <time-limit-seconds>")
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        let limit = Double(args[2]) ?? 120
        let pages = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) { results.append("\(condition ? "PASS" : "FAIL"): \(name)") }

        check("at least 24 pages queued (twice the cores of the owner's Mac)", pages.count >= 24)

        // Watchdogs on plain threads, so a starved cooperative pool cannot silence them.
        func watchdog(_ seconds: Double, _ message: String) -> WatchdogFlag {
            let flag = WatchdogFlag()
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: seconds)
                guard !flag.done else { return }
                print("SOME FAILED\nFAIL: \(message)")
                exit(1)
            }
            return flag
        }

        // Warm-up: one page alone. The first Vision text pass after an OS update (or a purged cache) waits for the
        // Neural Engine to compile its model in ANECompilerService, measured at over a minute on this Mac with the
        // app idle at 0% CPU. That wait is not the deadlock, so it is taken here, outside the timed batch.
        guard let first = pages.first else { print("SOME FAILED\nFAIL: no pages"); exit(1) }
        let warm = watchdog(600, "one page alone did not finish within 600 s (the Neural Engine compile?)")
        let warmStart = Date()
        _ = await RotationDetector.detectCorrection(imageURL: first)
        warm.done = true
        results.append("NOTE: warm-up page took \(String(format: "%.1f", Date().timeIntervalSince(warmStart))) s")

        let started = Date()
        _ = watchdog(limit, "\(pages.count) pages did not finish within \(Int(limit)) s (pool starvation)")

        // Every page at once, as `OCRProcessor`'s segment task group does with a high worker count.
        let found: [String: Int?] = await withTaskGroup(of: (String, Int?).self) { group in
            for url in pages {
                group.addTask { (url.lastPathComponent, await RotationDetector.detectCorrection(imageURL: url)) }
            }
            var out: [String: Int?] = [:]
            for await (name, c) in group { out[name] = c }
            return out
        }
        let elapsed = Date().timeIntervalSince(started)
        check("all \(pages.count) pages finished in \(String(format: "%.1f", elapsed)) s (limit \(Int(limit)) s)",
              found.count == pages.count)

        // Fixture pages are named <doc>-c<copy>-r<deg>.jpg, rotated <deg> clockwise, so the correction is
        // (360 - deg) % 360. Every page must come back on the right text axis and the right way up
        // (W40.fix-processor-rotation-flip: the accurate pass used to tie on the flip and return 21 of 36).
        var axisRight = 0, exact = 0, total = 0
        for (name, c) in found.sorted(by: { $0.key < $1.key }) {
            guard let r = name.split(separator: "-").last?.dropFirst().split(separator: ".").first,
                  let deg = Int(r) else { continue }
            total += 1
            let want = (360 - deg) % 360
            if let c, c % 180 == want % 180 { axisRight += 1 }
            if c == want { exact += 1 } else { results.append("NOTE: \(name) → \(c.map(String.init) ?? "nil"), want \(want)") }
        }
        check("text axis right on \(axisRight) of \(total) rotated fixture pages", total > 0 && axisRight == total)
        check("exact correction (flip resolved) on \(exact) of \(total)", total > 0 && exact == total)

        let passed = !results.contains { $0.hasPrefix("FAIL") }
        print((passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n"))
        exit(passed ? 0 : 1)
    }
}
