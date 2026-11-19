import SwiftUI
import ArchiveCore

/// Settings › Pages and output (W47.settings-panels): straightening, rotation, the text page and searchable pages,
/// image and PDF sizes, separate image export, skipping processed files, pre-OCRed input and the hand placer download.
struct SettingsPagesOutputPanel: View {
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.useGateway) private var useGateway: Bool = false
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel: Bool = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent: Bool = false
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision: Bool = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.skipAlreadyProcessed) private var skipAlreadyProcessed: Bool = false
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100
    @AppStorage(DefaultsKeys.standardImageSizeMB) private var standardImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.outputImageFile) private var outputImageFile: Bool = true
    @AppStorage(DefaultsKeys.pdfImageSizeMB) private var pdfImageSizeMB: Double = 2.0
    @AppStorage(DefaultsKeys.exportedImageSizeMB) private var exportedImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.textColumns) private var textColumns: Int = 1
    @AppStorage(DefaultsKeys.writeLogFile) private var writeLogEnabled: Bool = false
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.standard.rawValue
    @AppStorage(DefaultsKeys.reviewRotation) private var reviewRotation: Bool = false

    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .standard }

    /// The steppers below must offer exactly the range the run-time clamps enforce, so both read one
    /// declaration rather than repeating `0.5...20` / `1...12` (W16.cfg6-fu3).
    private typealias SizingBounds = SessionProcessingConfig.Bounds

    /// The standard image size a run would actually use. Identical to `standardImageSizeMB` once the
    /// writers are normalized — it exists so the two places that *quote a size to the operator* can never
    /// go back to advertising a number the pipeline will not honour.
    private var effectiveStandardImageMB: Double {
        SessionProcessingConfig.normalizedImageMB(standardImageSizeMB, fallback: 3.0)
    }

    /// The run's rotation calls go to the remote gateway's model (W46.rotation-default), as `detectRotation` decides.
    private var gatewayRotation: Bool {
        !useAppleVision && LLMRotationDetector.callsGateway(
            mode: rotationMode, gateway: useGateway ? GatewayConfig.fromDefaults() : nil, usesLocalAgent: useLocalAgent)
    }

    var body: some View {
        Form {
            Section {
                SettingsStageCards(rules: ["reading-copy"])
            } header: { Text("Straightening") }
            rotationSection
            Section {
                SettingsStageCards(rules: ["placement", "marks"])
            } header: { Text("The text page and searchable pages") }
            inputSection
        }
        .formStyle(.grouped)
    }

    /// Why the batch toggle cannot apply to this run, or nil when it can (W40.fix-processor-settings-backend-mismatch).
    /// Mirrors the pipeline, which batches only `batchMode && provider.supportsBatch` off the gateway and the Local
    /// Agent, so an enabled toggle never promises a discount the run will not take.
    private var batchUnavailableReason: String? {
        if useAppleVision { return "Not used: Apple Vision reads every page on this Mac, with nothing to batch." }
        if useLocalAgent { return "Not used: the CLI runs on your subscription, so there is no batch discount." }
        if useGateway { return "Not used: the API gateway has no batch endpoint." }
        if preOCRedInput { return "Not used for pre-OCRed input." }
        if !selectedProvider.supportsBatch { return "Not used: \(selectedProvider.rawValue) has no batch API here." }
        return nil
    }

    @ViewBuilder private var inputSection: some View {
        Section("Images, files and the run") {
            Toggle(isOn: $preOCRedInput) {
                HStack {
                    Text("Pre-OCRed PDF input")
                    HelpButton(text: "Process PDFs that already contain OCR text (e.g. from a prior run or another tool). Skips OCR API calls and uses the embedded text for tagging and collection ID.\n\nLeave this OFF to re-OCR: a dropped multi-page PDF is automatically split into its pages, each page is re-OCR'd, and one PDF is rebuilt alternating image / OCR-text (a pure document transform — tagging and collection options don't apply). This toggle is only for the tagging pipeline on already-OCR'd input.")
                }
            }
            Toggle(isOn: $batchMode) {
                HStack {
                    Text("Batch mode (slower, ~50% cheaper)")
                    HelpButton(text: "Batch jobs are queued and returned asynchronously — results can take minutes to hours — in exchange for ~50% lower cost. Not available with Apple Vision, the Local CLI Agent, an API Gateway, pre-OCRed input, or a provider without a batch API.\n\nGemini caveat: Gemini batch jobs occasionally get stuck in a pending state due to known Google API reliability issues. If a batch doesn't complete within a few hours, cancel and retry, or switch to non-batch mode.")
                }
            }
            .disabled(batchUnavailableReason != nil)
            .accessibilityIdentifier("ap.settings.batchMode")
            if let reason = batchUnavailableReason {
                Text(reason)
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.batchModeUnavailable")
            }
            Toggle(isOn: $skipAlreadyProcessed) {
                HStack {
                    Text("Skip already-processed files")
                    HelpButton(text: "On a re-run, skip any input whose output PDF already exists in the output folder and is no older than the source — so re-running a directory only processes new or changed files (helpful at large scale). Fails safe: whenever anything is ambiguous (a base name shared by two inputs, an unreadable modification date, or a source changed since its output) it processes the file rather than risk a silent miss. Applies to plain per-file output only — it is ignored for collection-organized or merged runs, where an output can't be reliably matched back to one source.")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Image resolution")
                    HelpButton(text: "A size target, not a fixed dimension %. At \(Int(imageScale))% it targets \(String(format: "%.2g", imageScale / 100 * effectiveStandardImageMB)) MB per image — larger files are downscaled more, while files already at/under target are left full-resolution. Not used for pre-OCRed input (no images are sent).")
                    Spacer()
                    Text("\(Int(imageScale))% of standard").foregroundStyle(.primary)
                }
                Slider(value: $imageScale, in: 5...100, step: 5)
            }
            .disabled(preOCRedInput)
            HStack {
                Text("Standard image size")
                HelpButton(text: "The reference size the resolution slider targets (default 3 MB). Set it to your collection's typical image size.")
                Spacer()
                TextField("", value: $standardImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.primary)
                Stepper("", value: $standardImageSizeMB, in: SizingBounds.imageMB, step: 0.5).labelsHidden()
            }
            .disabled(preOCRedInput)
            Toggle(isOn: $outputImageFile) {
                HStack {
                    Text("Also export a separate image file (two files)")
                    HelpButton(text: "On: each document is saved as BOTH a PDF (image page + OCR text page) and a separate image file. Off: only the PDF is saved (one file). The two images are sized independently below and separately from the image sent to the LLM.")
                }
            }
            .disabled(preOCRedInput)
            HStack {
                Text("PDF image size")
                HelpButton(text: "Target size for the image embedded in each output PDF (default 2 MB). Independent of both the image sent to the LLM and the source resolution — larger images are downscaled toward this target, while smaller ones are embedded as-is. Not used for pre-OCRed input.")
                Spacer()
                TextField("", value: $pdfImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.primary)
                Stepper("", value: $pdfImageSizeMB, in: SizingBounds.imageMB, step: 0.5).labelsHidden()
            }
            .disabled(preOCRedInput)
            HStack {
                Text("Text columns")
                HelpButton(text: "Number of columns for the OCR text page (page 2) of each output PDF. Use 2 or 3 for multi-column sources like newspapers. Default: 1 (single-column).")
                Spacer()
                Picker("", selection: $textColumns) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .disabled(preOCRedInput)
            HStack {
                Text("Exported image size")
                HelpButton(text: "Target size for the separately-exported image file (default 3 MB). Independent of the camera/source resolution — larger images are downscaled toward this target, while already-small JPEGs are kept byte-for-byte. Only applies when \"Also export a separate image file\" is on.")
                Spacer()
                TextField("", value: $exportedImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.primary)
                Stepper("", value: $exportedImageSizeMB, in: SizingBounds.imageMB, step: 0.5).labelsHidden()
            }
            .disabled(!outputImageFile || preOCRedInput)
            // W40.fix-processor-settings-backend-mismatch — Apple Vision sizes its workers from the Mac's
            // performance cores and the Local Agent never runs more than two CLI calls at once
            // (`LocalAgentClient.concurrencyLimiter`), so neither reads this stepper; show what the run will use.
            if useAppleVision {
                LabeledContent("Parallel OCR workers", value: "\(VisionClient.recommendedConcurrency), one per performance core")
                    .accessibilityIdentifier("ap.settings.ocrWorkersFixed")
            } else if useLocalAgent {
                LabeledContent("Parallel OCR workers", value: "At most 2, set by the CLI cap")
                    .accessibilityIdentifier("ap.settings.ocrWorkersFixed")
            } else {
                HStack {
                    Text("Parallel OCR workers: \(ocrWorkerCount)")
                    HelpButton(text: "More workers process OCR faster (roughly halving time going 4 → 8), but raise the chance of provider rate-limit errors (429/503); those are auto-retried with backoff. 4 is safe; 6–8 is usually fine.")
                    Spacer()
                    Stepper("", value: $ocrWorkerCount, in: SizingBounds.ocrWorkers).labelsHidden()
                }
            }
            Toggle(isOn: $writeLogEnabled) {
                HStack {
                    Text("Write a processing log file")
                    HelpButton(text: "On: after a run, write a plain-text log to the output folder summarizing the run and listing any files that failed to produce OCR text (with the error reason). Off (default): no log file is written.")
                }
            }
        }
        // W16.cfg6-fu3 — the writer side. Each MB row pairs a bounded `Stepper` with a `TextField` that
        // accepts any number, so typing 500 used to persist and keep displaying 500 while every run used
        // 20. `normalizeSizingDefaults` writes back exactly what a run would read, so the field snaps to
        // the effective value instead of the two silently disagreeing. It is idempotent, so the write it
        // triggers settles on the second pass rather than looping. `.onAppear` covers a value that was
        // already stored out of range (an applied profile, an older build, `defaults write`).
        .onAppear { SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: standardImageSizeMB) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: pdfImageSizeMB) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: exportedImageSizeMB) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: ocrWorkerCount) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
    }

    @ViewBuilder private var rotationSection: some View {
        Section {
            Picker(selection: $rotationModeRaw) {
                ForEach(RotationMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                HStack {
                    Text("Detect rotation")
                    HelpButton(text: "\(rotationMode.detail)\n\nTime impact: Off, Local Vision and the two local checks add no LLM time; the recommended mode calls the gateway on about 1 page in 10. Single makes one extra call per page that overlaps OCR — usually free time-wise. Majority makes three calls per page and can exceed OCR time on large batches, becoming the bottleneck (see the Time estimate).")
                }
            }
            .disabled(preOCRedInput)
            if rotationMode.orderings > 0, !preOCRedInput, !LLMRotationDetector.hasRoute(
                provider: useAppleVision ? .appleVision : selectedProvider,
                usesGateway: useGateway && GatewayConfig.fromDefaults() != nil, usesLocalAgent: useLocalAgent,
                gatewayIsLocal: gatewayLocalModel) {
                Text("This OCR backend has no LLM rotation check, so pages are checked with Local Vision instead.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ap.settings.rotationFallback")
            }
            if rotationMode == .agreement, !preOCRedInput, !gatewayRotation {
                // W46.rotation-default: the agreement rule asks a model only through the gateway (the one measured).
                Text("With no remote API gateway, a page the two local checks disagree on is left as it is and counted in the run’s summary.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ap.settings.rotationUnsure")
            }
            Toggle(isOn: $reviewRotation) {
                HStack {
                    Text("Review rotation")
                    HelpButton(text: "Pause for a quick, dedicated pass to check and fix each page's orientation before output — separate from (and before) the tagging/segmentation review, since rotation is a fast, mindless check. Runs in every tagging mode, including fully-manual. For Process Live, this pass runs once at Finish, over all captured pages. The chosen rotation is applied to both the PDF and the exported image. Requires a rotation-detection mode above (turn Detect rotation off to disable).")
                }
            }
            .disabled(rotationMode == .off || preOCRedInput)
        } header: { Text("Rotation Correction") }
    }
}
