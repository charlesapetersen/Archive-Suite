#if DEBUG
import AppKit
import ArchiveCore
import Foundation
import PDFKit

/// Drives Live Capture from page receipt through Skip and Finish on synthetic pages.
@MainActor
enum LiveCaptureTaggingFailureTestDriver {
    nonisolated static let envKey = "LIVECAPTURE_TAGGING_FAILURE_TEST"
    private static var didRun = false

    private actor Gateway {
        private(set) var statuses: [Int] = []
        private(set) var macModels: [String] = []
        private(set) var pageRequests = 0
        private(set) var fieldRequests = 0

        func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            guard let url = request.url,
                  let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
            if let model = json["model"] as? String,
               url.host == "127.0.0.1", url.port == 8080,
               model == ItemFieldExtractor.macImageModel || model == ItemFieldExtractor.macTextModel {
                macModels.append(model)
                let text = model == ItemFieldExtractor.macImageModel
                    ? #"{"kind":"report","byline":["Mary Jones"]}"#
                    : #"{"kind":"newsletter","publication_date":"1967-03"}"#
                let body = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": text], "finish_reason": "stop"]],
                ])
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.host == "gateway.test", json["model"] as? String == ItemFieldExtractor.gatewayModel {
                fieldRequests += 1
                let body = Data(#"{"choices":[{"message":{"content":"{\"kind\":\"report\"}"}}]}"#.utf8)
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["x-litellm-response-cost": "0.001"])!)
            }
            if url.host == "gateway.test", messages.first?["content"] is [[String: Any]] {
                pageRequests += 1
                let id = pageRequests == 1 ? "CONTROL-MEMO" : "REFUSED-MEMO"
                let body = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": "[document_start]\n\(id)\nMemorandum dated March 1918."],
                                 "finish_reason": "stop"]]
                ])
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["x-litellm-response-cost": "0.003"])!)
            }
            guard let prompt = messages.first?["content"] as? String,
                  prompt.contains("You are a metadata tagging assistant"),
                  prompt.contains("CONTROL-MEMO") != prompt.contains("REFUSED-MEMO") else {
                statuses.append(0)
                throw URLError(.badServerResponse)
            }
            let status = prompt.contains("REFUSED-MEMO") ? 500 : 200
            statuses.append(status)
            let error = Data(#"{"error":{"message":"synthetic tagging refusal"}}"#.utf8)
            let tags = #"{"year":"1918","subject_tags":["War Department","Military Intelligence"],"format":"memo"}"#
            let bodyData = status == 500 ? error : try JSONSerialization.data(
                withJSONObject: ["choices": [["message": ["content": tags]]]])
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                    headerFields: status == 200 ? ["x-litellm-response-cost": "0.002"] : nil) else {
                throw URLError(.badServerResponse)
            }
            return (bodyData, response)
        }
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard !didRun, env[envKey] == "1" else { return }
        didRun = true
        Task {
            do {
                let report = try await run(env: env)
                print(report)
                exit(0)
            } catch {
                print("S-045 probe failed: \(error)")
                exit(1)
            }
        }
    }

    private static func run(env: [String: String]) async throws -> String {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.resolvingSymlinksInPath()
        guard let backupPath = env["ARCHIVEPROC_TEST_BACKUP_ROOT"], let outputPath = env["LIVECAPTURE_TESTOUT"],
              let scratch = env["LIVECAPTURE_TAGGING_FAILURE_SCRATCH"] else {
            throw ProbeError("missing scratch paths")
        }
        let root = URL(fileURLWithPath: scratch).resolvingSymlinksInPath()
        let backup = URL(fileURLWithPath: backupPath).resolvingSymlinksInPath()
        let out = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath()
        guard root.path.hasPrefix(temp.path + "/"), backup.path == root.path + "/backup",
              out.path == root.path + "/out" else { throw ProbeError("paths must be under one temporary root") }

        let gateway = Gateway()
        GatewayConfig.testKeyOverride = "scratch-capture"
        NetworkSession.testTransport = { try await gateway.respond(to: $0) }
        defer {
            NetworkSession.testTransport = nil
            GatewayConfig.testKeyOverride = nil
            LiveCaptureProcessor._recoveryTestOCRStub = nil
        }
        guard NetworkSession.testTransportIsActive else { throw ProbeError("no injected transport") }

        // This collection is synthetic. Keep the fixture independent of the Mac's training preference.
        var settings = CollectionSettingsDocument(name: "Scratch Capture")
        settings.collection.set(.noTraining, .bool(false), source: .setByUser(Date()))
        try CollectionSettingsFile.write(settings, in: out)

        let staging = root.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let model = LLMModel(id: "test-model", displayName: "Test Model", provider: .gemini,
                             supportsThinking: false, returnsMd: false,
                             inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
        let macFields = env["LIVECAPTURE_MAC_ITEM_FIELDS"] == "1"
        let gatewayConfig = GatewayConfig(
            baseURL: macFields ? "http://127.0.0.1:1234/v1" : "https://gateway.test/v1",
            modelID: "synthetic-tagger", displayName: "Synthetic gateway",
            inputCostPer1M: 1, outputCostPer1M: 2, localModel: macFields)
        let config = SessionProcessingConfig(
            provider: .gemini, model: model, thinkingLevel: .low, apiKey: "",
            taggingMode: .automatic, rotationMode: .off, mergeDocuments: false, outputDirectory: out,
            customOCRPrompt: "", imageScale: 1, enableSegmentJSON: macFields, tagVocabulary: [],
            gateway: gatewayConfig,
            outputImageFile: false, pdfImageMB: 2, exportedImageMB: 3, textColumns: 1)
        let session = CaptureSession()
        let processor = session.liveProcessor
        session._recoveryTestBeginLive(config: config, stagingDir: staging)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let jpeg = bitmap?.representation(using: .jpeg, properties: [:]) else {
            throw ProbeError("could not make JPEG")
        }

        let documents = macFields ? ["CONTROL-MEMO"] : ["CONTROL-MEMO", "REFUSED-MEMO"]
        var lines: [String] = []
        for (index, id) in documents.enumerated() {
            if macFields {
                LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(
                    text: "\(id)\nMemorandum dated March 1918.", classification: .documentStart,
                    errorMessage: nil, errorCode: nil)
            }
            guard session.ingest(jpeg: jpeg, groupId: id, seq: index + 1, type: .document,
                                 quality: nil, year: 1918, month: 3, deviceName: "TestPhone") != nil,
                  session.markSegmentComplete(groupId: id, quality: nil, year: 1918, month: 3),
                  session.pendingTagGroup?.id == id, session.skipMacTags(groupId: id) else {
                throw ProbeError("could not receive and resolve \(id)")
            }
            if let warning = processor.trainingWarning { throw ProbeError(warning) }
            try await wait(for: "staging \(id)") {
                guard let phase = processor.statuses.first(where: { $0.id == id })?.phase else { return false }
                return !phase.isProcessing
            }
            guard let status = processor.statuses.first(where: { $0.id == id }),
                  let pdf = processor.stagedURLs(for: id).first else { throw ProbeError("no output for \(id)") }
            let row = SegmentItem(status: status, ocrText: processor.retainedText(for: id),
                                  providerModel: config.retryBackendDescription, expanded: true, finalizing: false)
            lines.append("\(id) staged Finder tags: \(try MacOSTagger.readTags(from: pdf).sorted())")
            lines.append("\(id) row: \(row.title), \(row.state), error=\(row.errorMessage ?? "nil"), code=\(row.errorCode ?? "nil"), actions=\(row.availableActions)")
            lines.append("\(id) session status: \(session.statusMessage)")
        }
        let requests = await gateway.statuses
        let expectedRequests = macFields ? [200] : [200, 500]
        guard requests == expectedRequests else { throw ProbeError("unexpected gateway responses \(requests)") }
        if macFields {
            let localCalls = await gateway.macModels
            guard localCalls == [ItemFieldExtractor.macImageModel, ItemFieldExtractor.macTextModel] else {
                throw ProbeError("unexpected local calls \(localCalls)")
            }
        }
        lines.append("Gateway responses, in order: \(requests)")

        let paidBeforeFinish = SettingsLayerStore.shared.paidRequestsThisMonth()
        if !macFields {
            let reported = paidBeforeFinish.filter { $0.request?.basis == .reported }
            let pageRequests = await gateway.pageRequests
            let fieldRequests = await gateway.fieldRequests
            let reportedUSD = reported.reduce(0) { $0 + $1.usd }
            guard pageRequests == 2, fieldRequests == 2, paidBeforeFinish.count == 6, reported.count == 5,
                  abs(reportedUSD - 0.010) < 1e-9,
                  paidBeforeFinish.contains(where: { $0.request?.basis == .unresolved && $0.usd > 0 })
            else {
                throw ProbeError("Live Capture billing before Finish: \(pageRequests) page reads, \(fieldRequests) field reads,"
                                 + " \(paidBeforeFinish.count) ledger entries, \(reported.count) reported at \(reportedUSD)")
            }
            lines.append("Live Capture recorded both page reads, both tagging attempts, and both item field calls before Finish.")
        } else if !paidBeforeFinish.isEmpty {
            throw ProbeError("Local model requests appeared in the paid ledger")
        }

        processor.requestFinish()
        guard processor.showFinalizeSheet, processor.drafts.count == 1 else {
            throw ProbeError("Finish did not reach collection naming")
        }
        var draft = processor.drafts[0]
        draft.finalName = "S045"
        processor.finalize([draft])
        try await wait(for: "Finish") { processor.finalizeSummary != nil }
        guard SettingsLayerStore.shared.paidRequestsThisMonth() == paidBeforeFinish else {
            throw ProbeError("Finish changed the paid request ledger")
        }
        let summary = processor.finalizeSummary ?? ""
        lines.append("Finish summary: \(summary)")
        lines.append("Finish shows warning: \(LiveCaptureProcessor.summaryReportsProblem(summary))")
        let folder = out.appendingPathComponent("S045", isDirectory: true)
        let pdfs = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard pdfs.count == documents.count else { throw ProbeError("unexpected filed PDF count \(pdfs.count)") }
        let expectedSubjects: Set<String> = ["War Department", "Military Intelligence"]
        for (pdf, id) in zip(pdfs, documents) {
            let text = PDFTextExtractor.extract(from: pdf).text ?? ""
            guard text.contains(id) else { throw ProbeError("filed PDF lost OCR text for \(id)") }
            let tags = Set(try MacOSTagger.readTags(from: pdf))
            guard tags.contains("1918"), tags.contains("Unread"),
                  id != documents.first || expectedSubjects.isSubset(of: tags) else {
                throw ProbeError("Finder tag fixture failed for \(id): \(tags.sorted())")
            }
            if macFields {
                let fields = PDFDocument(url: pdf).flatMap { PDFHeaderParser.textPageHeaders($0).first.flatMap { $0 } }?.itemFields
                guard fields?.documentKind == "report", fields?.byline == "Mary Jones",
                      fields?.publicationDate == "1967-03",
                      fields?.lowerConfidence == [.documentKind, .byline, .publicationDate],
                      let sidecar = ZoteroSidecar.read(pdf: pdf), sidecar.itemFields.byline == "Mary Jones" else {
                    throw ProbeError("filed PDF or sidecar lost the suggested item fields")
                }
                lines.append("Live Capture received, staged and filed the lower-confidence Mac item fields")
            }
            lines.append("\(pdf.lastPathComponent) (\(id)) Finder tags: \(tags.sorted())")
        }
        return lines.joined(separator: "\n")
    }

    private static func wait(for operation: String, until ready: () -> Bool) async throws {
        for _ in 0..<400 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProbeError("timed out waiting for \(operation)")
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
#endif
