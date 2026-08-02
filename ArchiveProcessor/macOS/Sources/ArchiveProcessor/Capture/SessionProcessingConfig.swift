import Foundation

/// A snapshot of every processing setting for a live-capture session. Built from the app's shared
/// settings stores when the operator confirms at session start, then **locked** once the first
/// segment is processed so every segment in the session is handled identically.
///
/// It reads the same UserDefaults / `@AppStorage` keys the Files tab uses (plus the API key from the
/// Keychain), so Live Capture and the Files tab share one source of truth.
struct SessionProcessingConfig: Sendable {
    var provider: LLMProvider
    var model: LLMModel
    var thinkingLevel: ThinkingLevel
    var apiKey: String
    var taggingMode: TaggingMode
    var rotationMode: RotationMode
    var mergeDocuments: Bool
    var outputDirectory: URL
    var contextCharCount: Int
    var sendPreviousImage: Bool
    var customOCRPrompt: String
    var imageScale: Double            // 0…1 (fraction of full resolution)
    var standardImageMB: Double = 3.0 // size target used to translate imageScale into dimensions
    var ocrWorkerCount: Int = 4        // parallel Process Files workers (1…12)
    var enableSegmentJSON: Bool
    var tagVocabulary: [String]
    var gateway: GatewayConfig?
    var outputImageFile: Bool         // two files (PDF + separate image) vs one file (PDF only)
    // 0 still means "full resolution" to the writers (`PDFGenerator`, `ImageEncoding`), but NEITHER
    // builder below can produce it: a defaults read of 0 (or of anything out of range) resolves to the
    // 2 MB / 3 MB fallback. Only a direct memberwise construction can pass the 0 sentinel through.
    var pdfImageMB: Double            // target MB for the image embedded in the PDF (0 = full resolution)
    var exportedImageMB: Double       // target MB for the separately-exported image (0 = full resolution)
    var textColumns: Int              // number of text columns on the OCR text page (1 = single-column)
    /// The Local Agent (subscription-auth CLI) backend for this live session, or nil when using an
    /// API key / gateway. Threaded alongside `gateway` (Design decision 2 of the local-agent plan);
    /// populated from settings + preferred at the construction sites in a later checkpoint. Default
    /// nil keeps the existing `fromDefaults` memberwise-init call (which omits it) compiling unchanged.
    var localAgent: LocalAgentConfig? = nil

