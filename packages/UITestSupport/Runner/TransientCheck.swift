// TransientCheck.swift — the RUNNER-side half of the transient-state check (W40.e13), compiled into all three
// UI-test bundles. The app-side recorder (`../App/TransientRecorder.swift`) samples the watched sections after every
// committed run-loop pass and judges each transition with `../Shared/TransientAnalysis.swift`; this file launches
// it, drives one transition at a time, and reads its report back through the accessibility tree.
//
// A SUITE USES IT like this: launch with `TransientCheck.launchArguments(sections:)`, then
//     TransientCheck.check("next note", in: app, test: self) { row.click() }
// which waits for the screen to be idle, runs the action, waits for the recorder to see the transition settle,
// and fails on every finding the recorder reported for it. `known:` carries a filed defect as a strict expected
// failure, as the layout guard does: it fails the run once the defect stops reproducing. A defect measured to
// show only on some runs is marked `intermittent` instead, and does not fail a run where it does not show.
//
// The checker is shown to fail twice before its passes are trusted: `TransientCheckSelfTest.run()` feeds the
// analysis synthetic flickers of every kind, and each suite runs one transition with the planted flicker
// (`-ArchiveTransientPlant blink`), which must be reported.

import XCTest

@MainActor
enum TransientCheck {
    static let sectionsArgument = "-ArchiveTransientSections"
    static let plantArgument = "-ArchiveTransientPlant"
    static let linksArgument = "-ArchiveTransientLinks"
    static let reportIdentifier = "ui.transient.report"
    /// Watches every element of every sheet (`TransientRecorder.sheetsSection`).
    static let sheets = "@sheets"

    /// `links` pairs elements whose texts must change in the same pass (`TransientLink`), each inside a section.
    static func launchArguments(sections: [String], links: [TransientLink] = [], plant: Bool = false) -> [String] {
        [sectionsArgument, sections.joined(separator: ",")]
            + (links.isEmpty ? [] : [linksArgument, links.map(\.description).joined(separator: ",")])
            + (plant ? [plantArgument, "blink"] : [])
    }

    /// A filed defect the recorder is expected to report, matched on a finding's line. `intermittent` is for a defect
    /// measured to show on some runs and not others (XCTest's non-strict expected failure): it is still printed and
    /// attached when it shows, and a run where it does not show is not a failure. Keep the matcher narrow, so that
    /// it cannot also swallow a different finding on the same transition.
    struct KnownIssue {
        let tag: String
        var intermittent = false
        let matches: (String) -> Bool
    }

