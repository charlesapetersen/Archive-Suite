import SwiftUI

struct ContentView: View {
    @StateObject private var processor = OCRProcessor()
    @StateObject private var capture = CaptureSession()
    @State private var mode: Mode =
        ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" ? .live : .files
    @AppStorage("hasSeenKeyOnboarding") private var hasSeenKeyOnboarding = false
    @State private var showKeyOnboarding = false

    enum Mode: String, CaseIterable { case files = "Process Files", live = "Live Capture", tools = "Tools" }

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
            case .tools:
                ToolsView()
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear {
            LiveCaptureTestDriver.runIfRequested(session: capture)
            maybePresentKeyOnboarding()
        }
        .sheet(isPresented: $showKeyOnboarding) {
            ProviderKeyWizard { showKeyOnboarding = false; hasSeenKeyOnboarding = true }
        }
    }

    /// On first launch with no API key of any kind, present the guided key wizard (dismissible;
    /// always re-openable from Settings). Skipped in the headless Live Capture test mode.
    private func maybePresentKeyOnboarding() {
        guard !hasSeenKeyOnboarding,
              ProcessInfo.processInfo.environment["LIVECAPTURE_TESTMODE"] != "1" else { return }
        let hasAnyKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) != nil
            || KeychainHelper.load(account: LLMProvider.mistral.rawValue) != nil
            || KeychainHelper.load(account: LLMProvider.anthropic.rawValue) != nil
            || KeychainHelper.load(account: "Gateway") != nil
        if !hasAnyKey { showKeyOnboarding = true }
    }
}
