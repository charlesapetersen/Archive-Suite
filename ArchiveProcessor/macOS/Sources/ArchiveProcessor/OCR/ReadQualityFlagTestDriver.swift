#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import Foundation
import VisionOCRKit

/// Key-free, no-network contract for W46.post-read-quality-flag: the weighted confidence and its cut, the flag riding
/// on the result through a reclassification and a save, the run's summary and history naming the flagged pages, and
/// Apple Vision leaving a clean page unflagged. Every file is in one temporary directory.
///
/// Run via `scripts/test-read-quality-flag.sh`.
@MainActor
enum ReadQualityFlagTestDriver {
    nonisolated static let envKey = "READQUALITY_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APReadQuality-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. The weighted confidence and the cut.
        typealias F = ReadQualityFlag
        let sure = String(repeating: "a", count: 97), unsure = String(repeating: "b", count: 3)
        check("1 the confidence is weighted by characters",
              abs((F.weightedConfidence([(sure, 1), (unsure, 0.5)]) ?? 0) - 0.985) < 1e-9)
        check("1 no characters, no confidence", F.weightedConfidence([]) == nil && F.weightedConfidence([("", 0.3)]) == nil)
        check("1 the cut is the fitted one", F.flagBelow == 0.9815)
        check("1 a page read with confidence is not flagged", F.assess([(sure, 1), ("cc", 0.5)]) == nil)   // 0.98990
        let flagged = F.assess([(sure, 1), (String(repeating: "d", count: 5), 0.5)])                         // 0.97549
        check("1 a page with more unsure text is flagged",
              flagged != nil && abs((flagged?.visionConfidence ?? 0) - 0.975490) < 1e-5 && flagged?.disagreement == nil)
        check("1 just under the cut is flagged, at it is not",
              F.assess([("x", 0.9814)]) != nil && F.assess([("x", 0.9815)]) == nil)

        var fast = VisionOCRSettings.default; fast.usesFastRecognition = true
        var floor = VisionOCRSettings.default; floor.minimumConfidence = 0.5
        var german = VisionOCRSettings.default; german.languages = ["de-DE"]
        check("1 the cut applies under the settings it was fitted with", F.applies(to: .default))
        check("1 and not under fast recognition, a confidence floor or other languages",
              !F.applies(to: fast) && !F.applies(to: floor) && !F.applies(to: german))

        // 2. The flag on the result.
        let read = OCRResult(text: "t", classification: .documentStart, errorMessage: nil, errorCode: nil, readPoorly: flagged)
        check("2 the result carries it", read.readPoorly == flagged)
        check("2 it survives a reclassification and a turn",
              read.with(classification: .documentContinuation, rotationDegrees: 90).readPoorly == flagged)
        check("2 a failed result carries none",
              OCRResult(text: nil, classification: nil, errorMessage: "x", errorCode: "500", readPoorly: flagged).readPoorly == nil)
        let coded = try? JSONDecoder().decode(OCRResult.self, from: JSONEncoder().encode(read))
        check("2 it persists with the run's results", coded?.readPoorly == flagged)
        let legacy = #"{"text":"t","rotationDegrees":0}"#
        check("2 a result saved before it decodes as unflagged",
              (try? JSONDecoder().decode(OCRResult.self, from: Data(legacy.utf8)))?.readPoorly == nil)

