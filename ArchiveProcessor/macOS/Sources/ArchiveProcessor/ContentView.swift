import ArchiveCore
import SwiftUI

struct ContentView: View {
    @StateObject private var processor = OCRProcessor()
    @StateObject private var capture = CaptureSession()
#if DEBUG
    @State private var mode: Mode = (
        ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1"
        || ProcessorUITestConfiguration.showsLiveCaptureFinishingScrim
        || ProcessorUITestConfiguration.showsLiveCaptureEmptyPaneClear
    ) ? .live : .files
#else
    @State private var mode: Mode =
        ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" ? .live : .files
#endif
    @AppStorage(DefaultsKeys.hasSeenKeyOnboarding) private var hasSeenKeyOnboarding = false
    @State private var showKeyOnboarding = false
    @AppStorage(DefaultsKeys.hasSeenGeneralInterview) private var hasSeenGeneralInterview = false
    @State private var showGeneralInterview = false

    enum Mode: String, CaseIterable { case files = "Process Files", live = "Live Capture", tools = "Tools" }

    var body: some View {
        Group {
#if DEBUG
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
                    Text("This window intentionally shows no UI.").font(.caption).foregroundStyle(.primary)
                }
                .frame(minWidth: 480, minHeight: 220)
            } else {
                mainContent
            }
#else
            mainContent
#endif
        }
        .onAppear {
#if DEBUG
            // The UI test needs the exact no-sheet regeneration window, but manufacturing it through a
            // real finalize would write files. This explicit launch switch changes only the observed model
            // flag: no receiver, OCR, Keychain, network, source, or output directory is touched.
            if ProcessorUITestConfiguration.showsLiveCaptureFinishingScrim {
                capture.liveProcessor._uiTestShowFinishingScrim()
            }
            if ProcessorUITestConfiguration.showsLiveCaptureEmptyPaneClear {
                capture.liveProcessor._uiTestShowEmptyPaneClear()
            }
            if ProcessorUITestConfiguration.showsFlaggedReview {
                processor._uiTestShowFlaggedReview()
            }
            if ProcessorUITestConfiguration.showsManualSegTag {
                processor._uiTestShowManualSegTag()
            }
#endif
#if DEBUG
            // W40.a5: the env-gated drivers are Debug-only; a Release build carries none of them.
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
            DualDateTestDriver.runIfRequested()              // $0 W37 enclosure relation + Sent With date self-test (env-gated)
            LocalAgentTestDriver.runIfRequested()            // $0 Local Agent CLI backend + PendingRun resume self-test (env-gated)
            NetworkSessionTestDriver.runIfRequested()        // $0 injected HTTP retry/limiter safety test (env-gated)
            USBMuxBridgeTestDriver.runIfRequested()          // $0 W40 iPhone cable route against a fake usbmuxd (env-gated)
            VisionHybridTestDriver.runIfRequested()          // $0 Vision OCR + text-only judgement request-shape contract
            RetryBackendTestDriver.runIfRequested()          // $0 Process Files retry backend-lock contract
            OCRRefusalFallbackTestDriver.runIfRequested()    // $0 W41 second reader for pages Gemini refuses
            OCRCascadeTestDriver.runIfRequested()            // $0 W41 cheap-first OCR cascade, no wire
            InstitutionalComputeImportTestDriver.runIfRequested()       // $0 W41 an institutional-computing bulk run's text, no wire
            OpenRouterTestDriver.runIfRequested()             // $0 W41 OpenRouter request pinning, no wire
            ProviderErrorTestDriver.runIfRequested()         // $0 W40 a 402 reads as credit/billing, not a rate limit
            LocalModelsTestDriver.runIfRequested()           // $0 W41 local open-weight model route, no wire
            OCRPageGuidanceTestDriver.runIfRequested()       // $0 W41 picker note: which model reads which pages
            OCRPageKindTestDriver.runIfRequested()           // $0 W41 page kind → its reader, no wire
            RotationRuleTestDriver.runIfRequested()          // $0 W46 rotation agreement rule + gateway route, no wire
            SegmentationEngineTestDriver.runIfRequested()    // $0 W36 window segmenter on recorded answers
            SegmentationChooserTestDriver.runIfRequested()   // $0 W36 approach chooser rows + render guard
            SettingsSolverTestDriver.runIfRequested()        // $0 W46 settings solver on the profile cases
            SettingsSheetTestDriver.runIfRequested()         // $0 W46 settings sheet: its words and its offscreen pages
            EntityFeatureTestDriver.runIfRequested()         // $0 W46 entity feature: prompt, evidence, policy, sidecar
            DateRouteTestDriver.runIfRequested()             // $0 W46 dating route: bench cases, decision, sidecar
            ReOCRRankingTestDriver.runIfRequested()          // $0 W44 Improve OCR ranked readers, no wire
            ImproveOCRRequestStoreTestDriver.runIfRequested() // $0 W44 Improve OCR hand-off store, scratch only
            ReOCRPreservationCheckTestDriver.runIfRequested() // $0 W44 Improve OCR byte-preservation check, in memory
            ReOCRIncrementalWriterTestDriver.runIfRequested() // $0 W44 Improve OCR writer on the pinned PDFium, scratch only
            ReOCRFileWriterTestDriver.runIfRequested()       // $0 W44 Improve OCR publication + crash recovery, scratch only
            ReOCRPairsTestDriver.runIfRequested()            // $0 W44 Improve OCR pair validation + replacement pages, scratch only
            ReOCRJobTestDriver.runIfRequested()              // $0 W44 Improve OCR one file's run with a fake reader, scratch only
            SettingsLayersTestDriver.runIfRequested()        // $0 W46 settings layers + the collection's document, scratch only
            SettingsInterviewsTestDriver.runIfRequested()    // $0 W46 the general and the collection interviews, scratch only
            SegmentationReviewTestDriver.runIfRequested()    // $0 W36 flagged-boundary review + window stage
            FlaggedCheckTimingTestDriver.runIfRequested(processor: processor) // $0 W46 timing the flagged checks (owner session)
            SegmentationPlanTestDriver.runIfRequested()      // $0 W36 Claude plan route: meter, calibration, cancel
            SegmentationChatGPTTestDriver.runIfRequested()   // $0 W36 ChatGPT plan route: Sign in with ChatGPT, fake server
            SegmentationProofDriver.runIfRequested()         // PAID (cents) W36 one real folder through real models
#endif
            maybePresentKeyOnboarding()
        }
