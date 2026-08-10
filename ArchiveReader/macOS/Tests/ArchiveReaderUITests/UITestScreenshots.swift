import XCTest

/// Where a screenshot is written so a human can READ it after the run.
///
/// ⚠️ **The VM's artifact share is NOT reachable from a test, and that was measured, not assumed.**
/// `ops/gui/vm-gui-runner.sh` mounts the host's `~/.tart-mirror/vm-artifacts` into the guest at
/// `/Volumes/My Shared Files/out`, so writing a PNG there *would* land it on the host with no
/// extraction step. But the XCUITest **runner is sandboxed** — the same trap as the GUI fixture path
/// (see `FixtureUITestCase`) — so that share is not writable from inside a test, and the first version
/// of this helper reported "no writable artifact dir" for all five shots of a run (2026-08-09).
///
/// So write to the runner's own temporary directory, which the sandbox always permits, and print the
/// path. `run_xcuitest` in `vm-gui-runner.sh` greps those `[shot] …: wrote <path>` lines out of the log
/// afterwards and copies each file to the host over the *unsandboxed* `tart exec` — which is what makes
/// STEP 3.5's "READ the screenshot from `~/.tart-mirror/vm-artifacts/`" true. The share is still tried
/// first (it costs one `isWritableFile` call and works if a future runner is unsandboxed), and
/// `AR_UITEST_SHOT_DIR` is tried ahead of it. Each candidate must be *writable* to be chosen, so an
/// override that the sandbox refuses falls through here rather than losing the shot.
///
/// This is a *diagnostic* channel, never an assertion: no test may pass or fail on where a shot went.
enum UITestShots {
    static let directory: URL = {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["AR_UITEST_SHOT_DIR"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append("/Volumes/My Shared Files/out")
        for path in candidates where FileManager.default.isWritableFile(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }()
}

extension XCTestCase {

    /// Capture the whole screen, attach it to the result bundle, and write it as `uitest-<name>.png`
    /// where the VM lane can collect it (see `UITestShots.directory`).
    ///
    /// The whole screen rather than one window on purpose: these shots are read to answer "did it
    /// actually DRAW", and a window-scoped capture of a pane that rendered nothing looks much like one
    /// that rendered. Returns the written path (nil only if the write itself failed).
    ///
    /// Both the attachment and the file are kept. The attachment alone is not enough: `xcresulttool`
    /// refuses a result bundle that was never finalized (a killed or failed run leaves one with no
    /// `Info.plist`), and recovering shots from `…xcresult/Data` then means classifying blobs by magic
    /// bytes — which is how the shots for `W26.docs-fu1` were read the first time.
    ///
    /// Lives on `XCTestCase` rather than on `FixtureUITestCase` because `WarmStartUITests` builds and
    /// launches its own corpus and cannot inherit that class's fixture `setUp` (`W26.verify-fu2`).
    @MainActor
    @discardableResult
    func captureScreenshot(_ name: String) -> URL? {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = UITestShots.directory.appendingPathComponent("uitest-\(name).png")
        do {
            try shot.pngRepresentation.write(to: url, options: .atomic)
            print("[shot] \(name): wrote \(url.path)")
            return url
        } catch {
            print("[shot] \(name): could not write \(url.path) — \(error)")
            return nil
        }
    }
}
