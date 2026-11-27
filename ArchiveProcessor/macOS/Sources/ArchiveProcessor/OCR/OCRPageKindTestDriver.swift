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

        // 3. Routing from the kind: the two-way split (owner, 2026-11-24, W49.proc-pipeline-prune-ok 2). A handwritten page
        // goes to the guide's handwritten pick; every other kind keeps the run's model.
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
                    run: PageKindRouting.Candidate = runDefault, override: PageKindRouting.Candidate? = nil)
            -> PageKindRouting.Choice {
            PageKindRouting.choose(kind: kind.map { PageKind(kind: $0, confidence: conf) }, guidance: guide,
                                   available: available, runDefault: run, override: override)
        }
        check("3 a sure handwritten page goes to the guide's first handwritten pick, Gemini 3.8 Flash",
              choose(.handwritten) == .init(provider: .gemini, modelID: flash.id, reason: .kind))
        check("3 a mixed page takes the handwritten pick too", choose(.mixed).modelID == flash.id)
        let typedKinds: [PageKindName] = [.typewritten, .printed, .forms, .newspapers, .clippings, .registers]
        check("3 typed, printed, form, newspaper, clipping and register pages keep the run's model",
              typedKinds.allSatisfy { choose($0) == .init(provider: .anthropic, modelID: claude.id, reason: .same) })
        check("3 a handwritten pick with no key is passed over; none runnable keeps the run's model (no_pick)",
              choose(.handwritten, available: [cand(claude)]) == .init(provider: .anthropic, modelID: claude.id, reason: .noPick))
        check("3 the guide's pick being the run's model reads as same",
              choose(.handwritten, run: cand(flash)).reason == .same)
        check("3 a page under \(PageKindRouting.minimumConfidence) keeps the run's model (uncertain)",
              choose(.handwritten, 0.79) == .init(provider: .anthropic, modelID: claude.id, reason: .uncertain)
              && choose(.handwritten, PageKindRouting.minimumConfidence).reason == .kind)
        check("3 a page with no kind keeps the run's model (unknown)", choose(nil).reason == .unknown)
        check("3 the user's choice wins over the kind, and over uncertainty",
              choose(.typewritten, 0.3, override: cand(qwen)) == .init(provider: .openrouter, modelID: qwen.id, reason: .override))
        check("3 the former switch's reason still reroutes, so an older run's record reads",
              PageKindRouting.Reason.handwriting.routes && !PageKindRouting.Reason.same.routes)
        check("3 keyed candidates: every built-in model of a keyed provider, none of an unkeyed one",
              PageKindRouting.keyedCandidates(hasKey: { $0 == .gemini })
              == Set(LLMModel.geminiModels.map(cand)))

        // 4. The file list's plan: per-page and per-batch choices; a PDF and a page not yet told are left out.
        let a = root.appendingPathComponent("a.jpg"), b = root.appendingPathComponent("b.jpg")
        let c = root.appendingPathComponent("c.jpg"), pdf = root.appendingPathComponent("d.pdf")
        let told: [String: PageKind] = [PageReaderPlan.key(a): PageKind(kind: .typewritten, confidence: 0.97),
                                        PageReaderPlan.key(b): PageKind(kind: .handwritten, confidence: 0.9),
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
              plan.entry(for: a)?.choice.reason == .same && plan.entry(for: b)?.choice.modelID == flash.id
              && plan.entry(for: c)?.choice.reason == .uncertain && plan.entry(for: a)?.kind?.confidence == 0.97)
        store.overrides[PageReaderPlan.key(a)] = .run
        plan = store.plan([a, b, c], guidance: guide, runDefault: runDefault)
        check("4 a per-page choice of the run's model keeps that page on it",
              plan.entry(for: a)?.choice == .init(provider: .anthropic, modelID: claude.id, reason: .override))
        plan = store.plan([a], guidance: guide, runDefault: cand(qwen))   // a keeps its own choice of the run's model
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
        store.overrides[PageReaderPlan.key(a)] = .run
        if let data = try? JSONEncoder().encode(plan), let back = try? JSONDecoder().decode(PageReaderPlan.self, from: data) {
            check("4 the plan round-trips through the run record's Codable", back == plan)
        } else { check("4 the plan round-trips through the run record's Codable", false) }

        // 5. The estimate follows the per-page choice.
        let pClaude = CostEstimator.secondReaderPageCost(model: claude, imageScale: 1)
        let pFlash = CostEstimator.secondReaderPageCost(model: flash, imageScale: 1)
        let pQwen = CostEstimator.secondReaderPageCost(model: qwen, imageScale: 1)
        plan = store.plan([a, b, c], guidance: guide, runDefault: runDefault)   // a: Claude (own), b: Flash, c: Claude
        let delta = plan.ocrCostDelta(runModel: claude, imageScale: 1)
        check("5 the plan adds each routed page's price less the run model's", pQwen > 0 && pClaude > 0 && pFlash > 0
              && abs(delta - (pFlash - pClaude)) < 1e-12, "delta \(delta) want \(pFlash - pClaude)")
        let est = CostEstimator.estimate(fileCount: 3, model: claude, enableTagging: false, sendPreviousImage: false,
                                         contextCharCount: 0, imageScale: 1)
        let adjusted = est.addingOCR(delta)
        check("5 the shown estimate moves by exactly that; the batch rate does not",
              abs(adjusted.totalStandard - (est.totalStandard + delta)) < 1e-12 && adjusted.batchOcrCost == est.batchOcrCost)
        check("5 the caption counts pages by reader", plan.routedCounts(runModel: claude).map { "\($0.0.id) \($0.1)" }
              == ["\(flash.id) 1"])
        check("5 an empty plan adds nothing", PageReaderPlan.empty.ocrCostDelta(runModel: claude, imageScale: 1) == 0)

        // 6. The real performOCRCall: a planned page reaches its chosen provider and records it.
        guard let image = makeJPEG(at: root.appendingPathComponent("page.jpg")),
              let other = makeJPEG(at: root.appendingPathComponent("other.jpg")) else {
            finish(results + ["FAIL: fixture JPEG could not be created"])
            return
        }
        // W49.proc-vision-page-cache: the pre-run classification and the newspaper reader's classify the same unchanged
        // file; the second is answered by the first's Vision passes, with the same call.
        let firstCall = await PageKindClassifier.classify(url: image)
        let afterFirst = PageVisionCache.shared.statistics
        let secondCall = await PageKindClassifier.classify(url: image)
        let afterSecond = PageVisionCache.shared.statistics
        check("6 classifying the same file again gives the same call", firstCall == secondCall,
              "\(String(describing: firstCall)) vs \(String(describing: secondCall))")
        check("6 and runs no Vision pass of its own", afterSecond.computed == afterFirst.computed
              && afterSecond.reused > afterFirst.reused, "\(afterFirst) then \(afterSecond)")
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
        let want = "\(PageKind(kind: .handwritten, confidence: 0.9).summary) → \(flash.displayName)"
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
        check("10 a clipping keeps its layout identity with other tags; otherwise Handwritten wins over Statistics",
              PageKindName.fromFinderTags(["Statistics", "Clippings", "Handwritten"]) == .clippings
              && PageKindName.fromFinderTags(["Statistics", "Handwritten"]) == .handwritten
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
        check("10 a Clippings tag keeps the kind, classifier hand and confidence even beside a newspaper call",
              PageKind.detect(classified: typed, newspaper: true, tags: ["Clippings"], photographed: true)
              == PageKind(kind: .clippings, confidence: 0.6, source: .finderTag, photographed: true,
                          readingKind: .typewritten))
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
        check("10 routing: newspapers and clippings read as print, a register as a form, mixed as the hand",
              choose(.newspapers) == choose(.printed) && choose(.clippings) == choose(.printed)
              && choose(.registers) == choose(.forms) && choose(.mixed) == choose(.handwritten))
        check("10 the header's Kind keeps the four ranked kinds; mixed and registers leave it absent",
              PageKindName.allCases.map(\.headerKind) == [.handwritten, .typewritten, .printed, .forms,
                                                          .printed, .printed, nil, nil])
        func route(_ k: PageKind?, override: PageKindRouting.Candidate? = nil) -> PageKindRouting.Choice {
            PageKindRouting.choose(kind: k, guidance: guide, available: all, runDefault: runDefault, override: override)
        }
        for tag in ["Statistics", "Handwritten"] {
            for confidence in [0.79, 0.8, 0.95] {
                let classified = PageKind(kind: .printed, confidence: confidence)
                let tagged = PageKind.detect(classified: classified, newspaper: false, tags: [tag], photographed: false)
                let expected: PageKindName = tag == "Statistics" ? .forms : .handwritten
                check("10 \(tag) at \(confidence): changes only an unsure kind and never lifts its confidence",
                      tagged?.kind == (confidence < 0.8 ? expected : .printed)
                      && tagged?.source == (confidence < 0.8 ? .finderTag : .classifier)
                      && tagged?.confidence == confidence
                      && route(tagged) == (confidence < 0.8 ? choose(.printed, confidence) : choose(.printed)))
            }
            check("10 a sure newspaper call is unchanged by \(tag)",
                  PageKind.detect(classified: PageKind(kind: .printed, confidence: 0.9), newspaper: true,
                                  tags: [tag], photographed: false)
                  == PageKind(kind: .newspapers, confidence: 1, source: .layout))
        }
        // Distinct picks: only the handwritten kind's is used (the two-way split); every other hand keeps the run's model.
        let distinctModels = [flash, claude, LLMModel.mistralModels[0], qwen]
        let distinctGuide = OCRPageGuidance(measured: "fixture", footnote: "", kinds:
            zip(PageKindName.classifierKinds, distinctModels).map { kind, model in
                .init(id: kind.rawValue, label: kind.label, pages: 1, picks: [
                    .init(name: model.displayName, nes: 100, appModel: model.id,
                          source: .init(file: "fixture", route: "fixture", attribute: "kind", value: kind.rawValue))
                ], note: nil)
            })
        let distinctAvailable = Set(distinctModels.map(cand))
        for (hand, expected) in zip(PageKindName.classifierKinds, distinctModels) {
            let clipping = PageKind.detect(classified: PageKind(kind: hand, confidence: 0.9), newspaper: false,
                                           tags: ["Clippings"], photographed: false)
            let pick = PageKindRouting.choose(kind: clipping, guidance: distinctGuide, available: distinctAvailable,
                                              runDefault: runDefault)
            let want = hand == .handwritten ? cand(expected) : runDefault
            check("10 clipping \(hand.rawValue) reaches \(hand == .handwritten ? "its distinct fixture reader" : "the run's model")",
                  pick.provider == want.provider && pick.modelID == want.modelID)
        }
        // Scratch JPEG -> real OCR seam -> Codable record -> generated two-page PDF. The semantic kind stays
        // clippings for layout and sidecars; every classifier hand keeps its own reader and four-kind header.
        await script.set(["anthropic": (200, claudeText), "generativelanguage": (200, geminiText),
                          "openrouter": (200, #"{"choices":[{"finish_reason":"stop","message":{"content":"[document_start]\nFORM-TEXT"}}]}"#)])
        for hand in PageKindName.classifierKinds {
            let classified = PageKind(kind: hand, confidence: 0.95)
            let clipping = PageKind.detect(classified: classified, newspaper: false,
                                           tags: ["Statistics", "HANDWRITTEN", "Clippings\n6"], photographed: true)
            let choice = route(clipping)
            check("10 a tagged clipping classified \(hand.rawValue) takes that reader and header",
                  clipping?.kind == .clippings && clipping?.routingKind == hand
                  && clipping?.headerKind == hand.headerKind && choice == route(classified))
            var plan = PageReaderPlan()
            plan.pages[PageReaderPlan.key(image)] = .init(kind: clipping, choice: choice)
            let planBack = (try? JSONEncoder().encode(plan)).flatMap { try? JSONDecoder().decode(PageReaderPlan.self, from: $0) }
            check("10 clipping \(hand.rawValue) survives the frozen plan", planBack == plan)
            let result = await ocr(image, planBack ?? .empty)
            let back = (try? JSONEncoder().encode(result)).flatMap { try? JSONDecoder().decode(OCRResult.self, from: $0) }
            check("10 clipping \(hand.rawValue) records its layout kind and classifier hand through Codable",
                  result.errorMessage == nil && result.text?.isEmpty == false && back?.pageReader == result.pageReader && result.pageReader?.kind == "clippings"
                  && result.pageReader?.readingKind == hand
                  && result.pageReader?.model == PageKindRouting.model(.init(provider: choice.provider, modelID: choice.modelID))?.displayName
                  && TextLayerRule.kind(explicit: nil, result: result) == .clippings)
            let pdf = root.appendingPathComponent("clipping-\(hand.rawValue).pdf")
            _ = try? PDFGenerator().generate(imageURL: image, result: back ?? result, model: claude, outputURL: pdf)
            check("10 clipping \(hand.rawValue) writes its classifier's Kind to a scratch PDF",
                  PDFHeaderParser.extract(pdf)?.textPages.first?.header?.kind == hand.headerKind)
        }
        let handwrittenClipping = OCRResult(text: "fixture", classification: nil, errorMessage: nil, errorCode: nil,
            pageReader: PageReaderRecord(kind: "clippings", confidence: 0.95, reason: .same,
                                         provider: LLMProvider.appleVision.rawValue, model: "fixture", readingKind: .handwritten))
        let entityInput = EntityRunPolicy.inputs(results: [handwrittenClipping], runProvider: nil, settings: [:],
            provider: .appleVision, model: claude, gateway: nil, localAgent: nil)
        check("10 entity safety keeps a clipping's classified handwriting on Vision text",
              entityInput.pageKinds == [.handwritten] && entityInput.textSource == .vision)
        let unsureClipping = PageKind.detect(classified: typed, newspaper: false, tags: ["Clippings"], photographed: false)
        check("10 an unsure clipping keeps the run's model, but an explicit reader still wins",
              route(unsureClipping).reason == .uncertain
              && route(unsureClipping, override: cand(flash)).reason == .override)
        var unsurePlan = PageReaderPlan()
        unsurePlan.pages[PageReaderPlan.key(image)] = .init(kind: unsureClipping, choice: route(unsureClipping))
        let unsureResult = await ocr(image, unsurePlan)
        check("10 an unsure clipping is read by the run's model and retains its classifier hand",
              unsureResult.pageReader?.reason == .uncertain && unsureResult.pageReader?.readingKind == .typewritten
              && unsureResult.text?.contains("CLAUDE-TEXT") == true)
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
        // renders it) and write `id call source confidence classifier lines wideW photographed untagged seconds
        // engine_newspaper routing untagged_routing header classifier_confidence` rows to
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
                                String(format: "%.12g", k?.confidence ?? 0), call?.kind.rawValue ?? "unknown",
                                "\(read?.lines ?? -1)", String(format: "%.3f", read?.wideWidth ?? -1), photo ? "1" : "0",
                                bare?.kind.rawValue ?? "unknown", String(format: "%.2f", seconds),
                                read?.isNewspaper == true ? "1" : "0", k?.routingKind.rawValue ?? "unknown",
                                bare?.routingKind.rawValue ?? "unknown", k?.headerKind?.rawValue ?? "unknown",
                                String(format: "%.6f", call?.confidence ?? 0)]
                    .joined(separator: "\t"))
            }
            try? (outRows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            check("11 kind pages measured (\(outRows.count))", !outRows.isEmpty)
        }

        // 12. The mixed-page pre-flag (W47.wh-mixed-preflag) stays in VisionOCRKit for 2.0 (W46.kinds-mixed-truth): its
        // switch is gone from the app (owner, 2026-11-24), so only its resize and bench parity are checked here.
        let ramp = (0..<(40 * 30)).map { UInt8(($0 % 40) * 6) }
        let flat = [UInt8](repeating: 77, count: 500 * 300)
        check("12 Pillow's bicubic: same size is the input, a flat page stays flat when squeezed, a ramp stays in range",
              MixedPagePreflag.bicubicResize(ramp, width: 40, height: 30, to: 40, 30) == ramp
              && MixedPagePreflag.bicubicResize(flat, width: 500, height: 300, to: 384, 384).allSatisfy { $0 == 77 }
              && MixedPagePreflag.bicubicResize(ramp, width: 40, height: 30, to: 384, 384).count == 384 * 384)
        // Pillow 13.0.0's own output (Image.BICUBIC, computed in the shared torch env) for a 6 x 4 ramp squeezed to
        // 3 x 2 and a 13 x 11 scramble, value (i * 37 + 11) % 256, squeezed to 5 x 4.
        let tiny: [UInt8] = [0, 40, 80, 120, 160, 200, 10, 50, 90, 130, 170, 210, 20, 60, 100, 140, 180, 220,
                             30, 70, 110, 150, 190, 230]
        let scramble = (0..<(13 * 11)).map { UInt8(($0 * 37 + 11) % 256) }
        let scrambled: [UInt8] = [105, 103, 179, 91, 131, 189, 111, 117, 173, 64, 101, 168, 83, 129, 158, 110, 114,
                                  185, 95, 144]
        check("12 Pillow's bicubic matches Pillow on two fixed cases",
              MixedPagePreflag.bicubicResize(tiny, width: 6, height: 4, to: 3, 2) == [28, 106, 184, 46, 124, 202]
              && MixedPagePreflag.bicubicResize(scramble, width: 13, height: 11, to: 5, 4) == scrambled,
              "\(MixedPagePreflag.bicubicResize(tiny, width: 6, height: 4, to: 3, 2)) "
              + "\(MixedPagePreflag.bicubicResize(scramble, width: 13, height: 11, to: 5, 4))")
        // And a page-sized squeeze, 26 to 1: a 260 x 390 scramble, value (i * 53 + 7) % 256, to 10 x 15.
        let wide = (0..<(390 * 260)).map { UInt8(($0 * 53 + 7) % 256) }
        let squeezed: [UInt8] = [
                                       126, 125, 126, 127, 128, 129, 130, 129, 129, 127, 127, 129, 129, 129, 129, 127, 126, 126, 126, 127,
                                       129, 127, 126, 126, 126, 127, 128, 129, 129, 129, 126, 126, 128, 129, 130, 129, 129, 127, 126, 126,
                                       129, 129, 129, 127, 126, 126, 126, 127, 128, 129, 126, 126, 126, 127, 128, 129, 130, 129, 128, 127,
                                       128, 129, 130, 129, 128, 127, 126, 125, 126, 127, 128, 127, 126, 125, 126, 127, 128, 129, 130, 129,
                                       126, 127, 128, 129, 130, 129, 128, 127, 126, 126, 129, 129, 128, 127, 126, 125, 126, 127, 128, 129,
                                       126, 126, 126, 127, 128, 129, 130, 129, 128, 127, 128, 129, 130, 129, 128, 127, 126, 126, 126, 127,
                                       128, 127, 126, 126, 126, 127, 128, 129, 130, 129, 126, 127, 128, 129, 129, 129, 128, 126, 126, 126,
                                       130, 129, 128, 127, 126, 125, 126, 127, 128, 129]
        check("12 Pillow's bicubic matches Pillow at a page's 26 to 1",
              MixedPagePreflag.bicubicResize(wide, width: 260, height: 390, to: 10, 15) == squeezed)
        let bare = ["VISIONOCR_MODEL_HOME": root.appendingPathComponent("no models").path]
        check("12 without the download the pre-flag is not installed and offers its whole size",
              !MixedPagePreflag.isInstalled(bare) && MixedPagePreflag.downloadMB(environment: bare) == 300
              && MixedPagePreflag.licence.contains("CC BY-NC 4.0"))

        // 12b. Parity with the bench (only when the script gives the pages and a model source): the app's own installer
        // fetches the pinned download into a scratch home, then ATRIUM reads each page.
        if let list = env["MIXED_PREFLAG_LIST"], let out = env["MIXED_PREFLAG_OUT"],
           let rows = try? String(contentsOfFile: list, encoding: .utf8) {
            var e = env
            if let home = env["MIXED_PREFLAG_HOME"] { e["VISIONOCR_MODEL_HOME"] = home }
            do {
                try await MixedPagePreflag.download(environment: e)
                check("12b the download installs through the app's installer", MixedPagePreflag.isInstalled(e))
                var lines: [String] = []
                for row in rows.split(whereSeparator: \.isNewline) where !row.hasPrefix("#") {
                    let f = row.split(separator: "\t").map(String.init)
                    guard f.count >= 2 else { continue }
                    let t0 = Date()
                    guard let reading = try? MixedPagePreflag.read(url: URL(fileURLWithPath: f[1]), environment: e) else {
                        lines.append("\(f[0])\tunread"); continue
                    }
                    lines.append(([f[0], reading.top, String(format: "%.4f", Date().timeIntervalSince(t0))]
                                  + reading.probabilities.map { String(format: "%.6f", $0) }).joined(separator: "\t"))
                }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
                check("12b parity pages read (\(lines.count))", !lines.isEmpty)
            } catch { check("12b the download installs through the app's installer: \(error)", false) }
        }

        // 13. The free split on the Mac (W49.proc-kind-split-mac): on Apple Vision a sure handwritten page goes to the
        // downloaded model that reads handwriting best, every other page stays on Vision, and no page leaves the Mac.
        let visionModel = LLMModel.appleVisionModels[0]
        let vision = cand(visionModel)
        let q9 = PageKindRouting.Candidate(provider: .appleVision, modelID: ManagedOCRModel.qwen35_9B.rawValue)
        let q8 = PageKindRouting.Candidate(provider: .appleVision, modelID: ManagedOCRModel.qwen3VL8B.rawValue)
        check("13 a sure handwritten page goes to the downloaded model with the best measured handwriting (Qwen3-VL 8B, 89.24 over 88.06)",
              choose(.handwritten, available: [q9, q8], run: vision) == .init(provider: .appleVision, modelID: q8.modelID, reason: .kind)
              && choose(.handwritten, available: [q9], run: vision).modelID == q9.modelID
              && choose(.mixed, available: [q9, q8], run: vision).modelID == q8.modelID)
        check("13 typed, printed, form, newspaper, clipping and register pages stay on Vision",
              typedKinds.allSatisfy { choose($0, available: [q8], run: vision) == .init(provider: .appleVision, modelID: visionModel.id, reason: .same) })
        check("13 with nothing downloaded a handwritten page stays on Vision (no_pick)",
              choose(.handwritten, available: [], run: vision) == .init(provider: .appleVision, modelID: visionModel.id, reason: .noPick))
        check("13 a free run never picks a cloud model, keyed or not",
              choose(.handwritten, available: all, run: vision).reason == .noPick)
        check("13 an unsure handwritten page stays on Vision", choose(.handwritten, 0.79, available: [q8], run: vision).reason == .uncertain)
        check("13 a cloud run never takes a model on this Mac as the guide's pick",
              choose(.handwritten, available: [q8, cand(claude)], run: runDefault).reason == .noPick)
        check("13 every local pick reads handwriting better than Vision, measured",
              LocalModelRoute.all.allSatisfy { $0.handwrittenNES > LocalModelRoute.visionHandwrittenNES })
        let localGW = GatewayConfig(baseURL: "http://kind-local.invalid/v1", modelID: q8.modelID,
                                    displayName: ManagedOCRModel.qwen3VL8B.pick.displayName,
                                    inputCostPer1M: nil, outputCostPer1M: nil, localModel: true)
        PageKindRouting.managedGatewayOverride = { $0 == .qwen3VL8B ? localGW : nil }
        PageKindStore.localOverride = [q8]
        defer { PageKindRouting.managedGatewayOverride = nil; PageKindStore.localOverride = nil }
        check("13 the candidates are the offered models whose download finished",
              PageKindRouting.localCandidates(offered: ManagedOCRModel.allCases) == [q8]
              && PageKindRouting.localCandidates(offered: []).isEmpty)

        let macStore = PageKindStore()
        macStore.update([a, b, c])
        for _ in 0..<200 where macStore.pending > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let macPlan = macStore.plan([a, b, c], guidance: guide, runDefault: vision)
        check("13 the file list's plan: the handwritten page to the model on this Mac, the typed page on Vision",
              macPlan.entry(for: b)?.choice == .init(provider: .appleVision, modelID: q8.modelID, reason: .kind)
              && macPlan.entry(for: a)?.choice.reason == .same && macPlan.entry(for: c)?.choice.reason == .uncertain)
        check("13 the menus offer the models on this Mac on Vision, and only cloud models on a key",
              macStore.menuCandidates(for: vision).map(\.0) == [q8]
              && !macStore.menuCandidates(for: runDefault).contains { $0.0.provider == .appleVision })
        macStore.overrides[PageReaderPlan.key(a)] = .model(q8)
        macStore.batchOverride = .run
        macStore.clearChoices()
        check("13 switching between Vision and a key clears the choices", macStore.overrides.isEmpty && macStore.batchOverride == nil)
        check("13 the estimate: nothing to pay, the caption names the model on this Mac",
              macPlan.ocrCostDelta(runModel: visionModel, imageScale: 1) == 0
              && macPlan.routedCounts(runModel: visionModel).map { "\($0.0.displayName) \($0.1)" }
                == ["\(ManagedOCRModel.qwen3VL8B.pick.displayName) 1"])
        let plainTime = TimeEstimator.estimate(fileCount: 3, model: visionModel, enableTagging: false, useGateway: true)
        let splitTime = TimeEstimator.estimate(fileCount: 3, model: visionModel, enableTagging: false, useGateway: true,
                                               routedLocalSeconds: macPlan.localSeconds)
        check("13 the time estimate adds the model's measured pace for each page it reads",
              macPlan.localSeconds == ManagedOCRModel.qwen3VL8B.pick.secondsPerPage
              && abs(splitTime.ocrSeconds - plainTime.ocrSeconds - macPlan.localSeconds) < 1e-9
              && PageReaderPlan.empty.localSeconds == 0, "\(plainTime.ocrSeconds) \(splitTime.ocrSeconds)")
        let macRow = PageKindRowLine(store: macStore, url: b, guidance: guide, runDefault: vision, runModel: visionModel)
        check("13 the row line names the model on this Mac",
              macRow.label?.text == "\(PageKind(kind: .handwritten, confidence: 0.9).summary) → \(ManagedOCRModel.qwen3VL8B.pick.displayName)"
              && macRow.label?.routed == true, "\(String(describing: macRow.label))")
        PageKindStore.localOverride = []
        let bareStore = PageKindStore()
        bareStore.update([])
        PageKindStore.localOverride = [q8]
        let withLocal = renderedInk(PageKindBatchControl(store: macStore, plan: .empty, runDefault: vision, runModel: visionModel))
        let noLocal = renderedInk(PageKindBatchControl(store: bareStore, plan: .empty, runDefault: vision, runModel: visionModel))
        check("13 with nothing downloaded the batch control says where to download one (\(noLocal) dark px against \(withLocal))",
              noLocal > withLocal + 300)

        let localText = #"{"choices":[{"finish_reason":"stop","message":{"content":"[document_start]\nLOCAL-TEXT"}}]}"#
        let localCut = #"{"choices":[{"finish_reason":"length","message":{"content":"[document_start]\nloop loop"}}]}"#
        func visionOCR(_ readers: PageReaderPlan) async -> OCRResult {
            await OCRProcessor.performOCRCall(
                imageURL: image, provider: .appleVision, model: visionModel, thinkingLevel: nil, apiKey: "",
                previousText: nil, previousImageURL: nil, rotationMode: .off, standardImageMB: 4, cascade: .off,
                readers: readers)
        }
        func macPlanFor(_ choice: PageKindRouting.Choice, kind: PageKind = PageKind(kind: .handwritten, confidence: 0.9))
            -> PageReaderPlan {
            var p = PageReaderPlan()
            p.pages[PageReaderPlan.key(image)] = .init(kind: kind, choice: choice)
            return p
        }
        let toLocal = macPlanFor(.init(provider: .appleVision, modelID: q8.modelID, reason: .kind))
        await script.set(["kind-local": (200, localText), "anthropic": (200, claudeText), "generativelanguage": (200, geminiText)])
        r = await visionOCR(toLocal)
        calls = await script.calls()
        check("13 Vision run: the handwritten page is read by the model on this Mac, and only by it",
              r.text?.contains("LOCAL-TEXT") == true && calls == ["kind-local.invalid"], "\(calls) \(r.errorMessage ?? "")")
        check("13 its record names the model as a gateway run does, at no cost, and counts as routed",
              r.pageReader == PageReaderRecord(kind: "handwritten", confidence: 0.9, reason: .kind,
                                               provider: localGW.displayName, model: q8.modelID,
                                               estimatedCost: 0, replacedCost: 0) && r.pageReader?.isRouted == true,
              "\(String(describing: r.pageReader))")
        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: visionModel, outputURL: pdfURL)
        let localHeader = PDFHeaderParser.extract(pdfURL)?.textPages.first?.header
        check("13 the PDF header names the model on this Mac and keeps the handwritten Kind",
              localHeader?.kind == .handwritten && localHeader?.provenance?.model == q8.modelID
              && localHeader?.provenance?.provider == localGW.displayName,
              "\(String(describing: localHeader?.provenance))")
        let localRun = RunHistorySnapshot(
            startedAt: Date(), provider: .appleVision, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: visionModel, visionTextProvider: nil, visionTextModel: nil, batchMode: false, enableTagging: false,
            enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false, mixedReOCR: false,
            sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .off, fileCount: 1)
        let localRecorded = localRun.makeRun(succeeded: 1, pageReaders: [r.pageReader].compactMap { $0 })
        check("13 the run history counts the page and adds nothing to the cost",
              localRecorded.kindRoutedPages == 1 && localRecorded.cost == localRun.estimatedCost)

        await script.set(["kind-local": (200, localCut)])
        r = await visionOCR(toLocal)
        calls = await script.calls()
        check("13 a page the model on this Mac fails (a cut reply) is read by Vision, and its record says so",
              !calls.isEmpty && calls.allSatisfy { $0 == "kind-local.invalid" } && r.pageReader?.reason == .localFailed
              && r.pageReader?.provider == LLMProvider.appleVision.rawValue && r.pageReader?.model == visionModel.displayName
              && r.pageReader?.isRouted == false && r.errorMessage?.contains("repeated") != true,
              "\(calls) \(String(describing: r.pageReader)) \(r.errorMessage ?? "")")
        await script.set(["kind-local": (500, "{}")])
        r = await visionOCR(toLocal)
        check("13 and a server error too", r.pageReader?.reason == .localFailed)

        await script.set(["kind-local": (200, localText)])
        r = await visionOCR(macPlanFor(.init(provider: .appleVision, modelID: q9.modelID, reason: .kind)))
        calls = await script.calls()
        check("13 a model whose download is gone keeps the page on Vision (no_pick), with no call",
              calls.isEmpty && r.pageReader?.reason == .noPick)
        await script.reset()
        r = await visionOCR(macPlanFor(.init(provider: .gemini, modelID: flash.id, reason: .override)))
        calls = await script.calls()
        check("13 a cloud choice left over on a Vision run never makes a call",
              calls.isEmpty && r.pageReader?.reason == .noPick)
        await script.reset()
        r = await visionOCR(macPlanFor(.init(provider: .appleVision, modelID: visionModel.id, reason: .same),
                                       kind: PageKind(kind: .typewritten, confidence: 0.97)))
        calls = await script.calls()
        check("13 a typed page on Vision is read by Vision, with no call", calls.isEmpty && r.pageReader?.reason == .same)
        await script.reset()
        _ = await ocr(image, toLocal)
        calls = await script.calls()
        check("13 a cloud run never sends a page to a model on this Mac", !calls.contains("kind-local.invalid")
              && calls.allSatisfy { $0.contains("anthropic") }, "\(calls)")

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
