import ArchiveCore
import Foundation

/// The optional label classifier of adoption (W49.proc-backfill-classify-optin, owner calls 21 and 31). An archive
/// without the owner's tags or colour marks has its box and folder photos read as documents; this pass finds them.
/// It reads each one-page file the inventory gave no item type, with Vision on this Mac, and asks the Processor's
/// text-only page classifier (`OCRPrompt.buildClassificationOnly`, the pre-OCRed route's) whether it is a box label,
/// a folder label or a document. Without `run` it only prints what the pass would cost and take, from a timed Vision
/// sample; with `run` it goes ahead only when that estimate is within the cap the user gives. It writes only the
/// manifest: a found label becomes a proposed item type that waits for review (`type-classified`).
enum AdoptionClassify {
    /// The page's text for the classifier, given the entry's path and the image to read: Vision on this Mac, $0 and
    /// no network. nil when Vision read nothing.
    typealias TextReader = @Sendable (String, URL) async -> String?
    /// The judgement on one page's text.
    typealias Judge = @Sendable (String) async throws -> DocumentClassification?

    static let visionText: TextReader = { _, image in
        let text = try? await PageReaders.visionReader().read(.init(imageURL: image)).detail.text
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Where the judgement is made. `vision-heuristic` is the Processor's keyword rules ($0, nothing leaves this Mac);
    /// `<provider>:<model id>` sends the Vision text (never the image) to that model with the user's key.
    enum Route: Equatable {
        case heuristic
        case model(LLMModel)

        static let heuristicName = "vision-heuristic"

        init?(_ name: String) {
            if name == Self.heuristicName { self = .heuristic; return }
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let provider = LLMProvider.allCases.first(where: { $0.rawValue.lowercased() == parts[0].lowercased() }),
                  provider != .appleVision,
                  let model = provider.models.first(where: { $0.id == parts[1] }) else { return nil }
            self = .model(model)
        }

        var name: String {
            switch self {
            case .heuristic: Self.heuristicName
            case .model(let model): "\(model.provider.rawValue.lowercased()):\(model.id)"
            }
        }

        /// One file's price by the Processor's own estimate for a text-only classification (`CostEstimator`: 600
        /// tokens in, 10 out); Mistral's text calls go to Mistral Small at its own rates. nil when the price is not known.
        var dollarsPerPage: Double? {
            guard case .model(let model) = self else { return 0 }
            if model.unpriced == true { return nil }
            let rates = model.provider == .mistral ? LLMTextClient.mistralTextRates
                : (input: model.inputCostPer1M, output: model.outputCostPer1M)
            return (CostEstimator.estimatedClassificationInputTokens * rates.input
                    + CostEstimator.estimatedClassificationOutputTokens * rates.output) / 1_000_000
        }

        var secondsPerCall: Double {
            guard case .model(let model) = self else { return 0 }
            return TimeEstimator.callSeconds(outputTokens: CostEstimator.estimatedClassificationOutputTokens,
                                             speed: TimeEstimator.speedFactor(for: model))
        }

        func judge(apiKey: String) -> Judge {
            switch self {
            case .heuristic:
                return { text in MistralClient.heuristicClassify(text: text, previousText: nil) }
            case .model(let model):
                return { text in
                    let reply = try await LLMTextClient.complete(
                        prompt: OCRPrompt.buildClassificationOnly(text: text, previousText: nil),
                        // The lowest thinking level keeps a reasoning model's reply near the estimate.
                        provider: model.provider, model: model, thinkingLevel: model.supportsThinking ? .low : nil,
                        apiKey: apiKey,
                        gatewayConfig: nil, maxTokens: maxTokens, timeout: 30)
                    return OCRPrompt.parseResponse(reply).0
                }
            }
        }
    }

    static let maxTokens = 64
    static let sampleSize = 3
    static let rulePrefix = "classifier:"

    struct Estimate: Equatable {
        let candidates: Int
        let sampled: Int
        let visionSecondsPerPage: Double
        let dollarsPerPage: Double?
        let secondsPerCall: Double

        var dollars: Double? { dollarsPerPage.map { $0 * Double(candidates) } }
        var seconds: Double { Double(candidates) * (visionSecondsPerPage + secondsPerCall) }
    }

    struct Result: Equatable {
        var boxes: [String] = []
        var folders: [String] = []
        var documents = 0
        var unread: [String] = []
        var failed: [String] = []
        var calls = 0
    }

    /// The entries the pass would read: one page, no item type yet, not skipped, convertible, not read by an
    /// earlier pass, and not yet frozen by conversion (a filed entry's facts are fixed).
    static func candidates(_ manifest: AdoptionManifest, ledger: AdoptionLedger?) -> [Int] {
        manifest.entries.indices.filter { index in
            let entry = manifest.entries[index]
            return entry.proposal.itemType == nil && entry.classified == nil && entry.decision != .skip
                && entry.pageCount == 1 && entry.review.allSatisfy(\.convertible) && ledger?.items[entry.path] == nil
        }
    }

    /// The photo the classifier reads: the matched original when it is on this Mac, else the PDF's page rendered
    /// into the temporary folder (`rendered`, deleted after the read).
    private static func image(for entry: AdoptionManifest.Entry, manifest: AdoptionManifest) async -> (URL, rendered: Bool)? {
        if entry.original.state == .matched, !entry.review.contains(.originalOffline),
           let originals = manifest.originalsRoot, let path = entry.original.path {
            return (URL(fileURLWithPath: originals).appendingPathComponent(path), false)
        }
        let pdf = URL(fileURLWithPath: manifest.sourceRoot).appendingPathComponent(entry.path)
        let image = await PDFGenerator.runWorker { PDFToImageConverter.imageURL(for: pdf) }
        return image == pdf ? nil : (image, true)
    }

    private static func read(_ entry: AdoptionManifest.Entry, manifest: AdoptionManifest,
                             reader: TextReader) async -> String?? {
        guard let (url, rendered) = await image(for: entry, manifest: manifest) else { return .none }
        let text = await reader(entry.path, url)
        if rendered { try? FileManager.default.removeItem(at: url) }
        return .some(text)
    }

    /// Times Vision on up to `sampleSize` candidates ($0) and prices the rest. Changes nothing.
    static func estimate(_ manifest: AdoptionManifest, ledger: AdoptionLedger?, route: Route,
                         reader: TextReader = visionText, clock: @Sendable () -> Date = Date.init) async -> Estimate {
        let indices = candidates(manifest, ledger: ledger)
        var elapsed = 0.0
        let sample = indices.prefix(sampleSize)
        for index in sample {
            let start = clock()
            _ = await read(manifest.entries[index], manifest: manifest, reader: reader)
            elapsed += clock().timeIntervalSince(start)
        }
        return Estimate(candidates: indices.count, sampled: sample.count,
                        visionSecondsPerPage: sample.isEmpty ? 0 : elapsed / Double(sample.count),
                        dollarsPerPage: route.dollarsPerPage, secondsPerCall: route.secondsPerCall)
    }

    /// Classifies every candidate and records each verdict in `manifest`. A box or folder label becomes a proposed
    /// item type with the classifier as its rule and waits for review; a document or an unread page keeps no type.
    static func run(_ manifest: inout AdoptionManifest, ledger: AdoptionLedger?, route: Route, judge: Judge,
                    reader: TextReader = visionText) async throws -> Result {
        var result = Result()
        let rule = rulePrefix + route.name
        for index in candidates(manifest, ledger: ledger) {
            try Task.checkCancellation()
            let entry = manifest.entries[index]
            guard case .some(let outcome) = await read(entry, manifest: manifest, reader: reader) else {
                result.failed.append(entry.path); continue
            }
            guard let text = outcome else {
                manifest.entries[index].classified = .init(value: "unread", rule: rule, evidence: "Vision read no text")
                result.unread.append(entry.path)
                continue
            }
            let verdict: DocumentClassification?
            do {
                if case .model = route { result.calls += 1 }
                verdict = try await judge(text)
            } catch {
                result.failed.append(entry.path); continue
            }
            let quote = String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            let type: ItemType? = switch verdict {
            case .boxLabel: .box
            case .folderLabel: .folder
            default: nil
            }
            let tag = verdict.map { "[\($0.rawValue)]" } ?? "no tag"
            manifest.entries[index].classified = .init(value: type.map { $0.rawValue.lowercased() } ?? "document",
                                                       rule: rule, evidence: "\(tag) from Vision text \"\(quote)\"")
            guard let type else { result.documents += 1; continue }
            manifest.entries[index].proposal.itemType = .init(value: type.rawValue.lowercased(), rule: rule,
                                                              evidence: "\(tag) from Vision text \"\(quote)\"")
            if !manifest.entries[index].review.contains(.typeClassified) {
                manifest.entries[index].review.append(.typeClassified)
            }
            manifest.entries[index].decision = .review
            if type == .box { result.boxes.append(entry.path) } else { result.folders.append(entry.path) }
        }
        return result
    }
}
