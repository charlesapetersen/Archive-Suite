#if DEBUG // a test driver, compiled out of Release
import Foundation
import ArchiveCore
import CoreGraphics
import ImageIO

/// Headless, key-free ($0) self-test of the dating route (W46.date-route), gated by `DATE_ROUTE_TEST=1`
/// (`scripts/test-date-route.sh`). No real network: every request goes to `NetworkSession.testTransport`, and the driver
/// stops before any call if that seam is not active. No Keychain read, no window, never the corpus: the end to end part
/// writes scratch images, PDFs and sidecars under a temporary folder and removes it.
///
///   1. The bench's cases (`segbench/fixtures/date-route-cases.json`, path in `DATE_ROUTE_CASES`; written by
///      `segbench/date_route_cases.py`): rule candidates and pick, the trace prompt byte for byte, the parsed reply, the
///      evidence check, the image reading and the route. `DATE_ROUTE_REAL_CASES` adds the same check on every
///      W46.date-route-pipeline document (the private bench cache; skipped when absent).
///   2. The decision on the tags and the sidecar object.
///   3. End to end through `performTaggingPhase` on scratch outputs: a remote gateway (the measured route, image pass on
///      the no-year documents only, then on every document with the switch on) and a direct key (no image pass).
private extension DateRoute.Decision {
    func with(measured: Bool) -> Self { var d = self; d.measured = measured; d.route = "r"; return d }
}

