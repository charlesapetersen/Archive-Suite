#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import ArchiveCore
import Foundation
import PDFKit
import SwiftUI
import VisionOCRKit

/// Key-free, no-network contract for W41.app-page-kind, gated by `OCRPAGEKIND_TEST=1`. Checks the bundled classifier
/// weights, the routing from a page's kind to the guide's first runnable pick, the file list's plan (per-page and
/// per-batch choices, PDFs left out), the cost the plan adds, and drives the REAL `OCRProcessor.performOCRCall`
/// through the injected HTTP transport to show a planned page reaching its chosen provider and recording it. Keys
/// come from `OCRCascade.keyOverride`, never the Keychain. With `OCRPAGEKIND_PARITY_LIST` (rows `id <TAB> image`)
/// it also classifies those images and writes `id kind confidence p_hand… p_form` rows to
/// `OCRPAGEKIND_PARITY_OUT`, which `scripts/test-ocr-page-kind.sh` compares with the bench's own predictions.
///
/// Run via `scripts/test-ocr-page-kind.sh`.
@MainActor
enum OCRPageKindTestDriver {
    nonisolated static let envKey = "OCRPAGEKIND_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private actor Script {
        var answers: [String: (Int, String)] = [:]
        var hosts: [String] = []
        func set(_ answers: [String: (Int, String)]) { self.answers = answers; hosts = [] }
        func answer(_ request: URLRequest) -> (Int, String) {
            let host = request.url?.host ?? ""
            hosts.append(host)
            for (key, value) in answers where host.contains(key) { return value }
            return (404, "{}")
        }
        func calls() -> [String] { hosts }
        func reset() { hosts = [] }
    }

    static func run() async {
        var results: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            results.append(condition ? "PASS: \(name)" : "FAIL: \(name) \(detail())")
        }
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APPageKind-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. The weights.
        guard let model = PageKindModel.bundled else {
            finish(["FAIL: the bundled kind-classifier-model.json is missing or does not decode"])
            return
        }
        check("1 the weights have no problems", model.problems().isEmpty, "\(model.problems())")
        check("1 the feature print is 768 values (macOS 26's revision)", model.printLength == 768, "\(model.printLength)")
        let zeros = model.hand.probabilities([Double](repeating: 0, count: model.hand.features.count)) ?? []
        check("1 the hand's probabilities sum to 1", zeros.count == 3 && abs(zeros.reduce(0, +) - 1) < 1e-9)
        check("1 a feature list of the wrong length is refused", model.hand.probabilities([1, 2]) == nil)
        check("1 a page with no Vision signal reads its NaN scalars as 0, as the bench fitted",
              PageKindSignals(print: [1, 2]).handFeatures() == [0, 0, 0, 0, 0, 1, 2]
              && PageKindSignals(tableShare: 0.5, tableCells: 3, print: [1]).formFeatures() == [0.5, 3, 0, 0, 0, 0, 0, 1])

        // 2. The decision: a form wins over the hand, as the bench routed.
        let hc = model.hand.classes
        check("2 the hand's top class decides when no form is called",
              PageKind.decide(hand: [0.1, 0.85, 0.05], form: [0.9, 0.1], handClasses: hc)
              == PageKind(kind: .typewritten, confidence: 0.85))
        check("2 a form call wins, with the form regression's probability",
              PageKind.decide(hand: [0.1, 0.85, 0.05], form: [0.3, 0.7], handClasses: hc)
              == PageKind(kind: .forms, confidence: 0.7))

        // 3. Routing from the kind to the guide's pick.
        guard let guide = OCRPageGuidance.loadBundled() else {
            finish(results + ["FAIL: the bundled ocr-page-guidance.json is missing"])
            return
        }
        let claude = LLMModel.anthropicModels[0]
        let flash = LLMModel.geminiModels.first { $0.id == "gemini-3.8-flash" }
        let qwen = LLMModel.openrouterModels.first { $0.id == "qwen/qwen3.6-27b" }
        guard let flash, let qwen else {
            finish(results + ["FAIL: catalog models missing"])
            return
        }
        func cand(_ m: LLMModel) -> PageKindRouting.Candidate { .init(provider: m.provider, modelID: m.id) }
        let runDefault = cand(claude)
        let all: Set = [cand(claude), cand(flash), cand(qwen)]
        func choose(_ kind: PageKindName?, _ conf: Double = 0.95, available: Set<PageKindRouting.Candidate> = all,
                    run: PageKindRouting.Candidate = runDefault, override: PageKindRouting.Candidate? = nil,
                    hand: Bool = false) -> PageKindRouting.Choice {
            PageKindRouting.choose(kind: kind.map { PageKind(kind: $0, confidence: conf) }, guidance: guide,
                                   available: available, runDefault: run, override: override, handwritingOnTyped: hand)
        }
        check("3 a sure typewritten page goes to the guide's first pick, Gemini 3.8 Flash",
              choose(.typewritten) == .init(provider: .gemini, modelID: flash.id, reason: .kind))
        check("3 a sure handwritten page too", choose(.handwritten).modelID == flash.id)
        check("3 a form goes to Qwen3.6 27B", choose(.forms) == .init(provider: .openrouter, modelID: qwen.id, reason: .kind))
        check("3 printed: Claude Sonnet 5.5 is not in the app, so the next pick, Qwen3.6 27B",
              choose(.printed).modelID == qwen.id)
        check("3 a pick with no key is passed over; none runnable keeps the run's model (no_pick)",
              choose(.printed, available: [cand(claude)]) == .init(provider: .anthropic, modelID: claude.id, reason: .noPick))
        check("3 the guide's pick being the run's model reads as same",
              choose(.typewritten, run: cand(flash)).reason == .same)
        check("3 a page under \(PageKindRouting.minimumConfidence) keeps the run's model (uncertain)",
              choose(.typewritten, 0.79) == .init(provider: .anthropic, modelID: claude.id, reason: .uncertain)
              && choose(.typewritten, PageKindRouting.minimumConfidence).reason == .kind)
        check("3 a page with no kind keeps the run's model (unknown)", choose(nil).reason == .unknown)
        check("3 the user's choice wins over the kind, and over uncertainty",
              choose(.typewritten, 0.3, override: cand(qwen)) == .init(provider: .openrouter, modelID: qwen.id, reason: .override))
        // W46.mixed-route-setting: "Read handwriting on typed pages" sends typed and printed pages to the handwritten pick.
        check("3 handwriting on typed pages: a printed page goes to the handwritten pick, Gemini 3.8 Flash, not Qwen",
              choose(.printed, hand: true) == .init(provider: .gemini, modelID: flash.id, reason: .handwriting))
        check("3 handwriting on typed pages: a typewritten page too, recorded as the switch's",
              choose(.typewritten, hand: true) == .init(provider: .gemini, modelID: flash.id, reason: .handwriting))
        check("3 handwriting on typed pages leaves handwritten pages and forms on their own kind's pick",
              choose(.handwritten, hand: true).reason == .kind
              && choose(.forms, hand: true) == .init(provider: .openrouter, modelID: qwen.id, reason: .kind))
        check("3 handwriting on typed pages: no runnable handwritten pick routes the page by its own kind",
              choose(.printed, available: [cand(claude), cand(qwen)], hand: true)
              == .init(provider: .openrouter, modelID: qwen.id, reason: .kind))
        check("3 handwriting on typed pages: the handwritten pick being the run's model reads as same",
              choose(.printed, run: cand(flash), hand: true).reason == .same)
        check("3 handwriting on typed pages leaves an unsure page and the user's choice alone",
              choose(.printed, 0.79, hand: true).reason == .uncertain
              && choose(.printed, override: cand(claude), hand: true).reason == .override)
        check("3 the switch's reason reroutes and reads in the file list",
              PageKindRouting.Reason.handwriting.routes && !PageKindRouting.Reason.same.routes
              && PageKindRouting.summary(kind: PageKind(kind: .printed, confidence: 0.9),
                                         choice: choose(.printed, hand: true), modelName: flash.displayName)
              == "Printed (90%) → \(flash.displayName), for its handwriting")
        check("3 keyed candidates: every built-in model of a keyed provider, none of an unkeyed one",
              PageKindRouting.keyedCandidates(key: { $0 == .gemini ? "k" : ($0 == .openai ? "" : nil) })
              == Set(LLMModel.geminiModels.map(cand)))

        // 4. The file list's plan: per-page and per-batch choices; a PDF and a page not yet told are left out.
        let a = root.appendingPathComponent("a.jpg"), b = root.appendingPathComponent("b.jpg")
        let c = root.appendingPathComponent("c.jpg"), pdf = root.appendingPathComponent("d.pdf")
        let told: [String: PageKind] = [PageReaderPlan.key(a): PageKind(kind: .typewritten, confidence: 0.97),
                                        PageReaderPlan.key(b): PageKind(kind: .forms, confidence: 0.9),
                                        PageReaderPlan.key(c): PageKind(kind: .printed, confidence: 0.5)]
        PageKindStore.classifyOverride = { told[PageReaderPlan.key($0)] }
        PageKindStore.availableOverride = all
        defer { PageKindStore.classifyOverride = nil; PageKindStore.availableOverride = nil }
        let store = PageKindStore()
        store.update([a, b, c, pdf])
        for _ in 0..<200 where store.pending > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        var plan = store.plan([a, b, c, pdf], guidance: guide, runDefault: runDefault)
        check("4 every image page is told and planned; the PDF is not", store.pending == 0 && plan.pages.count == 3
              && plan.entry(for: pdf) == nil && store.kind(for: pdf) == nil)
        check("4 the plan carries each page's kind and reader",
              plan.entry(for: a)?.choice.modelID == flash.id && plan.entry(for: b)?.choice.modelID == qwen.id
              && plan.entry(for: c)?.choice.reason == .uncertain && plan.entry(for: a)?.kind?.confidence == 0.97)
        store.overrides[PageReaderPlan.key(a)] = .run
        plan = store.plan([a, b, c], guidance: guide, runDefault: runDefault)
        check("4 a per-page choice of the run's model keeps that page on it",
              plan.entry(for: a)?.choice == .init(provider: .anthropic, modelID: claude.id, reason: .override))
        plan = store.plan([a], guidance: guide, runDefault: cand(qwen))
        check("4 \"the run's model\" follows a later change of the run's model",
              plan.entry(for: a)?.choice.modelID == qwen.id)
        store.batchOverride = .model(cand(flash))
        plan = store.plan([a, b, c], guidance: guide, runDefault: runDefault)
        check("4 a batch choice sends every page there, except the page with its own choice",
              plan.entry(for: b)?.choice.modelID == flash.id && plan.entry(for: c)?.choice.modelID == flash.id
              && plan.entry(for: a)?.choice.modelID == claude.id)
        store.update([b])
        check("4 a page removed from the list loses its own choice", store.overrides.isEmpty)
        store.batchOverride = nil
        store.handwritingOnTyped = true
        let handPlan = store.plan([a, b], guidance: guide, runDefault: cand(qwen))
        check("4 with handwriting on typed pages the store plans the typed page on the handwritten pick",
              handPlan.entry(for: a)?.choice == .init(provider: .gemini, modelID: flash.id, reason: .handwriting)
              && handPlan.entry(for: b)?.choice.reason == .same
              && handPlan.routedCounts(runModel: qwen).map { "\($0.0.id) \($0.1)" } == ["\(flash.id) 1"])
        store.handwritingOnTyped = false
        store.overrides[PageReaderPlan.key(a)] = .run
        if let data = try? JSONEncoder().encode(plan), let back = try? JSONDecoder().decode(PageReaderPlan.self, from: data) {
            check("4 the plan round-trips through the run record's Codable", back == plan)
        } else { check("4 the plan round-trips through the run record's Codable", false) }

        // 5. The estimate follows the per-page choice.
        let pClaude = CostEstimator.secondReaderPageCost(model: claude, imageScale: 1)
        let pFlash = CostEstimator.secondReaderPageCost(model: flash, imageScale: 1)
        let pQwen = CostEstimator.secondReaderPageCost(model: qwen, imageScale: 1)
        plan = store.plan([a, b, c], guidance: guide, runDefault: runDefault)   // a: Claude (own), b: Qwen, c: Claude
        let delta = plan.ocrCostDelta(runModel: claude, imageScale: 1)
        check("5 the plan adds each routed page's price less the run model's", pQwen > 0 && pClaude > 0
              && abs(delta - (pQwen - pClaude)) < 1e-12, "delta \(delta) want \(pQwen - pClaude)")
        let est = CostEstimator.estimate(fileCount: 3, model: claude, enableTagging: false, sendPreviousImage: false,
                                         contextCharCount: 0, imageScale: 1)
        let adjusted = est.addingOCR(delta)
        check("5 the shown estimate moves by exactly that; the batch rate does not",
              abs(adjusted.totalStandard - (est.totalStandard + delta)) < 1e-12 && adjusted.batchOcrCost == est.batchOcrCost)
        check("5 the caption counts pages by reader", plan.routedCounts(runModel: claude).map { "\($0.0.id) \($0.1)" }
              == ["\(qwen.id) 1"])
        check("5 an empty plan adds nothing", PageReaderPlan.empty.ocrCostDelta(runModel: claude, imageScale: 1) == 0)

        // 6. The real performOCRCall: a planned page reaches its chosen provider and records it.
        guard let image = makeJPEG(at: root.appendingPathComponent("page.jpg")),
              let other = makeJPEG(at: root.appendingPathComponent("other.jpg")) else {
            finish(results + ["FAIL: fixture JPEG could not be created"])
            return
        }
        let script = Script()
        check("6 the HTTP seam is dormant before the contract installs it", !NetworkSession.testTransportIsActive)
        NetworkSession.testTransport = { request in
            let (status, body) = await script.answer(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        OCRCascade.keyOverride = { $0 == .mistral ? nil : "test-\($0.rawValue)" }
        OCRRefusalFallback.routesOverride = { [] }
        defer { NetworkSession.testTransport = nil; OCRCascade.keyOverride = nil; OCRRefusalFallback.routesOverride = nil }
        let claudeText = #"{"content":[{"type":"text","text":"[document_start]\nCLAUDE-TEXT"}],"stop_reason":"end_turn"}"#
        let geminiText = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[document_start]\nGEMINI-TEXT"}]}}]}"#
        let qwenCut = #"{"choices":[{"finish_reason":"length","message":{"content":"[document_start]\nloop loop"}}]}"#
        await script.set(["anthropic": (200, claudeText), "generativelanguage": (200, geminiText),
                          "openrouter": (200, qwenCut)])
        let kindA = PageKind(kind: .typewritten, confidence: 0.97)
        var live = PageReaderPlan()
        live.pages[PageReaderPlan.key(image)] = .init(kind: kindA, choice: .init(provider: .gemini, modelID: flash.id, reason: .kind))
        func ocr(_ url: URL, _ readers: PageReaderPlan, cascade: OCRCascade = .off, gateway: GatewayConfig? = nil)
            async -> OCRResult {
            await OCRProcessor.performOCRCall(
                imageURL: url, provider: .anthropic, model: claude, thinkingLevel: .high, apiKey: "test-run",
                previousText: nil, previousImageURL: nil, gatewayConfig: gateway, rotationMode: .off,
                standardImageMB: 4, cascade: cascade, readers: readers)
        }
        var r = await ocr(image, live)
        var calls = await script.calls()
        check("6 a planned page is read by its chosen model, and only by it",
              r.text?.contains("GEMINI-TEXT") == true && calls.count == 1 && calls[0].contains("generativelanguage"),
              "\(calls) \(r.errorMessage ?? "")")
        check("6 the page records its kind, how sure, why, the reader and the prices",
              r.pageReader == PageReaderRecord(kind: "typewritten", confidence: 0.97, reason: .kind, provider: "Gemini",
                                               model: flash.displayName, estimatedCost: pFlash, replacedCost: pClaude),
              "\(String(describing: r.pageReader))")
        if let data = try? JSONEncoder().encode(r), let back = try? JSONDecoder().decode(OCRResult.self, from: data) {
            check("6 the record round-trips through the run record's Codable", back.pageReader == r.pageReader)
        } else { check("6 the record round-trips through the run record's Codable", false) }
        let older = #"{"text":"x","rotationDegrees":0}"#
        check("6 a result written before this field decodes with no record",
              (try? JSONDecoder().decode(OCRResult.self, from: Data(older.utf8)))?.pageReader == nil)
        let pdfURL = root.appendingPathComponent("page.pdf")
        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: claude, outputURL: pdfURL)
        let header = PDFDocument(url: pdfURL)?.page(at: 1)?.string ?? ""
        check("6 the PDF header names the model that read the page, not the run's",
              header.contains("Gemini \u{00B7} \(flash.displayName)") && !header.contains(claude.displayName))
        let parsedHeader = PDFHeaderParser.parse(header)
        check("6 structured header round-trips Kind, actual reader and body together",
              parsedHeader.header?.kind == .typewritten
              && parsedHeader.header?.provenance?.provider == "Gemini"
              && parsedHeader.header?.provenance?.model == flash.displayName
              && parsedHeader.body == r.text)
        check("6 the reclassify copy keeps the record",
              r.with(classification: .documentContinuation, rotationDegrees: 90).pageReader == r.pageReader)

        await script.reset()
        r = await ocr(other, live)
        calls = await script.calls()
        check("6 a page not in the plan is read by the run's model and records nothing",
              r.text?.contains("CLAUDE-TEXT") == true && calls == calls.filter { $0.contains("anthropic") }
              && r.pageReader == nil)

        var kept = PageReaderPlan()
        kept.pages[PageReaderPlan.key(image)] = .init(kind: PageKind(kind: .printed, confidence: 0.5),
                                                      choice: .init(provider: .anthropic, modelID: claude.id, reason: .uncertain))
        var own = PageReaderPlan()
        own.pages[PageReaderPlan.key(image)] = .init(kind: kindA, choice: .init(provider: .anthropic, modelID: claude.id, reason: .override))
        await script.reset()
        r = await ocr(image, own)
        check("6 a page the user set to the run's own model is not counted as rerouted",
              r.pageReader?.reason == .same && r.pageReader?.isRouted == false && r.text?.contains("CLAUDE-TEXT") == true)
        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: claude, outputURL: pdfURL)
        check("6 a known kind is written even when the reader is the run's own model",
              PDFHeaderParser.extract(pdfURL)?.textPages.first?.header?.kind == .typewritten)
        await script.reset()
        r = await ocr(image, kept)
        check("6 an uncertain page is read by the run's model and records why",
              r.text?.contains("CLAUDE-TEXT") == true && r.pageReader?.reason == .uncertain
              && r.pageReader?.model == claude.displayName && r.pageReader?.estimatedCost == nil)

        let mistral = LLMModel.mistralModels[0]
        var noKey = PageReaderPlan()
        noKey.pages[PageReaderPlan.key(image)] = .init(kind: kindA, choice: .init(provider: .mistral, modelID: mistral.id, reason: .override))
        await script.reset()
        r = await ocr(image, noKey)
        calls = await script.calls()
        check("6 a chosen reader with no key now keeps the run's model (no_pick), never a keyless call",
              r.text?.contains("CLAUDE-TEXT") == true && r.pageReader?.reason == .noPick
              && !calls.contains { $0.contains("mistral") })

        let gateway = GatewayConfig(baseURL: "https://kind-gateway.invalid/v1", modelID: "gw", displayName: "GW",
                                    inputCostPer1M: nil, outputCostPer1M: nil)
        await script.reset()
        _ = await ocr(image, live, gateway: gateway)
        calls = await script.calls()
        check("6 the gateway is the user's single route: the plan is not applied",
              !calls.contains { $0.contains("generativelanguage") })

        var toQwen = PageReaderPlan()
        toQwen.pages[PageReaderPlan.key(image)] = .init(kind: PageKind(kind: .forms, confidence: 0.9),
                                                        choice: .init(provider: .openrouter, modelID: qwen.id, reason: .kind))
        await script.reset()
        r = await ocr(image, toQwen, cascade: OCRCascade(routeID: OCRCascade.routeID(for: claude)))
        calls = await script.calls()
        check("6 with the cascade: a routed page its reader fails is escalated, and both records stand",
              r.text?.contains("CLAUDE-TEXT") == true && calls.first?.contains("openrouter") == true
              && r.secondReader?.firstReader == "OpenRouter · \(qwen.displayName)" && r.pageReader?.reason == .kind
              && r.pageReader?.model == qwen.displayName, "\(calls)")

        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: qwen, outputURL: pdfURL)
        let fallbackHeader = PDFHeaderParser.extract(pdfURL)?.textPages.first?.header
        check("6 fallback provenance wins over routing while the original Kind remains",
              fallbackHeader?.kind == .forms && fallbackHeader?.provenance?.model == claude.displayName)

        // 7. The run history adds the routed pages' price difference and counts them.
        let snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .anthropic, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: claude, visionTextProvider: nil, visionTextModel: nil, batchMode: false, enableTagging: false,
            enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false, mixedReOCR: false,
            sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .off, fileCount: 3)
        let records = [PageReaderRecord(kind: "forms", confidence: 0.9, reason: .kind, provider: "OpenRouter",
                                        model: qwen.displayName, estimatedCost: 0.01, replacedCost: 0.03),
                       PageReaderRecord(kind: "printed", confidence: 0.5, reason: .uncertain, provider: "Anthropic",
                                        model: claude.displayName)]
        let recorded = snapshot.makeRun(succeeded: 3, pageReaders: records)
        check("7 the history counts routed pages and adds their price difference",
              recorded.kindRoutedPages == 1 && abs(recorded.cost - (snapshot.estimatedCost - 0.02)) < 1e-12)
        check("7 a run with no routed page records none", snapshot.makeRun(succeeded: 3).kindRoutedPages == nil)

        // 8. Render guard: the row line and the batch control draw.
        store.update([a, b, c])
        let row = PageKindRowLine(store: store, url: b, guidance: guide, runDefault: runDefault, runModel: claude)
        let want = "Form or table (90%) → \(qwen.displayName)"
        check("8 the row line reads the kind, how sure, and the reader", row.label?.text == want && row.label?.routed == true,
              "\(String(describing: row.label))")
        let uncertain = PageKindRowLine(store: store, url: c, guidance: guide, runDefault: runDefault, runModel: claude)
        check("8 an unsure page's line says so and names the run's model",
              uncertain.label?.text == "Printed (50%), not sure → \(claude.displayName), the run's model"
              && uncertain.label?.routed == false, "\(String(describing: uncertain.label))")
        let rowInk = renderedInk(PageKindRowLine.Label(text: row.label?.text ?? "", routed: true))
        check("8 the row line's label renders (\(rowInk) dark px)", rowInk > 150)
        let batchTitle = PageKindBatchControl(store: store, plan: plan, runDefault: runDefault, runModel: claude).title
        check("8 the batch menu reads by kind", batchTitle == "Page readers: by each page's kind", batchTitle)
        let batchInk = renderedInk(PageKindBatchControl(store: store, plan: plan, runDefault: runDefault, runModel: claude))
        let captionOnly = renderedInk(PageKindBatchControl(store: store, plan: .empty, runDefault: runDefault, runModel: claude))
        check("8 the batch control's caption renders (\(batchInk) dark px, \(captionOnly) without it)",
              batchInk > captionOnly + 300)

        // 9. Parity with the bench, on the bench's own pages (only when the private cache is given).
        if let list = env["OCRPAGEKIND_PARITY_LIST"], let out = env["OCRPAGEKIND_PARITY_OUT"],
           let rows = try? String(contentsOfFile: list, encoding: .utf8) {
            var lines: [String] = []
            for row in rows.split(whereSeparator: \.isNewline) where !row.hasPrefix("#") {
                let f = row.split(separator: "\t").map(String.init)
                guard f.count >= 2 else { continue }
                guard let img = PageKindClassifier.loadImage(URL(fileURLWithPath: f[1])),
                      let s = await PageKindClassifier.measure(img),
                      let h = model.hand.probabilities(s.handFeatures()), let fm = model.form.probabilities(s.formFeatures()),
                      let k = PageKind.decide(hand: h, form: fm, handClasses: model.hand.classes) else {
                    lines.append("\(f[0])\tunread"); continue
                }
                lines.append(([f[0], k.kind.rawValue, String(format: "%.6f", k.confidence)]
                              + (h + [fm[1]]).map { String(format: "%.6f", $0) }).joined(separator: "\t"))
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            check("9 parity pages classified (\(lines.count))", !lines.isEmpty)
        }

        // 10. The one list (W42.int-s3): Finder tags, the newspaper rule, the precedence, routing and the header.
        check("10 the corpus's tags: Handwritten, Clippings, Statistics; case and colour suffix ignored",
              PageKindName.fromFinderTags(["handwritten\n6"]) == .handwritten
              && PageKindName.fromFinderTags(["Clippings"]) == .clippings
              && PageKindName.fromFinderTags(["STATISTICS", "Q2"]) == .forms
              && PageKindName.fromFinderTags(["Regis McKenna", "Q1"]) == nil)
        check("10 a file with several kind tags: Handwritten, then Clippings, then Statistics",
              PageKindName.fromFinderTags(["Statistics", "Clippings", "Handwritten"]) == .handwritten
              && PageKindName.fromFinderTags(["Statistics", "Clippings"]) == .clippings)
        func pageLines(_ n: Int, width: Double, text: String = "word word") -> [PageLine] {
            (0..<n).map { i in PageLine(text: text, box: CGRect(x: 0.1, y: Double(i) / Double(n + 1), width: width,
                                                                 height: 0.002), confidence: 0.9) }
        }
        check("10 a newspaper: 600 lines, or 200 set five columns across (under a fifth of the page)",
              EnginePageKind.isNewspaper(lines: pageLines(600, width: 0.45))
              && EnginePageKind.isNewspaper(lines: pageLines(200, width: 0.18))
              && !EnginePageKind.isNewspaper(lines: pageLines(599, width: 0.45))
              && !EnginePageKind.isNewspaper(lines: pageLines(340, width: 0.209))
              && !EnginePageKind.isNewspaper(lines: pageLines(199, width: 0.1)))
        check("10 a line of under four characters is not counted",
              !EnginePageKind.isNewspaper(lines: pageLines(700, width: 0.1, text: "a b"))
              && EnginePageKind.shape(of: pageLines(10, width: 0.3, text: "abcd")).lines == 10)
        let typed = PageKind(kind: .typewritten, confidence: 0.6)
        check("10 a Finder tag corrects the classifier and the newspaper rule",
              PageKind.detect(classified: typed, newspaper: true, tags: ["Clippings"], photographed: true)
              == PageKind(kind: .clippings, confidence: 1, source: .finderTag, photographed: true))
        check("10 the newspaper call wins over the classifier's print call",
              PageKind.detect(classified: typed, newspaper: true, tags: [], photographed: false)
              == PageKind(kind: .newspapers, confidence: 1, source: .layout))
        check("10 otherwise the classifier's call stands, photographed carried as a second axis",
              PageKind.detect(classified: typed, newspaper: false, tags: ["Q2"], photographed: true)
              == PageKind(kind: .typewritten, confidence: 0.6, source: .classifier, photographed: true))
        check("10 no classifier call (weights failed, older macOS): no kind, whatever the tags say",
              PageKind.detect(classified: nil, newspaper: true, tags: ["Handwritten"], photographed: false) == nil)
        check("10 only a page called printed is read for the newspaper call",
              PageKind.readsForNewspaper(PageKind(kind: .printed, confidence: 0.5))
              && !PageKind.readsForNewspaper(typed) && !PageKind.readsForNewspaper(PageKind(kind: .forms, confidence: 0.9))
              && !PageKind.readsForNewspaper(nil))
        check("10 routing: newspapers and clippings take print's pick, a register the form's, mixed the hand's",
              choose(.newspapers) == choose(.printed) && choose(.clippings) == choose(.printed)
              && choose(.registers) == choose(.forms) && choose(.mixed) == choose(.handwritten))
        check("10 'Read handwriting on typed pages' acts on a newspaper and a clipping too (they are print)",
              choose(.newspapers, hand: true).reason == .handwriting && choose(.clippings, hand: true).reason == .handwriting
              && choose(.registers, hand: true).reason == .kind)
        check("10 the header's Kind keeps the four ranked kinds; mixed and registers leave it absent",
              PageKindName.allCases.map(\.headerKind) == [.handwritten, .typewritten, .printed, .forms,
                                                          .printed, .printed, nil, nil])
        check("10 a Finder tag passes the confidence gate: an unsure printed page tagged Statistics takes the form pick",
              PageKind.detect(classified: PageKind(kind: .printed, confidence: 0.5), newspaper: false,
                              tags: ["Statistics"], photographed: false).map { choose($0.kind, $0.confidence) }
              == choose(.forms))
        check("10 a run record from before the source and photographed fields still decodes",
              (try? JSONDecoder().decode(PageKind.self, from: Data(#"{"kind":"printed","confidence":0.9}"#.utf8)))
              == PageKind(kind: .printed, confidence: 0.9))
        check("10 the interview's measured and asked kinds are the list's, and cover it once each",
              CollectionInterviewAnswers.measuredKinds == ["typewritten", "printed", "handwritten", "forms"]
              && CollectionInterviewAnswers.unmeasuredKinds == ["clippings", "newspapers", "registers", "mixed"]
              && Set(PageKindName.classifierKinds + PageKindName.askedKinds) == Set(PageKindName.allCases)
              && PageKindName.allCases.allSatisfy { PageKindName.classifierKinds.contains($0.mixKind) })
        check("10 a sample's newspaper page counts as print in the measured mix",
              KindMeasurement.tally([PageKind(kind: .newspapers, confidence: 1, source: .layout)]).counts == ["printed": 1])
        check("10 the file list says where a kind came from",
              PageKind(kind: .newspapers, confidence: 1, source: .layout, photographed: true).summary
              == "Whole newspaper page (by its columns), photographed"
              && PageKind(kind: .handwritten, confidence: 1, source: .finderTag).summary == "Handwritten (Finder tag)")

        // 11. The measure (W42.int-s3): with OCRPAGEKIND_KINDS_LIST (rows `id <TAB> file <TAB> page [<TAB> tags]`),
        // classify each page as the app does (an image file with its camera and Finder tags; a PDF page as the run
        // renders it) and write `id call source confidence classifier lines wideW photographed untagged seconds` rows to
        // OCRPAGEKIND_KINDS_OUT, which `scripts/segbench/page_kinds.py` scores against the truth. A tags column
        // ("; "-separated, the truth set's record of the original's tags) stands in for the xattr a cached copy lacks;
        // `untagged` is the call with no tags at all. Every page gets the engine's newspaper reading here, for its
        // shape and its seconds; the call reads it only where the app would (`readsForNewspaper`).
        if let list = env["OCRPAGEKIND_KINDS_LIST"], let out = env["OCRPAGEKIND_KINDS_OUT"],
           let rows = try? String(contentsOfFile: list, encoding: .utf8) {
            var outRows: [String] = []
            for row in rows.split(whereSeparator: \.isNewline) where !row.hasPrefix("#") {
                let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 3, let pageNumber = Int(f[2]) else { continue }
                let url = URL(fileURLWithPath: f[1])
                var image: CGImage?, properties: [CFString: Any]?, tags: [String] = []
                if PageKindStore.isPDF(url) {
                    image = PDFDocument(url: url)?.page(at: pageNumber - 1).flatMap(PDFToImageConverter.renderPageImage)
                } else {
                    image = PageKindClassifier.loadImage(url)
                    properties = CGImageSourceCreateWithURL(url as CFURL, nil)
                        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                    tags = (try? MacOSTagger.readTags(from: url)) ?? []
                }
                if f.count >= 4, !f[3].isEmpty { tags = f[3].components(separatedBy: "; ") }
                guard let image, let s = await PageKindClassifier.measure(image) else {
                    outRows.append("\(f[0])\tunread"); continue
                }
                var call: PageKind?
                if s.print.count == model.printLength, let h = model.hand.probabilities(s.handFeatures()),
                   let fm = model.form.probabilities(s.formFeatures()) {
                    call = PageKind.decide(hand: h, form: fm, handClasses: model.hand.classes)
                }
                let photo = EnginePageKind.isPhotograph(image, properties: properties)
                let started = Date()
                // Off the main actor, as the app calls it (`PageKindClassifier.classify` is nonisolated): run on the
                // main thread, the engine's banded Vision reading stalled inside Vision here.
                let read = await Task.detached(priority: .utility) { EnginePageKind.readNewspaper(image) }.value
                let seconds = Date().timeIntervalSince(started)
                let news = PageKind.readsForNewspaper(call) && read?.isNewspaper == true
                let k = PageKind.detect(classified: call, newspaper: news, tags: tags, photographed: photo)
                let bare = PageKind.detect(classified: call, newspaper: news, tags: [], photographed: photo)
                outRows.append([f[0], k?.kind.rawValue ?? "unknown", k?.source.rawValue ?? "-",
                                String(format: "%.4f", k?.confidence ?? 0), call?.kind.rawValue ?? "unknown",
                                "\(read?.lines ?? -1)", String(format: "%.3f", read?.wideWidth ?? -1), photo ? "1" : "0",
                                bare?.kind.rawValue ?? "unknown", String(format: "%.2f", seconds),
                                read?.isNewspaper == true ? "1" : "0"]
                    .joined(separator: "\t"))
            }
            try? (outRows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            check("11 kind pages measured (\(outRows.count))", !outRows.isEmpty)
        }

        finish(results)
    }

    private static func renderedInk(_ view: some View) -> Int {
        let content = view.frame(width: 420, alignment: .leading).padding(8).background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return 0 }
        if let dir = ProcessInfo.processInfo.environment["OCRPAGEKIND_RENDER_DIR"],
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("page-kind-\(UUID().uuidString.prefix(4)).png"))
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var ink = 0
        for i in stride(from: 0, to: px.count, by: 4) where (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3 < 160 {
            ink += 1
        }
        return ink
    }

    private static func makeJPEG(at url: URL) -> URL? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let data = bitmap?.representation(using: .jpeg, properties: [:]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["OCRPAGEKIND_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-ocr-page-kind.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}

#endif
