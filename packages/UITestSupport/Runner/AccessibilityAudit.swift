// AccessibilityAudit.swift — the suite's accessibility audit for XCUITest (W40.e3). ONE file, compiled into all
// three UI-test bundles (Reader, Notes, Processor) beside `LayoutGuard.swift`, through the same `project.yml`
// source path, for the same reason: three copies of a helper are how they drift.
//
// WHAT IT DOES. `AccessibilityAudit.audit(...)` runs Xcode's own `performAccessibilityAudit(for: .all)` on the
// screen the test has just opened — on macOS that is contrast, element detection, hit region, sufficient element
// description, action and parent/child — and then decides itself what fails. Xcode's default is to record every
// issue as a test failure with only its short text; this records each one with the element it names (type,
// identifier, label, frame), prints it under an `[a11y-audit]` prefix so a VM log can be grepped, and attaches a
// screenshot of the screen for any state with an issue.
//
// FINDINGS ARE FILED, NOT SILENCED. A reproduced issue that has been filed as a `W40.fix-*` item goes into the
// sweep's `known:` list as a `KnownIssue`, matched on the audit type and the element's identity — never on message
// text, which would swallow a new defect with the same wording. A known issue is reported inside
// `XCTExpectFailure`, so it does not turn the run red; any OTHER issue does; and a known issue that stops
// reproducing fails the run and says so, so the fix's session must delete the entry (the layout guard's rule).
// An `Exemption` is for an issue that is not the app's to fix — an element AppKit draws for every window — and
// must say why in its `reason`.
//
// What it cannot see: anything the audit does not model (VoiceOver reading order, keyboard-only reachability
// across a whole task, Dynamic Type, which macOS does not have). Those stay with the visual and journey reviews.

import XCTest

/// One issue the audit reported, copied out with the element it names so a `KnownIssue` can match on identity.
struct AuditFinding: CustomStringConvertible {
    var audit: String
    var type: XCUIElement.ElementType?
    var identifier = ""
    var label = ""
    var frame = CGRect.null
    var compact: String
    var detailed: String

    var element: String {
        guard let type else { return "(no element)" }
        let id = identifier.isEmpty ? "" : "#\(identifier)"
        let text = label.count > 40 ? String(label.prefix(40)) + "…" : label
        return "\(type.layoutGuardName)\(id)\(text.isEmpty ? "" : " \"\(text)\"") \(LayoutGuard.fmt(frame))"
    }
    var description: String { "[\(audit)] \(element): \(compact)" }
}

enum AccessibilityAudit {

    /// A reproduced, filed accessibility bug the audit expects to see until its fix lands (see the header).
    struct KnownIssue {
        var tag: String
        var matches: (AuditFinding) -> Bool
    }

    /// An issue that is not the app's to fix. `reason` is printed beside every finding it exempts.
    struct Exemption {
        var reason: String
        var matches: (AuditFinding) -> Bool
    }

    /// Exemptions every suite shares: none yet. Each one added here must name what it was seen on, and why.
    @MainActor static let shared: [Exemption] = []

    static func name(_ t: XCUIAccessibilityAuditType) -> String {
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

    /// Audit what `app` shows now. `screen` names it in messages ("navigation window, dark"). Fails the test with
    /// every issue that is neither known nor exempt, and with every known issue that no longer reproduces.
    @MainActor
    static func audit(_ app: XCUIApplication, screen: String, in test: XCTestCase,
                      known: [KnownIssue] = [], exempt: [Exemption] = [],
                      file: StaticString = #filePath, line: UInt = #line) {
        var found: [AuditFinding] = []
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                var f = AuditFinding(audit: name(issue.auditType), compact: issue.compactDescription,
                                     detailed: issue.detailedDescription)
                // `snapshot()` throws rather than failing the test when the element has gone, which the
                // property getters would do.
                if let snap = try? issue.element?.snapshot() {
                    f.type = snap.elementType
                    f.identifier = snap.identifier
                    f.label = snap.label.isEmpty ? ((snap.value as? String) ?? "") : snap.label
                    f.frame = snap.frame
                }
                found.append(f)
                return true   // handled here: this function decides what fails
            }
        } catch {
            XCTFail("accessibility audit: \(screen) — the audit did not run: \(error)", file: file, line: line)
            return
        }

        var unexpected: [AuditFinding] = []
        var knownSeen: [String: [AuditFinding]] = [:]
        for f in found {
            if let e = (shared + exempt).first(where: { $0.matches(f) }) {
                print("[a11y-audit] \(screen): exempt (\(e.reason)) \(f)")
            } else if let k = known.first(where: { $0.matches(f) }) {
                knownSeen[k.tag, default: []].append(f)
                print("[a11y-audit] \(screen): known \(k.tag) \(f)")
            } else {
                unexpected.append(f)
                print("[a11y-audit] \(screen): ISSUE \(f)\n    \(f.detailed)")
            }
        }
        print("[a11y-audit] \(screen): \(found.count) issue(s), \(unexpected.count) unexpected"
              + knownSeen.keys.sorted().map { ", \(knownSeen[$0]!.count) from \($0)" }.joined())

        if !found.isEmpty {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "a11y-audit \(screen)"
            shot.lifetime = .keepAlways
            test.add(shot)
        }
        if !unexpected.isEmpty {
            XCTFail("accessibility audit: \(screen)\n  " + unexpected.map(\.description).joined(separator: "\n  "),
                    file: file, line: line)
        }
        for k in known {
            if let seen = knownSeen[k.tag] {
                XCTExpectFailure("\(k.tag) — filed, not yet fixed") {
                    XCTFail("accessibility audit: \(screen), \(k.tag)\n  "
                            + seen.map(\.description).joined(separator: "\n  "), file: file, line: line)
                }
            } else {
                XCTFail("accessibility audit: \(screen) — \(k.tag) no longer reproduces. If it has been fixed, "
                        + "delete its KnownIssue from this audit.", file: file, line: line)
            }
        }
    }
}
