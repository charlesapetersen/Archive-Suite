// AccessibilityAudit.swift — the suite's accessibility audit for XCUITest (W40.e3). ONE file, compiled into all
// three UI-test bundles (Reader, Notes, Processor) beside `LayoutGuard.swift`, through the same `project.yml`
// source path, for the same reason: three copies of a helper are how they drift.
//
// WHAT IT DOES. An `AccessibilityAudit` sweep runs Xcode's own `performAccessibilityAudit(for: .all)` on each
// screen a test opens — on macOS that is contrast, element detection, hit region, sufficient element description,
// action and parent/child — and then decides itself what fails. Xcode's default is to record every issue as a test
// failure with only its short text; this records each one with the element it names (type, identifier, label,
// frame), prints it under an `[a11y-audit]` prefix so a VM log can be grepped, and attaches a screenshot of the
// screen for any state with an issue.
//
// ONE WINDOW AT A TIME. The audit runs over the whole application: every open window, the menu bar, a lingering
// tooltip, and whatever lies behind the window in front. The first VM run (2026-10-16) reported the navigation
// window's issues again on every later screen, and contrast failures for list rows that the document window was
// covering. So `audit(window, …)` keeps only the issues whose element is inside that window's own accessibility
// tree (a sheet counts: it is the window's child), matched on type, identifier and frame against one snapshot of
// the window. The rest are counted and dropped; each window is audited on its own screen.
//
// CONTRAST IS CHECKED AGAINST THE PIXELS. Xcode's contrast verdicts did not hold up in the VM: of the Notes
// texts it failed on 2026-10-16, "Inbox" measured 7.4:1 from the screenshot, a list date 14.9:1, the window title
// 10:1 — while the real failures were secondary text at 3.2–4.2:1. So every contrast issue is measured from a
// screenshot taken after the audit (`ScreenPixels`: the commonest colour under the frame is the background, the
// pixel farthest from it in luminance is the text). Measured at or above WCAG AA — 4.5:1, or 3:1 for text 24 pt
// tall or more — it is printed as not reproduced and does not fail; below, it stays a finding, with its ratio.
// Anti-aliasing can only pull the text pixel towards the background, so the measure errs towards failing.
// Under 1.1:1 nothing is drawn under the frame at all — text a sheet covers (the Reader's "Tags in view" behind
// its preview sheet measured 1.01:1) — so it is counted as covered, not failed.
//
// ONE REPORT PER ISSUE. A sweep reports each distinct issue (audit type, element type, identifier, label, size)
// once, on the first screen it shows up on, so a sheet over the window does not repeat the window's findings.
//
// FINDINGS ARE FILED, NOT SILENCED. A reproduced issue that has been filed as a `W40.fix-*` item goes into the
// sweep's `known:` list as a `KnownIssue`, matched on the audit type and the element's identity — never on message
// text alone, which would swallow a new defect with the same wording. A known issue is reported inside
// `XCTExpectFailure`, so it does not turn the run red; any OTHER issue does; and a known issue that stops
// reproducing anywhere in the sweep fails `finish()` and says so, so the fix's session must delete the entry (the
// layout guard's rule). An `Exemption` is for an issue that is not the app's to fix — something AppKit draws, or
// a document's own content — and must say why in its `reason`.
//
// What it cannot see: anything the audit does not model (VoiceOver reading order, keyboard-only reachability
// across a whole task, Dynamic Type, which macOS does not have). Those stay with the visual and journey reviews.

import XCTest

/// One issue the audit reported, copied out with the element it names so a `KnownIssue` can match on identity.
struct AuditFinding: CustomStringConvertible {
    var audit: XCUIAccessibilityAuditType
    var type: XCUIElement.ElementType?
    var identifier = ""
    var label = ""
    var frame = CGRect.null
    var compact: String
    var detailed: String
    /// How many labelled elements the element contains, from the window's snapshot (0 for a leaf).
    var labelledDescendants = 0
    /// For a contrast issue: the contrast ratio measured from the screenshot (see `ScreenPixels`).
    var measured: Double?

