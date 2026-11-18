#if DEBUG // a test driver, compiled out of Release
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ArchiveCore

/// Headless, key-free ($0) self-test of the item fields (W47.item-fields-build), gated by `ITEM_FIELDS_TEST=1`
/// (`scripts/test-item-fields.sh`). No real network: every request goes to `NetworkSession.testTransport`, and the
/// driver stops before any call if that seam is not active. No Keychain read, no window, never the corpus: the end to
/// end part writes scratch images, PDFs and sidecars under a temporary folder and removes it.
///
///   1. Parsing a reply as the bench does (`item_fields.parse` and `by_definition`), and the marked text.
///   2. The fill policy: which fields fill on which kinds, title withheld.
///   3. The sidecar object, and `SegmentJSONBuilder` with and without it.
///   4. End to end through `performTaggingPhase` on a remote gateway: the call made with the page images and the
///      measured model; none on a route the bench did not measure, nor with sidecars off.
@MainActor
enum ItemFieldsTestDriver {
    nonisolated static let envKey = "ITEM_FIELDS_TEST"
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

    static func run() async {
        parsing()
        policy()
        sidecar()
        await endToEnd()
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["ITEM_FIELDS_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1. Parsing

    private static func parsing() {
        typealias X = ItemFieldExtractor
        let article = """
        <think>a newspaper piece</think>```json
        {"kind": "Newspaper Article", "title": "  Senate  Passes \\"Tax\\" Bill ", "byline": "By John Smith",
         "publication": "The New York Times", "publication_date": "1967-5-22",
         "recipient_place": ["City, State"], "quotes": {"title": "Senate Passes", "byline": ["By", "John Smith"],
         "publication": null}}
        ```
        """
        guard let a = X.parse(article) else { check("1 a fenced reply with a think block parses", false); return }
        check("1 kind lowercased, title's whitespace folded", a.kind == "newspaper article"
              && a.title == "Senate Passes \"Tax\" Bill", "\(a.kind ?? "") \(a.title ?? "")")
        check("1 a byline string is a one-name list, the date zero-padded",
              a.byline == ["By John Smith"] && a.publicationDate == "1967-05-22", "\(a.byline) \(a.publicationDate ?? "")")
        check("1 a placeholder place is dropped", a.recipientPlace.isEmpty)
        check("1 quotes kept, a list joined, a null left out",
              a.quotes == ["title": "Senate Passes", "byline": "By John Smith"], "\(a.quotes)")
        let letter = X.parse(#"{"kind": "letter", "title": "Re: budget", "byline": ["A B"], "publication": "Times", "publication_date": "1958", "recipient_place": ["Boston, MA", {"name": "Unknown"}, ""]}"#)
        check("1 a letter has no title, byline, publication or publication date (by_definition)",
              letter?.title == nil && letter?.byline == [] && letter?.publication == nil && letter?.publicationDate == nil)
        check("1 a letter keeps its recipient place, an empty name dropped",
              letter?.recipientPlace == ["Boston, MA", "Unknown"], "\(letter?.recipientPlace ?? [])")
        let memo = X.parse(#"{"kind": "memo", "title": "Budget", "publication": "x"}"#)
        check("1 a memo keeps its subject line as a title", memo?.title == "Budget" && memo?.publication == nil)
        check("1 an unknown kind is other, a missing one nil",
              X.parse(#"{"kind": "pamphlet"}"#)?.kind == "other" && X.parse("{}")?.kind == nil)
        check("1 dates: a bad month drops month and day, a bad day the day, junk nil",
              X.date("1967-13-02") == "1967" && X.date("1967-02-40") == "1967-02" && X.date("May 1967") == nil
              && X.date(1967) == "1967" && X.date("null") == nil && X.date("67") == nil)
        check("1 null-like words are nil", X.clean("Not stated") == nil && X.clean(" - ") == nil && X.clean(true) == nil)
        check("1 a reply with no JSON object gives nil", X.parse("I cannot read this.") == nil)

        let texts = (1...12).map { "text \($0)  \n" }
        let marked = X.markedText(texts)
        check("1 a long document sends pages 1-8 and 11-12, each marked of 12",
              marked.hasPrefix("[page 1 of 12]\ntext 1\n\n[page 2 of 12]") && marked.contains("[page 8 of 12]")
              && !marked.contains("[page 9 of 12]") && marked.hasSuffix("[page 12 of 12]\ntext 12"))
        check("1 the pages sent match the text marks", X.capped(Array(1...12)) == [1, 2, 3, 4, 5, 6, 7, 8, 11, 12]
              && X.capped(Array(1...10)) == Array(1...10))
        let long = X.markedText([String(repeating: "é", count: 20000)])
        check("1 the text is cut at 16,000 scalars", long.unicodeScalars.count == X.textCap)
        let p = X.prompt(texts: ["hello"])
        check("1 the prompt carries the marked text where the bench puts it",
              p.hasSuffix("OCR text:\n---\n[page 1 of 1]\nhello\n---") && p.hasPrefix("You are labelling catalogue fields")
              && !p.contains("{text}"))
    }

    // MARK: 2. The fill policy

    private static func policy() {
        typealias P = ItemFieldPolicy
        check("2 kind and publication fill on every kind",
              P.withheld(.kind, kind: nil) == nil && P.withheld(.publication, kind: "speech") == nil)
        check("2 title is withheld on every kind", P.withheld(.title, kind: "newspaper article") == P.titleBelowBar
              && P.withheld(.title, kind: "memo") != nil)
        check("2 byline and publication date fill on published kinds only",
              P.withheld(.byline, kind: "report") == nil && P.withheld(.publicationDate, kind: "clipping") == nil
              && P.withheld(.byline, kind: "speech") != nil && P.withheld(.publicationDate, kind: nil) != nil)
        check("2 recipient place fills on correspondence only",
              P.withheld(.recipientPlace, kind: "telegram") == nil && P.withheld(.recipientPlace, kind: "report") != nil)
        let gw = GatewayConfig(baseURL: "https://gateway.test/v1", modelID: "m", displayName: "Gateway")
        let mac = GatewayConfig(baseURL: "http://127.0.0.1:1234/v1", modelID: "q", displayName: "Q", localModel: true)
        check("2 runs on a remote gateway with sidecars on", P.skipReason(gateway: gw, localAgent: nil, sidecars: true) == nil)
        check("2 not with sidecars off, on this Mac's model, nor with no gateway",
              P.skipReason(gateway: gw, localAgent: nil, sidecars: false) != nil
              && P.skipReason(gateway: mac, localAgent: nil, sidecars: true) != nil
              && P.skipReason(gateway: nil, localAgent: nil, sidecars: true) != nil)
    }

    // MARK: 3. The sidecar

    private static func sidecar() {
        var r = ItemFieldExtractor.Reading(kind: "newspaper article", title: "A Headline", byline: ["John Smith"],
                                           publication: "The Times", publicationDate: "1967-05",
                                           recipientPlace: [], quotes: ["title": "A Headline", "byline": "John Smith"])
        let o = ItemFieldResult(route: "Gateway · gemini-3.7-flash", outcome: .read(r)).sidecarObject
        check("3 the filled fields are written, the route and status named",
              o["status"] as? String == "read" && o["kind"] as? String == "newspaper article"
              && o["byline"] as? [String] == ["John Smith"] && o["publication"] as? String == "The Times"
              && o["publication_date"] as? String == "1967-05" && o["route"] as? String == "Gateway · gemini-3.7-flash")
        check("3 the title is not written, only why", o["title"] == nil
              && (o["not_filled"] as? [String: String])?["title"] == ItemFieldPolicy.titleBelowBar)
        check("3 a withheld field's quote is not written", (o["quotes"] as? [String: String]) == ["byline": "John Smith"])
        r.kind = "speech"
        let s = ItemFieldResult(route: "g", outcome: .read(r)).sidecarObject
        check("3 a byline on an unmeasured kind is not filled", s["byline"] == nil && s["publication_date"] == nil
              && (s["not_filled"] as? [String: String])?["byline"] != nil && s["publication"] as? String == "The Times")
        let f = ItemFieldResult(route: "g", outcome: .failed("the call failed")).sidecarObject
        check("3 a failed call is recorded with no fields", f["status"] as? String == "failed" && f["kind"] == nil)

        var tags = GeneratedTags()
        tags.format = "newspaper article"
        tags.publicationName = "Tagging Paper"
        tags.recipientLocation = "Tagging Place"
        let url = URL(fileURLWithPath: "/tmp/x.jpg")
        func built(_ obj: [String: Any]?) -> [String: Any] {
            guard let d = SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, itemFields: obj),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return j
        }
        let plain = built(nil)
        check("3 without the call the sidecar is as before", plain["item_fields"] == nil
              && plain["publication_name"] as? String == "Tagging Paper"
              && SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags)
              == SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, itemFields: nil))
        let read = built(o)
        check("3 a read replaces the tagging call's publication and recipient place, the format kept",
              read["item_fields"] != nil && read["publication_name"] == nil && read["recipient_location"] == nil
              && read["format"] as? String == "newspaper article")
        let failed = built(f)
        check("3 a failed call leaves the tagging call's fields", failed["item_fields"] != nil
              && failed["publication_name"] as? String == "Tagging Paper")
    }

    // MARK: 4. End to end

    /// Called from up to six concurrent requests, so every access holds the lock.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var tagging = 0
        /// Per item-field request: the marker, the model, the image count.
        var fields: [(String, String, Int)] = []
        var other = 0
    }

    private static func install(_ wire: Wire) {
        NetworkSession.testTransport = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let message = (body?["messages"] as? [[String: Any]])?.first?["content"]
            let parts = message as? [[String: Any]] ?? []
            let text = (message as? String) ?? (parts.last?["text"] as? String) ?? ""
            let images = parts.filter { $0["type"] as? String == "image_url" }.count
            let marker = ["DOCA", "DOCL"].first { text.contains($0) } ?? ""
            let content: String = wire.lock.withLock {
                if text.contains("You are a metadata tagging assistant") {
                    wire.tagging += 1
                    return marker == "DOCA" ? #"{"year": "1967", "format": "newspaper article", "publication_name": "Tagging Paper"}"#
                        : #"{"year": "1958", "format": "letter", "recipient_location": "Tagging Place"}"#
                }
                if text.contains("You are labelling catalogue fields") {
                    wire.fields.append((marker, body?["model"] as? String ?? "", images))
                    return marker == "DOCA"
                        ? #"{"kind": "newspaper article", "title": "Senate Acts", "byline": ["Mary Jones"], "publication": "The Sun", "publication_date": "1967-03-02", "recipient_place": []}"#
                        : #"{"kind": "letter", "title": null, "byline": [], "publication": null, "publication_date": null, "recipient_place": ["Boston, MA"]}"#
                }
                wire.other += 1
                return "{}"
            }
            let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// A small grey JPEG, so the call has a page image to send.
    private static func writeJPEG(_ url: URL) {
        let w = 40, h = 60
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(gray: 0.7, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func endToEnd() async {
        let fm = FileManager.default
        check("4 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("4 the injected transport is active", false, "stopping before any request")
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APItemFields-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // A: a two-page article · L: a one-page letter.
        let docs: [(String, Int)] = [("A", 2), ("L", 1)]
        func processor(gateway: GatewayConfig?, out: String) -> (OCRProcessor, [String: URL]) {
            let outDir = tmp.appendingPathComponent(out, isDirectory: true)
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let p = OCRProcessor()
            p.taggingMode = .automatic
            p.currentGateway = gateway
            var jobs: [OCRJob] = []
            var files: [URL] = []
            var outputs: [String: URL] = [:]
            var map: [URL: URL] = [:]
            for (name, pages) in docs {
                for page in 0..<pages {
                    let src = tmp.appendingPathComponent("\(out)-\(name)\(page).jpg")
                    writeJPEG(src)
                    files.append(src)
                    var job = OCRJob(sourceURL: src)
                    let cls: DocumentClassification = page == 0 ? .documentStart : .documentContinuation
                    job.result = OCRResult(text: "DOC\(name) page \(page + 1)", classification: cls,
                                           errorMessage: nil, errorCode: nil)
                    job.classification = cls
                    jobs.append(job)
                    let pdf = outDir.appendingPathComponent("\(name)\(page).pdf")
                    fm.createFile(atPath: pdf.path, contents: Data("%PDF-1.4\n%%EOF\n".utf8))
                    map[src] = pdf
                    if page == 0 { outputs[name] = pdf.deletingPathExtension().appendingPathExtension("json") }
                }
            }
            p.jobs = jobs
            p.outputURLMap = map
            p.rebuildSegments(files: files)
            return (p, outputs)
        }
        func json(_ u: URL?) -> [String: Any] {
            guard let u, let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        let gw = GatewayConfig(baseURL: "https://gateway.test/v1", modelID: "some-tagging-model", displayName: "Gateway")
        guard let route = OpenRouterRoute.catalog.first else { check("4 an OpenRouter route", false); return }

        let (g, gOut) = processor(gateway: gw, out: "gateway")
        check("4 two segments", g.segments.count == 2, "\(g.segments.count)")
        await g.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "",
                                    outputDirectory: tmp, enableSegmentJSON: true)
        let calls = wire.lock.withLock { wire.fields }
        check("4 gateway: one item-field call per document, on the measured model, with every page's image",
              calls.count == 2 && calls.allSatisfy { $0.1 == ItemFieldExtractor.gatewayModel }
              && calls.first { $0.0 == "DOCA" }?.2 == 2 && calls.first { $0.0 == "DOCL" }?.2 == 1, "\(calls)")
        let a = json(gOut["A"]), af = a["item_fields"] as? [String: Any] ?? [:]
        check("4 A: the article's fields filled, the title withheld",
              af["status"] as? String == "read" && af["publication"] as? String == "The Sun"
              && af["byline"] as? [String] == ["Mary Jones"] && af["publication_date"] as? String == "1967-03-02"
              && af["title"] == nil && (af["not_filled"] as? [String: String])?["title"] != nil, "\(af)")
        check("4 A: the tagging call's publication left out, its format kept",
              a["publication_name"] == nil && a["format"] as? String == "newspaper article", "\(a.keys.sorted())")
        let lf = json(gOut["L"])["item_fields"] as? [String: Any] ?? [:]
        check("4 L: the letter's recipient place filled", lf["kind"] as? String == "letter"
              && lf["recipient_place"] as? [String] == ["Boston, MA"] && lf["not_filled"] == nil, "\(lf)")

        // No sidecars: no call. A key route the bench did not measure: no call, the sidecar as before.
        wire.lock.withLock { wire.fields = [] }
        let (off, _) = processor(gateway: gw, out: "nosidecar")
        await off.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "",
                                      outputDirectory: tmp, enableSegmentJSON: false)
        check("4 sidecars off: no item-field call", wire.lock.withLock { wire.fields.isEmpty })
        let (key, keyOut) = processor(gateway: nil, out: "key")
        await key.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                      outputDirectory: tmp, enableSegmentJSON: true)
        let ka = json(keyOut["A"])
        check("4 a key route: no item-field call, the tagging call's publication kept",
              wire.lock.withLock { wire.fields.isEmpty } && ka["item_fields"] == nil
              && ka["publication_name"] as? String == "Tagging Paper", "\(ka.keys.sorted())")
    }
}
#endif
