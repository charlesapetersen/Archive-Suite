import SwiftUI

struct ContentView: View {
    @StateObject private var processor = OCRProcessor()
    @StateObject private var capture = CaptureSession()
    @State private var mode: Mode =
        ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" ? .live : .files

    enum Mode: String, CaseIterable { case files = "Process Files", live = "Live Capture" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                if mode == .live && capture.serverRunning {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            switch mode {
            case .files:
                OCRView(processor: processor)
            case .live:
                LiveCaptureView(session: capture, processor: processor, liveProc: capture.liveProcessor, onProcess: { mode = .files })
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear { LiveCaptureTestDriver.runIfRequested(session: capture) }
    }
}
