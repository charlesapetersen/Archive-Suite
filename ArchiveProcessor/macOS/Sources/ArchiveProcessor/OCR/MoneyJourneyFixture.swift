#if DEBUG
import CryptoKit
import Foundation
import ImageIO

/// Scratch inputs and a no-wire reply for the off-screen spending journeys. Capture uses the normal
/// persistence path, and the request recorder observes the already-encoded payload at the transport seam.
enum MoneyJourneyFixture {
    static let isActive = ProcessInfo.processInfo.environment["ARCHIVEPROC_HEADLESS"] == "1"
        && ProcessorUITestConfiguration.isActive
        && ProcessInfo.processInfo.arguments.contains("-APUITestMoneyJourney")
    static let dummyKey = "scratch-money-no-wire"

    static var directory: URL {
        guard isActive, let output = ProcessorUITestConfiguration.outputDirectory else {
            preconditionFailure("Spending journey requires a scratch output directory")
        }
        let root = output.deletingLastPathComponent().resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path.hasSuffix("/Library/Containers/com.archiveprocessor.uitests.xctrunner/Data/tmp"),
              UUID(uuidString: root.lastPathComponent) != nil,
              output.lastPathComponent == "out",
              output.resolvingSymlinksInPath().path == root.appendingPathComponent("out").path,
              ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"].map({
                  URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
              }) == root.appendingPathComponent("backup").path else {
            preconditionFailure("Spending journey must use its own temporary output and backup")
        }
        for child in ["state", "calls", "in"] {
            let url = root.appendingPathComponent(child)
            precondition(url.resolvingSymlinksInPath().path == url.path)
        }
        return root
    }

    private static var refusesGeminiReading: Bool {
        isActive && ProcessInfo.processInfo.arguments.contains("-APUITestGeminiRefusal")
    }

    static var monthlyLimit: Double? {
        let args = ProcessInfo.processInfo.arguments
        guard isActive, let index = args.firstIndex(of: "-APUITestMonthlyLimit"),
              args.indices.contains(index + 1) else { return nil }
        return Double(args[index + 1])
    }

    @MainActor static func configureIfRequested() {
        guard isActive else { return }
        _ = directory
        if let monthlyLimit {
            let store = SettingsLayerStore.shared
            var general = store.general
            let source = SettingsSource.setByUser(Date())
            general.set(.moneyHabit, .string(MoneyHabit.perMonth.rawValue), source: source)
            general.set(.monthCeilingUSD, .double(monthlyLimit), source: source)
            precondition(store.replaceGeneral(general))
            if store.file.ledger.isEmpty {
                precondition(store.recordSpend(usd: 1, runID: nil, outputDirectory: nil, files: 1))
            }
        }
        if refusesGeminiReading {
            OCRRefusalFallback.routesOverride = {
                guard let model = LLMModel.openaiModels.first(where: { $0.id == "gpt-5.4-mini" }) else { return [] }
                return [.init(provider: .openai, model: model, apiKey: dummyKey, localAgent: nil)]
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-APUITestScratchPageKinds") {
            PageKindStore.classifyOverride = { _ in PageKind(kind: .typewritten, confidence: 1) }
            PageKindStore.availableOverride = [.init(provider: .openai, modelID: "gpt-5-nano")]
        }
        // W49.proc-kind-split-mac: every photo is handwritten, and Qwen3-VL 8B is "downloaded" behind a stand-in host.
        if ProcessInfo.processInfo.arguments.contains("-APUITestScratchMacHandwriting") {
            PageKindStore.classifyOverride = { _ in PageKind(kind: .handwritten, confidence: 0.95) }
            let q8 = ManagedOCRModel.qwen3VL8B
            PageKindStore.localOverride = [.init(provider: .appleVision, modelID: q8.rawValue)]
            PageKindRouting.managedGatewayOverride = { m in
                m == q8 ? GatewayConfig(baseURL: "http://\(macLocalHost)/v1", modelID: m.rawValue,
                                        displayName: m.pick.displayName, inputCostPer1M: nil, outputCostPer1M: nil,
                                        localModel: true) : nil
            }
        }
    }

    @MainActor static func receiveScratchPhotosIfRequested(in session: CaptureSession) {
        guard isActive, ProcessInfo.processInfo.arguments.contains("-APUITestReceiveScratchPhotos"),
              session.photos.isEmpty else { return }
        if ProcessInfo.processInfo.arguments.contains("-APUITestRefuseHandoffReceipt") {
            session.manifestWriteOverride = { data, url in
                guard CaptureSession.decodeManifest(data)?.completedHandoff.isEmpty == true else { return false }
                do { try data.write(to: url, options: .atomic); return true }
                catch { return false }
            }
        }
        session.beginStageSessionForTest()
        for index in 1...2 {
            let changed = ProcessInfo.processInfo.arguments.contains("-APUITestReceiveChangedScratchPhoto")
            let sourceIndex = index == 1 && changed ? 2 : index
            let photo = directory.appendingPathComponent("in/photo-\(sourceIndex).jpg")
            guard let data = try? Data(contentsOf: photo),
                  session.ingest(jpeg: data, groupId: "doc", seq: index, type: .document,
                                 quality: nil, year: nil, month: nil, deviceName: "Scratch phone") != nil else {
                preconditionFailure("Could not receive scratch photo \(index)")
            }
        }
    }

    /// The stand-in for a downloaded model's worker on this Mac.
    static let macLocalHost = "mac-local.invalid"

    static let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        guard request.httpMethod == "POST", let url = request.url, let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw URLError(.unsupportedURL)
        }
        let reading = "[document_start]\nDear friend, this is a synthetic letter dated 12 March 1978."
        let reply: [String: Any]
        let images: [Data]
        let model: String
        let route: String
        let status: Int
        switch (url.host, url.path) {
        case ("api.openai.com", "/v1/chat/completions"):
            let messages = json["messages"] as? [[String: Any]] ?? []
            images = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { part in
                guard let field = part["image_url"] as? [String: Any], let dataURL = field["url"] as? String,
                      let comma = dataURL.firstIndex(of: ",") else { return nil }
                return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
            }
            model = json["model"] as? String ?? ""
            route = "openai"
            status = 200
            reply = ["choices": [["message": ["content": reading], "finish_reason": "stop"]]]
        case (macLocalHost, "/v1/chat/completions"):
            let messages = json["messages"] as? [[String: Any]] ?? []
            images = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { part in
                guard let field = part["image_url"] as? [String: Any], let dataURL = field["url"] as? String,
                      let comma = dataURL.firstIndex(of: ",") else { return nil }
                return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
            }
            model = json["model"] as? String ?? ""
            route = "mac-local"
            status = 200
            reply = ["choices": [["message": ["content": reading], "finish_reason": "stop"]]]
        case ("generativelanguage.googleapis.com", let path) where path.hasSuffix(":generateContent"):
            images = geminiImages(in: json)
            model = String(url.lastPathComponent.prefix { $0 != ":" })
            route = "gemini-direct"
            status = 200
            reply = refusesGeminiReading
                ? ["candidates": [["finishReason": "SAFETY"]]]
                : ["candidates": [["content": ["parts": [["text": reading]]], "finishReason": "STOP"]]]
        case ("generativelanguage.googleapis.com", let path) where path.hasSuffix(":batchGenerateContent"):
            let batch = json["batch"] as? [String: Any]
            let config = batch?["inputConfig"] as? [String: Any]
            let requests = config?["requests"] as? [String: Any]
            images = (requests?["requests"] as? [[String: Any]] ?? []).flatMap {
                geminiImages(in: $0["request"] as? [String: Any] ?? [:])
            }
            model = String(url.lastPathComponent.prefix { $0 != ":" })
            route = "gemini-batch"
            status = 400
            reply = ["error": ["status": "INVALID_ARGUMENT", "message": "Scratch recorder stops after submission."]]
        default:
            preconditionFailure("Unexpected provider request in the spending journey")
        }
        guard !images.isEmpty, !model.isEmpty else { throw URLError(.cannotDecodeContentData) }
        for image in images {
            guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? Int,
                  let height = info[kCGImagePropertyPixelHeight] as? Int else {
                throw URLError(.cannotDecodeContentData)
            }
            let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            let record = "\(route)\t\(model)\t\(width)x\(height)\t\(image.count)\t\(digest)"
            let file = directory.appendingPathComponent("calls").appendingPathComponent(UUID().uuidString)
            try Data(record.utf8).write(to: file, options: .atomic)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.data(withJSONObject: reply), response)
    }

    private static func geminiImages(in body: [String: Any]) -> [Data] {
        let contents = body["contents"] as? [[String: Any]] ?? []
        return contents.flatMap { $0["parts"] as? [[String: Any]] ?? [] }.compactMap { part in
            guard let inline = part["inlineData"] as? [String: Any], let data = inline["data"] as? String else { return nil }
            return Data(base64Encoded: data)
        }
    }
}
#endif
