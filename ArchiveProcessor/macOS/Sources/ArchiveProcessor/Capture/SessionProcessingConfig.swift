import Foundation

/// The settings a run reads plus the keys it needs (W49.proc-settings-config-unify). Every setting is in `config`, the
/// one `ResolvedRunConfig` resolved at Start (Process Files) or at session start (Live Capture) and then locked; the
/// keys are in `credentials`, which is never written anywhere. `provider`, `taggingMode` and the rest read and write
/// `config` through the dynamic member lookup, so this type keeps no copy of any setting.
///
/// Beside them, what the run's file list gave it rather than Settings: the page readers and the institutional-computing
/// text it imports.
@dynamicMemberLookup
struct SessionProcessingConfig: Sendable {
    var config: ResolvedRunConfig
    var credentials: RunCredentials
    /// The reader each page's kind chose (W41.app-page-kind), from the file list at Start. Empty = every page is read
    /// by the run's model. Frozen with the run, like the cascade, so a resumed run reads each page as it began.
    var pageReaders: PageReaderPlan = .empty
    /// An institutional-computing bulk run's text for this run's pages (W41.app-institutional-compute), set at Start where the page
    /// readers apply; nil = every page is read by the run. A resumed run reloads it from `institutionalComputeFolder`.
    var institutionalComputeImport: InstitutionalComputeImport? = nil

    init(config: ResolvedRunConfig, credentials: RunCredentials, pageReaders: PageReaderPlan = .empty,
         institutionalComputeImport: InstitutionalComputeImport? = nil) {
        self.config = config
        self.credentials = credentials
        self.pageReaders = pageReaders
        self.institutionalComputeImport = institutionalComputeImport
    }

    /// Build one from its parts, for the test drivers that name each setting.
    init(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel, apiKey: String,
         taggingMode: TaggingMode, rotationMode: RotationMode, mergeDocuments: Bool, outputDirectory: URL,
         customOCRPrompt: String, imageScale: Double, standardImageMB: Double = 3.0, ocrWorkerCount: Int = 4,
         enableSegmentJSON: Bool, tagVocabulary: [String], gateway: GatewayConfig?, outputImageFile: Bool,
         pdfImageMB: Double, exportedImageMB: Double, textColumns: Int, localAgent: LocalAgentConfig? = nil,
         visionSettings: VisionOCRSettings = .default, cascade: OCRCascade = .off, pageReaders: PageReaderPlan = .empty,
         institutionalComputeImport: InstitutionalComputeImport? = nil, visionTextLLM: LLMTextConfiguration? = nil,
         segmentationApproach: SegmentationApproach = .manual, dateLocalImage: Bool = false, macItemFields: Bool = true,
         keepPreservationCopies: Bool = true) {
        self.init(
            config: ResolvedRunConfig(
                provider: provider, model: model, thinkingLevel: thinkingLevel, gateway: gateway,
                localAgent: localAgent, visionSettings: visionSettings, cascade: cascade,
                customOCRPrompt: customOCRPrompt, imageScale: imageScale, standardImageMB: standardImageMB,
                ocrWorkerCount: ocrWorkerCount, taggingMode: taggingMode, segmentationApproach: segmentationApproach,
                mergeDocuments: mergeDocuments, tagVocabulary: tagVocabulary, dateLocalImage: dateLocalImage,
                macItemFields: macItemFields, outputDirectory: outputDirectory, rotationMode: rotationMode,
                enableSegmentJSON: enableSegmentJSON, outputImageFile: outputImageFile, pdfImageMB: pdfImageMB,
                exportedImageMB: exportedImageMB, textColumns: textColumns,
                keepPreservationCopies: keepPreservationCopies),
            credentials: RunCredentials(apiKey: apiKey),
            pageReaders: pageReaders, institutionalComputeImport: institutionalComputeImport)
        self.visionTextLLM = visionTextLLM
    }

    subscript<T>(dynamicMember keyPath: WritableKeyPath<ResolvedRunConfig, T>) -> T {
        get { config[keyPath: keyPath] }
        set { config[keyPath: keyPath] = newValue }
    }

