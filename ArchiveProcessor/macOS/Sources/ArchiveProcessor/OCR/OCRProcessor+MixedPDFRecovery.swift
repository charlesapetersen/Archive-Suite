import Foundation
import CryptoKit

extension OCRProcessor {
    /// The PDF half of a mixed Process Files run. This record exists before the first paid PDF page.
    /// Its page results are immutable once saved; an unresolved in-flight request is never replayed.
    struct PendingMixedPDF: Codable {
        let originalFiles: [URL]
        let pdfIndices: [Int]
        let outputDirectory: URL
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let batchMode: Bool
        let enableTagging: Bool
        let enableSegmentJSON: Bool
        let enableCollectionSegmentation: Bool
        let confirmCollectionIDs: Bool
        let reviewDocumentSegmentation: Bool
        let previousTextCharCount: Int
        let sendPreviousImage: Bool
        let customPrompt: String?
        let imageScale: Double
        let gatewayConfig: GatewayConfig?
        let localAgent: LocalAgentConfig?
        let runtimeConfig: PendingRunRuntimeConfig
        let startedAt: Date
        /// Indexed by original job index. A changed source must not be paired with saved page OCR.
        let sourceDigests: [String: String]
        /// Keys are "originalJobIndex:zeroBasedPage"; failures are saved as results too.
        var pageResults: [String: OCRResult] = [:]
        /// Set before a paid call and cleared only when its returned result is durably saved.
        var inFlightPage: String? = nil
        /// Exact per-source output reservation, saved before the first PDF assembly write.
        var reservedOutputPaths: [String: String] = [:]
        /// Digest of each completed output; existence alone cannot prove the saved association.
        var outputDigests: [String: String] = [:]
        var completedOutcomes: [MixedPDFOutcome] = []
        var integrity: String? = nil
    }

    nonisolated static let pendingMixedPDFFileName = "pending_mixed_pdf.json"
    nonisolated static var pendingMixedPDFURL: URL {
        pendingStateDirectoryFromEnvironment.appendingPathComponent(pendingMixedPDFFileName)
    }

    nonisolated static func mixedPDFPageKey(index: Int, page: Int) -> String { "\(index):\(page)" }

