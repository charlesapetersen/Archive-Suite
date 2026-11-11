// vm-set-display.swift — run INSIDE the GUI VM: raise the guest's screen resolution to at least
// WIDTHxHEIGHT so the apps under test get a window big enough to show their whole UI.
//
// WHY THIS EXISTS (W21.vmgui-c, measured 2026-08-01). `tart run --no-graphics` gives the guest no
// attached display, so its WindowServer comes up at the headless default **1024×768** — regardless of
// the VM's configured `Display` (ours reads `1920x1200` in `tart get`, and the guest still ran at
// 1024×768). The Archive Notes browser shell needs ~1084 pt of width for its three panes
// (tree 220 + list 490 + detail 360 + 2 dividers), so at 1024 SwiftUI centred the oversized content and
// clipped ~92 pt off EACH side of the window: the sidebar's "Add folder" button sat at x = −19 and the
// editor's raw-Markdown toggle at x = 1033, i.e. off-screen. Four `ArchiveNotesUITests` then failed as
// "is not hittable" / "seam must be drivable" — one harness geometry problem wearing four product-bug
// costumes. The guest advertises 16 modes up to 3840×2400; it simply had not been asked for one.
//
// 1× ONLY (W40.vm-macos27-harness, measured 2026-11-10). The macOS 27.2 guest boots at 1920×1200 POINTS
// backed by 3840×2400 PIXELS (2×, HiDPI); macOS 26 came up at 1×. The old point-size-only check read that
// as "already 1920×1200 — nothing to do", so every screenshot doubled (the snapshot reference went
// 300×180 → 600×360) and pixel checks that crop by point frames sampled the wrong place (contrast 1.0:1,
// the transient recorder's "no watched section changed"). The guest lists a 1× 1920×1200 mode only
// when asked for the low-resolution duplicates, so this asks for them and requires
// pixelWidth == width; the current mode counts as "already there" only when it is 1× too.
//
// USAGE:  swift vm-set-display.swift [WIDTH] [HEIGHT]        (default 1920 1200)
// Exits 0 when the display already meets the target or was switched successfully; non-zero otherwise,
// with the reason on stderr — the callers WARN loudly rather than dying, because a too-small display
// degrades a lane (Notes) instead of breaking it (Reader is fine at 1024×768).
import CoreGraphics
import Foundation

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("vm-set-display: \(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
let wantW = args.count > 1 ? (Int(args[1]) ?? 1920) : 1920
let wantH = args.count > 2 ? (Int(args[2]) ?? 1200) : 1200

let display = CGMainDisplayID()
guard display != 0 else { fail(2, "no main display — is a WindowServer session running in this guest?") }

func describe(_ m: CGDisplayMode?) -> String {
    guard let m else { return "?" }
    return m.pixelWidth == m.width ? "\(m.width)×\(m.height)" : "\(m.width)×\(m.height)@\(m.pixelWidth / max(m.width, 1))x"
}
let current = CGDisplayCopyDisplayMode(display)
let curW = current?.width ?? CGDisplayPixelsWide(display), curH = current?.height ?? CGDisplayPixelsHigh(display)
let curIs1x = current.map { $0.pixelWidth == $0.width } ?? true
if curW >= wantW && curH >= wantH && curIs1x {
    print("vm-set-display: already \(describe(current)) (target \(wantW)×\(wantH) at 1×) — nothing to do")
    exit(0)
}

let lowRes = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
guard let allModes = CGDisplayCopyAllDisplayModes(display, lowRes) as? [CGDisplayMode], !allModes.isEmpty else {
    fail(3, "display \(display) advertises no modes (currently \(describe(current)))")
}
let modes = allModes.filter { $0.pixelWidth == $0.width && $0.pixelHeight == $0.height && $0.isUsableForDesktopGUI() }

// Prefer the exact target; otherwise the largest mode that fits inside it (never overshoot the target —
// an over-large screen is harmless but the caller asked for a specific geometry, and modes above the
// target are the 3840×2400-class ones whose scaling behaviour we have not verified here).
let chosen = modes.first { $0.width == wantW && $0.height == wantH }
    ?? modes.filter { $0.width <= wantW && $0.height <= wantH }
            .max { ($0.width * $0.height) < ($1.width * $1.height) }
guard let mode = chosen, mode.width > curW || mode.height > curH || !curIs1x else {
    fail(4, "no 1× mode ≥ current \(describe(current)) and ≤ target \(wantW)×\(wantH); available: "
          + allModes.map(describe).joined(separator: " "))
}

var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success, let config else {
    fail(5, "CGBeginDisplayConfiguration failed")
}
let set = CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
guard set == .success else {
    CGCancelDisplayConfiguration(config)
    fail(6, "CGConfigureDisplayWithDisplayMode(\(mode.width)×\(mode.height)) failed (\(set.rawValue))")
}
// `.permanently` so a later run of either lane finds the display already correct and no-ops.
let done = CGCompleteDisplayConfiguration(config, .permanently)
guard done == .success else { fail(7, "CGCompleteDisplayConfiguration failed (\(done.rawValue))") }

// The WindowServer resizes asynchronously; give it a beat so a caller that immediately launches an app
// sees the new geometry, then report what actually took effect (never just what we asked for).
Thread.sleep(forTimeInterval: 2.0)
let now = CGDisplayCopyDisplayMode(display)
print("vm-set-display: \(describe(current)) → \(describe(now))"
      + " (asked \(describe(mode)), target \(wantW)×\(wantH) at 1×)")
// Report a switch that did not take as a failure, so the caller's WARN fires instead of a false OK.
guard let now, now.pixelWidth == now.width, now.width >= mode.width else { fail(8, "the new mode did not take effect") }
