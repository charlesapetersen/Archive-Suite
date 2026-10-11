// LayoutGuard.swift — the suite's layout guard for XCUITest (W40.e9). ONE file, compiled into all three
// UI-test bundles (Reader, Notes, Processor) through each app's `project.yml` (its app-side partner, the DEBUG
// appearance seam, is `../App/UITestAppearance.swift`); not a package, because a UI-test
// bundle needs nothing from it but XCTest, and three copies are how helpers here have drifted before.
//
// WHY IT EXISTS. The Notes note list shipped with every row clipped to about half its height
// (`W40.fix-notes-row-clip`) and no test noticed: the UI tests find an element by identifier and click it, and a
// clipped element is still found and still clickable. This guard looks at GEOMETRY instead. On a screen it reads
// the window's accessibility tree in one snapshot and reports:
//
//   • container — a text element or control that sticks out of its cell or row;
//   • window    — a text element or control, not inside a scroll view, that lies outside the window;
//   • short     — a non-empty single-line text element shorter than any legible line of text (`minTextHeight`).
//                 This is the check that sees the Notes clip: the cell's text field is held inside the cell by
//                 required constraints, so when the row collapses the FIELD collapses with it — its frame stays
//                 inside the cell and only its height betrays that the text is cut;
//   • overlap   — two sibling text elements, or two sibling rows or cells, that overlap.
//
// What it cannot see: anything drawn without an accessibility element (a custom-drawn chip, a CALayer), and a
// view that is wrong but geometrically tidy. Those are the visual reviews' job (`W40.e10`–`e12`), which feed
// every new class of defect this guard COULD catch back into it.
//
// HOW A SUITE USES IT. `LayoutGuard.sweep(...)` runs the checks on a window at its typical size and at its
// minimum size, each straight after the screen opens AND again once the layout has settled — because
// `W40.fix-notes-chips-overdrawn` drew correctly on open and broke about two seconds later. Light and dark are
// separate launches (`LayoutGuard.darkModeArguments`). Each suite's `LayoutGuardUITests.swift` names its
// screens. The pure checker (`LayoutGuard.violations(in:)`) is also exercised on synthetic trees by each suite's
// `testLayoutGuardCatchesPlantedDefects`, so a guard that silently stopped seeing anything fails there first.

import XCTest

/// One element of a window's accessibility tree, copied out of an `XCUIElementSnapshot` so the checker is a pure
/// function over values (and can be fed a synthetic tree in a test).
struct LayoutNode {
    var type: XCUIElement.ElementType
    var identifier: String = ""
    var label: String = ""
    var value: String = ""
    var frame: CGRect
    var children: [LayoutNode] = []

    /// What a person would read, for a violation message.
    var name: String {
        let id = identifier.isEmpty ? "" : "#\(identifier)"
        let text = label.isEmpty ? value : label
        let shown = text.count > 40 ? String(text.prefix(40)) + "…" : text
        return "\(type.layoutGuardName)\(id)\(shown.isEmpty ? "" : " \"\(shown)\"")"
    }

    @MainActor
    init(snapshot: XCUIElementSnapshot) {
        type = snapshot.elementType
        identifier = snapshot.identifier
        label = snapshot.label
        if let v = snapshot.value as? String { value = v }
        frame = snapshot.frame
        children = snapshot.children.map { LayoutNode(snapshot: $0) }
    }

    init(_ type: XCUIElement.ElementType, _ frame: CGRect, id: String = "", label: String = "",
         children: [LayoutNode] = []) {
        self.type = type; self.frame = frame; self.identifier = id; self.label = label; self.children = children
    }
}

struct LayoutViolation: CustomStringConvertible {
    enum Kind: String { case container, window, short, overlap }
    var kind: Kind
    var element: String
    var detail: String
    var description: String { "[\(kind.rawValue)] \(element): \(detail)" }
}

enum LayoutGuard {

    // MARK: - Tunables

    /// Geometry slack, in points. Accessibility frames are rounded and focus rings bleed a point or two.
    static let tolerance: CGFloat = 2

    /// The shortest frame a line of legible text can have. MEASURED, not guessed (VM, 2026-10-11): the smallest
    /// legitimate labels in Notes (10-11 pt fonts: the sidebar counts, "Location") are 13 pt tall, and the
    /// clipped rows of `W40.fix-notes-row-clip` (a 13 pt font whose line needs 16) are 12. So the floor is 13,
    /// with one point of margin on each side. A future 9 pt label would trip it; exempt that one at its call
    /// site rather than lowering the floor, which would blind the guard to the defect it was built for.
    static let minTextHeight: CGFloat = 13