    var auditName: String { AccessibilityAudit.name(audit) }
    var element: String {
        guard let type else { return "(no element)" }
        let id = identifier.isEmpty ? "" : "#\(identifier)"
        let text = label.count > 40 ? String(label.prefix(40)) + "…" : label
        return "\(type.layoutGuardName)\(id)\(text.isEmpty ? "" : " \"\(text)\"") \(LayoutGuard.fmt(frame))"
    }
    /// What makes two findings the same issue: position is left out, so a row seen again lower down, or a window
    /// that moved, does not count twice.
    var key: String {
        "\(audit.rawValue)|\(type?.rawValue ?? 0)|\(identifier)|\(label)|\(Int(frame.width))×\(Int(frame.height))"
    }
    var description: String {
        "[\(auditName)] \(element): \(compact)" + (measured.map { String(format: " (measured %.2f:1)", $0) } ?? "")
    }
}

@MainActor
final class AccessibilityAudit {

    /// A reproduced, filed accessibility bug the audit expects to see until its fix lands (see the header).
    /// `appearances` names the sweeps it must reproduce in; a contrast issue may be one appearance's only.
    struct KnownIssue {
        var tag: String
        var appearances: Set<String> = ["light", "dark"]
        var matches: (AuditFinding) -> Bool
    }

    /// An issue that is not the app's to fix. `reason` is printed beside every finding it exempts.
    struct Exemption {
        var reason: String
        var matches: (AuditFinding) -> Bool
    }

    /// Exemptions every suite shares. Each one added here must name what it was seen on, and why.
    static let shared: [Exemption] = [
        // Seen 2026-10-16 on the main window of all three apps: the 14×14 group AppKit wraps
        // around the close, minimise and zoom buttons. AppKit draws it; the app has no handle on it.
        Exemption(reason: "AppKit's title-bar button group") {
            $0.audit == .parentChild && $0.type == .group && $0.identifier.isEmpty
                && Int($0.frame.width) == 14 && Int($0.frame.height) == 14
        },
        // Seen 2026-10-16 on every SwiftUI `Picker` in the three apps — eleven of them, plain ones with nothing
        // custom about them included — and on three `Menu`s (the Reader's Saved Searches, Notes' New and heading
        // menus): "Action is missing".
        // SwiftUI builds these pop-ups itself and exposes no seam to add an accessibility action to them.
        Exemption(reason: "SwiftUI Picker/Menu pop-up; SwiftUI owns its actions") {
            $0.audit == .action && ($0.type == .popUpButton || $0.type == .menuButton)
        },
        // Seen 2026-10-16 in all three apps: SwiftUI's split panes, scroll and form containers, and list rows
        // that hold a label and a count. A container VoiceOver enters and whose contents are labelled is
        // navigable; a container with nothing labelled inside it still fails.
        Exemption(reason: "unlabelled container whose contents are labelled") {
            $0.audit == .sufficientElementDescription && $0.type == .group && $0.identifier.isEmpty
                && $0.label.isEmpty && $0.labelledDescendants > 0
        },
    ]

    nonisolated static func name(_ t: XCUIAccessibilityAuditType) -> String {
        switch t {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "sufficientElementDescription"
        case .action: "action"
        case .parentChild: "parentChild"
        default: "type \(t.rawValue)"
        }
    }

    private let app: XCUIApplication
    private let test: XCTestCase
    private let appearance: String
    private let known: [KnownIssue]
    private let exempt: [Exemption]
    private var reported = Set<String>()
    private var knownSeen = Set<String>()

    /// One sweep per test: `appearance` ("light"/"dark") is printed with every screen and decides which known
    /// issues `finish()` requires to have reproduced.
    init(_ app: XCUIApplication, appearance: String, in test: XCTestCase,
         known: [KnownIssue] = [], exempt: [Exemption] = []) {
        self.app = app
        self.test = test
        self.appearance = appearance
        self.known = known.filter { $0.appearances.contains(appearance) }
        self.exempt = Self.shared + exempt
    }

