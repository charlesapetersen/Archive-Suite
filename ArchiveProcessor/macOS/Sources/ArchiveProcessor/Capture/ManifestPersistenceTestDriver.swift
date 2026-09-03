import Foundation
import AppKit

/// Headless, $0 self-test of the Live Capture session-manifest persistence (B5-ii), gated by
/// `LIVECAPTURE_MANIFESTTEST=1` (does nothing in normal use). Proves — with synthetic data in a temp dir,
/// no OCR/network/GUI, never touching a real backup folder — that:
///   1. `completedDocGroups` round-trips through the real crash-safe (`.atomic`) write + JSON decode path,
///      so a mid-session Mac restart re-surfaces each completed segment's tag card (the fixed bug).
///   2. The photo entries round-trip alongside it (grouping/tags preserved).
///   3. A LEGACY bare-array manifest (pre-B5 builds) still decodes — entries intact, completion set empty —
///      so recovery of an in-flight legacy session is never broken (the ingest recovery invariant holds).
///   4. Corrupt (non-JSON) bytes decode to nil (ignored, not misapplied).
///   5. The LAN receiver authenticates and admits a bounded request head before body buffering, rejects
///      ambiguous HTTP framing, and enforces route-specific plus aggregate memory limits.
///   6. (W23.m7) The Mac tag card's Save/Skip is durable before anything acts on it: a failed manifest
///      write refuses the decision, rolls memory back, keeps the card up and tells the operator — and live
///      processing is notified only once the decision is already readable on disk.
///
/// Writes a PASS/FAIL report to `LIVECAPTURE_MANIFESTTEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum ManifestPersistenceTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["LIVECAPTURE_MANIFESTTEST"] == "1" else { return }
        didRun = true
        run()
    }

    static func run() {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("MANIFESTTEST \(ok ? "PASS" : "FAIL"): \(name)")
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("APManifestTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("manifest.json")

        // --- B8: Live Capture must not read or write Process Files' run settings. ---
        // Activate an empty live session and confirm it changes nothing shared. B8 originally guarded six
        // mutable `nonisolated(unsafe)` statics; W16.cfg6 deleted them and W16.cfg6-fu deleted the last one
        // (`MacOSTagger.stampUnread`), so there is no shared mutable state left to poke — the old assertion
        // ("activation does not arm the tagging global") had lost its subject entirely.
        //
        // What it becomes is the channel that IS still there. A Process Files run holding no snapshot answers
        // from pure UserDefaults reads — the five sizing values via `runSizing()`, the rotation mode via
        // `defaultRotationMode()`, and the tagging mode — so a live session could now only reach a later run
        // by PERSISTING its own config. Hand `beginLiveSession` a config that differs from what is on disk in
        // every one of those SEVEN values (`unlike` takes the far end of each `Bounds` range, or the other
        // enum case), then prove each key reads back exactly as before. The two halves are separate checks so
        // a failure says which one broke, and the first is what stops the second from going quietly vacuous:
        // it compares the seven per-field, because one struct-level `!=` is satisfied by a single differing
        // value and would let the other six stop being covered without anything going red.
        //
        // Deliberately NOT claimed to be inert: constructing `CaptureSession` mints the two capture-token
        // defaults when they are absent (`loadOrCreateToken`/`loadOrCreateLANToken`), and `activate` creates
        // the session's staging dir and prunes orphaned legacy staging. Those are exactly the writes this
        // check tolerates — none of them is a key a run's sizing/rotation/tagging read touches, which is the
        // separation being pinned. The read-backs compare the RAW stored strings, so a write that happens to
        // re-store a value-equal setting still shows up.
        typealias Bounds = SessionProcessingConfig.Bounds
        func unlike<T: Equatable>(_ onDisk: T, _ a: T, _ b: T) -> T { onDisk == a ? b : a }
        let b8SizingBefore = SessionProcessingConfig.runSizing()
        let b8RotationBefore = SessionProcessingConfig.defaultRotationMode()
        let b8RotationRawBefore = UserDefaults.standard.string(forKey: DefaultsKeys.rotationModeRaw)
        let b8TaggingRawBefore = UserDefaults.standard.string(forKey: DefaultsKeys.taggingModeRaw)
        let b8TaggingBefore = TaggingMode(rawValue: b8TaggingRawBefore ?? "") ?? .automatic
        let liveIsolationSession = CaptureSession()
        let liveProvider = LLMProvider.gemini
        let liveConfig = SessionProcessingConfig(
            provider: liveProvider, model: liveProvider.models[0], thinkingLevel: .low, apiKey: "",
            taggingMode: unlike(b8TaggingBefore, .automatic, .none),
            rotationMode: unlike(b8RotationBefore, .llmSingle, .off),
            mergeDocuments: false,
            outputDirectory: tmp, contextCharCount: 200, sendPreviousImage: false,
            customOCRPrompt: "", imageScale: 1,
            standardImageMB: unlike(b8SizingBefore.standardImageMB,
                                    Bounds.imageMB.lowerBound, Bounds.imageMB.upperBound),
            ocrWorkerCount: unlike(b8SizingBefore.ocrWorkerCount,
                                   Bounds.ocrWorkers.lowerBound, Bounds.ocrWorkers.upperBound),
            enableSegmentJSON: true, tagVocabulary: [], gateway: nil,
            outputImageFile: true,
            pdfImageMB: unlike(b8SizingBefore.pdfImageMB,
                               Bounds.imageMB.lowerBound, Bounds.imageMB.upperBound),
            exportedImageMB: unlike(b8SizingBefore.exportedImageMB,
                                    Bounds.imageMB.lowerBound, Bounds.imageMB.upperBound),
            textColumns: unlike(b8SizingBefore.textColumns,
                                Bounds.textColumns.lowerBound, Bounds.textColumns.upperBound))
        // W16.cfg6-fu4: the same isolation asked of the production READ PATH, alongside — never instead of
        // — the raw-key check below. An independent Process Files processor holding no snapshot is sampled
        // either side of the activation through the three seams a snapshot-less run actually resolves
        // through: `lateRunOutputSettings` (pdf/exported sizing + tagging/merge/export),
        // `ocrCallValues` (rotation mode + standard image size) and `schedulingWorkerCount`. Between them
        // those cover the same seven values the raw-key check pins, which is the point: the raw-key check
        // names the storage, this one names only the ANSWER, so a future leak through a channel nobody
        // enumerated — a reintroduced global, a shared singleton consulted inside `defaultRotationMode()`
        // or `runSizing()` — moves this observable while the seven named keys stay green.
        //
        // Be precise about which half is which, because the two are not interchangeable:
        //   • tagging / merge / export come from the processor INSTANCE's own stored properties. No
        //     production code holds this instance, so a real Live Capture leak cannot reach it — what this
        //     half guards is the resolution LOGIC growing an ambient input that outvotes the instance.
        //     Its three values are set to the far side of the live config (opposite tagging mode, inverted
        //     merge/export flags) so such an override is visible rather than coincidentally equal.
        //   • sizing / rotation / workers are pure `runSizing()` / `defaultRotationMode()` reads — the
        //     instance contributes NOTHING to them. That half therefore overlaps the raw-key check rather
        //     than superseding it, and it is strictly narrower in one direction: it sees resolved values,
        //     so a write that re-stores a value-equal setting is invisible to it and visible only to the
        //     raw-string comparison below. Deleting either check loses coverage.
        //
        // Constructing an `OCRProcessor` here is inert — plain stored properties, no custom init, no
        // defaults registration, `activeRunConfig` nil — which is why it can sit between the baseline reads
        // and the activation without disturbing what they pin.
        let pfIsolationProcessor = OCRProcessor()
        let pfIsolationTaggingMode = unlike(liveConfig.taggingMode, .automatic, .none)
        pfIsolationProcessor.taggingMode = pfIsolationTaggingMode
        pfIsolationProcessor.mergeDocuments = !liveConfig.mergeDocuments
        pfIsolationProcessor.exportOriginals = !liveConfig.outputImageFile
        let pfSettingsBeforeLive = pfIsolationProcessor.lateRunOutputSettings(for: nil)
        let pfOCRValuesBeforeLive = OCRProcessor.ocrCallValues(for: nil)
        let pfWorkersBeforeLive = OCRProcessor.schedulingWorkerCount(for: nil)
        check("B8: the live config differs from every shared default it could leak into (7/7)",
              liveConfig.standardImageMB != b8SizingBefore.standardImageMB
              && liveConfig.ocrWorkerCount != b8SizingBefore.ocrWorkerCount
              && liveConfig.pdfImageMB != b8SizingBefore.pdfImageMB
              && liveConfig.exportedImageMB != b8SizingBefore.exportedImageMB
              && liveConfig.textColumns != b8SizingBefore.textColumns
              && liveConfig.rotationMode != b8RotationBefore
              && liveConfig.taggingMode != b8TaggingBefore)
        liveIsolationSession.beginLiveSession(config: liveConfig)
        check("B8: Live Capture activation persists nothing a later Process Files run would read back",
              SessionProcessingConfig.runSizing() == b8SizingBefore
              && UserDefaults.standard.string(forKey: DefaultsKeys.rotationModeRaw) == b8RotationRawBefore
              && UserDefaults.standard.string(forKey: DefaultsKeys.taggingModeRaw) == b8TaggingRawBefore)
        let pfSettingsAfterLive = pfIsolationProcessor.lateRunOutputSettings(for: nil)
        check("B8: activation leaves an independent Process Files run's tagging policy untouched",
              pfSettingsAfterLive.taggingMode == pfSettingsBeforeLive.taggingMode
              && pfSettingsAfterLive.stampUnread == pfSettingsBeforeLive.stampUnread
              && pfSettingsAfterLive.mergeDocuments == pfSettingsBeforeLive.mergeDocuments
              && pfSettingsAfterLive.exportOriginals == pfSettingsBeforeLive.exportOriginals
              // …and still the far side of the live config, not a copy of it.
              && pfSettingsAfterLive.taggingMode == pfIsolationTaggingMode
              && pfSettingsAfterLive.stampUnread == pfIsolationTaggingMode.stampsUnread
              && pfSettingsAfterLive.mergeDocuments == !liveConfig.mergeDocuments
              && pfSettingsAfterLive.exportOriginals == !liveConfig.outputImageFile)
        check("B8: activation leaves an independent Process Files run's late-stage sizing untouched",
              pfSettingsAfterLive.pdfImageMB == pfSettingsBeforeLive.pdfImageMB
              && pfSettingsAfterLive.textColumns == pfSettingsBeforeLive.textColumns
              && pfSettingsAfterLive.exportedImageMB == pfSettingsBeforeLive.exportedImageMB
              // …and none of the three became the live run's value (all three differ from it by `unlike`).
              && pfSettingsAfterLive.pdfImageMB != liveConfig.pdfImageMB
              && pfSettingsAfterLive.textColumns != liveConfig.textColumns
              && pfSettingsAfterLive.exportedImageMB != liveConfig.exportedImageMB)
        let pfOCRValuesAfterLive = OCRProcessor.ocrCallValues(for: nil)
        let pfWorkersAfterLive = OCRProcessor.schedulingWorkerCount(for: nil)
        check("B8: activation leaves an independent Process Files run's OCR-call inputs untouched",
              pfOCRValuesAfterLive.rotationMode == pfOCRValuesBeforeLive.rotationMode
              && pfOCRValuesAfterLive.standardImageMB == pfOCRValuesBeforeLive.standardImageMB
              && pfWorkersAfterLive == pfWorkersBeforeLive
              // …and none of the three became the live run's value.
              && pfOCRValuesAfterLive.rotationMode != liveConfig.rotationMode
              && pfOCRValuesAfterLive.standardImageMB != liveConfig.standardImageMB
              && pfWorkersAfterLive != liveConfig.ocrWorkerCount)

        let configDefaultsSuite = "APManifestTest-\(UUID().uuidString)"
        let configDefaults = UserDefaults(suiteName: configDefaultsSuite)!
        defer { configDefaults.removePersistentDomain(forName: configDefaultsSuite) }
        check("W16.cfg1: an unset OCR worker default preserves the fallback of 4",
              SessionProcessingConfig.ocrWorkerCount(from: configDefaults) == 4)
        configDefaults.set(-1, forKey: DefaultsKeys.ocrWorkerCount)
        let invalidWorkers = SessionProcessingConfig.ocrWorkerCount(from: configDefaults)
        configDefaults.set(1, forKey: DefaultsKeys.ocrWorkerCount)
        let minimumWorkers = SessionProcessingConfig.ocrWorkerCount(from: configDefaults)
        configDefaults.set(13, forKey: DefaultsKeys.ocrWorkerCount)
        let maximumWorkers = SessionProcessingConfig.ocrWorkerCount(from: configDefaults)
        check("W16.cfg1: invalid/bounded OCR worker defaults preserve the existing 1...12 clamp",
              invalidWorkers == 4 && minimumWorkers == 1 && maximumWorkers == 12)
        check("W16.cfg1: fromDefaults wires the clamped worker count into the config",
              SessionProcessingConfig.fromDefaults(configDefaults).ocrWorkerCount == 12)
        check("W16.cfg1: image-size normalization mirrors the existing run-start clamp",
              SessionProcessingConfig.normalizedImageMB(0.1, fallback: 3) == 0.5
              && SessionProcessingConfig.normalizedImageMB(21, fallback: 3) == 20
              && SessionProcessingConfig.normalizedImageMB(.infinity, fallback: 3) == 3)
        configDefaults.set(0.1, forKey: DefaultsKeys.standardImageSizeMB)
        configDefaults.set(21.0, forKey: DefaultsKeys.pdfImageSizeMB)
        configDefaults.set(Double.infinity, forKey: DefaultsKeys.exportedImageSizeMB)
        configDefaults.set(5, forKey: DefaultsKeys.textColumns)
        let processFilesConfig = SessionProcessingConfig.fromProcessFilesRunStart(configDefaults)
        check("W16.cfg1: Process Files run-start builder normalizes every migrated setting",
              processFilesConfig.standardImageMB == 0.5
              && processFilesConfig.ocrWorkerCount == 12
              && processFilesConfig.pdfImageMB == 20
              && processFilesConfig.exportedImageMB == 3
              && processFilesConfig.textColumns == 4)

        // --- W16.cfg6: `runSizing` is a PURE read — the property the deleted statics could not have. ---
        // A static could hold a value written by a run that already finished (or by a test driver whose
        // `defer` a crash skipped). These three checks pin the replacement's actual guarantee: what comes
        // back is a function of the defaults handed in, at the moment it is asked, and nothing else.
        let sizingFirstRead = SessionProcessingConfig.runSizing(configDefaults)
        check("W16.cfg6: runSizing applies the same clamps loadStandardImageMB() did",
              sizingFirstRead.standardImageMB == 0.5      // 0.1 → clamped up
              && sizingFirstRead.ocrWorkerCount == 12     // 13  → clamped down
              && sizingFirstRead.pdfImageMB == 20         // 21  → clamped down
              && sizingFirstRead.exportedImageMB == 3     // .infinity → fallback
              && sizingFirstRead.textColumns == 4)        // 5   → clamped down
        check("W16.cfg6: reading twice with no write in between returns the identical value",
              SessionProcessingConfig.runSizing(configDefaults) == sizingFirstRead)
        configDefaults.set(1.5, forKey: DefaultsKeys.pdfImageSizeMB)
        configDefaults.set(2, forKey: DefaultsKeys.textColumns)
        let sizingAfterWrite = SessionProcessingConfig.runSizing(configDefaults)
        check("W16.cfg6: a changed default is picked up immediately — nothing is cached or retained",
              sizingAfterWrite.pdfImageMB == 1.5 && sizingAfterWrite.textColumns == 2
              && sizingAfterWrite.standardImageMB == sizingFirstRead.standardImageMB)
        check("W16.cfg6: the run-start builder normalizes through that same one read",
              SessionProcessingConfig.fromProcessFilesRunStart(configDefaults).runSizing == sizingAfterWrite)
        // Restore the values the later fromProcessFilesRunStart assertions above were written against.
        configDefaults.set(21.0, forKey: DefaultsKeys.pdfImageSizeMB)
        configDefaults.set(5, forKey: DefaultsKeys.textColumns)

        // --- W16.cfg6-fu2: LIVE CAPTURE's builder clamps identically to the run-start one. ---
        // `fromDefaults()` used to size pdfImageMB/exportedImageMB with bare inline closures
        // (`p > 0 ? p : 2.0`) — no `.isFinite` guard, no 0.5 floor, no 20 ceiling — while the other three
        // values went through the strict shared helpers. `CaptureSession` snapshots its whole session
        // config from `fromDefaults()`, so those two closures were the ONLY clamp an out-of-range default
        // met on the live path: 21 MB stayed 21 for a live capture while Process Files made it 20.
        // These pin the fix at the VALUE level (a check that merely compares the two builders to each
        // other would stay green if both drifted together).
        let liveBuilderConfig = SessionProcessingConfig.fromDefaults(configDefaults)
        check("W16.cfg6-fu2: fromDefaults clamps every sizing value, so Live Capture cannot be handed one out of range",
              liveBuilderConfig.standardImageMB == 0.5   // 0.1 → floor
              && liveBuilderConfig.ocrWorkerCount == 12  // 13  → ceiling
              && liveBuilderConfig.pdfImageMB == 20      // 21  → ceiling (was 21 unclamped)
              && liveBuilderConfig.exportedImageMB == 3  // non-finite → fallback (was passed through)
              && liveBuilderConfig.textColumns == 4)     // 5   → ceiling
        check("W16.cfg6-fu2: the live and run-start builders now resolve to the same five numbers",
              liveBuilderConfig.runSizing == SessionProcessingConfig.runSizing(configDefaults)
              && SessionProcessingConfig.fromProcessFilesRunStart(configDefaults).runSizing
                  == liveBuilderConfig.runSizing)

        // A separate suite, so these edge values cannot disturb the assertions above or below.
        let fu2Suite = "APManifestTest-fu2-\(UUID().uuidString)"
        let fu2Defaults = UserDefaults(suiteName: fu2Suite)!
        defer { fu2Defaults.removePersistentDomain(forName: fu2Suite) }
        let unsetConfig = SessionProcessingConfig.fromDefaults(fu2Defaults)
        check("W16.cfg6-fu2: an unset sizing default still yields the documented fallback, not the floor",
              unsetConfig.pdfImageMB == 2.0 && unsetConfig.exportedImageMB == 3.0
              && unsetConfig.standardImageMB == 3.0 && unsetConfig.ocrWorkerCount == 4
              && unsetConfig.textColumns == 1)
        // The sub-floor case the old closures let through untouched: `0.25 > 0`, so it was kept verbatim.
        fu2Defaults.set(0.25, forKey: DefaultsKeys.pdfImageSizeMB)
        fu2Defaults.set(0.4, forKey: DefaultsKeys.exportedImageSizeMB)
        let subFloorConfig = SessionProcessingConfig.fromDefaults(fu2Defaults)
        check("W16.cfg6-fu2: a sub-floor image size is raised to 0.5, not embedded as written",
              subFloorConfig.pdfImageMB == 0.5 && subFloorConfig.exportedImageMB == 0.5)
        // Non-finite is the case the old closures were WORST at: `Double.infinity > 0` is true, so an
        // infinite target went to Live Capture verbatim — and UserDefaults really does round-trip it
        // (measured, not assumed). NaN and negatives already fell back before the fix; they are here to
        // pin that the new `.isFinite && > 0` guard did not trade one hole for another.
        fu2Defaults.set(Double.infinity, forKey: DefaultsKeys.pdfImageSizeMB)
        fu2Defaults.set(Double.nan, forKey: DefaultsKeys.exportedImageSizeMB)
        let nonFiniteConfig = SessionProcessingConfig.fromDefaults(fu2Defaults)
        check("W16.cfg6-fu2: an infinite or NaN image size falls back rather than reaching a live session",
              fu2Defaults.double(forKey: DefaultsKeys.pdfImageSizeMB).isInfinite   // the input really is ∞
              && nonFiniteConfig.pdfImageMB == 2.0 && nonFiniteConfig.exportedImageMB == 3.0)
        fu2Defaults.set(-3.0, forKey: DefaultsKeys.pdfImageSizeMB)
        check("W16.cfg6-fu2: a negative image size falls back rather than being floored to 0.5",
              SessionProcessingConfig.fromDefaults(fu2Defaults).pdfImageMB == 2.0)

        // --- W16.cfg6-fu3: the WRITERS are bounded too, so what Settings shows is what a run uses. ---
        // fu2 made every defaults READ clamp, so nothing out of range can reach a run. What was left is
        // that an out-of-range number could still be STORED and DISPLAYED: each MB row pairs a bounded
        // Stepper with a TextField that accepts anything, so typing 500 persisted 500 and kept showing
        // 500 while every run used 20 and the cost pane quoted 500. These pin the writer half.
        let fu3Suite = "APManifestTest-fu3-\(UUID().uuidString)"
        let fu3Defaults = UserDefaults(suiteName: fu3Suite)!
        defer { fu3Defaults.removePersistentDomain(forName: fu3Suite) }

        // Pinned as VALUES, not as "the clamps agree with themselves": `pendingRunRuntimeConfigIsValid`
        // spelled these ranges out as its own literals until fu3 and now reads `Bounds`. If `Bounds` ever
        // widened, that fail-closed resume validator would silently start admitting a config that no
        // builder in the app can produce — this check is what makes the shared declaration safe.
        check("W16.cfg6-fu3: Bounds still spell the ranges the four former literal sites used",
              SessionProcessingConfig.Bounds.imageMB == 0.5...20
              && SessionProcessingConfig.Bounds.ocrWorkers == 1...12
              && SessionProcessingConfig.Bounds.textColumns == 1...4)

        // An unset key must STAY unset. Normalizing is about correcting what the operator stored, not
        // about materializing five defaults he never chose — `ProcessingProfileStore.read` distinguishes
        // stored from defaulted, so writing them all would change what a snapshot means.
        let normalizedNothing = SessionProcessingConfig.normalizeSizingDefaults(fu3Defaults)
        check("W16.cfg6-fu3: normalizing an all-unset domain writes nothing and reports no change",
              !normalizedNothing
              && fu3Defaults.object(forKey: DefaultsKeys.standardImageSizeMB) == nil
              && fu3Defaults.object(forKey: DefaultsKeys.pdfImageSizeMB) == nil
              && fu3Defaults.object(forKey: DefaultsKeys.exportedImageSizeMB) == nil
              && fu3Defaults.object(forKey: DefaultsKeys.ocrWorkerCount) == nil
              && fu3Defaults.object(forKey: DefaultsKeys.textColumns) == nil)

        // The headline case: the 500 an operator can type into the field today.
        fu3Defaults.set(500.0, forKey: DefaultsKeys.standardImageSizeMB)
        fu3Defaults.set(0.25, forKey: DefaultsKeys.pdfImageSizeMB)
        fu3Defaults.set(Double.infinity, forKey: DefaultsKeys.exportedImageSizeMB)
        fu3Defaults.set(100, forKey: DefaultsKeys.ocrWorkerCount)
        fu3Defaults.set(9, forKey: DefaultsKeys.textColumns)
        // What a run WOULD have used, read BEFORE the writer touches anything. This is the honest
        // subject of the next check — see the note there.
        let fu3SizingBeforeNormalizing = SessionProcessingConfig.runSizing(fu3Defaults)
        let normalizedSomething = SessionProcessingConfig.normalizeSizingDefaults(fu3Defaults)
        check("W16.cfg6-fu3: an out-of-range STORED value is rewritten to the value a run would use",
              normalizedSomething
              && fu3Defaults.double(forKey: DefaultsKeys.standardImageSizeMB) == 20    // 500 → ceiling
              && fu3Defaults.double(forKey: DefaultsKeys.pdfImageSizeMB) == 0.5        // 0.25 → floor
              && fu3Defaults.double(forKey: DefaultsKeys.exportedImageSizeMB) == 3.0   // ∞ → fallback
              && fu3Defaults.integer(forKey: DefaultsKeys.ocrWorkerCount) == 12        // 100 → ceiling
              && fu3Defaults.integer(forKey: DefaultsKeys.textColumns) == 4)           // 9   → ceiling

        // The property the item is actually about — visible == effective — stated so it can FAIL.
        // Comparing the stored values against a fresh `fromDefaults` *after* the write proves almost
        // nothing: the reader agrees with any in-range number it is handed, so a normalizer that clamped
        // ∞ to the 20 ceiling instead of the 3.0 fallback would pass it. (Measured, not assumed — that
        // mutation left the after-the-fact comparison green and only this form caught it.) So the subject
        // is what a run would have used BEFORE normalizing.
        check("W16.cfg6-fu3: the writer stores exactly what the pre-normalization read resolved to",
              fu3Defaults.double(forKey: DefaultsKeys.standardImageSizeMB)
                  == fu3SizingBeforeNormalizing.standardImageMB
              && fu3Defaults.double(forKey: DefaultsKeys.pdfImageSizeMB)
                  == fu3SizingBeforeNormalizing.pdfImageMB
              && fu3Defaults.double(forKey: DefaultsKeys.exportedImageSizeMB)
                  == fu3SizingBeforeNormalizing.exportedImageMB
              && fu3Defaults.integer(forKey: DefaultsKeys.ocrWorkerCount)
                  == fu3SizingBeforeNormalizing.ocrWorkerCount
              && fu3Defaults.integer(forKey: DefaultsKeys.textColumns)
                  == fu3SizingBeforeNormalizing.textColumns
              // …and the live builder still agrees afterwards, so the two halves have not drifted.
              && SessionProcessingConfig.fromDefaults(fu3Defaults).runSizing
                  == fu3SizingBeforeNormalizing)

        // It runs on every Settings change, so the second pass must be a genuine no-op — otherwise each
        // write re-enters `.onChange` and the field never settles.
        check("W16.cfg6-fu3: a second normalization writes nothing",
              !SessionProcessingConfig.normalizeSizingDefaults(fu3Defaults))

        // Every value the checks above land on is a bound or a fallback — 20 / 0.5 / 3.0 / 12 / 4, all
        // multiples of 0.5. A normalizer that ROUNDED each size to the nearest 0.5 would satisfy all of
        // them, idempotency included, while quietly turning an operator's 7.3 MB into 7.5. The writer is
        // only allowed to touch what is out of range, so pin an in-range, non-boundary, non-round value.
        fu3Defaults.set(7.3, forKey: DefaultsKeys.standardImageSizeMB)
        fu3Defaults.set(1.7, forKey: DefaultsKeys.pdfImageSizeMB)
        fu3Defaults.set(11.9, forKey: DefaultsKeys.exportedImageSizeMB)
        fu3Defaults.set(6, forKey: DefaultsKeys.ocrWorkerCount)
        fu3Defaults.set(2, forKey: DefaultsKeys.textColumns)
        let normalizedInRange = SessionProcessingConfig.normalizeSizingDefaults(fu3Defaults)
        check("W16.cfg6-fu3: an in-range value is left exactly as the operator set it",
              !normalizedInRange
              && fu3Defaults.double(forKey: DefaultsKeys.standardImageSizeMB) == 7.3
              && fu3Defaults.double(forKey: DefaultsKeys.pdfImageSizeMB) == 1.7
              && fu3Defaults.double(forKey: DefaultsKeys.exportedImageSizeMB) == 11.9
              && fu3Defaults.integer(forKey: DefaultsKeys.ocrWorkerCount) == 6
              && fu3Defaults.integer(forKey: DefaultsKeys.textColumns) == 2)

        // The ETA clamped the worker count LOW only (`max(1, ocrWorkers)`), so a stored 100 quoted a time
        // ~8× optimistic while `schedulingWorkerCount` still ran 12. Pinned against 12 (must match) AND
        // against 1 (must differ) — without the second half, an estimator that ignored workers entirely
        // would pass the first.
        let etaModel = LLMProvider.gemini.models[0]
        func etaOCRSeconds(_ workers: Int) -> Double {
            TimeEstimator.estimate(fileCount: 1000, model: etaModel, enableTagging: false,
                                   ocrWorkers: workers).ocrSeconds
        }
        check("W16.cfg6-fu3: the ETA clamps the worker count at both ends, as the pipeline does",
              etaOCRSeconds(100) == etaOCRSeconds(12)
              && etaOCRSeconds(0) == etaOCRSeconds(1)
              && etaOCRSeconds(12) < etaOCRSeconds(1))

        // A profile is unvalidated JSON on disk that `apply` writes verbatim — the one path that could put
        // any Double back into the five keys after Settings had been left in range. Exercised on a scratch
        // suite (that is why `apply` takes a `UserDefaults` now), never the real app's settings.
        let fu3ProfileSuite = "APManifestTest-fu3p-\(UUID().uuidString)"
        let fu3ProfileDefaults = UserDefaults(suiteName: fu3ProfileSuite)!
        defer { fu3ProfileDefaults.removePersistentDomain(forName: fu3ProfileSuite) }
        let handEditedProfile = ProcessingProfile(name: "hand-edited", values: [
            DefaultsKeys.standardImageSizeMB: .double(500),
            DefaultsKeys.pdfImageSizeMB: .double(-4),
            DefaultsKeys.exportedImageSizeMB: .double(0),
            DefaultsKeys.ocrWorkerCount: .int(64),
            DefaultsKeys.textColumns: .int(11),
            DefaultsKeys.batchMode: .bool(true),
        ])
        ProcessingProfileStore.shared.apply(handEditedProfile, to: fu3ProfileDefaults)
        check("W16.cfg6-fu3: applying a hand-edited profile cannot store a sizing value out of range",
              fu3ProfileDefaults.double(forKey: DefaultsKeys.standardImageSizeMB) == 20
              && fu3ProfileDefaults.double(forKey: DefaultsKeys.pdfImageSizeMB) == 2.0   // ≤ 0 → fallback
              && fu3ProfileDefaults.double(forKey: DefaultsKeys.exportedImageSizeMB) == 3.0
              && fu3ProfileDefaults.integer(forKey: DefaultsKeys.ocrWorkerCount) == 12
              && fu3ProfileDefaults.integer(forKey: DefaultsKeys.textColumns) == 4
              // …and a non-sizing key is still applied verbatim: this bounds the writer, not the feature.
              && fu3ProfileDefaults.bool(forKey: DefaultsKeys.batchMode))

        // --- W16.cfg2/cfg6: an injected config wins; with none, the helpers read defaults, not a global. ---
        let liveSizing = SessionProcessingConfig.runSizing()
        let fallbackPDF = OCRProcessor.pdfGenerationSettings(for: nil)
        check("W16.cfg6: a nil config resolves through runSizing() rather than a process-global",
              OCRProcessor.schedulingWorkerCount(for: nil) == liveSizing.ocrWorkerCount
              && fallbackPDF.imageMB == liveSizing.pdfImageMB
              && fallbackPDF.textColumns == liveSizing.textColumns
              && OCRProcessor.ocrCallValues(for: nil).standardImageMB == liveSizing.standardImageMB
              && OCRProcessor.ocrCallValues(for: nil).rotationMode
                  == SessionProcessingConfig.defaultRotationMode())
        var injectedConfig = processFilesConfig
        injectedConfig.standardImageMB = 7
        injectedConfig.ocrWorkerCount = 9
        injectedConfig.pdfImageMB = 8
        injectedConfig.textColumns = 3
        injectedConfig.exportedImageMB = 6
        let injectedPDF = OCRProcessor.pdfGenerationSettings(for: injectedConfig)
        check("W16.cfg2: an immutable config overrides the worker/PDF values a defaults read would give",
              OCRProcessor.schedulingWorkerCount(for: injectedConfig) == 9
              && injectedPDF.imageMB == 8
              && injectedPDF.textColumns == 3)
        let persistedConfig = OCRProcessor().makePendingRunRuntimeConfig(
            imageScale: 0.75, gatewayConfig: nil, runConfig: injectedConfig)
        check("W16.cfg2: resume snapshot records the exact injected sizing/scheduling values",
              persistedConfig.standardImageMB == 7
              && persistedConfig.ocrWorkerCount == 9
              && persistedConfig.pdfImageMB == 8
              && persistedConfig.textColumns == 3
              && persistedConfig.exportedImageMB == 6)
        let retryProcessor = OCRProcessor()
        retryProcessor.activeRunConfig = injectedConfig
        let retainedRetryConfig = retryProcessor.runConfigForRetry(nil)
        var explicitRetryConfig = injectedConfig
        explicitRetryConfig.pdfImageMB = 5
        let explicitRetryResult = retryProcessor.runConfigForRetry(explicitRetryConfig)
        check("W16.cfg2: post-run per-item retry retains the original config; an explicit retry config wins",
              retainedRetryConfig?.standardImageMB == 7
              && retainedRetryConfig?.pdfImageMB == 8
              && explicitRetryResult?.pdfImageMB == 5)

        // --- W16.cfg3: late review/regeneration/tagging reads retain the same immutable snapshot. ---
        let lateStageProcessor = OCRProcessor()
        lateStageProcessor.taggingMode = .none
        lateStageProcessor.mergeDocuments = true
        lateStageProcessor.exportOriginals = false
        lateStageProcessor.activeRunConfig = injectedConfig
        let retainedLateSettings = lateStageProcessor.lateRunOutputSettings(for: nil)
        var explicitLateConfig = injectedConfig
        explicitLateConfig.pdfImageMB = 5
        explicitLateConfig.textColumns = 2
        explicitLateConfig.exportedImageMB = 4
        explicitLateConfig.taggingMode = .human
        explicitLateConfig.mergeDocuments = true
        explicitLateConfig.outputImageFile = false
        let explicitLateSettings = lateStageProcessor.lateRunOutputSettings(for: explicitLateConfig)
        check("W16.cfg3: retained/explicit configs override conflicting late-stage mutable settings",
              retainedLateSettings.pdfImageMB == 8
              && retainedLateSettings.textColumns == 3
              && retainedLateSettings.exportedImageMB == 6
              && retainedLateSettings.stampUnread
              && retainedLateSettings.taggingMode == .automatic
              && !retainedLateSettings.mergeDocuments
              && retainedLateSettings.exportOriginals
              && explicitLateSettings.pdfImageMB == 5
              && explicitLateSettings.textColumns == 2
              && explicitLateSettings.exportedImageMB == 4
              && explicitLateSettings.stampUnread
              && explicitLateSettings.taggingMode == .human
              && explicitLateSettings.mergeDocuments
              && !explicitLateSettings.exportOriginals)
        lateStageProcessor.activeRunConfig = nil
        let fallbackLateSettings = lateStageProcessor.lateRunOutputSettings(for: nil)
        check("W16.cfg6: with no snapshot at all, late-stage sizing comes from a live defaults read",
              fallbackLateSettings.pdfImageMB == liveSizing.pdfImageMB
              && fallbackLateSettings.textColumns == liveSizing.textColumns
              && fallbackLateSettings.exportedImageMB == liveSizing.exportedImageMB
              && !fallbackLateSettings.stampUnread
              && fallbackLateSettings.taggingMode == .none
              && fallbackLateSettings.mergeDocuments
              && !fallbackLateSettings.exportOriginals)

        // W16.cfg6: `targetDimensionScale` requires its size target, so two runs cannot share one. The
        // same 1 MB file yields a different scale per caller, and neither call can influence the other.
        let sizedInput = tmp.appendingPathComponent("b8-one-megabyte.jpg")
        try? Data(repeating: 0x42, count: 1_000_000).write(to: sizedInput)
        let explicitScale = OCRProcessor.targetDimensionScale(
            forFileAt: sizedInput, sizeFraction: 1, standardImageMB: 0.5)
        let otherRunScale = OCRProcessor.targetDimensionScale(
            forFileAt: sizedInput, sizeFraction: 1, standardImageMB: 3)
        let explicitScaleAgain = OCRProcessor.targetDimensionScale(
            forFileAt: sizedInput, sizeFraction: 1, standardImageMB: 0.5)
        check("B8: each caller's own size snapshot decides its scale; a second caller changes nothing",
              abs(explicitScale - 0.5.squareRoot()) < 0.0001   // 0.5 MB target under a 1 MB file
              && otherRunScale == 1                            // 3 MB target ≥ 1 MB file → full res
              && explicitScaleAgain == explicitScale)

        let explicitlyStamped = tmp.appendingPathComponent("b8-explicit-stamp.txt")
        let explicitlyPlain = tmp.appendingPathComponent("b8-explicit-plain.txt")
        try? Data("stamp".utf8).write(to: explicitlyStamped)
        try? Data("plain".utf8).write(to: explicitlyPlain)
        // Two back-to-back writes with OPPOSITE policies, on one thread, through one adapter. Before
        // W16.cfg4 the second would have been decided by whatever the process-global last held; the
        // argument is now the only input, so neither call can colour the other. (W16.cfg6-fu deleted the
        // global, which is what turns this from "explicit wins over the global" into "there is nothing
        // else to win against".)
        // W16.cfg6-fu4: a THIRD call closes the direction two cannot see. Two calls — `true` then `false`,
        // on different files — only prove the second is not coloured by the first. The sequence is now
        // `true`, `false`, `true`, with the last two on the SAME file, so it also proves the copy-source
        // write leaves no residue that suppresses the later stamp: the exact failure any reintroduced
        // sticky state would produce, and the one direction a `true`-then-`false` pair is blind to.
        //
        // Tags are compared as a MULTISET, never by position (`SPEC/tag-format.md`: macOS may reorder on
        // write, which is why `CoordinatedTagWriter` verifies with `multisetEqual`). The stamp's presence
        // is the property under test — residue drops it entirely, it does not reorder it.
        _ = try? MacOSTagger.applyTags(["Subject"], to: explicitlyStamped, stampUnread: true)
        _ = try? MacOSTagger.applyTags(["Subject"], to: explicitlyPlain, stampUnread: false)
        let stampedTags = try? MacOSTagger.readTags(from: explicitlyStamped)
        let plainTags = try? MacOSTagger.readTags(from: explicitlyPlain)
        _ = try? MacOSTagger.applyTags(["Subject"], to: explicitlyPlain, stampUnread: true)
        let restampedTags = try? MacOSTagger.readTags(from: explicitlyPlain)
        check("B8: each write's own stampUnread: decides it; the adjacent opposite write changes nothing",
              stampedTags?.sorted() == ["Subject", "Unread"] && plainTags == ["Subject"])
        check("B8: a re-stamp after an interleaved copy-source write still lands",
              restampedTags?.sorted() == ["Subject", "Unread"])

        typealias Entry = CaptureSession.ManifestEntry
        let entries = [
            Entry(name: "00001-gDoc.jpg", groupId: "gDoc", seq: 1, type: "document", quality: "Q1", year: 1968, month: 3),
            Entry(name: "00002-gDoc.jpg", groupId: "gDoc", seq: 2, type: "document", quality: nil, year: 1968, month: 3),
            Entry(name: "00003-gBox.jpg", groupId: "gBox", seq: 3, type: "box", quality: nil, year: nil, month: nil),
        ]
        let completed: Set<String> = ["gDoc"]   // gDoc's segment was signalled complete; gBox is a marker

        // --- 1+2: current object form round-trips (photos AND completedDocGroups). ---
        let manifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: Array(completed))
        let wrote = (try? JSONEncoder().encode(manifest)).map { (try? $0.write(to: file, options: .atomic)) != nil } ?? false
        check("manifest written via atomic (.atomic) path", wrote && fm.fileExists(atPath: file.path))

        let roundTrip = (try? Data(contentsOf: file)).flatMap { CaptureSession.decodeManifest($0) }
        check("manifest round-trips (decodes back)", roundTrip != nil)
        check("completedDocGroups survives the round-trip", roundTrip?.completed == completed)
        check("photo entries survive the round-trip (count + fields)",
              roundTrip?.entries.count == 3
              && roundTrip?.entries.first?.groupId == "gDoc"
              && roundTrip?.entries.first?.quality == "Q1"
              && roundTrip?.entries.first?.year == 1968
              && roundTrip?.entries.last?.type == "box")

        // --- 3: a legacy bare-array manifest (pre-B5) still decodes — entries intact, completion empty. ---
        let legacyData = (try? JSONEncoder().encode(entries)) ?? Data()
        let legacy = CaptureSession.decodeManifest(legacyData)
        check("legacy bare-array manifest still decodes (recovery unbroken)", legacy != nil)
        check("legacy manifest keeps all photo entries", legacy?.entries.count == 3)
        check("legacy manifest completion set is empty (unchanged pre-B5 behavior)", legacy?.completed.isEmpty == true)

        // --- object form with an EMPTY completion set decodes fine (no false positives). ---
        let emptyManifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: [])
        let emptyDecoded = (try? JSONEncoder().encode(emptyManifest)).flatMap { CaptureSession.decodeManifest($0) }
        check("object manifest with empty completion set decodes with no completed groups",
              emptyDecoded != nil && emptyDecoded?.completed.isEmpty == true && emptyDecoded?.entries.count == 3)

        // --- 4: corrupt bytes decode to nil (ignored). ---
        check("corrupt (non-JSON) manifest bytes decode to nil (ignored)",
              CaptureSession.decodeManifest(Data("not json {".utf8)) == nil)

        // --- B9: resolvedGroupIds + macTags round-trip so a mid-session Mac restart does NOT re-surface an
        //         already-resolved tag card (nor drop its Mac-entered tags). Optional keys => pre-B9
        //         manifests still decode, to empty (back-compat). ---
        let b9File = tmp.appendingPathComponent("b9.json")
        let macTags: [String: MacSegmentTags] = [
            "gDoc": MacSegmentTags(subjects: ["elections", "1968 campaign"], quality: 1, year: 1968, month: 3)
        ]
        let b9Manifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: Array(completed),
                                                        resolvedGroupIds: ["gDoc"], macTags: macTags)
        let b9Wrote = (try? JSONEncoder().encode(b9Manifest)).map { (try? $0.write(to: b9File, options: .atomic)) != nil } ?? false
        let b9 = (try? Data(contentsOf: b9File)).flatMap { CaptureSession.decodeManifest($0) }
        check("B9: manifest with resolved/macTags written + decodes", b9Wrote && b9 != nil)
        check("B9: resolvedGroupIds survives the round-trip", b9?.resolved == ["gDoc"])
        check("B9: macTags survives the round-trip (subjects + date + Quality)",
              b9?.macTags["gDoc"]?.subjects == ["elections", "1968 campaign"]
              && b9?.macTags["gDoc"]?.year == 1968 && b9?.macTags["gDoc"]?.quality == 1)
        check("B9 back-compat: pre-B9 manifest (no resolved/macTags keys) decodes to empty",
              legacy?.resolved.isEmpty == true && legacy?.macTags.isEmpty == true
              && emptyDecoded?.resolved.isEmpty == true && emptyDecoded?.macTags.isEmpty == true)

        // --- B10: segment completion is acknowledged only after the real session manifest write succeeds.
        // Inject a write failure, prove memory rolls back, then retry and prove the card becomes durable.
        let session = CaptureSession()
        session.beginStageSessionForTest()   // never inherit live-processing defaults / launch OCR or network
        let ingested = session.ingest(jpeg: Data("synthetic page".utf8), groupId: "gDurable", seq: 99,
                                      type: .document, quality: nil, year: nil, month: nil,
                                      deviceName: "ManifestTest")
        check("B10: synthetic page ingests before completion test", ingested != nil)
        session.manifestWriteOverride = { _, _ in false }
        let failedCompletion = session.markSegmentComplete(
            groupId: "gDurable", quality: "Q1", year: 1972, month: 6)
        check("B10: manifest failure refuses completion acknowledgement", !failedCompletion)
        check("B10: manifest failure rolls completion/card state back", session.pendingTagGroup == nil)
        check("B10: manifest failure rolls photo metadata back",
              session.photos.first(where: { $0.groupId == "gDurable" })?.year == nil
              && session.photos.first(where: { $0.groupId == "gDurable" })?.quality == nil)
        session.manifestWriteOverride = nil
        let retriedCompletion = session.markSegmentComplete(
            groupId: "gDurable", quality: "Q1", year: 1972, month: 6)
        check("B10: retry acknowledges after durable manifest write", retriedCompletion)
        check("B10: successful retry exposes the completed tag card with metadata",
              session.pendingTagGroup?.id == "gDurable"
              && session.photos.first(where: { $0.groupId == "gDurable" })?.year == 1972
              && session.photos.first(where: { $0.groupId == "gDurable" })?.quality == "Q1")

        let sessionPhoto = session.ingest(jpeg: Data("synthetic final page".utf8), groupId: "gSession",
                                          seq: 100, type: .document, quality: nil, year: nil, month: nil,
                                          deviceName: "ManifestTest")
        check("B10: final open group ingests before session-completion test", sessionPhoto != nil)
        session.manifestWriteOverride = { _, _ in false }
        let failedSessionCompletion = session.completeAllOpenDocGroups()
        check("B10: manifest failure refuses session-completion acknowledgement", !failedSessionCompletion)
        check("B10: manifest failure rolls whole-session completion back",
              !session.completedDocGroups.contains("gSession"))
        session.manifestWriteOverride = nil
        let retriedSessionCompletion = session.completeAllOpenDocGroups()
        check("B10: whole-session retry acknowledges after durable manifest write",
              retriedSessionCompletion && session.completedDocGroups.contains("gSession"))

        session.liveProcessor.requestFinish()
        check("B10: initial operator Finish can wait on unresolved tag cards",
              session.liveProcessor.pendingFinish)
        let latePhoto = session.ingest(jpeg: Data("synthetic late page".utf8), groupId: "gLate",
                                       seq: 101, type: .document, quality: nil, year: nil, month: nil,
                                       deviceName: "ManifestTest")
        check("B10: late group ingests while Finish is pending", latePhoto != nil)
        session.manifestWriteOverride = { _, _ in false }
        session.liveProcessor.requestFinish()
        check("B10: failed Finish re-tap cancels the earlier watchdog",
              !session.liveProcessor.pendingFinish && !session.completedDocGroups.contains("gLate"))
        session.manifestWriteOverride = nil
        session.liveProcessor.requestFinish()
        check("B10: operator Finish retry persists the late group and re-arms safely",
              session.liveProcessor.pendingFinish && session.completedDocGroups.contains("gLate"))
        session.liveProcessor.cancelPendingFinish()
        let restoredSession = CaptureSession()
        check("B10: successful segment/session retries survive a fresh session restore",
              restoredSession.pendingTagGroup?.id == "gDurable"
              && restoredSession.completedDocGroups.isSuperset(of: ["gSession", "gLate"])
              && restoredSession.photos.first(where: { $0.groupId == "gDurable" })?.year == 1972
              && restoredSession.photos.first(where: { $0.groupId == "gDurable" })?.quality == "Q1")

        // --- W23.m7: the Mac tag card's Apply/Skip decision is durable BEFORE anything acts on it.
        // Same synthetic temp session (no corpus, no OCR, no network, no GUI). Two halves are proven:
        // (a) a failed manifest write refuses the decision, rolls memory back and leaves the card up with
        //     a message, so the operator can retry instead of losing a decision the app already acted on;
        // (b) live processing is told the segment resolved only AFTER the bytes are on disk — asserted by
        //     reading the real manifest file from inside the notification itself, not by inspection.
        let manifestFile = session.incomingFolder.appendingPathComponent("manifest.json")
        // Clear the cards B10 left pending so exactly one card is up per case below.
        var leftoverResolvesDurable = true
        while let pending = session.pendingTagGroup, pending.id != "gCard" {
            if !session.skipMacTags(groupId: pending.id) { leftoverResolvesDurable = false; break }
        }
        check("W23.m7: B10's leftover cards resolve durably (test precondition)",
              leftoverResolvesDurable && session.pendingTagGroup == nil)

        var notified: [String] = []
        var durableOnDiskWhenNotified: [String: Bool] = [:]
        session.resolvedNotifyHookForTest = { groupId in
            notified.append(groupId)
            let onDisk = (try? Data(contentsOf: manifestFile)).flatMap { CaptureSession.decodeManifest($0) }
            let durableNow = onDisk?.resolved.contains(groupId) == true
            // AND, not overwrite: one premature notification must stay visible even if a later retry
            // notifies again from a durable state.
            durableOnDiskWhenNotified[groupId] = (durableOnDiskWhenNotified[groupId] ?? true) && durableNow
        }

        let cardPhoto = session.ingest(jpeg: Data("synthetic card page".utf8), groupId: "gCard", seq: 102,
                                       type: .document, quality: "Q3", year: nil, month: nil,
                                       deviceName: "ManifestTest")
        check("W23.m7: a page for the tag-card group ingests", cardPhoto != nil)
        check("W23.m7: its segment completes and surfaces exactly one card",
              session.markSegmentComplete(groupId: "gCard", quality: nil, year: nil, month: nil)
              && session.pendingTagGroup?.id == "gCard")

        // (a) Save against a failing write: refused, rolled back, card kept, operator told, nothing acted on.
        var saveOfferedDecisionToDisk = false
        session.manifestWriteOverride = { data, _ in
            let offered = CaptureSession.decodeManifest(data)
            saveOfferedDecisionToDisk = offered?.resolved.contains("gCard") == true
                && offered?.macTags["gCard"]?.subjects == ["oral history"]
                && offered?.macTags["gCard"]?.year == 1971
                && offered?.macTags["gCard"]?.quality == 2
            return false
        }
        session.statusMessage = "Listening"
        let refusedSave = session.applyMacTags(groupId: "gCard", subjects: ["oral history"],
                                               quality: 2, year: 1971, month: 4)
        check("W23.m7: a failed manifest write refuses the Save instead of reporting success", !refusedSave)
        check("W23.m7: the refused Save had already staged the decision into the bytes offered to disk",
              saveOfferedDecisionToDisk)
        check("W23.m7: a refused Save rolls the resolve AND the Mac tags back",
              !session.resolvedGroupIds.contains("gCard") && session.macTags["gCard"] == nil)
        check("W23.m7: a refused Save leaves the card up (the operator can retry, nothing typed is lost)",
              session.pendingTagGroup?.id == "gCard")
        check("W23.m7: a refused Save never tells live processing the segment resolved", notified.isEmpty)
        check("W23.m7: a refused Save is announced to the operator",
              session.statusMessage == CaptureSession.tagDecisionNotDurableMessage)
        let afterRefusedSave = CaptureSession()
        check("W23.m7: after a refused Save a relaunch agrees with memory — card unresolved, no phantom tags",
              afterRefusedSave.pendingTagGroup?.id == "gCard"
              && !afterRefusedSave.resolvedGroupIds.contains("gCard")
              && afterRefusedSave.macTags["gCard"] == nil)

        // (b) Retry with the real writer: resolved, told once, and the disk already agreed at that moment.
        session.manifestWriteOverride = nil
        let retriedSave = session.applyMacTags(groupId: "gCard", subjects: ["oral history"],
                                               quality: 2, year: 1971, month: 4)
        check("W23.m7: the retry resolves the card once the write succeeds",
              retriedSave && session.pendingTagGroup == nil
              && session.macTags["gCard"]?.subjects == ["oral history"]
              && session.macTags["gCard"]?.quality == 2)
        let taggedHandoff = session.orderedFilesAndGroups()
        let cardHandoffIndex = taggedHandoff.files.firstIndex { $0.lastPathComponent == "00102-gCard.jpg" }
        check("W19.q7: a Mac Quality choice overrides the phone's Q3 before Process Files handoff",
              cardHandoffIndex.map { taggedHandoff.qualities[$0] == "Q2" } == true)
        check("W23.m7: live processing is told exactly once, and only for the durable decision",
              notified == ["gCard"])
        check("W23.m7: at the moment live processing was told, the decision was ALREADY on disk",
              durableOnDiskWhenNotified["gCard"] == true)

        // Skip is a decision too: same contract (a relaunch must not re-ask for an already-produced segment).
        let skipPhoto = session.ingest(jpeg: Data("synthetic skip page".utf8), groupId: "gSkip", seq: 103,
                                       type: .document, quality: nil, year: nil, month: nil,
                                       deviceName: "ManifestTest")
        check("W23.m7: a page for the skip-card group ingests + completes",
              skipPhoto != nil
              && session.markSegmentComplete(groupId: "gSkip", quality: nil, year: nil, month: nil)
              && session.pendingTagGroup?.id == "gSkip")
        session.manifestWriteOverride = { _, _ in false }
        session.statusMessage = "Listening"
        let refusedSkip = session.skipMacTags(groupId: "gSkip")
        check("W23.m7: a failed manifest write refuses the Skip too", !refusedSkip)
        check("W23.m7: a refused Skip rolls back, keeps the card, tells the operator, acts on nothing",
              !session.resolvedGroupIds.contains("gSkip")
              && session.pendingTagGroup?.id == "gSkip"
              && session.statusMessage == CaptureSession.tagDecisionNotDurableMessage
              && notified == ["gCard"])
        session.manifestWriteOverride = nil
        let retriedSkip = session.skipMacTags(groupId: "gSkip")
        check("W23.m7: the Skip retry resolves the card and is told only after the write",
              retriedSkip && session.pendingTagGroup == nil
              && notified == ["gCard", "gSkip"]
              && durableOnDiskWhenNotified["gSkip"] == true)
        session.resolvedNotifyHookForTest = nil
        let afterDurableDecisions = CaptureSession()
        check("W23.m7: both durable decisions survive a fresh session restore (no card re-asked)",
              afterDurableDecisions.pendingTagGroup == nil
              && afterDurableDecisions.resolvedGroupIds.isSuperset(of: ["gCard", "gSkip"])
              && afterDurableDecisions.macTags["gCard"]?.year == 1971
              && afterDurableDecisions.macTags["gCard"]?.quality == 2
              && afterDurableDecisions.macTags["gSkip"] == nil)

        // --- B17: LAN request admission happens from a bounded head before body accumulation. ---
        let serverToken = "test-token"
        func requestPrefix(
            method: String = "POST",
            path: String = "/photo",
            authorization: String = "Bearer test-token",
            contentLength: String,
            extraHeaders: [String] = [],
            bodyPrefix: Data = Data()
        ) -> Data {
            var lines = [
                "\(method) \(path) HTTP/1.1",
                "Authorization: \(authorization)",
                "Content-Length: \(contentLength)",
            ]
            lines.append(contentsOf: extraHeaders)
            var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            data.append(bodyPrefix)
            return data
        }
        check("B17: unauthenticated large upload is rejected from headers before size/body admission",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    authorization: "Bearer wrong", contentLength: "\(CaptureServer.maxPhotoBodyBytes)"),
                token: serverToken) == "unauthorized")
        check("B17: authenticated photo above the per-route cap is rejected",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "\(CaptureServer.maxPhotoBodyBytes + 1)"),
                token: serverToken) == "tooLarge")
        check("B17: control routes have a much smaller body cap",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    path: "/session/complete",
                    contentLength: "\(CaptureServer.maxControlBodyBytes + 1)"),
                token: serverToken) == "tooLarge")
        check("B17: authenticated body is refused when aggregate reservation is unavailable",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "4096"),
                token: serverToken, aggregateAvailable: 4095) == "overloaded")
        check("B17: valid authenticated photo head is admitted without requiring its body first",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "4096"),
                token: serverToken, aggregateAvailable: 4096) == "accept")
        check("W19.q7: LAN ingress accepts only canonical Q1...Q3 Quality values",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "0", extraHeaders: ["X-Quality: Q3"]),
                token: serverToken) == "accept"
              && CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "0", extraHeaders: ["X-Quality: Q0"]),
                token: serverToken) == "invalidMetadata"
              && CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "0", extraHeaders: ["X-Quality: P10"]),
                token: serverToken) == "invalidMetadata")
        check("B17: duplicate Content-Length framing is rejected",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    contentLength: "1", extraHeaders: ["Content-Length: 1"]),
                token: serverToken) == "bad")
        check("B17: unsupported Transfer-Encoding framing is rejected",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    contentLength: "0", extraHeaders: ["Transfer-Encoding: chunked"]),
                token: serverToken) == "bad")
        check("B17: non-numeric Content-Length is rejected instead of treated as zero",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(contentLength: "not-a-number"),
                token: serverToken) == "bad")
        check("B17: an unknown authenticated route is rejected before its declared body is read",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(path: "/unknown", contentLength: "1048576"),
                token: serverToken) == "unknownRoute")
        check("B17: bytes beyond Content-Length are rejected as ambiguous pipelining",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    contentLength: "1", bodyPrefix: Data([0x01, 0x02])),
                token: serverToken) == "bad")
        check("B17: connection and aggregate caps are finite and below their multiplied worst case",
              CaptureServer.maxConcurrentConnections == 8
              && CaptureServer.maxAggregateBodyBytes
                    < CaptureServer.maxConcurrentConnections * CaptureServer.maxPhotoBodyBytes)

        // --- W16.lan2: the LAN credential is high-entropy and SPLIT from the SPEC-pinned Drive-relay token. ---
        check("W16.lan2: LAN token length is high-entropy (≥128 bits: ≥26 chars over the 31-symbol alphabet)",
              CaptureSession.lanTokenLength >= 26
              && CaptureSession.makeLANToken().count == CaptureSession.lanTokenLength)
        check("W16.lan2: two freshly minted LAN tokens differ (drawn from a random source, not a constant)",
              CaptureSession.makeLANToken() != CaptureSession.makeLANToken())
        let lanSplitSession = CaptureSession()
        check("W16.lan2: LAN token is split from — and longer than — the 6-char Drive-relay token",
              lanSplitSession.lanToken != lanSplitSession.token
              && lanSplitSession.lanToken.count >= CaptureSession.lanTokenLength)
        check("W16.lan2: the Drive-relay token keeps its stable 6-char SPEC-pinned format (untouched)",
              lanSplitSession.token.count == 6)
        let lanServer = CaptureServer(session: lanSplitSession)
        check("W16.lan2: the LAN receiver authenticates the high-entropy lanToken, not the Drive-relay token",
              lanServer._testActiveToken == lanSplitSession.lanToken
              && lanServer._testActiveToken != lanSplitSession.token)
        check("W16.lan2: a request bearing the OLD 6-char Drive-relay token is rejected on the LAN path",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    authorization: "Bearer \(lanSplitSession.token)", contentLength: "1024"),
                token: lanServer._testActiveToken) == "unauthorized")
        check("W16.lan2: a request bearing the lanToken is admitted on the LAN path",
              CaptureServer._testAdmission(
                requestPrefix: requestPrefix(
                    authorization: "Bearer \(lanSplitSession.lanToken)", contentLength: "1024"),
                token: lanServer._testActiveToken, aggregateAvailable: 4096) == "accept")

        // --- W16.lan2: per-source failed-auth throttle bounds online token guessing. ---
        var throttle = CaptureServer.AuthThrottle()
        let src = "v4:10.0.0.5"
        check("W16.lan2 throttle: a fresh source is not throttled", !throttle.isThrottled(src, now: 0))
        for _ in 0..<CaptureServer.AuthThrottle.freeAttempts { throttle.recordFailure(src, now: 0) }
        check("W16.lan2 throttle: still open at exactly the free-attempt threshold",
              !throttle.isThrottled(src, now: 0))
        throttle.recordFailure(src, now: 0)   // one past the threshold → exponential backoff armed
        check("W16.lan2 throttle: blocked inside the backoff window after exceeding the threshold",
              throttle.isThrottled(src, now: 1))
        check("W16.lan2 throttle: a distinct source is unaffected by another's failures",
              !throttle.isThrottled("v4:10.0.0.6", now: 1))
        check("W16.lan2 throttle: recovers once the backoff window elapses",
              !throttle.isThrottled(src, now: 1000))
        var throttle2 = CaptureServer.AuthThrottle()   // a valid auth clears an ACTIVE block (QR re-scan recovery)
        for _ in 0...CaptureServer.AuthThrottle.freeAttempts { throttle2.recordFailure(src, now: 0) }
        check("W16.lan2 throttle: a source is blocked before the successful auth", throttle2.isThrottled(src, now: 1))
        throttle2.recordSuccess(src)
        check("W16.lan2 throttle: an authenticated request clears the source's streak immediately",
              !throttle2.isThrottled(src, now: 1))
        var unknownThrottle = CaptureServer.AuthThrottle()
        for _ in 0..<20 { unknownThrottle.recordFailure("unknown", now: 0) }
        check("W16.lan2 throttle: an undeterminable source fails open (a real phone is never locked out)",
              !unknownThrottle.isThrottled("unknown", now: 1))

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["LIVECAPTURE_MANIFESTTEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APManifestTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("MANIFESTTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