    var apiKey: String {
        get { credentials.apiKey }
        set { credentials.apiKey = newValue }
    }

    /// Optional direct LLM used only after Apple Vision has produced text: the config's `visionText` with its key.
    /// The image OCR provider remains `.appleVision`; this value is deliberately never handed to `performOCRCall`.
    var visionTextLLM: LLMTextConfiguration? {
        get {
            config.visionText.map {
                LLMTextConfiguration(provider: $0.provider, model: $0.model, thinkingLevel: $0.thinkingLevel,
                                     apiKey: credentials.visionTextAPIKey)
            }
        }
        set {
            config.visionText = newValue.map {
                .init(provider: $0.provider, model: $0.model, thinkingLevel: $0.thinkingLevel)
            }
            credentials.visionTextAPIKey = newValue?.apiKey ?? ""
        }
    }

    /// The backend for all post-transcription text work. For ordinary runs this is the OCR backend;
    /// for the Vision hybrid it is the separately-selected direct LLM.
    var textProvider: LLMProvider { config.visionText?.provider ?? config.provider }
    var textModel: LLMModel { config.visionText?.model ?? config.model }
    var textThinkingLevel: ThinkingLevel? { config.visionText?.thinkingLevel ?? config.thinkingLevel }
    var textAPIKey: String { config.visionText == nil ? credentials.apiKey : credentials.visionTextAPIKey }
    var textGateway: GatewayConfig? { config.visionText == nil ? config.gateway : nil }
    var textLocalAgent: LocalAgentConfig? { config.visionText == nil ? config.localAgent : nil }

    /// The one declaration of what each sizing/concurrency setting is allowed to be.
    ///
    /// Before W16.cfg6-fu3 these three ranges were literals repeated across the reader (`normalizedImageMB`,
    /// `ocrWorkerCount(from:)`, `runSizing`), the Settings `Stepper`s, and
    /// `OCRProcessor.pendingRunSnapshotIsValid`. Widening the ceiling meant finding all of them.
    enum Bounds {
        static let imageMB: ClosedRange<Double> = 0.5...20
        static let ocrWorkers: ClosedRange<Int> = 1...12
        static let textColumns: ClosedRange<Int> = 1...4
    }

    /// The built-in target for the image embedded in an output PDF. 1.5 MB, owner's call of 2026-11-24
    /// (W49.proc-pair-compress-hands): on 21 of the owner's hand and mixed pages it saved 8% against 2.0 MB and kept a
    /// median 98% of the long edge, with the image readback inside the noise. The searchable form's compression
    /// starts from the same sized image.
    static let defaultPDFImageMB = 1.5

    /// Preserve the Process Files run-start normalization now used by every fresh and resumed production
    /// path. W16.cfg6 only removes the remaining compatibility statics and optional fallbacks.
    ///
    /// A value that is not a usable size at all (0, negative, NaN, ±∞) takes the `fallback`; a usable one
    /// out of range is pulled to the nearest bound.
    static func normalizedImageMB(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? clampImageMB(value) : fallback
    }

    /// Pull a *usable* size into range. Callers must reject non-finite input first (`normalizedImageMB`
    /// does): `max(0.5, .nan)` is `.nan` on every platform Swift targets, so a NaN would survive this.
    static func clampImageMB(_ value: Double) -> Double {
        min(Bounds.imageMB.upperBound, max(Bounds.imageMB.lowerBound, value))
    }

    static func clampOCRWorkers(_ value: Int) -> Int {
        min(Bounds.ocrWorkers.upperBound, max(Bounds.ocrWorkers.lowerBound, value))
    }

    static func clampTextColumns(_ value: Int) -> Int {
        min(Bounds.textColumns.upperBound, max(Bounds.textColumns.lowerBound, value))
    }

