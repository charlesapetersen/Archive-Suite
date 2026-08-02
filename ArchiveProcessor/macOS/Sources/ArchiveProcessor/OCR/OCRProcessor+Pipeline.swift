import Foundation
import UserNotifications
import CryptoKit

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
        let runtimeConfig: PendingRunRuntimeConfig
        let completedResults: [String: OCRResult]
        let completedOutputPaths: [String: String]?

        init(run: PendingRun, runtimeConfig: PendingRunRuntimeConfig) {
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
        }
    }

    /// Compute the v2 identity hash. Nil means the snapshot could not be encoded; callers must not start
    /// a resumable paid run in that state.
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
        repaired.lifecycleFingerprint = nil
        return repaired
    }

    /// Structural validation is separate from the fingerprint. A locally-edited manifest could carry a
    /// freshly recomputed hash, so bound every value before it can control concurrency/sizing and require
    /// all Live Capture parallel arrays to be either absent or aligned with the ordered input list.
    nonisolated static func pendingRunRuntimeConfigIsValid(
        _ config: PendingRunRuntimeConfig,
        fileCount: Int,
        enableTagging: Bool,
        hasGateway: Bool
    ) -> Bool {
        guard config.schemaVersion == PendingRunRuntimeConfig.currentSchemaVersion,
              enableTagging == config.taggingMode.enablesTagging,
              config.passSourceTags == (config.taggingMode == .copySource),
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
              hasGateway == (config.gatewayUpstreamProvider != nil) else { return false }

        let optionalParallelCounts = [
            config.preGroupedPriorities.count,
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

    /// Capture the effective runtime values used by this run. Production callers supply their immutable
    /// config; with none, W16.cfg6 persists a fresh `runSizing()` read rather than the deleted statics —
    /// so a manifest can never record sizing values inherited from an unrelated earlier run.
    func makePendingRunRuntimeConfig(
        imageScale: Double,
        gatewayConfig: GatewayConfig?,
        runConfig: SessionProcessingConfig? = nil
    ) -> PendingRunRuntimeConfig {
        let effectiveScale = imageScale.isFinite ? max(0.01, min(1.0, imageScale)) : 1.0
        let sizing = runConfig?.runSizing ?? SessionProcessingConfig.runSizing()
        return PendingRunRuntimeConfig(
            schemaVersion: PendingRunRuntimeConfig.currentSchemaVersion,
            taggingMode: taggingMode,
            passSourceTags: passSourceTags,
            rotationMode: rotationMode,
            reviewRotation: reviewRotation,
            mergeDocuments: mergeDocuments,
            tagVocabulary: tagVocabulary,
            imageScale: effectiveScale,
            exportOriginals: exportOriginals,
            preGroupedBoundaries: preGroupedBoundaries,
            preGroupedTypes: preGroupedTypes,
            preGroupedPriorities: preGroupedPriorities,
            preGroupedYears: preGroupedYears,
            preGroupedMonths: preGroupedMonths,
            preGroupedSubjects: preGroupedSubjects,
            standardImageMB: sizing.standardImageMB,
            ocrWorkerCount: sizing.ocrWorkerCount,
            pdfImageMB: sizing.pdfImageMB,
            textColumns: sizing.textColumns,
            exportedImageMB: sizing.exportedImageMB,
            gatewayUpstreamProvider: gatewayConfig == nil ? nil : Self.gatewayUpstreamProviderFromDefaults()
        )
    }

    /// Build the single run config used by a resumed non-batch run. A v2 manifest overlays every persisted
    /// runtime value onto the current builder; a legacy manifest has no such snapshot, so it intentionally
    /// keeps the historical current-default fallback while restoring the identity fields it did persist.
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
        runConfig.contextCharCount = pending.previousTextCharCount
        runConfig.sendPreviousImage = pending.sendPreviousImage
        runConfig.customOCRPrompt = pending.customPrompt ?? ""
        runConfig.enableSegmentJSON = pending.enableSegmentJSON
        runConfig.gateway = pending.gatewayConfig
        runConfig.localAgent = pending.localAgent

        if let runtime = pending.runtimeConfig {
            runConfig.taggingMode = runtime.taggingMode
            runConfig.rotationMode = runtime.rotationMode
            runConfig.mergeDocuments = runtime.mergeDocuments
            runConfig.tagVocabulary = runtime.tagVocabulary
            runConfig.imageScale = runtime.imageScale
            runConfig.standardImageMB = runtime.standardImageMB
            runConfig.ocrWorkerCount = runtime.ocrWorkerCount
            runConfig.outputImageFile = runtime.exportOriginals
            runConfig.pdfImageMB = runtime.pdfImageMB
            runConfig.exportedImageMB = runtime.exportedImageMB
            runConfig.textColumns = runtime.textColumns
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
        runConfig.contextCharCount = 0
        runConfig.sendPreviousImage = pending.sendPreviousImage
        runConfig.customOCRPrompt = pending.customPrompt ?? ""
        runConfig.imageScale = Self.liveImageScaleFraction(defaults)
        runConfig.enableSegmentJSON = pending.enableSegmentJSON
        runConfig.gateway = nil
        runConfig.localAgent = nil
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
    }

    /// Apply exactly the instance/runtime-only values captured above. `pendingRunIsSelfConsistent`
    /// validates the snapshot before this is called; sizing, scheduling, and rotation now travel through
    /// `SessionProcessingConfig` instead of being fanned back out to process-global statics.
    func applyPendingRunRuntimeConfig(_ config: PendingRunRuntimeConfig) {
        taggingMode = config.taggingMode
        passSourceTags = config.passSourceTags
        rotationMode = config.rotationMode
        reviewRotation = config.reviewRotation
        mergeDocuments = config.mergeDocuments
        tagVocabulary = config.tagVocabulary
        exportOriginals = config.exportOriginals
        preGroupedBoundaries = config.preGroupedBoundaries
        preGroupedTypes = config.preGroupedTypes
        preGroupedPriorities = config.preGroupedPriorities
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

    /// Recompute a manifest's fingerprint from its OWN persisted fields and compare to the stored one.
    /// A mismatch means the file is torn/tampered/internally inconsistent (still-valid JSON but not a
    /// coherent run) → callers ignore it rather than misapply it. A v2 manifest must carry a complete,
    /// structurally valid runtime snapshot and matching v2 fingerprint; only legacy manifests may omit
    /// the fingerprint for backward compatibility.
    nonisolated static func pendingRunIsSelfConsistent(_ run: PendingRun) -> Bool {
        if let config = run.runtimeConfig {
            let validResultKeys = run.completedResults.keys.allSatisfy { key in
                guard let index = Int(key) else { return false }
                return key == String(index) && index >= 0 && index < run.fileURLs.count
            }
            let outputPaths = run.completedOutputPaths ?? [:]
            let validOutputPaths = Set(outputPaths.keys) == Set(run.completedResults.keys)
                && outputPaths.allSatisfy { key, path in
                guard run.completedResults[key] != nil else { return false }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                return NSString(string: path).isAbsolutePath
                    && url.pathExtension.lowercased() == "pdf"
                    && url.deletingLastPathComponent().path == run.outputDirectory.standardizedFileURL.path
            }
            guard pendingRunRuntimeConfigIsValid(
                config, fileCount: run.fileURLs.count, enableTagging: run.enableTagging,
                hasGateway: run.gatewayConfig != nil),
                  !run.fileURLs.isEmpty,
                  !run.preOCRedInput,
                  (0...20_000).contains(run.previousTextCharCount),
                  run.gatewayConfig == nil || run.localAgent == nil,
                  run.enableCollectionSegmentation
                    || (!run.confirmCollectionIDs && !run.reviewDocumentSegmentation),
                  validResultKeys, validOutputPaths,
                  let stored = run.runFingerprint,
                  let computed = pendingRunFingerprintV2(run) else { return false }
            return stored == computed
        }
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
        guard let lifecycleVersion = batch.lifecycleVersion else { return true }
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
        let outputPaths = batch.completedOutputPaths ?? [:]
        let outputPathsAreValid = Set(outputPaths.keys) == Set(batch.completedResults.keys)
            && outputPaths.allSatisfy { key, path in
                guard batch.completedResults[key] != nil else { return false }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                return NSString(string: path).isAbsolutePath
                    && url.pathExtension.lowercased() == "pdf"
                    && url.deletingLastPathComponent().path
                        == batch.outputDirectory.standardizedFileURL.path
            }
        guard resultKeysAreValid, outputPathsAreValid,
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
        Self.loadPendingBatch()?.fileURLs
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

    // MARK: - Processing history (cost + run log)

    /// The upstream provider family a gateway run bills against — drives the estimator's image-token math.
    /// Read from the SAME `@AppStorage` key the pre-run cost pane uses, so a recorded gateway run's cost
    /// matches what the operator saw. Only meaningful while a gateway is active.
    static func gatewayUpstreamProviderFromDefaults() -> LLMProvider {
        LLMProvider(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.gatewayUpstreamProvider) ?? "") ?? .anthropic
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
        ProcessingHistoryStore.shared.record(snapshot.makeRun(succeeded: succeeded))
        activeRunHistory = nil
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
        if activePendingRun == nil, activePendingBatch != nil {
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

    /// Atomically advance the in-memory + on-disk paid-batch journal. The old durable snapshot remains
    /// authoritative if the replacement fails; callers stop immediately instead of continuing past it.
    @discardableResult
    func persistPendingBatchMutation(
        failureMessage: String,
        _ mutation: (inout PendingBatch) -> Void
    ) -> Bool {
        guard var candidate = activePendingBatch else { return false }
        mutation(&candidate)
        guard let persisted = Self.savePendingBatch(candidate) else {
            statusMessage = failureMessage
            batchPollInterrupted = true
            isProcessing = false
            processingTask?.cancel()
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

    @discardableResult
    func recordSubmittedBatchChunk(_ chunkId: String) -> Bool {
        let normalized = chunkId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains(",") else { return false }
        if activePendingBatch?.submittedChunkIds.contains(normalized) == true { return true }
        return persistPendingBatchMutation(
            failureMessage: "A paid batch chunk was created, but its server ID could not be saved. Submission stopped."
        ) { $0.submittedChunkIds.append(normalized) }
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
        return persistPendingBatchMutation(
            failureMessage: "Batch results were written, but chunk completion could not be saved. The batch was kept for recovery."
        ) { $0.consumedChunkIds.append(chunkId) }
    }
    /// File URLs from a pending run (for populating the file list on resume).
    var pendingRunFileURLs: [URL]? {
        Self.loadPendingRun()?.fileURLs
    }
    /// Check for persisted pending batch or run on launch.
    func checkForPendingBatch() {
        // Check for pending batch. A manifest that fails to decode (corrupt JSON) already loads as nil;
        // additionally ignore one that is self-inconsistent (torn/tampered — valid JSON but its stored
        // fingerprint no longer matches its own fields) rather than offering a resume that could misapply
        // it (Tier-2 rule e). The local file is NOT deleted for a batch — a paid server-side job may
        // still exist, and dropping the manifest would strand it — it is simply not surfaced.
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
                pendingRunInfo = "Interrupted run from \(dateStr): \(completed)/\(total) files completed via \(pending.provider.rawValue) \(pending.model.displayName)."
            } else {
                NSLog("[ArchiveProcessor] WARNING: pending RUN manifest failed the self-consistency check but is being PRESERVED (kept on disk so its cached results are not lost/re-charged).")
                pendingRunInfo = "An interrupted run was found but its manifest failed a self-consistency check (it may be torn or tampered). It has NOT been discarded; the manifest was kept for recovery."
            }
        } else {
            pendingRunInfo = nil
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
    /// (`processFiles`, after `performBatchOCR` returns — which covers all four of its interrupted exits).
    /// Pinned headlessly by `BatchInterruptTailContract` (W16.bat4).
    func finishInterruptedBatchPoll() {
        activeBatch = nil
        activePendingBatch = nil
        isProcessing = false
        cleanupTempFiles()
        checkForPendingBatch()
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
        guard !batchPollInterrupted else { return }
        Self.deletePendingBatch()
        activePendingBatch = nil
    }
    /// Dismiss a pending batch notification (deletes local state only — server-side batch continues).
    func dismissPendingBatch() {
        Self.deletePendingBatch()
        pendingBatchInfo = nil
    }
    /// Dismiss a pending run notification.
    func dismissPendingRun() {
        Self.deletePendingRun()
        pendingRunInfo = nil
    }
    /// Whether the persisted incomplete run is the SAME job as the current input+output+settings —
    /// i.e. resuming it would continue *this* selection, not a different one. Lets a caller auto-resume
    /// on a match and treat a non-match as a distinct (stale) run to ignore (Tier-2 rule e). Returns
    /// false when there is no pending run or it is self-inconsistent.
    func pendingRunMatches(files: [URL], outputDirectory: URL) -> Bool {
        guard let pending = Self.loadPendingRun(), Self.pendingRunIsSelfConsistent(pending),
              let fp = pending.runFingerprint else { return false }
        if pending.runtimeConfig != nil {
            let selectedPaths = files.map { $0.standardizedFileURL.path }
            let persistedPaths = pending.fileURLs.map { $0.standardizedFileURL.path }
            return selectedPaths == persistedPaths
                && outputDirectory.standardizedFileURL.path == pending.outputDirectory.standardizedFileURL.path
        }
        return fp == Self.runFingerprint(
            files: files, outputDirectory: outputDirectory,
            taggingMode: nil, enableTagging: pending.enableTagging, batchMode: false)
    }
    /// Batch counterpart of `pendingRunMatches`.
    func pendingBatchMatches(files: [URL], outputDirectory: URL) -> Bool {
        guard let pending = Self.loadPendingBatch(), Self.pendingBatchIsSelfConsistent(pending),
              let fp = pending.runFingerprint else { return false }
        let preserveOrder = pending.fingerprintVersion == 2
        return fp == Self.runFingerprint(
            files: files, outputDirectory: outputDirectory,
            taggingMode: pending.taggingMode, enableTagging: pending.enableTagging, batchMode: true,
            preserveInputOrder: preserveOrder)
    }
    /// Resume polling a previously submitted batch.
    func resumeBatch(apiKey: String) async {
        // Ignore a torn/tampered manifest rather than misapply it (Tier-2 rule e).
        guard var pending = Self.loadPendingBatch(), Self.pendingBatchIsSelfConsistent(pending) else { return }

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
        pendingBatchInfo = nil
        failedFiles = []
        clearOutputWarnings()
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        _takenOutputPaths = []
        exportedImageMap = [:]
        currentModel = pending.model
        let runConfig = makePendingBatchResumeConfig(pending, apiKey: apiKey)
        applyResumeConfig(runConfig)
        activeRunConfig = runConfig
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
        // Jobs carry the ORIGINAL source URLs (correct output names + tag targets). For PDF inputs the
        // persisted temp JPEGs are long gone, so regenerate them from the originals — exactly like
        // resumeRun — and feed the temp images (not the .pdf) to the result/PDF-embed + retry paths.
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        let imageURLs = convertPDFInputs(pending.fileURLs)
        for i in jobs.indices { jobs[i].status = .processing }

        // Restore already-materialized files before polling. Their exact source→output associations are
        // reused verbatim; processBatchResults also skips these indices if it re-fetches an open chunk.
        let restoredOutputs = Self.resolveResumeOutputURLs(
            completedResults: pending.completedResults,
            completedOutputPaths: pending.completedOutputPaths,
            sourceURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory)
        for (key, result) in pending.completedResults {
            guard let index = Int(key), jobs.indices.contains(index) else { continue }
            jobs[index].result = result
            jobs[index].classification = result.classification
            jobs[index].status = result.text == nil ? .failed : .succeeded
            if result.text == nil {
                let name = jobs[index].sourceURL.lastPathComponent
                if !failedFiles.contains(name) { failedFiles.append(name) }
            }
            if let outputURL = restoredOutputs[index], FileManager.default.fileExists(atPath: outputURL.path) {
                outputURLMap[jobs[index].sourceURL] = outputURL
                _takenOutputPaths.insert(outputURL.standardizedFileURL.path.lowercased())
            }
        }
        progress = 0
        statusMessage = "Resuming batch…"

        // History snapshot for the resumed batch (see RunHistorySnapshot.init(resuming batch:…)).
        activeRunHistory = RunHistorySnapshot(
            resuming: pending, rotationMode: runConfig.rotationMode, imageScale: runConfig.imageScale)

        activeBatch = BatchContext(
            batchId: pending.batchId, apiKey: apiKey,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            provider: pending.provider
        )
        activePendingBatch = pending

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
        Self.deletePendingBatch()
        activeBatch = nil
        activePendingBatch = nil

        guard !Task.isCancelled else { return }

        await retryHighUseFailures(
            fileURLs: imageURLs, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled else { return }

        await retryLoopForFailedFiles(
            imageURLs: imageURLs,
            outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled else { return }

        // Tagging (before collection segmentation, matching main workflow order).
        // Switch on the persisted taggingMode so a batch submitted in Human / Auto-date / manual-seg
        // mode isn't silently downgraded to automatic tagging after a relaunch (and .none/.copySource
        // correctly skip LLM tagging).
        if pending.enableTagging && !passSourceTags {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            switch runOutputSettings.taggingMode {
            case .automatic:
                // Batch resume intentionally uses performTaggingPhase (NOT performAutomaticTaggingWithReview):
                // a resumed batch has no interactive session to drive the redo-review loop, so it tags straight
                // through. (The interactive run path uses the review loop; this divergence is deliberate.)
                await performTaggingPhase(
                    provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    runConfig: runConfig
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: runOutputSettings.taggingMode, provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory, enableSegmentJSON: pending.enableSegmentJSON,
                    runConfig: runConfig
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: runOutputSettings.taggingMode.autoFillsDate,
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON, preOCRed: false, files: pending.fileURLs,
                    runConfig: runConfig
                )
            case .none, .copySource:
                break
            }
        }

        guard !Task.isCancelled else { return }

        // Collection segmentation (after tagging)
        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                confirmBeforeOrganizing: pending.confirmCollectionIDs,
                reviewDocumentSegmentation: pending.reviewDocumentSegmentation,
                runConfig: runConfig
            )

            applyBoxFolderLabelTags(enableTagging: pending.enableTagging, runConfig: runConfig)
        }

        guard !Task.isCancelled else { return }

        // Dual output: write each original image beside its PDF (same base + tags) BEFORE merge repoints
        // outputURLMap and before organization moves files — exactly as startProcessing does. Skipped
        // unless exportOriginals is set (restored above), so the non-dual-output path is unchanged.
        await exportOriginalImages(runConfig: runConfig)

        if runOutputSettings.mergeDocuments {
            performDocumentMerging(
                files: pending.fileURLs, outputDirectory: pending.outputDirectory,
                runConfig: runConfig)
        }

        // Organize into collection folders (after merge so merged PDFs get moved)
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: pending.outputDirectory,
                    outputURLMap: outputURLMap,
                    moveSiblingImages: runOutputSettings.exportOriginals,
                    exportedImageMap: exportedImageMap
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }

        cleanupTempFiles()

        guard !Task.isCancelled else { return }
        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        progress = 1.0
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        recordRunHistory(succeeded: succeeded)
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        // W23.m5 / W23.h5-fu — say so when a written output went out untagged, or with a
        // placeholder instead of the scan. Both are silent failures otherwise: the file is
        // there and looks processed, but tag search will not find it / the scan is missing.
        statusMessage += Self.outputWarningSuffix(untagged: untaggedOutputs, placeholders: placeholderOutputs)
        if pending.enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }
    /// Resume an interrupted non-batch run.
    func resumeRun(apiKey: String) async {
        // Ignore a torn/tampered manifest rather than misapply it (Tier-2 rule e). `resumeRun` replays
        // the manifest's OWN persisted input set + output dir (never the current UI selection), so a
        // stale manifest can never cross-contaminate a different job; `pendingRunMatches(...)` lets a
        // caller confirm the two are the same run before auto-resuming.
        guard let pending = Self.loadPendingRun(), Self.pendingRunIsSelfConsistent(pending) else { return }

        isProcessing = true
        pendingRunInfo = nil
        failedFiles = []
        clearOutputWarnings()
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        _takenOutputPaths = []
        exportedImageMap = [:]
        pdfToImageMap = [:]
        currentModel = pending.model
        currentGateway = pending.gatewayConfig
        currentLocalAgent = pending.localAgent
        let runConfig = makePendingRunResumeConfig(pending, apiKey: apiKey)
        activeRunConfig = runConfig
        let resumeGatewayUpstream: LLMProvider
        if let config = pending.runtimeConfig {
            // V2: replay the immutable start-time snapshot. Self-consistency above has already validated
            // its version, ranges, parallel-array alignment, and identity fingerprint.
            applyPendingRunRuntimeConfig(config)
            resumeGatewayUpstream = config.gatewayUpstreamProvider ?? .anthropic
        } else {
            // Legacy manifests did not record these settings, so preserve their historical live-setting
            // fallback. There is no honest way to reconstruct the values that were active before relaunch.
            applyResumeConfig(runConfig)
            resumeGatewayUpstream = Self.gatewayUpstreamProviderFromDefaults()
        }
        let resumeImageScale = runConfig.imageScale
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
        removedSourceURLs = []
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        progress = 0

        // Restore the pending run tracker for incremental saves
        activePendingRun = pending

        // History uses the same restored values as the resumed pipeline (legacy runs use the fallback above).
        activeRunHistory = RunHistorySnapshot(
            resuming: pending, taggingMode: taggingMode, rotationMode: rotationMode,
            imageScale: resumeImageScale,
            imageTokenProvider: resumeGatewayUpstream)

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
                alreadyTaken: Set(outputURLMap.values.map { $0.standardizedFileURL.path.lowercased() }))
            for (key, result) in pending.completedResults.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
                guard let index = Int(key), index < jobs.count, index < imageURLs.count,
                      let outputURL = resolvedOutputs[index] else { continue }
                let sourceURL = jobs[index].sourceURL
                restores.append((index, result, sourceURL, outputURL))
                if !fm.fileExists(atPath: outputURL.path) {
                    toGenerate.append((imageURLs[index], outputURL, sourceURL.lastPathComponent, result))
                }
            }
            // Regenerate only missing PDFs, off the main thread. Track failures so we don't
            // populate outputURLMap with phantom entries pointing at nonexistent files (M2 fix).
            var failedRegenURLs = Set<URL>()
            if !toGenerate.isEmpty {
                let model = pending.model
                let gatewayName = currentGateway?.displayName
                let pdfSettings = Self.pdfGenerationSettings(for: runConfig)
                let pdfMB = pdfSettings.imageMB
                let txtCols = pdfSettings.textColumns
                statusMessage = "Rebuilding \(toGenerate.count) missing PDF\(toGenerate.count == 1 ? "" : "s")…"
                // W23.h5-fu — carry each regenerated PDF's image-page verdict back too, so a rebuilt
                // output that could not embed its scan is reported instead of counting as a clean redo.
                let regen: (failed: Set<URL>, placeholders: Set<URL>) = await Task.detached(priority: .utility) {
                    let gen = PDFGenerator()
                    var failed = Set<URL>()
                    var placeholders = Set<URL>()
                    for g in toGenerate {
                        do {
                            let outcome = try gen.generate(imageURL: g.imageURL, result: g.result, model: model,
                                              outputURL: g.outputURL, originalFileName: g.fileName,
                                              gatewayDisplayName: gatewayName, pdfImageMB: pdfMB, textColumns: txtCols)
                            if outcome.isPlaceholder { placeholders.insert(g.outputURL) }
                        } catch {
                            failed.insert(g.outputURL)
                        }
                    }
                    return (failed, placeholders)
                }.value
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
                if r.result.text == nil { failedFiles.append(r.sourceURL.lastPathComponent) }
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
                // For pre-OCRed, run the full pipeline (it's text extraction + classification, cheap)
                await performPreOCRedProcessing(
                    files: pending.fileURLs,
                    provider: pending.provider,
                    model: pending.model,
                    thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: pending.outputDirectory,
                    enableTagging: pending.enableTagging,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    enableCollectionSegmentation: pending.enableCollectionSegmentation,
                    confirmCollectionIDs: pending.confirmCollectionIDs,
                    reviewDocumentSegmentation: pending.reviewDocumentSegmentation,
                    customPrompt: pending.customPrompt,
                    runConfig: runConfig
                )
                // Pre-OCRed path handles its own post-processing; skip to finalization
                activePendingRun = nil
                Self.deletePendingRun()
                pendingRunInfo = nil
                guard !Task.isCancelled else { return }
                writeLogFile(outputDirectory: pending.outputDirectory)
                isProcessing = false
                progress = 1.0
                let succeeded = jobs.filter { $0.status == .succeeded }.count
                recordRunHistory(succeeded: succeeded)
                statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
                // W23.m5 / W23.h5-fu — say so when a written output went out untagged, or with a
                // placeholder instead of the scan. Both are silent failures otherwise: the file is
                // there and looks processed, but tag search will not find it / the scan is missing.
                statusMessage += Self.outputWarningSuffix(untagged: untaggedOutputs, placeholders: placeholderOutputs)
                postCompletionNotification()
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

        guard !Task.isCancelled else { cleanupTempFiles(); return }

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

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Interactive retry
        await retryLoopForFailedFiles(
            imageURLs: imageURLs,
            outputDirectory: pending.outputDirectory,
            runConfig: runConfig
        )

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Tagging (mode-dependent), matching the main workflow — not always automatic.
        if pending.enableTagging && !passSourceTags {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Tagging…"

            switch runOutputSettings.taggingMode {
            case .automatic:
                await performAutomaticTaggingWithReview(
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON, files: pending.fileURLs,
                    runConfig: runConfig
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: runOutputSettings.taggingMode, provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory, enableSegmentJSON: pending.enableSegmentJSON,
                    runConfig: runConfig
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: runOutputSettings.taggingMode.autoFillsDate,
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    preOCRed: pending.preOCRedInput, files: pending.fileURLs,
                    runConfig: runConfig
                )
            case .none, .copySource:
                break
            }
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Collection segmentation (after tagging)
        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                confirmBeforeOrganizing: pending.confirmCollectionIDs,
                reviewDocumentSegmentation: pending.reviewDocumentSegmentation,
                runConfig: runConfig
            )

            applyBoxFolderLabelTags(enableTagging: pending.enableTagging, runConfig: runConfig)
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Dual output: write each original image beside its PDF BEFORE merge repoints outputURLMap and
        // before organization moves files — exactly as startProcessing does. No-op unless exportOriginals
        // is set (restored above), so the non-dual-output path is unchanged.
        await exportOriginalImages(runConfig: runConfig)

        if runOutputSettings.mergeDocuments {
            performDocumentMerging(
                files: pending.fileURLs, outputDirectory: pending.outputDirectory,
                runConfig: runConfig)
        }

        // Organize into collection folders (after merge so merged PDFs get moved)
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: pending.outputDirectory,
                    outputURLMap: outputURLMap,
                    moveSiblingImages: runOutputSettings.exportOriginals,
                    exportedImageMap: exportedImageMap
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }

        cleanupTempFiles()

        guard !Task.isCancelled else { return }

        activePendingRun = nil
        Self.deletePendingRun()
        pendingRunInfo = nil

        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        progress = 1.0
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        recordRunHistory(succeeded: succeeded)
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        // W23.m5 / W23.h5-fu — say so when a written output went out untagged, or with a
        // placeholder instead of the scan. Both are silent failures otherwise: the file is
        // there and looks processed, but tag search will not find it / the scan is missing.
        statusMessage += Self.outputWarningSuffix(untagged: untaggedOutputs, placeholders: placeholderOutputs)
        if pending.enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
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
        let remaining = indices.count
        let gateway = currentGateway
        let localAgent = currentLocalAgent
        let ocrRun = Self.ocrCallValues(for: runConfig)

        if segmentationContext.previousTextCharCount == 0 {
            // Parallel: OCR only the remaining indices
            var completed = 0
            let concurrency = Self.schedulingWorkerCount(for: runConfig)
            for i in indices { jobs[i].status = .processing }
            statusMessage = "OCR 0/\(remaining) remaining… (parallel)"

            await withTaskGroup(of: (Int, OCRResult).self) { group in
                var nextSlot = 0

                for _ in 0..<min(concurrency, remaining) {
                    let index = indices[nextSlot]
                    let url = fileURLs[index]
                    let prevImageURL = (segmentationContext.sendPreviousImage && index > 0) ? fileURLs[index - 1] : nil
                    nextSlot += 1
                    let scale = segmentationContext.imageScale
                    group.addTask {
                        let result = await Self.performOCRCall(
                            imageURL: url, provider: provider, model: model,
                            thinkingLevel: thinkingLevel, apiKey: apiKey,
                            previousText: nil, previousImageURL: prevImageURL,
                            customPrompt: segmentationContext.customPrompt,
                            imageScale: scale,
                            gatewayConfig: gateway, localAgent: localAgent,
                            rotationMode: ocrRun.rotationMode,
                            standardImageMB: ocrRun.standardImageMB
                        )
                        return (index, result)
                    }
                }

                for await (index, result) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    guard await handleOCRResult(
                        result, index: index, url: fileURLs[index], model: model,
                        outputDirectory: outputDirectory, runConfig: runConfig) else {
                        group.cancelAll()
                        return
                    }
                    completed += 1
                    progress = Double(alreadyCompleted + completed) / Double(totalFiles) * 0.7
                    statusMessage = "OCR \(alreadyCompleted + completed)/\(totalFiles) complete (parallel)" + Self.rateLimitSuffix

                    if nextSlot < remaining {
                        let idx = indices[nextSlot]
                        let url = fileURLs[idx]
                        let prevImageURL = (segmentationContext.sendPreviousImage && idx > 0) ? fileURLs[idx - 1] : nil
                        nextSlot += 1
                        let scale = segmentationContext.imageScale
                        group.addTask {
                            let result = await Self.performOCRCall(
                                imageURL: url, provider: provider, model: model,
                                thinkingLevel: thinkingLevel, apiKey: apiKey,
                                previousText: nil, previousImageURL: prevImageURL,
                                customPrompt: segmentationContext.customPrompt,
                                imageScale: scale,
                                gatewayConfig: gateway, localAgent: localAgent,
                                rotationMode: ocrRun.rotationMode,
                                standardImageMB: ocrRun.standardImageMB
                            )
                            return (idx, result)
                        }
                    }
                }
            }
        } else {
            // Sequential: OCR remaining indices, using previous results for context
            for (attempt, index) in indices.enumerated() {
                guard !Task.isCancelled else { return }
                let url = fileURLs[index]
                jobs[index].status = .processing

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
                    standardImageMB: ocrRun.standardImageMB
                )

                if Self.isTimeoutError(result) {
                    statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)… retrying after timeout"
                    result = await Self.performOCRCall(
                        imageURL: url, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: nil, previousImageURL: nil,
                        customPrompt: segmentationContext.customPrompt,
                        imageScale: segmentationContext.imageScale,
                        gatewayConfig: gateway, localAgent: localAgent,
                        rotationMode: ocrRun.rotationMode,
                        standardImageMB: ocrRun.standardImageMB
                    )
                }

                guard await handleOCRResult(
                    result, index: index, url: url, model: model,
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
        // Read off the client that was actually constructed, never typed in — that is the whole point (see
        // `clientTypeName`): it is what a check compares against the provider whose rule will be applied.
        let clientTypeName: String
        switch batch.provider {
        case .anthropic:
            let client = AnthropicBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
            cancelChunk = { await client.cancelBatch(batchId: $0) }
            clientTypeName = String(describing: type(of: client))
        case .mistral:
            let client = MistralBatchClient(apiKey: batch.apiKey, model: batch.model)
            cancelChunk = { await client.cancelBatch(batchId: $0) }
            clientTypeName = String(describing: type(of: client))
        case .gemini:
            let client = GeminiBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
            cancelChunk = { await client.cancelBatch(batchName: $0) }
            clientTypeName = String(describing: type(of: client))
        case .openai:
            cancelChunk = { _ in false }   // never called; OpenAI has no batch path in v1.
            clientTypeName = "none"
        }
        return BatchChunkCanceller(provider: batch.provider, cancelChunk: cancelChunk,
                                   clientTypeName: clientTypeName)
    }

    /// Which server-side jobs `cancel()` will try to cancel: the journal's acknowledged chunk IDs when
    /// there is a v1 journal, otherwise the IDs packed into the batch's own ID (legacy comma-joined
    /// manifests). Pure, so the derivation is pinnable — getting it wrong here cancels the wrong paid
    /// jobs, or none, while the operator is told the batch was stopped (W16.bat2-fu).
    static func cancellationChunkIds(pendingBatch: PendingBatch?, batchId: String) -> [String] {
        pendingBatch?.effectiveChunkIds ?? PendingBatch.parseChunkIDs(batchId)
    }

    /// What `cancel()` did about a paid batch's server-side job and its recovery journal.
    /// `journalDeleted` is the safety-critical field: that journal is the only way back to a still-live
    /// batch the operator has already paid for, so deleting it on an unconfirmed cancellation strands
    /// the money with no way to collect the pages.
    struct BatchCancellationOutcome: Equatable, Sendable {
        /// True only when EVERY chunk of the batch was confirmed cancelled by the provider.
        let confirmed: Bool
        /// True iff the recovery journal was deleted (i.e. `deleteJournal` was called).
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

    /// Cancel a paid batch server-side and decide the fate of its recovery journal.
    ///
    /// The one shipped safety guarantee of the cancel path, extracted so it can be proven without a
    /// network, a key or a cent (`BatchCancelContract`, W16.bat2): **the journal is deleted ONLY when
    /// every chunk's cancellation was confirmed.** Anything else — an unconfirmed chunk, a multi-chunk
    /// batch this app has no single ID to cancel, a batch with no chunk IDs at all — keeps the journal
    /// and says so.
    ///
    /// - Parameters:
    ///   - canceller: the provider it applies plus how to cancel one chunk. `cancel()` passes the live
    ///     batch client's canceller; the headless driver passes a stub, which is the point of the seam.
    ///   - deleteJournal: removes the recovery journal. Called at most once, and only when confirmed.
    static func performServerBatchCancellation(
        canceller: BatchChunkCanceller,
        chunkIds: [String],
        deleteJournal: @MainActor () -> Void
    ) async -> BatchCancellationOutcome {
        let cancelChunk = canceller.cancelChunk
        var attempted: [String] = []
        let confirmed: Bool
        switch canceller.provider {
        case .anthropic, .mistral:
            // Both clients cancel exactly one server-side job. A batch split into several chunks has no
            // single ID to cancel, so nothing can be confirmed and the journal must survive.
            if chunkIds.count == 1 {
                attempted = chunkIds
                confirmed = await cancelChunk(chunkIds[0])
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
                if !(await cancelChunk(chunkId)) { allConfirmed = false }
            }
            confirmed = allConfirmed
        case .openai:
            confirmed = false   // OpenAI has no batch path in v1 (`supportsBatch == false`).
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

    func cancel() {
        // Kept after the handle is dropped, for the cancellation task at the bottom of this function: the
        // run this Stop is ending goes on unwinding on its own task afterwards, and writes its own
        // `statusMessage` on the way out. That is what the kept-journal warning has to outlive (W16.bat6).
        let interruptedRun = processingTask
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
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
        cleanupTempFiles()

        // Cancel server-side batch if active.
        // Every decision here is made from data and named seams rather than inline closures, so the
        // WIRING can be driven headlessly (`BatchCancelWiringContract`, W16.bat2-fu) — which jobs get
        // cancelled, with which provider's client, which journal may be deleted, and whether the
        // operator is told. The RULE those feed is `performServerBatchCancellation` (W16.bat2).
        if let batch = activeBatch {
            activeBatch = nil
            let chunkIds = Self.cancellationChunkIds(pendingBatch: activePendingBatch, batchId: batch.batchId)
            activePendingBatch = nil
            // Built synchronously (constructing a client opens no connection) so the choices are made
            // from state that is still current, not from whatever it became by the time the Task ran.
            let canceller = makeBatchChunkCanceller(batch)
            let deleteJournal = makeBatchJournalDeleter(.paidBatchJournal)
            batchCancellationTask = Task {
                let outcome = await Self.performServerBatchCancellation(
                    canceller: canceller, chunkIds: chunkIds, deleteJournal: deleteJournal)
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

        // If a non-batch run was active, keep the pending run file for resume
        if activePendingRun != nil {
            activePendingRun = nil
            // Refresh the pending run info banner
            checkForPendingBatch()
        }

        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let pending = jobs.filter { $0.status == .processing || $0.status == .pending }.count
        statusMessage = "Cancelled. \(succeeded) succeeded, \(failedFiles.count) failed, \(pending) skipped."
        // Mark any still-processing jobs as failed
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = .failed
        }
    }
    func startProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        batchMode: Bool,
        enableTagging: Bool,
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool = false,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        preOCRedInput: Bool = false,
        skipAlreadyProcessed: Bool = false,
        segmentationContext: SegmentationContext,
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil
    ) async {
        guard !files.isEmpty else { return }
        // Never overwrite recovery state from a different interrupted run. The UI surfaces explicit
        // Resume/Dismiss controls, but keep the invariant here as well for shortcuts and programmatic
        // callers. A paid batch may still exist even when its manifest is malformed or has no received ID.
        if Self.loadPendingBatch() != nil || Self.loadPendingRun() != nil {
            checkForPendingBatch()
            statusMessage = "An interrupted run is still preserved. Resume it or explicitly dismiss its recovery record before starting another run."
            return
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
        if skipAlreadyProcessed && preGroupedBoundaries.isEmpty
            && !enableCollectionSegmentation && !mergeDocuments {
            let decision = IncrementalSkip.partition(inputs: files, outputDirectory: outputDirectory)
            incrementalSkipped = decision.skipped.count
            files = decision.toProcess
            guard !files.isEmpty else {
                jobs = []; failedFiles = []; segments = []; collectionSegments = []
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
                preGroupedPriorities = []
                preGroupedYears = []
                preGroupedMonths = []
                preGroupedSubjects = []
            } else {
                preGroupedTypes = files.indices.map {
                    $0 < preGroupedTypes.count ? preGroupedTypes[$0] : .document
                }
                if !preGroupedPriorities.isEmpty {
                    preGroupedPriorities = files.indices.map {
                        $0 < preGroupedPriorities.count ? preGroupedPriorities[$0] : nil
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

        isProcessing = true
        failedFiles = []
        clearOutputWarnings()
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        _takenOutputPaths = []
        exportedImageMap = [:]
        pdfToImageMap = [:]
        removedSourceURLs = []
        var runConfig = SessionProcessingConfig.fromProcessFilesRunStart()
        // The Process Files controller/arguments are the authoritative run input (headless drivers
        // intentionally configure them without mutating UserDefaults), so every explicitly-threaded
        // consumer observes this exact start-time snapshot.
        runConfig.provider = provider
        runConfig.model = model
        runConfig.thinkingLevel = thinkingLevel ?? .low
        runConfig.apiKey = apiKey
        runConfig.taggingMode = taggingMode
        runConfig.rotationMode = rotationMode
        runConfig.mergeDocuments = mergeDocuments
        runConfig.outputDirectory = outputDirectory
        runConfig.contextCharCount = segmentationContext.previousTextCharCount
        runConfig.sendPreviousImage = segmentationContext.sendPreviousImage
        runConfig.customOCRPrompt = segmentationContext.customPrompt ?? ""
        runConfig.imageScale = segmentationContext.imageScale
        runConfig.enableSegmentJSON = enableSegmentJSON
        runConfig.tagVocabulary = tagVocabulary
        runConfig.gateway = gatewayConfig
        runConfig.outputImageFile = exportOriginals
        runConfig.localAgent = localAgent
        activeRunConfig = runConfig
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
        currentModel = model
        currentGateway = gatewayConfig
        currentLocalAgent = localAgent
        jobs = files.map { OCRJob(sourceURL: $0) }
        progress = 0

        // Auto-route a dropped multi-page PDF to the re-OCR transform (render each page → OCR → one
        // interleaved image/OCR-text PDF): it is an assembled document, not a page stream to segment
        // and tag, so it never goes through the tagging pipeline. `preOCRedInput` stays the deliberate
        // opt-in for that pipeline and wins when set. Presence-based (not all-inputs-are-PDF) so a
        // multi-page PDF is NEVER silently truncated to its first page by the image path; a non-PDF
        // sibling in the same run fails render loudly (this path only WRITES output — it never moves
        // or deletes a source — so file-safety holds regardless).
        let autoReOCR = !preOCRedInput && files.contains(where: PDFToImageConverter.isMultiPagePDF)

        // Snapshot this run's parameters for the processing-history log. Captured here (not at the tail)
        // because several completion paths clear other run state first; `enableTagging`/`sendPreviousImage`
        // mirror the pre-run cost pane's inputs (`taggingMode.llmTags`, the context-gated flag) so the
        // recorded cost equals what the operator saw. `batchMode` reflects whether batch ACTUALLY runs.
        activeRunHistory = RunHistorySnapshot(
            startedAt: Date(),
            provider: provider,
            gatewayConfig: gatewayConfig,
            imageTokenProvider: gatewayConfig != nil ? Self.gatewayUpstreamProviderFromDefaults() : nil,
            model: model,
            batchMode: batchMode && provider.supportsBatch && gatewayConfig == nil && localAgent == nil,
            enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            reOCRMultiPagePDF: autoReOCR,
            sendPreviousImage: segmentationContext.sendPreviousImage,
            contextCharCount: segmentationContext.previousTextCharCount,
            imageScale: segmentationContext.imageScale,
            rotationMode: rotationMode,
            fileCount: files.count
        )

        if autoReOCR {
            // --- Multi-page PDF re-OCR path: render every page → OCR each page image → rebuild ONE
            //     output PDF alternating image/OCR-text. A pure transform (no tagging/segmentation). ---
            await performMultiPagePDFReOCR(
                files: files,
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
        } else if preOCRedInput {
            // --- Pre-OCRed PDF path: extract text, classify, skip PDF generation ---
            await performPreOCRedProcessing(
                files: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs,
                reviewDocumentSegmentation: reviewDocumentSegmentation,
                customPrompt: segmentationContext.customPrompt,
                runConfig: runConfig
            )
        } else {
            // --- Standard image OCR path ---
            statusMessage = "Starting OCR…"

            // Convert any PDF inputs to temporary JPEG images
            let imageURLs = convertPDFInputs(files)

            // Phase 1: OCR + Classification
            if batchMode && provider.supportsBatch && localAgent == nil {
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
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale,
                    runConfig: runConfig
                )
                // Transient interruption during batch polling: the batch is preserved (resumable) and
                // no file was falsely failed. Stop cleanly rather than tagging/finalizing partial results.
                // The SAME tail as the resume site (W16.bat4) — resetting `isProcessing` alone left the
                // Resume control the interruption message names unrendered until the operator pressed Start
                // and was refused, and leaked this run's temp JPEGs. Reached by all four of
                // `performBatchOCR`'s interrupted exits: journal-save failure, a submission that stopped
                // part-way, a journal/ID disagreement, and the poll's own timeout / error streak.
                if batchPollInterrupted {
                    finishInterruptedBatchPoll()
                    return
                }
            } else {
                // Create a complete, versioned snapshot before the first non-batch OCR request. The v2
                // fingerprint covers ordered inputs + every run/backend/runtime setting and is recomputed
                // with each incrementally-persisted result/output association.
                let runtimeConfig = makePendingRunRuntimeConfig(
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

            guard !Task.isCancelled else { cleanupTempFiles(); return }

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

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 1c: Prompt user to retry remaining failures with different provider/model
            await retryLoopForFailedFiles(
                imageURLs: imageURLs,
                outputDirectory: outputDirectory,
                runConfig: runConfig
            )

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Dedicated rotation review (opt-in) — a fast, standalone pass, separate from and BEFORE
            // the segmentation/tagging review, and run in EVERY tagging mode. It bakes the corrected
            // rotation into each output PDF; the exported JPG then picks up the same value.
            if reviewRotation && rotationMode != .off {
                await showRotationReview(files: files, runConfig: runConfig)
                guard !Task.isCancelled else { cleanupTempFiles(); return }
            }

            // Segmentation: pre-grouped from Live Capture, else the interactive LLM review.
            if preGroupedBoundaries.count == files.count && !files.isEmpty {
                // Groups were defined on the phone — apply them directly, skip LLM segmentation.
                applyPreGroupedClassifications(files: files)
                rebuildSegments(files: files)
            } else if runOutputSettings.taggingMode.usesManualSegmentationUI {
                // Manual modes: the combined segment+tag window owns rotation, box/folder, and
                // segmentation, so skip the separate review here (it rebuilds segments itself).
            } else if (enableTagging && !passSourceTags) || enableCollectionSegmentation {
                await showFullSegmentationReview(files: files, runConfig: runConfig)
                guard !Task.isCancelled else { cleanupTempFiles(); return }

                // Final confirmation of box/folder identifications
                await showBoxFolderConfirmation(files: files, runConfig: runConfig)
                guard !Task.isCancelled else { cleanupTempFiles(); return }

                // Rebuild segments from user-confirmed classifications (excluding removed files)
                rebuildSegments(files: files)
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 2: Tagging (mode-dependent)
            if enableTagging && !passSourceTags {
                switch runOutputSettings.taggingMode {
                case .automatic:
                    await performAutomaticTaggingWithReview(
                        provider: provider, model: model, thinkingLevel: thinkingLevel,
                        apiKey: apiKey, outputDirectory: outputDirectory,
                        enableSegmentJSON: enableSegmentJSON, files: files,
                        runConfig: runConfig
                    )
                case .autoDate:
                    await performManualTaggingPhase(
                        mode: runOutputSettings.taggingMode, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        outputDirectory: outputDirectory, enableSegmentJSON: enableSegmentJSON,
                        runConfig: runConfig
                    )
                case .human, .autoDateManualSeg:
                    await performManualSegmentAndTag(
                        autoDate: runOutputSettings.taggingMode.autoFillsDate,
                        provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        enableSegmentJSON: enableSegmentJSON, preOCRed: false, files: files,
                        runConfig: runConfig
                    )
                case .none, .copySource:
                    break
                }
                guard !Task.isCancelled else { cleanupTempFiles(); return }
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 3: Collection Segmentation + name review (after tagging review, last step before completion)
            if enableCollectionSegmentation {
                await performCollectionSegmentation(
                    files: files,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    confirmBeforeOrganizing: confirmCollectionIDs,
                    reviewDocumentSegmentation: false,
                    runConfig: runConfig
                )

                applyBoxFolderLabelTags(enableTagging: enableTagging, runConfig: runConfig)
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Live Capture: layer per-page phone priority on top now that box/folder Red/Purple is
            // final, and before merge folds appliedTags into merged PDFs.
            applyCapturePriorityTags(runConfig: runConfig)

            // Live Capture dual output: write each original image next to its PDF (same base + tags),
            // before merge repoints outputURLMap and before organization moves files.
            await exportOriginalImages(runConfig: runConfig)

            // Phase 4: Merge multi-page documents (before collection organization moves files)
            if runOutputSettings.mergeDocuments {
                performDocumentMerging(
                    files: files, outputDirectory: outputDirectory, runConfig: runConfig)
            }

            // Phase 5: Organize into collection folders (after merge so merged PDFs get moved)
            if enableCollectionSegmentation && !collectionSegments.isEmpty {
                let segmenter2 = CollectionSegmenter()
                statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
                do {
                    try segmenter2.organizeOutput(
                        collections: collectionSegments,
                        outputDirectory: outputDirectory,
                        outputURLMap: outputURLMap,
                        moveSiblingImages: runOutputSettings.exportOriginals,
                        exportedImageMap: exportedImageMap
                    )
                    statusMessage = "Collections organized into \(collectionSegments.count) folders."
                } catch {
                    statusMessage = "Error organizing collections: \(error.localizedDescription)"
                }
            }

            cleanupTempFiles()
        }

        guard !Task.isCancelled else { return }

        // Clear pending run on successful completion
        activePendingRun = nil
        Self.deletePendingRun()
        pendingRunInfo = nil

        writeLogFile(outputDirectory: outputDirectory)
        isProcessing = false
        progress = 1.0   // fill the bar on completion (later phases don't drive the 0.7→1.0 band)
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        recordRunHistory(succeeded: succeeded)
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        // W23.m5 / W23.h5-fu — say so when a written output went out untagged, or with a
        // placeholder instead of the scan. Both are silent failures otherwise: the file is
        // there and looks processed, but tag search will not find it / the scan is missing.
        statusMessage += Self.outputWarningSuffix(untagged: untaggedOutputs, placeholders: placeholderOutputs)
        // Make the multi-page-re-OCR routing skip UNMISSABLE. "N failed" alone reads as an OCR/model problem,
        // and the per-row reason requires inspecting a row — so an operator whose images were skipped for a
        // pure ROUTING reason had no way to know. (2026-07-29: an owner dropped two .jpg files alongside one
        // 3-page PDF; both images were silently discarded and reported as "No OCR text".) The batch log would
        // also have said so, but `writeLogFile` is opt-in and defaults to OFF, so the status line is the only
        // channel guaranteed to be seen.
        let skippedNotPDF = jobs.filter { $0.result?.errorCode == "not_a_pdf_in_reocr_run" }.count
        if skippedNotPDF > 0 {
            statusMessage += " ⚠️ \(skippedNotPDF) non-PDF file\(skippedNotPDF == 1 ? "" : "s") NOT processed:"
                          + " this run contained a multi-page PDF, which routes the whole run through the"
                          + " PDF-only re-OCR transform. Re-run the images on their own."
        }
        if incrementalSkipped > 0 {
            statusMessage += " \(incrementalSkipped) already-processed skipped."
        }
        if enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }
    /// Called by UI when user chooses to retry failed files with a different provider/model.
    func retryFailedFiles(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .retry(provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey))
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
            case .retry(let provider, let model, let thinkingLevel, let apiKey):
                let indicesToRetry = failedFileIndices
                statusMessage = "Retrying \(indicesToRetry.count) files with \(provider.rawValue) \(model.displayName)…"

                for (attempt, index) in indicesToRetry.enumerated() {
                    guard !Task.isCancelled else { return }
                    _ = await retryOne(index: index, imageURL: imageURLs[index], provider: provider,
                                       model: model, thinkingLevel: thinkingLevel, apiKey: apiKey,
                                       outputDirectory: outputDirectory, runConfig: runConfig)
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

    /// Re-OCR a single file, then regenerate its output PDF (+ re-prune `failedFiles`). Extracted from the
    /// modal retry loop so the end-of-run modal AND per-item retry share one path — no duplicate logic.
    /// `imageURL` is the OCR input (may be a temp JPEG for pre-OCRed PDF input); it defaults to the job's
    /// source. `rotation` (if non-nil) forces the output rotation instead of the detected one (rotate &
    /// re-run). Returns whether OCR text was produced. Reuses `performOCRCall` + `handleOCRResult` verbatim
    /// (`handleOCRResult` already updates `jobs[index].status` and prunes/appends `failedFiles`).
    @discardableResult
    func retryOne(index: Int, imageURL: URL? = nil, provider: LLMProvider, model: LLMModel,
                  thinkingLevel: ThinkingLevel?, apiKey: String, outputDirectory: URL,
                  rotation: Int? = nil, runConfig: SessionProcessingConfig? = nil) async -> Bool {
        guard jobs.indices.contains(index) else { return false }
        jobs[index].status = .processing
        let ocrURL = imageURL ?? jobs[index].sourceURL
        let effectiveRunConfig = runConfigForRetry(runConfig)
        let ocrRun = Self.ocrCallValues(for: effectiveRunConfig)
        var result = await Self.performOCRCall(
            imageURL: ocrURL, provider: provider, model: model, thinkingLevel: thinkingLevel,
            apiKey: apiKey, previousText: nil, previousImageURL: nil, gatewayConfig: currentGateway,
            localAgent: currentLocalAgent, rotationMode: ocrRun.rotationMode,
            standardImageMB: ocrRun.standardImageMB)
        if let rotation {
            result = OCRResult(text: result.text, classification: result.classification,
                               rotationDegrees: ((rotation % 360) + 360) % 360,
                               errorMessage: result.errorMessage, errorCode: result.errorCode)
        }
        let persisted = await handleOCRResult(
            result, index: index, url: ocrURL, model: model, outputDirectory: outputDirectory,
            runConfig: effectiveRunConfig)
        return persisted && result.text != nil
    }
    /// Request notification permission (call once at app launch).
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Post a local notification summarizing the completed run.
    private func postCompletionNotification() {
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let failed = failedFiles.count
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        content.body = "\(succeeded) succeeded, \(failed) failed."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    private func writeLogFile(outputDirectory: URL) {
        // Opt-in: only write the log when the user has enabled it (default off).
        guard UserDefaults.standard.bool(forKey: DefaultsKeys.writeLogFile) else { return }
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
            lines.append("Files that did not produce OCR text:")
            for f in failedFiles {
                let job = jobs.first { $0.sourceURL.lastPathComponent == f }
                let reason = job?.result?.errorMessage ?? "Unknown error"
                let code = job?.result?.errorCode.map { " [\($0)]" } ?? ""
                lines.append("  \u{2022} \(f)\(code): \(reason)")
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

        let content = lines.joined(separator: "\n")
        let timestamp = Int(Date().timeIntervalSince1970)
        let logURL = outputDirectory.appendingPathComponent("ArchiveProcessor_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
