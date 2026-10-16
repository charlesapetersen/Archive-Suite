// TransientCheck.swift — the RUNNER-side half of the transient-state check (W40.e13), compiled into all three
// UI-test bundles. The app-side recorder (`../App/TransientRecorder.swift`) samples the watched sections after every
// committed run-loop pass and judges each transition with `../Shared/TransientAnalysis.swift`; this file launches
// it, drives one transition at a time, and reads its report back through the accessibility tree.
//
// A SUITE USES IT like this: launch with `TransientCheck.launchArguments(sections:)`, then
//     TransientCheck.check("next note", in: app, test: self) { row.click() }
// which waits for the screen to be idle, runs the action, waits for the recorder to see the transition settle,
// and fails on every finding the recorder reported for it. `known:` carries a filed defect as a strict expected
// failure, as the layout guard does: it fails the run once the defect stops reproducing.
//
// The checker is shown to fail twice before its passes are trusted: `TransientCheckSelfTest.run()` feeds the
// analysis synthetic flickers of every kind, and each suite runs one transition with the planted flicker
// (`-ArchiveTransientPlant blink`), which must be reported.

import XCTest

@MainActor
enum TransientCheck {
    static let sectionsArgument = "-ArchiveTransientSections"
    static let plantArgument = "-ArchiveTransientPlant"
    static let reportIdentifier = "ui.transient.report"
    /// Watches every element of every sheet (`TransientRecorder.sheetsSection`).
    static let sheets = "@sheets"

    static func launchArguments(sections: [String], plant: Bool = false) -> [String] {
        [sectionsArgument, sections.joined(separator: ",")] + (plant ? [plantArgument, "blink"] : [])
    }

    /// A filed defect the recorder is expected to report, matched on a finding's line.
    struct KnownIssue {
        let tag: String
        let matches: (String) -> Bool
    }

    struct Report {
        var transitions = 0
        var idle = false
        var samples = 0
        var walkMaxMs = 0
        var plants = 0
        var changing = ""
        var header = ""
        var findings: [(transition: Int, line: String)] = []

        init?(_ text: String) {
            var lines = text.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { return nil }
            header = lines.removeFirst()
            var fields: [String: Int] = [:]
            for pair in header.split(separator: " ") {
                let kv = pair.split(separator: "=")
                if kv.count == 2, let n = Int(kv[1]) { fields[String(kv[0])] = n }
            }
            guard let t = fields["transitions"] else { return nil }
            transitions = t
            idle = fields["idle"] == 1
            samples = fields["samples"] ?? 0
            walkMaxMs = fields["walkMaxMs"] ?? 0
            plants = fields["plants"] ?? 0
            changing = header.components(separatedBy: "changing=").dropFirst().first ?? ""
            findings = lines.compactMap { line in
                guard line.hasPrefix("#"), let space = line.firstIndex(of: " "),
                      let n = Int(line[line.index(after: line.startIndex)..<space]) else { return nil }
                return (n, String(line[line.index(after: space)...]))
            }
        }
    }

    static func read(_ app: XCUIApplication) -> Report? {
        let element = app.staticTexts[reportIdentifier]
        guard element.exists else { return nil }
        return Report((element.value as? String) ?? "")
    }

    /// Waits until the recorder reports idle twice, `quiet` seconds apart, with no transition in between.
    static func waitIdle(_ app: XCUIApplication, timeout: TimeInterval = 30, quiet: TimeInterval = 1.0) -> Report? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Report?
        while Date() < deadline {
            if let r = read(app), r.idle {
                if let p = previous, p.transitions == r.transitions { return r }
                previous = r
                Thread.sleep(forTimeInterval: quiet)
            } else {
                previous = nil
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        return nil
    }

    /// Runs `action` as one transition and fails on each finding the recorder reports for it. Returns the
    /// findings, known ones included, so a caller can assert on them (the planted-flicker test does).
    @discardableResult
    static func check(_ name: String, in app: XCUIApplication, test: XCTestCase, known: [KnownIssue] = [],
                      expectFindings: Bool = false, file: StaticString = #filePath, line: UInt = #line,
                      _ action: () -> Void) -> [String] {
        guard let before = waitIdle(app) else {
            XCTFail("transient: \(name): the recorder never reported idle before the action "
                    + "(is the app launched with TransientCheck.launchArguments?)", file: file, line: line)
            return []
        }
        action()
        let deadline = Date().addingTimeInterval(30)
        var after: Report?
        while Date() < deadline {
            if let r = waitIdle(app, timeout: 5), r.transitions > before.transitions { after = r; break }
        }
        guard let after else {
            let now = read(app)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "transient — \(name) — never settled"
            shot.lifetime = .keepAlways
            test.add(shot)
            let why = now.map { $0.changing.isEmpty
                ? "no watched section changed — the action did nothing on screen, or the watched sections are not "
                    + "the ones it changes"
                : "the screen never settled; still changing: \($0.changing)" } ?? "the report is gone"
            XCTFail("transient: \(name): \(why) [\(now?.header ?? "")]", file: file, line: line)
            return []
        }
        let lines = after.findings.filter { $0.transition > before.transitions }.map(\.line)
        let summary = "transient: \(name): \(after.transitions - before.transitions) transition(s), "
            + "\(lines.count) finding(s), \(after.samples - before.samples) samples, walk ≤ \(after.walkMaxMs) ms"
        print(([summary] + lines.map { "  " + $0 }).joined(separator: "\n"))
        let attachment = XCTAttachment(string: ([summary] + lines).joined(separator: "\n"))
        attachment.name = "transient — \(name)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if expectFindings {
            if lines.isEmpty { XCTFail("transient: \(name): expected findings, got none", file: file, line: line) }
            return lines
        }
        var unmatched = Set(known.map(\.tag))
        for finding in lines {
            if let k = known.first(where: { $0.matches(finding) }) {
                unmatched.remove(k.tag)
                print("  (known: \(k.tag))")
            } else {
                XCTFail("transient: \(name): \(finding)", file: file, line: line)
            }
        }
        for tag in unmatched.sorted() {
            XCTFail("transient: \(name): \(tag) no longer reproduces — delete its KnownIssue", file: file, line: line)
        }
        return lines
    }
}

