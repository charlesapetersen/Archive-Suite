#if DEBUG // a test driver, compiled out of Release
import Foundation
import ArchiveCore

/// Headless, key-free ($0) self-test of the entity feature (W46.ent-feature), gated by `ENTITY_FEATURE_TEST=1`
/// (`scripts/test-entity-feature.sh`). No real network: every request goes to `NetworkSession.testTransport`, and the
/// driver stops before any call if that seam is not active. No Keychain read, no window, never the corpus: the end to
/// end part writes scratch PDFs and sidecars under a temporary folder and removes it.
///
///   1. The evidence check on the cases shared with the bench (`segbench/fixtures/ent-evidence-cases.json`, path in
///      `ENTITY_FEATURE_CASES`; `test_ent_feature.py` runs the same cases through `ent_feature.evidence`).
///   2. Parsing a reply: a quoted, an inferred and a neighbour-lifted name, several recipients, "Unknown" dropped.
///   3. The run policy (owner call 11 and the stage's rules).
///   4. The sidecar object and `SegmentJSONBuilder` with and without it.
///   5. End to end through `performTaggingPhase`, a cloud route and a route on this Mac, on scratch outputs.
///   6. Live Capture (W46.ent-feature-live): through the real ingest → finalize path with the $0 OCR stand-in, the
///      sidecar's `entities` object, the names kept in the staging manifest, a rotation-review regeneration that
///      carries them with no second call, and no call with sidecars off or "No names". Needs the scratch backup root
///      (`ARCHIVEPROC_TEST_BACKUP_ROOT`) and refuses to run without it.
@MainActor
enum EntityFeatureTestDriver {
    nonisolated static let envKey = "ENTITY_FEATURE_TEST"
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        lines.append("\(ok ? "PASS" : "FAIL"): \(name)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    /// Called from up to six concurrent requests, so every access holds the lock.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var tagging = 0
        var entity: [String] = []
        /// Reply by a marker word in the document's text.
        var taggingReply: [String: String] = [:]
        var entityReply: [String: String] = [:]
    }

