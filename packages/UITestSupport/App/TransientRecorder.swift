// TransientRecorder.swift — the APP-side half of the transient-state check (W40.e13). Compiled into each macOS app
// target (Reader, Notes, Processor) through its `project.yml`, DEBUG only, and inert unless a UI test launches the
// app with `-ArchiveTransientSections <prefix>,<prefix>…`.
//
// WHY IT LIVES IN THE APP. The owner saw the Notes inspector flicker for a few milliseconds on every note change.
// An XCUITest query takes tens of milliseconds and only ever sees a settled screen, so the test runner cannot see
// it. The app can: this recorder samples the watched sections after EVERY pass of the main run loop, just after
// Core Animation has committed that pass to the screen, and so sees each state the user could have seen.
//
// WHAT IT SAMPLES. The app's own accessibility tree, walked in-process: every element whose identifier starts
// with a watched prefix, and every element inside one, as (role, identifier, displayed text, frame). That reaches
// SwiftUI and AppKit alike. An item `!<prefix>` excludes matching elements and everything inside them (a UITest
// harness strip that reports internals, not display); an open menu is skipped too (AppKit draws and highlights it,
// not the app). The pseudo-prefix `@sheets` watches every element of every sheet. Consecutive identical samples
// collapse; when no watched section has changed for
// `settleInterval`, the states since the last settle are one transition, judged by `TransientAnalysis`.
//
// HOW THE TEST READS IT. A small borderless panel, "Transient Recorder", holding one text element
// (`ui.transient.report`) whose value is a header line — `transitions=N idle=0|1 samples=S walkMaxMs=M plants=P` —
// followed by one line per transition, `@<transition> changed=<sections> sizes=<section>:<elements>,…`, and one
// line per finding, `#<transition> <section> <kind>: <detail>`. The UI-test runner is sandboxed and
// cannot read a file the app writes, which is why the report goes through the accessibility tree.
//
// LIMITS. A state that is committed and replaced inside one run-loop pass (an explicit `CATransaction.flush`) is not
// sampled, and walking the tree may itself make SwiftUI bring its view graph up to date. Both can only HIDE a
// flicker, never invent one; the screen video (`ops/gui/vm-screen-video.sh`) is the confirmation for that gap.
//
// `-ArchiveTransientPlant blink` plants a real flicker: on every transition after the first settle, the key
// window's content is hidden for one pass and shown again. The UI tests use it once per app to show the recorder
// failing before its passes are trusted.

#if DEBUG
import AppKit

@MainActor
final class TransientRecorder {
    static let argument = "-ArchiveTransientSections"
    static let plantArgument = "-ArchiveTransientPlant"
    static let reportIdentifier = "ui.transient.report"
    /// The section holding every element of every sheet, identified or not, so opening and closing one is a
    /// transition the recorder can see.
    static let sheetsSection = "@sheets"
    static let settleInterval: TimeInterval = 0.75
    private static let nodeBudget = 20_000
    private static let maxStatesPerSection = 400

    private(set) static var shared: TransientRecorder?

    static func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count else { return }
        let items = arguments[i + 1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let prefixes = items.filter { !$0.hasPrefix("!") }
        let excluded = items.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        guard !prefixes.isEmpty, shared == nil else { return }
        var plant = false
        if let p = arguments.firstIndex(of: plantArgument), p + 1 < arguments.count { plant = arguments[p + 1] == "blink" }
        let recorder = TransientRecorder(prefixes: prefixes, excluded: excluded, plantBlink: plant)
        shared = recorder
        recorder.install()
    }

    private let prefixes: [String]
    private let excluded: [String]
    private let plantBlink: Bool
    private var observer: CFRunLoopObserver?
    private var current: [String: TransientSectionState] = [:]
    private var segment: [String: [TransientSectionState]] = [:]
    private var changedSinceSettle = false
    private var changing: Set<String> = []
    private var settleTimer: Timer?
    private var transitions = 0
    private var findings: [String] = []
    private var samples = 0
    private var walkMaxMs = 0.0
    private var plants = 0
    private var plantedThisTransition = false
    private var hiddenByPlant: NSView?
    private var panel: NSPanel?
    private var field: NSTextField?
    private var published = ""
    private var sampling = false

    private init(prefixes: [String], excluded: [String], plantBlink: Bool) {
        self.prefixes = prefixes
        self.excluded = excluded
        self.plantBlink = plantBlink
    }

