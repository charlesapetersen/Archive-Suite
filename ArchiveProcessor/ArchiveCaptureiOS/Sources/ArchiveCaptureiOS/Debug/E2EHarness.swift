#if DEBUG
import Foundation

/// The phone↔Mac E2E's seams on iOS (W40.i3): what `scripts/e2e-phone-mac.sh --ios` drives in a headless
/// simulator. DEBUG builds only — a Release build compiles none of this, so no environment variable or file
/// can reach it there.
///
/// - **Inject (B1, Android's `test_inject.jpg`).** `CameraController.capturePhoto` takes the bytes of
///   `Documents/test_inject.jpg` when that file exists, deletes it, and hands them on exactly as a real shot,
///   so the page goes through `persistCapturedJPEG` → `addDocumentPhoto` → upload like any other. One file,
///   one tap. The simulator has no camera, so without this the shutter delivers nothing.
/// - **Pair.** `ARCHIVECAP_E2E_PAIR` holds a Wi-Fi QR payload (`{host, port, token, name}`); an unpaired app
///   pairs from it at launch through `connectFromQR`, the scanner's own path. With `ARCHIVECAP_E2E_CABLE=1`
///   it pairs through `connectCableFromQR` instead, the Connect screen's Cable path (W40.i-usb-build), and the
///   payload's empty host leaves the relay as the only way to the Mac.
/// - **Drive.** `ARCHIVECAP_E2E_DRIVE=1` makes the capture screen run, per JPEG in `Documents/e2e-inbox/`
///   in name order, what the Android driver taps: drop the file at the inject seam, press the shutter, End
///   segment, then "Skip (tag on Mac)". The simulator has no `adb input`, so the driver presses the buttons'
///   own actions rather than synthesising touches; the shutter goes through the screen's `capture(.document)`.
///   Progress goes to `Documents/e2e-status.txt`, one line per step, which the script polls; after each
///   capture the driver waits for the script's `Documents/e2e-shot-<n>` so the screenshot shows that page.
/// - **Feed (W40.i-sim-ui).** `ARCHIVECAP_UITEST_FEED=<dir>` makes every shutter, Box and Folder press take the
///   next JPEG of that host directory in name order, moving it out first, when no `test_inject.jpg` waits. The
///   UI test (`ArchiveCaptureiOSUITests`) taps the real buttons; this is only the camera the simulator lacks.
enum E2EHarness {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var pairPayload: String? { env["ARCHIVECAP_E2E_PAIR"].flatMap { $0.isEmpty ? nil : $0 } }
    static var drives: Bool { env["ARCHIVECAP_E2E_DRIVE"] == "1" }
    static var cable: Bool { env["ARCHIVECAP_E2E_CABLE"] == "1" }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var injectURL: URL { documents.appendingPathComponent("test_inject.jpg") }
    static var inboxDir: URL { documents.appendingPathComponent("e2e-inbox", isDirectory: true) }
    private static var statusURL: URL { documents.appendingPathComponent("e2e-status.txt") }

    /// The injected shot, consumed: nil when no file is waiting (the real camera path runs).
    static func takeInjected() -> Data? {
        guard let data = try? Data(contentsOf: injectURL) else { return takeFed() }
        try? FileManager.default.removeItem(at: injectURL)
        return data
    }

    /// The UI test's feed: the next JPEG of `ARCHIVECAP_UITEST_FEED`, consumed (renamed `.used`, so the script
    /// can count what the shutter took). Nil when the feed is unset or empty.
    private static func takeFed() -> Data? {
        guard let dir = env["ARCHIVECAP_UITEST_FEED"], !dir.isEmpty else { return nil }
        let feed = URL(fileURLWithPath: dir, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(at: feed, includingPropertiesForKeys: nil)) ?? []
        guard let next = names.filter({ $0.pathExtension.lowercased() == "jpg" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              let data = try? Data(contentsOf: next) else { return nil }
        let used = next.appendingPathExtension("used")
        guard (try? FileManager.default.moveItem(at: next, to: used)) != nil else { return nil }
        NSLog("[e2e] fed %@", next.lastPathComponent)
        return data
    }

    /// Whether the script has screenshotted page `n` (it creates `Documents/e2e-shot-<n>`).
    static func shotTaken(_ n: Int) -> Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent("e2e-shot-\(n)").path)
    }

    /// The inbox's JPEGs in name order (doc1…, doc2…), for the driver.
    static func inbox() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Move one inbox file to the inject seam (a move, so a rerun never shoots a page twice).
    static func stage(_ url: URL) -> Bool {
        try? FileManager.default.removeItem(at: injectURL)
        return (try? FileManager.default.moveItem(at: url, to: injectURL)) != nil
    }

    /// Append one progress line (`paired`, `captured 1`, `ended 1`, `DONE 3`, `FAIL <why>`).
    static func status(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: statusURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: statusURL, options: .atomic)
        }
        NSLog("[e2e] %@", line)
    }

    /// Poll `cond` on the main actor every 100 ms until it holds or `seconds` pass. False on cancellation too:
    /// a cancelled `Task.sleep` throws at once, so swallowing it would spin the main thread to the deadline.
    @MainActor
    static func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() > deadline { return false }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return true
    }

    /// The driver runs once per launch: a capture screen that reappears (a new view identity re-runs `.task`)
    /// must not drive the inbox's remainder a second time under the same `captured N` lines.
    @MainActor private static var driven = false
    @MainActor static func claimDrive() -> Bool { if driven { return false }; driven = true; return true }
}
#endif