    static func run() async {
        evidenceCases()
        parsing()
        policy()
        sidecar()
        await endToEnd()
        await liveCapture()
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["ENTITY_FEATURE_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1. The evidence check

    private static func evidenceCases() {
        guard let path = ProcessInfo.processInfo.environment["ENTITY_FEATURE_CASES"],
              let data = FileManager.default.contents(atPath: path),
              let cases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !cases.isEmpty else {
            check("1 the shared evidence cases load", false, "ENTITY_FEATURE_CASES")
            return
        }
        for c in cases {
            let id = c["id"] as? String ?? "?"
            let text = String(repeating: "x", count: c["pad"] as? Int ?? 0) + (c["text"] as? String ?? "")
            let got = EntityExtractor.evidence(quote: c["quote"] as? String, in: text)
            let want: EntityExtractor.Evidence = c["evidence"] as? String == "quoted"
                ? .quoted(distance: c["distance"] as? Int ?? -1) : .inferred(why: c["why"] as? String ?? "")
            check("1 \(id)", got == want, "got \(got) want \(want)")
        }
    }

    // MARK: 2. Parsing

    private static func parsing() {
        let text = "Dear Dr. Brown and Mrs. Black,\nThank you for your letter.\nYours, Alice Green\nBoston, Mass."
        let reply = """
        ```json
        {"sender": [{"name": "Robert White", "quote": "Robert White"}, {"name": "Alice Green", "quote": "Alice Green"}],
         "recipient": [{"name": "Charles Brown", "quote": "Dr. Brown"}, {"name": "Edith Black", "quote": null},
                       {"name": "Unknown", "quote": null}, {"name": "charles  brown", "quote": "Brown"}],
         "sending_place": "Boston, Massachusetts"}
        ```
        """
        guard let f = EntityExtractor.parse(reply, documentText: text) else {
            check("2 a fenced reply parses", false); return
        }
        check("2 a neighbour-lifted sender is written marked inferred",
              f.senders.first == .init(name: "Robert White", quote: "Robert White",
                                       evidence: .inferred(why: EntityExtractor.quoteNotInText)))
        check("2 a sender quoted from the text is read", f.senders.last?.evidence == .quoted(distance: 0)
              && f.senders.last?.confidence == "high")
        check("2 several recipients are kept apart, a repeat and \"Unknown\" dropped",
              f.recipients.map(\.name) == ["Charles Brown", "Edith Black"], "\(f.recipients.map(\.name))")
        check("2 a recipient with no quote is inferred, low",
              f.recipients.last?.evidence == .inferred(why: EntityExtractor.noQuote) && f.recipients.last?.confidence == "low")
        check("2 a bare string is a name with no quote",
              f.sendingPlaces == [.init(name: "Boston, Massachusetts", quote: nil,
                                        evidence: .inferred(why: EntityExtractor.noQuote))])
        check("2 a reply that is not a JSON object gives nil",
              EntityExtractor.parse("I could not find any names.", documentText: text) == nil
              && EntityExtractor.parse("[1, 2]", documentText: text) == nil)
        check("2 null and empty fields are empty",
              EntityExtractor.parse(#"{"sender": null, "recipient": [], "sending_place": [""]}"#, documentText: text)
              == EntityExtractor.Fields())
        let prompt = EntityExtractor.prompt(text: String(repeating: "a", count: 3100) + "TAIL")
        check("2 the prompt carries the first 3,000 characters only",
              prompt.contains(String(repeating: "a", count: 3000)) && !prompt.contains("TAIL")
              && !prompt.contains("Nearby documents"))
    }

    // MARK: 3. The run policy

    private static func policy() {
        typealias P = EntityRunPolicy
        func inputs(_ family: P.Family = .cloud, ranked: Bool = false, none: Bool = false, format: String? = "letter",
                    source: P.TextSource = .reader, kinds: [P.PageKind] = [.typedOrPrinted]) -> P.Inputs {
            P.Inputs(family: family, namesRanked: ranked, routeNone: none, format: format, textSource: source,
                     pageKinds: kinds, route: "r")
        }
        func runs(_ i: P.Inputs) -> P.Run? { if case .run(let r) = P.decide(i) { return r }; return nil }
        check("3 cloud: extracted even when names are not ranked, not shown",
              runs(inputs()).map { !$0.shown && $0.senderWithheld == nil } == true)
        check("3 cloud: shown when ranked", runs(inputs(ranked: true))?.shown == true)
        check("3 Mac: not run when names are not ranked", runs(inputs(.mac)) == nil)
        check("3 Mac: run when ranked, on typed pages", runs(inputs(.mac, ranked: true))?.shown == true)
        check("3 Mac: never on handwriting, even read by a model",
              runs(inputs(.mac, ranked: true, kinds: [.typedOrPrinted, .handwritten])) == nil)
        check("3 Mac: not on a page of unknown kind", runs(inputs(.mac, ranked: true, kinds: [.unknown])) == nil)
        check("3 Mac: not when the reader of a page is unknown",
              runs(inputs(.mac, ranked: true, source: .unknown)) == nil)
        check("3 cloud: a model's reading of handwriting is allowed",
              runs(inputs(source: .reader, kinds: [.handwritten])) != nil)
        check("3 Vision text on a handwritten page: never", runs(inputs(source: .vision, kinds: [.handwritten])) == nil)
        check("3 Vision text on an unclassified page: never", runs(inputs(source: .vision, kinds: [.unknown])) == nil)
        check("3 Vision text on typed pages: run, the sender withheld",
              runs(inputs(source: .vision))?.senderWithheld != nil
              && runs(inputs(.mac, ranked: true, source: .vision))?.senderWithheld != nil)
        check("3 unknown reader on a cloud route: as Vision text",
              runs(inputs(source: .unknown))?.senderWithheld != nil && runs(inputs(source: .unknown, kinds: [])) == nil)
        check("3 correspondence only: a report, a missing format",
              runs(inputs(format: "report")) == nil && runs(inputs(format: nil)) == nil
              && runs(inputs(format: " Memo ")) != nil && runs(inputs(format: "Telegram")) != nil)
        check("3 a Local Agent plan: not run", runs(inputs(.plan, ranked: true)) == nil)
        check("3 the user's \"No names\": not run", runs(inputs(none: true)) == nil)
    }

    // MARK: 4. The sidecar

    private static func sidecar() {
        let run = EntityRunPolicy.Run(route: "Gemini · Gemini 3.8 Flash", textSource: .reader, shown: true,
                                      senderWithheld: nil)
        let fields = EntityExtractor.Fields(
            senders: [.init(name: "Alice Green", quote: "Alice Green", evidence: .quoted(distance: 0))],
            recipients: [.init(name: "Charles Brown", quote: "Dr. Browm", evidence: .quoted(distance: 1)),
                         .init(name: "Edith Black", quote: "E. Black?", evidence: .inferred(why: EntityExtractor.quoteNotInText))],
            sendingPlaces: [])
        let o = EntityResult(decision: run, outcome: .extracted(fields)).sidecarObject
        let sender = (o["sender"] as? [[String: Any]])?.first
        let recips = o["recipient"] as? [[String: Any]] ?? []
        let place = o["sending_place"] as? [[String: Any]] ?? []
        check("4 status, route, text and shown", o["status"] as? String == "extracted" && o["shown"] as? Bool == true
              && o["text"] as? String == "reader" && o["route"] as? String == "Gemini · Gemini 3.8 Flash")
        check("4 a read name: quote, evidence, confidence", sender?["quote"] as? String == "Alice Green"
              && sender?["evidence"] as? String == "quoted" && sender?["confidence"] as? String == "high"
              && sender?["distance"] == nil)
        check("4 a near quote records its distance", recips.first?["distance"] as? Int == 1
              && recips.first?["confidence"] as? String == "medium")
        check("4 an inferred name keeps no quote and says why", recips.last?["quote"] == nil
              && recips.last?["evidence"] as? String == "inferred"
              && recips.last?["inferred_because"] as? String == EntityExtractor.quoteNotInText)
        check("4 an empty field is \"Unknown\"", place.count == 1 && place[0]["name"] as? String == "Unknown"
              && place[0]["evidence"] as? String == "unknown")
        let vision = EntityRunPolicy.Run(route: "r", textSource: .vision, shown: false,
                                         senderWithheld: "never from Apple Vision text")
        let v = EntityResult(decision: vision, outcome: .extracted(fields)).sidecarObject
        check("4 Vision text: no sender, and why", v["sender"] == nil
              && v["sender_withheld"] as? String == "never from Apple Vision text" && v["recipient"] != nil)
        let failed = EntityResult(decision: run, outcome: .failed("the call failed")).sidecarObject
        check("4 a failed call: no names, and the sidecar says so", failed["status"] as? String == "failed"
              && failed["reason"] as? String == "the call failed" && failed["sender"] == nil && failed["recipient"] == nil)

        let url = URL(fileURLWithPath: "/scratch/page1.jpg")
        let tags = GeneratedTags(year: "1958", subjectTags: ["Harbours"], format: "letter", authorName: "A. Green",
                                 recipientName: "C. Brown", authorLocation: "Boston", recipientLocation: "Salem")
        let plain = SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags)
        let none = SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, entities: nil)
        check("4 no entities: the sidecar is unchanged", plain != nil && plain == none)
        let withData = SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, entities: o) ?? Data()
        let w = (try? JSONSerialization.jsonObject(with: withData) as? [String: Any]) ?? [:]
        check("4 with entities: one answer per field (the tagging call's three name keys left out)",
              w["entities"] != nil && w["author_name"] == nil && w["recipient_name"] == nil
              && w["author_location"] == nil && w["recipient_location"] as? String == "Salem"
              && w["format"] as? String == "letter")
    }

