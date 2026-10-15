import Foundation
import XCTest

/// W40.e2 — lets `ops/verify/leaks-harvest.sh` run `leaks` on this app-hosted test process after the
/// last test, before it exits. Inert unless the run sets `TEST_RUNNER_AS_LEAKS_HOLD=1`.
///
/// Why not `leaks -atExit`: that works by setting `DYLD_INSERT_LIBRARIES`, which on an app-hosted bundle
/// replaces Xcode's own injector, and the runner then never connects (measured 2026-10-15: "The test
/// runner hung before establishing connection"). So the host runs `leaks <pid>` instead, and this hold
/// keeps the process alive for it: print the pid, wait for SIGUSR1 (or the time limit), then let XCTest
/// exit as usual. The bundle's `NSPrincipalClass` (project.yml) makes XCTest create it at load.
///
/// Mirrored in ArchiveNotesTests/LeakHarvestHold.swift under its own Objective-C name; keep them alike.
@objc(ARLeakHarvestHold)
final class LeakHarvestHold: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let env = ProcessInfo.processInfo.environment
        guard env["AS_LEAKS_HOLD"] == "1" else { return }
        let limit = Double(env["AS_LEAKS_HOLD_SECONDS"] ?? "") ?? 900
        signal(SIGUSR1, SIG_IGN)   // the dispatch source below still sees it; the default would kill us
        let released = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler { released.signal() }
        source.resume()
        FileHandle.standardError.write(Data("[leaks-hold] pid=\(getpid())\n".utf8))
        let outcome = released.wait(timeout: .now() + limit)
        source.cancel()
        let note = outcome == .success ? "released" : "timed out after \(Int(limit)) s"
        FileHandle.standardError.write(Data("[leaks-hold] \(note)\n".utf8))
    }
}
