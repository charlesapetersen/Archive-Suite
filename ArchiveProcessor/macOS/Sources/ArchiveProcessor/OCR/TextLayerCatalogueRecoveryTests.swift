#if DEBUG
import ArchiveCore
import Foundation
import PDFKit

extension TextLayerTestDriver {
    static func catalogueRecord(at url: URL?) -> CatalogueRecord? {
        guard let url, let pdf = PDFDocument(url: url),
              let identity = pdf.documentRef.flatMap(CataloguePDFIdentity.identity(in:)),
              let data = try? Data(contentsOf: url.appendingPathExtension("archivesuite.json")),
              let record = try? CatalogueRecord(json: data), record.fileID == identity.fileID,
              record.contentRevision == identity.contentRevision, pdf.pageCount == record.pages.count else { return nil }
        return record
    }

    static func catalogueRecoveryChecks(dir: URL, image: URL, multipagePDF: URL) async {
        guard let scratchState = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_STATE"],
              OCRProcessor.pendingCatalogueURL.deletingLastPathComponent().path == scratchState else {
            check("10 catalogue recovery uses an isolated journal", false)
            return
        }
        do {
            try await copiedSourceFacts(dir: dir, image: image)
            try await cachedCatalogueResume(dir: dir, image: image)
            try await mixedCatalogueResume(dir: dir, image: image, pdf: multipagePDF)
            try await frozenCatalogueResume(dir: dir, images: [image, multipagePDF], fixture: multipagePDF)
            try damagedCatalogueDismiss(dir: dir, image: image)
            try await batchCatalogueFiling(dir: dir, image: image)
        } catch {
            check("10 catalogue recovery fixtures", false, "\(error)")
        }
    }

    private static func copiedSourceFacts(dir: URL, image: URL) async throws {
        let source = dir.appendingPathComponent("copy-source.jpg")
        let output = dir.appendingPathComponent("copied source tags", isDirectory: true)
        try FileManager.default.copyItem(at: image, to: source)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        _ = try MacOSTagger.applyTags(["1978", "Q2", "Scratch Subject", "Read"], to: source, stampUnread: false)
        let processor = OCRProcessor()
        processor.taggingMode = .copySource
        processor.passSourceTags = true
        processor.rotationMode = .off
        await processor.startProcessing(files: [source], provider: .appleVision, model: LLMModel.appleVisionModels[0],
                                        thinkingLevel: nil, apiKey: "", outputDirectory: output,
                                        batchMode: false, enableTagging: true, enableSegmentJSON: false,
                                        segmentationContext: .init())
        let record = catalogueRecord(at: processor.outputURLMap[source])
        if case .value(let date)? = record?.documents.first?.fields?.documentDate?.current,
           case .value(let subjects)? = record?.documents.first?.fields?.subjects?.current,
           case .value(let quality)? = record?.fileFields.quality?.current,
           case .value(let read)? = record?.fileFields.readState?.current {
            check("10 Copy Source Tags imports established fields into the companion with export off",
                  date.date == ArchiveDate(year: 1978) && subjects == ["Scratch Subject"]
                    && quality == 2 && read == "read", processor.statusMessage)
        } else {
            check("10 Copy Source Tags imports established fields into the companion with export off", false,
                  processor.statusMessage)
        }
    }

