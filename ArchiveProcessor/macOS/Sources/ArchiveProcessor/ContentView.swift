import SwiftUI

struct ContentView: View {
    @StateObject private var processor = OCRProcessor()
    @StateObject private var capture = CaptureSession()
    @State private var mode: Mode =
        ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" ? .live : .files
    @AppStorage(DefaultsKeys.hasSeenKeyOnboarding) private var hasSeenKeyOnboarding = false
    @State private var showKeyOnboarding = false

    enum Mode: String, CaseIterable { case files = "Process Files", live = "Live Capture", tools = "Tools" }

    var body: some View {
        Group {
            if ProcessInfo.processInfo.environment["PROCESSFILES_TESTMODE"] == "1" {
                // Headless Process Files test: ProcessFilesTestDriver drives `processor` directly,
                // so render a STATIC placeholder (never OCRView / its review sheets / tag card). The
                // pipeline's rapid @Published churn re-rendering that heavy review UI crashes the
                // SwiftUI view graph under programmatic driving; the pipeline logic + output are
                // unaffected by what's on screen, so suppressing the UI lets the test exercise the
                // real OCR → segmentation → tagging → PDF path without the render crash.
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Headless Process Files test in progress…")
                    Text("This window intentionally shows no UI.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 480, minHeight: 220)
            } else {
                mainContent
            }
        }
        .onAppear {
            LiveCaptureTestDriver.runIfRequested(session: capture)
            FileRelayTestDriver.runIfRequested(session: capture)
            ProcessFilesTestDriver.runIfRequested()
            LiveCaptureRecoveryTestDriver.runIfRequested()   // $0 data-safety self-test (env-gated)
            BatchResumeTestDriver.runIfRequested()           // $0 Process-Files crash-resume self-test (env-gated)
            CollectionOrganizeTestDriver.runIfRequested()    // $0 merged-doc image-filing self-test (env-gated)
            MergeSafetyTestDriver.runIfRequested()           // $0 merged-doc tag-transfer safety test (env-gated)
            ProcessFilesTagWarningTestDriver.runIfRequested() // $0 untagged/placeholder output warning contract (env-gated)
            ManifestPersistenceTestDriver.runIfRequested()   // $0 completedDocGroups manifest round-trip (env-gated)
            MultiPageReOCRTestDriver.runIfRequested()        // $0 multi-page PDF re-OCR assembly + overwrite guard (env-gated)
            ProcessingHistoryTestDriver.runIfRequested()     // $0 cost/run-log record + bounded-persist self-test (env-gated)
            IncrementalSkipTestDriver.runIfRequested()       // $0 incremental-processing skip-decision self-test (env-gated)
            SegmentJSONBuilderTestDriver.runIfRequested()    // $0 segment-JSON sidecar byte-identity self-test (env-gated)
            LocalAgentTestDriver.runIfRequested()            // $0 Local Agent CLI backend + PendingRun resume self-test (env-gated)
            NetworkSessionTestDriver.runIfRequested()        // $0 injected HTTP retry/limiter safety test (env-gated)
            maybePresentKeyOnboarding()
        }
        .sheet(isPresented: $showKeyOnboarding) {
            ProviderKeyWizard { showKeyOnboarding = false; hasSeenKeyOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleProviderRequested)) { _ in
            // ⌘⌥P: cycle the provider app-wide (works from any tab), but stand down while a text field is
            // being edited so the shortcut never fires mid-typing.
            guard !TextEditingGuard.isEditingText else { return }
            ProviderCycler.advance()
        }
    }

    private var mainContent: some View {
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
    }

    /// On first launch with no API key of any kind, present the guided key wizard (dismissible;
    /// always re-openable from Settings). Skipped in the headless test modes.
    private func maybePresentKeyOnboarding() {
        guard !hasSeenKeyOnboarding,
              !KeychainHelper.isHeadlessTestMode else { return }
        let hasAnyKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) != nil
            || KeychainHelper.load(account: LLMProvider.mistral.rawValue) != nil
            || KeychainHelper.load(account: LLMProvider.anthropic.rawValue) != nil
            || KeychainHelper.load(account: LLMProvider.openai.rawValue) != nil
            || KeychainHelper.load(account: "Gateway") != nil
        if !hasAnyKey { showKeyOnboarding = true }
    }
}