    /// Stream the source digest so a large scanned PDF does not need a second full in-memory copy.
    nonisolated static func mixedPDFSourceDigest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                digest.update(data: chunk)
            }
        } catch { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func mixedPDFFingerprint(_ pending: PendingMixedPDF) -> String? {
        var unsigned = pending
        unsigned.integrity = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(unsigned) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func pendingMixedPDFIsSelfConsistent(_ pending: PendingMixedPDF) -> Bool {
        let count = pending.originalFiles.count
        let pdfSet = Set(pending.pdfIndices)
        let outputRoot = pending.outputDirectory.standardizedFileURL.path
        guard count > pending.pdfIndices.count, !pdfSet.isEmpty,
              pdfSet.count == pending.pdfIndices.count,
              pdfSet.allSatisfy({ (0..<count).contains($0) }),
              (0.01...1).contains(pending.imageScale), pending.imageScale.isFinite,
              (0...20_000).contains(pending.previousTextCharCount),
              pending.gatewayConfig == nil || pending.localAgent == nil,
              pendingRunRuntimeConfigIsValid(
                pending.runtimeConfig, fileCount: count,
                enableTagging: pending.enableTagging,
                hasGateway: pending.gatewayConfig != nil),
              Set(pending.originalFiles.map { $0.standardizedFileURL.path }).count == count,
              Set(pending.sourceDigests.keys) == Set(pending.pdfIndices.map(String.init)),
              pending.pdfIndices.allSatisfy({ pending.originalFiles[$0].pathExtension.lowercased() == "pdf" }),
              pending.sourceDigests.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            return false
        }
        func validPageKey(_ key: String) -> Bool {
            let parts = key.split(separator: ":")
            guard parts.count == 2, let index = Int(parts[0]), let page = Int(parts[1]) else { return false }
            return pdfSet.contains(index) && page >= 0 && key == mixedPDFPageKey(index: index, page: page)
        }
        guard pending.pageResults.keys.allSatisfy(validPageKey),
              pending.inFlightPage.map({ validPageKey($0) && pending.pageResults[$0] == nil }) ?? true,
              pending.reservedOutputPaths.keys.allSatisfy({ key in
                  guard let index = Int(key) else { return false }
                  return key == String(index) && pdfSet.contains(index)
              }),
              pending.reservedOutputPaths.values.allSatisfy({ path in
                  let url = URL(fileURLWithPath: path).standardizedFileURL
                  return NSString(string: path).isAbsolutePath
                      && url.pathExtension.lowercased() == "pdf"
                      && url.deletingLastPathComponent().path == outputRoot
              }),
              pending.outputDigests.keys.allSatisfy({ pending.reservedOutputPaths[$0] != nil }),
              pending.outputDigests.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
              else { return false }
        let reserved = pending.reservedOutputPaths.values.map {
            OutputFileSafety.pathKey(URL(fileURLWithPath: $0))
        }
        let inputs = Set(pending.originalFiles.map(OutputFileSafety.pathKey))
        guard Set(reserved).count == reserved.count,
              reserved.allSatisfy({ !inputs.contains($0) }),
              Set(pending.completedOutcomes.map(\.originalIndex)).count == pending.completedOutcomes.count,
              pending.completedOutcomes.allSatisfy({ outcome in
                  pdfSet.contains(outcome.originalIndex)
                      && outcome.sourceURL == pending.originalFiles[outcome.originalIndex]
                      && outcome.succeeded == (outcome.outputURL != nil)
                      && (!outcome.succeeded || pending.reservedOutputPaths[String(outcome.originalIndex)]
                            == outcome.outputURL?.path)
                      && (outcome.succeeded == (pending.outputDigests[String(outcome.originalIndex)] != nil))
              }),
              let stored = pending.integrity,
              let computed = mixedPDFFingerprint(pending) else { return false }
        return stored == computed
    }

    @discardableResult
    nonisolated static func savePendingMixedPDF(_ pending: PendingMixedPDF) -> PendingMixedPDF? {
        var signed = pending
        signed.integrity = mixedPDFFingerprint(signed)
        guard pendingMixedPDFIsSelfConsistent(signed),
              let data = try? JSONEncoder().encode(signed) else { return nil }
        do {
            try data.write(to: pendingMixedPDFURL, options: .atomic)
            return signed
        } catch {
            NSLog("[ArchiveProcessor] ERROR: could not persist mixed PDF journal: %@", error.localizedDescription)
            return nil
        }
    }

    nonisolated static func loadPendingMixedPDF() -> PendingMixedPDF? {
        guard let data = try? Data(contentsOf: pendingMixedPDFURL) else { return nil }
        return try? JSONDecoder().decode(PendingMixedPDF.self, from: data)
    }

    nonisolated static func deletePendingMixedPDF() {
        try? FileManager.default.removeItem(at: pendingMixedPDFURL)
    }

    /// The live copy is never trusted after a save failure: the on-disk in-flight marker is retained.
    var activePendingMixedPDF: PendingMixedPDF? {
        get { _activePendingMixedPDF }
        set { _activePendingMixedPDF = newValue }
    }

    @discardableResult
    func persistMixedPDFMutation(_ mutate: (inout PendingMixedPDF) -> Void) -> Bool {
        guard var pending = activePendingMixedPDF else { return false }
        mutate(&pending)
        guard let saved = Self.savePendingMixedPDF(pending) else {
            statusMessage = "The mixed PDF recovery record could not be saved. Processing stopped before another paid request."
            return false
        }
        activePendingMixedPDF = saved
        return true
    }

    func beginMixedPDFJournal(
        originalFiles: [URL], pdfIndices: [Int], outputDirectory: URL,
        provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
        batchMode: Bool, enableTagging: Bool, enableSegmentJSON: Bool,
        enableCollectionSegmentation: Bool, confirmCollectionIDs: Bool,
        reviewDocumentSegmentation: Bool, segmentationContext: SegmentationContext,
        gatewayConfig: GatewayConfig?, localAgent: LocalAgentConfig?,
        runConfig: SessionProcessingConfig
    ) -> Bool {
        var digests: [String: String] = [:]
        for index in pdfIndices {
            guard let digest = Self.mixedPDFSourceDigest(originalFiles[index]) else {
                statusMessage = "Could not fingerprint \(originalFiles[index].lastPathComponent). No PDF OCR requests were sent."
                return false
            }
            digests[String(index)] = digest
        }
        let pending = PendingMixedPDF(
            originalFiles: originalFiles, pdfIndices: pdfIndices,
            outputDirectory: outputDirectory, provider: provider, model: model,
            thinkingLevel: thinkingLevel, batchMode: batchMode,
            enableTagging: enableTagging, enableSegmentJSON: enableSegmentJSON,
            enableCollectionSegmentation: enableCollectionSegmentation,
            confirmCollectionIDs: confirmCollectionIDs,
            reviewDocumentSegmentation: reviewDocumentSegmentation,
            previousTextCharCount: segmentationContext.previousTextCharCount,
            sendPreviousImage: segmentationContext.sendPreviousImage,
            customPrompt: segmentationContext.customPrompt,
            imageScale: segmentationContext.imageScale,
            gatewayConfig: gatewayConfig, localAgent: localAgent,
            runtimeConfig: makePendingRunRuntimeConfig(
                imageScale: segmentationContext.imageScale,
                gatewayConfig: gatewayConfig, runConfig: runConfig),
            startedAt: Date(), sourceDigests: digests)
        guard let signed = Self.savePendingMixedPDF(pending) else {
            statusMessage = "Could not create the mixed PDF recovery record. No paid requests were sent."
            return false
        }
        activePendingMixedPDF = signed
        checkForPendingBatch()
        return true
    }

    func applyMixedPDFRuntimeConfig(
        _ runtime: PendingRunRuntimeConfig, to config: inout SessionProcessingConfig, apiKey: String
    ) {
        config.taggingMode = runtime.taggingMode
        config.rotationMode = runtime.rotationMode
        config.mergeDocuments = runtime.mergeDocuments
        config.tagVocabulary = runtime.tagVocabulary
        config.imageScale = runtime.imageScale
        config.standardImageMB = runtime.standardImageMB
        config.ocrWorkerCount = runtime.ocrWorkerCount
        config.outputImageFile = runtime.exportOriginals
        config.pdfImageMB = runtime.pdfImageMB
        config.exportedImageMB = runtime.exportedImageMB
        config.textColumns = runtime.textColumns
        config.visionSettings = runtime.visionSettings
        if let provider = runtime.visionTextProvider, let model = runtime.visionTextModel {
            config.visionTextLLM = LLMTextConfiguration(
                provider: provider, model: model,
                thinkingLevel: runtime.visionTextThinkingLevel,
                apiKey: KeychainHelper.load(account: provider.rawValue) ?? apiKey)
        }
    }

    func resumeMixedPDF(apiKey: String, keyProvider: LLMProvider) async {
        guard let pending = Self.loadPendingMixedPDF(),
              Self.pendingMixedPDFIsSelfConsistent(pending) else {
            checkForPendingBatch()
            statusMessage = "The mixed PDF recovery record could not be verified. It was kept for review."
            return
        }
        if let reason = mixedPDFResumeBlockReason(pending) {
            statusMessage = reason
            checkForPendingBatch()
            return
        }
        let resolvedKey: String
        if let gateway = pending.gatewayConfig {
            guard !gateway.apiKey.isEmpty else {
                statusMessage = "Restore the saved gateway key before resuming this run."
                return
            }
            resolvedKey = ""
        } else if pending.provider == .appleVision || pending.localAgent != nil {
            resolvedKey = ""
        } else if let savedKey = KeychainHelper.load(account: pending.provider.rawValue) {
            resolvedKey = savedKey
        } else if keyProvider == pending.provider {
            guard !apiKey.isEmpty else {
                statusMessage = "Enter the \(pending.provider.rawValue) API key before resuming this run."
                return
            }
            resolvedKey = apiKey
        } else {
            statusMessage = "Select \(pending.provider.rawValue) and enter its API key before resuming this run."
            return
        }
        if let textProvider = pending.runtimeConfig.visionTextProvider,
           KeychainHelper.load(account: textProvider.rawValue) == nil {
            statusMessage = "Restore the \(textProvider.rawValue) judgement key before resuming this run."
            return
        }
        applyPendingRunRuntimeConfig(pending.runtimeConfig)
        let context = SegmentationContext(
            previousTextCharCount: pending.previousTextCharCount,
            sendPreviousImage: pending.sendPreviousImage,
            customPrompt: pending.customPrompt,
            imageScale: pending.imageScale)
        await startProcessing(
            files: pending.originalFiles, provider: pending.provider, model: pending.model,
            thinkingLevel: pending.thinkingLevel, apiKey: resolvedKey,
            outputDirectory: pending.outputDirectory, batchMode: pending.batchMode,
            enableTagging: pending.enableTagging,
            enableSegmentJSON: pending.enableSegmentJSON,
            enableCollectionSegmentation: pending.enableCollectionSegmentation,
            confirmCollectionIDs: pending.confirmCollectionIDs,
            reviewDocumentSegmentation: pending.reviewDocumentSegmentation,
            segmentationContext: context, gatewayConfig: pending.gatewayConfig,
            localAgent: pending.localAgent, resumingMixedPDF: pending)
    }

    /// A page with an unresolved request may already have been billed. Keep the journal and ask the
    /// operator to review it rather than making another automatic call.
    func mixedPDFResumeBlockReason(_ pending: PendingMixedPDF) -> String? {
        guard let key = pending.inFlightPage else { return nil }
        let parts = key.split(separator: ":")
        guard parts.count == 2, let index = Int(parts[0]), let page = Int(parts[1]),
              pending.originalFiles.indices.contains(index) else {
            return "A PDF request may have been billed without a saved result. Automatic resume is held."
        }
        return "Page \(page + 1) of \(pending.originalFiles[index].lastPathComponent) may have been billed without a saved result. Automatic resume is held; review this PDF before choosing a new run."
    }

    var pendingMixedPDFFileURLs: [URL]? {
        guard let pending = Self.loadPendingMixedPDF(),
              Self.pendingMixedPDFIsSelfConsistent(pending) else { return nil }
        return pending.originalFiles
    }

    var canResumePendingMixedPDF: Bool {
        guard !mixedPDFCancellationUnwinding else { return false }
        guard let pending = Self.loadPendingMixedPDF(),
              Self.pendingMixedPDFIsSelfConsistent(pending) else { return false }
        return pending.inFlightPage == nil
    }

    nonisolated static func mixedPDFOutputsMatchJournal(_ pending: PendingMixedPDF) -> Bool {
        pending.completedOutcomes.allSatisfy { outcome in
            guard let output = outcome.outputURL else { return true }
            return mixedPDFSourceDigest(output) == pending.outputDigests[String(outcome.originalIndex)]
        }
    }

    func dismissPendingMixedPDF() {
        guard !isProcessing && !mixedPDFCancellationUnwinding else { return }
        Self.deletePendingMixedPDF()
        activePendingMixedPDF = nil
        pendingMixedPDFInfo = nil
    }
}