@MainActor
enum DateRouteTestDriver {
    nonisolated static let envKey = "DATE_ROUTE_TEST"
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
        let env = ProcessInfo.processInfo.environment
        cases(path: env["DATE_ROUTE_CASES"], label: "1", required: true)
        if let real = env["DATE_ROUTE_REAL_CASES"], FileManager.default.fileExists(atPath: real) {
            cases(path: real, label: "1r", required: true, summarize: true)
        } else {
            lines.append("SKIP: 1r the pipeline's own documents (DATE_ROUTE_REAL_CASES not present)")
        }
        decision()
        await endToEnd()
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = env["DATE_ROUTE_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1. The bench's cases

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber).map(\.intValue) }

    private static func cases(path: String?, label: String, required: Bool, summarize: Bool = false) {
        guard let path, let data = FileManager.default.contents(atPath: path),
              let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !all.isEmpty else {
            check("\(label) the bench's cases load", !required, path ?? "no path")
            return
        }
        var bad: [String: Int] = [:]
        var firstBad: [String: String] = [:]
        func note(_ part: String, _ id: String, _ ok: Bool, _ detail: String) {
            if summarize {
                if !ok { bad[part, default: 0] += 1; if firstBad[part] == nil { firstBad[part] = "\(id): \(detail)" } }
            } else {
                check("\(label) \(id): \(part)", ok, detail)
            }
        }
        for c in all {
            let id = c["id"] as? String ?? "?"
            let input = c["input"] as? [String: Any] ?? [:], want = c["expect"] as? [String: Any] ?? [:]
            let text = input["text"] as? String ?? ""
            let near = (input["near"] as? [[String: Any]] ?? []).map {
                DateRoute.Neighbour(label: $0["label"] as? String ?? "", dist: int($0["dist"]) ?? 0,
                                    text: $0["text"] as? String ?? "", file: nil)
            }
            let traceRaw = input["trace_raw"] as? String, imageRaw = input["image_raw"] as? String

            let cands = DateRoute.candidates(text)
            let got = cands.map { "\($0.year)|\($0.month.map(String.init) ?? "-")|\($0.kind)|\($0.lineNo)|\($0.line)" }
            let wantC = (want["candidates"] as? [[Any]] ?? []).map { a in
                "\(int(a[0]) ?? -1)|\(int(a[1]).map(String.init) ?? "-")|\(a[2])|\(int(a[3]) ?? -1)|\(a[4])"
            }
            note("candidates", id, got == wantC, "got \(got.prefix(4)) want \(wantC.prefix(4))")
            let pick = DateRoute.rulePick(cands)
            let wp = want["pick"] as? [Any] ?? []
            note("rule pick", id, pick?.year == int(wp.first) && DateRoute.pickMonth(pick) == int(wp.last),
                 "got \(pick?.year ?? -1)/\(DateRoute.pickMonth(pick) ?? -1)")
            let prompt = DateRoute.tracePrompt(text: text, near: near)
            let wantPrompt = want["prompt"] as? String ?? ""
            note("trace prompt byte for byte", id, prompt == wantPrompt,
                 "first difference at \(zip(prompt, wantPrompt).prefix { $0 == $1 }.count)")
            let tr = DateRoute.parseTrace(traceRaw), wt = want["trace"] as? [String: Any] ?? [:]
            note("parsed reply", id, tr.parsed == (wt["parsed"] as? Bool) && tr.year == int(wt["year"])
                 && tr.lo == int(wt["lo"]) && tr.hi == int(wt["hi"]) && tr.uncertain == (wt["uncertain"] as? Bool),
                 "got \(tr)")
            let chk = tr.parsed ? DateRoute.evidenceCheck(year: tr.year, evidence: tr.evidence,
                                                          context: DateRoute.context(text: text, near: near))
                : DateRoute.Check(verdict: "none", reason: "unparsed")
            let wc = want["check"] as? [String] ?? []
            note("evidence check", id, [chk.verdict, chk.reason] == wc, "got \(chk) want \(wc)")
            var image: DateRoute.ImageReading? = nil
            if let imageRaw {
                let r = DateRoute.readImage(imageRaw)
                image = r
                let wi = want["image"] as? [String: Any] ?? [:]
                note("image reading", id, r.ok == (wi["ok"] as? Bool) && r.ownYear == int(wi["own"])
                     && r.secondRole.count == int(wi["stamps"]),
                     "got ok \(r.ok) own \(r.ownYear ?? -1) stamps \(r.secondRole.count)")
            }
            // The route is sent the image only where the text has no candidate, as the bench sent it.
            let sent = cands.isEmpty ? image : nil
            let d = DateRoute.decide(text: text, near: near, traceRaw: traceRaw, image: sent, imageNote: "")
            let wr = want["route"] as? [String: Any] ?? [:]
            note("route", id, d.year == int(wr["year"]) && d.evidenceClass.rawValue == wr["cls"] as? String
                 && d.step == int(wr["step"]) && d.dateUncertain == (wr["du"] as? Bool),
                 "got \(d.year ?? -1) \(d.evidenceClass) \(d.step ?? -1) du \(d.dateUncertain) want \(wr)")
        }
        if summarize {
            for part in ["candidates", "rule pick", "trace prompt byte for byte", "parsed reply", "evidence check",
                         "image reading", "route"] {
                check("\(label) \(part) on the pipeline's \(all.count) documents", bad[part] == nil,
                      "\(bad[part] ?? 0) differ; first \(firstBad[part] ?? "")")
            }
        }
    }

    // MARK: 2. The decision on the tags and the sidecar

    private static func decision() {
        let near = [DateRoute.Neighbour(label: "P1", dist: 1, text: "Memo\nJune 2, 1957\nfile", file: "P1.pdf")]
        let letter = "Washington\nMarch 3, 1947\nDear Sir"
        let explicit = DateRoute.decide(text: letter, near: near, traceRaw: #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
                                        image: nil, imageNote: DateRoute.imageNotNeeded)
        var t = GeneratedTags(year: "1947", month: "03 March", day: "Day 3", dateUncertain: true)
        explicit.apply(to: &t)
        check("2 explicit text year: the tagging call's month and day kept when it read the same year, no flag",
              t.year == "1947" && t.month == "03 March" && t.day == "Day 3" && !t.dateUncertain)
        var t2 = GeneratedTags(year: "1950", month: "05 May", day: "Day 9")
        explicit.apply(to: &t2)
        check("2 explicit text year: another year's month and day replaced by the dated form's month",
              t2.year == "1947" && t2.month == "03 March" && t2.day == nil, "\(t2.allTags)")
        let o = explicit.with(measured: true).sidecarObject()
        check("2 sidecar, explicit: class, step, the quote and its line", o["class"] as? String == "text"
              && o["step"] as? Int == 1 && o["quote"] as? String == "March 3, 1947" && o["line"] as? Int == 2
              && o["interval_90"] == nil && o["image_pass"] as? String == DateRoute.imageNotNeeded)

        let memo = "MEMO\nTo: Files"
        let est = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "lo": 1956, "hi": 1958, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "June 2, 1957"}}"#,
                                   image: nil, imageNote: DateRoute.imageNoRoute)
        var t3 = GeneratedTags(year: "1957", month: "06 June", day: "Day 2")
        est.apply(to: &t3)
        check("2 estimate: the year with Date Uncertain, never a month or day", t3.year == "1957" && t3.dateUncertain
              && t3.month == nil && t3.day == nil)
        let eo = est.with(measured: true).sidecarObject()
        let iv = eo["interval_90"] as? [String: Any] ?? [:]
        check("2 sidecar, estimate: the neighbour's file, the check and the measured interval",
              eo["class"] as? String == "estimate" && eo["source"] as? String == "P1.pdf"
              && eo["quote"] as? String == "June 2, 1957" && iv["lo"] as? Int == 1956 && iv["hi"] as? Int == 1958
              && iv["measured"] != nil && (eo["check"] as? String)?.hasPrefix("quote found") == true)
        check("2 sidecar, estimate on an unmeasured route: no interval",
              est.with(measured: false).sidecarObject()["interval_90"] == nil)

        let failed = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "lo": 1957, "hi": 1957, "evidence": {"neighbour": "P1", "quote": "July 9, 1957"}}"#,
                                      image: nil, imageNote: DateRoute.imageNoRoute)
        var t4 = GeneratedTags(year: "1957", dateUncertain: false)
        failed.apply(to: &t4)
        let fo = failed.with(measured: true).sidecarObject()
        check("2 an estimate whose evidence fails: no year written, Date Uncertain, nothing of it shown",
              t4.year == nil && t4.dateUncertain && fo["class"] as? String == "none" && fo["quote"] == nil
              && fo["interval_90"] == nil && fo["reason"] as? String == "no year with checked evidence")

        var inherited = failed
        inherited.inherit(fromCover: GeneratedTags(year: "1958", month: "03 March"), coverFile: "L.pdf")
        var t5 = GeneratedTags()
        inherited.apply(to: &t5)
        check("2 step 3a: an enclosure with no own date takes the cover's year, Date Uncertain, no month",
              t5.year == "1958" && t5.dateUncertain && t5.month == nil
              && inherited.with(measured: true).sidecarObject()["source"] as? String == "L.pdf")
        var keeps = explicit
        keeps.inherit(fromCover: GeneratedTags(year: "1958"), coverFile: "L.pdf")
        check("2 step 3a: an enclosure's own explicit date wins", keeps.year == 1947 && keeps.evidenceClass == .text)

        let flagged = DateRoute.decide(text: letter, near: near, traceRaw: #"{"year": 1947, "date_uncertain": true, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
                                       image: nil, imageNote: "")
        check("2 owner call (a): the model's flag adds Date Uncertain to an explicit text year, the year kept",
              flagged.year == 1947 && flagged.dateUncertain && flagged.evidenceClass == .text
              && flagged.with(measured: true).sidecarObject()["uncertain_because"] != nil)

        let img = DateRoute.readImage(#"{"dates": [{"quote": "RECEIVED APR 4 1961", "page": 1, "where": "stamp", "kind": "stamped", "year": 1961}, {"quote": "March 30, 1961", "page": 1, "where": "dateline", "kind": "typed", "year": 1961, "month": 3}], "document_date": {"year": 1961, "month": 3, "quote": "March 30, 1961"}}"#)
        let byImage = DateRoute.decide(text: memo, near: [], traceRaw: nil, image: img, imageNote: DateRoute.imageSent)
        var t6 = GeneratedTags()
        byImage.apply(to: &t6)
        let io = byImage.with(measured: true).sidecarObject()
        let roles = io["second_role_dates"] as? [[String: Any]] ?? []
        check("2 image: the document's own quoted date, its month, no flag; the stamp kept as a second-role date",
              t6.year == "1961" && t6.month == "03 March" && !t6.dateUncertain && io["class"] as? String == "image"
              && io["quote"] as? String == "March 30, 1961" && io["where"] as? String == "dateline"
              && roles.count == 1 && roles[0]["quote"] as? String == "RECEIVED APR 4 1961" && roles[0]["role"] as? String == "stamp")

        let url = URL(fileURLWithPath: "/scratch/page1.jpg")
        let tags = GeneratedTags(year: "1958", subjectTags: ["Harbours"], format: "letter")
        check("2 no dating object: the sidecar is unchanged",
              SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags)
              == SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, dating: nil))
        let withData = SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, dating: o) ?? Data()
        let w = (try? JSONSerialization.jsonObject(with: withData) as? [String: Any]) ?? [:]
        check("2 with a dating object: written beside the date", (w["dating"] as? [String: Any])?["class"] as? String == "text"
              && w["date"] as? String == "1958")
    }

    // MARK: 3. End to end

    /// Called from up to six concurrent requests, so every access holds the lock.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var tagging = 0
        var trace: [String] = []
        /// The image calls by the documents' page widths, and the model each call asked for.
        var images: [[Int]] = []
        var models: Set<String> = []
        var taggingReply: [String: String] = [:]
        var traceReply: [String: String] = [:]
        var imageReply: [Int: String] = [:]
        /// The gateway does not serve the measured model: a 404 for it.
        var refuseMeasured = false
    }

    nonisolated private static let markers = ["DOCA", "DOCE", "DOCB", "DOCC", "DOCD"]

    private static func install(_ wire: Wire) {
        NetworkSession.testTransport = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let message = (body?["messages"] as? [[String: Any]])?.first
            let refused = wire.lock.withLock { wire.refuseMeasured && body?["model"] as? String == DateRoute.gatewayModel }
            if refused {
                return (Data(#"{"error": "model not found"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            let content: String = wire.lock.withLock {
                if let model = body?["model"] as? String { wire.models.insert(model) }
                if let parts = message?["content"] as? [[String: Any]] {
                    let widths = parts.compactMap { p -> Int? in
                        guard let u = (p["image_url"] as? [String: Any])?["url"] as? String,
                              let b64 = u.components(separatedBy: "base64,").last, let d = Data(base64Encoded: b64),
                              let src = CGImageSourceCreateWithData(d as CFData, nil),
                              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                        return props[kCGImagePropertyPixelWidth] as? Int
                    }
                    wire.images.append(widths)
                    return wire.imageReply[widths.first ?? 0] ?? "{}"
                }
                let prompt = message?["content"] as? String ?? ""
                let marker = markers.compactMap { m in prompt.range(of: m).map { (m, $0.lowerBound) } }
                    .min { $0.1 < $1.1 }?.0 ?? ""
                if prompt.contains("You are a metadata tagging assistant") {
                    wire.tagging += 1
                    return wire.taggingReply[marker] ?? "{}"
                }
                if prompt.hasPrefix("You are dating a document") {
                    wire.trace.append(marker)
                    return wire.traceReply[marker] ?? "no"
                }
                return "unexpected"
            }
            let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func writeJPEG(_ url: URL, width: Int) {
        guard let ctx = CGContext(data: nil, width: width, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 60))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func endToEnd() async {
        let fm = FileManager.default
        check("3 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("3 the injected transport is active", false, "stopping before any request")
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APDateRoute-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // In folder order: A, a letter with its date in the text · E, an enclosure of A with no date of its own ·
        // B, no year in the text, dated on the page image · C, no year anywhere, a neighbour's date with checked
        // evidence · D, no year, an estimate whose quote is not in the neighbour. Each page's width names its document.
        let texts = ["DOCA Washington\nMarch 3, 1947\nDear Mr. Hale:", "DOCE Enclosed: the list",
                     "DOCB MEMORANDUM\nTo: Files", "DOCC Note to the files", "DOCD Another note"]
        let widths = [110, 150, 120, 130, 140]
        let anyYear = #"{"year": "1950", "month": "05 May", "day": "Day 9", "date_uncertain": false, "format": "memo"}"#
        wire.taggingReply = Dictionary(uniqueKeysWithValues: markers.map { ($0, anyYear) })
        wire.taggingReply["DOCA"] = #"{"year": "1947", "month": "03 March", "day": "Day 3", "date_uncertain": false, "format": "letter"}"#
        wire.traceReply = [
            "DOCA": #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
            "DOCB": #"{"year": 1947, "lo": 1946, "hi": 1948, "date_uncertain": true, "evidence": {"neighbour": "P2", "quote": "March 3, 1947"}}"#,
            "DOCC": #"{"year": 1947, "lo": 1946, "hi": 1949, "date_uncertain": true, "evidence": {"neighbour": "P3", "quote": "March 3, 1947"}}"#,
            "DOCD": #"{"year": 1951, "lo": 1950, "hi": 1952, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "June 1951"}}"#,
            "DOCE": "I cannot tell.",
        ]
        wire.imageReply = [120: #"{"dates": [{"quote": "RECEIVED APR 4 1961", "page": 1, "where": "stamp", "kind": "stamped", "year": 1961}, {"quote": "March 30, 1961", "page": 1, "where": "dateline", "kind": "typed", "year": 1961, "month": 3}], "document_date": {"year": 1961, "month": 3, "quote": "March 30, 1961"}}"#,
                           110: #"{"dates": [{"quote": "Rec'd MAR 9 1947", "page": 1, "where": "stamp", "kind": "stamped", "year": 1947}], "document_date": {"year": 1947, "quote": "March 3, 1947"}}"#]

        func processor(gateway: GatewayConfig?, out: String, imageEvery: Bool = false) -> (OCRProcessor, [URL], [String: URL]) {
            let outDir = tmp.appendingPathComponent(out, isDirectory: true)
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let p = OCRProcessor()
            p.taggingMode = .automatic
            p.currentGateway = gateway
            let files = markers.map { tmp.appendingPathComponent("\(out)-\($0).jpg") }
            for (i, f) in files.enumerated() { writeJPEG(f, width: widths[i]) }
            p.jobs = texts.enumerated().map { i, t in
                var job = OCRJob(sourceURL: files[i])
                job.result = OCRResult(text: t, classification: .documentStart, errorMessage: nil, errorCode: nil,
                                       enclosure: i == 1)
                job.classification = .documentStart
                return job
            }
            var outputs: [String: URL] = [:]
            var map: [URL: URL] = [:]
            for (i, m) in markers.enumerated() {
                let pdf = outDir.appendingPathComponent("\(m).pdf")
                fm.createFile(atPath: pdf.path, contents: Data("%PDF-1.4\n%%EOF\n".utf8))
                outputs[m] = pdf.deletingPathExtension().appendingPathExtension("json")
                map[files[i]] = pdf
            }
            p.outputURLMap = map
            p.rebuildSegments(files: files)
            p.activeResolvedSettings = ResolvedSettingsSnapshot(
                runID: UUID(), resolvedAt: Date(), collectionID: nil, projectID: nil, projectName: nil, macMemoryGB: 16,
                values: [SettingsKey.dateImageEveryDocument.rawValue: ResolvedSetting(value: .bool(imageEvery))],
                processing: [:])
            return (p, files, outputs)
        }
        func json(_ u: URL?) -> [String: Any] {
            guard let u, let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        func applied(_ p: OCRProcessor, _ f: URL) -> [String] { p.jobs.first { $0.sourceURL == f }?.appliedTags ?? [] }
        guard let route = OpenRouterRoute.catalog.first else { check("3 an OpenRouter route", false); return }

        // A remote gateway: the measured route.
        let gw = GatewayConfig(baseURL: "https://gateway.test/v1", modelID: "some-tagging-model", displayName: "Gateway")
        let (g, gFiles, gOut) = processor(gateway: gw, out: "gateway")
        check("3 five segments, E an enclosure of A", g.segments.count == 5 && g.segments[1].enclosureOf == 0,
              "\(g.segments.map(\.enclosureOf))")
        await g.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                    enableSegmentJSON: true)
        check("3 gateway: every document tagged and dated once", wire.tagging == 5 && wire.trace.sorted() == markers.sorted(),
              "\(wire.tagging) \(wire.trace)")
        check("3 gateway: the image pass only on the documents whose text has no year (B C D E, not A)",
              wire.images.map { $0.first ?? 0 }.sorted() == [120, 130, 140, 150], "\(wire.images)")
        check("3 gateway: the dating calls ask for the measured model", wire.models.contains(DateRoute.gatewayModel))
        let a = applied(g, gFiles[0]), aj = json(gOut["DOCA"])
        check("3 A: 1947 from its text with the tagging call's month and day, no Date Uncertain",
              a.contains("1947") && a.contains("03 March") && a.contains("Day 3") && !a.contains("Date Uncertain"), "\(a)")
        check("3 A: the sidecar's dating object names the class, the quote and its line",
              (aj["dating"] as? [String: Any])?["class"] as? String == "text"
              && (aj["dating"] as? [String: Any])?["line"] as? Int == 2 && aj["date_uncertain"] as? Bool == false)
        let b = applied(g, gFiles[2]), bd = json(gOut["DOCB"])["dating"] as? [String: Any] ?? [:]
        check("3 B: 1961 from the page image, its month, no flag (not the tagging call's 1950, not the estimate)",
              b.contains("1961") && b.contains("03 March") && !b.contains("1950") && !b.contains("Date Uncertain"), "\(b)")
        check("3 B: the stamp is a second-role date in the sidecar, not a second year tag",
              (bd["second_role_dates"] as? [[String: Any]])?.first?["quote"] as? String == "RECEIVED APR 4 1961"
              && !b.contains("Sent With 1961") && bd["image_pass"] as? String == DateRoute.imageSent)
        let c = applied(g, gFiles[3]), cd = json(gOut["DOCC"])["dating"] as? [String: Any] ?? [:]
        check("3 C: the neighbour's 1947, always Date Uncertain, never a month",
              c.contains("1947") && c.contains("Date Uncertain") && !c.contains("05 May") && !c.contains("1950"), "\(c)")
        check("3 C: the estimate cites A's output file, the check and the measured interval",
              cd["class"] as? String == "estimate" && cd["source"] as? String == "gateway-DOCA.jpg"
              && (cd["interval_90"] as? [String: Any])?["hi"] as? Int == 1949)
        let dTags = applied(g, gFiles[4]), dd = json(gOut["DOCD"])
        check("3 D: an estimate that fails its check writes no year and shows nothing of it",
              !dTags.contains("1951") && !dTags.contains("1950") && dTags.contains("Date Uncertain")
              && (dd["dating"] as? [String: Any])?["class"] as? String == "none" && dd["date"] == nil, "\(dTags)")
        let e = applied(g, gFiles[1]), ed = json(gOut["DOCE"])
        check("3 E: the enclosure takes its cover's year with Date Uncertain, and Sent With the cover's date",
              e.contains("1947") && e.contains("Date Uncertain") && e.contains("Sent With 1947-03-03"), "\(e)")
        check("3 E: the sidecar names the cover as the source", (ed["dating"] as? [String: Any])?["class"] as? String
              == "inherited" && (ed["dating"] as? [String: Any])?["source"] as? String == "gateway-DOCA.jpg"
              && ed["enclosure_of"] != nil)

        // The switch on: the image pass on A too, for its stamp; A's text year stands.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (every, eFiles, eOut) = processor(gateway: gw, out: "every", imageEvery: true)
        await every.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                        enableSegmentJSON: true)
        let ea = applied(every, eFiles[0]), ead = json(eOut["DOCA"])["dating"] as? [String: Any] ?? [:]
        check("3 switch on: the image pass on every document", wire.images.count == 5, "\(wire.images)")
        check("3 switch on: A keeps its text year and gains its stamp as a second-role date",
              ea.contains("1947") && !ea.contains("Date Uncertain") && ead["class"] as? String == "text"
              && (ead["second_role_dates"] as? [[String: Any]])?.first?["quote"] as? String == "Rec'd MAR 9 1947")

        // A gateway that does not serve the measured model: the trace asked again on the gateway's own model, no image
        // pass, no interval, the route named as the gateway's own.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = []; wire.refuseMeasured = true }
        let (other, oFiles2, oOut2) = processor(gateway: gw, out: "othergw")
        await other.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                        enableSegmentJSON: true)
        wire.lock.withLock { wire.refuseMeasured = false }
        let oc = applied(other, oFiles2[3]), ocd = json(oOut2["DOCC"])["dating"] as? [String: Any] ?? [:]
        check("3 gateway without the measured model: dated on its own model, no image call, no interval",
              wire.trace.count == 5 && wire.images.isEmpty && oc.contains("1947") && oc.contains("Date Uncertain")
              && ocd["interval_90"] == nil && ocd["route"] as? String == "Gateway · Gateway"
              && ocd["image_pass"] as? String == DateRoute.imageNoRoute, "\(wire.trace) \(wire.images) \(oc) \(ocd)")
        let gcd = json(gOut["DOCC"])["dating"] as? [String: Any] ?? [:]
        check("3 the measured route is named in the sidecar", gcd["route"] as? String == "Gateway · gemini-3.7-flash")

        // A direct key: no measured image route, so step 2 is skipped and says so; the trace call takes the run's route.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (direct, dFiles, dOut) = processor(gateway: nil, out: "direct")
        await direct.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                         outputDirectory: tmp, enableSegmentJSON: true)
        check("3 direct key: dated once each, no image call", wire.trace.count == 5 && wire.images.isEmpty,
              "\(wire.trace) \(wire.images)")
        let db = applied(direct, dFiles[2]), dbd = json(dOut["DOCB"])["dating"] as? [String: Any] ?? [:]
        check("3 direct key: B falls to the neighbour estimate, Date Uncertain, no interval shown",
              db.contains("1947") && db.contains("Date Uncertain") && dbd["image_pass"] as? String == DateRoute.imageNoRoute
              && dbd["interval_90"] == nil && dbd["class"] as? String == "estimate", "\(db) \(dbd)")

        // Sidecars off: the route still dates the tags; no sidecar is written.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (off, oFiles, oOut) = processor(gateway: nil, out: "off")
        await off.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                      outputDirectory: tmp, enableSegmentJSON: false)
        check("3 sidecars off: the tags still dated by the route, no sidecar", applied(off, oFiles[0]).contains("1947")
              && !fm.fileExists(atPath: oOut["DOCA"]!.path))
    }
}
#endif
