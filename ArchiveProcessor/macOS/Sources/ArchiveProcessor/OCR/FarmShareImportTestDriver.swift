import AppKit
import Foundation
import PDFKit

/// Key-free, no-network contract for W41.app-farmshare-import. Builds a FarmShare bulk folder in the form
/// `fs_ocr.py bulk` writes it (`<image>.txt`, `_meta/<image>.json` with `sha256`, `model`, `preset`, `vllm_args`,
/// `job`) in a temporary directory, then drives the REAL `OCRProcessor.performOCRCall` through the injected HTTP
/// transport: a matched page takes FarmShare's text and spends only the text-only classification call, an unmatched
/// one is read by the run's model, a page is matched by its bytes and never by a name two boxes share, and the
/// gateway ignores the import. Also the PDF header, the precision label and the resume snapshot. Every file is
/// scratch; nothing outside the temporary directory is read or written.
///
/// Run via `scripts/test-farmshare-import.sh`.
@MainActor
enum FarmShareImportTestDriver {
    nonisolated static let envKey = "FARMSHARE_IMPORT_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private actor Script {
        var answer: (Int, String) = (404, "{}")
        var bodies: [String] = []
        func set(_ answer: (Int, String)) { self.answer = answer; bodies = [] }
        func take(_ request: URLRequest) -> (Int, String) {
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return answer
        }
        func calls() -> [String] { bodies }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APFarmShareImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        var results: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)\(condition || detail.isEmpty ? "" : " — \(detail)")")
        }

        // The run's input images: two boxes that both have a 001.jpg, a page FarmShare escalated, one it never read.
        let input = root.appendingPathComponent("input", isDirectory: true)
        let bulk = root.appendingPathComponent("bulk-out", isDirectory: true)
        guard let box1 = makeJPEG(input.appendingPathComponent("box1/001.jpg"), shade: 0.2),
              let box2 = makeJPEG(input.appendingPathComponent("box2/001.jpg"), shade: 0.6),
              let escalated = makeJPEG(input.appendingPathComponent("box1/002.jpg"), shade: 0.4),
              let unread = makeJPEG(input.appendingPathComponent("box3/009.jpg"), shade: 0.8),
              let renamed = makeJPEG(input.appendingPathComponent("elsewhere/renamed.jpg"), shade: 0.6) else {
            finish(["FAIL: fixture JPEGs could not be created"])
            return
        }
        let sha = { (url: URL) in FarmShareImport.sha256(of: url) ?? "" }
        let args = "--tensor-parallel-size 1 --max-model-len 16384 --kv-cache-dtype fp8 --gpu-memory-utilization 0.92"
        // FarmShare's tree mirrors its own --in, so its names need not be the Mac's: box2's page sits under b/.
        write(bulk, "box1/001.jpg", text: "BOX-ONE text from FarmShare",
              meta: ["kind": "typewritten", "table": false, "sha256": sha(box1), "model": "Qwen/Qwen3.6-27B-FP8",
                     "preset": "qwen3.6-27b", "vllm_args": args, "job": "1849739", "status": "ok"])
        write(bulk, "b/001.jpg", text: "BOX-TWO text from FarmShare",
              meta: ["kind": "handwritten", "table": false, "sha256": sha(box2), "model": "Qwen/Qwen3.6-27B-FP8",
                     "preset": "qwen3.6-27b", "vllm_args": args, "job": "1849740", "status": "ok"])
        // A page from before the kit recorded hashes: matches nothing, even though its name is box3's.
        write(bulk, "box3/009.jpg", text: "OLD text", meta: ["kind": "printed", "table": false, "status": "ok"])
        try? Data(#"{"image": "box1/002.jpg", "reason": "loop", "status": "failed"}"#.utf8 + [10])
            .write(to: bulk.appendingPathComponent("escalate-0.jsonl"))

        // 1. Loading.
        var loaded: FarmShareImport?
        do { loaded = try FarmShareImport.load(folder: bulk) } catch { check("the bulk folder loads", false, "\(error)") }
        check("two pages carry a hash; the one without is counted, not matched",
              loaded?.count == 2 && loaded?.unmatchable == 1, "\(loaded?.count ?? -1) / \(loaded?.unmatchable ?? -1)")
        var notBulk = false
        do { _ = try FarmShareImport.load(folder: input) } catch FarmShareImport.LoadError.notABulkRun { notBulk = true } catch {}
        check("a folder without _meta is refused as not a bulk run", notBulk)
        guard let imported = loaded else { finish(results); return }

        // 2. Matching is by bytes.
        check("box1's page takes box1's text", imported.result(for: box1)?.text == "BOX-ONE text from FarmShare")
        check("box2/001.jpg takes box2's text, not box1's (same name, other bytes)",
              imported.result(for: box2)?.text == "BOX-TWO text from FarmShare")
        check("a copy under another name still matches by its bytes",
              imported.result(for: renamed)?.text == "BOX-TWO text from FarmShare")
        check("an escalated page and an unread one (hashless meta of the same name) match nothing",
              imported.result(for: escalated) == nil && imported.result(for: unread) == nil)
        let reading = imported.result(for: box1)?.imported
        check("the reading records model, preset, precision and job",
              reading == ImportedReading(source: "FarmShare", model: "Qwen/Qwen3.6-27B-FP8", preset: "qwen3.6-27b",
                                         precision: "FP8 weights, fp8 KV cache", job: "1849739", kind: "typewritten"),
              "\(String(describing: reading))")
        check("the dyn preset's precision says vLLM quantised it at load",
              ImportedReading.precision(model: "Qwen/Qwen3.6-27B",
                                        vllmArgs: "--kv-cache-dtype auto --quantization fp8") == "fp8 weights (quantised at load)")
        check("the header's model position never carries the header's separator",
              ImportedReading(source: "FarmShare", model: "a · b", preset: nil, precision: nil, job: nil, kind: nil)
                .headerModel == "a, b")
        check("--flag=value reads like --flag value, and a newline never breaks the header block",
              ImportedReading.precision(model: "Qwen/Qwen3.6-27B", vllmArgs: "--quantization=fp8 --kv-cache-dtype=fp8")
                == "fp8 weights (quantised at load), fp8 KV cache"
              && ImportedReading(source: "FarmShare", model: "m\nx", preset: nil, precision: nil, job: "1\n2",
                                 kind: nil).headerModel == "m x (job 1 2)")
        try? fm.removeItem(at: bulk.appendingPathComponent("box1/001.jpg.txt"))
        check("a text file gone since loading matches nothing (the run's model reads the page)",
              imported.result(for: box1) == nil)
        write(bulk, "box1/001.jpg", text: "BOX-ONE text from FarmShare", meta: nil)
        // A folder replaced since loading: box1's _meta now records another image, so its text is not box1's.
        let box1Meta = bulk.appendingPathComponent("_meta/box1/001.jpg.json")
        let saved = try? Data(contentsOf: box1Meta)
        write(bulk, "box1/001.jpg", text: "SOMEONE ELSE's text",
              meta: ["sha256": String(repeating: "0", count: 64), "model": "m"])
        check("a _meta that no longer records the page's hash gives no match", imported.result(for: box1) == nil)
        write(bulk, "box1/001.jpg", text: "BOX-ONE text from FarmShare", meta: nil)
        try? saved?.write(to: box1Meta)

        // 3. Through performOCRCall, with the HTTP transport faked.
        let script = Script()
        check("the HTTP seam is dormant before the contract installs it", !NetworkSession.testTransportIsActive)
        NetworkSession.testTransport = { request in
            let (status, body) = await script.take(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        OCRRefusalFallback.routesOverride = { [] }
        defer { NetworkSession.testTransport = nil; OCRRefusalFallback.routesOverride = nil }
        guard NetworkSession.testTransportIsActive else {
            check("the injected transport is active", false, "stopping before any request")
            finish(results)
            return
        }
        let flash = LLMModel.geminiModels[0]
        func ocr(_ url: URL, gateway: GatewayConfig? = nil, rotation: RotationMode = .llmSingle) async -> OCRResult {
            await OCRProcessor.performOCRCall(
                imageURL: url, provider: .gemini, model: flash, thinkingLevel: nil, apiKey: "test-key",
                previousText: nil, previousImageURL: nil, gatewayConfig: gateway, rotationMode: rotation,
                standardImageMB: 4, cascade: .off, imported: imported)
        }
        await script.set((200, #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[document_start]\nMODEL-TEXT"}]}}]}"#))
        var r = await ocr(box2)
        var calls = await script.calls()
        check("a matched page keeps FarmShare's text and its reader",
              r.text == "BOX-TWO text from FarmShare" && r.imported?.job == "1849740" && r.errorCode == nil)
        check("a matched page spends one text-only call (its classification), with no image and no rotation call",
              calls.count == 1 && !calls[0].contains("inline_data") && !calls[0].contains("inlineData"),
              "\(calls.count) calls")
        check("its classification comes from the run's model; rotation stays 0",
              r.classification == .documentStart && r.rotationDegrees == 0)
        await script.set((500, #"{"error":{"message":"down"}}"#))
        r = await ocr(box2)
        check("a failed classification call still keeps FarmShare's text, unclassified",
              r.text == "BOX-TWO text from FarmShare" && r.classification == nil && r.errorMessage == nil)
        await script.set((200, #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[document_start]\nMODEL-TEXT"}]}}]}"#))
        r = await ocr(escalated, rotation: .off)
        calls = await script.calls()
        check("an escalated page is read by the run's model, with its image",
              r.text?.contains("MODEL-TEXT") == true && r.imported == nil && calls.count == 1
              && (calls[0].contains("inline_data") || calls[0].contains("inlineData")))
        // A model on this Mac: its key is a placeholder, so the contract never reads the Keychain.
        let gateway = GatewayConfig(baseURL: "http://local-mac.invalid:1234/v1", modelID: "qwen/qwen3-vl-8b",
                                    displayName: "GW", localModel: true)
        await script.set((200, #"{"choices":[{"finish_reason":"stop","message":{"content":"[document_start]\nGATEWAY-TEXT"}}]}"#))
        r = await ocr(box2, gateway: gateway, rotation: .off)
        check("the gateway, the user's single route, ignores the import",
              r.text?.contains("GATEWAY-TEXT") == true && r.imported == nil, r.text ?? r.errorMessage ?? "")

        // 4. The PDF header, and a rebuilt result keeps the reading.
        guard let matched = imported.result(for: box1) else {
            check("box1 matches again once its text is back", false)
            finish(results)
            return
        }
        check("a reclassified result keeps the reading",
              matched.with(classification: .documentContinuation, rotationDegrees: 0).imported == matched.imported)
        let pdf = root.appendingPathComponent("out/001.pdf")
        try? fm.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? PDFGenerator().generate(imageURL: box1, result: matched, model: flash, outputURL: pdf,
                                         originalFileName: "001.jpg")
        let page2 = PDFDocument(url: pdf)?.page(at: 1)?.string ?? ""
        check("the PDF header names FarmShare, its model, precision and job in the provider/model positions",
              page2.contains("FarmShare \u{00B7} Qwen3.6-27B-FP8 (FP8 weights, fp8 KV cache, job 1849739) \u{00B7} ")
              && page2.contains("BOX-ONE text from FarmShare"), String(page2.prefix(200)))
        if let data = try? JSONEncoder().encode(matched),
           let back = try? JSONDecoder().decode(OCRResult.self, from: data) {
            check("a persisted result keeps the reading", back.imported == matched.imported)
        } else {
            check("a persisted result keeps the reading", false)
        }
        let legacy = try? JSONDecoder().decode(OCRResult.self, from: Data(
            #"{"text":"t","rotationDegrees":0}"#.utf8))
        check("a result written without the field decodes as read in the run", legacy != nil && legacy?.imported == nil)

        // 5. The resume snapshot.
        let processor = OCRProcessor()
        let suite = "APFarmShareImport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = SessionProcessingConfig.fromProcessFilesRunStart(defaults)
        config.farmShareImport = imported
        let runtime = processor.makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil, runConfig: config)
        let back = (try? JSONEncoder().encode(runtime)).flatMap {
            try? JSONDecoder().decode(OCRProcessor.PendingRunRuntimeConfig.self, from: $0) }
        check("the run snapshot records the folder", back?.farmShareFolder == bulk.path)
        check("a resumed run reloads the folder",
              back?.farmShareFolder.flatMap { OCRProcessor.reloadFarmShareImport($0) }?.count == 2)
        check("a folder gone since gives no import (its pages go to the run's model)",
              OCRProcessor.reloadFarmShareImport(root.appendingPathComponent("gone").path) == nil)
        check("a run without an import records none and its call values carry none",
              processor.makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil).farmShareFolder == nil
              && OCRProcessor.ocrCallValues(for: nil).imported == nil
              && OCRProcessor.ocrCallValues(for: config).imported?.count == 2)

        check("nothing was written into the input folder",
              (fm.enumerator(atPath: input.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jpg") }.count == 5
              && (fm.enumerator(atPath: input.path)?.allObjects as? [String] ?? []).allSatisfy {
                  $0.hasSuffix(".jpg") || !$0.contains(".") })
        finish(results)
    }

    private static func write(_ bulk: URL, _ rel: String, text: String, meta: [String: Any]?) {
        let fm = FileManager.default
        let txt = bulk.appendingPathComponent(rel + ".txt")
        try? fm.createDirectory(at: txt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: txt)
        guard let meta else { return }
        let side = bulk.appendingPathComponent("_meta").appendingPathComponent(rel + ".json")
        try? fm.createDirectory(at: side.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: meta).write(to: side)
    }

    private static func makeJPEG(_ url: URL, shade: CGFloat) -> URL? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        if let pixels = bitmap.bitmapData {   // a flat grey per shade, so each fixture's bytes differ
            memset(pixels, Int32(shade * 255), bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        guard let data = bitmap.representation(using: .jpeg, properties: [:]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["FARMSHARE_IMPORT_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-farmshare-import.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