    /// Every request answered by `wire`: the tagging and the names prompt told apart by their first words, the
    /// document by the marker word nearest the start of the prompt (its own text comes first in both).
    private static func install(_ wire: Wire) {
        NetworkSession.testTransport = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let prompt = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            // The document's own text comes first in both prompts; the tagging prompt's neighbour context follows.
            let marker = ["DOCL", "DOCR", "DOCV", "DOCH", "DOCF"]
                .compactMap { m in prompt.range(of: m).map { (m, $0.lowerBound) } }
                .min { $0.1 < $1.1 }?.0 ?? ""
            let content: String = wire.lock.withLock {
                if prompt.contains("You are a metadata tagging assistant") {
                    wire.tagging += 1
                    return wire.taggingReply[marker] ?? "{}"
                }
                if prompt.contains("You are extracting correspondence metadata") {
                    wire.entity.append(marker)
                    return wire.entityReply[marker] ?? "no"
                }
                return "unexpected"
            }
            let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: 5. End to end

    private static func endToEnd() async {
        let fm = FileManager.default
        check("5 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("5 the injected transport is active", false, "stopping before any request")
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APEntityFeature-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let letter = #"{"year": "1958", "format": "letter", "author_name": "Tagging Sender", "recipient_name": "Tagging Recipient", "author_location": "Tagging Place"}"#
        wire.taggingReply = ["DOCL": letter, "DOCV": letter, "DOCH": letter, "DOCF": letter,
                             "DOCR": #"{"year": "1960", "format": "report", "author_name": "Report Author"}"#]
        let names = #"{"sender": [{"name": "Alice Green", "quote": "Alice Green"}], "recipient": [{"name": "Charles Brown", "quote": "Dr. Brown"}, {"name": "Edith Black", "quote": null}], "sending_place": []}"#
        wire.entityReply = ["DOCL": names, "DOCV": names, "DOCH": names, "DOCF": "I cannot help with that."]

        // L: typed, read by Gemini · R: a report · V: typed, Apple Vision text · H: handwritten, Apple Vision text ·
        // F: typed, read by Gemini, an unusable entity reply.
        let docs: [(String, String, String)] = [("L", "typewritten", "Gemini"), ("R", "printed", "Gemini"),
                                                ("V", "typewritten", "Apple Vision"), ("H", "handwritten", "Apple Vision"),
                                                ("F", "typewritten", "Gemini")]
        func processor(gateway: GatewayConfig?, ranked: Bool, out: String,
                       noNames: Bool = false) -> (OCRProcessor, [String: URL]) {
            let outDir = tmp.appendingPathComponent(out, isDirectory: true)
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let p = OCRProcessor()
            p.taggingMode = .automatic
            p.currentGateway = gateway
            let files = docs.map { tmp.appendingPathComponent("\(out)-\($0.0).jpg") }
            p.jobs = docs.enumerated().map { i, d in
                var job = OCRJob(sourceURL: files[i])
                job.result = OCRResult(text: "DOC\(d.0) Dear Dr. Brown,\nThank you.\nYours, Alice Green",
                                       classification: .documentStart, errorMessage: nil, errorCode: nil,
                                       pageReader: PageReaderRecord(kind: d.1, confidence: 0.9, reason: .kind,
                                                                    provider: d.2, model: "m"))
                job.classification = .documentStart
                return job
            }
            var outputs: [String: URL] = [:]
            var map: [URL: URL] = [:]
            for (i, d) in docs.enumerated() {
                let pdf = outDir.appendingPathComponent("\(d.0).pdf")
                fm.createFile(atPath: pdf.path, contents: Data("%PDF-1.4\n%%EOF\n".utf8))
                outputs[d.0] = pdf.deletingPathExtension().appendingPathExtension("json")
                map[files[i]] = pdf
            }
            p.outputURLMap = map
            p.rebuildSegments(files: files)
            p.activeResolvedSettings = ResolvedSettingsSnapshot(
                runID: UUID(), resolvedAt: Date(), collectionID: nil, projectID: nil, projectName: nil, macMemoryGB: 16,
                values: [SettingsKey.priorities.rawValue: ResolvedSetting(
                            value: .strings(ranked ? ["reading", "names"] : ["reading", "dates"])),
                         SettingsSheetModel.overrideKey("entities").rawValue: ResolvedSetting(
                            value: .string(noNames ? "none" : ""))],
                processing: [:])
            return (p, outputs)
        }
        func json(_ u: URL?) -> [String: Any] {
            guard let u, let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        guard let route = OpenRouterRoute.catalog.first else { check("5 an OpenRouter route", false); return }

        // A cloud route, names not ranked: extracted, not shown.
        let (cloud, cloudOut) = processor(gateway: nil, ranked: false, out: "cloud")
        check("5 five segments", cloud.segments.count == 5, "\(cloud.segments.count)")
        await cloud.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                        outputDirectory: tmp, enableSegmentJSON: true)
        check("5 cloud: every document tagged once", wire.tagging == 5, "\(wire.tagging)")
        check("5 cloud: the entity call on the letters the policy allows (L, V, F), not the report or the hand",
              wire.entity.sorted() == ["DOCF", "DOCL", "DOCV"], "\(wire.entity)")
        let l = json(cloudOut["L"])
        let le = l["entities"] as? [String: Any] ?? [:]
        check("5 L: extracted, not shown, read by a model, the route named", le["status"] as? String == "extracted"
              && le["shown"] as? Bool == false && le["text"] as? String == "reader"
              && le["route"] as? String == "OpenRouter · \(route.model.displayName)", "\(le["route"] ?? "")")
        check("5 L: the sender read, two recipients, the place Unknown",
              (le["sender"] as? [[String: Any]])?.first?["evidence"] as? String == "quoted"
              && (le["recipient"] as? [[String: Any]])?.count == 2
              && (le["sending_place"] as? [[String: Any]])?.first?["name"] as? String == "Unknown")
        check("5 L: the tagging call's name keys are not beside it", l["author_name"] == nil && l["format"] as? String == "letter")
        let r = json(cloudOut["R"])
        check("5 R: no entities, the tagging call's fields as before",
              r["entities"] == nil && r["author_name"] as? String == "Report Author")
        let ve = json(cloudOut["V"])["entities"] as? [String: Any] ?? [:]
        check("5 V: Vision text, the sender withheld", ve["text"] as? String == "vision" && ve["sender"] == nil
              && ve["sender_withheld"] != nil && ve["recipient"] != nil)
        let h = json(cloudOut["H"])
        check("5 H: no entities on handwriting read by Apple Vision", h["entities"] == nil && !h.isEmpty)
        let fe = json(cloudOut["F"])["entities"] as? [String: Any] ?? [:]
        check("5 F: an unusable reply is recorded as failed, with no names",
              fe["status"] as? String == "failed" && fe["sender"] == nil)

        // This Mac's model, names not ranked: no entity call at all; ranked: typed pages only.
        let local = GatewayConfig(baseURL: "http://127.0.0.1:1234/v1", modelID: "qwen3-vl-8b", displayName: "Qwen3-VL 8B",
                                  localModel: true)
        wire.lock.withLock { wire.tagging = 0; wire.entity = [] }
        let (mac, macOut) = processor(gateway: local, ranked: false, out: "mac")
        await mac.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "",
                                      outputDirectory: tmp, enableSegmentJSON: true)
        check("5 Mac, names not ranked: tagged, no entity call", wire.tagging == 5 && wire.entity.isEmpty,
              "\(wire.tagging) \(wire.entity)")
        check("5 Mac, names not ranked: the sidecar as before", json(macOut["L"])["entities"] == nil
              && json(macOut["L"])["author_name"] as? String == "Tagging Sender")
        wire.lock.withLock { wire.tagging = 0; wire.entity = [] }
        let (macRanked, macRankedOut) = processor(gateway: local, ranked: true, out: "macranked")
        await macRanked.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "",
                                            outputDirectory: tmp, enableSegmentJSON: true)
        check("5 Mac, names ranked: L, V and F, never the hand", wire.entity.sorted() == ["DOCF", "DOCL", "DOCV"],
              "\(wire.entity)")
        let me = json(macRankedOut["L"])["entities"] as? [String: Any] ?? [:]
        check("5 Mac, names ranked: shown, the route named as this Mac and its own model",
              me["shown"] as? Bool == true && me["route"] as? String == "this Mac · Qwen3-VL 8B", "\(me["route"] ?? "")")

        // "No names" on the Names card (the sheet stores it for the whole stage): no entity call on any route.
        wire.lock.withLock { wire.tagging = 0; wire.entity = [] }
        let (noNames, noNamesOut) = processor(gateway: nil, ranked: true, out: "nonames", noNames: true)
        await noNames.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                          outputDirectory: tmp, enableSegmentJSON: true)
        check("5 \"No names\": tagged, no entity call, the sidecar as before",
              wire.tagging == 5 && wire.entity.isEmpty && json(noNamesOut["L"])["entities"] == nil,
              "\(wire.tagging) \(wire.entity)")
    }