    /// Frames this small in either dimension are deliberate (the 1×1 UITest probes such as
    /// `an.status.indexReady`), or not on screen at all, and are skipped.
    static let degenerate: CGFloat = 2

    /// Launch arguments for the two appearance passes, read by the app's DEBUG `UITestAppearance` seam
    /// (`packages/UITestSupport/App`). Light is passed explicitly too, so a dark guest cannot turn the light pass
    /// dark. (`-AppleInterfaceStyle Dark` was tried first and left the app light.)
    static let darkModeArguments = ["-ArchiveUITestAppearance", "dark"]
    static let lightModeArguments = ["-ArchiveUITestAppearance", "light"]

    static let textTypes: Set<XCUIElement.ElementType> = [.staticText, .textField, .secureTextField, .searchField]
    static let singleLineTextTypes: Set<XCUIElement.ElementType> = [.staticText, .textField, .secureTextField,
                                                                    .searchField]
    static let controlTypes: Set<XCUIElement.ElementType> = [
        .button, .checkBox, .radioButton, .popUpButton, .comboBox, .slider, .segmentedControl, .menuButton,
        .stepper, .disclosureTriangle, .image, .toggle, .link, .textView, .colorWell, .levelIndicator,
    ]
    static let rowTypes: Set<XCUIElement.ElementType> = [.cell, .tableRow, .outlineRow]

    // MARK: - The pure checker

    /// Every violation in `window`'s tree. `ignore` exempts a node (and its subtree) the caller knows is
    /// deliberately off-layout; keep its use rare and say why at the call site.
    static func violations(in window: LayoutNode, ignore: (LayoutNode) -> Bool = { _ in false }) -> [LayoutViolation] {
        var out: [LayoutViolation] = []
        walk(window, window: window.frame, row: nil, clip: window.frame, inScroll: false, ignore: ignore, into: &out)
        return out
    }