/// Feeds the pure analysis synthetic sequences: every kind of flicker must be reported as that kind, and a clean
/// transition and a smooth animation must pass.
enum TransientCheckSelfTest {
    static func run(file: StaticString = #filePath, line: UInt = #line) {
        func e(_ id: String, _ text: String, h: Int = 20, y: Int = 0) -> TransientEntry {
            TransientEntry(role: "AXStaticText", identifier: id, text: text, x: 0, y: y, w: 100, h: h)
        }
        func s(_ entries: TransientEntry...) -> TransientSectionState { TransientSectionState(entries: entries) }
        func kinds(_ states: [TransientSectionState]) -> [TransientFinding.Kind] {
            TransientAnalysis.findings(section: "x", states: states).map(\.kind)
        }
        let a = s(e("x.title", "Moore"), e("x.date", "1968"))
        let b = s(e("x.title", "Intel"), e("x.date", "1971"))
        XCTAssertEqual(kinds([a, b]), [], "a direct change is clean", file: file, line: line)
        XCTAssertEqual(kinds([a]), [], "no change is clean", file: file, line: line)
        XCTAssertEqual(kinds([a, s(e("x.title", ""), e("x.date", "")), b]), [.value],
                       "an empty inspector between two notes", file: file, line: line)
        XCTAssertEqual(kinds([a, s(e("x.title", "Intel"), e("x.date", "1968")), b]), [.value],
                       "a half-updated inspector", file: file, line: line)
        XCTAssertEqual(kinds([a, b, a, b]), [.reverted], "new, old, new", file: file, line: line)
        XCTAssertEqual(kinds([a, s(), b]), [.removed], "the section left and came back", file: file, line: line)
        XCTAssertEqual(kinds([a, s(e("x.title", "Moore", h: 34), e("x.date", "1968")), a]), [.geometry],
                       "a height that grows and settles back", file: file, line: line)
        let tall = s(e("x.title", "Moore", h: 40), e("x.date", "1968"))
        XCTAssertEqual(kinds([a, s(e("x.title", "Moore", h: 30), e("x.date", "1968")),
                              s(e("x.title", "Moore", h: 25), e("x.date", "1968")), tall]), [.geometry],
                       "a height that turns back inside its range", file: file, line: line)
        XCTAssertEqual(kinds([a, s(e("x.title", "Moore"), e("x.date", "1968"), e("x.extra", "")), a]),
                       [.value, .structure], "an element added and removed again", file: file, line: line)
        XCTAssertEqual(kinds([a, s(e("x.title", "Moore", h: 27), e("x.date", "1968")),
                              s(e("x.title", "Moore", h: 33), e("x.date", "1968")), tall]), [],
                       "a smooth animation from one height to another is clean", file: file, line: line)
        XCTAssertNotNil(TransientCheck.Report("transitions=3 idle=1 samples=9 walkMaxMs=4 plants=0\n#2 x value: y"),
                        file: file, line: line)
        let r = TransientCheck.Report("transitions=3 idle=1 samples=9 walkMaxMs=4 plants=1\n#2 x value: y")
        XCTAssertEqual(r?.findings.first?.transition, 2, file: file, line: line)
        XCTAssertEqual(r?.findings.first?.line, "x value: y", file: file, line: line)
        XCTAssertEqual(r?.plants, 1, file: file, line: line)
    }
}