    /// Audit `window` as it is now (see the header for what counts as inside it). `screen` names it in messages.
    /// Fails the test with every new issue that is neither known nor exempt.
    func audit(_ window: XCUIElement, screen name: String, file: StaticString = #filePath, line: UInt = #line) {
        let screen = "\(name), \(appearance)"
        var found: [AuditFinding] = []
        // All six audits in one pass first. When that runs out of time (Xcode's own limit, error -56: seen on
        // every Notes screen in the first run), each audit runs on its own, so the ones that do finish still
        // report and the one that does not is named. An audit that never finishes fails the screen: a screen
        // nobody could audit has not passed.
        if let error = runAudit(.all, into: &found) {
            guard (error as NSError).code == -56 else {
                XCTFail("accessibility audit: \(screen) — the audit did not run: \(error)", file: file, line: line)
                return
            }
            print("[a11y-audit] \(screen): the combined audit ran out of time; running each audit on its own")
            found.removeAll()
            for type in Self.each {
                if let error = runAudit(type, into: &found) {
                    XCTFail("accessibility audit: \(screen) — the \(Self.name(type)) audit did not finish: \(error)",
                            file: file, line: line)
                }
            }
        }

        guard let tree = try? window.snapshot() else {
            XCTFail("accessibility audit: \(screen) — the window to audit is not there", file: file, line: line)
            return
        }
        // Every element in the window, with how many labelled elements it holds.
        var inWindow: [String: Int] = [:]
        @discardableResult func collect(_ s: XCUIElementSnapshot) -> Int {
            let inside = s.children.reduce(0) { $0 + collect($1) }
            inWindow[Self.placeKey(s.elementType, s.identifier, s.frame)] = inside
            return inside + (s.label.isEmpty ? 0 : 1)
        }
        collect(tree)
        let visible = tree.frame
        let screenshot = XCUIScreen.main.screenshot()
        let pixels = ScreenPixels(screenshot)

        var outside = 0, repeated = 0, offWindow = 0, notReproduced = 0, covered = 0
        var unexpected: [AuditFinding] = []
        var knownHere: [String: [AuditFinding]] = [:]
        for var f in found {
            // An issue with no element left to name cannot be placed, so it is kept rather than dropped.
            if let type = f.type {
                guard let n = inWindow[Self.placeKey(type, f.identifier, f.frame)] else { outside += 1; continue }
                f.labelledDescendants = n
            }
            // Contrast is measured from the pixels under the element's frame. Where the frame is not wholly on
            // the window — text scrolled below a Settings pane, a field running past the edge — those pixels
            // belong to something else, and the first run failed text the screenshot shows plainly legible.
            if f.audit == .contrast, f.type != nil, !visible.contains(f.frame) { offWindow += 1; continue }
            guard reported.insert(f.key).inserted else { repeated += 1; continue }
            if f.audit == .contrast, f.type != nil, let ratio = pixels?.contrast(under: f.frame) {
                f.measured = ratio
                if ratio < 1.1 {
                    covered += 1
                    print("[a11y-audit] \(screen): contrast not measurable, nothing drawn under the frame \(f)")
                    continue
                }
                if ratio >= (f.frame.height >= 24 ? 3 : 4.5) {
                    notReproduced += 1
                    print("[a11y-audit] \(screen): contrast not reproduced from the screenshot \(f)")
                    continue
                }
            }
            if let e = exempt.first(where: { $0.matches(f) }) {
                print("[a11y-audit] \(screen): exempt (\(e.reason)) \(f)")
            } else if let k = known.first(where: { $0.matches(f) }) {
                knownHere[k.tag, default: []].append(f)
                knownSeen.insert(k.tag)
                print("[a11y-audit] \(screen): known \(k.tag) \(f)")
            } else {
                unexpected.append(f)
                print("[a11y-audit] \(screen): ISSUE \(f)\n    \(f.detailed)")
            }
        }
        let new = found.count - outside - repeated - offWindow - notReproduced - covered
        print("[a11y-audit] \(screen): \(new) new issue(s), \(unexpected.count) unexpected"
              + knownHere.keys.sorted().map { ", \(knownHere[$0]!.count) from \($0)" }.joined()
              + " (\(repeated) seen on an earlier screen, \(outside) outside this window, "
              + "\(offWindow) contrast off the visible window, \(notReproduced) contrast not reproduced, "
              + "\(covered) contrast covered)")

        if new > 0 || notReproduced > 0 {
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = "a11y-audit \(screen)"
            shot.lifetime = .keepAlways
            test.add(shot)
        }
        if !unexpected.isEmpty {
            XCTFail("accessibility audit: \(screen)\n  " + unexpected.map(\.description).joined(separator: "\n  "),
                    file: file, line: line)
        }
        for (tag, seen) in knownHere.sorted(by: { $0.key < $1.key }) {
            XCTExpectFailure("\(tag) — filed, not yet fixed") {
                XCTFail("accessibility audit: \(screen), \(tag)\n  "
                        + seen.map(\.description).joined(separator: "\n  "), file: file, line: line)
            }
        }
    }