    private func install() {
        // Order 2_500_000: after AppKit's display cycle and Core Animation's commit (both run at about 2_000_000
        // in `beforeWaiting`), before the autorelease pool's pop, so each sample is the state just committed.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          2_500_000) { _, _ in
            MainActor.assumeIsolated { TransientRecorder.shared?.sample() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        ensurePanel()
        let start = CFAbsoluteTimeGetCurrent()
        let snapshot = takeSnapshot()
        walkMaxMs = max(walkMaxMs, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        samples += 1
        var changed = false
        for prefix in prefixes {
            let state = snapshot[prefix] ?? TransientSectionState()
            guard current[prefix] != state else { continue }
            current[prefix] = state
            var states = segment[prefix] ?? []
            states.append(state)
            if states.count > Self.maxStatesPerSection { states.remove(at: 1) }
            segment[prefix] = states
            changing.insert(prefix)
            changed = true
        }
        guard changed else { return }
        changedSinceSettle = true
        if plantBlink, transitions > 0, !plantedThisTransition { plant() }
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.settleInterval, repeats: false) { _ in
            MainActor.assumeIsolated { TransientRecorder.shared?.settle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
        publish(idle: false)
    }

    private func settle() {
        guard changedSinceSettle else { return }
        changedSinceSettle = false
        plantedThisTransition = false
        transitions += 1
        findings.append("@\(transitions) changed=\(changing.sorted().joined(separator: ",")) sizes="
                        + prefixes.map { "\($0):\(current[$0]?.entries.count ?? 0)" }.joined(separator: ","))
        for prefix in prefixes {
            let states = segment[prefix] ?? []
            for finding in TransientAnalysis.findings(section: prefix, states: states) {
                findings.append("#\(transitions) \(finding)")
            }
            segment[prefix] = current[prefix].map { [$0] } ?? []
        }
        changing = []
        publish(idle: true)
    }

    // MARK: - the walk

    private func takeSnapshot() -> [String: TransientSectionState] {
        var out: [String: TransientSectionState] = [:]
        var budget = Self.nodeBudget
        let windows = NSApp.windows.filter { $0.isVisible && $0 !== panel }.sorted { $0.windowNumber < $1.windowNumber }
        for window in windows {
            let section = window.isSheet && prefixes.contains(Self.sheetsSection) ? Self.sheetsSection : nil
            guard let node = AXNode(window) else { continue }
            walk(node, section: section, origin: window.frame.origin, depth: 0, into: &out, budget: &budget)
        }
        return out
    }

    private func walk(_ element: AXNode, section: String?, origin: CGPoint, depth: Int,
                      into out: inout [String: TransientSectionState], budget: inout Int) {
        guard budget > 0, depth < 80 else { return }
        budget -= 1
        let identifier = element.identifier
        if !identifier.isEmpty, excluded.contains(where: { identifier.hasPrefix($0) }) { return }
        // An open menu is AppKit's menu tracking, not the app's display: while a pop-up button's menu is open its
        // items are the button's children, and their highlight follows the pointer (measured 2026-10-17: picking a
        // Processor segmentation option reported every item the pointer crossed as a transient value).
        let role = element.role
        if role == NSAccessibility.Role.menu.rawValue { return }
        let section = section ?? prefixes.first { !identifier.isEmpty && identifier.hasPrefix($0) }
        if let section {
            let frame = element.frame
            let entry = TransientEntry(role: role, identifier: identifier, text: element.text,
                                       x: Int((frame.minX - origin.x).rounded()), y: Int((frame.minY - origin.y).rounded()),
                                       w: Int(frame.width.rounded()), h: Int(frame.height.rounded()))
            out[section, default: TransientSectionState()].entries.append(entry)
        }
        // A table's or outline's rows are its `accessibilityRows`, which its children need not include (measured:
        // a Notes folder switch changed only the list's rows, and a children-only walk saw no change at all).
        var children = element.children
        for row in element.rows where !children.contains(where: { $0 === row }) {
            children.append(row)
        }
        for child in children {
            guard let child = AXNode(child) else { continue }
            walk(child, section: section, origin: origin, depth: depth + 1, into: &out, budget: &budget)
        }
    }

    /// One element as the walk reads it. The accessibility server reads an element by message, whatever it declares,
    /// and the walk has to as well, because an app's tree mixes three kinds (all measured in the VM, 2026-10-17):
    /// - AppKit views and windows, which declare `NSAccessibilityProtocol`;
    /// - SwiftUI's elements (`SwiftUI.AccessibilityNode`), which answer that protocol's messages without declaring
    ///   it, so `as? NSAccessibilityProtocol` fails on them. A walk that relied on the cast dropped every child of a
    ///   SwiftUI scroll view and stopped at 16 elements; the Processor's panels, all inside one, were never sampled;
    /// - AppKit's older elements, such as `NSTableRow` (a view-based table's rows), which answer only the legacy
    ///   `accessibilityAttributeValue:`. The Reader's file list returned 20 of them, and without them a selection
    ///   change showed nothing.
    /// The first two are read through the protocol (the second by `unsafeBitCast`, sound because an `@objc`
    /// protocol's existential is the bare object reference and every call is an Objective-C message), each optional
    /// message checked before it is sent; the third through its attributes, asking only those it lists.
    private struct AXNode {
        let object: NSObject
        private let modern: NSAccessibilityProtocol?
        private let attributes: Set<String>

        private static let required = ["accessibilityIdentifier", "accessibilityFrame", "accessibilityRole",
                                       "accessibilityChildren"].map(NSSelectorFromString)
        private static let attributeValue = NSSelectorFromString("accessibilityAttributeValue:")
        private static let attributeNames = NSSelectorFromString("accessibilityAttributeNames")

        init?(_ any: Any) {
            guard let object = any as? NSObject else { return nil }
            self.object = object
            if let element = object as? NSAccessibilityProtocol {
                modern = element
                attributes = []
            } else if Self.required.allSatisfy({ object.responds(to: $0) }) {
                modern = unsafeBitCast(object, to: NSAccessibilityProtocol.self)
                attributes = []
            } else if object.responds(to: Self.attributeValue), object.responds(to: Self.attributeNames) {
                modern = nil
                attributes = Set(object.perform(Self.attributeNames)?.takeUnretainedValue() as? [String] ?? [])
            } else {
                return nil
            }
        }

        private func answers(_ selector: String) -> Bool { object.responds(to: NSSelectorFromString(selector)) }

        private func attribute(_ name: NSAccessibility.Attribute) -> Any? {
            guard attributes.contains(name.rawValue) else { return nil }
            return object.perform(Self.attributeValue, with: name.rawValue)?.takeUnretainedValue()
        }

        var identifier: String {
            if let modern { return modern.accessibilityIdentifier() ?? "" }
            return attribute(.identifier) as? String ?? ""
        }

        var role: String {
            if let modern { return modern.accessibilityRole()?.rawValue ?? "" }
            return attribute(.role) as? String ?? ""
        }

        var frame: CGRect {
            if let modern { return modern.accessibilityFrame() }
            let origin = (attribute(.position) as? NSValue)?.pointValue ?? .zero
            let size = (attribute(.size) as? NSValue)?.sizeValue ?? .zero
            return CGRect(origin: origin, size: size)
        }

        var children: [AnyObject] {
            if let modern { return (modern.accessibilityChildren() ?? []).map { $0 as AnyObject } }
            return (attribute(.children) as? [Any] ?? []).map { $0 as AnyObject }
        }

        var rows: [AnyObject] {
            if let modern {
                guard answers("accessibilityRows") else { return [] }
                return (modern.accessibilityRows() ?? []).map { $0 as AnyObject }
            }
            return (attribute(.rows) as? [Any] ?? []).map { $0 as AnyObject }
        }

        /// Title, label and value, plus a selection highlight or a greyed-out control, which are displayed state too:
        /// a row deselected and selected again, or a toolbar button that flashes disabled, is a flicker.
        var text: String {
            let title, label: String?
            let value: Any?
            let selected, enabled: Bool
            if let modern {
                title = answers("accessibilityTitle") ? modern.accessibilityTitle() : nil
                label = answers("accessibilityLabel") ? modern.accessibilityLabel() : nil
                value = answers("accessibilityValue") ? modern.accessibilityValue() : nil
                selected = answers("isAccessibilitySelected") && modern.isAccessibilitySelected()
                enabled = !answers("isAccessibilityEnabled") || modern.isAccessibilityEnabled()
            } else {
                title = attribute(.title) as? String
                label = attribute(.description) as? String
                value = attribute(.value)
                selected = (attribute(.selected) as? NSNumber)?.boolValue ?? false
                enabled = (attribute(.enabled) as? NSNumber)?.boolValue ?? true
            }
            var parts: [String] = []
            if let title, !title.isEmpty { parts.append(title) }
            if let label, !label.isEmpty, !parts.contains(label) { parts.append(label) }
            switch value {
            case let s as String where !s.isEmpty && !parts.contains(s): parts.append(s)
            case let a as NSAttributedString where a.length > 0: parts.append(a.string)
            case let n as NSNumber: parts.append(n.stringValue)
            default: break
            }
            if selected { parts.append("⟨selected⟩") }
            if !enabled { parts.append("⟨disabled⟩") }
            return parts.joined(separator: " | ")
        }
    }

    // MARK: - the planted flicker

    private func plant() {
        guard let content = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView, !content.isHidden else { return }
        plantedThisTransition = true
        plants += 1
        content.isHidden = true
        hiddenByPlant = content
        let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
            MainActor.assumeIsolated {
                TransientRecorder.shared?.hiddenByPlant?.isHidden = false
                TransientRecorder.shared?.hiddenByPlant = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - the report

    private func ensurePanel() {
        guard panel == nil, NSApp.windows.contains(where: { $0.isVisible }) else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 18),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Transient Recorder"
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 9)
        field.frame = NSRect(x: 2, y: 2, width: 416, height: 14)
        field.setAccessibilityIdentifier(Self.reportIdentifier)
        panel.contentView?.addSubview(field)
        if let screen = NSScreen.main { panel.setFrameOrigin(screen.visibleFrame.origin) }
        panel.orderFrontRegardless()
        self.panel = panel
        self.field = field
        publish(idle: false)
    }

    private func publish(idle: Bool) {
        let header = "transitions=\(transitions) idle=\(idle ? 1 : 0) samples=\(samples) "
            + "walkMaxMs=\(Int(walkMaxMs.rounded())) plants=\(plants) changing=\(changing.sorted().joined(separator: ","))"
        let text = ([header] + findings.suffix(200)).joined(separator: "\n")
        guard text != published, let field else { return }
        published = text
        field.stringValue = text
        field.setAccessibilityValue(text)
    }
}
#endif
