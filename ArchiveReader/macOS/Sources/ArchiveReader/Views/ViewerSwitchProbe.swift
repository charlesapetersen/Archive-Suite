#if DEBUG
import Foundation
import Darwin
import SwiftUI

/// DEBUG only, and off unless launched with `-ARSwitchProbe YES` (W40.fix-reader-viewer-switch): what the
/// main actor spends on each document-window file switch, and the app's footprint over a run. Read by
/// `ViewerSwitchUITests` in the VM, where real PDFViews draw; the unit host draws nothing, so this is the
/// only place a switch's real cost (PDFKit's own layout and tiles included) can be seen.
///
/// Main-busy is measured by a run-loop observer: the time between waking and going back to sleep, summed
/// over the `window` after a switch starts. It counts everything the main thread does then, including the
/// accessibility queries the UI test makes while it waits for the app to idle, so it overstates; a run with
/// `-ARViewerNoPrefetch YES` (no neighbours, no bitmaps: the code before this item) carries the same noise.
@MainActor
final class ViewerSwitchProbe: ObservableObject {
    static let shared: ViewerSwitchProbe? = UserDefaults.standard.bool(forKey: "ARSwitchProbe") ? ViewerSwitchProbe() : nil
    /// The comparison run: the viewer opens nothing ahead and draws no bitmaps.
    static let prefetchDisabled = UserDefaults.standard.bool(forKey: "ARViewerNoPrefetch")

    /// How long after a switch starts its main-busy is counted.
    static let window: CFAbsoluteTime = 1.2

    @Published private(set) var summary = "n=0"

    private var observer: CFRunLoopObserver?
    private var awakeSince: CFAbsoluteTime?
    private var open: (start: CFAbsoluteTime, busy: Double, longest: Double, hit: Bool)?
    private var busy: [Double] = []
    private var longest: [Double] = []
    private var hits = 0
    private var footprints: [String] = []

    private init() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue
                                                          | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observe(activity) }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        awakeSince = CFAbsoluteTimeGetCurrent()
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting { awakeSince = now; return }
        guard let since = awakeSince else { return }
        awakeSince = nil
        guard var o = open else { return }
        let from = max(since, o.start), to = min(now, o.start + Self.window)
        if to > from {
            o.busy += to - from
            o.longest = max(o.longest, to - from)
            open = o
        }
    }

    /// A file switch begins (`DocumentViewerModel.loadCurrent`): `bitmapReady` says whether the image
    /// page's prerendered bitmap was already in hand.
    func switchStarted(bitmapReady: Bool) {
        close()
        open = (CFAbsoluteTimeGetCurrent(), 0, 0, bitmapReady)
        let n = busy.count + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window + 0.05) { [weak self] in
            MainActor.assumeIsolated { if self?.busy.count == n - 1 { self?.close() } }
        }
    }

    private func close() {
        guard var o = open else { return }
        open = nil
        // The interval still running when the switch began counts from the switch.
        if let since = awakeSince {
            let from = max(since, o.start), to = min(CFAbsoluteTimeGetCurrent(), o.start + Self.window)
            if to > from { o.busy += to - from; o.longest = max(o.longest, to - from) }
        }
        busy.append(o.busy * 1000)
        longest.append(o.longest * 1000)
        if o.hit { hits += 1 }
        if busy.count == 1 || busy.count % 20 == 0 { footprints.append("\(busy.count):\(Self.footprintMiB())") }
        publish()
    }

    /// Note the footprint now, once the run is over and has been quiet.
    func noteFootprint(_ label: String) {
        close()
        footprints.append("\(label):\(Self.footprintMiB())")
        publish()
    }

    private func publish() {
        func pct(_ v: [Double], _ p: Double) -> String {
            guard !v.isEmpty else { return "-" }
            let s = v.sorted()
            return String(format: "%.1f", s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))])
        }
        summary = "n=\(busy.count) busy_p50=\(pct(busy, 0.5)) busy_p90=\(pct(busy, 0.9)) busy_max=\(pct(busy, 1)) "
            + "longest_p50=\(pct(longest, 0.5)) longest_max=\(pct(longest, 1)) bitmap_hits=\(hits) "
            + "prefetch=\(Self.prefetchDisabled ? "off" : "on") footprint=\(footprints.joined(separator: ","))"
    }

    private static func footprintMiB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

/// The probe's summary as an accessibility element the UI test reads; drawn invisibly.
struct ViewerSwitchProbeLabel: View {
    @ObservedObject var probe: ViewerSwitchProbe

    var body: some View {
        Text(probe.summary)
            .font(.system(size: 1))
            .opacity(0.02)
            .frame(width: 2, height: 2)
            .accessibilityLabel(probe.summary)
            .accessibilityIdentifier("ar.debug.switchProbe")
    }
}
#endif
