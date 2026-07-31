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

        // --- B8: Live Capture must not read or write Process Files' mutable run statics. ---
        // Activate an empty live session under deliberately conflicting globals. Activation used to
        // overwrite all three, and later Process Files writes could change Live Capture mid-session.
        let originalRotation = OCRProcessor.rotationModeForRun
        let originalStandardImageMB = OCRProcessor.standardImageMB
        let originalOCRWorkerCount = OCRProcessor.ocrWorkerCount
        let originalPDFImageMB = OCRProcessor.pdfImageMB
        let originalTextColumns = OCRProcessor.textColumns
        let originalExportedImageMB = OCRProcessor.exportedImageMB
        let originalStampUnread = MacOSTagger.stampUnread
        defer {
            OCRProcessor.rotationModeForRun = originalRotation
            OCRProcessor.standardImageMB = originalStandardImageMB
            OCRProcessor.ocrWorkerCount = originalOCRWorkerCount
            OCRProcessor.pdfImageMB = originalPDFImageMB
            OCRProcessor.textColumns = originalTextColumns
            OCRProcessor.exportedImageMB = originalExportedImageMB
            MacOSTagger.stampUnread = originalStampUnread
        }
        OCRProcessor.rotationModeForRun = .off
        OCRProcessor.standardImageMB = 19
        MacOSTagger.stampUnread = false
        let liveIsolationSession = CaptureSession()
        let liveProvider = LLMProvider.gemini
        let liveConfig = SessionProcessingConfig(
            provider: liveProvider, model: liveProvider.models[0], thinkingLevel: .low, apiKey: "",
            taggingMode: .automatic, rotationMode: .llmSingle, mergeDocuments: false,
            outputDirectory: tmp, contextCharCount: 200, sendPreviousImage: false,
            customOCRPrompt: "", imageScale: 1, standardImageMB: 0.5,
            enableSegmentJSON: true, tagVocabulary: [], gateway: nil,
            outputImageFile: true, pdfImageMB: 2, exportedImageMB: 3, textColumns: 1)
        liveIsolationSession.beginLiveSession(config: liveConfig)
        check("B8: Live Capture activation does not mutate Process Files rotation/size/tag globals",
              OCRProcessor.rotationModeForRun == .off
              && OCRProcessor.standardImageMB == 19
              && !MacOSTagger.stampUnread)

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

        // --- W16.cfg2: injected scheduling/PDF settings win; nil retains the migration fallback. ---
        OCRProcessor.ocrWorkerCount = 2
        OCRProcessor.pdfImageMB = 3
        OCRProcessor.textColumns = 1
        let fallbackPDF = OCRProcessor.pdfGenerationSettings(for: nil)
        check("W16.cfg2: nil config retains worker/PDF static fallbacks for resume migration",
              OCRProcessor.schedulingWorkerCount(for: nil) == 2
              && fallbackPDF.imageMB == 3
              && fallbackPDF.textColumns == 1)
        var injectedConfig = processFilesConfig
        injectedConfig.standardImageMB = 7
        injectedConfig.ocrWorkerCount = 9
        injectedConfig.pdfImageMB = 8
        injectedConfig.textColumns = 3
        injectedConfig.exportedImageMB = 6
        let injectedPDF = OCRProcessor.pdfGenerationSettings(for: injectedConfig)
        check("W16.cfg2: immutable config overrides conflicting worker/PDF statics",
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
        OCRProcessor.exportedImageMB = 11
        let fallbackLateSettings = lateStageProcessor.lateRunOutputSettings(for: nil)
        check("W16.cfg3: nil config preserves late-stage fallback until resume migration",
              fallbackLateSettings.pdfImageMB == 3
              && fallbackLateSettings.textColumns == 1
              && fallbackLateSettings.exportedImageMB == 11
              && !fallbackLateSettings.stampUnread
              && fallbackLateSettings.taggingMode == .none
              && fallbackLateSettings.mergeDocuments
              && !fallbackLateSettings.exportOriginals)

        let sizedInput = tmp.appendingPathComponent("b8-one-megabyte.jpg")
        try? Data(repeating: 0x42, count: 1_000_000).write(to: sizedInput)
        let explicitScale = OCRProcessor.targetDimensionScale(
            forFileAt: sizedInput, sizeFraction: 1, standardImageMB: 0.5)
        let globalScale = OCRProcessor.targetDimensionScale(forFileAt: sizedInput, sizeFraction: 1)
        check("B8: explicit Live Capture size snapshot wins over conflicting Process Files global",
              abs(explicitScale - 0.5.squareRoot()) < 0.0001 && globalScale == 1)

        let explicitlyStamped = tmp.appendingPathComponent("b8-explicit-stamp.txt")
        let explicitlyPlain = tmp.appendingPathComponent("b8-explicit-plain.txt")
        try? Data("stamp".utf8).write(to: explicitlyStamped)
        try? Data("plain".utf8).write(to: explicitlyPlain)
        _ = try? MacOSTagger.applyTags(["Subject"], to: explicitlyStamped, stampUnread: true)
        MacOSTagger.stampUnread = true
        _ = try? MacOSTagger.applyTags(["Subject"], to: explicitlyPlain, stampUnread: false)
        let stampedTags = try? MacOSTagger.readTags(from: explicitlyStamped)
        let plainTags = try? MacOSTagger.readTags(from: explicitlyPlain)
        check("B8: explicit Live Capture tag policy wins over conflicting Process Files global",
              stampedTags?.last == "Unread" && plainTags == ["Subject"])
        MacOSTagger.stampUnread = false

        typealias Entry = CaptureSession.ManifestEntry
        let entries = [
            Entry(name: "00001-gDoc.jpg", groupId: "gDoc", seq: 1, type: "document", priority: "P8", year: 1968, month: 3),
            Entry(name: "00002-gDoc.jpg", groupId: "gDoc", seq: 2, type: "document", priority: nil, year: 1968, month: 3),
            Entry(name: "00003-gBox.jpg", groupId: "gBox", seq: 3, type: "box", priority: nil, year: nil, month: nil),
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
              && roundTrip?.entries.first?.priority == "P8"
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
            "gDoc": MacSegmentTags(subjects: ["elections", "1968 campaign"], priority: "P8", year: 1968, month: 3)
        ]
        let b9Manifest = CaptureSession.SessionManifest(photos: entries, completedDocGroups: Array(completed),
                                                        resolvedGroupIds: ["gDoc"], macTags: macTags)
        let b9Wrote = (try? JSONEncoder().encode(b9Manifest)).map { (try? $0.write(to: b9File, options: .atomic)) != nil } ?? false
        let b9 = (try? Data(contentsOf: b9File)).flatMap { CaptureSession.decodeManifest($0) }
        check("B9: manifest with resolved/macTags written + decodes", b9Wrote && b9 != nil)
        check("B9: resolvedGroupIds survives the round-trip", b9?.resolved == ["gDoc"])
        check("B9: macTags survives the round-trip (subjects + date + priority)",
              b9?.macTags["gDoc"]?.subjects == ["elections", "1968 campaign"]
              && b9?.macTags["gDoc"]?.year == 1968 && b9?.macTags["gDoc"]?.priority == "P8")
        check("B9 back-compat: pre-B9 manifest (no resolved/macTags keys) decodes to empty",
              legacy?.resolved.isEmpty == true && legacy?.macTags.isEmpty == true
              && emptyDecoded?.resolved.isEmpty == true && emptyDecoded?.macTags.isEmpty == true)

        // --- B10: segment completion is acknowledged only after the real session manifest write succeeds.
        // Inject a write failure, prove memory rolls back, then retry and prove the card becomes durable.
        let session = CaptureSession()
        session.beginStageSessionForTest()   // never inherit live-processing defaults / launch OCR or network
        let ingested = session.ingest(jpeg: Data("synthetic page".utf8), groupId: "gDurable", seq: 99,
                                      type: .document, priority: nil, year: nil, month: nil,
                                      deviceName: "ManifestTest")
        check("B10: synthetic page ingests before completion test", ingested != nil)
        session.manifestWriteOverride = { _, _ in false }
        let failedCompletion = session.markSegmentComplete(
            groupId: "gDurable", priority: "P8", year: 1972, month: 6)
        check("B10: manifest failure refuses completion acknowledgement", !failedCompletion)
        check("B10: manifest failure rolls completion/card state back", session.pendingTagGroup == nil)
        check("B10: manifest failure rolls photo metadata back",
              session.photos.first(where: { $0.groupId == "gDurable" })?.year == nil
              && session.photos.first(where: { $0.groupId == "gDurable" })?.priority == nil)
        session.manifestWriteOverride = nil
        let retriedCompletion = session.markSegmentComplete(
            groupId: "gDurable", priority: "P8", year: 1972, month: 6)
        check("B10: retry acknowledges after durable manifest write", retriedCompletion)
        check("B10: successful retry exposes the completed tag card with metadata",
              session.pendingTagGroup?.id == "gDurable"
              && session.photos.first(where: { $0.groupId == "gDurable" })?.year == 1972
              && session.photos.first(where: { $0.groupId == "gDurable" })?.priority == "P8")

        let sessionPhoto = session.ingest(jpeg: Data("synthetic final page".utf8), groupId: "gSession",
                                          seq: 100, type: .document, priority: nil, year: nil, month: nil,
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
                                       seq: 101, type: .document, priority: nil, year: nil, month: nil,
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
              && restoredSession.photos.first(where: { $0.groupId == "gDurable" })?.priority == "P8")

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
                                       type: .document, priority: nil, year: nil, month: nil,
                                       deviceName: "ManifestTest")
        check("W23.m7: a page for the tag-card group ingests", cardPhoto != nil)
        check("W23.m7: its segment completes and surfaces exactly one card",
              session.markSegmentComplete(groupId: "gCard", priority: nil, year: nil, month: nil)
              && session.pendingTagGroup?.id == "gCard")

        // (a) Save against a failing write: refused, rolled back, card kept, operator told, nothing acted on.
        var saveOfferedDecisionToDisk = false
        session.manifestWriteOverride = { data, _ in
            let offered = CaptureSession.decodeManifest(data)
            saveOfferedDecisionToDisk = offered?.resolved.contains("gCard") == true
                && offered?.macTags["gCard"]?.subjects == ["oral history"]
                && offered?.macTags["gCard"]?.year == 1971
            return false
        }
        session.statusMessage = "Listening"
        let refusedSave = session.applyMacTags(groupId: "gCard", subjects: ["oral history"],
                                               priority: "P8", year: 1971, month: 4)
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
                                               priority: "P8", year: 1971, month: 4)
        check("W23.m7: the retry resolves the card once the write succeeds",
              retriedSave && session.pendingTagGroup == nil
              && session.macTags["gCard"]?.subjects == ["oral history"])
        check("W23.m7: live processing is told exactly once, and only for the durable decision",
              notified == ["gCard"])
        check("W23.m7: at the moment live processing was told, the decision was ALREADY on disk",
              durableOnDiskWhenNotified["gCard"] == true)

        // Skip is a decision too: same contract (a relaunch must not re-ask for an already-produced segment).
        let skipPhoto = session.ingest(jpeg: Data("synthetic skip page".utf8), groupId: "gSkip", seq: 103,
                                       type: .document, priority: nil, year: nil, month: nil,
                                       deviceName: "ManifestTest")
        check("W23.m7: a page for the skip-card group ingests + completes",
              skipPhoto != nil
              && session.markSegmentComplete(groupId: "gSkip", priority: nil, year: nil, month: nil)
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
              && afterDurableDecisions.macTags["gCard"]?.priority == "P8"
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
