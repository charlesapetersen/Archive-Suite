import Foundation

/// Best-effort USB bridge: runs `adb reverse tcp:<port> tcp:<port>` so a USB-tethered phone can
/// reach the Live Capture server at `127.0.0.1:<port>` (wired pairing, no shared Wi-Fi needed).
/// No-op if `adb` or a device isn't present. Runs off the main thread.
enum USBBridge {
    static func setupReverse(port: UInt16) {
        DispatchQueue.global(qos: .utility).async {
            guard let adb = findADB() else { return }
            _ = run(adb, ["start-server"])
            _ = run(adb, ["reverse", "tcp:\(port)", "tcp:\(port)"])
        }
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