    // MARK: 6. Live Capture

    private static func liveCapture() async {
        let fm = FileManager.default
        guard !(ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"] ?? "").isEmpty else {
            check("6 Live Capture runs against a scratch backup root (never the operator's)", false)
            return
        }
        guard let route = OpenRouterRoute.catalog.first else { check("6 an OpenRouter route", false); return }
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil; LiveCaptureProcessor._recoveryTestOCRStub = nil }
        guard NetworkSession.testTransportIsActive else {
            check("6 the injected transport is active", false, "stopping before any request")
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APEntityLive-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let letter = #"{"year": "1958", "format": "letter", "author_name": "Tagging Sender", "recipient_name": "Tagging Recipient", "author_location": "Tagging Place"}"#
        wire.taggingReply = ["DOCL": letter, "DOCV": letter, "DOCH": letter, "DOCF": letter,
                             "DOCR": #"{"year": "1960", "format": "report", "author_name": "Report Author"}"#]
        let names = #"{"sender": [{"name": "Alice Green", "quote": "Alice Green"}], "recipient": [{"name": "Charles Brown", "quote": "Dr. Brown"}, {"name": "Edith Black", "quote": null}], "sending_place": []}"#
        wire.entityReply = ["DOCL": names, "DOCV": names, "DOCH": names, "DOCF": "I cannot help with that."]
        let docs: [(String, String, String)] = [("L", "typewritten", "Gemini"), ("R", "printed", "Gemini"),
                                                ("V", "typewritten", "Apple Vision"), ("H", "handwritten", "Apple Vision"),
                                                ("F", "typewritten", "Gemini")]

        func settle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func json(_ u: URL?) -> [String: Any] {
            guard let u, let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        func config(_ out: String, sidecars: Bool = true) -> SessionProcessingConfig {
            SessionProcessingConfig(
                provider: .openrouter, model: route.model, thinkingLevel: .low, apiKey: "test-key",
                taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
                outputDirectory: tmp.appendingPathComponent(out, isDirectory: true),
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: sidecars, tagVocabulary: [], gateway: nil,
                outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1)
        }
        /// One live session: each document's one page ingested with its stand-in OCR result, resolved, and staged.
        func session(_ name: String, sidecars: Bool = true,
                     settings: [String: ResolvedSetting] = [:]) async -> (CaptureSession, URL, SessionProcessingConfig) {
            let staging = tmp.appendingPathComponent("APStaging-\(name)", isDirectory: true)
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let cfg = config(name, sidecars: sidecars)
            let s = CaptureSession()
            s._recoveryTestBeginLive(config: cfg, stagingDir: staging)
            s.liveProcessor._entityTestSetSettings(settings)
            for (i, d) in docs.enumerated() {
                LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(
                    text: "DOC\(d.0) Dear Dr. Brown,\nThank you.\nYours, Alice Green", classification: nil,
                    errorMessage: nil, errorCode: nil,
                    pageReader: PageReaderRecord(kind: d.1, confidence: 0.9, reason: .kind, provider: d.2, model: "m"))
                _ = s.ingest(jpeg: Data("synthetic page bytes".utf8), groupId: d.0, seq: i + 1, type: .document,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            for d in docs { s.liveProcessor.segmentResolved(groupId: d.0) }
            let all = await settle { s.liveProcessor.staged.count == docs.count }
            check("6 \(name): every document stages", all, "\(s.liveProcessor.staged.count)")
            return (s, staging, cfg)
        }
        func sidecar(_ s: CaptureSession, _ gid: String) -> [String: Any] {
            json(s.liveProcessor.staged.first { $0.groupId == gid }?.jsonURL)
        }

        // A cloud route, names not ranked: extracted on the letters the policy allows, not shown.
        let (cloud, cloudStaging, cloudConfig) = await session("live")
        check("6 Live: every document tagged once", wire.tagging == 5, "\(wire.tagging)")
        check("6 Live: the entity call on L, V and F, not the report or the hand",
              wire.entity.sorted() == ["DOCF", "DOCL", "DOCV"], "\(wire.entity)")
        let l = sidecar(cloud, "L")
        let le = l["entities"] as? [String: Any] ?? [:]
        check("6 Live L: extracted, not shown, read by a model, the route named",
              le["status"] as? String == "extracted" && le["shown"] as? Bool == false
              && le["text"] as? String == "reader" && le["route"] as? String == "OpenRouter · \(route.model.displayName)",
              "\(le)")
        check("6 Live L: the sender read, two recipients, the place Unknown",
              (le["sender"] as? [[String: Any]])?.first?["evidence"] as? String == "quoted"
              && (le["recipient"] as? [[String: Any]])?.count == 2
              && (le["sending_place"] as? [[String: Any]])?.first?["name"] as? String == "Unknown")
        check("6 Live L: the tagging call's name keys are not beside it",
              l["author_name"] == nil && l["recipient_name"] == nil && l["format"] as? String == "letter")
        let r = sidecar(cloud, "R")
        check("6 Live R: no entities, the tagging call's fields as before",
              r["entities"] == nil && r["author_name"] as? String == "Report Author")
        let ve = sidecar(cloud, "V")["entities"] as? [String: Any] ?? [:]
        check("6 Live V: Apple Vision text, the sender withheld",
              ve["text"] as? String == "vision" && ve["sender"] == nil && ve["sender_withheld"] != nil)
        let h = sidecar(cloud, "H")
        check("6 Live H: no entities on handwriting read by Apple Vision", h["entities"] == nil && !h.isEmpty)
        check("6 Live F: an unusable reply is recorded as failed, with no names",
              (sidecar(cloud, "F")["entities"] as? [String: Any])?["status"] as? String == "failed")

        // The staging manifest keeps the names, so a relaunch's rotation review regenerates them.
        let kept = cloud.liveProcessor._entityTestRetainedEntities("L")
        check("6 Live: the names are retained with the segment", kept.map {
            if case .extracted(let f) = $0.outcome { return f.senders.first?.name == "Alice Green" }; return false
        } == true)
        let reloaded = CaptureSession()
        reloaded.liveProcessor._recoveryTestLoadManifest(stagingDir: cloudStaging, config: cloudConfig)
        check("6 Live: the staging manifest round-trips them", kept != nil
              && reloaded.liveProcessor._entityTestRetainedEntities("L") == kept
              && reloaded.liveProcessor._entityTestRetainedEntities("R") == nil)

        // A rotation-review regeneration rewrites the sidecar with the same names and makes no second call.
        let calls = wire.lock.withLock { wire.entity.count }
        let before = le as NSDictionary
        if let src = cloud.photos.first(where: { $0.groupId == "L" })?.url {
            cloud.liveProcessor.rotationReviewPages = [
                LiveCaptureProcessor.RotationReviewPage(groupId: "L", pageIndex: 0, order: 1, sourceURL: src,
                                                        rotationDegrees: 90)
            ]
            cloud.liveProcessor.applyRotationReviewAndFinalize()
            check("6 Live: the rotation change triggers a regeneration", cloud.liveProcessor.isFinalizing)
            let done = await settle { !cloud.liveProcessor.isFinalizing }
            let after = sidecar(cloud, "L")["entities"] as? [String: Any] ?? [:]
            check("6 Live: the regenerated sidecar carries the same names, no second call",
                  done && (after as NSDictionary) == before && wire.lock.withLock { wire.entity.count } == calls,
                  "\(after)")
        } else {
            check("6 Live: L's source page is on disk", false)
        }

        // Sidecars off: the names have no output, so no call; "No names": no call either.
        wire.lock.withLock { wire.tagging = 0; wire.entity = [] }
        _ = await session("nosidecars", sidecars: false)
        check("6 Live, sidecars off: tagged, no entity call", wire.tagging == 5 && wire.entity.isEmpty,
              "\(wire.tagging) \(wire.entity)")
        wire.lock.withLock { wire.tagging = 0; wire.entity = [] }
        let (none, _, _) = await session("nonames", settings: [
            SettingsSheetModel.overrideKey("entities").rawValue: ResolvedSetting(value: .string("none"))])
        check("6 Live, \"No names\": tagged, no entity call, the sidecar as before",
              wire.tagging == 5 && wire.entity.isEmpty && sidecar(none, "L")["entities"] == nil
              && sidecar(none, "L")["author_name"] as? String == "Tagging Sender", "\(wire.tagging) \(wire.entity)")
    }
}

#endif