    private static func walk(_ node: LayoutNode, window: CGRect, row: LayoutNode?, clip: CGRect, inScroll: Bool,
                             ignore: (LayoutNode) -> Bool, into out: inout [LayoutViolation]) {
        if ignore(node) { return }
        let f = node.frame
        let visible = f.width >= degenerate && f.height >= degenerate && f.intersects(clip)
        let isSheet = node.type == .sheet
        let isScroll = node.type == .scrollView

        if visible {
            let isText = textTypes.contains(node.type)
            if isText || controlTypes.contains(node.type) {
                if let row, !contains(row.frame, f) {
                    out.append(.init(kind: .container, element: node.name,
                                     detail: "frame \(fmt(f)) leaves its \(row.type.layoutGuardName) "
                                        + fmt(row.frame)))
                }
            }
            // Everything inside a scroll view may legitimately scroll past the window's edge, so it is exempt —
            // but the scroll view itself is not: the Reader sidebar's whole scroll view sat 50 pt off the left
            // edge, and its rows, being inside it, were never checked. A sheet is checked as a whole too: it is
            // its own window, so its contents are checked against IT, and a sheet bigger than its parent is
            // reported once rather than once per control.
            if (isText || controlTypes.contains(node.type) || isScroll || isSheet), !inScroll, !contains(window, f) {
                out.append(.init(kind: .window, element: node.name,
                                 detail: "frame \(fmt(f)) leaves the window \(fmt(window))"))
            }
            if singleLineTextTypes.contains(node.type), !(node.label.isEmpty && node.value.isEmpty),
               f.height < minTextHeight {
                out.append(.init(kind: .short, element: node.name,
                                 detail: "\(Int(f.height.rounded())) pt tall — text this short is cut off "
                                    + "(minimum \(Int(minTextHeight)) pt)"))
            }
        }

        // Siblings: two text elements, or two rows/cells, must not overlap. Only on-screen ones.
        let kids = node.children.filter { k in
            !ignore(k) && k.frame.width >= degenerate && k.frame.height >= degenerate && k.frame.intersects(clip)
        }
        for group in [kids.filter { textTypes.contains($0.type) }, kids.filter { rowTypes.contains($0.type) }] {
            guard group.count > 1 else { continue }
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let o = group[i].frame.intersection(group[j].frame)
                    if !o.isNull, o.width > tolerance, o.height > tolerance {
                        out.append(.init(kind: .overlap, element: group[i].name,
                                         detail: "overlaps \(group[j].name) by \(fmt(o))"))
                    }
                }
            }
        }

        if isSheet {
            for child in node.children {
                walk(child, window: f, row: nil, clip: f, inScroll: false, ignore: ignore, into: &out)
            }
            return
        }
        let childRow = rowTypes.contains(node.type) ? node : row
        let childClip = isScroll ? clip.intersection(f) : clip
        for child in node.children {
            walk(child, window: window, row: childRow, clip: childClip, inScroll: inScroll || isScroll,
                 ignore: ignore, into: &out)
        }
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -tolerance, dy: -tolerance).contains(inner)
    }

    static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    // MARK: - Driving a real window

    /// A fingerprint of everything the checker reads, to tell when the layout has stopped moving.
    private static func fingerprint(_ n: LayoutNode) -> String {
        var s = "\(n.type.rawValue)\(fmt(n.frame))\(n.label)|"
        for c in n.children { s += fingerprint(c) }
        return s
    }

    /// The tree as indented text — attached beside a failing state's screenshot, so a violation can be read
    /// against every frame around it.
    static func dump(_ n: LayoutNode, depth: Int = 0) -> String {
        String(repeating: "  ", count: depth) + "\(n.name) \(fmt(n.frame))\n"
            + n.children.map { dump($0, depth: depth + 1) }.joined()
    }

    @MainActor
    static func capture(_ window: XCUIElement) -> LayoutNode? {
        guard let snap = try? window.snapshot() else { return nil }
        return LayoutNode(snapshot: snap)
    }

    /// Wait until the window's tree is unchanged across two reads 0.75 s apart, after at least `minimum`
    /// seconds (thumbnails, previews and re-layouts land in the first seconds after a screen opens). Returns false
    /// if it never settled within `timeout` — reported, not failed: a spinner is not a layout bug.
    @MainActor
    @discardableResult
    static func waitUntilSettled(_ window: XCUIElement, minimum: TimeInterval = 3, timeout: TimeInterval = 15) -> Bool {
        RunLoop.current.run(until: Date().addingTimeInterval(minimum))
        let deadline = Date().addingTimeInterval(timeout)
        var last = capture(window).map(fingerprint)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            let now = capture(window).map(fingerprint)
            if now != nil, now == last { return true }
            last = now
        }
        return false
    }

    /// Drag the window's bottom-right corner so it ends at `corner` (screen coordinates). The resize handle sits
    /// on the frame edge; try just inside it first, then just outside. Returns the frame afterwards.
    @MainActor
    @discardableResult
    static func dragCorner(of window: XCUIElement, to corner: CGPoint) -> CGRect {
        let before = window.frame
        for inset in [CGVector(dx: -1, dy: -1), CGVector(dx: 3, dy: 3)] {
            let handle = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(inset)
            let target = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: corner.x - before.minX + inset.dx, dy: corner.y - before.minY + inset.dy))
            handle.press(forDuration: 0.3, thenDragTo: target)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if window.frame.size != before.size { break }
        }
        return window.frame
    }

    /// A reproduced, filed layout bug the sweep expects to see until its fix lands. Its violations are reported
    /// inside `XCTExpectFailure`, so they do not turn the run red; any OTHER violation still does; and if the known
    /// issue stops reproducing, the sweep fails and says so, so the fix's session must delete the entry.
    struct KnownIssue {
        var tag: String
        var matches: (LayoutViolation) -> Bool
    }

    /// Check one screen: at the window's current (typical) size and at its minimum size, each on open and once
    /// settled, then put the window back. Fails the test with every violation found, and attaches a screenshot
    /// and the tree of each failing state. `screen` names the state in messages ("notes list, dark").
    /// `resize: false` is for a window that cannot be resized, or one carrying a sheet (which blocks the drag): it
    /// checks the current size only, and says so in the log. `ignore` exempts the suite's UI-test-only harness
    /// elements (probes, test buttons), which are not part of the product's layout.
    @MainActor
    static func sweep(_ window: XCUIElement, screen: String, in test: XCTestCase, resize: Bool = true,
                      known: [KnownIssue] = [],
                      file: StaticString = #filePath, line: UInt = #line,
                      ignore: (LayoutNode) -> Bool = { _ in false }) {
        guard window.waitForExistence(timeout: 10) else {
            XCTFail("layout guard: window for \(screen) never appeared", file: file, line: line); return
        }
        let typical = window.frame
        var report: [String] = []
        var knownReport: [String: [String]] = [:]   // tag → the states it was seen in

        func list(_ vs: [LayoutViolation]) -> String {
            vs.prefix(25).map(\.description).joined(separator: "\n    ")
                + (vs.count > 25 ? "\n    … and \(vs.count - 25) more" : "")
        }

        func check(_ state: String) {
            guard let tree = capture(window) else {
                report.append("\(state): could not read the accessibility tree"); return
            }
            let found = violations(in: tree, ignore: ignore)
            let unexpected = found.filter { v in !known.contains { $0.matches(v) } }
            var note = ""
            for k in known {
                let mine = found.filter(k.matches)
                guard !mine.isEmpty else { continue }
                knownReport[k.tag, default: []].append("\(state):\n    " + list(mine))
                note += ", \(mine.count) from \(k.tag)"
            }
            print("[layout-guard] \(screen) — \(state): window \(fmt(tree.frame)), \(unexpected.count) violation(s)"
                  + note)
            guard !found.isEmpty else { return }
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "layout-guard \(screen) — \(state)"
            shot.lifetime = .keepAlways
            test.add(shot)
            let text = XCTAttachment(string: dump(tree))
            text.name = "layout-guard tree \(screen) — \(state)"
            text.lifetime = .keepAlways
            test.add(text)
            if !unexpected.isEmpty { report.append("\(state) (window \(fmt(tree.frame))):\n    " + list(unexpected)) }
        }

        check("typical size, on open")
        if !waitUntilSettled(window) { print("[layout-guard] \(screen): typical size never settled in 15 s") }
        check("typical size, settled")

        let shrinkTo = CGPoint(x: typical.minX + 40, y: typical.minY + 40)
        let minimum = resize ? dragCorner(of: window, to: shrinkTo) : typical
        if !resize {
            print("[layout-guard] \(screen): fixed size, minimum size not applicable")
        } else if minimum.size == typical.size {
            // Either the window already opened at its minimum, or the drag did nothing. Growing it tells the two
            // apart: a window that grows and shrinks back to the same size was already at its minimum, which the
            // checks above have covered.
            let grown = dragCorner(of: window, to: CGPoint(x: typical.maxX + 80, y: typical.maxY + 60))
            if grown.size == typical.size {
                report.append("minimum size: the window would neither shrink nor grow, so the minimum size was NOT "
                              + "checked (pass resize: false if this window is fixed-size)")
            } else {
                dragCorner(of: window, to: shrinkTo)
                _ = waitUntilSettled(window, minimum: 1)
                print("[layout-guard] \(screen): opened at its minimum size \(fmt(typical)); checked above")
            }
        } else {
            check("minimum size, on open")
            if !waitUntilSettled(window) { print("[layout-guard] \(screen): minimum size never settled in 15 s") }
            check("minimum size, settled")
            dragCorner(of: window, to: CGPoint(x: typical.maxX, y: typical.maxY))
            _ = waitUntilSettled(window, minimum: 1)
        }

        if !report.isEmpty {
            XCTFail("layout guard: \(screen)\n  " + report.joined(separator: "\n  "), file: file, line: line)
        }
        for k in known {
            if let seen = knownReport[k.tag] {
                XCTExpectFailure("\(k.tag) — filed, not yet fixed") {
                    XCTFail("layout guard: \(screen), \(k.tag)\n  " + seen.joined(separator: "\n  "),
                            file: file, line: line)
                }
            } else {
                XCTFail("layout guard: \(screen) — \(k.tag) no longer reproduces. If it has been fixed, delete "
                        + "its KnownIssue from this sweep.", file: file, line: line)
            }
        }
    }
}