    static func ocrWorkerCount(from defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: DefaultsKeys.ocrWorkerCount)
        return value > 0 ? clampOCRWorkers(value) : 4
    }

    /// The five run-scoped sizing/concurrency values, and nothing else.
    ///
    /// These are exactly the numbers that used to live in `OCRProcessor`'s six mutable
    /// `nonisolated(unsafe)` statics (W16.cfg6 deleted them). They are grouped here so every path that
    /// answers for them cannot drift apart: `fromDefaults()` (which is what **Live Capture** snapshots),
    /// `fromProcessFilesRunStart()`, and the last-resort read below all normalize through
    /// `runSizing(_:)`.
    ///
    /// ⚠️ Scope that exactly: **one clamp per value per DEFAULTS READ** — NOT "the only clamp in the app".
    /// Downstream still re-bounds some of these (`OCRProcessor.schedulingWorkerCount` the worker count,
    /// `PDFGenerator` the column count); those are idempotent belt-and-braces over an *injected* config,
    /// which need not have come from a defaults read. Two paths bypass this type: a resumed Process Files
    /// run, which fail-closed *validates* its persisted runtime config against `Bounds` rather than
    /// clamping it (`OCRProcessor.pendingRunSnapshotIsValid`), and `StagedSegment`'s decoder, which
    /// restores a staged live segment's sizes verbatim (harmless — the build that wrote the segment is the
    /// build that reads it back).
    ///
    /// W16.cfg6-fu3 added the writer half, `normalizeSizingDefaults(_:)`: the number an operator can type
    /// or a profile can apply is held to `Bounds` too, so what Settings shows is now IN RANGE — 500 can no
    /// longer sit in the field while every run uses 20. Not "shows the exact bytes": the MB fields render
    /// to one decimal, so a stored 19.96 still *displays* as 20 (measured). That residue is under 0.05 MB
    /// and deliberately left alone.
    ///
    /// W16.cfg6-fu2 is what made even the narrow claim true. Until then `fromDefaults()` sized `pdfImageMB` and
    /// `exportedImageMB` with its own looser inline closures — no `.isFinite` guard, no 0.5 floor, no 20
    /// ceiling — while `standardImageMB`/`ocrWorkerCount` went through the strict shared helpers. Since
    /// Live Capture builds its session config from `fromDefaults()` (`CaptureSession.swift`) and Process
    /// Files overwrites the five values at run start, an out-of-range default reached Live Capture
    /// unclamped while the same number was clamped for Process Files: a 500 MB `pdfImageSizeMB` sized the
    /// image embedded in every live-captured PDF, and an infinite one is not a size at all.
    struct RunSizing: Sendable, Equatable {
        var standardImageMB: Double
        var ocrWorkerCount: Int
        var pdfImageMB: Double
        var textColumns: Int
        var exportedImageMB: Double
    }

    /// Read the sizing values straight from UserDefaults, with the exact clamps
    /// `OCRProcessor.loadStandardImageMB()` historically applied at run start.
    ///
    /// Deliberately **Keychain-free**: unlike `fromDefaults()` this performs no provider/model/Keychain
    /// lookup, because none of these five values needs one — so it is safe to call from a nonisolated
    /// last-resort path without risking a blocking Keychain prompt.
    ///
    /// It is also a **pure function of UserDefaults**, which is the point of W16.cfg6: the statics it
    /// replaces were process-global `var`s that a test driver could leave mutated when a crash skipped
    /// its `defer` restore, silently giving a later real run the wrong embedded-image size, column
    /// count, or worker count. A value read here can be *current* but never *left over*.
    static func runSizing(_ d: UserDefaults = .standard) -> RunSizing {
        RunSizing(
            standardImageMB: normalizedImageMB(
                d.double(forKey: DefaultsKeys.standardImageSizeMB), fallback: 3.0),
            ocrWorkerCount: ocrWorkerCount(from: d),
            pdfImageMB: normalizedImageMB(
                d.double(forKey: DefaultsKeys.pdfImageSizeMB), fallback: defaultPDFImageMB),
            textColumns: clampTextColumns(d.integer(forKey: DefaultsKeys.textColumns)),
            exportedImageMB: normalizedImageMB(
                d.double(forKey: DefaultsKeys.exportedImageSizeMB), fallback: 3.0)
        )
    }

    /// Rewrite the five sizing/concurrency defaults as the values a run would actually use — the WRITER
    /// half of W16.cfg6-fu3.
    ///
    /// Since W16.cfg6-fu2 every *read* clamps, so nothing out of range can reach a run. What remained was
    /// that an out-of-range number could still be **stored and displayed**: typing 500 into the Settings
    /// MB field beside its 0.5…20 stepper persisted 500 and kept showing 500, while every run used 20 and
    /// the cost pane quoted 500. This closes that divergence at the source rather than adding a fifth
    /// clamp on the way out.
    ///
    /// It writes `runSizing(d)` verbatim, so the normalizer and the reader cannot disagree about a bound
    /// or a fallback — they are literally the same function.
    ///
    /// Two deliberate restraints:
    /// - **An UNSET key stays unset.** Materializing it would only trade one silent difference for
    ///   another (`ProcessingSettingsCapture` distinguishes stored from defaulted), and an unset key already
    ///   resolves to exactly the value this would write.
    /// - **A key already equal to its normalized value is not rewritten**, so calling this on every
    ///   settings change is idempotent and does not churn `@AppStorage` observers.
    ///
    /// - Returns: whether anything was actually rewritten (for tests and callers that want to know).
    @discardableResult
    static func normalizeSizingDefaults(_ d: UserDefaults = .standard) -> Bool {
        let sizing = runSizing(d)
        var changed = false
        func normalizeDouble(_ key: String, to value: Double) {
            // NaN compares unequal to everything, so a stored NaN is always rewritten. Intended.
            guard d.object(forKey: key) != nil, d.double(forKey: key) != value else { return }
            d.set(value, forKey: key)
            changed = true
        }
        func normalizeInt(_ key: String, to value: Int) {
            guard d.object(forKey: key) != nil, d.integer(forKey: key) != value else { return }
            d.set(value, forKey: key)
            changed = true
        }
        normalizeDouble(DefaultsKeys.standardImageSizeMB, to: sizing.standardImageMB)
        normalizeDouble(DefaultsKeys.pdfImageSizeMB, to: sizing.pdfImageMB)
        normalizeDouble(DefaultsKeys.exportedImageSizeMB, to: sizing.exportedImageMB)
        normalizeInt(DefaultsKeys.ocrWorkerCount, to: sizing.ocrWorkerCount)
        normalizeInt(DefaultsKeys.textColumns, to: sizing.textColumns)
        return changed
    }

    /// This config's own sizing values, for comparing an injected snapshot against a defaults read.
    var runSizing: RunSizing { config.runSizing }

    /// The rotation mode `fromDefaults()` would select, read on its own and without the Keychain.
    ///
    /// Companion to `runSizing(_:)` for the sixth value W16.cfg6 removed: the `rotationModeForRun`
    /// static. Same rule — an OCR call with no run snapshot reads the setting as it is *now* rather
    /// than whatever a previous run or a test driver last stored in a global.
    static func defaultRotationMode(_ d: UserDefaults = .standard) -> RotationMode {
        RotationMode(rawValue: d.string(forKey: DefaultsKeys.rotationModeRaw) ?? "") ?? .standard
    }

    /// Read the app's shared settings into a config snapshot: `ResolvedRunConfig.fromDefaults` for every setting, then
    /// the keys that config's routes need.
    ///
    /// The five sizing/concurrency values come from `runSizing(_:)` — the same single normalization the
    /// Process Files run start uses (W16.cfg6-fu2). This matters because **Live Capture snapshots its
    /// whole session config here**, so this is the only clamp an out-of-range default meets on that path.
    static func fromDefaults(_ d: UserDefaults = .standard,
                             allowCredentialInteraction: Bool = true,
                             primaryAPIKey: String? = nil,
                             visionTextAPIKey: String? = nil,
                             keepPreservationCopies: Bool = true) -> SessionProcessingConfig {
        let config = ResolvedRunConfig.fromDefaults(d, keepPreservationCopies: keepPreservationCopies)
        return SessionProcessingConfig(
            config: config,
            credentials: credentials(for: config, d, allowInteraction: allowCredentialInteraction,
                                     primaryAPIKey: primaryAPIKey, visionTextAPIKey: visionTextAPIKey))
    }

    /// The keys `config` needs. API key: the Keychain in production. Headless test fallback (env-gated): a headless
    /// CI/E2E host has no GUI Keychain, so when running under ARCHIVEPROC_HEADLESS and the Keychain has no key, fall
    /// back to the LIVECAPTURE_OCRKEY env var — this lets the LIVE phone-driven pipeline OCR headlessly. The key stays
    /// in the environment only (never written to disk or logged). PROD: env unset (or a real Keychain key present) →
    /// the Keychain value, exactly as before.
    static func credentials(for config: ResolvedRunConfig, _ d: UserDefaults = .standard, allowInteraction: Bool = true,
                            primaryAPIKey: String? = nil, visionTextAPIKey: String? = nil) -> RunCredentials {
        let useAppleVision = config.provider == .appleVision
        let useGateway = !useAppleVision && d.bool(forKey: DefaultsKeys.useGateway)
        let apiKey: String = primaryAPIKey ?? {
            // A saved gateway key is only valid when the session has a gateway destination.
            guard !useGateway || config.gateway != nil else { return "" }
            guard !useAppleVision, config.localAgent == nil else { return "" }
            let keychainKey = useGateway ? GatewayConfig.storedKey(d, allowInteraction: allowInteraction)
                : (KeychainHelper.load(account: config.provider.rawValue, allowInteraction: allowInteraction) ?? "")
            if !keychainKey.isEmpty { return keychainKey }
            let env = ProcessInfo.processInfo.environment
            if env["ARCHIVEPROC_HEADLESS"] != nil, let envKey = env["LIVECAPTURE_OCRKEY"], !envKey.isEmpty {
                return envKey
            }
            return keychainKey
        }()
        let textKey = config.visionText.map {
            visionTextAPIKey ?? KeychainHelper.load(account: $0.provider.rawValue, allowInteraction: allowInteraction) ?? ""
        } ?? ""
        return RunCredentials(apiKey: apiKey, visionTextAPIKey: textKey)
    }

    /// Build the Process Files run snapshot with the exact normalization historically performed by
    /// `OCRProcessor.loadStandardImageMB()`. Fresh runs, resumes, and standalone diagnostics inject these
    /// values across OCR, PDF generation, review, tagging, export, and merge.
    ///
    /// The view can supply credentials it has already read for Start, avoiding another Keychain read
    /// when constructing the snapshot. Other callers still get the stored credentials.
    static func fromProcessFilesRunStart(_ d: UserDefaults = .standard,
                                         primaryAPIKey: String? = nil,
                                         visionTextAPIKey: String? = nil) -> SessionProcessingConfig {
        fromDefaults(d, primaryAPIKey: primaryAPIKey, visionTextAPIKey: visionTextAPIKey)
    }

    /// The backend name a retry may truthfully show. A Local Agent wins over a gateway for the same reason
    /// it wins at the client construction sites; the direct provider/model is only a fallback on that path.
    var retryBackendDescription: String {
        if let localAgent = config.localAgent {
            return "\(localAgent.provenanceDisplayName) · \(localAgent.provenanceModelName)"
        }
        if let gateway = config.gateway {
            return "\(gateway.displayName) · \(gateway.modelID)"
        }
        return "\(config.provider.rawValue) · \(config.model.displayName)"
    }

    /// A short one-line summary for the control panel: the route this session's pages actually take (the
    /// same precedence as a retry, so a Local Agent or gateway session never reads as direct provider·model),
    /// then the tagging mode. W40.fix-processor-live-settings-per-run: it used to name the provider even on
    /// the gateway route and omit the Local Agent, so a stale snapshot was not visible.
    var summary: String {
        "\(retryBackendDescription) · \(config.taggingMode.displayName)"
    }
}
