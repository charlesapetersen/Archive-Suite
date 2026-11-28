import Foundation
import UserNotifications
import CryptoKit
import ArchiveCore

extension OCRProcessor {
    // MARK: - Batch/run resume identity (crash-resume, Tier-2)

    /// Legacy batch/pre-v2 content fingerprint — the input set + destination + the
    /// settings that change what lands on disk. Two runs with the same fingerprint are the SAME job, so
    /// a persisted manifest may be resumed into the current context; a different fingerprint means a
    /// different input set / output / settings and MUST NOT be misapplied (Tier-2 rule e). Order-stable
    /// (inputs are sorted) so re-adding the same files in a different order still matches. New non-batch
    /// manifests use `pendingRunFingerprintV2`, which is deliberately order-sensitive and covers their
    /// complete immutable runtime snapshot and evolving completion state.
    nonisolated static func runFingerprint(
        files: [URL], outputDirectory: URL, taggingMode: TaggingMode?,
        enableTagging: Bool, batchMode: Bool, preserveInputOrder: Bool = false
    ) -> String {
        let rawPaths = files.map { $0.standardizedFileURL.path }
        let paths = preserveInputOrder ? rawPaths : rawPaths.sorted()
        let canonical = ([
            "out=" + outputDirectory.standardizedFileURL.path,
            "mode=" + (taggingMode?.rawValue ?? "-"),
            "tag=" + (enableTagging ? "1" : "0"),
            "batch=" + (batchMode ? "1" : "0"),
            "n=\(paths.count)"
        ] + paths).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical v2 identity for a standard Process Files run. Unlike the legacy fingerprint above,
    /// input order is significant because `completedResults` and `completedOutputPaths` are keyed by
    /// file index. It also covers every persisted run argument/backend and the complete runtime snapshot,
    /// so a valid-JSON manifest with any identity field changed fails closed instead of combining cached
    /// results with different settings.
    private struct PendingRunIdentityV2: Encodable {
        let formatVersion = 2
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let orderedFilePaths: [String]
        let outputDirectoryPath: String
        let enableTagging: Bool
        let enableSegmentJSON: Bool
        let enableCollectionSegmentation: Bool
        let confirmCollectionIDs: Bool
        let reviewDocumentSegmentation: Bool
        let preOCRedInput: Bool
        let previousTextCharCount: Int
        let sendPreviousImage: Bool
        let customPrompt: String?
        let startedAt: Date
        let gatewayConfig: GatewayConfig?
        let localAgent: LocalAgentConfig?
        let legacyExportOriginals: Bool?
        let runtimeConfig: PendingRunSnapshot
        let completedResults: [String: OCRResult]
        let completedOutputPaths: [String: String]?
        let mixedPDFOutcomes: [MixedPDFOutcome]?

        init(run: PendingRun, runtimeConfig: PendingRunSnapshot) {
            provider = run.provider
            model = run.model
            thinkingLevel = run.thinkingLevel
            orderedFilePaths = run.fileURLs.map { $0.standardizedFileURL.path }
            outputDirectoryPath = run.outputDirectory.standardizedFileURL.path
            enableTagging = run.enableTagging
            enableSegmentJSON = run.enableSegmentJSON
            enableCollectionSegmentation = run.enableCollectionSegmentation
            confirmCollectionIDs = run.confirmCollectionIDs
            reviewDocumentSegmentation = run.reviewDocumentSegmentation
            preOCRedInput = run.preOCRedInput
            previousTextCharCount = run.previousTextCharCount
            sendPreviousImage = run.sendPreviousImage
            customPrompt = run.customPrompt
            startedAt = run.startedAt
            gatewayConfig = run.gatewayConfig
            localAgent = run.localAgent
            legacyExportOriginals = run.exportOriginals
            self.runtimeConfig = runtimeConfig
            completedResults = run.completedResults
            completedOutputPaths = run.completedOutputPaths
            mixedPDFOutcomes = run.mixedPDFOutcomes
        }
    }

    /// Compute the v2 identity hash. Nil means the snapshot could not be encoded; callers must not start
    /// a resumable paid run in that state.
    /// W46.settings-layers: a started run's collection record, written once by `recordActiveRunInCollection`.
    struct PendingCollectionRecord {
        let snapshot: ResolvedSettingsSnapshot
        let outputDirectory: URL
        let fileCount: Int
    }

    /// Record the run in its collection's folder, once per start; a second call (the image half of a mixed run) does
    /// nothing. A record that cannot be written never stops the run (`SettingsLayerStore.record`).
    func recordActiveRunInCollection(kind: String) {
        guard let pending = activeRunToRecord else { return }
        activeRunToRecord = nil
        SettingsLayerStore.shared.record(pending.snapshot, kind: kind, fileCount: pending.fileCount,
                                         in: pending.outputDirectory)
    }

    nonisolated static func pendingRunFingerprintV2(_ run: PendingRun) -> String? {
        guard let config = run.runtimeConfig else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(PendingRunIdentityV2(run: run, runtimeConfig: config)) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical identity for the evolving paid-batch lifecycle journal. The original batch
    /// `runFingerprint` intentionally remains unchanged for backward compatibility; this additive hash
    /// covers every persisted setting plus the ordered server IDs and per-file completion associations.
    private struct PendingBatchLifecycleIdentityV1: Encodable {
        let formatVersion = 1
        let batchId: String
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let orderedFilePaths: [String]
        let outputDirectoryPath: String
        let enableTagging: Bool
        let enableCollectionSegmentation: Bool
        let sendPreviousImage: Bool
        let submittedAt: Date
        let enableSegmentJSON: Bool
        let confirmCollectionIDs: Bool
        let reviewDocumentSegmentation: Bool
        let customPrompt: String?
        let taggingMode: TaggingMode
        let fingerprintVersion: Int?
        let runFingerprint: String?
        let exportOriginals: Bool?
        let submittedChunkIds: [String]
        let consumedChunkIds: [String]
        let submissionComplete: Bool
        let completedResults: [String: OCRResult]
        let completedOutputPaths: [String: String]?
        let mixedPDFOutcomes: [MixedPDFOutcome]?
        let newspaperManifest: NewspaperBatch.Manifest?
        let newspaperParts: [String: OCRResult]?
        let outputSubfolders: [String: String]?

        let segmentationApproach: SegmentationApproach?
        let segmentationPartner: SegmentationApproach?
        let segmentationWindows: [AnsweredWindow]?
        let segmentationAnswers: [String: SavedGapAnswer]?
        let enclosureCovers: [String: String]?
        let resultsCollected: Bool?
        let paidRequestLinks: [String: UUID]?

        struct AnsweredWindow: Encodable {
            let key: WindowKey
            let answer: WindowAnswer
        }

        init(batch: PendingBatch) {
            batchId = batch.batchId
            provider = batch.provider
            model = batch.model
            thinkingLevel = batch.thinkingLevel
            orderedFilePaths = batch.fileURLs.map { $0.standardizedFileURL.path }
            outputDirectoryPath = batch.outputDirectory.standardizedFileURL.path
            enableTagging = batch.enableTagging
            enableCollectionSegmentation = batch.enableCollectionSegmentation
            sendPreviousImage = batch.sendPreviousImage
            submittedAt = batch.submittedAt
            enableSegmentJSON = batch.enableSegmentJSON
            confirmCollectionIDs = batch.confirmCollectionIDs
            reviewDocumentSegmentation = batch.reviewDocumentSegmentation
            customPrompt = batch.customPrompt
            taggingMode = batch.taggingMode
            fingerprintVersion = batch.fingerprintVersion
            runFingerprint = batch.runFingerprint
            exportOriginals = batch.exportOriginals
            submittedChunkIds = batch.submittedChunkIds
            consumedChunkIds = batch.consumedChunkIds.sorted()
            submissionComplete = batch.submissionComplete
            completedResults = batch.completedResults
            completedOutputPaths = batch.completedOutputPaths
            mixedPDFOutcomes = batch.mixedPDFOutcomes
            newspaperManifest = batch.newspaperManifest
            newspaperParts = batch.newspaperParts
            outputSubfolders = batch.outputSubfolders
            segmentationApproach = batch.segmentationApproach
            segmentationPartner = batch.segmentationPartner
            // Codable encodes a dictionary with struct keys as an unordered array of key/value pairs.
            segmentationWindows = batch.segmentationWindows?.map { AnsweredWindow(key: $0.key, answer: $0.value) }
                .sorted { ($0.key.voter, $0.key.pages, $0.key.start, $0.key.end) <
                          ($1.key.voter, $1.key.pages, $1.key.start, $1.key.end) }
            segmentationAnswers = batch.segmentationAnswers
            enclosureCovers = batch.enclosureCovers
            resultsCollected = batch.resultsCollected
            paidRequestLinks = batch.paidRequestLinks
        }
    }

    nonisolated static func pendingBatchLifecycleFingerprint(_ batch: PendingBatch) -> String? {
        guard batch.lifecycleVersion == PendingBatch.currentLifecycleVersion else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(PendingBatchLifecycleIdentityV1(batch: batch)) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Return a copy ready for an atomic write. Callers only publish this copy in memory after the disk
    /// replacement succeeds, so a failed save cannot move the process ahead of its durable journal.
    nonisolated static func preparedPendingBatchForPersistence(_ batch: PendingBatch) -> PendingBatch? {
        var prepared = batch
        if prepared.lifecycleVersion != nil {
            guard prepared.lifecycleVersion == PendingBatch.currentLifecycleVersion else { return nil }
            prepared.batchId = prepared.submittedChunkIds.joined(separator: ",")
            guard let fingerprint = pendingBatchLifecycleFingerprint(prepared) else { return nil }
            prepared.lifecycleFingerprint = fingerprint
        }
        return prepared
    }

    /// Re-open consumed chunks when one of their materialized PDFs disappeared after the journal write.
    /// The injected existence probe keeps the recovery policy deterministic and headless-testable.
    nonisolated static func batchByReopeningMissingOutputs(
        _ batch: PendingBatch,
        fileExists: (String) -> Bool
    ) -> PendingBatch {
        guard batch.lifecycleVersion == PendingBatch.currentLifecycleVersion else { return batch }
        var repaired = batch
        let missingKeys = repaired.completedOutputPaths?.compactMap { key, path in
            fileExists(path) ? nil : key
        } ?? []
        guard !missingKeys.isEmpty else { return batch }
        for key in missingKeys {
            repaired.completedResults.removeValue(forKey: key)
            repaired.completedOutputPaths?.removeValue(forKey: key)
        }
        // Chunk→file ranges are provider-owned and legacy Gemini IDs are string-only, so conservatively
        // re-fetch every consumed chunk. processBatchResults skips still-present per-file keys.
        repaired.consumedChunkIds = []
        repaired.resultsCollected = nil
        repaired.lifecycleFingerprint = nil
        return repaired
    }

    /// Structural validation is separate from the fingerprint. A locally-edited manifest could carry a
    /// freshly recomputed hash, so bound every value before it can control concurrency/sizing and require
    /// all Live Capture parallel arrays to be either absent or aligned with the ordered input list.
    nonisolated static func pendingRunSnapshotIsValid(
        _ config: PendingRunSnapshot,
        fileCount: Int,
        enableTagging: Bool,
        hasGateway: Bool
    ) -> Bool {
        guard config.schemaVersion == PendingRunSnapshot.currentSchemaVersion,
              enableTagging == config.taggingMode.enablesTagging,
              config.imageScale.isFinite, (0.01...1.0).contains(config.imageScale),
              // W16.cfg6-fu3: the same `Bounds` the clamps and the Settings steppers use, so this
              // fail-closed validator cannot drift *stricter* than what a builder can produce — which is
              // the direction that would strand a resumable paid run. It can still be looser: the Text
              // columns control is a 1/2/3 Picker, so a persisted 4 is admitted here (and rendered fine
              // by `PDFGenerator`) even though no control can produce it.
              config.standardImageMB.isFinite,
              SessionProcessingConfig.Bounds.imageMB.contains(config.standardImageMB),
              SessionProcessingConfig.Bounds.ocrWorkers.contains(config.ocrWorkerCount),
              config.pdfImageMB.isFinite,
              SessionProcessingConfig.Bounds.imageMB.contains(config.pdfImageMB),
              SessionProcessingConfig.Bounds.textColumns.contains(config.textColumns),
              config.exportedImageMB.isFinite,
              SessionProcessingConfig.Bounds.imageMB.contains(config.exportedImageMB),
              config.visionSettings.isValid,
              hasGateway == (config.gatewayUpstreamProvider != nil) else { return false }

        // The three hybrid fields are an all-or-none direct provider snapshot. A Vision OCR run must
        // never resume halfway configured and quietly fall back to sending an image through another
        // backend; the only permitted fallback is no hybrid at all.
        if config.dateLocalImage {
            guard config.taggingMode == .autoDate, config.segmentationApproach == .manual,
                  config.visionText == nil, !hasGateway, !config.postCorrection else { return false }
        }
        if let text = config.visionText {
            guard text.provider != .appleVision, text.model.provider == text.provider else { return false }
        }

        let optionalParallelCounts = [
            config.preGroupedQualities.count,
            config.preGroupedYears.count,
            config.preGroupedMonths.count,
            config.preGroupedSubjects.count,
        ]
        if config.preGroupedBoundaries.isEmpty {
            return config.preGroupedTypes.isEmpty && optionalParallelCounts.allSatisfy { $0 == 0 }
        }
        return config.preGroupedBoundaries.count == fileCount
            && config.preGroupedTypes.count == fileCount
            && optionalParallelCounts.allSatisfy { $0 == 0 || $0 == fileCount }
    }

    /// Capture the effective runtime values used by this run: the run's own `ResolvedRunConfig`, with the values the
    /// controller holds for it (tagging, rotation, merge, vocabulary, the second image file) and the scale the run
    /// priced. With no config, W16.cfg6 persists a fresh defaults read rather than the deleted statics, so a manifest
    /// can never record sizing values inherited from an unrelated earlier run.
    func makePendingRunSnapshot(
        imageScale: Double,
        gatewayConfig: GatewayConfig?,
        runConfig: SessionProcessingConfig? = nil
    ) -> PendingRunSnapshot {
        var config = runConfig?.config ?? {
            var read = ResolvedRunConfig.fromDefaults()
            // Without a run's own config there is no text model or local date pass to record.
            read.visionText = nil
            read.dateLocalImage = false
            return read
        }()
        config.taggingMode = taggingMode
        config.rotationMode = rotationMode
        config.reviewRotation = reviewRotation
        config.mergeDocuments = mergeDocuments
        config.tagVocabulary = tagVocabulary
        config.imageScale = imageScale.isFinite ? max(0.01, min(1.0, imageScale)) : 1.0
        config.outputImageFile = exportOriginals
        config.gatewayUpstreamProvider = gatewayConfig == nil ? nil : Self.gatewayUpstreamProviderFromDefaults()
        config.postCorrection = activePostCorrection != nil
        return PendingRunSnapshot(
            schemaVersion: PendingRunSnapshot.currentSchemaVersion,
            config: config,
            preGroupedBoundaries: preGroupedBoundaries,
            preGroupedTypes: preGroupedTypes,
            preGroupedQualities: preGroupedQualities,
            preGroupedYears: preGroupedYears,
            preGroupedMonths: preGroupedMonths,
            preGroupedSubjects: preGroupedSubjects,
            pageReaders: runConfig.map { $0.pageReaders.isEmpty ? nil : $0.pageReaders } ?? nil,
            institutionalComputeFolder: runConfig?.institutionalComputeImport?.folder.path,
            outputSubfolders: outputSubfolders.isEmpty ? nil : outputSubfolders
        )
    }

    /// Build the single run config used by a resumed non-batch run. A v2 manifest runs on its frozen config whole,
    /// with the backend and destination of the pending record; a legacy manifest has no such snapshot, so it
    /// intentionally keeps the historical current-default fallback while restoring the identity fields it did persist.
    func makePendingRunResumeConfig(
        _ pending: PendingRun,
        apiKey: String,
        defaults: UserDefaults = .standard
    ) -> SessionProcessingConfig {
        var runConfig = SessionProcessingConfig.fromProcessFilesRunStart(defaults)
        runConfig.provider = pending.provider
        runConfig.model = pending.model
        runConfig.thinkingLevel = pending.thinkingLevel ?? .low
        runConfig.apiKey = apiKey
        runConfig.outputDirectory = pending.outputDirectory
        runConfig.customOCRPrompt = pending.customPrompt ?? ""
        runConfig.enableSegmentJSON = pending.enableSegmentJSON
        runConfig.gateway = pending.gatewayConfig
        runConfig.localAgent = pending.localAgent

        if let runtime = pending.runtimeConfig {
            runConfig.config = runtime.config.resumed(identity: runConfig.config)
            runConfig.pageReaders = runtime.pageReaders ?? .empty
            // Credentials never enter the pending-run manifest. Resume with the key for the snapshotted text
            // backend, not whichever backend happens to be selected now, and never another provider's key.
            runConfig.credentials.visionTextAPIKey = runConfig.visionText.map {
                KeychainHelper.load(account: $0.provider.rawValue) ?? ""
            } ?? ""
        } else {
            runConfig.imageScale = Self.liveImageScaleFraction(defaults)
            if let exportOriginals = pending.exportOriginals {
                runConfig.outputImageFile = exportOriginals
            }
        }
        return runConfig
    }

    /// Paid-batch manifests predate the complete runtime snapshot. Rebuild their run config from current
    /// defaults, then overlay every identity/output value the legacy format does persist.
    func makePendingBatchResumeConfig(
        _ pending: PendingBatch,
        apiKey: String,
        defaults: UserDefaults = .standard
    ) -> SessionProcessingConfig {
        var runConfig = SessionProcessingConfig.fromProcessFilesRunStart(defaults)
        runConfig.provider = pending.provider
        runConfig.model = pending.model
        runConfig.thinkingLevel = pending.thinkingLevel ?? .low
        runConfig.apiKey = apiKey
        runConfig.taggingMode = pending.taggingMode
        runConfig.outputDirectory = pending.outputDirectory
        runConfig.customOCRPrompt = pending.customPrompt ?? ""
        runConfig.imageScale = Self.liveImageScaleFraction(defaults)
        runConfig.enableSegmentJSON = pending.enableSegmentJSON
        runConfig.gateway = nil
        runConfig.localAgent = nil
        runConfig.segmentationApproach = pending.segmentationApproach ?? .manual
        // The cascade the batch was submitted with (W41.app-ocr-cascade); a journal without one escalates nothing.
        runConfig.cascade = pending.cascade ?? .off
        if let exportOriginals = pending.exportOriginals {
            runConfig.outputImageFile = exportOriginals
        }
        return runConfig
    }

    /// Mirror a constructed legacy resume config onto the MainActor-owned controller state used by the
    /// remaining UI/review code. The run's actual OCR/output consumers receive the config explicitly.
    func applyResumeConfig(_ runConfig: SessionProcessingConfig) {
        taggingMode = runConfig.taggingMode
        passSourceTags = runConfig.taggingMode == .copySource
        rotationMode = runConfig.rotationMode
        mergeDocuments = runConfig.mergeDocuments
        tagVocabulary = runConfig.tagVocabulary
        exportOriginals = runConfig.outputImageFile
        // S-060: a legacy/paid-batch resume has no phone hand-off snapshot; never inherit stale Live Capture arrays.
        preGroupedBoundaries = []
        preGroupedTypes = []
        preGroupedQualities = []
        preGroupedYears = []
        preGroupedMonths = []
        preGroupedSubjects = []
    }

    /// Apply exactly the instance/runtime-only values captured above. `pendingRunIsSelfConsistent`
    /// validates the snapshot before this is called; sizing, scheduling, and rotation now travel through
    /// `SessionProcessingConfig` instead of being fanned back out to process-global statics.
    func applyPendingRunSnapshot(_ config: PendingRunSnapshot) {
        taggingMode = config.taggingMode
        passSourceTags = config.passSourceTags
        rotationMode = config.rotationMode
        reviewRotation = config.reviewRotation
        mergeDocuments = config.mergeDocuments
        tagVocabulary = config.tagVocabulary
        exportOriginals = config.exportOriginals
        preGroupedBoundaries = config.preGroupedBoundaries
        preGroupedTypes = config.preGroupedTypes
        preGroupedQualities = config.preGroupedQualities
        preGroupedYears = config.preGroupedYears
        preGroupedMonths = config.preGroupedMonths
        preGroupedSubjects = config.preGroupedSubjects
    }

    /// The input file indices a resume must still process: everything NOT already in the manifest's
    /// completed set. Factored out so `resumeRun` and the headless self-test share ONE definition of
    /// "skip the done files" — the anti-double-cost guarantee (Tier-2 rule a: never re-OCR a done file).
    nonisolated static func remainingIndices(totalFiles: Int, completedResults: [String: OCRResult]) -> [Int] {
        (0..<max(0, totalFiles)).filter { completedResults["\($0)"] == nil }
    }

    /// Map each completed file index to the output-PDF URL a resume must restore it to. B7 fix: an index
    /// with a persisted assignment in `completedOutputPaths` reuses that path VERBATIM, so the source→output
    /// association recorded on disk (in COMPLETION order by the original pass) is preserved even when two
    /// sources share a base filename — re-deriving in index order would swap them and mis-tag both PDFs.
    /// An index WITHOUT a persisted path (a legacy manifest written before the map existed) falls back to
    /// the old deterministic index-order derivation, disambiguating colliding base names against
    /// `alreadyTaken` (plus paths claimed earlier in this pass). `sourceURLs` is indexed by file index.
    /// Factored out so `resumeRun` and the headless self-test exercise ONE definition (Tier-2 DRY).
    nonisolated static func resolveResumeOutputURLs(
        completedResults: [String: OCRResult],
        completedOutputPaths: [String: String]?,
        sourceURLs: [URL],
        outputDirectory: URL,
        alreadyTaken: Set<String> = []
    ) -> [Int: URL] {
        var takenOutputs = alreadyTaken
        var resolved: [Int: URL] = [:]
        for (key, _) in completedResults.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            guard let index = Int(key), index >= 0, index < sourceURLs.count else { continue }
            let sourceURL = sourceURLs[index]
            let outputURL: URL
            if let persisted = completedOutputPaths?[key] {
                // Reuse the persisted assignment VERBATIM — the path already on disk for THIS source.
                outputURL = URL(fileURLWithPath: persisted)
            } else {
                // Legacy manifest (no persisted path): re-derive deterministically in index order.
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                var candidate = outputDirectory.appendingPathComponent(baseName + ".pdf")
                var n = 2
                while takenOutputs.contains(candidate.standardizedFileURL.path.lowercased()) {
                    candidate = outputDirectory.appendingPathComponent("\(baseName) (\(n)).pdf"); n += 1
                }
                outputURL = candidate
            }
            takenOutputs.insert(outputURL.standardizedFileURL.path.lowercased())
            resolved[index] = outputURL
        }
        return resolved
    }

    /// The image list remains contiguous for OCR; these indices reconstruct the original mixed drop.
    nonisolated static func mixedInputURLs(
        images: [URL], pdfs: [MixedPDFOutcome]?
    ) -> [URL]? {
        guard let pdfs, !pdfs.isEmpty else { return images }
        let total = images.count + pdfs.count
        guard Set(pdfs.map(\.originalIndex)).count == pdfs.count,
              pdfs.allSatisfy({ (0..<total).contains($0.originalIndex) }),
              Set(images.map { $0.standardizedFileURL.path }).count == images.count,
              Set(pdfs.map { $0.sourceURL.standardizedFileURL.path }).count == pdfs.count,
              Set(images.map { $0.standardizedFileURL.path }).isDisjoint(
                with: Set(pdfs.map { $0.sourceURL.standardizedFileURL.path })) else { return nil }
        var ordered = [URL?](repeating: nil, count: total)
        for pdf in pdfs { ordered[pdf.originalIndex] = pdf.sourceURL }
        var imageIterator = images.makeIterator()
        for index in ordered.indices where ordered[index] == nil { ordered[index] = imageIterator.next() }
        return ordered.compactMap { $0 }.count == total ? ordered.compactMap { $0 } : nil
    }

    nonisolated static func mixedPDFOutcomesAreValid(
        _ pdfs: [MixedPDFOutcome]?, images: [URL], outputDirectory: URL,
        imageOutputPaths: [String]
    ) -> Bool {
        guard let pdfs else { return true }
        guard !pdfs.isEmpty, mixedInputURLs(images: images, pdfs: pdfs) != nil else { return false }
        let outputRoot = outputDirectory.standardizedFileURL.path
        let working = catalogueWorkingRun(outputRoot: outputDirectory, sources: images + pdfs.map(\.sourceURL))
        let pdfOutputPaths = pdfs.compactMap { $0.outputURL.map(OutputFileSafety.pathKey) }
        let normalizedImagePaths = imageOutputPaths.map {
            OutputFileSafety.pathKey(URL(fileURLWithPath: $0))
        }
        guard Set(pdfOutputPaths).count == pdfOutputPaths.count,
              Set(pdfOutputPaths).isDisjoint(with: Set(normalizedImagePaths)) else { return false }
        return pdfs.allSatisfy { pdf in
            guard pdf.sourceURL.pathExtension.lowercased() == "pdf",
                  pdf.succeeded == (pdf.outputURL != nil) else { return false }
            guard let output = pdf.outputURL else { return true }
            let url = output.standardizedFileURL
            return url.pathExtension.lowercased() == "pdf"
                && (url.deletingLastPathComponent().path == outputRoot || working?.contains(url) == true)
                && url.path != pdf.sourceURL.standardizedFileURL.path
        }
    }

    func captureMixedPDFOutcomes(indices: [Int]) -> [MixedPDFOutcome]? {
        var outcomes: [MixedPDFOutcome] = []
        for index in indices {
            guard jobs.indices.contains(index), let result = jobs[index].result else { return nil }
            let source = jobs[index].sourceURL
            let succeeded = jobs[index].status == .succeeded
            let output = outputURLMap[source]
            guard succeeded == (output != nil) else { return nil }
            outcomes.append(MixedPDFOutcome(originalIndex: index, sourceURL: source,
                                            result: result, succeeded: succeeded, outputURL: output,
                                            pdfLayerLogNotes: jobs[index].pdfLayerLogNotes))
        }
        return outcomes
    }

    /// Reserve the PDF paths before an image resume can create a same-stem output. A missing PDF stays
    /// failed and visible; its paid OCR cannot be safely rebuilt by the single-image PDF writer.
    func restoreMixedPDFAssociations(_ outcomes: [MixedPDFOutcome]?) {
        reOCRSourceURLs = Set((outcomes ?? []).map(\.sourceURL))
        for pdf in outcomes ?? [] {
            if let output = pdf.outputURL {
                if FileManager.default.fileExists(atPath: output.path) {
                    let working = catalogueRun.map {
                        catalogueResumeOutput(output, for: pdf.sourceURL, in: $0.outputRoot)
                    } ?? output
                    if FileManager.default.fileExists(atPath: working.path) {
                        _takenOutputPaths.insert(OutputFileSafety.pathKey(working))
                        outputURLMap[pdf.sourceURL] = working
                        continue
                    }
                }
                failedFiles[pdf.sourceURL.standardizedFileURL.path] = Self.missingRebuiltPDFFailure
            } else {
                recordFileFailure(for: pdf.sourceURL, result: pdf.result)
            }
        }
    }

    private static let missingRebuiltPDFFailure = ProcessFileFailure(
        reason: "The rebuilt PDF output is missing. Re-run this source PDF to recover it.",
        code: "pdf_output_missing")

    func restoreMixedPDFJobs(_ outcomes: [MixedPDFOutcome]?) {
        guard let outcomes, !outcomes.isEmpty else { return }
        let total = jobs.count + outcomes.count
        var ordered = [OCRJob?](repeating: nil, count: total)
        for pdf in outcomes {
            var job = OCRJob(sourceURL: pdf.sourceURL)
            if pdf.succeeded && outputURLMap[pdf.sourceURL] == nil {
                job.result = OCRResult(text: nil, classification: nil,
                    errorMessage: Self.missingRebuiltPDFFailure.reason, errorCode: Self.missingRebuiltPDFFailure.code)
                job.status = .failed
            } else {
                job.result = pdf.result
                job.classification = pdf.result.classification
                job.status = pdf.succeeded ? .succeeded : .failed
                job.pdfLayerLogNotes = pdf.pdfLayerLogNotes
            }
            ordered[pdf.originalIndex] = job
        }
        var imageIterator = jobs.makeIterator()
        for index in ordered.indices where ordered[index] == nil { ordered[index] = imageIterator.next() }
        jobs = ordered.compactMap { $0 }
    }

    /// Recompute a manifest's fingerprint from its own persisted fields before resuming work.
    nonisolated static func pendingRunIsSelfConsistent(_ run: PendingRun) -> Bool {
        if let config = run.runtimeConfig {
            let validResultKeys = run.completedResults.keys.allSatisfy { key in
                guard let index = Int(key) else { return false }
                return key == String(index) && index >= 0 && index < run.fileURLs.count
            }
            let outputPaths = run.completedOutputPaths ?? [:]
            let working = catalogueWorkingRun(outputRoot: run.outputDirectory, sources: run.fileURLs)
            let validOutputPaths = Set(outputPaths.keys) == Set(run.completedResults.keys)
                && outputPaths.allSatisfy { key, path in
                guard run.completedResults[key] != nil else { return false }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                return NSString(string: path).isAbsolutePath
                    && url.pathExtension.lowercased() == "pdf"
                    && (url.deletingLastPathComponent().path == run.outputDirectory.standardizedFileURL.path
                        || working?.contains(url) == true)
            }
            guard pendingRunSnapshotIsValid(
                config, fileCount: run.fileURLs.count, enableTagging: run.enableTagging,
                hasGateway: run.gatewayConfig != nil),
                  !run.fileURLs.isEmpty,
                  !run.preOCRedInput,
                  (0...20_000).contains(run.previousTextCharCount),
                  run.gatewayConfig == nil || run.localAgent == nil,
                  config.dateLocalImage != true || (run.provider == .appleVision && run.localAgent == nil
                    && !run.enableCollectionSegmentation),
                  run.enableCollectionSegmentation
                    || (!run.confirmCollectionIDs && !run.reviewDocumentSegmentation),
                  validResultKeys, validOutputPaths,
                  mixedPDFOutcomesAreValid(run.mixedPDFOutcomes, images: run.fileURLs,
                                           outputDirectory: run.outputDirectory,
                                           imageOutputPaths: Array(outputPaths.values)),
                  let stored = run.runFingerprint,
                  let computed = pendingRunFingerprintV2(run) else { return false }
            return stored == computed
        }
        guard run.mixedPDFOutcomes == nil else { return false } // new carrier requires the v2 fingerprint
        guard let stored = run.runFingerprint else { return true }
        return stored == runFingerprint(
            files: run.fileURLs, outputDirectory: run.outputDirectory,
            taggingMode: nil, enableTagging: run.enableTagging, batchMode: false)
    }
    nonisolated static func pendingBatchIsSelfConsistent(_ batch: PendingBatch) -> Bool {
        let immutableIdentityIsValid: Bool
        switch batch.fingerprintVersion {
        case nil:
            // Legacy on-disk batch; a missing fingerprint predates integrity tracking and must remain
            // visible so a paid server-side job is not stranded.
            if let stored = batch.runFingerprint {
                immutableIdentityIsValid = stored == runFingerprint(
                    files: batch.fileURLs, outputDirectory: batch.outputDirectory,
                    taggingMode: batch.taggingMode, enableTagging: batch.enableTagging, batchMode: true)
            } else {
                immutableIdentityIsValid = true
            }
        case 2:
            guard let stored = batch.runFingerprint else { return false }
            immutableIdentityIsValid = stored == runFingerprint(
                files: batch.fileURLs, outputDirectory: batch.outputDirectory,
                taggingMode: batch.taggingMode, enableTagging: batch.enableTagging, batchMode: true,
                preserveInputOrder: true)
        default: return false                 // unknown future identity contract
        }
        guard immutableIdentityIsValid else { return false }

        // A nil lifecycle version is the old submit-once manifest. Preserve its paid job exactly as the
        // compatibility path above did; only v1 journals are held to the stronger evolving-state contract.
        guard let lifecycleVersion = batch.lifecycleVersion else {
            return batch.mixedPDFOutcomes == nil && batch.segmentationApproach == nil
                && batch.segmentationPartner == nil && batch.segmentationWindows == nil
                && batch.segmentationAnswers == nil && batch.enclosureCovers == nil && batch.resultsCollected == nil && batch.paidRequestLinks == nil
        }
        guard lifecycleVersion == PendingBatch.currentLifecycleVersion,
              !batch.fileURLs.isEmpty,
              batch.batchId == batch.submittedChunkIds.joined(separator: ","),
              batch.submittedChunkIds.allSatisfy({ !$0.isEmpty && !$0.contains(",") }),
              Set(batch.submittedChunkIds).count == batch.submittedChunkIds.count,
              batch.consumedChunkIds.allSatisfy({ !$0.isEmpty }),
              Set(batch.consumedChunkIds).count == batch.consumedChunkIds.count,
              Set(batch.consumedChunkIds).isSubset(of: Set(batch.submittedChunkIds)),
              !batch.submissionComplete || !batch.submittedChunkIds.isEmpty else { return false }

        let resultKeysAreValid = batch.completedResults.keys.allSatisfy { key in
            guard let index = Int(key) else { return false }
            return key == String(index) && index >= 0 && index < batch.fileURLs.count
        }
        guard resultKeysAreValid else { return false }
        let outputPaths = batch.completedOutputPaths ?? [:]
        let outputRoot = batch.outputDirectory.standardizedFileURL
        let working = catalogueWorkingRun(outputRoot: outputRoot, sources: batch.fileURLs)
        let outputPathsAreValid = Set(outputPaths.keys) == Set(batch.completedResults.keys)
            && outputPaths.allSatisfy { key, path in
                guard let index = Int(key), NSString(string: path).isAbsolutePath else { return false }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.pathExtension.lowercased() == "pdf" else { return false }
                if working?.contains(url) == true { return true }
                let parent = url.deletingLastPathComponent()
                // The tree writer may fall back to the output root. Otherwise the parent must be
                // this source's exact assigned tree folder, with no link redirecting it elsewhere.
                if parent.path == outputRoot.path { return true }
                let sourcePath = batch.fileURLs[index].standardizedFileURL.path
                guard let relative = batch.outputSubfolders?[sourcePath],
                      let parts = ContainerTree.components(ofRelativePath: relative) else { return false }
                func treeFolder(under root: URL) -> URL {
                    parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                }
                return parent.path == treeFolder(under: outputRoot).path
                    && parent.resolvingSymlinksInPath().path
                        == treeFolder(under: outputRoot.resolvingSymlinksInPath()).path
            }
        guard NewspaperBatch.valid(batch.newspaperManifest, parts: batch.newspaperParts, files: batch.fileURLs.count),
              outputPathsAreValid,
              batch.paidRequestLinks?.keys.allSatisfy({ batch.submittedChunkIds.contains($0) }) ?? true,
              batch.resultsCollected != true || (batch.submissionComplete && batch.usesWindowSegmentation
                  && batch.completedResults.count == batch.fileURLs.count),
              mixedPDFOutcomesAreValid(batch.mixedPDFOutcomes, images: batch.fileURLs,
                                       outputDirectory: batch.outputDirectory,
                                       imageOutputPaths: Array(outputPaths.values)),
              let stored = batch.lifecycleFingerprint,
              let computed = pendingBatchLifecycleFingerprint(batch) else { return false }
        return stored == computed
    }

    // MARK: Headless self-test hooks ($0, no network) — see BatchResumeTestDriver
    // Write/read a manifest to an EXPLICIT url (a temp dir in tests — never the real Application Support
    // state), so the self-test exercises the real serialization + crash-safe (`.atomic`) write path
    // without disturbing a user's actual pending run.
    nonisolated static func _testWritePendingRun(_ run: PendingRun, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(run) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }
    nonisolated static func _testReadPendingRun(from url: URL) -> PendingRun? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingRun.self, from: data)
    }
    nonisolated static func _testWritePendingBatch(_ batch: PendingBatch, to url: URL) -> PendingBatch? {
        guard let prepared = preparedPendingBatchForPersistence(batch),
              let data = try? JSONEncoder().encode(prepared) else { return nil }
        do { try data.write(to: url, options: .atomic); return prepared } catch { return nil }
    }
    nonisolated static func _testReadPendingBatch(from url: URL) -> PendingBatch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingBatch.self, from: data)
    }

    /// The paid-batch recovery journal's file name. A named constant because the cancel path has to be
    /// able to say *which* durable file a confirmed cancellation may remove, and be checked on it
    /// without touching the file itself (W16.bat2-fu → `BatchCancellationJournal`).
    nonisolated static let pendingBatchFileName = "pending_batch.json"

    // MARK: The directory the two durable journals live in — and its ONE test-only override (W16.bat2-fu2)

    /// Environment variable naming a test-only base directory for `pending_batch.json` / `pending_run.json`,
    /// on the same pattern as `ARCHIVEPROC_TEST_BACKUP_ROOT` — but gated twice, not once
    /// (see `pendingStateDirectory`).
    nonisolated static let pendingStateTestRootEnvKey = "ARCHIVEPROC_TEST_STATE_ROOT"
    /// The headless batch-resume driver's own gate. The override above is honoured ONLY when this variable
    /// reads exactly `"1"` — the same string `BatchResumeTestDriver.runIfRequested()` demands before it runs
    /// at all, so the redirect cannot outlive the driver that needs it.
    nonisolated static let batchResumeTestEnvKey = "BATCHRESUME_TEST"

    /// The REAL, operator-facing state directory: `<Application Support>/ArchiveProcessor`. Computed in
    /// exactly one place so the fail-closed fallback below cannot drift from the path production uses.
    nonisolated static func realPendingStateDirectory(_ fm: FileManager = .default) -> URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return appSupport.appendingPathComponent("ArchiveProcessor")
    }

    /// Where the paid-batch journal and the interrupted-run manifest live — **fail closed** (W16.bat2-fu2).
    ///
    /// *Why an override exists at all.* Deleting `pending_batch.json` is the one act on the money path no
    /// check could ever perform, because performing it deleted the operator's real journal — so the shipped
    /// deleter (`makeBatchJournalDeleter`'s default) was verified by reading it, and mutating its body to
    /// `{ }` left every check green. With the directory redirectable, a headless check can write a journal,
    /// run the SHIPPED deleter, and watch the file go. The second half matters just as much: with the path
    /// pinned to Application Support, anyone who later bolted an *un-seamed* deletion into the cancel block
    /// would make *running `test-batch-resume.sh`* the thing that destroys a live journal.
    ///
    /// *Why it is gated twice.* A mis-read environment variable here does not fail a test — it **strands a
    /// paid batch**: the app would look for a live server-side job's journal in a directory it was never
    /// written to. So the override is honoured only when `BATCHRESUME_TEST` reads exactly `"1"` AND the
    /// override names a usable ABSOLUTE directory. Unset, empty, whitespace, `"0"`, `"true"`, `"1 "`,
    /// relative, `~`-relative, a path that names a file, or a path that cannot be created → the REAL
    /// directory, every time. There is deliberately no other trigger: no `#if DEBUG`, no test-bundle
    /// sniffing, no debug flag.
    ///
    /// Pure in its inputs on purpose. That is what lets `BatchJournalPathContract` hand it every bad reading
    /// directly and assert the real path comes back — a fail-closed direction that no amount of env-var
    /// mutation could check safely from inside a running app.
    nonisolated static func pendingStateDirectory(testFlag: String?,
                                                  overrideRoot: String?,
                                                  fileManager fm: FileManager = .default) -> URL {
        if let redirected = validatedPendingStateOverride(testFlag: testFlag, overrideRoot: overrideRoot,
                                                          fileManager: fm) {
            return redirected
        }
        let real = realPendingStateDirectory(fm)
        try? fm.createDirectory(at: real, withIntermediateDirectories: true)
        return real
    }

    /// The override directory, or `nil` if any part of the request is not exactly right. Every `return nil`
    /// below is a fail-closed edge: the caller answers with the operator's real path.
    private nonisolated static func validatedPendingStateOverride(testFlag: String?,
                                                                  overrideRoot: String?,
                                                                  fileManager fm: FileManager) -> URL? {
        // Exact match, not `!= nil` and not a truthiness test: `"0"`, `"true"` and `"1 "` are all somebody
        // being approximate about a variable that decides where a paid batch's only record is kept.
        guard testFlag == "1" else { return nil }
        // Absolute paths only. A relative or `~`-relative root would resolve against the app's working
        // directory (or not at all), i.e. somewhere neither the test nor the operator meant.
        guard let trimmed = overrideRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: trimmed, isDirectory: true)
        try? fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        // Must actually BE a directory now — a root that names a regular file, or that could not be created,
        // is unusable, and silently writing the journal beside it is worse than not redirecting.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return candidate
    }

    /// The live answer for this process, resolved from its environment.
    nonisolated static var pendingStateDirectoryFromEnvironment: URL {
        let env = ProcessInfo.processInfo.environment
#if DEBUG
        if PaidBatchUITestFixture.isActive { return PaidBatchUITestFixture.stateDirectory }
        if MoneyJourneyFixture.isActive { return MoneyJourneyFixture.directory.appendingPathComponent("state") }
        for (flag, key) in [("TEXTLAYER_TEST", "TEXTLAYER_TEST_STATE"),
                            ("RETRY_BACKEND_TEST", "RETRY_BACKEND_TEST_STATE")] {
            if let scoped = validatedPendingStateOverride(testFlag: env[flag], overrideRoot: env[key], fileManager: .default) {
                return scoped
            }
        }
#endif
        return pendingStateDirectory(testFlag: env[batchResumeTestEnvKey],
                                     overrideRoot: env[pendingStateTestRootEnvKey])
    }

    /// Internal rather than private so a check can assert *where this resolves* before it writes anything
    /// near it — the guard that keeps `BatchJournalPathContract`'s destructive checks off the real journal.
    nonisolated static var pendingBatchURL: URL {
        pendingStateDirectoryFromEnvironment.appendingPathComponent(pendingBatchFileName)
    }
    @discardableResult
    static func savePendingBatch(_ batch: PendingBatch) -> PendingBatch? {
        guard let prepared = preparedPendingBatchForPersistence(batch),
              let data = try? JSONEncoder().encode(prepared) else { return nil }
        // Crash-safe: `.atomic` writes to a sibling temp file then renames it into place, so a crash or
        // power-loss mid-write can never leave a half-written (corrupt) manifest — a reader sees either
        // the previous complete manifest or the new complete one (Tier-2 rule e).
        do {
            try data.write(to: pendingBatchURL, options: .atomic)
            return prepared
        } catch {
            NSLog("[ArchiveProcessor] ERROR: could not persist paid-batch journal: %@", error.localizedDescription)
            return nil
        }
    }
    private static func loadPendingBatch() -> PendingBatch? {
        guard let data = try? Data(contentsOf: pendingBatchURL) else { return nil }
        return try? JSONDecoder().decode(PendingBatch.self, from: data)
    }
    static func deletePendingBatch() {
        try? FileManager.default.removeItem(at: pendingBatchURL)
    }
    /// File URLs from a pending batch (for populating the file list on resume).
    var pendingBatchFileURLs: [URL]? {
        guard let pending = Self.loadPendingBatch() else { return nil }
        guard pending.mixedPDFOutcomes != nil else { return pending.fileURLs }
        guard Self.pendingBatchIsSelfConsistent(pending) else { return nil }
        return Self.mixedInputURLs(images: pending.fileURLs, pdfs: pending.mixedPDFOutcomes)
    }
    /// The interrupted-run manifest's file name. Named for the same reason as its batch sibling, and
    /// pinned as a DIFFERENT file: cancelling a paid batch must never take this one with it.
    nonisolated static let pendingRunFileName = "pending_run.json"
    /// Same directory, same override, same fail-closed rule (`pendingStateDirectory`) — and internal for the
    /// same reason as its batch sibling: a check has to be able to prove the paid-batch cancellation left
    /// THIS file alone, which means knowing where it is.
    nonisolated static var pendingRunURL: URL {
        pendingStateDirectoryFromEnvironment.appendingPathComponent(pendingRunFileName)
    }
    @discardableResult
    private static func savePendingRun(_ run: PendingRun) -> Bool {
        guard let data = try? JSONEncoder().encode(run) else { return false }
        // Crash-safe write-then-rename (see savePendingBatch): the incremental per-file manifest is
        // rewritten after every completed file, so a crash mid-write must not corrupt it (Tier-2 rule e).
        do {
            try data.write(to: pendingRunURL, options: .atomic)
            return true
        } catch {
            NSLog("[ArchiveProcessor] ERROR: could not persist pending run: %@", error.localizedDescription)
            return false
        }
    }
    private static func loadPendingRun() -> PendingRun? {
        guard let data = try? Data(contentsOf: pendingRunURL) else { return nil }
        return try? JSONDecoder().decode(PendingRun.self, from: data)
    }
    private static func deletePendingRun() {
        try? FileManager.default.removeItem(at: pendingRunURL)
    }

    /// Bind the frozen plan to the exact journals it supersedes. Each has its own consistency checks.
    func catalogueInputJournalDigests(for run: ProcessorCatalogueRun, completed: Bool = true) throws -> [String: String] {
        func sameRun(_ root: URL, _ sources: [URL]?) -> Bool {
            root.standardizedFileURL.path == run.outputRoot.path
                && sources?.map { $0.standardizedFileURL.path } == run.sources.map { $0.standardizedFileURL.path }
        }
        var digests: [String: String] = [:]
        for url in [Self.pendingRunURL, Self.pendingBatchURL, Self.pendingMixedPDFURL] where Self.workingOutputOccupied(url) {
            let verified: Bool
            switch url {
            case Self.pendingRunURL:
                verified = Self.loadPendingRun().map {
                    Self.pendingRunIsSelfConsistent($0)
                        && sameRun($0.outputDirectory, Self.mixedInputURLs(images: $0.fileURLs, pdfs: $0.mixedPDFOutcomes))
                } == true
            case Self.pendingBatchURL:
                verified = Self.loadPendingBatch().map {
                    Self.pendingBatchIsSelfConsistent($0)
                        && (!completed || (!batchPollInterrupted
                            && ($0.submissionComplete || !$0.effectiveChunkIds.isEmpty)))
                        && sameRun($0.outputDirectory, Self.mixedInputURLs(images: $0.fileURLs, pdfs: $0.mixedPDFOutcomes))
                } == true
            default:
                verified = Self.loadPendingMixedPDF().map {
                    Self.pendingMixedPDFIsSelfConsistent($0) && sameRun($0.outputDirectory, $0.originalFiles)
                        && (!completed || ($0.inFlightPage == nil && $0.completedOutcomes.count == $0.pdfIndices.count
                            && Self.mixedPDFOutputsMatchJournal($0)))
                } == true
            }
            guard verified, let digest = Self.mixedPDFSourceDigest(url) else { throw CocoaError(.fileReadCorruptFile) }
            digests[url.lastPathComponent] = digest
        }
        return digests
    }

    func retireCatalogueInputJournals(for run: ProcessorCatalogueRun) throws -> URL? {
        let journals = [Self.pendingRunURL, Self.pendingBatchURL, Self.pendingMixedPDFURL]
            .filter(Self.workingOutputOccupied)
        for journal in journals {
            guard let expected = run.inputJournalDigests?[journal.lastPathComponent],
                  Self.mixedPDFSourceDigest(journal) == expected else { throw CocoaError(.fileReadCorruptFile) }
        }
        let batchArchive = Self.pendingBatchURL.deletingLastPathComponent()
            .appendingPathComponent(run.workingRoot.lastPathComponent + "-partial-batch.json")
        if let pending = Self.loadPendingBatch(), !pending.submissionComplete {
            let fingerprint = run.inputJournalDigests?[Self.pendingBatchURL.lastPathComponent]
            if !Self.workingOutputOccupied(batchArchive) {
                let data = try Data(contentsOf: Self.pendingBatchURL)
                try data.write(to: batchArchive, options: .withoutOverwriting)
                try ProcessorCatalogueRun.flushFileAndParent(batchArchive)
            }
            guard fingerprint != nil, Self.mixedPDFSourceDigest(batchArchive) == fingerprint else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        for journal in journals { try FileManager.default.removeItem(at: journal) }
        try ProcessorCatalogueRun.flushFileAndParent(Self.pendingCatalogueURL)
        return Self.workingOutputOccupied(batchArchive) ? batchArchive : nil
    }

    // MARK: - Processing history (cost + run log)

    /// The upstream provider family a gateway run bills against — drives the estimator's image-token math.
    /// Read from the SAME `@AppStorage` key the pre-run cost pane uses, so a recorded gateway run's cost
    /// matches what the operator saw. Only meaningful while a gateway is active.
    nonisolated static func gatewayUpstreamProviderFromDefaults(_ d: UserDefaults = .standard) -> LLMProvider {
        LLMProvider(rawValue: d.string(forKey: DefaultsKeys.gatewayUpstreamProvider) ?? "") ?? .anthropic
    }

    /// Live image-size-target fraction (0–1) from the resolution `@AppStorage`, defaulting to full size
    /// when unset. Used by batch resumes and legacy non-batch manifests that predate the v2 runtime
    /// snapshot; new non-batch resumes use their persisted scale instead.
    static func liveImageScaleFraction(_ defaults: UserDefaults = .standard) -> Double {
        let pct = (defaults.object(forKey: DefaultsKeys.imageResolutionPercent) as? Double) ?? 100
        return max(0.01, min(1.0, pct / 100.0))
    }

    /// Record the just-completed Process-Files run in the persistent history (estimator-derived cost +
    /// provider/model + file counts), then clear the in-memory snapshot so it can't be double-logged.
    /// A no-op when no snapshot was captured (e.g. a cancelled run cleared it, or an unexpected path).
    /// Called only from genuine success tails, never on cancel/interruption.
    func recordRunHistory(succeeded: Int) {
        guard let snapshot = activeRunHistory else { return }
#if DEBUG
        if ProcessInfo.processInfo.environment["TEXTLAYER_TEST"] == "1",
           ProcessInfo.processInfo.environment["TEXTLAYER_TEST_STATE"] != nil {
            activeRunHistory = nil
            return
        }
#endif
        let run = snapshot.makeRun(
            succeeded: succeeded, secondReaders: jobs.compactMap { $0.result?.secondReader },
            pageReaders: jobs.compactMap { $0.result?.pageReader },
            rotationUnsure: jobs.filter { $0.result?.rotationUnsure == true }.count,
            readPoorly: readPoorlyNames.count,
            layouts: jobs.compactMap { $0.result?.newspaperLayout })
        ProcessingHistoryStore.shared.record(run)
        activeRunHistory = nil
    }

    /// The run summary's last line: the counts, and how many pages a second reader read (W41.app-ocr-default-fu1).
    func runDoneMessage(succeeded: Int, failed: Int) -> String {
        let secondRead = jobs.filter { $0.result?.secondReader != nil }.count
        let routed = jobs.filter { $0.result?.pageReader?.isRouted == true }.count
        let rotations = jobs.filter { $0.status == .succeeded }.compactMap(\.result)
        let failedVotes = rotations.filter { $0.comparativeRotationFailed == true }.count
        let unsure = rotations.filter { $0.rotationUnsure == true }
        let leftUnturned = unsure.filter { $0.rotationDegrees % 360 == 0 }.count
        let turned = unsure.count - leftUnturned
        return "Done. \(succeeded) succeeded, \(failed) failed."
            + (secondRead == 0 ? "" : " \(secondRead) \(secondRead == 1 ? "page" : "pages") read by a second reader.")
            + (routed == 0 ? "" : " \(routed) \(routed == 1 ? "page" : "pages") read by the reader \(routed == 1 ? "its" : "their") kind chose.")
            + (failedVotes == 0 ? "" : " Comparative rotation check failed on \(failedVotes) \(failedVotes == 1 ? "page" : "pages"). Apple Vision checked rotation instead.")
            + (leftUnturned == 0 ? "" : " \(leftUnturned) \(leftUnturned == 1 ? "page" : "pages") left unturned, rotation unsure.")
            + (turned == 0 ? "" : " \(turned) \(turned == 1 ? "page was" : "pages were") turned, rotation unsure.")
            + Self.readPoorlyClause(readPoorlyPages)
    }

    /// This run's pages that probably read poorly (W46.post-read-quality-flag), on a page that succeeded: Apple
    /// Vision's reading with low confidence, or another reader's that disagreed with Vision's (W47.wh-read-flag-readers).
    var readPoorlyPages: [(name: String, flag: ReadQualityFlag)] {
        jobs.compactMap { job in
            guard let flag = job.result?.readPoorly, job.result?.errorMessage == nil else { return nil }
            return (job.sourceURL.lastPathComponent, flag)
        }
    }

    var readPoorlyNames: [String] { readPoorlyPages.map(\.name) }

    /// The run summary's clause naming them: up to three files, then how many more; why they were flagged; and, per
    /// reader, the pages it was measured on and what it caught at its fitted cut.
    static func readPoorlyClause(_ pages: [(name: String, flag: ReadQualityFlag)]) -> String {
        guard !pages.isEmpty else { return "" }
        let names = pages.map(\.name)
        let shown = names.prefix(3).joined(separator: ", ")
        let more = names.count > 3 ? " and \(names.count - 3) more" : ""
        let unsure = pages.contains { $0.flag.visionConfidence != nil }
        let differs = pages.contains { $0.flag.disagreement != nil }
        let why = unsure && differs ? "Apple Vision was unsure, or read the page differently"
            : differs ? "Apple Vision read \(names.count == 1 ? "it" : "them") differently" : "Apple Vision was unsure"
        var measured: [String] = []
        for page in pages {
            let vision = page.flag.visionConfidence != nil
            var line = vision
                ? "Apple Vision's check was measured on \(ReadQualityFlag.visionMeasuredOn)"
                : "\(page.flag.reader ?? "the reader")'s check was measured on \(page.flag.measuredOn ?? "the bench's pages")"
            if let caught = vision ? ReadQualityFlag.visionMeasuredCatch : page.flag.measuredCatch {
                line += " and \(caught)"
            }
            if !measured.contains(line) { measured.append(line) }
        }
        return " \(names.count) \(names.count == 1 ? "page" : "pages") may have read poorly (\(why)); "
            + "check \(shown)\(more). " + measured.joined(separator: "; ") + "."
    }
    /// Save window and flagged-gap answers, and document review's cover choices, so a resume can reuse them
    /// after OCR.
    @discardableResult
    func persistWindowSegmentationProgress(windows: [WindowKey: WindowAnswer]? = nil,
                                           answers: [String: SavedGapAnswer]? = nil,
                                           covers: [String: String]? = nil) -> Bool {
        guard !Task.isCancelled else { return false }
        if var run = activePendingRun {
            if let windows { run.segmentationWindows = windows }
            if let answers { run.segmentationAnswers = (run.segmentationAnswers ?? [:]).merging(answers) { $1 } }
            if let covers { run.enclosureCovers = (run.enclosureCovers ?? [:]).merging(covers) { $1 } }
            activePendingRun = run
            if let save = pendingRunSaveOverride { save(run) } else { Self.savePendingRun(run) }
        } else if let batch = activePendingBatch, batch.usesWindowSegmentation {
            let saved = persistPendingBatchMutation(
                failureMessage: "Could not save segmentation progress. The paid batch was kept for Resume."
            ) { batch in
                if let windows { batch.segmentationWindows = windows }
                if let answers { batch.segmentationAnswers = (batch.segmentationAnswers ?? [:]).merging(answers) { $1 } }
                if let covers { batch.enclosureCovers = (batch.enclosureCovers ?? [:]).merging(covers) { $1 } }
            }
            guard saved else {
                finishInterruptedBatchPoll()
                return false
            }
        }
        return true
    }

    // W49.proc-unified-pipeline-1 (absorbing W49.proc-resume-tagging-progress): `taggingProgressKey` is in
    // OCRProcessor+PostOCRFinalizer.swift; these write the pending run, so they live beside its private save.
    /// The answers a resumed run already paid for, keyed by `taggingProgressKey`; empty outside a resumable run.
    var savedTaggingProgress: [String: SavedSegmentTags] { activePendingRun?.taggingProgress ?? [:] }

    /// Keep one segment's answers in the run's manifest as they land, so a crash or quit during tagging does not buy
    /// them again. A failed save costs only that: the run goes on, and a resume asks again.
    func persistTaggingProgress(_ saved: SavedSegmentTags, key: String, sources: [URL]) {
        // Only into the manifest of the run whose pages these are.
        guard !Task.isCancelled, var run = activePendingRun, !sources.isEmpty,
              Set(run.fileURLs).isSuperset(of: sources) else { return }
        run.taggingProgress = (run.taggingProgress ?? [:]).merging([key: saved]) { $1 }
        activePendingRun = run
        if let save = pendingRunSaveOverride { save(run) } else { Self.savePendingRun(run) }
    }

    /// A Redo asks every tagging call again, so the answers kept for a resume go with it.
    func forgetTaggingProgress() {
        guard var run = activePendingRun, run.taggingProgress != nil else { return }
        run.taggingProgress = nil
        activePendingRun = run
        if let save = pendingRunSaveOverride { save(run) } else { Self.savePendingRun(run) }
    }

    /// Save a completed OCR result to the pending run on disk, along with the EXACT output-PDF path that
    /// was assigned to this index in the original pass. Persisting the assigned path (not just the result)
    /// is what lets resume reuse the same source→output association verbatim instead of re-deriving it in
    /// index order, which would swap outputs for two sources that share a base filename (B7).
    @discardableResult
    func saveResultToPendingRun(index: Int, result: OCRResult, outputURL: URL? = nil) -> Bool {
        // Paid batches have their own lifecycle journal. Persist every materialized result before a
        // Gemini chunk can be marked consumed, so a relaunch can skip already-written files even if the
        // process died halfway through that chunk.
        if activePendingRun == nil {
            if activePendingBatch != nil {
                return persistPendingBatchMutation(
                    failureMessage: "Could not save paid-batch progress. Processing stopped to avoid duplicate outputs or charges."
                ) { batch in
                    let key = "\(index)"
                    batch.completedResults[key] = result
                    if let outputURL {
                        if batch.completedOutputPaths == nil { batch.completedOutputPaths = [:] }
                        batch.completedOutputPaths?[key] = outputURL.path
                    }
                }
            }
            // Stop can land after the provider returned this result but before its PDF and durable
            // completion record finish writing. The PDF is already on disk by this call, and the address
            // is the exact journal Stop retained; append this fact to that file so Resume skips the result
            // instead of retrieving the same completed chunk and allocating a duplicate output path.
            if closedPaidBatchJournalAddress != nil {
                guard recordCompletedResultToClosedPaidBatchJournal(
                    index: index, result: result, outputURL: outputURL
                ) else {
                    reportInterruptedPaidBatch(
                        "Batch results were written after Stop, but their recovery record could not be saved. The batch was kept for recovery.",
                        cancelRun: false)
                    return false
                }
                // A post-Stop materialization must never fall through a terminal-status poll as a clean
                // completion: the cancelled task may have no next loop iteration in which to observe its
                // cancellation. The journal stays for Resume even when this was its final chunk.
                batchPollInterrupted = true
                isProcessing = false
                return true
            }
        }

        guard var run = activePendingRun else { return true }
        run.completedResults["\(index)"] = result
        if let outputURL {
            if run.completedOutputPaths == nil { run.completedOutputPaths = [:] }
            run.completedOutputPaths?["\(index)"] = outputURL.path
        }
        // V2 integrity covers the evolving completion state as well as immutable configuration. Recompute
        // after each result so a swapped/tampered index→result/output association fails self-consistency.
        if run.runtimeConfig != nil {
            guard let fingerprint = Self.pendingRunFingerprintV2(run) else {
                statusMessage = "Could not update the resume snapshot. Processing stopped to avoid duplicate OCR charges."
                isProcessing = false
                processingTask?.cancel()
                return false
            }
            run.runFingerprint = fingerprint
        }
        // Do not publish the in-memory mutation until its atomic disk replacement succeeds. If storage
        // fails, the previous durable manifest remains valid and the run stops before scheduling more work.
        guard Self.savePendingRun(run) else {
            statusMessage = "Could not save the resume snapshot. Processing stopped to avoid duplicate OCR charges."
            isProcessing = false
            processingTask?.cancel()
            return false
        }
        activePendingRun = run
        return true
    }

    /// The one way a paid-batch run says *"I was cut short"* (W16.bat3-fu).
    ///
    /// `batchPollInterrupted` is the single fact every caller reads to decide the journal's fate
    /// (`retirePaidBatchJournalIfPollCompleted`, `resumePendingBatch`, `processFiles`), and **nothing resets
    /// it at the start of a run** — the only `= false` in the app is inside `pollBatchUntilComplete`. So an
    /// interrupted exit that stays quiet is not neutral: it hands this run's verdict to whatever the
    /// *previous* run happened to leave behind. `true` is also the keep-on-doubt answer — every reader of
    /// the flag treats it as "the journal survives", and none of them deletes on it.
    ///
    /// Deliberately does NOT touch the journal, the jobs, the resume banner, or any output: reporting an
    /// interruption and acting on one are different jobs, and the acting is `finishInterruptedBatchPoll()`'s
    /// at the caller.
    ///
    /// `cancelRun` is why this takes a second parameter at all. Stopping the run is right when the run is
    /// still LIVE and has just discovered it cannot go on — a journal write that failed. It is wrong when we
    /// are already unwinding FROM a Stop: `cancel()` has set `processingTask = nil`, and by the time this
    /// run's submit loop notices, the operator may legitimately have started a NEW one (a confirmed
    /// cancellation deletes the journal `startProcessing` refuses on, while this run is still resolving a
    /// provider request that can take 30–120s). `processingTask` would then be the new run's, and cancelling
    /// it would kill the wrong run. So the post-Stop exit reports without cancelling — there is nothing of
    /// ours left to cancel.
    func reportInterruptedPaidBatch(_ message: String, cancelRun: Bool = true) {
        statusMessage = message
        // Kept as well as shown (W16.bat3-fu2). `performBatchOCR`'s catch summarises the interruption over
        // the top of this, and the summary knows the counts while only the reporter knows the cause; this is
        // how the cause survives to be read alongside them.
        lastPaidBatchInterruptionReport = message
        batchPollInterrupted = true
        isProcessing = false
        if cancelRun { processingTask?.cancel() }
    }

    /// Shown when the in-memory journal is gone before a mutation could be applied. `cancel()` nils
    /// `activePendingBatch` while a submit may still be running, so this is the shape a Stop pressed
    /// mid-submit arrives in — not a corruption, and nothing here removed anything.
    static let pendingBatchJournalClosedMessage =
        "A paid batch step could not be recorded — its recovery journal had already been closed by Stop. Nothing further was removed; check for a pending batch before retrying."

    // MARK: - Telling the operator what an interrupted submission really did (W16.bat3-fu2)

    /// What the durable paid-batch journal says at the instant it is asked.
    ///
    /// Read from DISK on purpose. The in-memory `activePendingBatch` is exactly what a Stop mid-submit has
    /// just nil'd, so it answers "there is no journal and nothing was acknowledged" on the one path where
    /// both halves are false — which is how `performBatchOCR`'s catch came to tell the operator the journal
    /// had been kept while reporting zero acknowledged jobs.
    struct PaidBatchJournalState: Equatable, Sendable {
        /// The journal FILE exists. Deliberately a file-system fact rather than "it decoded": a torn journal
        /// is still a journal on disk, and saying it is gone would send the operator looking for a paid job
        /// with no local record when the record is right there.
        let onDisk: Bool
        /// Server job IDs the journal actually carries. Zero for a file that failed to decode — which
        /// understates nothing, because it is compared against the created count and any shortfall is
        /// reported as unrecorded work.
        let acknowledgedChunkCount: Int
    }

    static func paidBatchJournalState() -> PaidBatchJournalState {
        PaidBatchJournalState(
            onDisk: FileManager.default.fileExists(atPath: pendingBatchURL.path),
            acknowledgedChunkCount: loadPendingBatch()?.effectiveChunkIds.count ?? 0)
    }

    /// The sentence an operator decides whether to re-submit a paid batch from.
    ///
    /// Pure, so the whole matrix behind it can be swept for $0 (`BatchSubmissionMessageContract`). Every
    /// clause is a fact one of the callers measured rather than an inference:
    ///   * `createdJobCount` is what the submit loop created (`paidJobsCreatedThisSubmission`), NOT what the
    ///     journal it may no longer hold says. This is the money number and it is never guessed downward.
    ///   * the journal clause comes from the file on disk, so "kept" is only ever said about a file that is
    ///     there — the old text asserted it unconditionally.
    ///   * a shortfall between the two is named. Created-but-unrecorded jobs are the one shape Resume cannot
    ///     reach, so an operator who reads only "the journal was kept" would never go looking for them.
    ///   * `priorReport` leads, when a mutator already explained the cause. It used to be overwritten here.
    static func interruptedSubmissionMessage(
        createdJobCount: Int,
        journal: PaidBatchJournalState,
        priorReport: String?
    ) -> String {
        func jobs(_ n: Int) -> String { "\(n) server job\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if let priorReport, !priorReport.isEmpty { parts.append(priorReport) }

        if createdJobCount == 0 {
            // Still uncertain rather than "nothing happened": a non-idempotent create can be accepted
            // server-side with its reply lost on the way back, which is the case this wording exists for.
            parts.append("Batch submission outcome is uncertain. No server job was acknowledged, "
                         + "but a create whose reply was lost may still have been accepted.")
        } else {
            parts.append("Batch submission stopped after \(jobs(createdJobCount)) had been created.")
        }

        let unrecorded = max(0, createdJobCount - journal.acknowledgedChunkCount)
        if journal.onDisk {
            if unrecorded > 0 {
                parts.append("The recovery journal was kept, but \(jobs(unrecorded)) "
                             + "\(unrecorded == 1 ? "is" : "are") missing from it, so Resume will not reach "
                             + "\(unrecorded == 1 ? "it" : "them").")
            } else if journal.acknowledgedChunkCount > 0 {
                parts.append("The recovery journal was kept, so Resume can pick the batch up.")
            } else {
                parts.append("The recovery journal was kept. Check the provider's batch console for a job.")
            }
        } else {
            parts.append(createdJobCount == 0
                ? "No recovery journal is on disk."
                : "No recovery journal is on disk, so the app has no local record of "
                  + "\(createdJobCount == 1 ? "that job" : "those jobs").")
        }
        parts.append("Review before retrying.")
        return parts.joined(separator: " ")
    }

    /// `performBatchOCR`'s submission-failure exit, extracted so it can be driven without a paid submission.
    ///
    /// Same four statements the exit always made — say what happened, flag the interruption, end the run,
    /// refresh the Resume banner — with the message now composed from measurements. It does NOT cancel
    /// `processingTask`: this runs *on* that task, and the run is ending under its own power.
    func reportInterruptedBatchSubmission(
        refusal: BatchCreateRefusal? = nil,
        localRefusal: String? = nil,
        address: ClosedPaidBatchJournalAddress? = nil
    ) {
        let refusalMessage = localRefusal ?? refusal?.localizedDescription
        if let refusalMessage, let address, !Task.isCancelled, paidJobsCreatedThisSubmission.isEmpty,
           let activePendingBatch, address.matches(activePendingBatch),
           activePendingBatch.effectiveChunkIds.isEmpty,
           let journal = Self.loadPendingBatch(), address.matches(journal),
           Self.pendingBatchIsSelfConsistent(journal), journal.submissionComplete == false,
           journal.effectiveChunkIds.isEmpty,
           journal.lifecycleFingerprint == activePendingBatch.lifecycleFingerprint,
           journal.mixedPDFOutcomes == nil || hasRetainedMixedPDFJournal() {
            // A first-create refusal proves there is no batch work to recover or charge. The mixed PDF
            // journal, if any, still holds the PDF work and remains available after this batch is retired.
            Self.deletePendingBatch()
            activeRunHistory = nil
            statusMessage = refusalMessage
            if Self.paidBatchJournalState().onDisk {
                statusMessage += " The local batch journal could not be removed."
            }
        } else {
            statusMessage = Self.interruptedSubmissionMessage(
                createdJobCount: paidJobsCreatedThisSubmission.count,
                journal: Self.paidBatchJournalState(),
                priorReport: refusalMessage ?? lastPaidBatchInterruptionReport)
        }
        batchPollInterrupted = true
        isProcessing = false
        checkForPendingBatch()
    }

    private func hasRetainedMixedPDFJournal() -> Bool {
        guard let activePendingMixedPDF, let saved = Self.loadPendingMixedPDF() else { return false }
        return Self.pendingMixedPDFIsSelfConsistent(saved) && saved.integrity == activePendingMixedPDF.integrity
    }

    /// Atomically advance the in-memory + on-disk paid-batch journal. The old durable snapshot remains
    /// authoritative if the replacement fails; callers stop immediately instead of continuing past it.
    ///
    /// **Neither failure exit is silent** (W16.bat3-fu). It used to have one that was: the missing-journal
    /// guard below `return false`d without a word, and `performBatchOCR`'s
    /// `guard markBatchSubmissionComplete() else { return }` — its FIFTH interrupted exit — turned that into
    /// a silent return from a run whose batch is already paid for.
    @discardableResult
    func persistPendingBatchMutation(
        failureMessage: String,
        _ mutation: (inout PendingBatch) -> Void
    ) -> Bool {
        guard var candidate = activePendingBatch else {
            // Post-Stop by construction (only `cancel()` nils this mid-run), so `cancelRun: false` — see
            // the reporter's doc: `processingTask` is either already nil or a NEWER run's, never ours.
            reportInterruptedPaidBatch(Self.pendingBatchJournalClosedMessage, cancelRun: false)
            return false
        }
        mutation(&candidate)
        guard let persisted = Self.savePendingBatch(candidate) else {
            reportInterruptedPaidBatch(failureMessage)
            return false
        }
        activePendingBatch = persisted
        if let context = activeBatch {
            activeBatch = BatchContext(
                batchId: persisted.batchId, apiKey: context.apiKey, model: context.model,
                thinkingLevel: context.thinkingLevel, provider: context.provider)
        }
        return true
    }

    // MARK: - Recording a job created after Stop closed the journal (W16.bat5-fu)

    /// Which paid-batch journal `cancel()` closed — enough to recognise it again on disk, and nothing more.
    ///
    /// Deliberately NOT the `PendingBatch` itself. A snapshot could be written back, and writing back a
    /// snapshot taken at Stop would undo anything the journal gained afterwards; an address can only ever be
    /// compared. `submittedAt` is stamped once per submission and `runFingerprint` covers the run's inputs,
    /// destination and settings, so together they answer "is the file on disk still THIS batch's journal?"
    /// — the question that keeps a late chunk ID off a *different* run's paid batch.
    struct ClosedPaidBatchJournalAddress: Equatable, Sendable {
        let submittedAt: Date
        let runFingerprint: String?

        init?(_ pendingBatch: PendingBatch?) {
            guard let pendingBatch else { return nil }
            submittedAt = pendingBatch.submittedAt
            runFingerprint = pendingBatch.runFingerprint
        }

        func matches(_ candidate: PendingBatch) -> Bool {
            candidate.submittedAt == submittedAt && candidate.runFingerprint == runFingerprint
        }
    }

    /// Append one server job ID to the paid-batch journal a Stop already closed (W16.bat5-fu).
    ///
    /// **Append-only, and only ever onto a journal that is already there.** It re-reads the file, adds the ID
    /// to `submittedChunkIds` if it is missing, and writes the result back through the production writer (so
    /// the derived comma-joined mirror and the lifecycle fingerprint are recomputed exactly as the live path
    /// recomputes them). Every other field is carried through untouched. It never creates a journal, never
    /// replaces one it could not read, and never restores `activePendingBatch` — the run is over; only the
    /// operator's way back to a paid job is being repaired.
    ///
    /// Four refusals, each of which would otherwise make the app do something worse than losing the ID:
    ///   * **No address, or a live journal.** Only `cancel()` sets the address, and only while
    ///     `activePendingBatch` is nil is the closed journal the right place to write — with a live journal
    ///     the normal `persistPendingBatchMutation` path owns the file.
    ///   * **No file on disk.** A confirmed cancellation deletes the journal; re-creating it here would
    ///     resurrect a Resume banner for a batch that was really cancelled, and `startProcessing` refuses to
    ///     start while one exists. A journal that failed to decode is likewise left exactly as it is rather
    ///     than overwritten — a torn file is still the operator's only record of the paid job.
    ///   * **A different batch's journal.** After a delete the operator may have started another run; adding
    ///     a stranger's job ID to a LIVE batch's journal would make its poll fetch another run's pages.
    ///   * **A legacy (pre-lifecycle) journal.** `effectiveChunkIds` reads a legacy manifest's comma-joined
    ///     `batchId`, not `submittedChunkIds`, so an append there would be written and never read back.
    ///
    /// Synchronous on the MainActor by construction: the load and the save are one uninterrupted turn, so
    /// the cancellation task's own journal delete cannot land between them.
    ///
    /// Takes an ID its caller has already trimmed and validated (`recordSubmittedBatchChunk` does both
    /// before calling), and writes through `savePendingBatch` rather than encoding the struct itself — the
    /// resume guard checks the comma-joined mirror and the lifecycle fingerprint the writer recomputes, so
    /// a hand-rolled write would produce a journal the app then refuses to offer for resume.
    @discardableResult
    func appendChunkIdToClosedPaidBatchJournal(_ chunkId: String, paidAttemptID: UUID? = nil) -> Bool {
        guard activePendingBatch == nil, let address = closedPaidBatchJournalAddress else { return false }
        guard let onDisk = Self.loadPendingBatch(), address.matches(onDisk),
              onDisk.lifecycleVersion == PendingBatch.currentLifecycleVersion else { return false }
        // Already recorded — by the submit loop before the Stop, or by a retried callback. Report success:
        // the ID *is* in the journal, which is the whole property this function exists to provide.
        guard !onDisk.effectiveChunkIds.contains(chunkId) else { return true }
        var appended = onDisk
        appended.submittedChunkIds.append(chunkId)
        if let paidAttemptID { appended.paidRequestLinks = [chunkId: paidAttemptID] }
        return Self.savePendingBatch(appended) != nil
    }

    /// A successful standard-rate newspaper fallback is durable before its output is materialised, even when
    /// Stop closed the live journal while the response was arriving. Never creates or reopens a journal.
    func persistNewspaperFallback(_ result: OCRResult, index: Int,
                                  address: ClosedPaidBatchJournalAddress?) -> Bool {
        guard let address else { return false }
        let live = activePendingBatch.map { address.matches($0) } == true
        let closed = activePendingBatch == nil && closedPaidBatchJournalAddress == address
        guard live || closed,
              var pending = live ? activePendingBatch : Self.loadPendingBatch(), address.matches(pending),
              pending.newspaperManifest?.pages.contains(where: { $0.fileIndex == index && $0.isExpanded }) == true
        else { return false }
        if pending.newspaperParts == nil { pending.newspaperParts = [:] }
        pending.newspaperParts?["file-\(index)"] = result
        guard let saved = Self.savePendingBatch(pending) else { return false }
        if live { activePendingBatch = saved }
        return true
    }

    /// Record a result whose PDF was materialized after Stop had closed its in-memory journal. This is the
    /// result-side counterpart to `appendChunkIdToClosedPaidBatchJournal`: it re-reads only the journal
    /// identified by Stop, records an otherwise missing completed index and exact output path, and lets the
    /// production writer recompute every lifecycle-derived field. A result already in the journal is the
    /// desired state, so a late/retried continuation is a no-op success rather than a second output claim.
    ///
    /// It is intentionally narrower than `persistPendingBatchMutation`: only completed-result facts from a
    /// write that has already happened can cross this boundary. In particular, `submissionComplete` remains
    /// closed after Stop — a late mark would falsely claim the cancelled chunk list was exhaustive.
    @discardableResult
    private func recordCompletedResultToClosedPaidBatchJournal(
        index: Int, result: OCRResult, outputURL: URL?
    ) -> Bool {
        guard activePendingBatch == nil, let address = closedPaidBatchJournalAddress else { return false }
        guard var onDisk = Self.loadPendingBatch(), address.matches(onDisk),
              onDisk.lifecycleVersion == PendingBatch.currentLifecycleVersion else { return false }
        let key = "\(index)"
        guard onDisk.completedResults[key] == nil else { return true }
        onDisk.completedResults[key] = result
        if let outputURL {
            if onDisk.completedOutputPaths == nil { onDisk.completedOutputPaths = [:] }
            onDisk.completedOutputPaths?[key] = outputURL.path
        }
        return Self.savePendingBatch(onDisk) != nil
    }

    /// Shown when a job created as Stop landed was recorded in the journal `cancel()` had already closed.
    ///
    /// The submission still stops here — this is the same interruption
    /// `pendingBatchJournalClosedMessage` describes, and pressing Stop must not be answered by continuing to
    /// spend. What changed is that the operator is no longer being sent to the provider console for a job the
    /// app now knows about: it is in the journal Resume reads.
    static let pendingBatchChunkRecordedAfterStopMessage =
        "A paid batch job was created just as Stop landed. Its server ID was added to the recovery journal, so Resume can still reach it. Submission stopped; nothing was removed."

    @discardableResult
    func recordSubmittedBatchChunk(_ chunkId: String, paidAttemptID: UUID? = nil) -> Bool {
        let normalized = chunkId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tally FIRST, and before the validation guard (W16.bat3-fu2). This is called once per server-side
        // job the provider has already created, so it is the earliest — and, once Stop has nil'd
        // `activePendingBatch`, the only — place the count of what was billed still exists. An ID the guard
        // below rejects is counted too: the job is no less real for having an unusable name, and a count
        // that quietly omitted it would be the same understatement this item exists to remove.
        if !paidJobsCreatedThisSubmission.contains(normalized) {
            paidJobsCreatedThisSubmission.append(normalized)
        }
        guard !normalized.isEmpty, !normalized.contains(",") else { return false }
        if activePendingBatch?.submittedChunkIds.contains(normalized) == true { return true }
        // The journal may be CLOSED and still on disk (W16.bat5-fu). That is what a Stop pressed mid-submit
        // leaves — `cancel()` nils `activePendingBatch`, and keeps the file whenever the submission had not
        // finished — and this callback runs for a job the provider has ALREADY created and billed. Write the
        // ID into the file rather than losing it. Returning `false` regardless is deliberate and load-bearing:
        // it is what makes the submit loop throw and stop creating more paid jobs after a Stop. The ID is
        // recovered; the run is still over.
        if appendChunkIdToClosedPaidBatchJournal(normalized, paidAttemptID: paidAttemptID) {
            // `cancelRun: false` for the same reason the missing-journal guard below uses it: post-Stop,
            // `processingTask` is nil or a NEWER run's — see `reportInterruptedPaidBatch`'s doc.
            reportInterruptedPaidBatch(Self.pendingBatchChunkRecordedAfterStopMessage, cancelRun: false)
            return false
        }
        return persistPendingBatchMutation(
            failureMessage: "A paid batch chunk was created, but its server ID could not be saved. Submission stopped."
        ) { pending in
            pending.submittedChunkIds.append(normalized)
            if let paidAttemptID { pending.paidRequestLinks = [normalized: paidAttemptID] }
        }
    }

    @discardableResult
    func markBatchSubmissionComplete() -> Bool {
        persistPendingBatchMutation(
            failureMessage: "The paid batch was submitted, but final submission state could not be saved. It was kept for recovery."
        ) { $0.submissionComplete = true }
    }

    @discardableResult
    func markBatchChunkConsumed(_ chunkId: String) -> Bool {
        if activePendingBatch?.consumedChunkIds.contains(chunkId) == true { return true }
        // `processBatchResults` has already written this chunk's PDFs when it reaches here. If Stop
        // closed only the in-memory journal during that write, retain the completion fact in the exact
        // on-disk journal it kept; Resume then skips the recorded pages instead of materializing them again.
        if markClosedPaidBatchChunkConsumed(chunkId) {
            batchPollInterrupted = true
            isProcessing = false
            return true
        }
        return persistPendingBatchMutation(
            failureMessage: "Batch results were written, but chunk completion could not be saved. The batch was kept for recovery."
        ) { $0.consumedChunkIds.append(chunkId) }
    }

    /// Append a consumed-chunk fact to the matching journal Stop retained. Like the result helper above,
    /// this has no route to a live/different/legacy/deleted journal and never reopens `activePendingBatch`.
    @discardableResult
    private func markClosedPaidBatchChunkConsumed(_ chunkId: String) -> Bool {
        guard activePendingBatch == nil, let address = closedPaidBatchJournalAddress else { return false }
        guard var onDisk = Self.loadPendingBatch(), address.matches(onDisk),
              onDisk.lifecycleVersion == PendingBatch.currentLifecycleVersion else { return false }
        guard !onDisk.consumedChunkIds.contains(chunkId) else { return true }
        onDisk.consumedChunkIds.append(chunkId)
        return Self.savePendingBatch(onDisk) != nil
    }
    /// File URLs from a pending run (for populating the file list on resume).
    var pendingRunFileURLs: [URL]? {
        if let run = Self.savedCatalogueRun(), run.files != nil { return run.sources }
        guard let pending = Self.loadPendingRun() else { return nil }
        guard pending.mixedPDFOutcomes != nil else { return pending.fileURLs }
        guard Self.pendingRunIsSelfConsistent(pending) else { return nil }
        return Self.mixedInputURLs(images: pending.fileURLs, pdfs: pending.mixedPDFOutcomes)
    }
    /// The backend a pending run replays, in `performOCRCall`'s precedence: the Local Agent, then the gateway,
    /// then the direct provider (W40.fix-processor-resume-run-key).
    nonisolated static func pendingRunBackend(of run: PendingRun) -> PendingRunBackend {
        if run.localAgent != nil { return .localAgent }
        if let gateway = run.gatewayConfig { return .gateway(gateway) }
        return run.provider == .appleVision ? .appleVision : .direct(run.provider)
    }
    /// What read the interrupted run, for the Interrupted Run box, in `pendingRunBackend`'s precedence. A Local Agent
    /// or gateway run's stored provider and model are only the UI selection at the time, so they are not named
    /// (W40.fix-processor-pending-run-caption).
    nonisolated static func pendingRunRouteLabel(of run: PendingRun) -> String {
        switch pendingRunBackend(of: run) {
        case .localAgent:
            guard let agent = run.localAgent else { return "the Local Agent" }
            return "the Local Agent (\(agent.tool.displayName), \(agent.provenanceModelName))"
        case .gateway(let gateway):
            return gateway.isLocalModel ? "a model on this Mac (\(gateway.displayName))" : "the gateway (\(gateway.displayName))"
        case .appleVision:
            return "Apple Vision"
        case .direct(let provider):
            let model = run.model.displayName
            return model.hasPrefix(provider.rawValue) ? model : "\(provider.rawValue) \(model)"
        }
    }
    /// Only a direct-provider resume needs the selected provider and a configured key.
    func pendingRunResumeBlockReason(hasKey: Bool, fieldProvider: LLMProvider?) -> String? {
        guard let backend = pendingRunBackend else { return "This run's record could not be verified." }
        guard case .direct(let provider) = backend else { return nil }
        if fieldProvider == provider && hasKey { return nil }
        return fieldProvider == provider
            ? "Add your \(provider.rawValue) API key in Settings › Accounts, then click Resume."
            : "Select \(provider.rawValue) in Settings › Processing and save its API key in Settings › Accounts, then click Resume."
    }
    /// The key `resumeRun` gets for the pending run's backend, or nil (with the reason in `statusMessage`) when a
    /// gateway run's saved key is missing. A direct run takes the field's key, which the button has already
    /// checked belongs to the run's provider.
    func pendingRunResumeKey(fieldKey: String) -> String? {
        guard case .gateway(let gateway) = pendingRunBackend else { return fieldKey }
        let key = gateway.apiKey
        guard !key.isEmpty else {
            statusMessage = "Restore the saved gateway key before resuming this run."
            return nil
        }
        return key
    }
    nonisolated static func sameJournalPayload<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let original = try? encoder.encode(lhs) else { return false }
        return (try? encoder.encode(rhs)) == original
    }

    /// Check for persisted pending batch or run on launch.
    func checkForPendingBatch() {
        if let run = Self.savedCatalogueRun(), let files = run.files {
            pendingBatchInfo = nil
            pendingMixedPDFInfo = nil
            pendingRunInfo = "\(files.count) prepared PDF\(files.count == 1 ? "" : "s") are waiting to finish catalogue filing."
            pendingRunBackend = .appleVision
            return
        }
        if FileManager.default.fileExists(atPath: Self.pendingCatalogueURL.path),
           !Self.workingOutputOccupied(Self.pendingRunURL), !Self.workingOutputOccupied(Self.pendingBatchURL),
           !Self.workingOutputOccupied(Self.pendingMixedPDFURL) {
            pendingBatchInfo = nil
            pendingMixedPDFInfo = nil
            pendingRunInfo = "Process Files kept a working copy before it could prepare the catalogue filing. Set it aside with Dismiss before starting the run again."
            pendingRunBackend = nil
            return
        }
        // Keep and surface malformed or self-inconsistent batch journals for review. The resume
        // path verifies the journal again before using it for any provider request.
        if let pending = Self.loadPendingBatch() {
            if Self.pendingBatchIsSelfConsistent(pending) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let dateStr = formatter.string(from: pending.submittedAt)
                pendingBatchInfo = "Pending batch from \(dateStr): \(pending.fileURLs.count) files via \(pending.provider.rawValue) \(pending.model.displayName)."
            } else {
                // FAIL-SAFE (Finding 4): a batch is a PAID server-side job. If its manifest fails the
                // self-consistency guard we must NOT silently hide it (the old `= nil`) and must NEVER
                // delete it — doing either could strand a paid batch, an unrecoverable loss. Instead keep
                // the file on disk and SURFACE the situation (plus a prominent log) so the operator can
                // see the batch still exists and decide what to do.
                NSLog("[ArchiveProcessor] WARNING: pending BATCH manifest failed the self-consistency check but is being PRESERVED (a paid server-side batch may still exist and must not be stranded).")
                pendingBatchInfo = "A pending batch was found but its manifest failed a self-consistency check (it may be torn or tampered). It has NOT been discarded — a paid server-side batch may still exist. The manifest was kept for recovery; review before resuming."
            }
        } else if FileManager.default.fileExists(atPath: Self.pendingBatchURL.path) {
            pendingBatchInfo = "A pending batch journal could not be read. It was kept for review. Automatic resume is unavailable."
        } else {
            pendingBatchInfo = nil
        }

        // Check for pending run (same self-consistency guard). A run manifest is local-only (no paid
        // server-side job), but the guard is still non-destructive: a rejected manifest is KEPT (never
        // deleted) so its cached results stay available and are not re-charged, and it is surfaced/logged
        // rather than silently swallowed (Finding 4 — mirror the batch fail-safe).
        if let pending = Self.loadPendingRun() {
            if Self.pendingRunIsSelfConsistent(pending) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let dateStr = formatter.string(from: pending.startedAt)
                let completed = pending.completedResults.count
                let total = pending.fileURLs.count
                pendingRunInfo = "Interrupted run from \(dateStr): \(completed)/\(total) files completed via \(Self.pendingRunRouteLabel(of: pending))."
                    + Self.pendingRunMissingNote(pending)
                pendingRunBackend = Self.pendingRunBackend(of: pending)
            } else {
                pendingRunBackend = nil
                NSLog("[ArchiveProcessor] WARNING: pending RUN manifest failed the self-consistency check but is being PRESERVED (kept on disk so its cached results are not lost/re-charged).")
                pendingRunInfo = "An interrupted run was found but its manifest failed a self-consistency check (it may be torn or tampered). It has NOT been discarded; the manifest was kept for recovery."
            }
        } else if Self.workingOutputOccupied(Self.pendingRunURL) {
            pendingRunInfo = "An interrupted run's record could not be read. Dismiss sets aside its recovery files."
            pendingRunBackend = nil
        } else {
            pendingRunInfo = nil
            pendingRunBackend = nil
        }
        #if DEBUG
        if let synthetic = ProcessorUITestConfiguration.syntheticPendingRun {
            pendingRunInfo = synthetic.info
            pendingRunBackend = synthetic.backend
        }
        #endif
        // A crash between saving the image journal and retiring the PDF journal leaves both.
        // Prefer the validated image journal once it contains this exact completed PDF set. An empty
        // batch journal could still be waiting on its first create, so keep the mixed copy until a job
        // ID is saved. The batch journal takes priority while the create outcome is unresolved.
        var mixedTransferred = false
        if let mixed = Self.loadPendingMixedPDF(), Self.pendingMixedPDFIsSelfConsistent(mixed),
           mixed.completedOutcomes.count == mixed.pdfIndices.count {
            let transferred: [MixedPDFOutcome]?
            let images = mixed.originalFiles.indices
                .filter { !Set(mixed.pdfIndices).contains($0) }
                .map { mixed.originalFiles[$0] }
            if let run = Self.loadPendingRun(), Self.pendingRunIsSelfConsistent(run),
               run.fileURLs == images {
                transferred = run.mixedPDFOutcomes
            } else if let batch = Self.loadPendingBatch(), Self.pendingBatchIsSelfConsistent(batch),
                      !batch.effectiveChunkIds.isEmpty, batch.fileURLs == images {
                transferred = batch.mixedPDFOutcomes
            } else {
                transferred = nil
            }
            mixedTransferred = transferred.map { Self.sameJournalPayload($0, mixed.completedOutcomes) } ?? false
            if mixedTransferred, Self.savedCatalogueRun() == nil {
                Self.deletePendingMixedPDF()
                activePendingMixedPDF = nil
            }
        }
        if !mixedTransferred, !FileManager.default.fileExists(atPath: Self.pendingBatchURL.path),
           FileManager.default.fileExists(atPath: Self.pendingMixedPDFURL.path) {
            if let pending = Self.loadPendingMixedPDF(), Self.pendingMixedPDFIsSelfConsistent(pending) {
                let completed = pending.completedOutcomes.count
                let total = pending.pdfIndices.count
                pendingMixedPDFInfo = mixedPDFResumeBlockReason(pending)
                    ?? "Interrupted mixed run: \(completed)/\(total) PDFs recorded; saved page results will be reused."
            } else {
                pendingMixedPDFInfo = "A mixed PDF recovery record could not be verified. It was kept for review; automatic resume is unavailable."
            }
        } else {
            pendingMixedPDFInfo = nil
        }
    }
    /// The tail every transiently-interrupted paid batch must run before its run ends (W16.bat4).
    ///
    /// A transient interruption — poll timeout, the 10-error network streak, a journal-persistence failure,
    /// a submission that stopped part-way — leaves a PAID server-side batch alive and its journal on disk,
    /// so the run must stop short of tagging/finalize but hand the operator the way back to it. Every
    /// `batchPollInterrupted` message says the batch was kept "so you can resume it", and the Resume control
    /// (`OCRView`'s "Pending Batch" box) renders only from `pendingBatchInfo`, which is written **only** by
    /// `checkForPendingBatch()` — so a path that skips this call tells the operator to press a button that
    /// is not there.
    ///
    /// Deliberately NON-destructive: it deletes no journal (`deletePendingBatch()` is exactly what must not
    /// happen while a paid job may still be running) and touches no output. The only files it removes are
    /// this run's own temporary PDF→JPEG conversions, which a resume regenerates from the original sources.
    ///
    /// Both entry points into a paid batch call this and nothing else, so the two cannot drift again: the
    /// resume path (`resumePendingBatch`, after `pollBatchUntilComplete` returns) and the first-run path
    /// (`processFiles`, after `performBatchOCR` returns — which covers all FIVE of its interrupted exits;
    /// the fifth, `guard markBatchSubmissionComplete()`, only started reporting itself in W16.bat3-fu).
    /// Pinned headlessly by `BatchInterruptTailContract` (W16.bat4).
    func finishInterruptedBatchPoll() {
        activeRunHistory = nil
        activeBatch = nil
        activePendingBatch = nil
        isProcessing = false
        cleanupTempFiles()
        checkForPendingBatch()
        if let message = monthlyStopMessage {
            monthlyStopMessage = nil
            statusMessage = message + " The provider batch is saved. Resume when more money is available."
        }
    }
    /// The first run's counterpart: retire a paid batch's recovery journal, and ONLY when the poll ran to
    /// completion (W16.bat3).
    ///
    /// `performBatchOCR` ends here, and this is the *destructive* half of the interruption decision — the
    /// journal is a live server-side job's only local record, so an interrupted poll must leave it on disk
    /// for the Resume control to find. Extracted from the inline `if` it used to be purely so that direction
    /// can be DRIVEN against a real journal file (`BatchPollCancelContract`, section 17) rather than read:
    /// the surrounding function needs a paid submission to reach, so nothing could call it before.
    /// Behaviour is unchanged — same condition, same two statements, same order.
    func retirePaidBatchJournalIfPollCompleted() {
        guard catalogueRun == nil else { return }
        guard !batchPollInterrupted else { return }
        Self.deletePendingBatch()
        activePendingBatch = nil
    }
    /// Dismiss stops local recovery. The provider can still run and charge for a submitted batch.
    func dismissPendingBatch() {
        guard !isProcessing else { return }
        do {
            let lease = try ProcessorCatalogueRun.Lease(journal: Self.pendingCatalogueURL)
            defer { withExtendedLifetime(lease) {} }
            if try !setAsideCatalogueRecovery(requestedJournal: Self.pendingBatchURL) { Self.deletePendingBatch() }
            activePendingBatch = nil
            checkForPendingBatch()
        } catch {
            statusMessage = "The batch recovery files are still active. \(error.localizedDescription)"
        }
    }
    /// W49.proc-resume-standard-runs: a resume reads the run's own file list, so a page moved, renamed or deleted since
    /// is not found. Said in the Interrupted Run box before Resume, rather than discovered as failures afterwards.
    /// Files added to the folder since are not part of the run and are not mentioned.
    nonisolated static func pendingRunMissingNote(_ pending: PendingRun) -> String {
        let fm = FileManager.default
        let missing = remainingIndices(totalFiles: pending.fileURLs.count, completedResults: pending.completedResults)
            .filter { !fm.fileExists(atPath: pending.fileURLs[$0].path) }.count
        guard missing > 0 else { return "" }
        let noun = missing == 1 ? "file" : "files"
        return " \(missing) \(noun) not yet read \(missing == 1 ? "is" : "are") no longer where the run found "
            + "\(missing == 1 ? "it" : "them"): put \(missing == 1 ? "it" : "them") back before resuming, or "
            + "\(missing == 1 ? "it fails" : "they fail") without being sent."
    }
    /// Dismiss a pending run notification.
    func dismissPendingRun() {
        guard !isProcessing else { return }
        do {
            let lease = try ProcessorCatalogueRun.Lease(journal: Self.pendingCatalogueURL)
            defer { withExtendedLifetime(lease) {} }
            if try !setAsideCatalogueRecovery(requestedJournal: Self.pendingRunURL) { Self.deletePendingRun() }
            activePendingRun = nil
            checkForPendingBatch()
        } catch {
            statusMessage = "The run recovery files are still active. \(error.localizedDescription)"
        }
    }

    /// The lease couples the working plan to its input journals. Copy and flush the entire set
    /// before releasing its active names. The private working directory stays with the saved plan.
    func setAsideCatalogueRecovery(requestedJournal: URL) throws -> Bool {
        let journal = Self.pendingCatalogueURL
        guard Self.workingOutputOccupied(journal) else { return false }
        let inputs = [Self.pendingRunURL, Self.pendingBatchURL, Self.pendingMixedPDFURL]
            .filter(Self.workingOutputOccupied)
        if !inputs.isEmpty, inputs != [requestedJournal] {
            guard let run = Self.savedCatalogueRun() else { throw CocoaError(.fileReadCorruptFile) }
            let expected = try run.files == nil ? catalogueInputJournalDigests(for: run, completed: false)
                : run.inputJournalDigests ?? [:]
            for input in inputs {
                guard let digest = expected[input.lastPathComponent], Self.mixedPDFSourceDigest(input) == digest else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        let recovery = journal.deletingLastPathComponent()
            .appendingPathComponent("catalogue-recovery-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: recovery, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        for file in [journal] + inputs {
            guard (try? fm.destinationOfSymbolicLink(atPath: file.path)) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let contents = try Data(contentsOf: file)
            let archived = recovery.appendingPathComponent(file.lastPathComponent)
            try contents.write(to: archived, options: .withoutOverwriting)
            try ProcessorCatalogueRun.flushFileAndParent(archived)
        }
        try ProcessorCatalogueRun.flushFileAndParent(journal)
        for input in inputs { try fm.removeItem(at: input) }
        try ProcessorCatalogueRun.flushFileAndParent(journal)
        try fm.removeItem(at: journal)
        catalogueRun = nil
        activePendingRun = nil
        activePendingBatch = nil
        activePendingMixedPDF = nil
        statusMessage = "Catalogue recovery records kept in \(recovery.path)."
        return true
    }

    /// Resume polling a previously submitted batch.
    func resumeBatch(apiKey: String) async {
        // Ignore a torn/tampered manifest rather than misapply it (Tier-2 rule e).
        guard let pending = Self.loadPendingBatch(), Self.pendingBatchIsSelfConsistent(pending) else { return }

        let paid = processPaidRequests(runID: pending.resolvedSettings?.runID, outputDirectory: pending.outputDirectory)
        await paid.run(denyDataCollection: OpenRouterDataPolicy.deny(pending.resolvedSettings?.values)) {
            await resumeBatch(pending, apiKey: apiKey)
        }
    }

    private func resumeBatch(_ savedBatch: PendingBatch, apiKey: String) async {
        var pending = savedBatch
        guard SearchableArchival.isAvailable,
              await beginCatalogueRun(outputRoot: pending.outputDirectory,
                                sources: Self.mixedInputURLs(images: pending.fileURLs, pdfs: pending.mixedPDFOutcomes) ?? pending.fileURLs,
                                resuming: true, keepPreservationCopies: pending.resolvedSettings?.run?.keepPreservationCopies,
                                confirmResume: {
            guard let current = Self.loadPendingBatch(), Self.pendingBatchIsSelfConsistent(current) else { return false }
            if let savedFingerprint = savedBatch.lifecycleFingerprint {
                return current.lifecycleFingerprint == savedFingerprint
            }
            return Self.sameJournalPayload(current, savedBatch)
        }) else { return }
        defer { catalogueRunLease = nil }

        // A journal can be internally valid even if an operator later removed one of its output PDFs.
        // Re-open all consumed chunks in that case, retain the still-present per-file associations, and
        // re-fetch results so only the missing outputs are materialized again. This is a GET-only recovery;
        // it never submits another paid batch job.
        if pending.lifecycleVersion == PendingBatch.currentLifecycleVersion {
            let reopened = Self.batchByReopeningMissingOutputs(
                pending, fileExists: { FileManager.default.fileExists(atPath: $0) })
            if reopened.completedResults.count != pending.completedResults.count {
                guard let repaired = Self.savePendingBatch(reopened) else {
                    statusMessage = "Missing batch outputs were found, but recovery state could not be saved. Nothing was re-fetched."
                    isProcessing = false
                    return
                }
                pending = repaired
            }
            guard !pending.effectiveChunkIds.isEmpty else {
                statusMessage = "This interrupted submission has no recoverable server ID. Its journal was kept for manual review; retrying automatically could duplicate a paid job."
                isProcessing = false
                checkForPendingBatch()
                return
            }
        }

        isProcessing = true
        paidRequestScope = PaidRequests.context
        pendingBatchInfo = nil
        failedFiles = [:]
        clearOutputWarnings()
        segments = []
        appliedGeneratedTags = [:]
        enclosureDateReviews = [:]
        collectionSegments = []
        outputURLMap = [:]
        deferredOutputs = [:]
        defersOutputWrites = false
        _takenOutputPaths = []
        exportedImageMap = [:]
        outputSubfolders = pending.outputSubfolders ?? [:]   // W47.ct-processor-intake
        removedSourceURLs = []
        enclosureCoverChoices = pending.enclosureCovers ?? [:]   // W49.proc-s047-cover-select: kept for the run's life
        currentModel = pending.model
        // The run's own frozen settings, not the last started run's: the PDFs it still writes read them
        // (W42.int-s5 `textLayerOptions`, the dating route's switch). nil (a run recorded before them) is the defaults.
        activeResolvedSettings = pending.resolvedSettings
        activePostCorrection = nil
        let runConfig = makePendingBatchResumeConfig(pending, apiKey: apiKey)
        applyResumeConfig(runConfig)
        activeRunConfig = runConfig
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
        // Jobs carry the ORIGINAL source URLs (correct output names + tag targets). For PDF inputs the
        // persisted temp JPEGs are long gone, so regenerate them from the originals — exactly like
        // resumeRun — and feed the temp images (not the .pdf) to the result/PDF-embed + retry paths.
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        restoreMixedPDFAssociations(pending.mixedPDFOutcomes)
        var restoredFullJobs = false
        defer {
            if !restoredFullJobs { restoreMixedPDFJobs(pending.mixedPDFOutcomes) }
            progressRange = nil
        }
        if let pdfs = pending.mixedPDFOutcomes {
            progressRange = (start: Double(pdfs.count) / Double(pending.fileURLs.count + pdfs.count),
                             span: Double(pending.fileURLs.count) / Double(pending.fileURLs.count + pdfs.count))
        } else { progressRange = nil }
        let imageURLs = convertPDFInputs(pending.fileURLs)
        for i in jobs.indices { jobs[i].status = .processing }

        // Restore already-materialized files before polling. Their exact source→output associations are
        // reused verbatim; processBatchResults also skips these indices if it re-fetches an open chunk.
        let restoredOutputs = Self.resolveResumeOutputURLs(
            completedResults: pending.completedResults,
            completedOutputPaths: pending.completedOutputPaths,
            sourceURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory,
            alreadyTaken: _takenOutputPaths)
        for (key, result) in pending.completedResults {
            guard let index = Int(key), jobs.indices.contains(index) else { continue }
            jobs[index].result = result
            jobs[index].classification = result.classification
            jobs[index].status = result.text == nil ? .failed : .succeeded
            if result.text == nil {
                recordFileFailure(for: jobs[index].sourceURL, result: result)
            }
            if let previous = restoredOutputs[index], FileManager.default.fileExists(atPath: previous.path) {
                let outputURL = catalogueResumeOutput(previous, for: jobs[index].sourceURL, in: pending.outputDirectory)
                guard FileManager.default.fileExists(atPath: outputURL.path) else {
                    isProcessing = false
                    checkForPendingBatch()
                    statusMessage = "A saved batch output could not be copied to working storage. The batch record is preserved."
                    return
                }
                outputURLMap[jobs[index].sourceURL] = outputURL
                _takenOutputPaths.insert(outputURL.standardizedFileURL.path.lowercased())
            }
        }
        progress = 0
        statusMessage = "Resuming batch…"

        // History snapshot for the resumed batch (see RunHistorySnapshot.init(resuming batch:…)).
        activeRunHistory = RunHistorySnapshot(
            resuming: pending, rotationMode: runConfig.rotationMode, imageScale: runConfig.imageScale)
        activeRunHistory?.sidecars = true

        beginMonthlySpend(outputDirectory: pending.outputDirectory)

        activeBatch = BatchContext(
            batchId: pending.batchId, apiKey: apiKey,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            provider: pending.provider
        )
        activePendingBatch = pending

        if let links = pending.paidRequestLinks, let paidRequestScope {
            do {
                for (jobID, attemptID) in links {
                    try paidRequestScope.store.linkPaidBatch(attemptID: attemptID, provider: pending.provider,
                                                              jobID: jobID, runID: paidRequestScope.runID)
                }
            } catch {
                statusMessage = "The paid request journal could not be updated. The provider batch was kept for Resume."
                finishInterruptedBatchPoll()
                return
            }
        }

        await pollBatchUntilComplete(
            batchId: pending.batchId, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, fileURLs: imageURLs,
            outputDirectory: pending.outputDirectory, runConfig: runConfig
        )

        // A transient interruption (network streak / timeout) leaves the batch resumable — don't delete
        // the pending batch or continue into tagging/finalize on incomplete results; let the user Resume.
        // Reset isProcessing + re-surface the pending-batch banner (mirrors startProcessing) so the UI
        // isn't wedged with every Start/Resume button disabled until relaunch.
        if batchPollInterrupted {
            finishInterruptedBatchPoll()
            return
        }
        activeBatch = nil
        guard !Task.isCancelled else { return }
        if monthlySpend == nil, !pending.usesWindowSegmentation {
            retirePaidBatchJournalIfPollCompleted()
        }

        await retryHighUseFailures(
            fileURLs: imageURLs, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled, !stopIfMonthlyReadDeclined() else { return }

        await retryLoopForFailedFiles(
            imageURLs: imageURLs,
            outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled else { return }

        // The shared stages after OCR (W49.proc-unified-pipeline-1), in the batch's persisted tagging mode, so a batch
        // submitted in Human / Auto-date / manual-seg mode isn't silently downgraded to automatic tagging after a
        // relaunch (and .none/.copySource correctly skip LLM tagging).
        let plan = PostOCRPlan(
            origin: .resumedBatch, files: pending.fileURLs, outputDirectory: pending.outputDirectory,
            runConfig: runConfig, settings: pending.resolvedSettings,
            text: .init(provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                        apiKey: apiKey),
            enableTagging: pending.enableTagging, enableSegmentJSON: pending.enableSegmentJSON,
            enableCollectionSegmentation: pending.enableCollectionSegmentation,
            confirmCollectionIDs: pending.confirmCollectionIDs,
            reviewWholeRun: pending.reviewWholeRun ?? true, reviewRotation: false,
            // A batch journal keeps no phone groups, so groups still in memory belong to another run.
            phoneGroupsApply: false)
        guard await runPostOCRStages(plan) else { return }

        guard !Task.isCancelled else { return }
        restoreMixedPDFJobs(pending.mixedPDFOutcomes)
        restoredFullJobs = true
        progressRange = nil
        await completeRun(RunCompletion(
            outputDirectory: pending.outputDirectory, enableTagging: pending.enableTagging,
            enableCollectionSegmentation: pending.enableCollectionSegmentation,
            preOCRed: false,   // a batch run never has pre-OCRed input
            exportingImages: runOutputSettings.exportOriginals, stampsUnread: runOutputSettings.stampUnread))
    }
    /// Resume an interrupted non-batch run.
    /// `readWithoutClusterText` is the operator's answer to `institutionalComputeResumePrompt`: read the pages of a
    /// run whose cluster folder is gone with the run's model.
    func resumeRun(apiKey: String, readWithoutClusterText: Bool = false) async {
        guard !isProcessing else { return }
        if let run = Self.savedCatalogueRun(), run.files != nil {
            isProcessing = true
            defer { isProcessing = false }
            do {
                let lease = try ProcessorCatalogueRun.Lease(journal: Self.pendingCatalogueURL)
                defer { withExtendedLifetime(lease) {} }
                guard let live = Self.savedCatalogueRun(), live.workingRoot == run.workingRoot else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                _ = try await completeCatalogueRun(live)
                pendingRunInfo = nil
                pendingRunBackend = nil
                statusMessage = "Recovered catalogue filing for \(run.files?.count ?? 0) PDFs." + catalogueFilingWarning
            } catch {
                statusMessage = "Catalogue filing could not be recovered. Working files remain saved. \(error.localizedDescription)"
            }
            return
        }
        // Ignore a torn/tampered manifest rather than misapply it (Tier-2 rule e). `resumeRun` replays
        // the manifest's OWN persisted input set + output dir (never the current UI selection), so a
        // stale manifest can never cross-contaminate a different job.
        guard let pending = Self.loadPendingRun(), Self.pendingRunIsSelfConsistent(pending) else { return }

        let paid = processPaidRequests(runID: pending.resolvedSettings?.runID, outputDirectory: pending.outputDirectory)
        await paid.run(denyDataCollection: OpenRouterDataPolicy.deny(pending.resolvedSettings?.values)) {
            await resumeRun(pending, apiKey: apiKey, readWithoutClusterText: readWithoutClusterText)
        }
    }

    private func resumeRun(_ pending: PendingRun, apiKey: String, readWithoutClusterText: Bool) async {
        if pending.provider == .openrouter, pending.gatewayConfig == nil, pending.localAgent == nil,
           pending.completedResults.count < pending.fileURLs.count || pending.enableTagging
               || pending.enableCollectionSegmentation,
           let warning = OpenRouterRoute.unavailableSelection(pending.model.id) {
            statusMessage = warning + Self.unavailableModelRecoveryNote
            return
        }
        var runConfig = makePendingRunResumeConfig(pending, apiKey: apiKey)
        runConfig.localAgent?.requiresSubscription = SettingsLayerStore.shared.resolver(at: pending.outputDirectory)
            .monthlyLimitUSD != nil
        if let folder = pending.runtimeConfig?.institutionalComputeFolder {
            do {
                runConfig.institutionalComputeImport = try await reloadInstitutionalComputeImport(folder)
            } catch { return }
            guard !Task.isCancelled else { return }
        }

        let resumeClassifies = (pending.enableTagging && runConfig.taggingMode != .copySource)
            || runConfig.mergeDocuments || pending.enableCollectionSegmentation
        runConfig.institutionalComputeImport?.classifyPages = resumeClassifies

        // W40.fix-processor-instcompute-resume-silent: ask before changing the saved run.
        if !readWithoutClusterText, let prompt = Self.institutionalComputeResumePrompt(
            recordedFolder: pending.runtimeConfig?.institutionalComputeFolder,
            reloaded: runConfig.institutionalComputeImport,
            remainingPages: Self.remainingIndices(totalFiles: pending.fileURLs.count,
                                                  completedResults: pending.completedResults).count,
            model: pending.model.displayName) {
            // A resume in another window can update or dismiss the journal during the scan.
            guard Self.loadPendingRun()?.runFingerprint == pending.runFingerprint else {
                checkForPendingBatch()
                return
            }
            institutionalComputeResumePrompt = prompt
            return
        }
        institutionalComputeResumePrompt = nil
        guard SearchableArchival.isAvailable,
              await beginCatalogueRun(outputRoot: pending.outputDirectory,
                                sources: Self.mixedInputURLs(images: pending.fileURLs, pdfs: pending.mixedPDFOutcomes) ?? pending.fileURLs,
                                resuming: true, keepPreservationCopies: pending.runtimeConfig?.keepPreservationCopies,
                                confirmResume: {
            guard let current = Self.loadPendingRun(), Self.pendingRunIsSelfConsistent(current) else { return false }
            if pending.runtimeConfig != nil && pending.runFingerprint != nil { return current.runFingerprint == pending.runFingerprint }
            return Self.sameJournalPayload(current, pending)
        }) else { return }
        defer { catalogueRunLease = nil }

        isProcessing = true
        paidRequestScope = PaidRequests.context
        pendingRunInfo = nil
        failedFiles = [:]
        clearOutputWarnings()
        segments = []
        appliedGeneratedTags = [:]
        enclosureDateReviews = [:]
        collectionSegments = []
        outputURLMap = [:]
        deferredOutputs = [:]
        defersOutputWrites = false
        _takenOutputPaths = []
        exportedImageMap = [:]
        pdfToImageMap = [:]
        outputSubfolders = pending.runtimeConfig?.outputSubfolders ?? [:]   // W47.ct-processor-intake
        currentModel = pending.model
        // The run's own frozen settings, not the last started run's: the PDFs it still writes read them
        // (W42.int-s5 `textLayerOptions`, the dating route's switch). nil (a run recorded before them) is the defaults.
        activeResolvedSettings = pending.resolvedSettings
        currentGateway = pending.gatewayConfig
        currentLocalAgent = runConfig.localAgent
        activeRunConfig = runConfig
        activePostCorrection = Self.makePostCorrection(
            requested: pending.runtimeConfig?.postCorrection == true,
            gateway: pending.gatewayConfig, localAgent: pending.localAgent, outputDirectory: pending.outputDirectory,
            frozen: pending.resolvedSettings?.values)
        let resumeGatewayUpstream: LLMProvider
        if let config = pending.runtimeConfig {
            // V2: replay the immutable start-time snapshot. Self-consistency above has already validated
            // its version, ranges, parallel-array alignment, and identity fingerprint.
            applyPendingRunSnapshot(config)
            resumeGatewayUpstream = config.gatewayUpstreamProvider ?? .anthropic
        } else {
            // Legacy manifests did not record these settings, so preserve their historical live-setting
            // fallback. There is no honest way to reconstruct the values that were active before relaunch.
            applyResumeConfig(runConfig)
            resumeGatewayUpstream = Self.gatewayUpstreamProviderFromDefaults()
        }
        let resumeImageScale = runConfig.imageScale
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
        // Resume keeps the OCR backend pinned in `pending`, while post-OCR text work remains pinned
        // in the runtime snapshot. These never feed an image request below.
        let textProvider = runConfig.textProvider
        let textModel = runConfig.textModel
        let textThinkingLevel = runConfig.textThinkingLevel
        let textAPIKey = runConfig.textAPIKey
        removedSourceURLs = []
        enclosureCoverChoices = pending.enclosureCovers ?? [:]   // W49.proc-s047-cover-select: kept for the run's life
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        restoreMixedPDFAssociations(pending.mixedPDFOutcomes)
        var restoredFullJobs = false
        defer {
            if !restoredFullJobs { restoreMixedPDFJobs(pending.mixedPDFOutcomes) }
            progressRange = nil
        }
        if let pdfs = pending.mixedPDFOutcomes {
            progressRange = (start: Double(pdfs.count) / Double(pending.fileURLs.count + pdfs.count),
                             span: Double(pending.fileURLs.count) / Double(pending.fileURLs.count + pdfs.count))
        } else { progressRange = nil }
        progress = 0

        // Restore the pending run tracker for incremental saves
        activePendingRun = pending
        // As on a fresh run, the outputs wait for the reviews (W49.proc-unified-pipeline-2). A pre-OCRed run has none.
        defersOutputWrites = !pending.preOCRedInput

        // History uses the same restored values as the resumed pipeline (legacy runs use the fallback above).
        activeRunHistory = RunHistorySnapshot(
            resuming: pending, taggingMode: taggingMode, rotationMode: rotationMode,
            imageScale: resumeImageScale,
            imageTokenProvider: resumeGatewayUpstream)
        activeRunHistory?.sidecars = pending.enableSegmentJSON || !pending.preOCRedInput

        beginMonthlySpend(outputDirectory: pending.outputDirectory, pricedImages: pending.completedResults.count)
        let pricedModel = activeRunHistory?.visionTextModel ?? pending.model
        if monthlySpend != nil, !pending.preOCRedInput || activeRunHistory?.classifyPreOCRedInput == true {
            let billing = await ClaudeCLIUsage.shared.refresh(config: pending.localAgent)
            guard !Task.isCancelled else { return }
            if !ProcessFilesMonthlySpend.hasPrice(model: pricedModel, gateway: pending.gatewayConfig,
                                                  localAgent: pending.localAgent, claudeBilling: billing) {
                guard reserveMonthlySpend(nil, for: "this reader") else { return }
            }
        }

        let segmentationContext = SegmentationContext(
            previousTextCharCount: pending.previousTextCharCount,
            sendPreviousImage: pending.sendPreviousImage,
            customPrompt: pending.customPrompt,
            imageScale: resumeImageScale
        )

        // Convert any PDF inputs
        let imageURLs = convertPDFInputs(pending.fileURLs)

        // Restore already-completed results. The original run already wrote these PDFs, so reuse
        // them when present and only regenerate genuinely-missing ones — off the main actor, since
        // embedding full-resolution images is heavy (this was causing a beachball on resume).
        let completedCount = pending.completedResults.count
        if completedCount > 0 {
            statusMessage = "Restoring \(completedCount) previously completed results…"
            let fm = FileManager.default
            // Gather on the main actor.
            var restores: [(index: Int, result: OCRResult, sourceURL: URL, outputURL: URL)] = []
            var toGenerate: [(imageURL: URL, outputURL: URL, fileName: String, result: OCRResult)] = []
            // Resolve each completed index to the SAME output PDF the original pass assigned it. The
            // original pass assigns paths in COMPLETION order (via uniqueOutputURL) and persists the exact
            // path per index in `completedOutputPaths`; `resolveResumeOutputURLs` reuses those verbatim (the
            // B7 fix) and only re-derives in index order for legacy manifests lacking the map. Factored out
            // so this restore and the headless self-test share ONE association-preserving definition.
            let resolvedOutputs = Self.resolveResumeOutputURLs(
                completedResults: pending.completedResults,
                completedOutputPaths: pending.completedOutputPaths,
                sourceURLs: jobs.map { $0.sourceURL },
                outputDirectory: pending.outputDirectory,
                alreadyTaken: _takenOutputPaths)
            for (key, result) in pending.completedResults.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
                guard let index = Int(key), index < jobs.count, index < imageURLs.count,
                      let previous = resolvedOutputs[index] else { continue }
                let sourceURL = jobs[index].sourceURL
                let outputURL = catalogueResumeOutput(previous, for: sourceURL, in: pending.outputDirectory)
                restores.append((index, result, sourceURL, outputURL))
                if !fm.fileExists(atPath: outputURL.path) {
                    toGenerate.append((imageURLs[index], outputURL, sourceURL.lastPathComponent, result))
                }
            }
            // Regenerate only missing PDFs, off the main thread. Track failures so we don't
            // populate outputURLMap with phantom entries pointing at nonexistent files (M2 fix).
            var failedRegenURLs = Set<URL>()
            if defersOutputWrites {
                // Held back like the readings still to come, and written once after the reviews.
                let pdfSettings = Self.pdfGenerationSettings(for: runConfig)
                let missing = Dictionary(toGenerate.map { ($0.outputURL, $0.imageURL) }, uniquingKeysWith: { first, _ in first })
                for r in restores {
                    guard let imageURL = missing[r.outputURL] else { continue }
                    deferredOutputs[r.outputURL] = DeferredOutput(request: OutputWriteRequest(
                        imageURL: imageURL, source: r.sourceURL, outputURL: r.outputURL, result: r.result,
                        model: pending.model, gatewayName: currentGateway?.displayName,
                        localAgentDisplayName: currentLocalAgent?.provenanceDisplayName,
                        localAgentModelName: currentLocalAgent?.provenanceModelName,
                        pdfImageMB: pdfSettings.imageMB, textColumns: pdfSettings.textColumns,
                        textLayer: textLayerOptions, copySourceTags: passSourceTags,
                        catalogueIdentity: catalogueWriteIdentity(for: r.outputURL)))
                }
            } else if !toGenerate.isEmpty {
                let model = pending.model
                let gatewayName = currentGateway?.displayName
                let localAgentDisplayName = currentLocalAgent?.provenanceDisplayName
                let localAgentModelName = currentLocalAgent?.provenanceModelName
                let pdfSettings = Self.pdfGenerationSettings(for: runConfig)
                let pdfMB = pdfSettings.imageMB
                let txtCols = pdfSettings.textColumns
                statusMessage = "Rebuilding \(toGenerate.count) missing PDF\(toGenerate.count == 1 ? "" : "s")…"
                // W23.h5-fu — carry each regenerated PDF's image-page verdict back too, so a rebuilt
                // output that could not embed its scan is reported instead of counting as a clean redo.
                let layerOptions = textLayerOptions
                let identities = Dictionary(toGenerate.compactMap { g in catalogueWriteIdentity(for: g.outputURL).map { (g.outputURL, $0) } },
                                            uniquingKeysWith: { first, _ in first })
                let regen: (failed: Set<URL>, placeholders: Set<URL>) = await PDFGenerator.runWorker(priority: .utility) { [toGenerate] in
                    let gen = PDFGenerator()
                    var failed = Set<URL>()
                    var placeholders = Set<URL>()
                    for g in toGenerate {
                        guard !Task.isCancelled else { break }
                        do {
                            let outcome = try gen.generateOutput(imageURL: g.imageURL, result: g.result, model: model,
                                              outputURL: g.outputURL, originalFileName: g.fileName,
                                              gatewayDisplayName: gatewayName,
                                              localAgentDisplayName: localAgentDisplayName,
                                              localAgentModelName: localAgentModelName,
                                              pdfImageMB: pdfMB, textColumns: txtCols, textLayer: layerOptions,
                                              sourceFormat: OutputForm.format(ofExtension: (g.fileName as NSString).pathExtension),
                                              catalogueIdentity: identities[g.outputURL]).imagePage
                            if outcome.isPlaceholder { placeholders.insert(g.outputURL) }
                        } catch {
                            failed.insert(g.outputURL)
                        }
                    }
                    return (failed, placeholders)
                }
                guard !Task.isCancelled else { return }
                failedRegenURLs = regen.failed
                for r in restores where regen.placeholders.contains(r.outputURL) {
                    recordImagePage(.placeholder, forSource: r.sourceURL)
                }
            }
            // Apply the (cheap) state updates back on the main actor.
            for r in restores {
                jobs[r.index].result = r.result
                jobs[r.index].classification = r.result.classification
                jobs[r.index].status = r.result.text != nil ? .succeeded : .failed
                if r.result.text == nil { recordFileFailure(for: r.sourceURL, result: r.result) }
                // Only populate outputURLMap when the PDF actually exists on disk (already
                // present or successfully regenerated). Skipping prevents phantom entries.
                if !failedRegenURLs.contains(r.outputURL) {
                    outputURLMap[r.sourceURL] = r.outputURL
                    if passSourceTags {
                        if let sourceTags = try? MacOSTagger.readTags(from: r.sourceURL), !sourceTags.isEmpty {
                            // Copy-source pass-through on resume: verbatim, label untouched.
                            tagOutput(sourceTags, at: r.outputURL, source: r.sourceURL, stampUnread: false)
                            jobs[r.index].appliedTags = sourceTags
                        }
                    }
                }
            }
            let total = pending.fileURLs.count
            progress = Double(completedCount) / Double(total) * 0.7
            statusMessage = "Restored \(completedCount)/\(total). Resuming OCR…"
        }


        // Run OCR only on files that were NOT already completed — the anti-double-cost guarantee: a file
        // whose result is cached in the manifest is never re-OCR'd (Tier-2 rule a). Its output PDF is
        // regenerated above from the cached result only when missing on disk, never re-charged.
        let remainingIndices = Self.remainingIndices(
            totalFiles: pending.fileURLs.count, completedResults: pending.completedResults)

        if !remainingIndices.isEmpty {
            if pending.preOCRedInput {
                guard reserveMonthlySpend(activeRunHistory?.estimatedCost ?? 0, for: "processing these PDFs") else { return }
                // For pre-OCRed, run the full pipeline (it's text extraction + classification, cheap)
                await performPreOCRedProcessing(
                    files: pending.fileURLs,
                    provider: textProvider,
                    model: textModel,
                    thinkingLevel: textThinkingLevel,
                    apiKey: textAPIKey,
                    outputDirectory: pending.outputDirectory,
                    enableTagging: pending.enableTagging,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    enableCollectionSegmentation: pending.enableCollectionSegmentation,
                    confirmCollectionIDs: pending.confirmCollectionIDs,
                    reviewWholeRun: pending.reviewWholeRun ?? true,
                    customPrompt: pending.customPrompt,
                    runConfig: runConfig,
                    settings: pending.resolvedSettings
                )
                // Pre-OCRed path handles its own post-processing; skip to finalization
                guard !Task.isCancelled, isProcessing else { return }
                await completeRun(RunCompletion(
                    outputDirectory: pending.outputDirectory, enableTagging: pending.enableTagging,
                    enableCollectionSegmentation: pending.enableCollectionSegmentation, preOCRed: true,
                    exportingImages: false, stampsUnread: runOutputSettings.stampUnread, clearsPendingRun: true))
                return
            }

            // Resume OCR for remaining files
            await performOCRPhaseForIndices(
                indices: remainingIndices,
                fileURLs: imageURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                segmentationContext: segmentationContext,
                totalFiles: pending.fileURLs.count,
                alreadyCompleted: completedCount,
                runConfig: runConfig
            )
        }

        guard !Task.isCancelled, isProcessing else { cleanupTempFiles(); return }

        // Retry high-use failures
        await retryHighUseFailures(
            fileURLs: imageURLs,
            provider: pending.provider,
            model: pending.model,
            thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey,
            outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled, isProcessing, !stopIfMonthlyReadDeclined() else { cleanupTempFiles(); return }

        // Interactive retry
        await retryLoopForFailedFiles(
            imageURLs: imageURLs,
            outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled, isProcessing else { cleanupTempFiles(); return }

        // The shared stages after OCR (W49.proc-unified-pipeline-1), in the run's own tagging mode — not always
        // automatic. Tagging answers the manifest kept are reused (`taggingProgress`).
        let plan = PostOCRPlan(
            origin: .resumedRun, files: pending.fileURLs, outputDirectory: pending.outputDirectory,
            runConfig: runConfig, settings: pending.resolvedSettings,
            text: .init(provider: textProvider, model: textModel, thinkingLevel: textThinkingLevel, apiKey: textAPIKey),
            enableTagging: pending.enableTagging, enableSegmentJSON: pending.enableSegmentJSON,
            enableCollectionSegmentation: pending.enableCollectionSegmentation,
            confirmCollectionIDs: pending.confirmCollectionIDs,
            reviewWholeRun: pending.reviewWholeRun ?? true, reviewRotation: false, phoneGroupsApply: true)
        guard await runPostOCRStages(plan) else { return }

        guard !Task.isCancelled else { return }
        restoreMixedPDFJobs(pending.mixedPDFOutcomes)
        restoredFullJobs = true
        progressRange = nil
        await completeRun(RunCompletion(
            outputDirectory: pending.outputDirectory, enableTagging: pending.enableTagging,
            enableCollectionSegmentation: pending.enableCollectionSegmentation, preOCRed: pending.preOCRedInput,
            exportingImages: runOutputSettings.exportOriginals, stampsUnread: runOutputSettings.stampUnread))
    }
    /// OCR only specific file indices (for resuming interrupted runs).
    private func performOCRPhaseForIndices(
        indices: [Int],
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext,
        totalFiles: Int,
        alreadyCompleted: Int,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        let pass = beginDrainablePass()
        defer { endDrainablePass(pass) }   // W49.proc-resume-standard-runs
        guard !stopForUnavailableOpenRouterModel(provider: provider, model: model) else { return }
        let remaining = indices.count
        let gateway = currentGateway
        let localAgent = currentLocalAgent
        let ocrRun = Self.ocrCallValues(for: runConfig)
        let scanDetector = NewspaperDetector.scans(activeResolvedSettings?.values)
        let newspaperSpend = activeRunHistory?.newspaperSpend
        let postCorrection = newspaperSpend == nil ? nil : activePostCorrection
        let visionTextLLM = provider == .appleVision ? runConfig?.visionTextLLM : nil

        if segmentationContext.previousTextCharCount == 0 {
            // Parallel: OCR only the remaining indices
            var completed = 0
            let concurrency = model.provider == .appleVision
                ? VisionClient.recommendedConcurrency : Self.schedulingWorkerCount(for: runConfig, gateway: gateway)
            for i in indices { jobs[i].status = .processing }
            // W16.bat10 — the identity of every slot this resume is for, snapshotted before the group can
            // suspend; the refill site below runs after a `handleOCRResult` that may have awaited a detached
            // PDF write, so re-reading the live `jobs` there could subscript an array that Clear emptied.
            // Parallel to `indices`, so a slot number resolves both without an optional to unwrap.
            let jobIDs: [OCRJob.ID] = indices.map { jobs[$0].id }
            let splitLocalLane = provider == .appleVision && gateway == nil && localAgent == nil && !ocrRun.readers.isEmpty
            var primarySlots: [Int] = []
            var localSlots: [Int] = []
            primarySlots.reserveCapacity(remaining)
            for slot in 0..<remaining {
                if splitLocalLane && ocrRun.readers.routesToLocal(fileURLs[indices[slot]], runProvider: provider, runModelID: model.id) {
                    localSlots.append(slot)
                } else {
                    primarySlots.append(slot)
                }
            }
            statusMessage = "OCR 0/\(remaining) remaining… (parallel)"

            await withTaskGroup(of: (Int, OCRJob.ID, OCRResult, Bool).self) { group in
                var nextPrimary = 0
                var nextLocal = 0

                @MainActor func enqueue(slot: Int, isLocalLane: Bool) -> Bool {
                    let index = indices[slot]
                    let url = fileURLs[index]
                    guard reserveMonthlyImage(url, runConfig: runConfig) else { return false }
                    let jobID = jobIDs[slot]
                    let prevImageURL = (segmentationContext.sendPreviousImage && index > 0) ? fileURLs[index - 1] : nil
                    let scale = segmentationContext.imageScale
                    group.addTask {
                        let ocrResult = await Self.performOCRCall(
                            imageURL: url, provider: provider, model: model,
                            thinkingLevel: thinkingLevel, apiKey: apiKey,
                            previousText: nil, previousImageURL: prevImageURL,
                            customPrompt: segmentationContext.customPrompt,
                            imageScale: scale,
                            gatewayConfig: gateway, localAgent: localAgent,
                            rotationMode: ocrRun.rotationMode,
                            standardImageMB: ocrRun.standardImageMB,
                            visionSettings: ocrRun.visionSettings, cascade: ocrRun.cascade, readers: ocrRun.readers, imported: ocrRun.imported, newspaperSpend: newspaperSpend,
                            scanDetector: scanDetector, postCorrection: postCorrection
                        )
                        let result = await Self.applyingVisionTextClassification(
                            to: ocrResult, previousText: nil,
                            customPrompt: segmentationContext.customPrompt,
                            configuration: visionTextLLM)
                        return (index, jobID, result, isLocalLane)
                    }
                    return true
                }

                while nextPrimary < min(concurrency, primarySlots.count) {
                    guard enqueue(slot: primarySlots[nextPrimary], isLocalLane: false) else { break }
                    nextPrimary += 1
                }
                if nextLocal < localSlots.count {
                    if enqueue(slot: localSlots[nextLocal], isLocalLane: true) { nextLocal += 1 }
                }

                for await (index, jobID, result, isLocalLane) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if result.errorCode == OpenRouterRoute.unavailableModelCode,
                       stopForUnavailableOpenRouterModel(provider: provider, model: model, knownUnavailable: true) { continue }
                    if monthlyStopMessage != nil, result.text == nil { continue }
                    guard await handleOCRResult(
                        result, index: index, jobID: jobID, url: fileURLs[index], model: model,
                        outputDirectory: outputDirectory, runConfig: runConfig) else {
                        group.cancelAll()
                        return
                    }
                    completed += 1
                    progress = Double(alreadyCompleted + completed) / Double(totalFiles) * 0.7
                    statusMessage = "OCR \(alreadyCompleted + completed)/\(totalFiles) complete (parallel)" + Self.rateLimitSuffix

                    if nextPrimary < primarySlots.count || nextLocal < localSlots.count {
                        stopForUnavailableOpenRouterModel(provider: provider, model: model)
                    }
                    if drainingPages {
                        statusMessage = pageDrainMessage
                    } else if isLocalLane {
                        if nextLocal < localSlots.count {
                            let slot = localSlots[nextLocal]
                            nextLocal += 1
                            _ = enqueue(slot: slot, isLocalLane: true)
                        }
                    } else if nextPrimary < primarySlots.count {
                        let slot = primarySlots[nextPrimary]
                        nextPrimary += 1
                        _ = enqueue(slot: slot, isLocalLane: false)
                    }
                }
            }
        } else {
            // Sequential: OCR remaining indices, using previous results for context
            for (attempt, index) in indices.enumerated() {
                guard !Task.isCancelled, !drainingPages,
                      !stopForUnavailableOpenRouterModel(provider: provider, model: model) else { return }
                let url = fileURLs[index]
                guard reserveMonthlyImage(url, runConfig: runConfig) else { return }
                jobs[index].status = .processing
                // W16.bat10 — bound with the index, before this file's round-trip.
                let jobID = jobs[index].id

                let previousText: String?
                if index > 0, let prevResult = jobs[index - 1].result, segmentationContext.previousTextCharCount > 0 {
                    previousText = prevResult.text.flatMap { String($0.suffix(segmentationContext.previousTextCharCount)) }
                } else {
                    previousText = nil
                }
                let contextImageURL = segmentationContext.sendPreviousImage && index > 0 ? fileURLs[index - 1] : nil

                statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)…" + Self.rateLimitSuffix
                var result = await Self.performOCRCall(
                    imageURL: url, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey,
                    previousText: previousText, previousImageURL: contextImageURL,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale,
                    gatewayConfig: gateway, localAgent: localAgent,
                    rotationMode: ocrRun.rotationMode,
                    standardImageMB: ocrRun.standardImageMB,
                    visionSettings: ocrRun.visionSettings, cascade: ocrRun.cascade, readers: ocrRun.readers, imported: ocrRun.imported, newspaperSpend: newspaperSpend,
                    scanDetector: scanDetector, postCorrection: postCorrection
                )

                if Self.isTimeoutError(result), reserveMonthlyImage(url, runConfig: runConfig, retry: true) {
                    statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)… retrying after timeout"
                    result = await Self.performOCRCall(
                        imageURL: url, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: nil, previousImageURL: nil,
                        customPrompt: segmentationContext.customPrompt,
                        imageScale: segmentationContext.imageScale,
                        gatewayConfig: gateway, localAgent: localAgent,
                        rotationMode: ocrRun.rotationMode,
                        standardImageMB: ocrRun.standardImageMB,
                        visionSettings: ocrRun.visionSettings, cascade: ocrRun.cascade, readers: ocrRun.readers, imported: ocrRun.imported, newspaperSpend: newspaperSpend,
                        scanDetector: scanDetector, postCorrection: postCorrection
                    )
                }

                result = await Self.applyingVisionTextClassification(
                    to: result, previousText: previousText,
                    customPrompt: segmentationContext.customPrompt, configuration: visionTextLLM)

                // A page that Stop cut short (a call cancelled, or one waiting for the Claude plan's window) is not recorded, so
                // Resume reads it in its main pass instead of taking it as already tried (W41.app-claude-plan-reading).
                if (Task.isCancelled || monthlyStopMessage != nil) && result.text == nil { return }
                if result.errorCode == OpenRouterRoute.unavailableModelCode,
                   stopForUnavailableOpenRouterModel(provider: provider, model: model, knownUnavailable: true) { return }
                guard await handleOCRResult(
                    result, index: index, jobID: jobID, url: url, model: model,
                    outputDirectory: outputDirectory, runConfig: runConfig) else { return }
                progress = Double(alreadyCompleted + attempt + 1) / Double(totalFiles) * 0.7
                statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles) complete"
            }
        }
    }
    /// One paid batch's per-chunk canceller: the provider whose RULE applies, how to cancel one chunk, and
    /// — for checks only — which client that closure closed over.
    ///
    /// Bundling them is the point (W16.bat2-fu): `performServerBatchCancellation` reads the provider off the
    /// canceller instead of taking it as a second argument, so a CALL SITE can no longer pass a provider that
    /// contradicts the client it also passed — the pair is built in exactly one place,
    /// `liveBatchChunkCanceller`. What that does *not* buy is a self-verifying pair: `provider` is an
    /// independent field, so an edit inside that one place can still put the wrong client behind the right
    /// provider. `clientTypeName` is what makes that visible to a check.
    /// Not `Sendable`: it is built and consumed entirely on the MainActor.
    struct BatchChunkCanceller {
        let provider: LLMProvider
        /// Performs one chunk's server-side cancellation; true means the provider confirmed it.
        let cancelChunk: @MainActor (String) async -> Bool
        /// The type of the batch client `cancelChunk` closed over, read off the constructed value
        /// (`type(of:)`) rather than written by hand — `"none"` where there is no client (OpenAI), `"stub"`
        /// for a test double. Load-bearing: without it a check can only confirm the provider LABEL, and a
        /// copy-paste that cancels a Gemini job through the Mistral client — or an arm short-circuited to
        /// `{ _ in true }` — would keep every check green while reporting a paid job as cancelled and
        /// deleting the recovery journal that was the only way back to it.
        let clientTypeName: String
        var confirmChunk: (@MainActor (String) async -> Bool)? = nil
    }

    /// The durable file a confirmed cancellation is allowed to remove. There is exactly one — the
    /// paid-batch recovery journal — and naming it as a *value* rather than an inline closure is what
    /// lets a headless driver assert that `cancel()` asked to delete that and nothing else, without
    /// ever running the deleter against the operator's real state (W16.bat2-fu).
    enum BatchCancellationJournal: String, CaseIterable, Sendable {
        case paidBatchJournal
        /// The file this names — as a name, so asking costs no filesystem access.
        var fileName: String {
            switch self {
            case .paidBatchJournal: return OCRProcessor.pendingBatchFileName
            }
        }
    }

    /// Build the live per-chunk canceller for a batch: the only provider-specific part of the cancel
    /// path. Keyed on the batch's OWN provider, so a paid job can never be cancelled with another
    /// provider's client. Constructing a client opens no connection — the network call happens only
    /// when the returned closure is invoked, which is why a driver can safely ask for one.
    static func liveBatchChunkCanceller(for batch: BatchContext) -> BatchChunkCanceller {
        let cancelChunk: @MainActor (String) async -> Bool
        let confirmChunk: (@MainActor (String) async -> Bool)?
        // Read off the client that was actually constructed, never typed in — that is the whole point (see
        // `clientTypeName`): it is what a check compares against the provider whose rule will be applied.
        let clientTypeName: String
        switch batch.provider {
        case .anthropic:
            let client = AnthropicBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
            cancelChunk = { await client.cancelBatch(batchId: $0) }
            confirmChunk = { await client.confirmCancellation(batchId: $0) }
            clientTypeName = String(describing: type(of: client))
        case .mistral:
            let client = MistralBatchClient(apiKey: batch.apiKey, model: batch.model)
            cancelChunk = { await client.cancelBatch(batchId: $0) }
            confirmChunk = { await client.confirmCancellation(batchId: $0) }
            clientTypeName = String(describing: type(of: client))
        case .gemini:
            let client = GeminiBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
            cancelChunk = { await client.cancelBatch(batchName: $0) }
            confirmChunk = { await client.confirmCancellation(batchName: $0) }
            clientTypeName = String(describing: type(of: client))
        case .openai:
            cancelChunk = { _ in false }   // never called; OpenAI has no batch path in v1.
            clientTypeName = "none"
            confirmChunk = nil
        case .appleVision, .openrouter:
            cancelChunk = { _ in false }   // neither has a server-side batch path.
            clientTypeName = "none"
            confirmChunk = nil
        }
        return BatchChunkCanceller(provider: batch.provider, cancelChunk: cancelChunk,
                                   clientTypeName: clientTypeName, confirmChunk: confirmChunk)
    }

    /// Which server-side jobs `cancel()` will try to cancel: the journal's acknowledged chunk IDs when
    /// there is a v1 journal, otherwise the IDs packed into the batch's own ID (legacy comma-joined
    /// manifests). Pure, so the derivation is pinnable — getting it wrong here cancels the wrong paid
    /// jobs, or none, while the operator is told the batch was stopped (W16.bat2-fu).
    static func cancellationChunkIds(pendingBatch: PendingBatch?, batchId: String) -> [String] {
        pendingBatch?.effectiveChunkIds ?? PendingBatch.parseChunkIDs(batchId)
    }

    /// Is a paid-batch SUBMISSION still being constructed for this journal? (W16.bat5)
    ///
    /// The invariant it serves: **a submit is in flight ⇒ the journal survives.** `cancel()` snapshots the
    /// chunk IDs once and then cancels them; a Gemini run creates its server-side jobs one at a time, so a
    /// chunk created *after* that snapshot is billed with its ID recorded nowhere — and if every chunk in
    /// the stale snapshot confirms, the journal (the only local trace of the run) is deleted on top of it.
    /// The owner considered and rejected re-reading the journal's IDs after the cancellations: a chunk
    /// created between the re-read and the delete still slips, so it narrows the race rather than removing
    /// it. The rule here removes it — whenever a submission had not finished at the moment Stop landed, the
    /// journal is kept, no matter what the cancellations then confirm.
    ///
    /// The flag is `submissionComplete`, which the journal already carries and which already brackets the
    /// submit loop exactly: `performBatchOCR` writes the journal with `submissionComplete: false` **before**
    /// the first provider create request (`+OCR.swift`), and `markBatchSubmissionComplete()` flips it true
    /// **after** the last one — and the Gemini submit loop is strictly sequential (`BatchOCR.swift`: each
    /// create is followed inline by its `onJobCreated` callback, no task group, nothing detached), so
    /// "the flag is still false" really does mean "another create may yet happen". Reusing it rather than
    /// adding a second, process-local bool is deliberate: it is durable, and there is no new set/clear
    /// pair for a later edit to forget.
    ///
    /// ⚠️ **It is a SUPERSET of "a create is happening right now", and that is the point.** What it really
    /// answers is *"was this submission ever recorded as finished?"* — so it also says yes for a journal
    /// left unfinished by an earlier interrupted submit (including one being resumed, where nothing is
    /// being submitted at all) and for a submit that finished but whose marker write failed. Each of those
    /// is a batch whose full set of paid jobs is unknown, which is exactly the condition that must keep the
    /// journal, so the breadth is the correct reading rather than slop. It does mean the operator-facing
    /// message must not claim anything about *when* — see
    /// `batchCancellationSubmissionInFlightMessage`, which is worded from the unfinished record instead.
    ///
    /// The one direction it deliberately does NOT cover:
    ///   * No journal at all ⇒ NOT in flight. There is no submission state to consult (a legacy
    ///     comma-joined manifest is written after its single submit, and `activePendingBatch` is non-nil for
    ///     the whole of a v1 submit window — it is assigned one line before `activeBatch`, with no
    ///     suspension between, so `cancel()` can never see a live batch without its journal).
    ///
    /// Pure, and read synchronously by `cancel()` **before** it drops `activePendingBatch` — the answer
    /// describes the instant Stop was pressed, which is what makes it a rule and not another race.
    static func batchSubmissionIsInFlight(_ pendingBatch: PendingBatch?) -> Bool {
        guard let pendingBatch else { return false }
        return !pendingBatch.submissionComplete
    }

    /// What `cancel()` did about a paid batch's server-side job and its recovery journal.
    /// `journalDeleted` is the safety-critical field: that journal is the only way back to a still-live
    /// batch the operator has already paid for, so deleting it on an unconfirmed cancellation strands
    /// the money with no way to collect the pages.
    struct BatchCancellationOutcome: Equatable, Sendable {
        /// True only when every chunk the cancellation KNEW ABOUT was confirmed cancelled by the provider —
        /// which is the whole batch only when `submissionInFlight` was false. That distinction is the whole
        /// of W16.bat5: the chunk list is a snapshot, and an unfinished submission means it may be short.
        let confirmed: Bool
        /// True iff the recovery journal was deleted (i.e. `deleteJournal` was called).
        ///
        /// ⚠️ **Not a synonym for `confirmed` any more** (W16.bat5): `confirmed && !journalDeleted` is a
        /// real, reachable outcome — every chunk the cancellation knew about was stopped, but either the
        /// submission was still in flight or already-fetched results were still materializing, so the journal
        /// survives.
        /// `journalDeleted` is the safety-critical one; read it, never `confirmed`, to know the file's fate.
        let journalDeleted: Bool
        /// The operator-facing message — set only when the journal was KEPT, so the text and the
        /// on-disk fact can never disagree.
        let statusMessage: String?
        /// The chunk IDs a server-side cancellation was actually attempted for. Empty when the
        /// provider's rule declines to even try (multi-chunk Anthropic/Mistral, OpenAI, no chunks).
        let attemptedChunkIds: [String]
    }

    /// The exact words the operator sees when the journal was kept. A constant so a test can pin the
    /// promise ("kept for recovery") that the on-disk behaviour has to match.
    static let batchCancellationNotConfirmedMessage =
        "Cancelled locally, but server cancellation was not confirmed. The paid-batch journal was kept for recovery."

    /// The words for the OTHER reason the journal is kept (W16.bat5): every chunk the cancellation knew
    /// about was confirmed, but the journal's submission was never recorded as finished, so the list may
    /// not have been the whole batch. Distinct from the message above on purpose — "we could not stop it"
    /// and "we stopped everything we knew of, and there may be more" are different things to hand an
    /// operator who is deciding whether to press Resume.
    ///
    /// ⚠️ **Deliberately says nothing about *when*.** The obvious wording — "cancelled while the batch was
    /// still being submitted, so a job may have been created after the cancellation started" — is FALSE in
    /// two shapes this rule also fires on, and this is the one sentence the operator makes a money decision
    /// from: a Stop during a *resumed* batch whose original submission never completed (resume is GET-only,
    /// so nothing is being submitted and nothing is created after the Stop), and a submit that really did
    /// finish but whose `markBatchSubmissionComplete()` could not persist. The unfinished *record* is what
    /// is true in all three, and it is the whole reason the journal is kept.
    static let batchCancellationSubmissionInFlightMessage =
        "The batch's submission was never recorded as finished, so paid jobs may exist beyond the ones that were cancelled. The paid-batch journal was kept for recovery."

    /// The other confirmed-cancellation keep case: the provider result was already fetched but its PDFs
    /// had not all reached their durable completion entries when Stop landed. This is not a claim that a
    /// job is still running; it is the truthful reason its local journal must remain long enough for Resume
    /// to skip the outputs already materialized (W16.bat5-fu2).
    static let batchCancellationMaterializationInFlightMessage =
        "Already-fetched batch results were still being materialized when Stop landed. The paid-batch journal was kept for recovery."

    /// Cancel a paid batch server-side and decide the fate of its recovery journal.
    ///
    /// The one shipped safety guarantee of the cancel path, extracted so it can be proven without a
    /// network, a key or a cent (`BatchCancelContract`, W16.bat2): **the journal is deleted ONLY when
    /// every chunk's cancellation was confirmed.** Anything else — an unconfirmed chunk, a multi-chunk
    /// batch this app has no single ID to cancel, a batch with no chunk IDs at all — keeps the journal
    /// and says so.
    ///
    /// **A submission still in flight overrides confirmation** (W16.bat5). `chunkIds` is a snapshot taken
    /// when Stop landed; if the run was still creating server-side jobs at that instant, the snapshot is not
    /// the whole batch, and confirming all of it says nothing about the job created next. So the journal is
    /// kept — the operator is told a paid job may exist beyond the ones that were stopped. This is the only
    /// case where a fully confirmed cancellation still keeps the journal. W16.bat5-fu2 adds one more:
    /// already-fetched results being materialized. Those PDFs have no durable completion facts until the
    /// main actor writes them, so confirmed cancellation must keep the journal for that bounded window too.
    ///
    /// - Parameters:
    ///   - canceller: the provider it applies plus how to cancel one chunk. `cancel()` passes the live
    ///     batch client's canceller; the headless driver passes a stub, which is the point of the seam.
    ///   - submissionInFlight: was the batch's submission still unfinished when Stop was pressed
    ///     (`batchSubmissionIsInFlight`)? Deliberately NOT defaulted: a caller that has to answer it cannot
    ///     forget it, and on this path forgetting means deleting a journal that should have survived.
    ///   - materializationInFlight: were already-fetched results for this exact batch still becoming PDFs
    ///     when Stop landed? This is process-local but identity-bound by `processBatchResults`; it prevents
    ///     a confirmed cancellation from deleting the only record before those completed facts can land.
    ///   - deleteJournal: removes the recovery journal. Called at most once, and only when the cancellation
    ///     was confirmed and neither a submission nor result materialization was in flight.
    static func performServerBatchCancellation(
        canceller: BatchChunkCanceller,
        chunkIds: [String],
        submissionInFlight: Bool,
        materializationInFlight: Bool,
        deleteJournal: @MainActor () -> Void
    ) async -> BatchCancellationOutcome {
        let cancelChunk = canceller.cancelChunk
        var attempted: [String] = []
        var confirmed: Bool
        var acknowledged: [String] = []
        switch canceller.provider {
        case .anthropic, .mistral:
            // Both clients cancel exactly one server-side job. A batch split into several chunks has no
            // single ID to cancel, so nothing can be confirmed and the journal must survive.
            if chunkIds.count == 1 {
                attempted = chunkIds
                confirmed = await cancelChunk(chunkIds[0])
                if confirmed { acknowledged = chunkIds }
            } else {
                confirmed = false
            }
        case .gemini:
            // Every chunk must be cancelled. An empty list is NOT a vacuous success.
            var allConfirmed = !chunkIds.isEmpty
            for chunkId in chunkIds {
                attempted.append(chunkId)
                // Deliberately no early exit: a later chunk is still worth cancelling after an earlier
                // one failed — leaving it running is exactly what costs money.
                if await cancelChunk(chunkId) { acknowledged.append(chunkId) }
                else { allConfirmed = false }
            }
            confirmed = allConfirmed
        case .openai:
            confirmed = false   // OpenAI has no batch path in v1 (`supportsBatch == false`).
        case .appleVision, .openrouter:
            confirmed = false   // neither has a server-side batch path.
        }
        if let confirmChunk = canceller.confirmChunk {
            for chunkID in acknowledged {
                if !(await confirmChunk(chunkID)) { confirmed = false }
            }
        }
        // Keep-on-doubt, and the doubt outranks confirmation. An unfinished submission means the chunk
        // list may be short; a materialization in flight means a just-written PDF may not yet have a
        // durable completion record. Either loss must keep the exact journal Stop closed.
        if confirmed && submissionInFlight {
            return BatchCancellationOutcome(
                confirmed: true, journalDeleted: false,
                statusMessage: Self.batchCancellationSubmissionInFlightMessage,
                attemptedChunkIds: attempted)
        }
        if confirmed && materializationInFlight {
            return BatchCancellationOutcome(
                confirmed: true, journalDeleted: false,
                statusMessage: Self.batchCancellationMaterializationInFlightMessage,
                attemptedChunkIds: attempted)
        }
        if confirmed {
            deleteJournal()
            return BatchCancellationOutcome(confirmed: true, journalDeleted: true,
                                            statusMessage: nil, attemptedChunkIds: attempted)
        }
        return BatchCancellationOutcome(confirmed: false, journalDeleted: false,
                                        statusMessage: Self.batchCancellationNotConfirmedMessage,
                                        attemptedChunkIds: attempted)
    }

    // MARK: - Quitting during a run (W49.proc-resume-standard-runs)

    /// Holds off App Nap while the processor works and idle sleep during its main OCR pass, and enrols it in the quit
    /// check.
    func updateRunActivity() {
        if isProcessing {
            Self.processorsThatRan.removeAll { $0.processor == nil }
            if !Self.processorsThatRan.contains(where: { $0.processor === self }) {
                Self.processorsThatRan.append(WeakProcessor(processor: self))
            }
        }
        let holdSleep = isProcessing && ocrPhaseActive
        if let activity = runActivity, !isProcessing || holdSleep != runActivityHoldsSleep {
            ProcessInfo.processInfo.endActivity(activity)
            runActivity = nil
        }
        if isProcessing, runActivity == nil {
            runActivity = ProcessInfo.processInfo.beginActivity(
                options: holdSleep ? [.userInitiated, .idleSystemSleepDisabled] : .userInitiatedAllowingIdleSystemSleep,
                reason: "Processing files")
            runActivityHoldsSleep = holdSleep
        }
    }

    /// The processors still working when the app is asked to quit.
    static var processorsStillRunning: [OCRProcessor] {
        processorsThatRan.compactMap(\.processor).filter(\.isProcessing)
    }

    /// Set once every waiting run has stopped, so the second quit goes through without asking again.
    static var quitApproved = false

    /// The app's own quit (`ProcessorAppDelegate` sets it); the quit contract replaces it.
    static var quitApp: (() -> Void)?

    static let quitWaitMessage = "Quitting once the pages being read now are saved…"

    /// The quit's "wait" answer: finish the pages in flight, start no new one, then stop the run and quit. Only
    /// meaningful in the main OCR pass (`ocrPhaseActive`); anywhere else there is no page in flight to wait for.
    func beginQuitWhenPagesSaved() {
        guard isProcessing, ocrPhaseActive else { return }
        quitWhenPagesSaved = true
        statusMessage = pageDrainMessage
    }

    static let unavailableModelRecoveryNote = " To resume this run, the original model must be available again."
        + " To start a new run, dismiss the interrupted run first."
    static let stoppedAfterDrainNote = "The pages being read were saved; Resume Run continues from the first page not read."
    static let stopWaitMessage = "Stopping once the pages being read now are saved… Stop Now stops at once."
    static let batchQuitWaitMessage = "Quitting once the provider's reply to the batch submission is in and recorded…"
    static let batchStopWaitMessage = "Stopping once the provider's reply to the batch submission is in, so the job can "
        + "be cancelled… Stop Now stops at once."
    static let batchQuitRecordedMessage = "The batch job is recorded; Resume collects its results. Quitting…"

    /// What the run says while it waits for the pages in flight, or for a batch submission's reply.
    var pageDrainMessage: String {
        switch (drainablePassKind, quitWhenPagesSaved) {
        case (.pages, true): Self.quitWaitMessage
        case (.pages, false): Self.stopWaitMessage
        case (.batchSubmission, true): Self.batchQuitWaitMessage
        case (.batchSubmission, false): Self.batchStopWaitMessage
        }
    }

    /// W49.proc-stop-saves-inflight: the Stop button and ⌘. In the main OCR pass the first press waits for the pages
    /// being read (a reading that lands after a plain Stop is not saved, so Resume Run would read and pay for that page
    /// again); a second press, shown as Stop Now, stops at once, for a page that hangs. Anywhere else, and with a quit
    /// already waiting, it stops at once as before.
    func requestStop() {
        guard isProcessing, ocrPhaseActive, !drainingPages else { cancel(); return }
        stopWhenPagesSaved = true
        statusMessage = pageDrainMessage
    }

    /// Stop scheduling pages if the frozen direct reader leaves the listing. Keep the recovery record and let
    /// requests already in flight finish. A page refused before it had a client stays unread in the record.
    @discardableResult
    func stopForUnavailableOpenRouterModel(
        provider: LLMProvider, model: LLMModel, knownUnavailable: Bool = false
    ) -> Bool {
        guard !Task.isCancelled, provider == .openrouter, currentGateway == nil, currentLocalAgent == nil,
              knownUnavailable || OpenRouterRoute.unavailableSelection(model.id) != nil else { return false }
        unavailableOpenRouterRunMessage = OpenRouterRoute.unavailableMessage(model.id)
        if ocrPhaseActive {
            stopWhenPagesSaved = true
        } else {
            cancel()
        }
        return true
    }

    /// Marks the start of a pass a quit or Stop can wait on. The token ties its end to this run: a run stopped at once
    /// goes on unwinding, and its end must neither unmark nor stop a newer run started on the same processor.
    func beginDrainablePass(_ kind: DrainablePassKind = .pages) -> UUID {
        let pass = UUID()
        drainablePass = pass
        drainablePassKind = kind
        ocrPhaseActive = true
        return pass
    }

    func endDrainablePass(_ pass: UUID) {
        guard drainablePass == pass else { return }
        drainablePass = nil
        ocrPhaseActive = false
        finishPageDrainIfAsked(after: drainablePassKind)
    }

    /// W49.proc-quit-waits-batch-submit: a batch submission that failed has ended its run and said why, so a quit or
    /// Stop waiting on it is dropped rather than carried out: the app stays open on the failure message.
    func abandonDrainablePass(_ pass: UUID) {
        guard drainablePass == pass else { return }
        drainablePass = nil
        ocrPhaseActive = false
        quitWhenPagesSaved = false
        stopWhenPagesSaved = false
    }

    /// Called as the main OCR pass ends, however it ends. When a quit or Stop is waiting, every page started has been
    /// saved to the run's record by now, so Stop keeps a run that Resume Run continues from the first page not read.
    /// After a batch submission every job created is in the journal: Stop then cancels them all with the provider,
    /// and a quit leaves them running, journaled, for Resume to collect.
    func finishPageDrainIfAsked(after kind: DrainablePassKind = .pages) {
        guard drainingPages else { return }
        let quitting = quitWhenPagesSaved
        let run = processingTask
        // A quit is not a Stop: the jobs stay with the provider and the journal on disk. Without the batch context
        // `cancel()` neither cancels them nor closes the journal. A Stop asked before the quit still cancels them.
        let keepJobs = quitting && kind == .batchSubmission && !stopWhenPagesSaved
        if keepJobs {
            activeRunHistory = nil
            activeBatch = nil
        }
        let modelBecameUnavailable = unavailableOpenRouterRunMessage != nil
        let moneyLimitReached = monthlyStopMessage != nil
        cancel()
        let cancellation = batchCancellationTask
        guard quitting else {
            if kind == .pages && !modelBecameUnavailable && !moneyLimitReached { statusMessage += " " + Self.stoppedAfterDrainNote }
            return
        }
        statusMessage = kind == .pages ? "The pages being read are saved. Quitting…"
            : keepJobs ? Self.batchQuitRecordedMessage : "Cancelling the batch job, then quitting…"
        Task {
            // Let the stopped run unwind (and its ledger line land) before the process ends.
            await run?.value
            if !keepJobs, kind == .batchSubmission { await cancellation?.value }
            await Task.yield()
            // Another window's run still draining quits for both when it is done; a run started meanwhile was not
            // asked about, so the quit then waits for a new ⌘Q.
            guard Self.processorsStillRunning.isEmpty else { return }
            Self.quitApproved = true
            Self.quitApp?()
        }
    }

    func cancel() {
        if let reload = institutionalComputeReloadTask {
            reload.cancel()
            statusMessage = "Resume stopped. The interrupted run is still saved."
            return
        }
        let unavailableModel = unavailableOpenRouterRunMessage
        let spendingLimit = monthlyStopMessage
        monthlyStopMessage = nil
        let collectingPaidBatchLater = activeBatch == nil && activePendingBatch?.effectiveChunkIds.isEmpty == false
            && (monthlySpend != nil || activePendingBatch?.usesWindowSegmentation == true)
        let keepsRecovery = activePendingRun != nil || activePendingMixedPDF != nil || collectingPaidBatchLater
        unavailableOpenRouterRunMessage = nil
        // A Stop pressed while a quit waits for its pages takes the quit back: the run stops and the app stays open.
        // Pressed while a Stop waits, it is Stop Now.
        quitWhenPagesSaved = false
        stopWhenPagesSaved = false
        // Kept after the handle is dropped, for the cancellation task at the bottom of this function: the
        // run this Stop is ending goes on unwinding on its own task afterwards, and writes its own
        // `statusMessage` on the way out. That is what the kept-journal warning has to outlive (W16.bat6).
        let interruptedRun = processingTask
        processingTask?.cancel()
        processingTask = nil
        activeRunHistory = nil
        if activePendingMixedPDF != nil, interruptedRun != nil {
            mixedPDFCancellationUnwinding = true
            Task {
                await interruptedRun?.value
                mixedPDFCancellationUnwinding = false
                checkForPendingBatch()
            }
        }
        isProcessing = false
        // W49.proc-unified-pipeline-2: a stopped run writes none of the outputs it held back (their readings are in
        // the journal, and its resume writes them), so no row may go on pointing at one or take an edit for it.
        for (url, held) in deferredOutputs where outputURLMap[held.request.source] == url
            && !FileManager.default.fileExists(atPath: url.path) {
            outputURLMap[held.request.source] = nil
        }
        deferredOutputs = [:]
        defersOutputWrites = false
        awaitingFinalReview = false
        awaitingDocumentReview = false
        awaitingCollectionConfirmation = false
        awaitingRetryDecision = false
        documentReviewContinuation?.resume()
        documentReviewContinuation = nil
        finalReviewContinuation?.resume(returning: .complete)
        finalReviewContinuation = nil
        collectionConfirmationContinuation?.resume()
        collectionConfirmationContinuation = nil
        retryContinuation?.resume(returning: .continueWithout)
        retryContinuation = nil
        // Manual segmentation/tagging + box-folder review continuations (so escaping those dialogs
        // aborts cleanly without leaking a continuation or leaving the review window open).
        awaitingManualTagging = false
        manualTaggingContinuation?.resume()
        manualTaggingContinuation = nil
        awaitingManualSegTag = false
        manualSegTaggingRange = nil
        manualSegContinuation?.resume()
        manualSegContinuation = nil
        awaitingBoxFolderConfirmation = false
        boxFolderConfirmContinuation?.resume()
        boxFolderConfirmContinuation = nil
        releaseWindowStageContinuations()
        cleanupTempFiles()

        // Cancel server-side batch if active.
        // Every decision here is made from data and named seams rather than inline closures, so the
        // WIRING can be driven headlessly (`BatchCancelWiringContract`, W16.bat2-fu) — which jobs get
        // cancelled, with which provider's client, which journal may be deleted, and whether the
        // operator is told. The RULE those feed is `performServerBatchCancellation` (W16.bat2).
        if let batch = activeBatch {
            activeBatch = nil
            let chunkIds = Self.cancellationChunkIds(pendingBatch: activePendingBatch, batchId: batch.batchId)
            // Read HERE, synchronously, from the same journal state the chunk snapshot came from (W16.bat5).
            // Whether the submission had finished is a fact about the instant Stop landed, so it is settled
            // now rather than re-derived by the cancellation task later — by then `activePendingBatch` is
            // the nil set on the next line, and the predicate answers "nothing in flight" for want of a
            // journal to read, which is the deleting direction. `cancel()` has no `await`, so this read and
            // the decision that uses it are one uninterrupted MainActor turn: no window, not a re-read.
            let submissionInFlight = Self.batchSubmissionIsInFlight(activePendingBatch)
            // Closed, not unreachable (W16.bat5-fu). Dropping the journal is what stops the cancelled run
            // from advancing it, and it must keep doing that — but a Gemini submit loop creates one paid job
            // at a time, so a create can still be in flight right now and its ID would land nowhere. Keep the
            // journal ADDRESSABLE (identity only, never a snapshot to write back) so a late submit callback
            // can append its ID, and an already-fetched result can append its completion facts, to the file.
            // Nothing here waits: the owner rejected quiescing in-flight submits before this line precisely
            // because a hung provider request would stall Stop.
            let materializationInFlight: Bool
            if let address = batchResultMaterializationAddress, let pending = activePendingBatch {
                materializationInFlight = address.matches(pending)
            } else {
                materializationInFlight = false
            }
            closedPaidBatchJournalAddress = ClosedPaidBatchJournalAddress(activePendingBatch)
            activePendingBatch = nil
            // Built synchronously (constructing a client opens no connection) so the choices are made
            // from state that is still current, not from whatever it became by the time the Task ran.
            let canceller = makeBatchChunkCanceller(batch)
            let deleteJournal = makeBatchJournalDeleter(.paidBatchJournal)
            batchCancellationTask = Task {
                let outcome = await Self.performServerBatchCancellation(
                    canceller: canceller, chunkIds: chunkIds,
                    submissionInFlight: submissionInFlight,
                    materializationInFlight: materializationInFlight, deleteJournal: deleteJournal)
                // The cancelled run is still unwinding, and it writes `statusMessage` too: a poll whose
                // status check was in flight when Stop landed still reports "Batch processing… n/m" or
                // "Error checking batch… Retrying…" once that request resolves. Wait for it to finish
                // before the warning goes up (W16.bat6) — the two tasks were previously racing, and the
                // loser is whichever writes first.
                //
                // Ordered deliberately, and ONLY the message is held back. The server-side cancellations
                // above stop paid work, and the Resume banner here is the control every interruption
                // message points at — W16.bat4 shipped because leaving it unrendered wedges the operator
                // into pressing Start and being refused. Neither may wait on an unwinding run.
                checkForPendingBatch()
                //
                // This waits, but not indefinitely. That task is already cancelled, and all seven
                // continuations it could be parked on were resumed above, so the one thing that can still
                // hold it open is an in-flight provider request running out its own `timeoutInterval`
                // (30s for a status check, 120s for a result fetch). A late warning beats a lost one — and
                // beats narrowing the window, since the write that clobbers is by definition the one that
                // comes back last.
                await interruptedRun?.value
                // Only a KEPT journal produces a message, and the operator must see it: it is the only
                // signal that a paid job may still be running server-side.
                if let message = outcome.statusMessage { statusMessage = message }
                // Recomputed again, because the run that just finished unwinding may have changed what is
                // on disk (its tail retires the journal when the poll had in fact completed), and the
                // banner has to describe the disk as it finally is rather than as it was mid-unwind.
                checkForPendingBatch()
            }
        }

        // Keep the recovery record for direct reads or an already-collected batch.
        if activePendingRun != nil || collectingPaidBatchLater {
            activePendingRun = nil
            if collectingPaidBatchLater { activePendingBatch = nil }
            checkForPendingBatch()
        }

        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let pending = jobs.filter { $0.status == .processing || $0.status == .pending }.count
        if let spendingLimit {
            statusMessage = spendingLimit
            if keepsRecovery { statusMessage += " Your progress is saved. Resume when more money is available." }
        } else if let unavailableModel {
            statusMessage = "Processing stopped. " + unavailableModel
            if keepsRecovery { statusMessage += Self.unavailableModelRecoveryNote }
        } else {
            statusMessage = "Cancelled. \(succeeded) succeeded, \(failedFiles.count) failed, \(pending) skipped."
        }
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = unavailableModel == nil && spendingLimit == nil ? .failed : .pending
        }
    }
    func startProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        visionTextAPIKey: String? = nil,
        outputDirectory: URL,
        batchMode: Bool,
        enableTagging: Bool,
        enableSegmentJSON: Bool,
        enableCollectionSegmentation: Bool = false,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        reviewFreshDocumentSegmentation: Bool = true,
        preOCRedInput: Bool = false,
        skipAlreadyProcessed: Bool = false,
        segmentationContext: SegmentationContext,
        gatewayConfig: GatewayConfig? = nil,
        localAgent requestedLocalAgent: LocalAgentConfig? = nil,
        resumingMixedPDF: PendingMixedPDF? = nil,
        postCorrectionRequested: Bool = false
    ) async {
        // A mixed PDF resume keeps the choice its record saved at Start (owner call 30: Resume skips only a review the
        // user turned off; W40.fix-processor-resume-reviews). An older record without it reads as on.
        let reviewWholeRun = resumingMixedPDF.map { $0.reviewWholeRun ?? true } ?? reviewFreshDocumentSegmentation
        let localAgent = requestedLocalAgent.map { config in
            var config = config
            config.requiresSubscription = SettingsLayerStore.shared.resolver(at: outputDirectory).monthlyLimitUSD != nil
            return config
        }
        let isDirectOCR = gatewayConfig == nil && localAgent == nil && provider != .appleVision && !preOCRedInput
        let useBatch = batchMode && provider.supportsBatch && isDirectOCR
        // W41.app-page-kind: taken and cleared before any early return, so a start that is refused cannot leave its
        // plan for a later run whose caller set none.
        let plannedReaders = pageReaders
        pageReaders = .empty
        let plannedImport = institutionalComputeImport
        institutionalComputeImport = nil
        let plannedSubfolders = plannedOutputSubfolders   // W47.ct-processor-intake
        plannedOutputSubfolders = [:]
        guard !files.isEmpty else { return }
        // S-048: Process Files lists a file once, but Live Capture and the test seams fill the list without it. Two
        // jobs for one source would read it twice and then collide at filing, so refuse before any request.
        if let repeated = ProcessFilesTree.firstRepeat(in: files) {
            statusMessage = "\(repeated.lastPathComponent) is listed more than once. Remove the repeat and start again; no request was sent."
            return
        }
        if provider == .openrouter, gatewayConfig == nil, localAgent == nil,
           let warning = OpenRouterRoute.unavailableSelection(model.id) {
            statusMessage = warning + (resumingMixedPDF == nil ? "" : Self.unavailableModelRecoveryNote)
            return
        }
        if resumingMixedPDF == nil, !preOCRedInput,
           let tree = ProcessFilesTree.treeHoldingOutput(subfolders: plannedSubfolders, outputDirectory: outputDirectory) {
            statusMessage = ProcessFilesTree.overlapMessage(tree)
            return
        }
        // Never overwrite recovery state from a different interrupted run. The UI surfaces explicit
        // Resume/Dismiss controls, but keep the invariant here as well for shortcuts and programmatic
        // callers. A paid batch may still exist even when its manifest is malformed or has no received ID.
        if FileManager.default.fileExists(atPath: Self.pendingBatchURL.path) || Self.loadPendingRun() != nil ||
           (FileManager.default.fileExists(atPath: Self.pendingMixedPDFURL.path)
            && resumingMixedPDF == nil) {
            checkForPendingBatch()
            statusMessage = "An interrupted run is still preserved. Resume it or explicitly dismiss its recovery record before starting another run."
            return
        }
        if let resumingMixedPDF {
            guard !mixedPDFCancellationUnwinding else {
                statusMessage = "The cancelled PDF request is still finishing. Resume will be available once it stops."
                return
            }
            guard let onDisk = Self.loadPendingMixedPDF(),
                  Self.pendingMixedPDFIsSelfConsistent(onDisk),
                  onDisk.integrity == resumingMixedPDF.integrity,
                  onDisk.inFlightPage == nil,
                  onDisk.originalFiles == files,
                  onDisk.outputDirectory == outputDirectory,
                  onDisk.pdfIndices.allSatisfy({ index in
                      Self.mixedPDFSourceDigest(files[index]) == onDisk.sourceDigests[String(index)]
                  }),
                  Self.mixedPDFOutputsMatchJournal(onDisk) else {
                checkForPendingBatch()
                statusMessage = "The PDF recovery record or its sources changed. Review it before resuming; no paid request was sent."
                return
            }
        }
        // Normalize programmatic/profile inputs to the same bounds as the UI before either the live run
        // or its immutable resume snapshot observes them.
        var segmentationContext = segmentationContext
        segmentationContext.previousTextCharCount = min(20_000, max(0, segmentationContext.previousTextCharCount))
        segmentationContext.imageScale = segmentationContext.imageScale.isFinite
            ? max(0.01, min(1.0, segmentationContext.imageScale)) : 1.0

        // Incremental processing: drop inputs whose output PDF already exists at the destination and is
        // no older than the source (the owner-specified skip key). Confined to plain per-file output —
        // NOT a Live Capture pre-grouped handoff (its file count must match the boundary arrays), and
        // NOT collection-organized or merged runs (there the output isn't a stable top-level
        // <out>/<base>.pdf, so the check can't reliably attribute an output to a source). In every other
        // mode this is a safe no-op. IncrementalSkip is conservative: any ambiguity → PROCESS, so a
        // re-run can never silently miss a file that needed output.
        var files = files
        var incrementalSkipped = 0
        if resumingMixedPDF == nil && skipAlreadyProcessed && preGroupedBoundaries.isEmpty
            && !enableCollectionSegmentation && !mergeDocuments {
            let decision = Self.incrementalPartition(files, outputDirectory: outputDirectory,
                                                     subfolders: preOCRedInput ? [:] : plannedSubfolders,
                                                     requiresCatalogue: true)
            incrementalSkipped = decision.skipped.count
            files = decision.toProcess
            guard !files.isEmpty else {
                jobs = []; failedFiles = [:]; segments = []; collectionSegments = []
                clearOutputWarnings()
                progress = 1.0
                statusMessage = "All \(incrementalSkipped) file(s) already processed — nothing to do."
                return
            }
        }

        // Convert sparse/partial Live Capture metadata into the exact effective arrays the pipeline
        // already treats missing entries as (document / nil / empty). This keeps the live run and its
        // strict resume snapshot byte-for-byte aligned even if a programmatic handoff omitted a sibling
        // array. A boundary-count mismatch disables the handoff entirely, matching the OCRView gate.
        if !preGroupedBoundaries.isEmpty {
            if preGroupedBoundaries.count != files.count {
                preGroupedBoundaries = []
                preGroupedTypes = []
                preGroupedQualities = []
                preGroupedYears = []
                preGroupedMonths = []
                preGroupedSubjects = []
            } else {
                preGroupedTypes = files.indices.map {
                    $0 < preGroupedTypes.count ? preGroupedTypes[$0] : .document
                }
                if !preGroupedQualities.isEmpty {
                    preGroupedQualities = files.indices.map {
                        $0 < preGroupedQualities.count ? preGroupedQualities[$0] : nil
                    }
                }
                if !preGroupedYears.isEmpty {
                    preGroupedYears = files.indices.map { $0 < preGroupedYears.count ? preGroupedYears[$0] : nil }
                }
                if !preGroupedMonths.isEmpty {
                    preGroupedMonths = files.indices.map { $0 < preGroupedMonths.count ? preGroupedMonths[$0] : nil }
                }
                if !preGroupedSubjects.isEmpty {
                    preGroupedSubjects = files.indices.map {
                        $0 < preGroupedSubjects.count ? preGroupedSubjects[$0] : []
                    }
                }
            }
        }

        guard SearchableArchival.isAvailable else {
            statusMessage = "Process Files needs the PDF preparation tool. The original files are intact."
            return
        }
        // W49.proc-settings-config-unify: one answer for the intake and the run's config, the frozen one on a resume.
        let keepsPreservationCopies = resumingMixedPDF?.runtimeConfig.keepPreservationCopies
            ?? SettingsLayerStore.shared.keepsPreservationCopies
        guard await beginCatalogueRun(outputRoot: outputDirectory, sources: files, resuming: resumingMixedPDF != nil,
                                      keepPreservationCopies: keepsPreservationCopies, confirmResume: {
            guard let resumingMixedPDF else { return true }
            return Self.loadPendingMixedPDF()?.integrity == resumingMixedPDF.integrity
        }) else { return }
        defer { catalogueRunLease = nil }
        isProcessing = true
        failedFiles = [:]
        clearOutputWarnings()
        segments = []
        appliedGeneratedTags = [:]
        enclosureDateReviews = [:]
        collectionSegments = []
        outputURLMap = [:]
        deferredOutputs = [:]
        defersOutputWrites = false
        _takenOutputPaths = []
        exportedImageMap = [:]
        pdfToImageMap = [:]
        removedSourceURLs = []
        enclosureCoverChoices = [:]
        // W47.ct-processor-intake: the pre-OCRed route tags its inputs where they are, so it has no tree.
        outputSubfolders = resumingMixedPDF.map { $0.runtimeConfig.outputSubfolders ?? [:] }
            ?? (preOCRedInput ? [:] : Self.keyedSubfolders(plannedSubfolders))
        var runConfig = SessionProcessingConfig.fromProcessFilesRunStart(primaryAPIKey: apiKey, visionTextAPIKey: visionTextAPIKey)
        runConfig.keepPreservationCopies = keepsPreservationCopies
        // The Process Files controller/arguments are the authoritative run input (headless drivers
        // intentionally configure them without mutating UserDefaults), so every explicitly-threaded
        // consumer observes this exact start-time snapshot.
        runConfig.provider = provider
        runConfig.model = model
        runConfig.thinkingLevel = thinkingLevel ?? .low
        runConfig.apiKey = apiKey
        runConfig.taggingMode = taggingMode
        if let segmentationApproach { runConfig.segmentationApproach = segmentationApproach }
        runConfig.rotationMode = rotationMode
        runConfig.mergeDocuments = mergeDocuments
        runConfig.outputDirectory = outputDirectory
        runConfig.customOCRPrompt = segmentationContext.customPrompt ?? ""
        runConfig.imageScale = segmentationContext.imageScale
        runConfig.enableSegmentJSON = enableSegmentJSON
        runConfig.tagVocabulary = tagVocabulary
        runConfig.gateway = gatewayConfig
        runConfig.outputImageFile = exportOriginals
        runConfig.localAgent = localAgent
        // Per-page readers and institutional imports apply to direct OCR outside a provider batch. Per-page readers
        // also apply to an Apple Vision run, whose handwritten pages may go to a model on this Mac
        // (W49.proc-kind-split-mac; `PageKindRouting.reader` never sends one of its pages off the Mac).
        let allowsPageReaders = isDirectOCR && !useBatch
        let visionReaders = provider == .appleVision && gatewayConfig == nil && localAgent == nil && !preOCRedInput
        runConfig.pageReaders = allowsPageReaders || visionReaders ? plannedReaders : .empty
        runConfig.institutionalComputeImport = allowsPageReaders ? plannedImport : nil
        if let resumingMixedPDF {
            applyMixedPDFRuntimeConfig(resumingMixedPDF.runtimeConfig, to: &runConfig, apiKey: apiKey,
                                       reloadedImport: plannedImport)
            activePendingMixedPDF = resumingMixedPDF
        }
        let startClassifies = (enableTagging && !passSourceTags) || runConfig.mergeDocuments || enableCollectionSegmentation
        runConfig.institutionalComputeImport?.classifyPages = startClassifies
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
        currentModel = model
        currentGateway = gatewayConfig
        currentLocalAgent = localAgent
        jobs = files.map { OCRJob(sourceURL: $0) }
        progressRange = nil
        progress = 0

        // Route each multi-page PDF to the pure re-OCR transform, and every other input through
        // the standard image path. A filtered PDF keeps its original job index; the image path's
        // older positional code sees only its own contiguous job subset until both paths finish.
        let pdfIndices = preOCRedInput ? [] : files.indices.filter { PDFToImageConverter.isMultiPagePDF(files[$0]) }
        let pdfIndexSet = Set(pdfIndices)
        let imageIndices = files.indices.filter { !pdfIndexSet.contains($0) }
        let autoReOCR = !pdfIndices.isEmpty
        let mixedReOCR = autoReOCR && !imageIndices.isEmpty
        // One id for the run across a resume from its PDF recovery record (W46.settings-ledger-more).
        let runID = resumingMixedPDF?.ledgerRunID ?? UUID()
        // W46.settings-layers: resolve the general, project and collection layers once and freeze them for this run's
        // pending record. The run is recorded in the collection's folder only once it is committed to start
        // (`recordActiveRunInCollection`), and a resumed mixed-PDF run was recorded when it first started.
        var frozen = SettingsLayerStore.shared.snapshot(outputDirectory: outputDirectory, runID: runID)
        activeResolvedSettings = frozen
        if resumingMixedPDF == nil {
            runConfig.dateLocalImage = provider == .appleVision && runConfig.visionTextLLM == nil
                && taggingMode == .autoDate && enableTagging && !preOCRedInput
                && !enableCollectionSegmentation && gatewayConfig == nil && localAgent == nil
                && DateRoute.localImageEnabled(frozen.values[SettingsKey.dateLocalImage.rawValue]?.value)
        }
        if runConfig.dateLocalImage {
            // This mode keeps the whole run local even if a paid segmenter or OCR correction was saved.
            runConfig.segmentationApproach = .manual
        }
        activeRunConfig = runConfig
        let wantsCorrection = resumingMixedPDF.map { $0.runtimeConfig.postCorrection == true } ?? postCorrectionRequested
        activePostCorrection = Self.makePostCorrection(
            requested: wantsCorrection && !runConfig.dateLocalImage && !preOCRedInput && !(autoReOCR && !mixedReOCR)
                && !useBatch
                && segmentationContext.customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            gateway: gatewayConfig, localAgent: localAgent, outputDirectory: outputDirectory, frozen: frozen.values)
        // W49.proc-settings-config-unify: the record keeps the config the run goes on with, now that it is final.
        var recordedConfig = runConfig.config
        recordedConfig.reviewRotation = reviewRotation
        recordedConfig.postCorrection = activePostCorrection != nil
        frozen.run = recordedConfig.forRecord
        activeResolvedSettings = frozen
        if let resumingMixedPDF {
            guard autoReOCR && pdfIndices == resumingMixedPDF.pdfIndices else {
                isProcessing = false
                statusMessage = "The PDF inputs changed since the recovery record was saved. No paid request was sent."
                checkForPendingBatch()
                return
            }
        } else if autoReOCR {
            guard beginMixedPDFJournal(
                originalFiles: files, pdfIndices: pdfIndices, outputDirectory: outputDirectory,
                provider: provider, model: model, thinkingLevel: thinkingLevel,
                batchMode: useBatch, enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs,
                reviewDocumentSegmentation: reviewDocumentSegmentation,
                segmentationContext: segmentationContext, gatewayConfig: gatewayConfig,
                localAgent: localAgent, runConfig: runConfig, ledgerRunID: runID,
                reviewWholeRun: reviewWholeRun) else {
                isProcessing = false
                return
            }
        }
        reOCRSourceURLs = Set(pdfIndices.map { files[$0] })
        var mixedPDFOutcomes: [MixedPDFOutcome]?
        var fullJobsAfterPDF: [OCRJob]?
        var fullQualitiesAfterPDF: [String?]?
        var editingImageSubset = false
        /// The phone ratings follow the rows back, so the catalogue's rating (`catalogueQuality`, read by row
        /// index) stays aligned with the full run (W49.proc-catalogue-cutover). A rating the subset changed
        /// (a manual Quality intent) is kept.
        func restoredQualities() -> [String?]? {
            guard var full = fullQualitiesAfterPDF else { return nil }
            for (subsetIndex, originalIndex) in imageIndices.enumerated()
            where subsetIndex < preGroupedQualities.count && originalIndex < full.count {
                full[originalIndex] = preGroupedQualities[subsetIndex]
            }
            return full
        }
        defer {
            // Also restore original row order after an early return or cancellation in the image path.
            if editingImageSubset, let fullJobsAfterPDF {
                var restored = fullJobsAfterPDF
                for (subsetIndex, originalIndex) in imageIndices.enumerated() where subsetIndex < jobs.count {
                    restored[originalIndex] = jobs[subsetIndex]
                }
                jobs = restored
                if let qualities = restoredQualities() { preGroupedQualities = qualities }
            }
            progressRange = nil
        }

        // Snapshot this run's parameters for the processing-history log. Captured here (not at the tail)
        // because several completion paths clear other run state first; `enableTagging`/`sendPreviousImage`
        // mirror the pre-run cost pane's inputs (`taggingMode.llmTags`, the context-gated flag) so the
        // recorded cost equals what the operator saw. `batchMode` reflects whether batch ACTUALLY runs.
        activeRunHistory = RunHistorySnapshot(
            startedAt: Date(),
            provider: provider,
            gatewayConfig: gatewayConfig,
            localAgent: localAgent,
            imageTokenProvider: gatewayConfig != nil ? Self.gatewayUpstreamProviderFromDefaults() : nil,
            model: model,
            // Multi-page re-OCR is a pure image/PDF transform and deliberately skips judgement,
            // tagging, and segmentation. Do not attribute an unused text backend to its history row.
            visionTextProvider: autoReOCR && !mixedReOCR ? nil : runConfig.visionTextLLM?.provider,
            visionTextModel: autoReOCR && !mixedReOCR ? nil : runConfig.visionTextLLM?.model,
            batchMode: useBatch,
            enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            reOCRMultiPagePDF: autoReOCR,
            mixedReOCR: mixedReOCR,
            sendPreviousImage: segmentationContext.sendPreviousImage,
            contextCharCount: segmentationContext.previousTextCharCount,
            imageScale: segmentationContext.imageScale,
            rotationMode: rotationMode,
            fileCount: files.count,
            pdfFileCount: pdfIndices.count,
            pdfPageCount: RunHistorySnapshot.directPDFPageCount(pdfIndices.map { files[$0] }),
            pdfSources: pdfIndices.map { files[$0] }
        )

        activeRunHistory?.ledgerRunID = frozen.runID
        activeRunHistory?.dateImageEveryDocument = frozen.values[SettingsKey.dateImageEveryDocument.rawValue]?
            .value.bool ?? false
        activeRunHistory?.sidecars = enableSegmentJSON || !preOCRedInput
        activeRunHistory?.classifyPreOCRedInput = (enableTagging && !passSourceTags) || enableCollectionSegmentation
        activeRunHistory?.setNamesEstimate(taggingMode: taggingMode) { frozen.values[$0.rawValue]?.value }
        activeRunHistory?.outputDirectory = outputDirectory
        beginMonthlySpend(outputDirectory: outputDirectory)
        let pricedModel = activeRunHistory?.visionTextModel ?? model
        if monthlySpend != nil, !preOCRedInput || activeRunHistory?.classifyPreOCRedInput == true {
            let billing = await ClaudeCLIUsage.shared.refresh(config: localAgent)
            guard !Task.isCancelled else { return }
            if !ProcessFilesMonthlySpend.hasPrice(model: pricedModel, gateway: gatewayConfig,
                                                  localAgent: localAgent, claudeBilling: billing) {
                guard reserveMonthlySpend(nil, for: "this reader") else { return }
            }
        }
        activeRunToRecord = resumingMixedPDF == nil
            ? PendingCollectionRecord(snapshot: frozen, outputDirectory: outputDirectory, fileCount: files.count) : nil

        let paid = processPaidRequests(runID: frozen.runID, outputDirectory: outputDirectory)
        paidRequestScope = paid
        await paid.run(denyDataCollection: OpenRouterDataPolicy.deny(frozen.values)) {
            if autoReOCR {
                recordActiveRunInCollection(kind: mixedReOCR ? "mixed" : "reOCR")
                // --- PDF subset: pure render/OCR/rebuild, with no tagging or segmentation. ---
                if mixedReOCR {
                    progressRange = (start: 0, span: Double(pdfIndices.count) / Double(files.count))
                }
                await performMultiPagePDFReOCR(
                    files: pdfIndices.map { (jobIndex: $0, url: files[$0]) },
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    customPrompt: segmentationContext.customPrompt,
                    gatewayConfig: gatewayConfig,
                    localAgent: localAgent,
                    runConfig: runConfig
                )
                guard !Task.isCancelled, isProcessing, !stopIfMonthlyReadDeclined() else { cleanupTempFiles(); return }
                guard pdfIndices.allSatisfy({ jobs[$0].status == .succeeded || jobs[$0].status == .failed }) else {
                    activeRunHistory = nil
                    isProcessing = false
                    checkForPendingBatch()
                    return
                }
                if mixedReOCR {
                    guard let pending = activePendingMixedPDF,
                          Self.mixedPDFOutputsMatchJournal(pending) else {
                        activeRunHistory = nil
                        isProcessing = false
                        statusMessage = "A rebuilt PDF changed before image processing. The recovery record was kept for review."
                        checkForPendingBatch()
                        return
                    }
                    guard let outcomes = captureMixedPDFOutcomes(indices: pdfIndices) else {
                        activeRunHistory = nil
                        isProcessing = false
                        statusMessage = "The rebuilt PDF results could not be recorded safely. No images were processed."
                        return
                    }
                    mixedPDFOutcomes = outcomes
                    activeRunHistory?.pdfHalfRead = true
                }
                // Rebuilt PDFs have OCR text but bypass tagging. Use their own output instead of the later image subset.
                await recordLocalNameMentions(runConfig: runConfig, mode: runOutputSettings.taggingMode,
                                              rebuiltPDFs: Set(pdfIndices.map { files[$0] }))
                guard !Task.isCancelled else { cleanupTempFiles(); return }
                if mixedReOCR {
                    fullJobsAfterPDF = jobs
                    jobs = imageIndices.map { jobs[$0] }
                    editingImageSubset = true
                    progressRange = (start: Double(pdfIndices.count) / Double(files.count),
                                     span: Double(imageIndices.count) / Double(files.count))
                    if !preGroupedBoundaries.isEmpty {
                        preGroupedBoundaries = imageIndices.map { preGroupedBoundaries[$0] }
                        preGroupedTypes = imageIndices.map { preGroupedTypes[$0] }
                        if !preGroupedQualities.isEmpty {
                            fullQualitiesAfterPDF = preGroupedQualities
                            preGroupedQualities = imageIndices.map { preGroupedQualities[$0] }
                        }
                        if !preGroupedYears.isEmpty { preGroupedYears = imageIndices.map { preGroupedYears[$0] } }
                        if !preGroupedMonths.isEmpty { preGroupedMonths = imageIndices.map { preGroupedMonths[$0] } }
                        if !preGroupedSubjects.isEmpty { preGroupedSubjects = imageIndices.map { preGroupedSubjects[$0] } }
                    }
                }
            }
            if preOCRedInput {
                // --- Pre-OCRed PDF path: extract text, classify, skip PDF generation ---
                // A Vision-hybrid selection has no image work on this route either. Reuse its text
                // judgement backend rather than presenting Apple Vision as a network text provider.
                guard reserveMonthlySpend(activeRunHistory?.estimatedCost ?? 0, for: "processing these PDFs") else { return }
                // This route keeps no pending record, so the collection's run record is its only frozen settings.
                recordActiveRunInCollection(kind: "preOCRed")
                await performPreOCRedProcessing(
                    files: files,
                    provider: runConfig.textProvider,
                    model: runConfig.textModel,
                    thinkingLevel: runConfig.textThinkingLevel,
                    apiKey: runConfig.textAPIKey,
                    outputDirectory: outputDirectory,
                    enableTagging: enableTagging,
                    enableSegmentJSON: enableSegmentJSON,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    confirmCollectionIDs: confirmCollectionIDs,
                    reviewWholeRun: reviewWholeRun,
                    customPrompt: segmentationContext.customPrompt,
                    runConfig: runConfig,
                    settings: activeResolvedSettings
                )
                guard !Task.isCancelled, isProcessing else { return }
            } else if !autoReOCR || mixedReOCR {
                // --- Standard path: all inputs except the multi-page PDFs already rebuilt above. ---
                let files = mixedReOCR ? imageIndices.map { files[$0] } : files
                statusMessage = "Starting OCR…"

                // Convert any PDF inputs to temporary JPEG images
                let imageURLs = convertPDFInputs(files)

                // Phase 1: OCR + Classification
                if useBatch {
                    await performBatchOCR(
                        fileURLs: imageURLs,
                        originalFiles: files,
                        provider: provider,
                        model: model,
                        thinkingLevel: thinkingLevel,
                        apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        sendPreviousImage: segmentationContext.sendPreviousImage,
                        enableTagging: enableTagging,
                        enableCollectionSegmentation: enableCollectionSegmentation,
                        enableSegmentJSON: enableSegmentJSON,
                        confirmCollectionIDs: confirmCollectionIDs,
                        reviewDocumentSegmentation: reviewDocumentSegmentation,
                        reviewWholeRun: reviewWholeRun,
                        customPrompt: segmentationContext.customPrompt,
                        imageScale: segmentationContext.imageScale,
                        runConfig: runConfig,
                        mixedPDFOutcomes: mixedPDFOutcomes
                    )
                    // Transient interruption during batch polling: the batch is preserved (resumable) and
                    // no file was falsely failed. Stop cleanly rather than tagging/finalizing partial results.
                    // The SAME tail as the resume site (W16.bat4) — resetting `isProcessing` alone left the
                    // Resume control the interruption message names unrendered until the operator pressed Start
                    // and was refused, and leaked this run's temp JPEGs. Reached by all FIVE of
                    // `performBatchOCR`'s interrupted exits: journal-save failure, a submission that stopped
                    // part-way, a journal/ID disagreement, a `markBatchSubmissionComplete()` that could not
                    // persist (W16.bat3-fu — the one that used to leave silently), and the poll's own
                    // timeout / error streak.
                    if batchPollInterrupted {
                        finishInterruptedBatchPoll()
                        return
                    }
                } else {
                    // Create a complete, versioned snapshot before the first non-batch OCR request. The v2
                    // fingerprint covers ordered inputs + every run/backend/runtime setting and is recomputed
                    // with each incrementally-persisted result/output association.
                    let runtimeConfig = makePendingRunSnapshot(
                        imageScale: segmentationContext.imageScale,
                        gatewayConfig: gatewayConfig,
                        runConfig: runConfig)
                    var pendingRun = PendingRun(
                        provider: provider, model: model, thinkingLevel: thinkingLevel,
                        fileURLs: files, outputDirectory: outputDirectory,
                        enableTagging: enableTagging, enableSegmentJSON: enableSegmentJSON,
                        enableCollectionSegmentation: enableCollectionSegmentation,
                        confirmCollectionIDs: confirmCollectionIDs,
                        reviewDocumentSegmentation: reviewDocumentSegmentation,
                        preOCRedInput: false,
                        previousTextCharCount: segmentationContext.previousTextCharCount,
                        sendPreviousImage: segmentationContext.sendPreviousImage,
                        customPrompt: segmentationContext.customPrompt,
                        startedAt: Date(), gatewayConfig: gatewayConfig,
                        completedResults: [:],
                        runFingerprint: nil,
                        exportOriginals: exportOriginals,
                        localAgent: localAgent,
                        runtimeConfig: runtimeConfig
                    )
                    pendingRun.mixedPDFOutcomes = mixedPDFOutcomes
                    pendingRun.resolvedSettings = activeResolvedSettings
                    pendingRun.reviewWholeRun = reviewWholeRun
                    guard let fingerprint = Self.pendingRunFingerprintV2(pendingRun) else {
                        cleanupTempFiles()
                        activeRunHistory = nil
                        isProcessing = false
                        statusMessage = "Could not create a safe resume snapshot. No OCR requests were sent."
                        return
                    }
                    pendingRun.runFingerprint = fingerprint
                    guard Self.pendingRunIsSelfConsistent(pendingRun) else {
                        cleanupTempFiles()
                        activeRunHistory = nil
                        isProcessing = false
                        statusMessage = "The run settings could not be captured safely. No OCR requests were sent."
                        return
                    }
                    activePendingRun = pendingRun
                    guard Self.savePendingRun(pendingRun) else {
                        cleanupTempFiles()
                        activePendingRun = nil
                        activeRunHistory = nil
                        isProcessing = false
                        statusMessage = "Could not save the resume snapshot. No OCR requests were sent."
                        return
                    }
                    recordActiveRunInCollection(kind: "processFiles")
                    // Each reading is journaled before its write, so the PDFs wait for the reviews
                    // (W49.proc-unified-pipeline-2, `materializeDeferredOutputs`).
                    defersOutputWrites = true
                    if activePendingMixedPDF != nil {
                        if catalogueRun == nil { Self.deletePendingMixedPDF() }
                        activePendingMixedPDF = nil
                        pendingMixedPDFInfo = nil
                    }

                    await performOCRPhase(
                        fileURLs: imageURLs,
                        provider: provider,
                        model: model,
                        thinkingLevel: thinkingLevel,
                        apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        segmentationContext: segmentationContext,
                        runConfig: runConfig
                    )
                }

                guard !Task.isCancelled, isProcessing else { cleanupTempFiles(); return }

                // Phase 1b: Retry files that failed due to high use
                await retryHighUseFailures(
                    fileURLs: imageURLs,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    runConfig: runConfig
                )

                guard !Task.isCancelled, isProcessing, !stopIfMonthlyReadDeclined() else { cleanupTempFiles(); return }

                // Phase 1c: Prompt user to retry remaining failures with different provider/model
                await retryLoopForFailedFiles(
                    imageURLs: imageURLs,
                    outputDirectory: outputDirectory,
                    runConfig: runConfig
                )

                guard !Task.isCancelled, isProcessing else { cleanupTempFiles(); return }

                // The shared stages after OCR (W49.proc-unified-pipeline-1): reviews, segmentation, tagging,
                // collections, the late header and quality writes, the dual-output images and merge.
                let plan = PostOCRPlan(
                    origin: .fresh, files: files, outputDirectory: outputDirectory, runConfig: runConfig,
                    settings: activeResolvedSettings,
                    text: .init(provider: runConfig.textProvider, model: runConfig.textModel,
                                thinkingLevel: runConfig.textThinkingLevel, apiKey: runConfig.textAPIKey),
                    enableTagging: enableTagging, enableSegmentJSON: enableSegmentJSON,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    confirmCollectionIDs: confirmCollectionIDs,
                    reviewWholeRun: reviewWholeRun, reviewRotation: reviewRotation && rotationMode != .off,
                    phoneGroupsApply: true)
                guard await runPostOCRStages(plan) else { return }
            }

            guard !Task.isCancelled else { return }
            if editingImageSubset, let fullJobsAfterPDF {
                var restored = fullJobsAfterPDF
                for (subsetIndex, originalIndex) in imageIndices.enumerated() {
                    restored[originalIndex] = jobs[subsetIndex]
                }
                jobs = restored
                if let qualities = restoredQualities() { preGroupedQualities = qualities }
                editingImageSubset = false
                progressRange = nil
            }
            await completeRun(RunCompletion(
                outputDirectory: outputDirectory, enableTagging: enableTagging,
                enableCollectionSegmentation: enableCollectionSegmentation, preOCRed: preOCRedInput,
                exportingImages: preOCRedInput ? false : runOutputSettings.exportOriginals,
                stampsUnread: runOutputSettings.stampUnread, incrementalSkipped: incrementalSkipped))
        }
    }
    /// Called by UI when the operator chooses to replay the failed files on the run's locked backend.
    func retryFailedFiles() {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .retry)
        retryContinuation = nil
    }
    /// Called by UI when user chooses to continue without retrying.
    func continueWithoutRetry() {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .continueWithout)
        retryContinuation = nil
    }
    /// Present retry dialog and wait for user decision. Returns the action chosen.
    private func promptRetryForFailedFiles() async -> RetryAction {
        guard !Task.isCancelled else { return .continueWithout }   // don't install a continuation for a cancelled run
        failedFileIndices = jobs.indices.filter { jobs[$0].status == .failed }.sorted()
        guard !failedFileIndices.isEmpty else { return .continueWithout }

        statusMessage = "\(failedFileIndices.count) file(s) failed OCR. Review and retry or continue."
        awaitingRetryDecision = true

        return await withCheckedContinuation { continuation in
            retryContinuation = continuation
        }
    }
    /// Retry loop: keeps presenting the retry dialog until all files succeed or user continues.
    private func retryLoopForFailedFiles(
        imageURLs: [URL],
        outputDirectory: URL,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        while true {
            guard !Task.isCancelled else { return }

            let failedCount = jobs.filter { $0.status == .failed }.count
            guard failedCount > 0 else { return }

            let action = await promptRetryForFailedFiles()

            switch action {
            case .continueWithout:
                return
            case .retry:
                guard let retryConfig = runConfigForRetry(runConfig) else {
                    statusMessage = "Cannot retry: the original run configuration is unavailable."
                    return
                }
                guard !stopForUnavailableOpenRouterModel(provider: retryConfig.provider, model: retryConfig.model)
                else { return }
                let indicesToRetry = failedFileIndices
                statusMessage = "Retrying \(indicesToRetry.count) files with \(retryConfig.retryBackendDescription)…"

                for (attempt, index) in indicesToRetry.enumerated() {
                    guard !Task.isCancelled else { return }
                    _ = await retryOne(index: index, imageURL: imageURLs[index],
                                       outputDirectory: outputDirectory, runConfig: retryConfig)
                    guard !Task.isCancelled, isProcessing, !stopIfMonthlyReadDeclined() else { return }
                    progress = Double(attempt + 1) / Double(indicesToRetry.count)
                    statusMessage = "Retried \(attempt + 1)/\(indicesToRetry.count)"
                }
            }
            // Loop back — if there are still failures, the dialog will appear again
        }
    }

    /// An explicit caller snapshot wins; post-run per-item actions reuse the snapshot retained by the
    /// original fresh run. Resume leaves both nil until W16.cfg5, preserving its static fallback meanwhile.
    func runConfigForRetry(_ explicit: SessionProcessingConfig?) -> SessionProcessingConfig? {
        explicit ?? activeRunConfig
    }

    /// The user-visible identity of a retry's actual backend. It is computed only from the immutable run
    /// snapshot, never from current Settings, so a retry cannot silently change route or authentication.
    var retryBackendDescription: String {
        activeRunConfig?.retryBackendDescription ?? "the original run configuration"
    }

    /// Re-OCR a single file, then regenerate its output PDF (+ re-prune `failedFiles`). Extracted from the
    /// modal retry loop so the end-of-run modal AND per-item retry share one path — no duplicate logic.
    /// `imageURL` is the OCR input (may be a temp JPEG for pre-OCRed PDF input); it defaults to the job's
    /// source. `rotation` (if non-nil) forces the output rotation instead of the detected one (rotate &
    /// re-run). Returns whether OCR text was produced. Reuses `performOCRCall` + `handleOCRResult` verbatim
    /// (`handleOCRResult` already updates `jobs[index].status` and prunes/appends `failedFiles`).
    @discardableResult
    func retryOne(index: Int, imageURL: URL? = nil, outputDirectory: URL,
                  rotation: Int? = nil, runConfig: SessionProcessingConfig? = nil) async -> Bool {
        guard jobs.indices.contains(index), let effectiveRunConfig = runConfigForRetry(runConfig) else {
            return false
        }
        guard !reOCRSourceURLs.contains(jobs[index].sourceURL) else {
            statusMessage = "This rebuilt PDF must be re-OCR'd as a multi-page document in a new run."
            return false
        }
        if effectiveRunConfig.provider == .openrouter, effectiveRunConfig.gateway == nil, effectiveRunConfig.localAgent == nil,
           let warning = OpenRouterRoute.unavailableSelection(effectiveRunConfig.model.id) {
            if isProcessing {
                stopForUnavailableOpenRouterModel(provider: .openrouter, model: effectiveRunConfig.model,
                                                  knownUnavailable: true)
            } else {
                statusMessage = warning
            }
            return false
        }
        let denyDataCollection = OpenRouterDataPolicy.deny(activeResolvedSettings?.values)
        let standalone = catalogueRunLease == nil
        let source = jobs[index].sourceURL
        let previousOutput = outputURLMap[source]
        if standalone {
            guard !isProcessing else { return false }
            guard SearchableArchival.isAvailable else {
                statusMessage = "Retry needs the PDF preparation tool. The existing files are intact."
                return false
            }
            guard await beginCatalogueRun(outputRoot: outputDirectory, sources: [source],
                                          keepPreservationCopies: effectiveRunConfig.keepPreservationCopies) else { return false }
            isProcessing = true
            defersOutputWrites = false   // a retry after the run files its output itself, at once
        }
        defer {
            if standalone {
                catalogueRunLease = nil
                isProcessing = false
                checkForPendingBatch()
            }
        }
        let paid = PaidRequests.context ?? processPaidRequests(runID: activeResolvedSettings?.runID,
                                                               outputDirectory: outputDirectory)
        if standalone { paidRequestScope = paid }
        let succeeded = await paid.run(denyDataCollection: denyDataCollection) {
            let ocrURL = imageURL ?? PDFToImageConverter.imageURL(for: source)
            defer {
                if imageURL == nil, ocrURL != source { try? FileManager.default.removeItem(at: ocrURL) }
            }
            guard reserveMonthlyImage(ocrURL, runConfig: effectiveRunConfig, retry: true) else { return false }
            let previousStatus = jobs[index].status
            jobs[index].status = .processing
            // W16.bat10 — the row this retry is FOR. `ocrURL` cannot stand in for it: for a pre-OCRed PDF (or a
            // rotate-and-re-run) it is a temp JPEG that is deliberately NOT the job's source, which is exactly
            // why the identity threaded into `handleOCRResult` is the job's id rather than a URL comparison.
            let jobID = jobs[index].id
            let ocrRun = Self.ocrCallValues(for: effectiveRunConfig)
            let scanDetector = NewspaperDetector.scans(activeResolvedSettings?.values)
            let newspaperSpend = activeRunHistory?.newspaperSpend
            let postCorrection = newspaperSpend == nil ? nil : activePostCorrection
            var result = await Self.performOCRCall(
                imageURL: ocrURL, provider: effectiveRunConfig.provider, model: effectiveRunConfig.model,
                thinkingLevel: effectiveRunConfig.thinkingLevel, apiKey: effectiveRunConfig.apiKey,
                previousText: nil, previousImageURL: nil, gatewayConfig: effectiveRunConfig.gateway,
                localAgent: effectiveRunConfig.localAgent, rotationMode: ocrRun.rotationMode,
                standardImageMB: ocrRun.standardImageMB,
                // W41.app-institutional-compute: no import here. A Retry (or Rotate & re-run) is the user asking for a fresh
                // read, and an imported page matches its institutional-computing text again by its bytes (Tier-2 review).
                visionSettings: ocrRun.visionSettings, cascade: ocrRun.cascade, readers: ocrRun.readers, imported: nil, newspaperSpend: newspaperSpend,
                scanDetector: scanDetector, postCorrection: postCorrection)
            if result.errorCode == OpenRouterRoute.unavailableModelCode, !Task.isCancelled {
                guard jobs.indices.contains(index), jobs[index].id == jobID else { return false }
                jobs[index].status = previousStatus
                if isProcessing {
                    stopForUnavailableOpenRouterModel(provider: .openrouter, model: effectiveRunConfig.model,
                                                      knownUnavailable: true)
                } else {
                    statusMessage = OpenRouterRoute.unavailableMessage(effectiveRunConfig.model.id)
                }
                return false
            }
            if let rotation {
                result = OCRResult(text: result.text, classification: result.classification,
                                   rotationDegrees: ((rotation % 360) + 360) % 360,
                                   errorMessage: result.errorMessage, errorCode: result.errorCode,
                                   enclosure: result.enclosure, ocrClassification: .some(result.ocrClassification), ocrEnclosure: .some(result.ocrEnclosure),
                                   secondReader: result.secondReader, pageReader: result.pageReader, imported: result.imported,
                                   readingCodes: result.readingCodes, newspaperLayout: result.newspaperLayout,
                                   readPoorly: result.readPoorly, imageCorrectionApplied: result.imageCorrectionApplied)
            }
            result = await Self.applyingVisionTextClassification(
                to: result, previousText: nil, customPrompt: effectiveRunConfig.customOCRPrompt,
                configuration: effectiveRunConfig.provider == .appleVision
                    ? effectiveRunConfig.visionTextLLM : nil)
            if monthlyStopMessage != nil, result.text == nil {
                if jobs.indices.contains(index), jobs[index].id == jobID { jobs[index].status = previousStatus }
                return false
            }
            let persisted = await handleOCRResult(
                result, index: index, jobID: jobID, url: ocrURL, model: effectiveRunConfig.model,
                outputDirectory: outputDirectory, runConfig: effectiveRunConfig)
            return persisted && result.text != nil
        }
        guard standalone else { return succeeded }
        if let message = monthlyStopMessage {
            monthlyStopMessage = nil
            if !succeeded {
                statusMessage = message
                return false
            }
        }
        guard !Task.isCancelled, isProcessing else {
            outputURLMap[source] = previousOutput
            return false
        }
        let stampsUnread = lateRunOutputSettings(for: effectiveRunConfig).stampUnread
        guard await finishCatalogueRun(organizing: false, preOCRed: false, exportingImages: false,
                                       stampsUnread: stampsUnread) != nil else {
            outputURLMap[source] = previousOutput
            return false
        }
        statusMessage = (succeeded ? "Retry filed a new PDF." : "Retry did not return OCR text.") + catalogueFilingWarning
        return succeeded
    }
    /// Resolve the stage once for the run. A resume honours both the original policy and any tighter current policy.
    private static func makePostCorrection(
        requested: Bool, gateway: GatewayConfig?, localAgent: LocalAgentConfig?, outputDirectory: URL,
        frozen: [String: ResolvedSetting]?
    ) -> OCRPostCorrection? {
        guard requested, gateway == nil, localAgent == nil,
              OCRPostCorrection.policyReason(frozen) == nil else {
            return nil
        }
        guard OCRPostCorrection.policyReason(at: outputDirectory, store: .shared) == nil,
              let key = KeychainHelper.load(account: LLMProvider.openrouter.rawValue), !key.isEmpty else {
            return nil
        }
        return OCRPostCorrection(apiKey: key)
    }

    /// Request notification permission (call once at app launch).
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Post a local notification summarizing the completed run.
    func postCompletionNotification() {
#if DEBUG
        if ProcessInfo.processInfo.environment["TEXTLAYER_TEST"] == "1" { return }
#endif
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let failed = failedFiles.count
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        content.body = "\(succeeded) succeeded, \(failed) failed."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    /// W49.proc-fix-s042 — the run log's section for failed tagging calls; empty when every call answered.
    nonisolated static func taggingFailureLogLines(_ failures: [(name: String, reason: String)]) -> [String] {
        guard !failures.isEmpty else { return [] }
        return ["", "Documents whose tagging call failed (filed with no subject tags from the model;"
                    + " named by their first input file):"]
            + failures.map { "  \u{2022} \($0.name): \($0.reason)" }
    }
    func recordFileFailure(for source: URL, result: OCRResult) {
        failedFiles[source.standardizedFileURL.path] = ProcessFileFailure(
            reason: result.errorMessage ?? "No OCR text", code: result.errorCode)
    }

    func clearFileFailure(for source: URL) {
        failedFiles.removeValue(forKey: source.standardizedFileURL.path)
    }

    func writeLogFile(outputDirectory: URL, enabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKeys.writeLogFile)) {
        // Opt-in: only write the log when the user has enabled it (default off).
        guard enabled else { return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMMM yyyy HH:mm"
        let dateStr = dateFormatter.string(from: Date())

        var lines = ["Archive Processor — OCR Log", "Date: \(dateStr)", ""]
        let removedCount = jobs.filter { $0.status == .removed }.count
        lines.append("Total files: \(jobs.count)")
        lines.append("Succeeded: \(jobs.filter { $0.status == .succeeded }.count)")
        lines.append("Failed: \(failedFiles.count)")
        if removedCount > 0 { lines.append("Removed during review: \(removedCount)") }
        if !segments.isEmpty {
            lines.append("Document segments: \(segments.count)")
        }
        lines.append("")

        if failedFiles.isEmpty {
            lines.append("All files processed successfully.")
        } else {
            lines.append("Failed input files:")
            for (path, failure) in failedFiles.sorted(by: { $0.key < $1.key }) {
                let code = failure.code.map { " [\($0)]" } ?? ""
                lines.append("  \u{2022} \(path)\(code): \(failure.reason)")
            }
        }

        // W23.m5 / W23.h5-fu — the two failures that leave a file looking fine. The status line names
        // at most three; this log is the complete list, so it is the one place an operator can work
        // through them file by file.
        if !untaggedOutputs.isEmpty {
            lines.append("")
            lines.append("Input files whose output was written WITHOUT Finder tags"
                       + " (tag search will not find it):")
            for name in untaggedOutputs { lines.append("  \u{2022} \(name)") }
        }
        if !placeholderOutputs.isEmpty {
            lines.append("")
            lines.append("Input files whose output PDF holds a PLACEHOLDER image page, not the scan"
                       + " (the source image was not touched):")
            for name in placeholderOutputs { lines.append("  \u{2022} \(name)") }
        }
        let rotationRows = jobs.compactMap { job -> String? in
            guard job.status == .succeeded, let result = job.result else { return nil }
            var notes: [String] = []
            if result.comparativeRotationFailed == true {
                notes.append("Comparative rotation check failed. Apple Vision checked rotation instead.")
            }
            if result.rotationUnsure == true {
                notes.append(result.rotationDegrees % 360 == 0
                    ? "Left unturned, rotation unsure." : "Turned \(result.rotationDegrees)°, rotation unsure.")
            }
            guard !notes.isEmpty else { return nil }
            return "  \u{2022} \(job.sourceURL.lastPathComponent): " + notes.joined(separator: " ")
        }
        if !rotationRows.isEmpty { lines += ["", "Rotation warnings:"] + rotationRows }

        lines += Self.taggingFailureLogLines(taggingFailureNames)
        if !textPageOnlyOutputs.isEmpty {
            lines.append("")
            lines.append("Pages with no searchable text on the image (their text is on the text page):")
            for entry in textPageOnlyOutputs { lines.append("  \u{2022} \(entry.name): \(entry.reason)") }
        }
        if !searchableFormNotes.isEmpty {
            lines.append("")
            lines.append("Pages set to be one searchable page, with no text page:")
            for entry in searchableFormNotes { lines.append("  \u{2022} \(entry.name): \(entry.note)") }
        }

        let rebuiltPDFRows = jobs.compactMap { job -> [String]? in
            guard job.status == .succeeded, let notes = job.pdfLayerLogNotes, !notes.isEmpty else { return nil }
            return ["  \u{2022} \(job.sourceURL.lastPathComponent):"] + notes.map { "    \($0)" }
        }
        if !rebuiltPDFRows.isEmpty {
            lines += ["", "Searchable text on the image in rebuilt PDFs:"]
            lines += rebuiltPDFRows.flatMap { $0 }
        }

        let content = lines.joined(separator: "\n")
        let timestamp = Int(Date().timeIntervalSince1970)
        let logURL = outputDirectory.appendingPathComponent("ArchiveProcessor_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
