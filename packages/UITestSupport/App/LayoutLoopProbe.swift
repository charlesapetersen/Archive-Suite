// LayoutLoopProbe — catch an AppKit layout loop before AppKit does (W48.notes-stacked-layout).
//
// AppKit throws "more Update Constraints passes than there are views in the window" when one display cycle keeps
// asking for another pass, and `_NSViewLayout` turns that into a crash. The crash report names the window, never
// the view that kept changing. Under the UITest harness the app's AppKit scroll views call `note(_:_:)` from
// `tile()` and `layout()`; the probe keeps the calls of the CURRENT run-loop turn (a run-loop observer clears them
// when the loop goes back to its sources, so an animation's frames never add up) and, when a single turn reaches
// `threshold` calls, appends them (with the window's view tree, at most `maxDumps` times per launch) to
// `uitest-layoutloop.txt` in the harness's output directory. The UITest copies that file out like a screenshot.
// The threshold is low on purpose: AppKit's cap counts the views in the layout engine's own subtree (a hosted
// scroll view's is small), and a normal turn tiles a scroll view a handful of times.
#if DEBUG
import AppKit
import QuartzCore

@MainActor
enum LayoutLoopProbe {
    /// Set by the app when it runs under a UITest harness; nil (the default) disables the probe entirely.
    static var outputDirectory: URL? {
        didSet { if outputDirectory != nil { installObserver() } }
    }
    static let threshold = 12, maxDumps = 6

    private static var burst: [String] = []
    private static var dumps = 0
    private static var observer: CFRunLoopObserver?

    static func note(_ view: NSScrollView, _ event: String) {
        guard outputDirectory != nil, dumps < maxDumps else { return }
        burst.append(describe(view, event))
        if burst.count == threshold { dump(window: view.window) }
    }

    private static func installObserver() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.beforeSources, .afterWaiting, .beforeWaiting]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { burst.removeAll(keepingCapacity: true) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func describe(_ view: NSScrollView, _ event: String) -> String {
        func r(_ rect: CGRect) -> String {
            "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
        }
        var line = String(format: "%.4f ", CACurrentMediaTime()) + "\(event) \(type(of: view)) frame=\(r(view.frame)) clip=\(r(view.contentView.frame))"
        line += " doc=\(view.documentView.map { r($0.frame) } ?? "-")"
        line += " h=\(view.horizontalScroller.map { $0.isHidden ? "hidden" : "shown" } ?? "none")"
        line += " v=\(view.verticalScroller.map { $0.isHidden ? "hidden" : "shown" } ?? "none")"
        if let table = view.documentView as? NSTableView {
            line += " cols=\(table.tableColumns.map { Int($0.width.rounded()) })"
        }
        line += " win=\(view.window.map { r($0.frame) } ?? "-")"
        return line
    }

    private static func dump(window: NSWindow?) {
        dumps += 1
        guard let dir = outputDirectory else { return }
        var text = "\n===== LayoutLoopProbe dump \(dumps): \(burst.count) scroll-view layout calls in one run-loop turn =====\n"
        text += burst.joined(separator: "\n")
        if let window {
            text += "\n\nwindow \(window.title) frame=\(window.frame) min=\(window.minSize) contentMin=\(window.contentMinSize)\n"
            if dumps == 1, let root = window.contentView { text += tree(root, depth: 0) }
        }
        let url = dir.appendingPathComponent("uitest-layoutloop.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func tree(_ view: NSView, depth: Int) -> String {
        guard depth < 30 else { return "" }
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(type(of: view)) \(view.frame.integral)"
        if view.translatesAutoresizingMaskIntoConstraints == false { line += " [constraints]" }
        if view.needsLayout { line += " needsLayout" }
        if view.needsUpdateConstraints { line += " needsUpdateConstraints" }
        if let id = view.identifier?.rawValue, !id.isEmpty { line += " id=\(id)" }
        line += "\n"
        return line + view.subviews.map { tree($0, depth: depth + 1) }.joined()
    }
}
#endif
