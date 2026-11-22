#if DEBUG // a test driver, compiled out of Release
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ArchiveCore
import PDFKit

/// Headless, key-free ($0) self-test of the item fields (W47.item-fields-build), gated by `ITEM_FIELDS_TEST=1`
/// (`scripts/test-item-fields.sh`). No real network: every request goes to `NetworkSession.testTransport`, and the
/// driver stops before any call if that seam is not active. No Keychain read, no window, never the corpus: the end to
/// end part writes scratch images, PDFs and sidecars under a temporary folder and removes it.
///
///   1. Parsing a reply as the bench does (`item_fields.parse` and `by_definition`), and the marked text.
///   2. The fill policy: which fields fill on which kinds; an all-capitals title in title case on the header.
///   3. The sidecar object, and `SegmentJSONBuilder` with and without it.
///   4. End to end through `performTaggingPhase` on a remote gateway: the call made with the page images and the
///      measured model, its lines in the outputs' page-2 headers; none on a route the bench did not measure, nor with
///      sidecars off.
///   5. The page-2 header lines (SPEC §2-page PDF): written at render time and by the after-the-call rewrite, read
///      back by Core's parser with every other line and the body unchanged.
///   6. The Cost Estimate (W49.proc-fix-s041, suspect S-041): a term for every kind of call part 4's runs made (the
///      dating route's two and the item fields') and none for a kind they did not, and its figures for W40.d1's runs.
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
        headerLines()
        await endToEnd()
        estimateFigures()
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
        check("2 title fills on every kind",
              P.withheld(.title, kind: "newspaper article") == nil && P.withheld(.title, kind: "memo") == nil
              && P.withheld(.title, kind: nil) == nil)
        let cases: [(String, String)] = [
            ("ECONOMICS OF PROGRAMMING PRODUCTION", "Economics of Programming Production"),
            ("ARE OUR UNIVERSITIES LETTING US DOWN?", "Are Our Universities Letting Us Down?"),
            ("THE 100 MOST POWERFUL PEOPLE IN SILICON VALLEY", "The 100 Most Powerful People in Silicon Valley"),
            ("A COLLEGE MYTH: 'PRESTIGE' ISN'T ALWAYS THE KEY", "A College Myth: 'Prestige' Isn't Always the Key"),
            ("ASIAN-AMERICAN RATES AND THE U.S. TV PART II", "Asian-American Rates and the U.S. TV Part II"),
            ("CORPORATE CULTURE: THE HARD VALUES", "Corporate Culture: The Hard Values"),
            ("LETTERS TO THE", "Letters to The"),
            ("How Harvard Finds Freshmen In a Deluge", "How Harvard Finds Freshmen In a Deluge"),
            ("CORPORATE CULTURE The hard-to-change values", "CORPORATE CULTURE The hard-to-change values"),
            ("1979", "1979"),
            ("MCGOVERN AND O'BRIEN ON THE FBI AND AFL-CIO", "McGovern and O'Brien on the FBI and AFL-CIO"),
            ("U.S.-SOVIET TRADE—AND MORE", "U.S.-Soviet Trade—And More"),
            ("MY WAY: MIX", "My Way: Mix"),
            ("", ""), ("- —", "- —"),
        ]
        for (read, shown) in cases {
            let got = ItemFieldResult.titleCased(read)
            check("2 title case: \(read)", got == shown, got)
        }
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
        check("3 the title is written as read, nothing withheld", o["title"] as? String == "A Headline"
              && o["not_filled"] == nil)
        check("3 the filled fields' quotes are written",
              (o["quotes"] as? [String: String]) == ["title": "A Headline", "byline": "John Smith"])
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
        check("3 a read replaces the tagging call's publication, the format kept; off correspondence its place stays",
              read["item_fields"] != nil && read["publication_name"] == nil
              && read["recipient_location"] as? String == "Tagging Place"
              && read["format"] as? String == "newspaper article")
        let letterRead = built(ItemFieldResult(route: "g", outcome: .read(.init(kind: "letter", recipientPlace: ["Boston, MA"])))
            .sidecarObject)
        check("3 on a letter the item call's recipient place replaces the tagging call's",
              letterRead["recipient_location"] == nil
              && (letterRead["item_fields"] as? [String: Any])?["recipient_place"] as? [String] == ["Boston, MA"])
        let failed = built(f)
        check("3 a failed call leaves the tagging call's fields", failed["item_fields"] != nil
              && failed["publication_name"] as? String == "Tagging Paper")
    }

    // MARK: 5. The page-2 header lines

    private static func headerLines() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("APItemHeader-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard let model = OpenRouterRoute.catalog.first?.model else { check("5 a model", false); return }
        let image = tmp.appendingPathComponent("scan_001.jpg")
        writeJPEG(image)
        let text = "SENATE ACTS\nBy Mary Jones\n\nThe Senate passed the bill."
        let result = OCRResult(text: text, classification: .documentStart, errorMessage: nil, errorCode: nil)
        let pdf = tmp.appendingPathComponent("scan_001.pdf")
        _ = try? PDFGenerator().generate(imageURL: image, result: result, model: model, outputURL: pdf,
                                         originalFileName: "scan_001.jpg",
                                         sourceDates: PDFSourceDates(documentDate: "1967"), pageKind: .printed)
        guard let original = try? Data(contentsOf: pdf),
              let oldHeader = PDFDocument(data: original)?.page(at: 1).map({ PDFHeaderParser.parse($0) })?.header else {
            check("5 a generated pair", false); return
        }
        let fields = ItemFieldResult(route: "g", outcome: .read(.init(
            kind: "newspaper article", title: "SENATE ACTS", byline: ["Mary Jones", "John Smith"], publication: "The Sun",
            publicationDate: "1967-03-02"))).headerFields
        check("5 the header fields: the filled ones, the byline joined, the title in title case",
              fields == PDFItemFields(documentKind: "newspaper article", title: "Senate Acts",
                                      byline: "Mary Jones; John Smith",
                                      publication: "The Sun", publicationDate: "1967-03-02"), "\(fields)")
        let gen = PDFGenerator()
        let headerFields = PDFSourceDates(documentDate: "1967", dateEvidence: "image; page 1", itemFields: fields)
        guard case .rewrite(let added) = gen.taggedHeaderRewrite(of: original, sourceName: "scan_001.jpg", fields: headerFields,
                                                                body: text, textColumns: 1) else {
            check("5 the rewrite adds the lines", false); return
        }
        let back = PDFDocument(data: added)?.page(at: 1).map { PDFHeaderParser.parse($0) }
        var expected = oldHeader
        expected.dateEvidence = "image; page 1"
        expected.itemFields = fields
        check("5 the rewrite adds them after the evidence line; every other line and the body read back unchanged",
              back?.header == expected && PDFGenerator.squashed(back?.body ?? "") == PDFGenerator.squashed(text)
              && back?.header?.documentDate == "1967", "\(String(describing: back))")
        check("5 the same lines again: unchanged",
              gen.taggedHeaderRewrite(of: added, sourceName: "scan_001.jpg", fields: headerFields, body: text,
                                      textColumns: 1) == .unchanged)
        if case .rewrite(let removed) = gen.taggedHeaderRewrite(of: added, sourceName: "scan_001.jpg", fields: PDFSourceDates(documentDate: "1967"),
                                                             body: text, textColumns: 1) {
            check("5 none removes stale lines", PDFDocument(data: removed)?.page(at: 1)
                    .map { PDFHeaderParser.parse($0) }?.header == oldHeader)
        } else { check("5 none removes stale lines", false) }
        let long = PDFItemFields(documentKind: "report", publication: PDFItemFields.lineValue(String(repeating: "Long ", count: 40)))
        if case .rewrite(let l) = gen.taggedHeaderRewrite(of: original, sourceName: "scan_001.jpg",
                                                         fields: PDFSourceDates(documentDate: "1967", itemFields: long), body: text,
                                                          textColumns: 2) {
            let lp = PDFDocument(data: l)?.page(at: 1).map { PDFHeaderParser.parse($0) }
            check("5 a long value is fitted to one line and reads back whole (two text columns)",
                  lp?.header?.itemFields == long && PDFGenerator.squashed(lp?.body ?? "") == PDFGenerator.squashed(text),
                  "\(String(describing: lp?.header?.itemFields))")
        } else { check("5 a long value is fitted to one line and reads back whole (two text columns)", false) }
        if case .skipped = gen.taggedHeaderRewrite(of: original, sourceName: "scan_002.jpg", fields: headerFields,
                                                   body: text, textColumns: 1) {
            check("5 a header that names another file is left alone", true)
        } else { check("5 a header that names another file is left alone", false) }

        // W40.fix-processor-evidence-rewrite-name: a source name with a U+00A0, as the RG 165 photos have. PDFKit reads
        // it back as a space, so the script reads the name's characters with pypdf and checks the file with qpdf
        // (`ITEM_FIELDS_TEST_KEEP`); here, the file is written as `generate` writes one.
        let nbspName = "00009 \u{2014}\u{00A0}RG 165.jpg"
        let nbsp = tmp.appendingPathComponent("nbsp.pdf")
        _ = try? PDFGenerator().generate(imageURL: image, result: result, model: model, outputURL: nbsp,
                                         originalFileName: nbspName,
                                         sourceDates: PDFSourceDates(documentDate: "1918"), pageKind: .printed)
        if let data = try? Data(contentsOf: nbsp),
           case .rewrite(let dated) = gen.taggedHeaderRewrite(of: data, sourceName: nbspName,
                                                            fields: PDFSourceDates(documentDate: "1918", dateEvidence: "image; page 1", itemFields: fields),
                                                            body: text, textColumns: 1) {
            let bytes = String(decoding: dated, as: UTF8.self)
            let back = PDFDocument(data: dated)?.page(at: 1).map { PDFHeaderParser.parse($0) }?.header
            check("5 a U+00A0 name: rewritten with both kinds of line, as PDF/A, with no unwritten object",
                  back?.dateEvidence == "image; page 1" && back?.itemFields == fields
                  && bytes.contains("<pdfaid:part>2</pdfaid:part>") && !bytes.contains("0000000000 00000 n"),
                  "\(String(describing: back))")
            if let keep = ProcessInfo.processInfo.environment["ITEM_FIELDS_TEST_KEEP"] {
                let dir = URL(fileURLWithPath: keep, isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: dir.appendingPathComponent("nbsp-original.pdf"))
                try? dated.write(to: dir.appendingPathComponent("nbsp-dated.pdf"))
                try? Data(nbspName.utf8).write(to: dir.appendingPathComponent("nbsp-name.txt"))
            }
        } else { check("5 a U+00A0 name: rewritten with both kinds of line, as PDF/A, with no unwritten object", false) }

        // At render time (Live Capture's path): the lines after the source dates.
        let live = tmp.appendingPathComponent("live.pdf")
        var dates = PDFSourceDates(documentDate: "1958")
        dates.itemFields = PDFItemFields(documentKind: "letter", recipientPlace: "Boston, MA")
        _ = try? PDFGenerator().generate(imageURL: image, result: result, model: model, outputURL: live,
                                         originalFileName: "scan_001.jpg", sourceDates: dates, pageKind: .typewritten)
        let lh = PDFDocument(url: live)?.page(at: 1).map { PDFHeaderParser.parse($0) }
        check("5 render time: the lines read back after the document date, the body whole",
              lh?.header?.itemFields == dates.itemFields && lh?.header?.documentDate == "1958"
              && PDFGenerator.squashed(lh?.body ?? "") == PDFGenerator.squashed(text), "\(String(describing: lh))")
    }

    // MARK: 4. End to end

    /// Called from up to six concurrent requests, so every access holds the lock.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var tagging = 0
        /// Per item-field request: the marker, the model, the image count.
        var fields: [(String, String, Int)] = []
        /// The dating route's trace and image calls (`DateRoute.run`).
        var trace = 0
        var image = 0
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
                        ? #"{"kind": "newspaper article", "title": "SENATE ACTS ON THE BUDGET", "byline": ["Mary Jones"], "publication": "The Sun", "publication_date": "1967-03-02", "recipient_place": []}"#
                        : #"{"kind": "letter", "title": null, "byline": [], "publication": null, "publication_date": null, "recipient_place": ["Boston, MA"]}"#
                }
                if text.contains("You are dating a document") { wire.trace += 1 }
                else if text.contains("These are the first pages of one archival document") { wire.image += 1 }
                else { wire.other += 1 }
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
                    // A real pair, so the header lines can be checked on the written file.
                    if let model = OpenRouterRoute.catalog.first?.model, let result = job.result {
                        _ = try? PDFGenerator().generate(imageURL: src, result: result, model: model, outputURL: pdf,
                                                         originalFileName: src.lastPathComponent)
                    }
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
        let fileCount = docs.reduce(0) { $0 + $1.1 }
        /// Part 6: the run's calls by kind against the estimate for its settings, then the counts cleared.
        func estimateCovers(_ label: String, gateway: GatewayConfig?, sidecars: Bool) {
            let (trace, image, fields) = wire.lock.withLock { (wire.trace, wire.image, wire.fields.count) }
            wire.lock.withLock { wire.trace = 0; wire.image = 0 }
            let measured = DateRoute.measuredRoute(gateway: gateway, usesLocalAgent: false)
            let e = CostEstimator.estimate(fileCount: fileCount, model: route.model, enableTagging: true,
                                           sendPreviousImage: false, contextCharCount: 0, useGateway: gateway != nil,
                                           measuredRoute: measured, sidecars: sidecars)
            let docs = CostEstimator.estimatedDocuments(fileCount)
            let traceTerm = measured ? docs * CostEstimator.gatewayDateTraceCallCost
                : docs * (CostEstimator.estimatedDateTraceInputTokens * route.model.inputCostPer1M
                          + CostEstimator.estimatedDateTraceOutputTokens * route.model.outputCostPer1M) / 1_000_000
            let imageTerm = measured ? docs * CostEstimator.dateImageShare * CostEstimator.gatewayDateImageCallCost : 0
            check("6 \(label): the trace call made (\(trace)) is priced", trace > 0 && traceTerm > 0,
                  "\(trace) \(traceTerm)")
            check("6 \(label): an image pass made (\(image)) has its term, none where none is made",
                  (image > 0) == (imageTerm > 0) && abs(e.datingCost - traceTerm - imageTerm) < 1e-12,
                  "\(image) \(e.datingCost) \(traceTerm) \(imageTerm)")
            check("6 \(label): an item-field call made (\(fields)) has its term, none where none is made",
                  (fields > 0) == (e.itemFieldCost > 0)
                  && (fields == 0 || abs(e.itemFieldCost - Double(fileCount) * CostEstimator.gatewayItemFieldPageCost) < 1e-12),
                  "\(fields) \(e.itemFieldCost)")
            check("6 \(label): both are in the total", abs(e.totalStandard - e.ocrCost - e.classificationCost - e.taggingCost
                  - e.collectionCost - e.rotationCost - e.datingCost - e.itemFieldCost) < 1e-12)
        }

        let (g, gOut) = processor(gateway: gw, out: "gateway")
        check("4 two segments", g.segments.count == 2, "\(g.segments.count)")
        await g.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "",
                                    outputDirectory: tmp, enableSegmentJSON: true)
        let calls = wire.lock.withLock { wire.fields }
        estimateCovers("gateway", gateway: gw, sidecars: true)
        check("4 gateway: one item-field call per document, on the measured model, with every page's image",
              calls.count == 2 && calls.allSatisfy { $0.1 == ItemFieldExtractor.gatewayModel }
              && calls.first { $0.0 == "DOCA" }?.2 == 2 && calls.first { $0.0 == "DOCL" }?.2 == 1, "\(calls)")
        let a = json(gOut["A"]), af = a["item_fields"] as? [String: Any] ?? [:]
        check("4 A: the article's fields filled, the title as read",
              af["status"] as? String == "read" && af["publication"] as? String == "The Sun"
              && af["byline"] as? [String] == ["Mary Jones"] && af["publication_date"] as? String == "1967-03-02"
              && af["title"] as? String == "SENATE ACTS ON THE BUDGET" && af["not_filled"] == nil, "\(af)")
        check("4 A: the tagging call's publication left out, its format kept",
              a["publication_name"] == nil && a["format"] as? String == "newspaper article", "\(a.keys.sorted())")
        func header(_ name: String) -> PDFPageHeader? {
            guard let u = gOut[name]?.deletingPathExtension().appendingPathExtension("pdf"),
                  let page = PDFDocument(url: u)?.page(at: 1) else { return nil }
            return PDFHeaderParser.parse(page).header
        }
        let ah = header("A"), a1 = PDFDocument(url: tmp.appendingPathComponent("gateway/A1.pdf"))?.page(at: 1)
            .flatMap { PDFHeaderParser.parse($0).header }
        check("4 A: both pages' headers carry the filled fields, the title in title case",
              ah?.itemFields == PDFItemFields(documentKind: "newspaper article", title: "Senate Acts on the Budget",
                                              byline: "Mary Jones",
                                              publication: "The Sun", publicationDate: "1967-03-02")
              && a1?.itemFields == ah?.itemFields && ah?.originalFilename == "gateway-A0.jpg",
              "\(String(describing: ah)) \(String(describing: a1))")
        check("4 L: the letter's header carries its kind and recipient place",
              header("L")?.itemFields == PDFItemFields(documentKind: "letter", recipientPlace: "Boston, MA"))
        let lf = json(gOut["L"])["item_fields"] as? [String: Any] ?? [:]
        check("4 L: the letter's recipient place filled", lf["kind"] as? String == "letter"
              && lf["recipient_place"] as? [String] == ["Boston, MA"] && lf["not_filled"] == nil, "\(lf)")

        // No sidecars: no call. A key route the bench did not measure: no call, the sidecar as before.
        wire.lock.withLock { wire.fields = [] }
        let (off, _) = processor(gateway: gw, out: "nosidecar")
        await off.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "",
                                      outputDirectory: tmp, enableSegmentJSON: false)
        check("4 sidecars off: no item-field call", wire.lock.withLock { wire.fields.isEmpty })
        estimateCovers("sidecars off", gateway: gw, sidecars: false)
        let (key, keyOut) = processor(gateway: nil, out: "key")
        await key.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                      outputDirectory: tmp, enableSegmentJSON: true)
        estimateCovers("a key route", gateway: nil, sidecars: true)
        let ka = json(keyOut["A"])
        let keyHeader = PDFDocument(url: tmp.appendingPathComponent("key/A0.pdf"))?.page(at: 1)
            .flatMap { PDFHeaderParser.parse($0).header }
        check("4 a key route: no item-field lines", keyHeader != nil && keyHeader?.itemFields.isEmpty == true)
        check("4 a key route: no item-field call, the tagging call's publication kept",
              wire.lock.withLock { wire.fields.isEmpty } && ka["item_fields"] == nil
              && ka["publication_name"] as? String == "Tagging Paper", "\(ka.keys.sorted())")
    }

    // MARK: 6. The Cost Estimate's figures

    /// W40.d1's two runs of the 113-photo RG 165 box (`verification/evidence/processor/W40.d1-bulk-ocr.md`), with the
    /// inputs its `estimate.txt` used. The stand-in run made 57 trace, 57 image and 57 item-field calls that the
    /// estimate had no term for; the paid OpenRouter run made 41 trace calls, metered at most $0.1056 in all.
    private static func estimateFigures() {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        let docs = 113.0 / 3
        // On the measured route the two terms are the bench's per-call figures, whatever the run's own model.
        if let flash = LLMModel.geminiModels.first {
            let g = CostEstimator.estimate(fileCount: 113, model: flash, enableTagging: true, sendPreviousImage: false,
                                           contextCharCount: 0, useGateway: true, imageTokenProvider: .gemini,
                                           measuredRoute: true, sidecars: true)
            check("6 the stand-in run: the dating route's calls, the image pass on 32%",
                  near(g.datingCost, docs * (0.00220 + 0.32 * 0.00284)), g.datingFormatted)
            check("6 the stand-in run: the item fields by the page", near(g.itemFieldCost, 113 * 1.00 / 627),
                  g.itemFieldFormatted)
            check("6 dating and item fields are never batched", near(g.totalBatch - g.batchOcrCost,
                                                                     g.totalStandard - g.ocrCost))
            let every = CostEstimator.estimate(fileCount: 113, model: flash, enableTagging: true, sendPreviousImage: false,
                                               contextCharCount: 0, useGateway: true, measuredRoute: true,
                                               dateImageEveryDocument: true, sidecars: true)
            check("6 image on every document: the image pass on each", near(every.datingCost, docs * (0.00220 + 0.00284)))
            let none = CostEstimator.estimate(fileCount: 113, model: flash, enableTagging: false, sendPreviousImage: false,
                                              contextCharCount: 0, useGateway: true, measuredRoute: true, sidecars: true)
            check("6 no tagging: no dating or item-field call", none.datingCost == 0 && none.itemFieldCost == 0)
        } else {
            check("6 a Gemini model", false)
        }
        guard let qwen = OpenRouterRoute.forModel("qwen/qwen3.8-flash")?.model else {
            check("6 the paid run's model", false); return
        }
        let p = CostEstimator.estimate(fileCount: 113, model: qwen, enableTagging: true, sendPreviousImage: false,
                                       contextCharCount: 0)
        check("6 the paid run: OCR and tagging as its estimate.txt", p.ocrFormatted == "$0.1146"
              && p.taggingFormatted == "$0.0120", "\(p.ocrFormatted) \(p.taggingFormatted)")
        check("6 the paid run: the trace call on its own model, no image pass or item fields",
              near(p.datingCost, docs * (2000 * 0.15 + 300 * 0.47) / 1_000_000) && p.itemFieldCost == 0, p.datingFormatted)
        check("6 the paid run: the estimate stays above the metered $0.1056", p.totalStandard >= 0.1056,
              p.totalStandardFormatted)
    }
}
#endif
