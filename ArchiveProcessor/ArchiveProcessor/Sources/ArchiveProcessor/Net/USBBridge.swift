import Foundation

/// Best-effort USB bridge: keeps `adb reverse tcp:<port> tcp:<port>` asserted so a USB-tethered
/// phone can reach the Live Capture server at 127.0.0.1:<port>. It re-asserts on a short timer so
/// an unplug/replug (which drops the mapping) self-heals within a few seconds. No-op if adb or a
/// device isn't present. All adb work runs off the main thread.
enum USBBridge {
    private static let q = DispatchQueue(label: "usb.reverse", qos: .utility)
    // Only mutated from startReverse/stopReverse, which are called on the main actor.
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Assert the reverse tunnel now, then re-assert every 5s (heals a replug). Replaces any
    /// existing timer, so it's safe to call on each server start.
    static func startReverse(port: UInt16) {
        stopReverse()
        guard let adb = findADB() else { return }
        q.async {
            _ = run(adb, ["start-server"])
            _ = run(adb, ["reverse", "tcp:\(port)", "tcp:\(port)"])
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: 5.0)
        t.setEventHandler { _ = run(adb, ["reverse", "tcp:\(port)", "tcp:\(port)"]) }
        t.resume()
        timer = t
    }

    static func stopReverse() {
        timer?.cancel()
        timer = nil
    }

    private static func findADB() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