    private static func cachedCatalogueResume(dir: URL, image: URL) async throws {
        let output = dir.appendingPathComponent("cached resume", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let builder = OCRProcessor()
        builder.taggingMode = .none
        builder.rotationMode = .off
        guard builder.beginCatalogueRun(outputRoot: output, sources: [image]), let catalogue = builder.catalogueRun else {
            throw CocoaError(.fileWriteUnknown)
        }
        let cachedText = "The resumed PDF keeps this exact cached OCR reading."
        let cached = OCRResult(text: cachedText, classification: .documentStart, errorMessage: nil, errorCode: nil)
        let missing = catalogue.workingRoot.appendingPathComponent("memo.pdf")
        var config = SessionProcessingConfig.fromProcessFilesRunStart()
        config.visionTextLLM = nil
        var run = OCRProcessor.PendingRun(
            provider: .appleVision, model: LLMModel.appleVisionModels[0], thinkingLevel: nil,
            fileURLs: [image], outputDirectory: output, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false, reviewDocumentSegmentation: false,
            preOCRedInput: false, previousTextCharCount: 0, sendPreviousImage: false, customPrompt: nil,
            startedAt: Date(), gatewayConfig: nil, completedResults: ["0": cached], runFingerprint: nil,
            exportOriginals: false, localAgent: nil,
            runtimeConfig: builder.makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil, runConfig: config))
        run.completedOutputPaths = ["0": missing.path]
        run.runFingerprint = OCRProcessor.pendingRunFingerprintV2(run)
        guard OCRProcessor.pendingRunIsSelfConsistent(run), OCRProcessor._testWritePendingRun(run, to: OCRProcessor.pendingRunURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        builder.catalogueRunLease = nil

        let resumed = OCRProcessor()
        await resumed.resumeRun(apiKey: "")
        let filed = resumed.outputURLMap[image]
        check("10 standard resume rebuilds missing working PDF from the cached OCR and files a pair",
              catalogueRecord(at: filed) != nil
                && filed.flatMap { PDFDocument(url: $0)?.string?.contains(cachedText) } == true
                && !OCRProcessor.workingOutputOccupied(OCRProcessor.pendingRunURL) && OCRProcessor.savedCatalogueRun() == nil,
              resumed.statusMessage)
    }

    private static func mixedCatalogueResume(dir: URL, image: URL, pdf: URL) async throws {
        let output = dir.appendingPathComponent("mixed resume", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let files = [image, pdf]
        let originalPDF = try Data(contentsOf: pdf)
        let builder = OCRProcessor()
        builder.taggingMode = .none
        builder.rotationMode = .off
        let model = LLMModel.appleVisionModels[0]
        var config = SessionProcessingConfig.fromProcessFilesRunStart()
        config.visionTextLLM = nil
        let context = SegmentationContext()
        guard builder.beginCatalogueRun(outputRoot: output, sources: files), let catalogue = builder.catalogueRun,
              builder.beginMixedPDFJournal(originalFiles: files, pdfIndices: [1], outputDirectory: output,
                                           provider: .appleVision, model: model, thinkingLevel: nil, batchMode: false,
                                           enableTagging: false, enableSegmentJSON: false, enableCollectionSegmentation: false,
                                           confirmCollectionIDs: false, reviewDocumentSegmentation: false, segmentationContext: context,
                                           gatewayConfig: nil, localAgent: nil, runConfig: config) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let partial = catalogue.workingRoot.appendingPathComponent("jpeg.pdf")
        let corrupt = Data("incomplete privately staged derivative".utf8)
        try corrupt.write(to: partial, options: .withoutOverwriting)
        guard builder.persistMixedPDFMutation({ pending in
            pending.reservedOutputPaths["1"] = partial.path
            for page in 0..<2 {
                pending.pageResults[OCRProcessor.mixedPDFPageKey(index: 1, page: page)] =
                    OCRResult(text: "Saved PDF reading number \(page + 1).", classification: nil,
                              errorMessage: nil, errorCode: nil)
            }
        }) else { throw CocoaError(.fileWriteUnknown) }
        builder.catalogueRunLease = nil

        let resumed = OCRProcessor()
        resumed.checkForPendingBatch()
        check("10 mixed PDF interruption exposes Resume before the image journal exists",
              resumed.pendingMixedPDFInfo != nil && resumed.canResumePendingMixedPDF,
              resumed.statusMessage)
        await resumed.resumeMixedPDF(apiKey: "", keyProvider: .appleVision)
        let rebuilt = resumed.outputURLMap[pdf]
        let pdfText = rebuilt.flatMap { PDFDocument(url: $0)?.string }
        check("10 mixed resume files both source types and reuses the saved PDF page readings",
              catalogueRecord(at: resumed.outputURLMap[image]) != nil
                && catalogueRecord(at: rebuilt)?.pages.count == 4
                && pdfText?.contains("Saved PDF reading number 1.") == true
                && pdfText?.contains("Saved PDF reading number 2.") == true
                && originalPDF == (try? Data(contentsOf: pdf))
                && OCRProcessor.loadPendingMixedPDF() == nil && !OCRProcessor.workingOutputOccupied(OCRProcessor.pendingRunURL)
                && OCRProcessor.savedCatalogueRun() == nil, resumed.statusMessage)
    }

    private static func frozenCatalogueResume(dir: URL, images: [URL], fixture: URL) async throws {
        let fm = FileManager.default
        let output = dir.appendingPathComponent("frozen resume", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let builder = OCRProcessor()
        guard builder.beginCatalogueRun(outputRoot: output, sources: images), var plan = builder.catalogueRun else {
            throw CocoaError(.fileWriteUnknown)
        }

        let workingRoot = plan.workingRoot
        let rootInstance = UUID()
        let sources = images
        let frozen = try await PDFGenerator.runWorker(priority: .utility) {
            try sources.enumerated().map { index, source in
                let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
                let prepared = workingRoot.appendingPathComponent(identity.fileID.uuidString + ".pdf")
                let bytes = try SearchableArchival.catalogueCopy(of: fixture, identity: identity)
                try bytes.write(to: prepared, options: .withoutOverwriting)
                try ProcessorCatalogueRun.flushFileAndParent(prepared)
                let document = ProcessorCatalogueRecord.Document(id: UUID(), ownerFileID: identity.fileID,
                                                                 fields: .init(), enclosedWith: nil)
                let record = ProcessorCatalogueRecord(identity: identity, sourcePages: [.init(roles: ["image", "text"])],
                                                      document: document, fileFields: .init())
                let target = output.appendingPathComponent("\(index + 1).pdf")
                let filing = try ProcessorCatalogueFiling(operationID: identity.fileID, root: output,
                                                          rootInstanceID: rootInstance, destination: target)
                return ProcessorCatalogueRun.File(workingPDF: prepared, prepared: prepared, sources: [source],
                                                  destination: target, record: try record.encoded(), filing: filing, exports: [])
            }
        }
        let model = LLMModel.geminiModels[0]
        let batchID = "batches/known-partial"
        let savedResult = OCRResult(text: "Previously collected scratch OCR", classification: .documentStart,
                                    errorMessage: nil, errorCode: nil)
        let batch = OCRProcessor.PendingBatch(
            batchId: batchID, provider: .gemini, model: model, thinkingLevel: nil, fileURLs: images,
            outputDirectory: output, enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            enableSegmentJSON: false, taggingMode: TaggingMode.none,
            runFingerprint: OCRProcessor.runFingerprint(files: images, outputDirectory: output, taggingMode: TaggingMode.none,
                                                        enableTagging: false, batchMode: true, preserveInputOrder: true),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: [batchID], consumedChunkIds: [batchID], submissionComplete: false,
            completedResults: ["0": savedResult, "1": savedResult],
            completedOutputPaths: ["0": frozen[0].prepared.path, "1": frozen[1].prepared.path])
        guard let saved = OCRProcessor.savePendingBatch(batch), OCRProcessor.pendingBatchIsSelfConsistent(saved) else {
            check("10 the partial batch fixture is valid for recovery", false)
            return
        }
        let journalBytes = try Data(contentsOf: OCRProcessor.pendingBatchURL)
        let partialArchive = OCRProcessor.pendingBatchURL.deletingLastPathComponent()
            .appendingPathComponent(plan.workingRoot.lastPathComponent + "-partial-batch.json")
        plan.inputJournalDigests = try builder.catalogueInputJournalDigests(for: plan)
        plan.files = frozen
        try plan.save(to: OCRProcessor.pendingCatalogueURL)
        let reopened = OCRProcessor()
        reopened.dismissPendingRun()
        check("10 a stale Dismiss cannot remove a frozen run while its lease is held",
              OCRProcessor.savedCatalogueRun()?.files?.count == 2)
        builder.catalogueRunLease = nil

        let obstruction = frozen[1].destination.appendingPathExtension("archivesuite.json")
        let foreign = Data("unrelated existing companion".utf8)
        try foreign.write(to: obstruction, options: .withoutOverwriting)
        await reopened.resumeRun(apiKey: "")
        let first = frozen[0].destination
        let before = try? Data(contentsOf: first)
        check("10 an obstructed companion keeps the frozen plan and all working inputs",
              catalogueRecord(at: first) != nil && (try? Data(contentsOf: obstruction)) == foreign
                && OCRProcessor.savedCatalogueRun()?.files?.count == 2
                && (try? Data(contentsOf: OCRProcessor.pendingBatchURL)) == journalBytes
                && frozen.allSatisfy { fm.fileExists(atPath: $0.prepared.path) }, reopened.statusMessage)
        try fm.moveItem(at: obstruction, to: dir.appendingPathComponent("preserved unrelated companion.json"))
        await reopened.resumeRun(apiKey: "")
        await reopened.resumeRun(apiKey: "")
        check("10 local Resume finishes the original plan without renumbering existing pairs",
              frozen.allSatisfy { file in
                  catalogueRecord(at: file.destination) != nil
                      && (try? Data(contentsOf: file.destination.appendingPathExtension("archivesuite.json"))) == file.record
              } && before == (try? Data(contentsOf: first)) && OCRProcessor.savedCatalogueRun() == nil,
              reopened.statusMessage)
        check("10 known results file and the unresolved batch record is archived byte for byte",
              (try? Data(contentsOf: partialArchive)) == journalBytes
                && !OCRProcessor.workingOutputOccupied(OCRProcessor.pendingBatchURL),
              reopened.statusMessage)
    }

    private static func damagedCatalogueDismiss(dir: URL, image: URL) throws {
        let fm = FileManager.default
        let output = dir.appendingPathComponent("damaged recovery", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let builder = OCRProcessor()
        guard builder.beginCatalogueRun(outputRoot: output, sources: [image]), let run = builder.catalogueRun else {
            throw CocoaError(.fileWriteUnknown)
        }
        builder.catalogueRunLease = nil
        let invalidJournal = Data("malformed ordinary OCR journal".utf8)
        try invalidJournal.write(to: OCRProcessor.pendingRunURL, options: .withoutOverwriting)
        let planBefore = try Data(contentsOf: OCRProcessor.pendingCatalogueURL)
        let resumed = OCRProcessor()
        resumed.checkForPendingBatch()
        check("10 malformed scratch journal is visible with a Dismiss action",
              resumed.pendingRunInfo?.contains("Dismiss") == true && resumed.pendingRunBackend == nil)
        resumed.dismissPendingRun()
        let state = OCRProcessor.pendingCatalogueURL.deletingLastPathComponent()
        let archived = try fm.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("catalogue-recovery-") }
        check("10 Dismiss preserves a damaged journal and its companion plan together",
              !OCRProcessor.workingOutputOccupied(OCRProcessor.pendingRunURL)
                && OCRProcessor.savedCatalogueRun() == nil && run.hasWorkingDirectory
                && archived.contains { root in
                    (try? Data(contentsOf: root.appendingPathComponent(OCRProcessor.pendingRunURL.lastPathComponent))) == invalidJournal
                        && (try? Data(contentsOf: root.appendingPathComponent(OCRProcessor.pendingCatalogueURL.lastPathComponent))) == planBefore
                }, resumed.statusMessage)
    }

    private actor BatchRequests {
        var methods: [String] = []
        func record(_ method: String) { methods.append(method) }
    }

    private static func batchCatalogueFiling(dir: URL, image: URL) async throws {
        let output = dir.appendingPathComponent("batch filing", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let requests = BatchRequests()
        NetworkSession.testTransport = { request in
            guard let url = request.url, let method = request.httpMethod else { throw URLError(.badURL) }
            await requests.record(method)
            let body: String
            if method == "POST", url.path.hasSuffix(":batchGenerateContent") {
                body = #"{"name":"batches/catalogue-test"}"#
            } else if method == "GET", url.path.hasSuffix("/batches/catalogue-test") {
                body = #"{"metadata":{"state":"JOB_STATE_SUCCEEDED"},"response":{"inlinedResponses":{"inlinedResponses":[{"metadata":{"key":"file-0"},"response":{"candidates":[{"content":{"parts":[{"text":"[document_start]\nThe saved batch reading."}]}}]}}]}}}"#
            } else {
                throw URLError(.unsupportedURL)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("10 batch fixture uses the offline transport", false)
            return
        }
        let processor = OCRProcessor()
        processor.rotationMode = .off
        processor.taggingMode = .none
        let followReview = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if processor.awaitingRetryDecision { processor.continueWithoutRetry() }
            }
        }
        defer { followReview.cancel() }
        await processor.startProcessing(files: [image], provider: .gemini, model: LLMModel.geminiModels[0],
                                        thinkingLevel: nil, apiKey: "offline-catalogue-fixture", outputDirectory: output,
                                        batchMode: true, enableTagging: false, enableSegmentJSON: false,
                                        segmentationContext: .init())
        let calls = await requests.methods
        let filed = processor.outputURLMap[image]
        check("10 fresh batch completion files its PDF companion before retiring its journal",
              calls == ["POST", "GET"] && catalogueRecord(at: filed) != nil
                && filed.flatMap { PDFDocument(url: $0)?.string?.contains("The saved batch reading.") } == true
                && !OCRProcessor.workingOutputOccupied(OCRProcessor.pendingBatchURL) && OCRProcessor.savedCatalogueRun() == nil,
              "\(calls) \(processor.statusMessage)")
    }
}
#endif