        // 3. The run's summary and history.
        let visionSaid = " Apple Vision's check was measured on \(F.visionMeasuredOn)."
        let differs = ReadQualityFlag(visionConfidence: nil, disagreement: 0.8, reader: "LightOnOCR-3",
                                      measuredOn: "96 plain photographs, read on this Mac")
        let lightOnSaid = "LightOnOCR-3's check was measured on 96 plain photographs, read on this Mac"
        check("3 no flagged pages, no clause", OCRProcessor.readPoorlyClause([]).isEmpty)
        check("3 one page is named, with what its check was measured on",
              OCRProcessor.readPoorlyClause([("a.jpg", flagged!)])
                == " 1 page may have read poorly (Apple Vision was unsure); check a.jpg." + visionSaid)
        check("3 past three, the rest are counted",
              OCRProcessor.readPoorlyClause(["a", "b", "c", "d", "e"].map { ($0, flagged!) })
                == " 5 pages may have read poorly (Apple Vision was unsure); check a, b, c and 2 more." + visionSaid)
        check("3 another reader's disagreement says so, and what its cut was measured on",
              OCRProcessor.readPoorlyClause([("a", differs), ("b", differs)])
                == " 2 pages may have read poorly (Apple Vision read them differently); check a, b. \(lightOnSaid).")
        check("3 both kinds in one run name both, each reader once",
              OCRProcessor.readPoorlyClause([("a", differs), ("b", flagged!), ("c", differs)])
                == " 3 pages may have read poorly (Apple Vision was unsure, or read the page differently); check a, b, c. "
                + "\(lightOnSaid); Apple Vision's check was measured on \(F.visionMeasuredOn).")
        check("3 a PDF keeps its most concerning page's flag",
              F.worst([flagged!, differs]) == differs && F.worst([flagged!]) == flagged && F.worst([]) == nil)
        let processor = OCRProcessor()
        var good = OCRJob(sourceURL: root.appendingPathComponent("good.jpg"))
        good.result = OCRResult(text: "t", classification: .documentStart, errorMessage: nil, errorCode: nil)
        var poor = OCRJob(sourceURL: root.appendingPathComponent("poor.jpg"))
        poor.result = read
        var unwritten = OCRJob(sourceURL: root.appendingPathComponent("unwritten.jpg"))
        unwritten.result = OCRResult(text: "t", classification: .documentStart, errorMessage: "pdf", errorCode: "pdf_write_failed",
                                     readPoorly: flagged)
        processor.jobs = [good, poor, unwritten]
        check("3 the run names the succeeded flagged page only", processor.readPoorlyNames == ["poor.jpg"])
        check("3 the run summary says so", processor.runDoneMessage(succeeded: 2, failed: 1)
              == "Done. 2 succeeded, 1 failed. 1 page may have read poorly (Apple Vision was unsure); check poor.jpg."
                 + visionSaid)
        let snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .appleVision, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: LLMModel.appleVisionModels[0], visionTextProvider: nil, visionTextModel: nil, batchMode: false,
            enableTagging: false, enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false,
            mixedReOCR: false, sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .agreement,
            fileCount: 3)
        check("3 the history counts them", snapshot.makeRun(succeeded: 3, readPoorly: 2).readPoorlyPages == 2)
        check("3 a run with none records none", snapshot.makeRun(succeeded: 3).readPoorlyPages == nil)

        // 4. Apple Vision on a clean page: read, and not flagged.
        if let page = makePage(at: root.appendingPathComponent("clean.jpg")) {
            let r = try? await VisionClient(settings: .default).ocr(imageURL: page)
            check("4 Vision reads the clean page", (r?.text?.count ?? 0) > 200)
            check("4 and does not flag it", r != nil && r?.readPoorly == nil)
        } else {
            check("4 the clean page was drawn", false)
        }

        // 5. W47.wh-read-flag-readers: another reader's disagreement with Vision.
        typealias D = ReadQualityDisagreement
        check("5 the bench's NES: the same text is 1, one letter in three is 2/3",
              D.similarity("abc", "abc") == 1 && abs(D.similarity("abc", "abd") - 2.0 / 3) < 1e-9 && D.similarity("", "") == 1)
        check("5 the edit distance is Levenshtein's", D.editDistance(Array("kitten"), Array("sitting")) == 3
              && D.editDistance([], Array("abc")) == 3 && D.editDistance(Array("ab"), []) == 2)
        check("5 typography, bullets and spacing are unified as the bench does",
              D.similarity("\u{201C}a\u{201D} \u{2013} b\n- item | x\u{2022}", "\"a\" - b * item   x*") == 1)
        check("5 a letter and its accent are one character either way", D.similarity("cafe\u{301}", "caf\u{E9}") == 1)
        check("5 the length is the longer text's", abs(D.similarity("abcd", "ab") - 0.5) < 1e-9)
        // Python works on code points: a mark after a space stays a word of its own, a quote under a mark is still
        // unified, and only a line feed opens a line for the bullet rule.
        check("5 a mark after a space is kept, as Python's split keeps it", D.normalized("a \u{301}b") == "a \u{301}b")
        check("5 a quote carrying a mark is still unified", D.normalized("\u{2019}\u{301}") == "'\u{301}")
        check("5 a dash opens a line only after a line feed",
              D.normalized("a\n- b") == "a * b" && D.normalized("a\u{2028}- b") == "a - b" && D.normalized("- b") == "* b")
        check("5 the four information separators split words, as in Python", D.normalized("a\u{1C}b") == "a b")

        func route(_ provider: LLMProvider, _ id: String, gateway: Bool = false, local: Bool = false) -> D.Route {
            D.Route(provider: provider, modelID: id, gateway: gateway, local: local)
        }
        check("5 LightOnOCR on this Mac has its rule, and not on a remote server or as a thinking variant",
              D.rule(for: route(.gemini, "lightonocr-3-4b-mlx8bit", gateway: true, local: true)) == D.lightOnOCR
                && D.rule(for: route(.gemini, "lightonocr-3", gateway: true)) == nil
                && D.rule(for: route(.gemini, "qwen/qwen3-vl-8b-thinking", gateway: true, local: true)) == nil)
        check("5 the Mac's Qwen3-VL 8B", D.rule(for: route(.gemini, "qwen/qwen3-vl-8b", gateway: true, local: true)) == D.qwenVL8Mac)
        check("5 a measured model through OpenRouter on its maker's endpoint has the model's rule",
              D.rule(for: route(.openrouter, "google/gemini-3.8-flash")) == D.direct[.gemini]?["gemini-3.8-flash"]
                && D.rule(for: route(.openrouter, "openai/gpt-5.4-mini")) == D.direct[.openai]?["gpt-5.4-mini"]
                && D.rule(for: route(.openrouter, "google/gemini-3.1-pro-preview")) == D.direct[.gemini]?["gemini-3.1-pro"]
                && D.rule(for: route(.openrouter, "anthropic/claude-sonnet-5.5")) == nil)
        check("5 the Mac's Qwen3.5 9B under each server's name",
              ["mlx-community/Qwen3.5-9B-4bit", "qwen3.5:9b", "qwen/qwen3.5-9b"]
                .allSatisfy { D.rule(for: route(.gemini, $0, gateway: true, local: true)) == D.qwenMac })
        check("5 Gemini 3.7 Flash through a remote gateway, and not a local server of that name",
              D.rule(for: route(.gemini, "gemini-3.7-flash", gateway: true)) == D.gemini37Gateway
                && D.rule(for: route(.gemini, "gemini-3.7-flash", gateway: true, local: true)) == nil)
        check("5 a gateway model the bench did not read has no rule",
              D.rule(for: route(.gemini, "gw", gateway: true)) == nil
                && D.rule(for: route(.gemini, "qwen/qwen3.5-9b", gateway: true)) == nil)
        check("5 a direct route the bench did not read has no rule", D.rule(for: route(.openai, "gpt-5-nano")) == nil)
        for (provider, rules) in D.direct {
            for (id, rule) in rules {
                check("5 \(rule.reader) has its rule by its app id",
                      D.rule(for: route(provider, id)) == rule && D.rule(for: route(provider, id, gateway: true)) == nil)
            }
        }
        check("5 every cut is a disagreement between 0 and 1", D.all.allSatisfy { $0.flagAtOrAbove > 0 && $0.flagAtOrAbove <= 1 })

        let rule = D.lightOnOCR
        let base = String(repeating: "abcdefghij", count: 10)
        func text(differingIn n: Int) -> String { String(repeating: "z", count: n) + base.dropFirst(n) }
        let at = Int((rule.flagAtOrAbove * 100).rounded(.up)), under = at - 1
        check("5 a reading that disagrees at the cut is flagged, with its reader and what it was measured on",
              D.assess(readerText: text(differingIn: at), visionText: base, rule: rule)
                == ReadQualityFlag(visionConfidence: nil, disagreement: Double(at) / 100, reader: rule.reader,
                                   measuredOn: rule.measuredOn))
        check("5 just under it is not", D.assess(readerText: text(differingIn: under), visionText: base, rule: rule) == nil)
        check("5 Vision reading nothing counts as total disagreement, as in the fit",
              D.assess(readerText: base, visionText: nil, rule: rule)?.disagreement == 1)

        let page = root.appendingPathComponent("page.jpg")
        D.visionOverride = { _ in .text(base) }
        defer { D.visionOverride = nil }
        let lightOn = route(.gemini, "lightonocr-3", gateway: true, local: true)
        func result(_ t: String?, secondReader: SecondReader? = nil, readPoorly: ReadQualityFlag? = nil) -> OCRResult {
            OCRResult(text: t, classification: .documentStart, errorMessage: t == nil ? "x" : nil, errorCode: nil,
                      secondReader: secondReader, readPoorly: readPoorly)
        }
        let far = text(differingIn: 90)
        check("5 the check flags a disagreeing page", await D.check(result(far), route: lightOn, imageURL: page)?.reader == rule.reader)
        check("5 and not an agreeing one", await D.check(result(base), route: lightOn, imageURL: page) == nil)
        let unruled = await D.check(result(far), route: route(.openai, "gpt-5-nano"), imageURL: page)
        let visionOwn = await D.check(result(far), route: route(.appleVision, "lightonocr"), imageURL: page)
        let agent = await D.check(result(far), route: nil, imageURL: page)
        check("5 nor a route with no rule, Vision's own, or the Local Agent", unruled == nil && visionOwn == nil && agent == nil)
        let failed = await D.check(result(nil), route: lightOn, imageURL: page)
        let already = await D.check(result(far, readPoorly: flagged), route: lightOn, imageURL: page)
        check("5 nor a failed page or one already flagged", failed == nil && already == nil)
        let second = SecondReader(provider: "Anthropic", model: "m", firstCode: "length", trigger: .failure)
        check("5 nor a page another route read", await D.check(result(far, secondReader: second), route: lightOn, imageURL: page) == nil)
        var regions = result(far)
        regions.newspaperLayout = NewspaperLayoutRecord(regions: 3, requests: 3, coverage: 0.9, filled: true, fallback: nil)
        check("5 nor a newspaper page read in regions", await D.check(regions, route: lightOn, imageURL: page) == nil)
        var whole = result(far)   // every page the layout stage passes whole carries a record with no regions
        whole.newspaperLayout = NewspaperLayoutRecord(regions: 0, requests: 1, coverage: nil, filled: false, fallback: nil)
        check("5 but a page read whole is checked", await D.check(whole, route: lightOn, imageURL: page) != nil)
        let turned = result(far).with(classification: .documentStart, rotationDegrees: 90)
        check("5 nor a page the app turned", await D.check(turned, route: lightOn, imageURL: page) == nil)
        check("5 nor a blank reading", await D.check(result(" \n "), route: lightOn, imageURL: page) == nil)
        D.visionOverride = { _ in .nothing }
        check("5 Vision finding no text counts as total disagreement",
              await D.check(result(base), route: lightOn, imageURL: page)?.disagreement == 1)
        D.visionOverride = { _ in .failed }
        check("5 but Vision failing says nothing, so no flag", await D.check(result(far), route: lightOn, imageURL: page) == nil)
        D.visionOverride = nil

        // Real Vision on the clean page, against a reader that read it the same: not flagged.
        if let clean = makePage(at: root.appendingPathComponent("clean2.jpg")),
           let vision = try? await VisionClient(settings: .default).ocr(imageURL: clean), let same = vision.text {
            check("5 a reader that read the clean page as Vision did is not flagged",
                  await D.check(result(same), route: lightOn, imageURL: clean) == nil)
            check("5 one that read something else is",
                  await D.check(result(String(repeating: "Lorem ipsum dolor sit amet. ", count: 60)), route: lightOn,
                                imageURL: clean) != nil)
        } else {
            check("5 Vision read the clean page", false)
        }

        // 6. Optional: parity with the bench's scorer on real readings. READQUALITY_PARITY names a JSON list of
        // {"vision", "reader", "nes"} the bench computed (`post_read_flag.py parity`); nothing is committed from it.
        if let path = ProcessInfo.processInfo.environment["READQUALITY_PARITY"],
           let data = FileManager.default.contents(atPath: path),
           let pairs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let off = pairs.compactMap { p -> Double? in
                guard let v = p["vision"] as? String, let r = p["reader"] as? String, let nes = p["nes"] as? Double
                else { return 1 }
                return abs(D.similarity(v, r) - nes)
            }
            check("6 the bench's NES on \(pairs.count) real readings, to 1e-6 (worst \(off.max() ?? -1))",
                  !pairs.isEmpty && off.allSatisfy { $0 < 1e-6 })
        }

        // 7. W49.proc-vision-language-auto: no language chosen means Vision detects it.
        let suite = "APVisionLanguages-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            defer { d.removePersistentDomain(forName: suite) }
            check("7 an unset field is the default, en-US", VisionOCRSettings.fromDefaults(d).languages == ["en-US"])
            d.set("fr-FR, de-DE", forKey: DefaultsKeys.visionLanguages)
            check("7 named languages are kept in order", VisionOCRSettings.fromDefaults(d).languages == ["fr-FR", "de-DE"])
            d.set(" , ", forKey: DefaultsKeys.visionLanguages)
            check("7 separators without a language count as blank", VisionOCRSettings.fromDefaults(d).languages.isEmpty)
            d.set("", forKey: DefaultsKeys.visionLanguages)
            let none = VisionOCRSettings.fromDefaults(d)
            check("7 an emptied field is no language", none.languages.isEmpty)
            check("7 which is valid, and outside the read-poorly cut's fit", none.isValid && !F.applies(to: none))
            if let page = makePage(at: root.appendingPathComponent("french.jpg"),
                                   line: "Le comité s\u{2019}est réuni à Genève pour étudier le rapport, ligne") {
                let reader = try? PageReaders.reader(
                    provider: .appleVision, model: LLMModel.appleVisionModels[0],
                    apiKey: "", thinkingLevel: nil, visionSettings: none, newspaperLayout: false)
                let r = try? await reader?.read(PageReaderInput(imageURL: page))
                check("7 Vision with no language reads a French page with its accents",
                      (r?.text ?? "").contains("comité") && (r?.text ?? "").contains("Genève"))
            } else {
                check("7 the French page was drawn", false)
            }
        } else {
            check("7 a scratch defaults suite", false)
        }

        finish(results)
    }

    /// A page of dark text lines on white, upright.
    private static func makePage(
        at url: URL, line text: String = "The committee met on the fourth of March to consider the report, line"
    ) -> URL? {
        let size = NSSize(width: 850, height: 1100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
        for line in 0..<30 {
            ("\(text) \(line)." as NSString)
                .draw(at: NSPoint(x: 60, y: 1040 - CGFloat(line) * 33), withAttributes: attrs)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["READQUALITY_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-read-quality.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
#endif