#if DEBUG
        .overlay(alignment: .bottomLeading) {
            if let result = processor.uiTestFlaggedResult {
                Text(result).font(.caption).padding(4).accessibilityIdentifier("ap.uitest.flaggedResult")
            }
        }
#endif
        .onOpenURL { url in
            // W44: a hand-off from the Reader only opens the Improve OCR dialog, on the Process Files tab.
            guard url.scheme == ImproveOCRRequest.scheme else { return }
            ImproveOCRHandoff.pending = url
            mode = .files
            DispatchQueue.main.async { NotificationCenter.default.post(name: .improveOCRHandoff, object: nil) }
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
                .accessibilityIdentifier("ap.mode.picker")   // finds the main window in every mode (UI tests)
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
        // On this view rather than beside the key wizard's sheet, so neither is a second sheet on one view.
        .sheet(isPresented: $showGeneralInterview) {
            GeneralInterviewView {
                showGeneralInterview = false
                hasSeenGeneralInterview = true
                hasSeenKeyOnboarding = true   // the interview offers the key wizard itself
            }
        }
    }

    /// At first launch, the general interview (W46.settings-interviews), which shows the keys found and offers the
    /// key wizard. After it, the key wizard alone still opens once for a Mac with no key of any kind (dismissible;
    /// always re-openable from Settings). Only whether a key exists is checked, so no Keychain prompt. Skipped in the
    /// headless test modes.
    private func maybePresentKeyOnboarding() {
        var askedByUITest = false
#if DEBUG
        askedByUITest = ProcessorUITestConfiguration.showsGeneralInterview
#endif
        if askedByUITest || (!hasSeenGeneralInterview && !KeychainHelper.isHeadlessTestMode) {
            showGeneralInterview = true
            return
        }
        guard !KeychainHelper.isHeadlessTestMode else { return }
        guard !hasSeenKeyOnboarding else { return }
        let hasAnyKey = MacInventory.keyAccounts.contains { KeychainHelper.exists(account: $0.account) }
        if !hasAnyKey { showKeyOnboarding = true }
    }
}