extension XCUIElement.ElementType {
    /// A short readable name for a violation message; the raw enum prints as a number.
    var layoutGuardName: String {
        switch self {
        case .window: "window"
        case .sheet: "sheet"
        case .staticText: "text"
        case .textField: "textField"
        case .textView: "textView"
        case .searchField: "searchField"
        case .secureTextField: "secureField"
        case .button: "button"
        case .checkBox: "checkBox"
        case .radioButton: "radio"
        case .popUpButton: "popUp"
        case .menuButton: "menuButton"
        case .comboBox: "comboBox"
        case .segmentedControl: "segmented"
        case .slider: "slider"
        case .image: "image"
        case .cell: "cell"
        case .tableRow: "row"
        case .outlineRow: "outlineRow"
        case .table: "table"
        case .outline: "outline"
        case .scrollView: "scrollView"
        case .group: "group"
        case .toolbar: "toolbar"
        default: "type\(rawValue)"
        }
    }
}

/// The synthetic-tree self-test every suite runs (`testLayoutGuardCatchesPlantedDefects`): a tidy window must
/// pass, and each planted defect must be reported as its own kind. A guard that stops seeing a defect class fails
/// here, before anyone trusts its silence on a real screen.
enum LayoutGuardSelfTest {
    static func run(file: StaticString = #filePath, line: UInt = #line) {
        let win = CGRect(x: 0, y: 0, width: 800, height: 600)
        func row(_ y: CGFloat, height: CGFloat = 24, text: CGRect? = nil) -> LayoutNode {
            let r = CGRect(x: 10, y: y, width: 500, height: height)
            let t = text ?? r.insetBy(dx: 4, dy: 4)
            return LayoutNode(.tableRow, r, children: [
                LayoutNode(.cell, r, children: [LayoutNode(.staticText, t, id: "title", label: "A note title")]),
            ])
        }
        func tree(_ rows: [LayoutNode], extra: [LayoutNode] = []) -> LayoutNode {
            LayoutNode(.window, win, children: [
                LayoutNode(.scrollView, CGRect(x: 0, y: 40, width: 800, height: 500), children: [
                    LayoutNode(.table, CGRect(x: 0, y: 40, width: 800, height: 2000), children: rows),
                ]),
            ] + extra)
        }

        let tidy = tree([row(40), row(66), row(92),
                         // A row scrolled out of view is not reported for being outside the window.
                         row(1500)],
                        extra: [LayoutNode(.button, CGRect(x: 700, y: 560, width: 80, height: 24), label: "OK"),
                                LayoutNode(.staticText, CGRect(x: 5, y: 5, width: 1, height: 1), id: "probe",
                                           label: "ready")])
        let clean = LayoutGuard.violations(in: tidy)
        XCTAssertTrue(clean.isEmpty, "a tidy window must pass the layout guard, got: \(clean)", file: file, line: line)

        func expect(_ kind: LayoutViolation.Kind, _ t: LayoutNode, _ what: String) {
            let found = LayoutGuard.violations(in: t)
            XCTAssertTrue(found.contains { $0.kind == kind },
                          "the layout guard must report \(what) as [\(kind.rawValue)], got: \(found)",
                          file: file, line: line)
        }
        // The Notes clip (W40.fix-notes-row-clip): the row collapses and the text field collapses with it.
        expect(.short, tree([row(40, height: 12, text: CGRect(x: 14, y: 42, width: 400, height: 8))]),
               "a text field squashed to 8 pt")
        expect(.container, tree([row(40, text: CGRect(x: 14, y: 36, width: 400, height: 32))]),
               "text taller than its row")
        expect(.window, tree([row(40)], extra: [LayoutNode(.button, CGRect(x: 760, y: 560, width: 80, height: 24),
                                                           label: "Off the edge")]),
               "a button past the window edge")
        expect(.overlap, tree([row(40), row(52)]), "two rows overlapping")
        // The Reader sidebar at its minimum width: the whole scroll view starts off the window's left edge.
        expect(.window, LayoutNode(.window, win, children: [
            LayoutNode(.scrollView, CGRect(x: -50, y: 40, width: 210, height: 500), children: [row(40)]),
        ]), "a scroll view hanging off the window")

        // A sheet bigger than its window is ONE violation (the sheet), not one per control inside it.
        let sheet = LayoutNode(.window, win, children: [
            LayoutNode(.sheet, CGRect(x: -20, y: 40, width: 840, height: 500), children: [
                LayoutNode(.button, CGRect(x: 740, y: 60, width: 60, height: 24), label: "Done"),
                LayoutNode(.staticText, CGRect(x: -10, y: 60, width: 200, height: 16), label: "file.pdf"),
            ]),
        ])
        let sheetFound = LayoutGuard.violations(in: sheet)
        XCTAssertEqual(sheetFound.map(\.element), ["sheet"],
                       "an oversized sheet is reported once, as the sheet, got: \(sheetFound)", file: file, line: line)
        expect(.overlap, tree([], extra: [
            LayoutNode(.staticText, CGRect(x: 10, y: 560, width: 200, height: 16), label: "a"),
            LayoutNode(.staticText, CGRect(x: 100, y: 562, width: 200, height: 16), label: "b"),
        ]),
               "two labels drawn over each other")
    }
}