    /// The one declaration of what each sizing/concurrency setting is allowed to be.
    ///
    /// Before W16.cfg6-fu3 these three ranges were literals repeated across the reader (`normalizedImageMB`,
    /// `ocrWorkerCount(from:)`, `runSizing`), the Settings `Stepper`s, and
    /// `OCRProcessor.pendingRunRuntimeConfigIsValid`. Widening the ceiling meant finding all of them.
    enum Bounds {
        static let imageMB: ClosedRange<Double> = 0.5...20
        static let ocrWorkers: ClosedRange<Int> = 1...12
        static let textColumns: ClosedRange<Int> = 1...4
    }

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
    /// clamping it (`OCRProcessor.pendingRunRuntimeConfigIsValid`), and `StagedSegment`'s decoder, which
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
                d.double(forKey: DefaultsKeys.pdfImageSizeMB), fallback: 2.0),
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
    ///   another (`ProcessingProfileStore` distinguishes stored from defaulted), and an unset key already
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
    var runSizing: RunSizing {
        RunSizing(standardImageMB: standardImageMB, ocrWorkerCount: ocrWorkerCount,
                  pdfImageMB: pdfImageMB, textColumns: textColumns, exportedImageMB: exportedImageMB)
    }

    /// The rotation mode `fromDefaults()` would select, read on its own and without the Keychain.
    ///
    /// Companion to `runSizing(_:)` for the sixth value W16.cfg6 removed: the `rotationModeForRun`
    /// static. Same rule — an OCR call with no run snapshot reads the setting as it is *now* rather
    /// than whatever a previous run or a test driver last stored in a global.
    static func defaultRotationMode(_ d: UserDefaults = .standard) -> RotationMode {
        RotationMode(rawValue: d.string(forKey: DefaultsKeys.rotationModeRaw) ?? "") ?? .llmSingle
    }

    /// Read the app's shared settings into a config snapshot.
    ///
    /// The five sizing/concurrency values come from `runSizing(_:)` — the same single normalization the
    /// Process Files run start uses (W16.cfg6-fu2). This matters because **Live Capture snapshots its
    /// whole session config here**, so this is the only clamp an out-of-range default meets on that path.
    static func fromDefaults(_ d: UserDefaults = .standard) -> SessionProcessingConfig {
        let sizing = runSizing(d)
        let provider = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        let modelId = d.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        let builtIns = provider.models
        let custom = CustomModelStore.shared.allCustomModels.filter { $0.provider == provider }
        let model = (builtIns + custom).first { $0.id == modelId } ?? builtIns.first ?? provider.models[0]

        let useGateway = d.bool(forKey: DefaultsKeys.useGateway)
        let gateway = GatewayConfig.fromDefaults(d)

        let outURL: URL = {
            if let path = d.string(forKey: DefaultsKeys.outputDirectory), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }()

        // API key: the Keychain in production. Headless test fallback (env-gated): a headless CI/E2E host
        // has no GUI Keychain, so when running under ARCHIVEPROC_HEADLESS and the Keychain has no key, fall
        // back to the LIVECAPTURE_OCRKEY env var — this lets the LIVE phone-driven pipeline OCR headlessly.
        // The key stays in the environment only (never written to disk or logged). PROD: env unset (or a
        // real Keychain key present) → the Keychain value, exactly as before.
        let keychainKey = KeychainHelper.load(account: useGateway ? "Gateway" : provider.rawValue) ?? ""
        let apiKey: String = {
            if !keychainKey.isEmpty { return keychainKey }
            let env = ProcessInfo.processInfo.environment
            if env["ARCHIVEPROC_HEADLESS"] != nil, let envKey = env["LIVECAPTURE_OCRKEY"], !envKey.isEmpty {
                return envKey
            }
            return keychainKey
        }()

        return SessionProcessingConfig(
            provider: provider,
            model: model,
            thinkingLevel: ThinkingLevel(rawValue: d.string(forKey: DefaultsKeys.selectedThinking) ?? "") ?? .low,
            apiKey: apiKey,
            taggingMode: TaggingMode(rawValue: d.string(forKey: DefaultsKeys.taggingModeRaw) ?? "") ?? .automatic,
            rotationMode: defaultRotationMode(d),
            mergeDocuments: d.bool(forKey: DefaultsKeys.mergeDocuments),
            outputDirectory: outURL,
            contextCharCount: Int(d.object(forKey: DefaultsKeys.contextCharCount) as? Double ?? 200),
            sendPreviousImage: d.bool(forKey: DefaultsKeys.sendPreviousImage),
            customOCRPrompt: d.string(forKey: DefaultsKeys.customOCRPrompt) ?? "",
            imageScale: (d.object(forKey: DefaultsKeys.imageResolutionPercent) as? Double ?? 100) / 100.0,
            standardImageMB: sizing.standardImageMB,
            ocrWorkerCount: sizing.ocrWorkerCount,
            enableSegmentJSON: d.object(forKey: DefaultsKeys.enableSegmentJSON) as? Bool ?? true,
            tagVocabulary: (d.string(forKey: DefaultsKeys.tagVocabulary) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            gateway: gateway,
            outputImageFile: (d.object(forKey: DefaultsKeys.outputImageFile) as? Bool) ?? true,
            pdfImageMB: sizing.pdfImageMB,
            exportedImageMB: sizing.exportedImageMB,
            textColumns: sizing.textColumns,
            localAgent: LocalAgentConfig.fromDefaults(d)
        )
    }

    /// Build the Process Files run snapshot with the exact normalization historically performed by
    /// `OCRProcessor.loadStandardImageMB()`. Fresh runs, resumes, and standalone diagnostics inject these
    /// values across OCR, PDF generation, review, tagging, export, and merge.
    ///
    /// Retained as the *named* run-start seam its call sites read against, but since W16.cfg6-fu2 it is
    /// exactly `fromDefaults(d)`: that builder now applies the same `runSizing(_:)` normalization, so
    /// there is nothing left for a run start to correct. It used to re-apply the sizing on top —
    /// necessary only because `fromDefaults()` clamped two of the five values more loosely, which is the
    /// bug fu2 fixed. If run start ever needs to freeze something Live Capture must not, it goes here.
    static func fromProcessFilesRunStart(_ d: UserDefaults = .standard) -> SessionProcessingConfig {
        fromDefaults(d)
    }

    /// The effective model for OCR calls (gateway model when a gateway is configured).
    var effectiveModel: LLMModel { gateway?.asLLMModel() ?? model }

    /// A short one-line summary for the control panel.
    var summary: String {
        "\(provider.rawValue) · \(gateway?.displayName ?? model.displayName) · \(taggingMode.displayName)"
    }
}
