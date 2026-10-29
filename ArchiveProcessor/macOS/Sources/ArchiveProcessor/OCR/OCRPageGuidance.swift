import SwiftUI

/// Which OCR model reads which kind of page best, from the W41 OCR panels (W41.app-ocr-hierarchy). The figures live in
/// one checked-in table, `segbench-results/ocr-page-guidance.json`, bundled straight from the bench like
/// `options.json`; `scripts/test-ocr-page-guidance.sh` checks every figure against the result file it names.
struct OCRPageGuidance: Decodable, Equatable {
    struct Source: Decodable, Equatable {
        let file: String
        let route: String
        let attribute: String
        let value: String
    }

    struct Pick: Decodable, Equatable {
        let name: String
        let nes: Double
        /// The Processor's `LLMModel.id` when the app offers this model; nil when it does not.
        let appModel: String?
        let source: Source

        enum CodingKeys: String, CodingKey { case name, nes, appModel = "app_model", source }
    }

    struct Kind: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let pages: Int
        let picks: [Pick]
        let note: String?
    }

    let measured: String
    let footnote: String
    let kinds: [Kind]

    static let resourceName = "ocr-page-guidance"

    static func decode(_ data: Data) throws -> OCRPageGuidance {
        try JSONDecoder().decode(OCRPageGuidance.self, from: data)
    }

    /// Loaded once; nil hides the note.
    static let bundled = loadBundled()

    /// nil when the resource is missing or does not decode; the picker then simply shows no note.
    static func loadBundled(_ bundle: Bundle = .main) -> OCRPageGuidance? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    /// Every built-in model id, for `appModel` checks. Built-in only: a custom model that happens to share an id is
    /// not the model that was measured.
    static var builtInModelIDs: Set<String> {
        Set((LLMModel.anthropicModels + LLMModel.geminiModels + LLMModel.mistralModels + LLMModel.openaiModels
             + LLMModel.openrouterModels).map(\.id))
    }

    /// What is wrong with the table, so a bad bench edit fails the self-test instead of reaching the picker.
    func problems(modelIDs: Set<String> = builtInModelIDs) -> [String] {
        var out: [String] = []
        if kinds.isEmpty { out.append("no kinds") }
        if Set(kinds.map(\.id)).count != kinds.count { out.append("duplicate kind ids") }
        for k in kinds {
            if k.picks.isEmpty { out.append("\(k.id): no picks") }
            if k.pages <= 0 { out.append("\(k.id): no pages") }
            if k.picks.map(\.nes) != k.picks.map(\.nes).sorted(by: >) { out.append("\(k.id): picks not best first") }
            for p in k.picks {
                if !(0...100).contains(p.nes) { out.append("\(k.id): \(p.name) NES \(p.nes) out of range") }
                if let id = p.appModel, !modelIDs.contains(id) { out.append("\(k.id): \(p.name) app_model \(id) unknown") }
            }
        }
        return out
    }

    /// One pick as the note reads it: "Gemini 3.8 Flash 96.0", with " (not in this list yet)" when the app lacks it.
    static func text(_ p: Pick, modelIDs: Set<String>) -> String {
        let score = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), p.nes)
        let missing = p.appModel.map { modelIDs.contains($0) } == true ? "" : " (not in this list yet)"
        return "\(p.name) \(score)\(missing)"
    }

    /// The line for one kind of page: "Handwriting (16 pages): Gemini 3.8 Flash 96.0, then Gemini 3.1 Pro 94.1."
    static func line(_ k: Kind, modelIDs: Set<String>) -> String {
        let picks = k.picks.map { text($0, modelIDs: modelIDs) }
        let head = picks.first ?? ""
        let rest = picks.dropFirst().joined(separator: ", ")
        let body = rest.isEmpty ? head : "\(head), then \(rest)"
        let pages = k.pages == 1 ? "1 page" : "\(k.pages) pages"
        return "\(k.label) (\(pages)): \(body)." + (k.note.map { " \($0)" } ?? "")
    }
}

/// The note under the OCR model picker.
struct OCRPageGuidanceNote: View {
    let guidance: OCRPageGuidance
    var modelIDs: Set<String> = OCRPageGuidance.builtInModelIDs

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("What reads which pages best")
                .font(.caption.weight(.semibold))
            ForEach(guidance.kinds) { k in
                Text(OCRPageGuidance.line(k, modelIDs: modelIDs))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(guidance.footnote)
                .font(.caption2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.settings.ocrPageGuidance")
    }
}
