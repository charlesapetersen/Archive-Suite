// vm-check-accessibility.swift — run INSIDE the GUI VM: prove the Accessibility API actually answers
// BEFORE the xcuitest lane runs, so a guest permission fault can never masquerade as a product bug.
//
// WHY THIS EXISTS (2026-08-10). Every XCUITest in BOTH apps failed with "Main window should appear",
// twice in a row, and the health gate parked the daemon on `gui-vm` as a "reproducible build/test
// regression". It was nothing of the kind. The apps were drawing perfectly — `CGWindowList` showed the
// Reader's navigation window at its usual 900×612 — but XCUITest reads the **accessibility tree**, and in
// the guest that tree had gone dark:
//
//     AXIsProcessTrusted() == false
//     AXUIElementCopyAttributeValue(app, kAXWindows) == -25211  (kAXErrorAPIDisabled)
//
// The cause was a stale TCC grant. Everything `tart exec` starts is attributed to the guest agent as its
// RESPONSIBLE process, so the whole lane borrows the agent's Accessibility grant. That row was still
// present and still `auth_value = 2`, but its stored code requirement pinned two cdhashes that the
// installed binary no longer has, so `tccd` refused it outright:
//
//     Failed to match existing code requirement for subject …/tart-guest-agent
//         and service kTCCServiceAccessibility
//     AUTHREQ_RESULT: authValue=0, authReason=5
//
// A grant that exists, reads as "allowed", and is silently not honoured is invisible from the outside —
// which is exactly why it cost a day of hunting a phantom regression and then parked the run. The lane
// must therefore ASK the accessibility API a question it can only answer when the grant is live, and say
// so in the guest's own words when it isn't. Re-seed with `ops/gui/vm-seed-accessibility.sh`.
//
// This deliberately probes a REAL app rather than trusting `AXIsProcessTrusted()` alone: trust is
// per-responsible-process and can read true while a query against another process still fails. With no
// pid it degrades to the trust check, which is the half that needs no app running.
//
// USAGE:  swift vm-check-accessibility.swift [PID]
// Exit 0 = the API answered (lane may proceed). 1 = denied/disabled. 2 = probe could not run.
import ApplicationServices
import Foundation

func note(_ message: String) { print("vm-check-accessibility: \(message)") }
func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("vm-check-accessibility: \(message)\n".utf8))
    exit(code)
}

let trusted = AXIsProcessTrusted()
note("AXIsProcessTrusted() = \(trusted)")

// No pid: the trust flag is all we can check. Treat untrusted as fatal — the lane cannot work without it.
guard let pidArg = CommandLine.arguments.dropFirst().first else {
    if trusted { note("accessibility is live (no pid given — trust flag only)"); exit(0) }
    fail(1, "the Accessibility API is NOT authorised for this guest session. Every XCUITest window "
          + "assertion will fail while this is true, and the app under test is probably fine. "
          + "Re-seed with ops/gui/vm-seed-accessibility.sh, then re-run.")
}
guard let pid = pid_t(pidArg) else { fail(2, "'\(pidArg)' is not a pid") }

// The real question: can we enumerate another process's windows? That is precisely what XCUITest does.
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)

// -25211 kAXErrorAPIDisabled / -25204 kAXErrorCannotComplete are the permission-shaped failures. Anything
// else (a dead pid, say) is a bad probe rather than a verdict, so it exits 2 and the caller can tell the
// difference between "the guest is not authorised" and "my probe was wrong".
switch err {
case .success:
    let count = (value as? [AXUIElement])?.count ?? 0
    note("AXUIElementCopyAttributeValue(kAXWindows) on pid \(pid) → \(count) window(s)")
    if !trusted {
        fail(1, "the query answered but this session is not trusted — treat as denied")
    }
    note("accessibility is live")
    exit(0)
case .apiDisabled, .cannotComplete, .notImplemented:
    fail(1, "the Accessibility API is NOT authorised for this guest session (AXError \(err.rawValue) "
          + "querying pid \(pid)). Every XCUITest window assertion will fail while this is true, and "
          + "the app under test is probably fine — check pixels before believing a UI regression. "
          + "Re-seed with ops/gui/vm-seed-accessibility.sh, then re-run.")
default:
    fail(2, "probe inconclusive: AXError \(err.rawValue) querying pid \(pid) — is that pid still alive?")
}