    private static let each: [XCUIAccessibilityAuditType] =
        [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild]

    /// Run `types` over the whole app, copying each issue into `found`. Returns the audit's error, if any.
    private func runAudit(_ types: XCUIAccessibilityAuditType, into found: inout [AuditFinding]) -> Error? {
        var batch: [AuditFinding] = []
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                var f = AuditFinding(audit: issue.auditType, compact: issue.compactDescription,
                                     detailed: issue.detailedDescription)
                // `snapshot()` throws rather than failing the test when the element has gone, which the
                // property getters would do.
                if let snap = try? issue.element?.snapshot() {
                    f.type = snap.elementType
                    f.identifier = snap.identifier
                    f.label = snap.label.isEmpty ? ((snap.value as? String) ?? "") : snap.label
                    f.frame = snap.frame
                }
                batch.append(f)
                return true   // handled here: this sweep decides what fails
            }
        } catch {
            found += batch
            return error
        }
        found += batch
        return nil
    }

    /// Call once the sweep's screens are done: every known issue for this appearance must have reproduced.
    func finish(file: StaticString = #filePath, line: UInt = #line) {
        for k in known where !knownSeen.contains(k.tag) {
            XCTFail("accessibility audit, \(appearance) — \(k.tag) no longer reproduces. If it has been fixed, "
                    + "delete its KnownIssue from this audit.", file: file, line: line)
        }
    }

    private static func placeKey(_ type: XCUIElement.ElementType, _ id: String, _ f: CGRect) -> String {
        "\(type.rawValue)|\(id)|\(Int(f.minX.rounded())),\(Int(f.minY.rounded())),"
            + "\(Int(f.width.rounded())),\(Int(f.height.rounded()))"
    }
}

/// The screen's pixels, for measuring a contrast issue (see the header). Built from one screenshot.
struct ScreenPixels {
    private let rgba: [UInt8]
    private let width: Int, height: Int
    private let scale: CGFloat

    @MainActor init?(_ shot: XCUIScreenshot) {
        guard let image = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        rgba = buffer
        width = w
        height = h
        scale = CGFloat(w) / max(shot.image.size.width, 1)   // pixels per point
    }

    /// WCAG contrast between the commonest colour under `frame` (screen points, top-left origin) and the pixel
    /// farthest from it in luminance. nil when the frame is not on the screenshot.
    func contrast(under frame: CGRect) -> Double? {
        let x0 = Int((frame.minX * scale).rounded()), y0 = Int((frame.minY * scale).rounded())
        let x1 = Int((frame.maxX * scale).rounded()), y1 = Int((frame.maxY * scale).rounded())
        guard x0 >= 0, y0 >= 0, x1 <= width, y1 <= height, x1 > x0, y1 > y0 else { return nil }
        var counts: [UInt32: Int] = [:]
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                counts[UInt32(rgba[i]) << 16 | UInt32(rgba[i + 1]) << 8 | UInt32(rgba[i + 2]), default: 0] += 1
            }
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let lb = Self.luminance(background)
        let lt = counts.keys.map(Self.luminance).max(by: { abs($0 - lb) < abs($1 - lb) }) ?? lb
        return (max(lb, lt) + 0.05) / (min(lb, lt) + 0.05)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16 & 0xFF) + 0.7152 * channel(rgb >> 8 & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }
}
