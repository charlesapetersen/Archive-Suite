// vm-finder-open-ax.swift — run INSIDE the GUI VM by vm-finder-open-check.sh (W49.notes-finder-open-check).
//
// Reads, and presses buttons in, the accessibility tree of the Notes instance LaunchServices started for a
// library opened from Finder. XCUITest cannot query that instance (W49.notes-store-format), so this asks the
// Accessibility API directly, by pid. Everything `tart exec` starts borrows the guest agent's Accessibility
// grant (ops/gui/vm-check-accessibility.swift), so no other permission is needed.
//
// USAGE:  swift vm-finder-open-ax.swift press [--no-save-panel] BUNDLE_ID TIMEOUT TITLE [TITLE…]
//           Wait for exactly one instance with a dialog holding one of the TITLE buttons, and press it. When a
//           dialog shows more than one, the first TITLE listed wins. Prints the dialogs it saw. Exit 0 pressed,
//           1 nothing to press before TIMEOUT, 2 the Accessibility API refused, 3 (with --no-save-panel) the
//           first-launch Save panel (its "Make Library" button) appeared as well.
//         swift vm-finder-open-ax.swift dialogs BUNDLE_ID
//           Print the newest instance's windows; exit 0 when none is a dialog, 1 when one is, 2 as above.
import AppKit
import ApplicationServices

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// Every button under `element`, with its title, at most `depth` levels down.
func buttons(in element: AXUIElement, depth: Int = 20) -> [(String, AXUIElement)] {
    var found: [(String, AXUIElement)] = []
    if (attr(element, kAXRoleAttribute) as? String) == kAXButtonRole as String,
       let title = attr(element, kAXTitleAttribute) as? String, !title.isEmpty {
        found.append((title, element))
    }
    guard depth > 0 else { return found }
    for child in children(element) { found += buttons(in: child, depth: depth - 1) }
    return found
}

/// The texts under `element` (an alert's message), for the log.
func texts(in element: AXUIElement, depth: Int = 6) -> [String] {
    var found: [String] = []
    if (attr(element, kAXRoleAttribute) as? String) == kAXStaticTextRole as String,
       let value = attr(element, kAXValueAttribute) as? String, !value.isEmpty {
        found.append(value)
    }
    guard depth > 0 else { return found }
    for child in children(element) { found += texts(in: child, depth: depth - 1) }
    return found
}

struct Window {
    let element: AXUIElement
    let title: String
    let subrole: String
    /// A modal alert window, or a sheet on a window.
    let dialogs: [AXUIElement]
}

func windows(of pid: pid_t) -> [Window]? {
    let app = AXUIElementCreateApplication(pid)
    var value: AnyObject?
    let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    if error == .apiDisabled || error == .notImplemented { return nil }
    return ((value as? [AXUIElement]) ?? []).map { window in
        let subrole = (attr(window, kAXSubroleAttribute) as? String) ?? ""
        let sheets = children(window).filter { (attr($0, kAXRoleAttribute) as? String) == "AXSheet" }
        return Window(element: window, title: (attr(window, kAXTitleAttribute) as? String) ?? "",
                      subrole: subrole, dialogs: (subrole == "AXDialog" ? [window] : []) + sheets)
    }
}

func describe(_ dialog: AXUIElement) -> String {
    "texts=\(texts(in: dialog)) buttons=\(buttons(in: dialog).map(\.0))"
}

func instances(_ bundleID: String) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { !$0.isTerminated }
        .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
}

/// The open and save panels of a sandboxed app are drawn by a service process, not the app, so a Save panel
/// is looked for among every process's windows as well.
func savePanelWindowOwners() -> [String] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { $0[kCGWindowOwnerName as String] as? String }
        .filter { $0.localizedCaseInsensitiveContains("Open and Save Panel") }
}

var args = CommandLine.arguments
let forbidSavePanel = args.count > 2 && args[2] == "--no-save-panel"
if forbidSavePanel { args.remove(at: 2) }
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: press [--no-save-panel] BUNDLE_ID TIMEOUT TITLE… | dialogs BUNDLE_ID\n".data(using: .utf8)!)
    exit(64)
}
let bundleID = args[2]

switch args[1] {
case "press":
    guard args.count >= 5, let timeout = Double(args[3]) else { exit(64) }
    let titles = Array(args[4...])
    let deadline = Date().addingTimeInterval(timeout)
    var lastSeen = ""
    while Date() < deadline {
        let running = instances(bundleID)
        if running.count == 1, let found = windows(of: running[0].processIdentifier) {
            let dialogs = found.flatMap(\.dialogs)
            let seen = dialogs.map(describe).joined(separator: " | ")
            if seen != lastSeen { print("pid \(running[0].processIdentifier) dialogs: \(seen.isEmpty ? "none" : seen)"); lastSeen = seen }
            // Every window's buttons, not only the dialogs': a Save panel need not report itself as one.
            let all = found.flatMap { buttons(in: $0.element) }
            if forbidSavePanel, all.contains(where: { $0.0 == "Make Library" }) || !savePanelWindowOwners().isEmpty {
                print("FAIL: the first-launch Save panel is showing beside the question")
                exit(3)
            }
            for title in titles {
                if let button = all.first(where: { $0.0 == title })?.1 {
                    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                    print("pressed \u{201C}\(title)\u{201D} (AX result \(result.rawValue))")
                    exit(result == .success ? 0 : 2)
                }
            }
        } else if let only = instances(bundleID).first, windows(of: only.processIdentifier) == nil {
            print("FAIL: the Accessibility API refused (re-seed with ops/gui/vm-seed-accessibility.sh)")
            exit(2)
        }
        usleep(500_000)
    }
    print("FAIL: no dialog with \(titles) within \(Int(timeout)) s (\(instances(bundleID).count) instance(s) running)")
    exit(1)

case "dialogs":
    guard let newest = instances(bundleID).last else { print("no instance running"); exit(1) }
    guard let found = windows(of: newest.processIdentifier) else {
        print("FAIL: the Accessibility API refused")
        exit(2)
    }
    for window in found {
        print("pid \(newest.processIdentifier) window \u{201C}\(window.title)\u{201D} \(window.subrole)"
              + window.dialogs.map { " dialog: " + describe($0) }.joined())
    }
    exit(found.contains { !$0.dialogs.isEmpty } ? 1 : 0)

default:
    exit(64)
}