    struct Report {
        var transitions = 0
        var idle = false
        var samples = 0
        var walkMaxMs = 0
        var plants = 0
        var ahead = 0
        var changing = ""
        var header = ""
        var findings: [(transition: Int, line: String)] = []
        /// Per transition: which sections changed, and how many elements each section held once settled.
        var changes: [(transition: Int, line: String)] = []

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
            ahead = fields["ahead"] ?? 0
            changing = header.components(separatedBy: "changing=").dropFirst().first ?? ""
            func numbered(_ mark: Character) -> [(Int, String)] { lines.compactMap { line in
                guard line.first == mark, let space = line.firstIndex(of: " "),
                      let n = Int(line[line.index(after: line.startIndex)..<space]) else { return nil }
                return (n, String(line[line.index(after: space)...]))
            } }
            findings = numbered("#")
            changes = numbered("@")
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
        // The guest's epoch at the action, for lining a screen video up with the transitions (transient-frames.py).
        print("transient-mark: \(String(format: "%.3f", Date().timeIntervalSince1970)) \(name)")
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
        let changes = after.changes.filter { $0.transition > before.transitions }.map(\.line)
        let summary = "transient: \(name): \(after.transitions - before.transitions) transition(s), "
            + "\(lines.count) finding(s), \(after.samples - before.samples) samples, walk ≤ \(after.walkMaxMs) ms"
            + (after.ahead > before.ahead ? ", \(after.ahead - before.ahead) ahead of the screen (skipped)" : "")
        print(([summary] + changes.map { "  · " + $0 } + lines.map { "  " + $0 }).joined(separator: "\n"))
        let attachment = XCTAttachment(string: ([summary] + lines).joined(separator: "\n"))
        attachment.name = "transient — \(name)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if expectFindings {
            if lines.isEmpty { XCTFail("transient: \(name): expected findings, got none", file: file, line: line) }
            return lines
        }
        var unmatched = Set(known.filter { !$0.intermittent }.map(\.tag))
        for finding in lines {
            if let k = known.first(where: { $0.matches(finding) }) {
                unmatched.remove(k.tag)
                print("  (known\(k.intermittent ? ", intermittent" : ""): \(k.tag))")
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
        // THE SLIDE ALLOWANCE (W40.fix-split-animation-wobble): a wobble up to 1/20 of how far the element slides.
        func slide(_ ys: [Int], _ hs: [Int]) -> [TransientFinding.Kind] {
            kinds(zip(ys, hs).map { s(e("x.title", "Moore", h: $1, y: $0), e("x.date", "1968")) })
        }
        func slideWide(_ xs: [Int], _ ws: [Int]) -> [TransientFinding.Kind] {
            kinds(zip(xs, ws).map { s(TransientEntry(role: "AXStaticText", identifier: "x.title", text: "Moore",
                                                     x: $0, y: 0, w: $1, h: 20)) })
        }
        XCTAssertEqual(slide([0, 100, 200], [20, 23, 20]), [],
                       "a 3 pt wobble in height while the element slides 200 pt is clean", file: file, line: line)
        XCTAssertEqual(slide([0, 100, 200], [20, 16, 22]), [],
                       "4 pt outside the range while sliding is clean", file: file, line: line)
        XCTAssertEqual(slideWide([-1, 211, 217], [1115, 1108, 1116]), [],
                       "the Reader row measured 2026-10-21 is clean", file: file, line: line)
        XCTAssertEqual(slide([0, 100, 200], [20, 31, 20]), [.geometry],
                       "an 11 pt wobble is a finding even while sliding 200 pt", file: file, line: line)
        XCTAssertEqual(slide([0, 50, 100], [20, 26, 20]), [.geometry],
                       "a 6 pt wobble is a finding while sliding 100 pt", file: file, line: line)
        XCTAssertEqual(slide([0, 20, 39], [20, 23, 20]), [.geometry],
                       "a 3 pt wobble while moving under 40 pt is a finding", file: file, line: line)
        XCTAssertEqual(slide([0, 0, 0], [20, 21, 20]), [.geometry],
                       "a 1 pt wobble with no slide is a finding", file: file, line: line)
        XCTAssertEqual(slide([0, 100, 97, 200], [20, 20, 20, 20]), [.geometry],
                       "a turn back in the moving coordinate itself is a finding", file: file, line: line)
        XCTAssertEqual(slideWide([0, 100, 97, 200], [100, 160, 220, 260]), [.geometry],
                       "a turn back in a moving coordinate is a finding while another one moves too",
                       file: file, line: line)
        XCTAssertEqual(TransientAnalysis.geometryDeviation([1112, 1113, 1111]), 1, file: file, line: line)
        XCTAssertEqual(TransientAnalysis.geometryDeviation([1112, 1109, 1115]), 3, file: file, line: line)
        XCTAssertEqual(TransientAnalysis.geometryDeviation([0, 10, 7, 20]), 3, file: file, line: line)
        XCTAssertEqual(TransientAnalysis.geometryDeviation([0, 10, 20]), 0, file: file, line: line)
        let link = TransientLink(first: "x.title", second: "y.body")
        func pair(_ title: String, _ body: String) -> TransientAnalysis.LinkState { (title, body) }
        func linkKinds(_ states: [TransientAnalysis.LinkState]) -> [TransientFinding.Kind] {
            TransientAnalysis.linkFindings(link: link, states: states).map(\.kind)
        }
        XCTAssertEqual(linkKinds([pair("Moore", "old body"), pair("Intel", "new body")]), [],
                       "both texts changing in one pass is clean", file: file, line: line)
        XCTAssertEqual(linkKinds([pair("Moore", "old body"), pair("Intel", "old body"), pair("Intel", "new body")]),
                       [.apart], "the header changing a pass before the body", file: file, line: line)
        XCTAssertEqual(linkKinds([pair("Moore", "old body"), pair("Moore", "new body"), pair("Intel", "new body")]),
                       [.apart], "the body changing a pass before the header", file: file, line: line)
        XCTAssertEqual(linkKinds([pair("Moore", "old body"), pair("", "old body"), pair("", "")]), [.apart],
                       "the header leaving a pass before the body empties", file: file, line: line)
        XCTAssertEqual(linkKinds([pair("Moore", "a"), pair("Moore", "b"), pair("Moore", "c")]), [],
                       "a link whose header does not change is left to the section rule", file: file, line: line)
        XCTAssertEqual(TransientLink("an.detail.header+an.editor.text"),
                       TransientLink(first: "an.detail.header", second: "an.editor.text"), file: file, line: line)
        XCTAssertNil(TransientLink("an.detail.header"), file: file, line: line)
        XCTAssertEqual(link.key([e("x.title", "Moore"), e("x.title.date", "1968"), e("x.titled", "no"),
                                 e("y.body", "text")]).first, "Moore | 1968",
                       "an identifier covers its dotted children only", file: file, line: line)
        XCTAssertNotNil(TransientCheck.Report("transitions=3 idle=1 samples=9 walkMaxMs=4 plants=0\n#2 x value: y"),
                        file: file, line: line)
        let r = TransientCheck.Report("transitions=3 idle=1 samples=9 walkMaxMs=4 plants=1\n#2 x value: y")
        XCTAssertEqual(r?.findings.first?.transition, 2, file: file, line: line)
        XCTAssertEqual(r?.findings.first?.line, "x value: y", file: file, line: line)
        XCTAssertEqual(r?.plants, 1, file: file, line: line)
        let c = TransientCheck.Report("transitions=1 idle=1 samples=2 walkMaxMs=1 plants=0\n@1 changed=x sizes=x:2")
        XCTAssertEqual(c?.changes.first?.line, "changed=x sizes=x:2", file: file, line: line)
        XCTAssertEqual(c?.findings.count, 0, "a per-transition line is not a finding", file: file, line: line)
    }
}
